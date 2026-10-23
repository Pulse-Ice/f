#import "SGLog.h"
#import <stdatomic.h>

static const NSUInteger kLogLimit = 256 * 1024;
static dispatch_queue_t sg_logQueue;
static const void *sg_logQueueKey = &sg_logQueueKey;

static dispatch_queue_t logQueue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_logQueue = dispatch_queue_create("spotifyglass.diagnostics.log", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(sg_logQueue, sg_logQueueKey, (void *)sg_logQueueKey, NULL);
    });
    return sg_logQueue;
}

static NSURL *logFile(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    return [[support URLByAppendingPathComponent:@"spoti.pw" isDirectory:YES]
            URLByAppendingPathComponent:@"diagnostics.log"];
}

static void appendLog(NSString *message) {
    static NSDateFormatter *formatter;
    if (!formatter) {
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    }
    NSString *line = [NSString stringWithFormat:@"%@ [spotifyglass] %@\n", [formatter stringFromDate:NSDate.date], message];
    NSData *addition = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *url = logFile();
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
                               withIntermediateDirectories:YES attributes:nil error:&error]) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_ERROR, "[spotifyglass] cannot create diagnostics directory: %{public}s",
                         error.localizedDescription.UTF8String ?: "unknown error");
        return;
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path] &&
        ![NSFileManager.defaultManager createFileAtPath:url.path contents:nil attributes:nil]) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_ERROR, "[spotifyglass] cannot create diagnostics log");
        return;
    }
    NSNumber *size = nil;
    if (![url getResourceValue:&size forKey:NSURLFileSizeKey error:&error]) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_ERROR, "[spotifyglass] cannot inspect diagnostics log: %{public}s",
                         error.localizedDescription.UTF8String ?: "unknown error");
        return;
    }
    if (size.unsignedIntegerValue + addition.length > kLogLimit) {
        NSMutableData *data = [[NSData dataWithContentsOfURL:url options:0 error:&error] mutableCopy];
        if (!data) {
            os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_ERROR, "[spotifyglass] cannot rotate diagnostics log: %{public}s",
                             error.localizedDescription.UTF8String ?: "unknown error");
            return;
        }
        [data appendData:addition];
        NSUInteger discard = data.length - kLogLimit;
        const uint8_t *bytes = data.bytes;
        while (discard < data.length && bytes[discard] != '\n') discard++;
        if (discard < data.length) {
            discard++;
        } else {
            discard = data.length - kLogLimit;
            while (discard < data.length && (bytes[discard] & 0xC0) == 0x80) discard++;
        }
        [data replaceBytesInRange:NSMakeRange(0, discard) withBytes:NULL length:0];
        if (![data writeToURL:url options:NSDataWritingAtomic error:&error]) {
            os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_ERROR, "[spotifyglass] cannot save diagnostics log: %{public}s",
                             error.localizedDescription.UTF8String ?: "unknown error");
        }
        return;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:url.path];
    if (!handle) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_ERROR, "[spotifyglass] cannot open diagnostics log");
        return;
    }
    [handle seekToEndOfFile];
    if (![handle writeData:addition error:&error]) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_ERROR, "[spotifyglass] cannot append diagnostics log: %{public}s",
                         error.localizedDescription.UTF8String ?: "unknown error");
    }
    error = nil;
    if (![handle closeAndReturnError:&error]) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_ERROR, "[spotifyglass] cannot close diagnostics log: %{public}s",
                         error.localizedDescription.UTF8String ?: "unknown error");
    }
}

static atomic_uint_fast64_t sg_seq = ATOMIC_VAR_INIT(0);
static NSMutableArray<NSDictionary *> *sg_recent = nil;
static const NSUInteger kRecentKept = 500;

// Dedicated lock object for sg_recent. (The old code used @synchronized(SGLogMessage),
// but SGLogMessage is a C function, not an ObjC object, so newer clang rejects it.)
static NSObject *SGLogRecentLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

void SGLogMessage(NSString *message) {
    NSString *text = message ?: @"(empty log message)";
    uint64_t seq = atomic_fetch_add_explicit(&sg_seq, 1, memory_order_relaxed) + 1;
    NSTimeInterval at = NSDate.date.timeIntervalSince1970;
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "[spotifyglass] %{public}s", text.UTF8String);
    dispatch_async(logQueue(), ^{
        @synchronized (SGLogRecentLock()) {
            if (!sg_recent) sg_recent = [NSMutableArray array];
            [sg_recent addObject:@{@"seq": @(seq), @"text": text, @"at": @(at)}];
            if (sg_recent.count > kRecentKept) [sg_recent removeObjectsInRange:NSMakeRange(0, sg_recent.count - kRecentKept)];
        }
        appendLog(text);
    });
}

uint64_t SGLogLastSeq(void) {
    return atomic_load_explicit(&sg_seq, memory_order_relaxed);
}

NSArray<NSDictionary *> *SGLogRecent(uint64_t since) {
    __block NSArray *out = nil;
    // Copy under lock on the log queue to avoid racing appends; never blocks main for long
    // (bounded copy of at most kRecentKept small dictionaries).
    dispatch_block_t copy = ^{
        @synchronized (SGLogRecentLock()) {
            if (!sg_recent) out = @[];
            else {
                NSMutableArray *kept = [NSMutableArray array];
                for (NSDictionary *line in sg_recent) {
                    if ([line[@"seq"] unsignedLongLongValue] > since) [kept addObject:line];
                }
                out = [kept copy];
            }
        }
    };
    if (dispatch_get_specific(sg_logQueueKey)) copy();
    else dispatch_sync(logQueue(), copy);
    return out;
}

BOOL SGRunOnMain(NSTimeInterval timeout, dispatch_block_t block) {
    if (!block) return YES;
    if (NSThread.isMainThread) {
        block();
        return YES;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        block();
        dispatch_semaphore_signal(done);
    });
    return dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) == 0;
}

NSString *SGLogContents(void) {
    __block NSString *contents;
    dispatch_block_t read = ^{
        NSError *error = nil;
        contents = [NSString stringWithContentsOfURL:logFile() encoding:NSUTF8StringEncoding error:&error];
        if (!contents && error && error.code != NSFileReadNoSuchFileError) {
            os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_ERROR, "[spotifyglass] cannot read diagnostics log: %{public}s",
                             error.localizedDescription.UTF8String ?: "unknown error");
            contents = [NSString stringWithFormat:@"Could not read the diagnostics log: %@", error.localizedDescription];
        }
        if (!contents) contents = @"No diagnostics have been recorded yet.";
    };
    dispatch_queue_t queue = logQueue();
    if (dispatch_get_specific(sg_logQueueKey)) read();
    else dispatch_sync(queue, read);
    return contents;
}

// The unified log cuts a message at about 1 KB, so long dumps go out as numbered parts.
void SGLogLong(NSString *tag, NSString *text) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSMutableString *current = [NSMutableString string];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (current.length && [current lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + [line lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 900) {
            [parts addObject:[current copy]];
            [current setString:@""];
        }
        [current appendFormat:@"%@\n", line];
    }
    if (current.length) [parts addObject:current];
    [parts enumerateObjectsUsingBlock:^(NSString *part, NSUInteger i, BOOL *stop) {
        SGLog(@"%@ %lu/%lu\n%@", tag, (unsigned long)i + 1, (unsigned long)parts.count, part);
    }];
}

void SGRequireClasses(NSArray<NSString *> *names) {
    for (NSString *name in names) {
        if (!NSClassFromString(name)) SGLog(@"class %@ not found, its hooks are inactive", name);
    }
}
