// Launch tracer for hangs before the first frame (notably LiveContainer guests, where the
// Mac console is unavailable). Writes to Documents/spotifyglass-launch.log, which can be
// read from the Files app after killing the frozen app. Each launch overwrites the file.
//
// - constructor(101) runs before every Logos %ctor, so the first line proves the dylib loaded;
// - a watchdog thread pings the main queue every 2 s; while a ping goes unanswered it dumps
//   the main thread's stack (suspend + frame-pointer walk, no allocation while suspended);
// - app-lifecycle notes show whether UIApplicationMain ever got going.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>

static char sg_tracePath[1024];
static pthread_mutex_t sg_traceLock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint64_t sg_pingPending;
static mach_port_t sg_mainThread;
static uintptr_t sg_stackLow, sg_stackHigh;

static void traceWrite(const char *line) {
    pthread_mutex_lock(&sg_traceLock);
    FILE *f = fopen(sg_tracePath, "a");
    if (f) {
        fputs(line, f);
        fputc('\n', f);
        fclose(f);
    }
    pthread_mutex_unlock(&sg_traceLock);
}

// Allocation-free: the main thread is suspended while this runs.
static int walkMain(uintptr_t *frames, int max) {
    int n = 0;
    if (thread_suspend(sg_mainThread) != KERN_SUCCESS) return 0;
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(sg_mainThread, ARM_THREAD_STATE64, (thread_state_t)&state, &count) == KERN_SUCCESS) {
        frames[n++] = (uintptr_t)arm_thread_state64_get_pc(state) & 0x0000007FFFFFFFFFull;
        if (n < max) frames[n++] = (uintptr_t)arm_thread_state64_get_lr(state) & 0x0000007FFFFFFFFFull;
        uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(state);
        while (fp && n < max && fp >= sg_stackLow && fp + 2 * sizeof(uintptr_t) <= sg_stackHigh && !(fp & 0x7)) {
            uintptr_t next = ((uintptr_t *)fp)[0];
            uintptr_t ret = ((uintptr_t *)fp)[1] & 0x0000007FFFFFFFFFull;
            if (ret) frames[n++] = ret;
            if (next <= fp) break;
            fp = next;
        }
    }
    thread_resume(sg_mainThread);
    return n;
}

static void describeInto(uintptr_t address, char *out, size_t size) {
    Dl_info info;
    if (!dladdr((void *)address, &info) || !info.dli_fname) {
        snprintf(out, size, "? 0x%lx", (unsigned long)address);
        return;
    }
    const char *slash = strrchr(info.dli_fname, '/');
    const char *image = slash ? slash + 1 : info.dli_fname;
    if (info.dli_sname && strcmp(info.dli_sname, "<redacted>") != 0) {
        snprintf(out, size, "%s %s+%lu", image, info.dli_sname,
                 (unsigned long)(address - (uintptr_t)info.dli_saddr));
    } else {
        snprintf(out, size, "%s +0x%lx", image, (unsigned long)(address - (uintptr_t)info.dli_saddr));
    }
}

static void *watcher(void *unused) {
    char buf[512];
    int stuck = 0;
    for (int tick = 0; tick < 150; tick++) {
        atomic_store(&sg_pingPending, mach_absolute_time());
        dispatch_async(dispatch_get_main_queue(), ^{ atomic_store(&sg_pingPending, 0); });
        sleep(2);
        if (atomic_load(&sg_pingPending)) {
            stuck++;
            uintptr_t frames[40];
            int n = walkMain(frames, 40);
            snprintf(buf, sizeof buf, "[+%ds] main thread not answering (sample %d, %d frames)", tick * 2, stuck, n);
            traceWrite(buf);
            for (int i = 0; i < n; i++) {
                describeInto(frames[i], buf, sizeof buf);
                traceWrite(buf);
            }
            if (stuck >= 5) sleep(8); // keep sampling a long hang without flooding the file
        } else if (stuck) {
            traceWrite("main thread answered again (hang ended)");
            stuck = 0;
        }
    }
    traceWrite("watchdog stopping after ~5 min");
    return NULL;
}

__attribute__((constructor(101))) static void SGLaunchTraceInit(void) {
    @autoreleasepool {
        NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *dir = docs.firstObject ?: NSTemporaryDirectory();
        NSString *path = [dir stringByAppendingPathComponent:@"spotifyglass-launch.log"];
        strncpy(sg_tracePath, path.UTF8String ?: "/tmp/spotifyglass-launch.log", sizeof sg_tracePath - 1);
        FILE *f = fopen(sg_tracePath, "w");
        if (f) {
            fprintf(f, "taurus launch pid=%d bundle=%s ios=%s\n", getpid(),
                    NSBundle.mainBundle.bundleIdentifier.UTF8String ?: "?",
                    UIDevice.currentDevice.systemVersion.UTF8String ?: "?");
            fclose(f);
        }
        sg_mainThread = mach_thread_self();
        pthread_t self = pthread_self();
        sg_stackHigh = (uintptr_t)pthread_get_stackaddr_np(self);
        sg_stackLow = sg_stackHigh - pthread_get_stacksize_np(self);
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            traceWrite("note: didFinishLaunching");
        }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            traceWrite("note: didBecomeActive");
        }];
        pthread_t th;
        if (pthread_create(&th, NULL, watcher, NULL) == 0) pthread_detach(th);
        traceWrite("watchdog started");
    }
}
