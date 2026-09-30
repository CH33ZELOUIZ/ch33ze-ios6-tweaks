#import <Foundation/Foundation.h>

static NSString * const CHZQueuePath = @"/var/mobile/Library/NavTunesImportQueue.plist";

static void usage(const char *argv0) {
    fprintf(stderr, "Usage: %s -f file -t title [-a artist] [-b album] [-g genre] [-l seconds] [-y year] [-w artwork.jpg]\n", argv0);
}

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
    if (![[item objectForKey:@"path"] length] || ![[item objectForKey:@"title"] length]) { usage(argv[0]); return 2; }
    NSMutableArray *queue = [NSMutableArray arrayWithContentsOfFile:CHZQueuePath];
    if (!queue) queue = [NSMutableArray array];
    [queue addObject:item];
    if (![queue writeToFile:CHZQueuePath atomically:YES]) {
        fprintf(stderr, "failed to write %s\n", [CHZQueuePath UTF8String]);
        return 1;
    }
    printf("queued import: %s\n", [[item objectForKey:@"title"] UTF8String]);
    [pool drain];
    return 0;
}
