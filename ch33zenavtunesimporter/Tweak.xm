#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>

static NSString * const CHZQueuePath = @"/var/mobile/Library/NavTunesImportQueue.plist";
static NSString * const CHZLogPath = @"/var/mobile/Library/Logs/NavTunesImporter.log";
static BOOL CHZBusy = NO;
static NSTimer *CHZTimer = nil;

static void CHZLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *out = [NSString stringWithFormat:@"[%@] %@\n", [[NSDate date] description], line];
    FILE *f = fopen([CHZLogPath UTF8String], "a");
    if (f) { fputs([out UTF8String], f); fclose(f); }
    NSLog(@"NavTunesImporter: %@", line);
    [line release];
}

static id CHZNewMetadata(NSDictionary *item) {
    Class Meta = objc_getClass("SSDownloadMetadata");
    if (!Meta) Meta = NSClassFromString(@"SSDownloadMetadata");
    if (!Meta) { CHZLog(@"SSDownloadMetadata missing"); return nil; }

    NSDictionary *base = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0] forKey:@"is-in-queue"];
    id metad = [[Meta alloc] initWithDictionary:base];
    if (!metad) { CHZLog(@"metadata init failed"); return nil; }

#define CALL1(selName, obj) do { SEL s = NSSelectorFromString(selName); if ([metad respondsToSelector:s] && (obj)) [metad performSelector:s withObject:(obj)]; else CHZLog(@"metadata selector missing or nil: %@", selName); } while(0)
    NSString *path = [item objectForKey:@"path"];
    CALL1(@"setPrimaryAssetURL:", [NSURL fileURLWithPath:path]);
    CALL1(@"setKind:", [item objectForKey:@"kind"] ?: @"song");
    CALL1(@"setTitle:", [item objectForKey:@"title"] ?: [[path lastPathComponent] stringByDeletingPathExtension]);
    CALL1(@"setArtistName:", [item objectForKey:@"artist"] ?: @"Unknown Artist");
    CALL1(@"setCollectionName:", [item objectForKey:@"album"] ?: @"NavTunes");
    CALL1(@"setGenre:", [item objectForKey:@"genre"] ?: @"Music");
    CALL1(@"setDurationInMilliseconds:", [item objectForKey:@"duration"] ?: [NSNumber numberWithInt:0]);
    CALL1(@"setReleaseYear:", [item objectForKey:@"year"] ?: [NSNumber numberWithInt:0]);
    CALL1(@"setCopyright:", @"Imported by CH33ZE NavTunes");
    CALL1(@"setPurchaseDate:", [NSDate date]);
    CALL1(@"setReleaseDate:", [NSDate date]);
    NSString *artwork = [item objectForKey:@"artwork"];
    if ([artwork length]) CALL1(@"setFullSizeImageURL:", [NSURL fileURLWithPath:artwork]);
#undef CALL1
    return metad;
}

static BOOL CHZImportItem(NSDictionary *item) {
    NSString *path = [item objectForKey:@"path"];
    if (![path length] || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        CHZLog(@"missing file for import: %@", path);
        return NO;
    }

    dlopen("/System/Library/PrivateFrameworks/StoreServices.framework/StoreServices", RTLD_LAZY | RTLD_GLOBAL);
    Class Queue = objc_getClass("SSDownloadQueue");
    Class Download = objc_getClass("SSDownload");
    if (!Queue || !Download) {
        CHZLog(@"StoreServices classes missing Queue=%@ Download=%@", Queue, Download);
        return NO;
    }

    id metad = CHZNewMetadata(item);
    if (!metad) return NO;

    id kinds = nil;
    if ([Queue respondsToSelector:@selector(mediaDownloadKinds)]) kinds = [Queue performSelector:@selector(mediaDownloadKinds)];
    id queue = [[Queue alloc] initWithDownloadKinds:kinds];
    id download = [[Download alloc] initWithDownloadMetadata:metad];
    [metad release];

    if (!queue || !download) {
        CHZLog(@"queue/download init failed queue=%@ download=%@", queue, download);
        [queue release]; [download release];
        return NO;
    }

    SEL setHandler = NSSelectorFromString(@"setDownloadHandler:completionBlock:");
    if ([download respondsToSelector:setHandler]) {
        void (^block)(void) = ^{ CHZLog(@"completion block title=%@", [item objectForKey:@"title"]); };
        typedef void (*MsgSendSetHandler)(id, SEL, id, id);
        ((MsgSendSetHandler)objc_msgSend)(download, setHandler, nil, block);
    }
    if ([queue respondsToSelector:@selector(addDownload:)]) {
        [queue performSelector:@selector(addDownload:) withObject:download];
        CHZLog(@"queued native import: %@", path);
    } else {
        CHZLog(@"SSDownloadQueue addDownload: missing");
        [queue release]; [download release];
        return NO;
    }

    [download release];
    [queue release];
    return YES;
}

static void CHZProcessQueue(void) {
    if (CHZBusy) return;
    CHZBusy = YES;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSArray *queue = [NSArray arrayWithContentsOfFile:CHZQueuePath];
    if ([queue count] > 0) {
        CHZLog(@"processing queue count=%u", [queue count]);
        NSMutableArray *remaining = [NSMutableArray array];
        for (NSDictionary *item in queue) {
            if (![item isKindOfClass:[NSDictionary class]] || !CHZImportItem(item)) [remaining addObject:item];
        }
        if ([remaining count]) [remaining writeToFile:CHZQueuePath atomically:YES];
        else [[NSFileManager defaultManager] removeItemAtPath:CHZQueuePath error:nil];
    }
    [pool drain];
    CHZBusy = NO;
}

static void CHZStartImporter(void) {
    if (CHZTimer) return;
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
    CHZLog(@"Music hook active in %@; queue=%@", bundle, CHZQueuePath);
    dlopen("/System/Library/PrivateFrameworks/StoreServices.framework/StoreServices", RTLD_LAZY | RTLD_GLOBAL);
    // Defer work until Music has finished launching; doing StoreServices work in the ctor can trip the iOS watchdog.
    CHZTimer = [[NSTimer scheduledTimerWithTimeInterval:15.0
                                                 target:[NSBlockOperation blockOperationWithBlock:^{ CHZProcessQueue(); }]
                                               selector:@selector(main)
                                               userInfo:nil
                                                repeats:YES] retain];
}

%ctor {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
    CHZLog(@"ctor loaded in %@", bundle);
    if ([bundle isEqualToString:@"com.apple.mobileipod"]) {
        CHZStartImporter();
    }
    [pool drain];
}
