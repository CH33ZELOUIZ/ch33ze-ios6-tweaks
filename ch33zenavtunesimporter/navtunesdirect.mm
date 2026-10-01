#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static void usage(const char *argv0) {
    fprintf(stderr, "Usage: %s -f file -t title [-a artist] [-b album] [-g genre] [-l seconds] [-y year] [-w artwork.jpg]\n", argv0);
}

static id getArg(NSDictionary *d, NSString *k, id def) { id v=[d objectForKey:k]; return v ? v : def; }

int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSMutableDictionary *item = [NSMutableDictionary dictionaryWithObject:@"song" forKey:@"kind"];
    for (int i = 1; i < argc; i++) {
        NSString *arg = [NSString stringWithUTF8String:argv[i]];
        if (i + 1 >= argc) { usage(argv[0]); return 2; }
        NSString *val = [NSString stringWithUTF8String:argv[++i]];
        if ([arg isEqualToString:@"-f"]) [item setObject:val forKey:@"path"];
        else if ([arg isEqualToString:@"-t"]) [item setObject:val forKey:@"title"];
        else if ([arg isEqualToString:@"-a"]) [item setObject:val forKey:@"artist"];
        else if ([arg isEqualToString:@"-b"]) [item setObject:val forKey:@"album"];
        else if ([arg isEqualToString:@"-g"]) [item setObject:val forKey:@"genre"];
        else if ([arg isEqualToString:@"-l"]) [item setObject:[NSNumber numberWithInt:(int)([val floatValue] * 1000.0f)] forKey:@"duration"];
        else if ([arg isEqualToString:@"-y"]) [item setObject:[NSNumber numberWithInt:[val intValue]] forKey:@"year"];
        else if ([arg isEqualToString:@"-w"]) [item setObject:val forKey:@"artwork"];
        else { usage(argv[0]); return 2; }
    }
    NSString *path=[item objectForKey:@"path"];
    if (![path length] || ![[item objectForKey:@"title"] length]) { usage(argv[0]); return 2; }
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) { fprintf(stderr, "missing file: %s\n", [path UTF8String]); return 1; }

    NSString *tmpName = [NSString stringWithFormat:@"navtunes-%d-%@.%@", getpid(), [[path lastPathComponent] stringByDeletingPathExtension], [path pathExtension]];
    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:tmpName];
    [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
    NSError *copyError = nil;
    if (![[NSFileManager defaultManager] copyItemAtPath:path toPath:tmpPath error:&copyError]) {
        fprintf(stderr, "copy failed: %s\n", [[copyError description] UTF8String]);
        return 1;
    }
    path = tmpPath;
    fprintf(stderr, "using temp asset: %s\n", [path UTF8String]);

    dlopen("/System/Library/PrivateFrameworks/StoreServices.framework/StoreServices", RTLD_LAZY | RTLD_GLOBAL);
    Class Meta=objc_getClass("SSDownloadMetadata");
    Class Queue=objc_getClass("SSDownloadQueue");
    Class Download=objc_getClass("SSDownload");
    Class Options=objc_getClass("SSDownloadManagerOptions");
    fprintf(stderr, "classes Meta=%p Queue=%p Download=%p Options=%p\n", Meta, Queue, Download, Options);
    if (!Meta || !Queue || !Download) return 3;

    id meta = [[Meta alloc] initWithDictionary:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0] forKey:@"is-in-queue"]];
#define CALL(selName, obj) do { SEL s=NSSelectorFromString(selName); id o=(obj); if ([meta respondsToSelector:s] && o) ((void(*)(id,SEL,id))objc_msgSend)(meta,s,o); else fprintf(stderr,"skip %s\n", [selName UTF8String]); } while(0)
    CALL(@"setPrimaryAssetURL:", [NSURL fileURLWithPath:path]);
    CALL(@"setViewStoreItemURL:", [NSURL URLWithString:@"http://twitter.com/H2CO3_iOS"]);
    CALL(@"setCopyright:", @"Imported by CH33ZE NavTunes");
    CALL(@"setKind:", getArg(item,@"kind",@"song"));
    CALL(@"setTitle:", getArg(item,@"title",[path lastPathComponent]));
    CALL(@"setArtistName:", getArg(item,@"artist",@"Unknown Artist"));
    CALL(@"setCollectionName:", getArg(item,@"album",@"NavTunes"));
    CALL(@"setGenre:", getArg(item,@"genre",@"Music"));
    CALL(@"setDurationInMilliseconds:", getArg(item,@"duration",[NSNumber numberWithInt:0]));
    CALL(@"setReleaseYear:", getArg(item,@"year",[NSNumber numberWithInt:0]));
    CALL(@"setPurchaseDate:", [NSDate date]);
    CALL(@"setReleaseDate:", [NSDate date]);
    NSString *art=[item objectForKey:@"artwork"]; if ([art length]) CALL(@"setFullSizeImageURL:", [NSURL fileURLWithPath:art]);
#undef CALL
    id kinds = [Queue respondsToSelector:@selector(mediaDownloadKinds)] ? ((id(*)(id,SEL))objc_msgSend)(Queue,@selector(mediaDownloadKinds)) : nil;
    id queue = nil;
    if (Options && [Queue instancesRespondToSelector:@selector(initWithDownloadManagerOptions:)]) {
        id opts = [[Options alloc] init];
        if ([opts respondsToSelector:@selector(setDownloadKinds:)]) ((void(*)(id,SEL,id))objc_msgSend)(opts, @selector(setDownloadKinds:), kinds);
        if ([opts respondsToSelector:@selector(setPersistenceIdentifier:)]) ((void(*)(id,SEL,id))objc_msgSend)(opts, @selector(setPersistenceIdentifier:), @"com.apple.mobileipod");
        if ([opts respondsToSelector:@selector(setShouldFilterExternalOriginatedDownloads:)]) ((void(*)(id,SEL,BOOL))objc_msgSend)(opts, @selector(setShouldFilterExternalOriginatedDownloads:), NO);
        queue = [[Queue alloc] initWithDownloadManagerOptions:opts];
        [opts release];
    }
    if (!queue) queue = [[Queue alloc] initWithDownloadKinds:kinds];
    id download = [[Download alloc] initWithDownloadMetadata:meta];
    fprintf(stderr, "objects meta=%p queue=%p download=%p\n", meta, queue, download);
    if (!queue || !download) return 4;
    if ([queue respondsToSelector:@selector(setShouldAutomaticallyFinishDownloads:)]) {
        ((void(*)(id,SEL,BOOL))objc_msgSend)(queue, @selector(setShouldAutomaticallyFinishDownloads:), YES);
    }
    SEL setHandler = NSSelectorFromString(@"setDownloadHandler:completionBlock:");
    if ([download respondsToSelector:setHandler]) {
        id heldQueue = [queue retain];
        void (^block)(void) = ^{ fprintf(stderr, "completion block\n"); [heldQueue release]; };
        ((void(*)(id,SEL,id,id))objc_msgSend)(download, setHandler, nil, block);
    }
    ((void(*)(id,SEL,id))objc_msgSend)(queue, @selector(addDownload:), download);
    fprintf(stderr, "addDownload returned\n");
    for (int i = 0; i < 15; i++) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
    [download release]; [queue release]; [meta release];
    [pool drain];
    return 0;
}
