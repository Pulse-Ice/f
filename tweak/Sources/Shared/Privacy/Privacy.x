#import "Core/SGCore.h"
#import "Privacy.h"

typedef struct { const char *host, *path, *label; } SGBlockRule;

// host matched on the domain and its subdomains, path as a substring; no path means the whole host.
static const SGBlockRule kRules[] = {
    {"app-measurement.com",               NULL,                      "Firebase"},
    {"crashlytics.com",                   NULL,                      "Crashlytics"},
    {"facebook.com",                      "/activities",             "Facebook"},
    {"ep1.facebook.com",                  NULL,                      "Facebook"},
    {"ep2.facebook.com",                  NULL,                      "Facebook"},
    {"branch.io",                         "/v1/event",               "Branch"},
    {"scorecardresearch.com",             NULL,                      "Comscore"},
    {"segment.io",                        NULL,                      "Segment"},
    {"zqtk.net",                          NULL,                      "Segment"},
    {"google-analytics.com",              NULL,                      "Google"},
    {"googleadservices.com",              NULL,                      "Google"},
    {"doubleclick.net",                   NULL,                      "Google"},
};
static const size_t kRuleCount = sizeof(kRules) / sizeof(kRules[0]);

static NSString *const kCounts = @"spotifyglass.privacy.counts";
static NSMutableDictionary<NSString *, NSNumber *> *sg_counts;
static BOOL sg_dirty;             // in-memory counts are newer than what is stored
static BOOL sg_flushScheduled;    // a background write is already queued

@interface SGBlockProtocol : NSURLProtocol
@end

static NSMutableDictionary<NSString *, NSNumber *> *countsLocked(void) {
    if (!sg_counts) {
        sg_counts = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kCounts] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSSet<NSString *> *current = [NSSet setWithArray:SGBlockedLabels()];
        for (NSString *label in sg_counts.allKeys) {
            if (![current containsObject:label]) sg_counts[label] = nil;
        }
        if (sg_counts.count) sg_dirty = YES; // pruned entries are dropped on the next flush
    }
    return sg_counts;
}

static dispatch_queue_t flushQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("spotifyglass.privacy.flush", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

// The stored counts are only ever touched here, off whatever thread counted: a stall in the
// preferences daemon then parks this queue alone, never the app (LiveContainer guests).
static void flushAsync(void) {
    dispatch_async(flushQueue(), ^{
        NSDictionary *snapshot = nil;
        @synchronized (SGBlockProtocol.class) {
            sg_flushScheduled = NO;
            if (!sg_dirty || !sg_counts) return;
            snapshot = [sg_counts copy];
            sg_dirty = NO;
        }
        if (snapshot) [NSUserDefaults.standardUserDefaults setObject:snapshot forKey:kCounts];
    });
}

// Called with the counts lock held. Coalesces bursts into one write.
static void noteDirtyLocked(void) {
    sg_dirty = YES;
    if (!sg_flushScheduled) {
        sg_flushScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), flushQueue(), ^{
            flushAsync();
        });
    }
}

static void countOne(NSString *label) {
    @synchronized (SGBlockProtocol.class) {
        NSMutableDictionary<NSString *, NSNumber *> *counts = countsLocked();
        counts[label] = @(counts[label].unsignedIntegerValue + 1);
        noteDirtyLocked();
    }
}

static NSString *labelFor(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    if (!host) return nil;
    NSString *path = url.path ?: @"";
    for (size_t i = 0; i < kRuleCount; i++) {
        NSString *domain = @(kRules[i].host);
        if (![host isEqualToString:domain] && ![host hasSuffix:[@"." stringByAppendingString:domain]]) continue;
        if (kRules[i].path && ![path containsString:@(kRules[i].path)]) continue;
        return @(kRules[i].label);
    }
    return nil;
}

NSArray<NSString *> *SGBlockedLabels(void) {
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    for (size_t i = 0; i < kRuleCount; i++) {
        NSString *label = @(kRules[i].label);
        if (![labels containsObject:label]) [labels addObject:label];
    }
    return labels;
}

NSUInteger SGBlockedCount(NSString *label) {
    @synchronized (SGBlockProtocol.class) {
        NSDictionary<NSString *, NSNumber *> *counts = countsLocked();
        if (label) return counts[label].unsignedIntegerValue;
        NSUInteger total = 0;
        for (NSNumber *count in counts.allValues) total += count.unsignedIntegerValue;
        return total;
    }
}

void SGResetBlocked(void) {
    @synchronized (SGBlockProtocol.class) {
        sg_counts = [NSMutableDictionary dictionary];
        sg_dirty = YES;
        noteDirtyLocked();
    }
}

@implementation SGBlockProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return labelFor(request.URL) != nil;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSString *label = labelFor(self.request.URL);
    if (label) countOne(label);
    // 204 rather than an error: the sender takes it for delivered and queues no retry behind it.
    NSHTTPURLResponse *answer = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:204 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    [self.client URLProtocol:self didReceiveResponse:answer cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
}

@end

static NSURLSessionConfiguration *carryingProtocol(NSURLSessionConfiguration *configuration) {
    if (!configuration || [configuration.protocolClasses containsObject:SGBlockProtocol.class]) return configuration;
    NSMutableArray *classes = [configuration.protocolClasses mutableCopy] ?: [NSMutableArray array];
    [classes insertObject:SGBlockProtocol.class atIndex:0];
    configuration.protocolClasses = classes;
    return configuration;
}

%hook NSURLSessionConfiguration

+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *configuration = %orig;
    return carryingProtocol(configuration);
}

+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *configuration = %orig;
    return carryingProtocol(configuration);
}

%end

%ctor {
    if (SGEnabled(SGKeyBlockTelemetry)) {
        [NSURLProtocol registerClass:SGBlockProtocol.class];
        %init;
    }
}
