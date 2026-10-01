#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>
#import <sqlite3.h>

static NSString * const CHZQueuePath = @"/var/mobile/Library/NavTunesImportQueue.plist";
static NSString * const CHZLogPath = @"/var/mobile/Library/Logs/NavTunesImporter.log";
static NSString * const CHZPrefsPath = @"/var/mobile/Library/Preferences/com.ch33ze.navtunes.plist";
static NSString * const CHZDownloadRoot = @"/var/mobile/Media/Downloads/NavTunes";
static NSString * const CHZDownloadsPath = @"/var/mobile/Library/NavTunesDownloads.plist";
static NSString * const CHZPlaylistRequestsPath = @"/var/mobile/Library/NavTunesPlaylistRequests.plist";
static BOOL CHZBusy = NO;
static NSTimer *CHZTimer = nil;
static AVAudioPlayer *CHZAudioPlayer = nil;
static NSMutableSet *CHZActiveSongIds = nil;
static void CHZLog(NSString *fmt, ...);
static void CHZSetDownloadRecord(NSDictionary *song, NSString *state, NSString *detail, NSString *path);
static BOOL CHZPlayLocalPath(NSString *path);

static BOOL CHZMusicLibraryHasImportedItem(NSDictionary *item) {
    NSString *title = [item objectForKey:@"title"] ?: @"";
    NSString *artist = [item objectForKey:@"artist"] ?: @"";
    NSString *album = [item objectForKey:@"album"] ?: @"";
    if (![title length]) return NO;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2("/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb", &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) return NO;
    const char *sql = "select i.item_pid from item i join item_extra e on i.item_pid=e.item_pid left join item_artist ar on i.item_artist_pid=ar.item_artist_pid left join album al on i.album_pid=al.album_pid where e.title=? and (?='' or ar.item_artist=?) and (?='' or al.album=?) and length(coalesce(e.location,''))>0 limit 1";
    sqlite3_stmt *stmt = NULL;
    BOOL found = NO;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, [title UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, [artist UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 3, [artist UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 4, [album UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 5, [album UTF8String], -1, SQLITE_TRANSIENT);
        found = (sqlite3_step(stmt) == SQLITE_ROW);
    }
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return found;
}

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

static BOOL CHZImportItem(NSDictionary *item) {
    NSString *path = [item objectForKey:@"path"];
    if (![path length] || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;

    // Use Apple's StoreServices download/import path instead of writing MediaLibrary.sqlitedb.
    // Copy to tmp because StoreServices moves/deletes the source asset during import.
    NSString *tmpName = [NSString stringWithFormat:@"navtunes-%u-%@.%@", arc4random(), [[path lastPathComponent] stringByDeletingPathExtension], [path pathExtension]];
    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:tmpName];
    [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
    NSError *copyError = nil;
    if (![[NSFileManager defaultManager] copyItemAtPath:path toPath:tmpPath error:&copyError]) {
        CHZLog(@"StoreServices import temp copy failed for %@: %@", path, [copyError localizedDescription]);
        CHZSetDownloadRecord(item, @"Downloaded", @"Saved MP3; Music import copy failed", path);
        return NO;
    }

    dlopen("/System/Library/PrivateFrameworks/StoreServices.framework/StoreServices", RTLD_LAZY | RTLD_GLOBAL);
    Class Meta = objc_getClass("SSDownloadMetadata");
    Class Queue = objc_getClass("SSDownloadQueue");
    Class Download = objc_getClass("SSDownload");
    Class Options = objc_getClass("SSDownloadManagerOptions");
    if (!Meta || !Queue || !Download) {
        CHZLog(@"StoreServices classes unavailable Meta=%p Queue=%p Download=%p", Meta, Queue, Download);
        [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
        CHZSetDownloadRecord(item, @"Downloaded", @"Saved MP3; Music importer unavailable", path);
        return NO;
    }

    CHZSetDownloadRecord(item, @"Importing", @"Sending to Music library", path);
    id meta = [[Meta alloc] initWithDictionary:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0] forKey:@"is-in-queue"]];
#define CHZ_META(selName, obj) do { SEL s = NSSelectorFromString(selName); id o = (obj); if ([meta respondsToSelector:s] && o) ((void(*)(id,SEL,id))objc_msgSend)(meta, s, o); } while (0)
    CHZ_META(@"setPrimaryAssetURL:", [NSURL fileURLWithPath:tmpPath]);
    CHZ_META(@"setViewStoreItemURL:", [NSURL URLWithString:@"http://cydia.personaltechwiz.com/"]);
    CHZ_META(@"setCopyright:", @"Imported by CH33ZE NavTunes");
    CHZ_META(@"setKind:", [item objectForKey:@"kind"] ?: @"song");
    CHZ_META(@"setTitle:", [item objectForKey:@"title"] ?: [[path lastPathComponent] stringByDeletingPathExtension]);
    CHZ_META(@"setArtistName:", [item objectForKey:@"artist"] ?: @"Unknown Artist");
    CHZ_META(@"setCollectionName:", [item objectForKey:@"album"] ?: @"NavTunes");
    CHZ_META(@"setGenre:", [item objectForKey:@"genre"] ?: @"Music");
    CHZ_META(@"setDurationInMilliseconds:", [item objectForKey:@"duration"] ?: [NSNumber numberWithInt:0]);
    CHZ_META(@"setReleaseYear:", [item objectForKey:@"year"] ?: [NSNumber numberWithInt:0]);
    CHZ_META(@"setPurchaseDate:", [NSDate date]);
    CHZ_META(@"setReleaseDate:", [NSDate date]);
#undef CHZ_META

    id kinds = [Queue respondsToSelector:@selector(mediaDownloadKinds)] ? ((id(*)(id,SEL))objc_msgSend)(Queue, @selector(mediaDownloadKinds)) : nil;
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
    if (!queue || !download) {
        CHZLog(@"StoreServices object creation failed queue=%p download=%p", queue, download);
        if (download) [download release]; if (queue) [queue release]; [meta release];
        [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
        CHZSetDownloadRecord(item, @"Downloaded", @"Saved MP3; Music importer failed", path);
        return NO;
    }
    if ([queue respondsToSelector:@selector(setShouldAutomaticallyFinishDownloads:)]) ((void(*)(id,SEL,BOOL))objc_msgSend)(queue, @selector(setShouldAutomaticallyFinishDownloads:), YES);
    SEL setHandler = NSSelectorFromString(@"setDownloadHandler:completionBlock:");
    if ([download respondsToSelector:setHandler]) {
        id heldQueue = [queue retain];
        void (^block)(void) = ^{ CHZLog(@"StoreServices completion for %@", [item objectForKey:@"title"]); [heldQueue release]; };
        ((void(*)(id,SEL,id,id))objc_msgSend)(download, setHandler, nil, block);
    }
    ((void(*)(id,SEL,id))objc_msgSend)(queue, @selector(addDownload:), download);
    CHZLog(@"StoreServices addDownload queued for %@ from %@", [item objectForKey:@"title"], tmpPath);
    for (int i = 0; i < 20; i++) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    [download release]; [queue release]; [meta release];
    if (CHZMusicLibraryHasImportedItem(item)) {
        CHZSetDownloadRecord(item, @"Imported", @"Added to Music library", path);
        CHZLog(@"verified Music library import for %@", [item objectForKey:@"title"]);
    } else {
        CHZSetDownloadRecord(item, @"Importing", @"Music import queued; open Music search to verify", path);
        CHZLog(@"StoreServices queued but Music library row not visible yet for %@", [item objectForKey:@"title"]);
    }
    return YES;
}

static BOOL CHZEnqueueImport(NSDictionary *item) {
    if (![item isKindOfClass:[NSDictionary class]]) return NO;
    NSMutableArray *queue = [NSMutableArray arrayWithContentsOfFile:CHZQueuePath];
    if (!queue) queue = [NSMutableArray array];
    [queue addObject:item];
    BOOL ok = [queue writeToFile:CHZQueuePath atomically:YES];
    CHZLog(@"%@ import queue item: %@", ok ? @"wrote" : @"failed writing", [item objectForKey:@"title"]);
    return ok;
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
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString *path = [item objectForKey:@"path"];
            if (![path length] || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                CHZLog(@"dropping stale missing import item: %@", path);
                continue;
            }
            if (!CHZImportItem(item)) [remaining addObject:item];
        }
        if ([remaining count]) [remaining writeToFile:CHZQueuePath atomically:YES];
        else [[NSFileManager defaultManager] removeItemAtPath:CHZQueuePath error:nil];
    }
    [pool drain];
    CHZBusy = NO;
}

static NSString *CHZSafePathComponent(NSString *value) {
    if (![value length]) return @"Unknown";
    NSMutableString *safe = [NSMutableString stringWithString:value];
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/:\\?%*|\"<>\n\r\t"];
    for (NSUInteger i = 0; i < [safe length]; i++) {
        if ([bad characterIsMember:[safe characterAtIndex:i]]) [safe replaceCharactersInRange:NSMakeRange(i, 1) withString:@"_"];
    }
    return safe;
}

static NSString *CHZStringValue(id obj) {
    if ([obj isKindOfClass:[NSString class]]) return obj;
    if ([obj respondsToSelector:@selector(stringValue)]) return [obj stringValue];
    return @"";
}

static NSArray *CHZArrayFromSubsonicObject(id obj) {
    if ([obj isKindOfClass:[NSArray class]]) return obj;
    if ([obj isKindOfClass:[NSDictionary class]]) return [NSArray arrayWithObject:obj];
    return [NSArray array];
}

static NSArray *CHZDownloadRecords(void) {
    NSArray *items = [NSArray arrayWithContentsOfFile:CHZDownloadsPath];
    if (![items isKindOfClass:[NSArray class]]) return [NSArray array];
    return items;
}

static NSDictionary *CHZDownloadRecordForSongId(NSString *songId) {
    if (![songId length]) return nil;
    for (NSDictionary *record in CHZDownloadRecords()) if ([[record objectForKey:@"id"] isEqualToString:songId]) return record;
    return nil;
}

static BOOL CHZBeginSongDownload(NSString *songId) {
    if (![songId length]) return YES;
    @synchronized([NSFileManager defaultManager]) {
        if (!CHZActiveSongIds) CHZActiveSongIds = [[NSMutableSet alloc] init];
        if ([CHZActiveSongIds containsObject:songId]) return NO;
        [CHZActiveSongIds addObject:songId];
        return YES;
    }
}

static void CHZEndSongDownload(NSString *songId) {
    if (![songId length]) return;
    @synchronized([NSFileManager defaultManager]) { [CHZActiveSongIds removeObject:songId]; }
}

static void CHZSetDownloadRecord(NSDictionary *song, NSString *state, NSString *detail, NSString *path) {
    NSString *songId = CHZStringValue([song objectForKey:@"id"]);
    if (![songId length]) songId = CHZStringValue([song objectForKey:@"path"]);
    if (![songId length]) songId = CHZStringValue([song objectForKey:@"title"]);
    if (![songId length]) return;

    NSMutableArray *records = [NSMutableArray arrayWithArray:CHZDownloadRecords()];
    NSMutableDictionary *record = nil;
    NSUInteger found = NSNotFound;
    for (NSUInteger i = 0; i < [records count]; i++) {
        NSDictionary *candidate = [records objectAtIndex:i];
        if ([[candidate objectForKey:@"id"] isEqualToString:songId]) {
            record = [NSMutableDictionary dictionaryWithDictionary:candidate];
            found = i;
            break;
        }
    }
    if (!record) record = [NSMutableDictionary dictionary];
    [record setObject:songId forKey:@"id"];
    [record setObject:([song objectForKey:@"title"] ?: [song objectForKey:@"name"] ?: songId) forKey:@"title"];
    [record setObject:([song objectForKey:@"artist"] ?: @"Unknown Artist") forKey:@"artist"];
    [record setObject:([song objectForKey:@"album"] ?: @"Navidrome") forKey:@"album"];
    if ([state length]) [record setObject:state forKey:@"state"];
    if ([detail length]) [record setObject:detail forKey:@"detail"];
    if ([path length]) [record setObject:path forKey:@"path"];
    NSString *artwork = [song objectForKey:@"artwork"];
    if ([artwork length]) [record setObject:artwork forKey:@"artwork"];
    [record setObject:[[NSDate date] description] forKey:@"updatedAt"];
    if (found == NSNotFound) [records insertObject:record atIndex:0];
    else [records replaceObjectAtIndex:found withObject:record];
    while ([records count] > 500) [records removeLastObject];
    [records writeToFile:CHZDownloadsPath atomically:YES];
}

static void CHZClearDownloadRecords(void) {
    [[NSFileManager defaultManager] removeItemAtPath:CHZDownloadsPath error:nil];
}

static NSArray *CHZRecentDownloadRecords(void) {
    NSMutableArray *recent = [NSMutableArray array];
    for (NSDictionary *record in CHZDownloadRecords()) {
        NSString *state = [record objectForKey:@"state"];
        if ([state isEqualToString:@"Downloaded"] || [state isEqualToString:@"Imported"]) [recent addObject:record];
        if ([recent count] >= 100) break;
    }
    return recent;
}

static void CHZRecordPlaylistRequest(NSString *playlistName, NSArray *songs) {
    if (![playlistName length]) return;
    NSMutableArray *requests = [NSMutableArray arrayWithContentsOfFile:CHZPlaylistRequestsPath];
    if (!requests) requests = [NSMutableArray array];
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *song in songs) {
        NSString *sid = CHZStringValue([song objectForKey:@"id"]);
        if ([sid length]) [ids addObject:sid];
    }
    NSDictionary *request = [NSDictionary dictionaryWithObjectsAndKeys:playlistName, @"name", ids, @"songIds", [[NSDate date] description], @"createdAt", nil];
    [requests insertObject:request atIndex:0];
    while ([requests count] > 50) [requests removeLastObject];
    [requests writeToFile:CHZPlaylistRequestsPath atomically:YES];
    CHZLog(@"recorded playlist request %@ with %u songs", playlistName, [ids count]);
}

static NSDictionary *CHZPrefs(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:CHZPrefsPath];
    if (![prefs isKindOfClass:[NSDictionary class]]) prefs = [NSDictionary dictionary];
    return prefs;
}

static NSString *CHZBaseURL(NSDictionary *prefs) {
    NSString *server = [prefs objectForKey:@"server"];
    if (![server length]) server = [prefs objectForKey:@"url"];
    if (![server length]) server = @"https://nav.personaltechwiz.com";
    while ([server hasSuffix:@"/"]) server = [server substringToIndex:[server length] - 1];
    return server;
}

static NSURL *CHZSubsonicURL(NSString *method, NSDictionary *params) {
    NSDictionary *prefs = CHZPrefs();
    NSString *base = CHZBaseURL(prefs);
    NSString *user = [prefs objectForKey:@"username"];
    if (![user length]) user = [prefs objectForKey:@"user"];
    NSString *password = [prefs objectForKey:@"password"];
    NSString *token = [prefs objectForKey:@"token"];
    NSString *salt = [prefs objectForKey:@"salt"];
    if (![user length] || ((![password length]) && (![token length] || ![salt length]))) return nil;

    NSMutableArray *parts = [NSMutableArray array];
#define ADD_PARAM(k, v) do { NSString *_v = CHZStringValue((v)); if ([_v length]) [parts addObject:[NSString stringWithFormat:@"%@=%@", (k), [_v stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]]]; } while(0)
    ADD_PARAM(@"u", user);
    if ([token length] && [salt length]) { ADD_PARAM(@"t", token); ADD_PARAM(@"s", salt); }
    else ADD_PARAM(@"p", password);
    ADD_PARAM(@"v", @"1.16.1");
    ADD_PARAM(@"c", @"CH33ZENavTunes");
    ADD_PARAM(@"f", @"json");
    for (NSString *key in params) ADD_PARAM(key, [params objectForKey:key]);
#undef ADD_PARAM
    NSString *url = [NSString stringWithFormat:@"%@/rest/%@.view?%@", base, method, [parts componentsJoinedByString:@"&"]];
    return [NSURL URLWithString:url];
}

static id CHZResponsePayload(NSData *data, NSError **outError) {
    if (![data length]) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:outError];
    NSDictionary *root = [json isKindOfClass:[NSDictionary class]] ? [json objectForKey:@"subsonic-response"] : nil;
    NSString *status = [root objectForKey:@"status"];
    if (root && (!status || [status isEqualToString:@"ok"])) return root;
    if (outError && root) {
        NSDictionary *err = [root objectForKey:@"error"];
        NSString *msg = [err objectForKey:@"message"] ?: @"Navidrome API error";
        *outError = [NSError errorWithDomain:@"CH33ZENavTunes" code:[[err objectForKey:@"code"] intValue] userInfo:[NSDictionary dictionaryWithObject:msg forKey:NSLocalizedDescriptionKey]];
    }
    return nil;
}

@interface CHZProgressDownload : NSObject {
    NSMutableData *_data;
    NSDictionary *_song;
    BOOL _done;
    NSError *_error;
    long long _expected;
    long long _received;
    NSDate *_start;
}
@property(nonatomic, readonly) BOOL done;
@property(nonatomic, retain) NSError *error;
@property(nonatomic, readonly) NSData *data;
- (id)initWithSong:(NSDictionary *)song;
@end

@implementation CHZProgressDownload
@synthesize done = _done;
@synthesize error = _error;
- (id)initWithSong:(NSDictionary *)song { self = [super init]; if (self) { _song = [song retain]; _data = [[NSMutableData alloc] init]; _expected = 0; _received = 0; _start = [[NSDate date] retain]; } return self; }
- (void)dealloc { [_data release]; [_song release]; [_error release]; [_start release]; [super dealloc]; }
- (NSData *)data { return _data; }
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response { _expected = [response expectedContentLength]; if (_expected < 0) _expected = 0; _received = 0; [_data setLength:0]; CHZSetDownloadRecord(_song, @"Downloading", _expected > 0 ? @"0% · starting" : @"starting", nil); }
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data { [_data appendData:data]; _received += [data length]; NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:_start]; double speed = elapsed > 0 ? ((double)_received / elapsed / 1024.0) : 0; NSString *detail = nil; if (_expected > 0) detail = [NSString stringWithFormat:@"%lld%% · %.1f KB/s", (long long)((_received * 100) / _expected), speed]; else detail = [NSString stringWithFormat:@"%.1f MB · %.1f KB/s", ((double)_received / 1048576.0), speed]; CHZSetDownloadRecord(_song, @"Downloading", detail, nil); }
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error { self.error = error; _done = YES; }
- (void)connectionDidFinishLoading:(NSURLConnection *)connection { _done = YES; }
@end

static NSData *CHZDownloadDataWithProgress(NSURL *url, NSDictionary *song, NSError **outError) {
    NSURLRequest *req = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:300.0];
    CHZProgressDownload *delegate = [[CHZProgressDownload alloc] initWithSong:song];
    NSURLConnection *conn = [[[NSURLConnection alloc] initWithRequest:req delegate:delegate startImmediately:YES] autorelease];
    if (!conn) { if (outError) *outError = [NSError errorWithDomain:@"CH33ZENavTunes" code:503 userInfo:[NSDictionary dictionaryWithObject:@"Could not start download" forKey:NSLocalizedDescriptionKey]]; [delegate release]; return nil; }
    while (![delegate done]) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
    if ([delegate error]) { if (outError) *outError = [delegate error]; [delegate release]; return nil; }
    NSData *data = [[delegate data] retain];
    [delegate release];
    return [data autorelease];
}

static NSString *CHZDownloadCoverArt(NSDictionary *song, NSString *dir) {
    NSString *coverId = CHZStringValue([song objectForKey:@"coverArt"]);
    if (![coverId length]) return nil;
    NSURL *url = CHZSubsonicURL(@"getCoverArt", [NSDictionary dictionaryWithObject:coverId forKey:@"id"]);
    if (!url) return nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:[NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60.0] returningResponse:nil error:nil];
    if (![data length]) return nil;
    NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"cover-%@.jpg", CHZSafePathComponent(coverId)]];
    if ([data writeToFile:path atomically:YES]) return path;
    return nil;
}

static id CHZFetchSubsonic(NSString *method, NSDictionary *params, NSError **error) {
    NSURL *url = CHZSubsonicURL(method, params);
    if (!url) {
        if (error) *error = [NSError errorWithDomain:@"CH33ZENavTunes" code:401 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"Configure %@ with server, username, and password or token/salt.", CHZPrefsPath] forKey:NSLocalizedDescriptionKey]];
        return nil;
    }
    NSURLRequest *req = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:45.0];
    NSURLResponse *resp = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:error];
    return CHZResponsePayload(data, error);
}

static BOOL CHZDownloadAndImportSong(NSDictionary *song, NSError **outError) {
    NSString *songId = CHZStringValue([song objectForKey:@"id"]);
    if (!CHZBeginSongDownload(songId)) {
        CHZSetDownloadRecord(song, @"Skipped", @"Already downloading", nil);
        return YES;
    }
    NSDictionary *existing = CHZDownloadRecordForSongId(songId);
    NSString *existingPath = [existing objectForKey:@"path"];
    NSString *existingState = [existing objectForKey:@"state"];
    if (([existingState isEqualToString:@"Downloaded"] || [existingState isEqualToString:@"Imported"]) && [existingPath length] && [[[existingPath pathExtension] lowercaseString] isEqualToString:@"mp3"] && [[NSFileManager defaultManager] fileExistsAtPath:existingPath]) {
        CHZSetDownloadRecord(song, @"Skipped", @"Already downloaded", existingPath);
        CHZEndSongDownload(songId);
        return YES;
    }
    CHZSetDownloadRecord(song, @"Queued", @"Preparing MP3 download", nil);
    NSDictionary *streamParams = [NSDictionary dictionaryWithObjectsAndKeys:songId, @"id", @"mp3", @"format", @"320", @"maxBitRate", nil];
    NSURL *url = CHZSubsonicURL(@"stream", streamParams);
    if (!url) {
        if (outError) *outError = [NSError errorWithDomain:@"CH33ZENavTunes" code:401 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"Configure %@ before downloading.", CHZPrefsPath] forKey:NSLocalizedDescriptionKey]];
        CHZEndSongDownload(songId);
        return NO;
    }

    NSError *error = nil;
    CHZSetDownloadRecord(song, @"Downloading", @"Fetching audio from Navidrome", nil);
    NSData *data = CHZDownloadDataWithProgress(url, song, &error);
    if (![data length] || error) {
        if (outError) *outError = error ?: [NSError errorWithDomain:@"CH33ZENavTunes" code:502 userInfo:[NSDictionary dictionaryWithObject:@"No audio data returned by Navidrome stream." forKey:NSLocalizedDescriptionKey]];
        CHZSetDownloadRecord(song, @"Failed", error ? [error localizedDescription] : @"No audio data returned", nil);
        CHZEndSongDownload(songId);
        return NO;
    }

    NSString *artist = [song objectForKey:@"artist"] ?: @"Unknown Artist";
    NSString *album = [song objectForKey:@"album"] ?: @"Navidrome";
    NSString *title = [song objectForKey:@"title"] ?: [song objectForKey:@"name"] ?: songId;
    NSString *suffix = @"mp3";
    NSString *dir = [[CHZDownloadRoot stringByAppendingPathComponent:CHZSafePathComponent(artist)] stringByAppendingPathComponent:CHZSafePathComponent(album)];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *artworkPath = CHZDownloadCoverArt(song, dir);
    NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", CHZSafePathComponent(title), suffix]];
    if (![data writeToFile:path atomically:YES]) {
        if (outError) *outError = [NSError errorWithDomain:@"CH33ZENavTunes" code:500 userInfo:[NSDictionary dictionaryWithObject:@"Could not save downloaded track" forKey:NSLocalizedDescriptionKey]];
        CHZSetDownloadRecord(song, @"Failed", @"Could not save downloaded track", path);
        CHZEndSongDownload(songId);
        return NO;
    }

    NSMutableDictionary *import = [NSMutableDictionary dictionaryWithObjectsAndKeys:path, @"path", title, @"title", artist, @"artist", album, @"album", @"song", @"kind", nil];
    if ([songId length]) [import setObject:songId forKey:@"id"];
    if ([song objectForKey:@"genre"]) [import setObject:[song objectForKey:@"genre"] forKey:@"genre"];
    if ([song objectForKey:@"duration"]) [import setObject:[NSNumber numberWithInt:[[song objectForKey:@"duration"] intValue] * 1000] forKey:@"duration"];
    if ([song objectForKey:@"year"]) [import setObject:[song objectForKey:@"year"] forKey:@"year"];
    if ([song objectForKey:@"track"]) [import setObject:[song objectForKey:@"track"] forKey:@"track"];
    if ([song objectForKey:@"discNumber"]) [import setObject:[song objectForKey:@"discNumber"] forKey:@"discNumber"];
    if ([song objectForKey:@"playlist"]) [import setObject:[song objectForKey:@"playlist"] forKey:@"playlist"];
    if ([artworkPath length]) [import setObject:artworkPath forKey:@"artwork"];
    CHZEnqueueImport(import);
    CHZSetDownloadRecord(import, @"Downloaded", @"Saved MP3; tap here to play in NavTunes", path);
    CHZLog(@"downloaded Navidrome track to %@", path);
    CHZProcessQueue();
    CHZEndSongDownload(songId);
    return YES;
}


static BOOL CHZPlayLocalPath(NSString *path) {
    if (![path length] || ![[NSFileManager defaultManager] fileExistsAtPath:path]) { CHZLog(@"play missing file: %@", path); return NO; }
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if ([session respondsToSelector:@selector(setCategory:error:)]) {
        NSError *sessionError = nil;
        [session setCategory:AVAudioSessionCategoryPlayback error:&sessionError];
        if (sessionError) CHZLog(@"audio session category warning: %@", [sessionError localizedDescription]);
    }
    if ([session respondsToSelector:@selector(setActive:error:)]) {
        NSError *activeError = nil;
        [session setActive:YES error:&activeError];
        if (activeError) CHZLog(@"audio session active warning: %@", [activeError localizedDescription]);
    }
    if (CHZAudioPlayer) { [CHZAudioPlayer stop]; [CHZAudioPlayer release]; CHZAudioPlayer = nil; }
    NSURL *url = [NSURL fileURLWithPath:path];
    CHZAudioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&error];
    if (!CHZAudioPlayer || error) { CHZLog(@"play failed for %@: %@", path, [error localizedDescription]); [CHZAudioPlayer release]; CHZAudioPlayer = nil; return NO; }
    CHZAudioPlayer.volume = 1.0;
    [CHZAudioPlayer prepareToPlay];
    BOOL ok = [CHZAudioPlayer play];
    CHZLog(@"play %@ -> %@ duration=%.2f volume=%.2f", path, ok ? @"ok" : @"failed", [CHZAudioPlayer duration], CHZAudioPlayer.volume);
    return ok;
}

typedef enum { CHZNavLevelHome = 0, CHZNavLevelArtists = 1, CHZNavLevelAlbums = 2, CHZNavLevelSongs = 3, CHZNavLevelPlaylistSongs = 4, CHZNavLevelSearch = 5, CHZNavLevelDownloads = 6, CHZNavLevelRecent = 7 } CHZNavLevel;

@interface CHZNavidromeViewController : UITableViewController <UIAlertViewDelegate> {
    CHZNavLevel _level;
    NSString *_parentId;
    NSString *_parentTitle;
    NSString *_searchQuery;
    NSTimer *_autoRefreshTimer;
    NSArray *_items;
    NSString *_status;
    BOOL _loading;
}
- (id)initWithLevel:(CHZNavLevel)level parentId:(NSString *)parentId title:(NSString *)title;
@end

@implementation CHZNavidromeViewController
- (id)initWithLevel:(CHZNavLevel)level parentId:(NSString *)parentId title:(NSString *)title {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _level = level;
        _parentId = [parentId copy];
        _parentTitle = [title copy];
        _items = [[NSArray alloc] init];
        _status = [@"Loading…" retain];
        self.title = title ?: @"Navidrome";
        self.tabBarItem = [[[UITabBarItem alloc] initWithTitle:@"Navidrome" image:nil tag:61333] autorelease];
    }
    return self;
}
- (void)dealloc { [_autoRefreshTimer invalidate]; [_parentId release]; [_parentTitle release]; [_searchQuery release]; [_items release]; [_status release]; [super dealloc]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    if (_level == CHZNavLevelSearch) self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:@"Search" style:UIBarButtonItemStyleBordered target:self action:@selector(showSearchPrompt)] autorelease];
    else if (_level == CHZNavLevelDownloads) self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStyleBordered target:self action:@selector(clearDownloads)] autorelease];
    else self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refresh)] autorelease];
    [self refresh];
    if (_level == CHZNavLevelDownloads || _level == CHZNavLevelRecent) _autoRefreshTimer = [[NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(refreshLocalStatus) userInfo:nil repeats:YES] retain];
    if (_level == CHZNavLevelSearch) [self showSearchPrompt];
}
- (void)refreshLocalStatus {
    if (_level == CHZNavLevelDownloads) [self setItemsOnMain:CHZDownloadRecords() status:[NSString stringWithFormat:@"%u item%@", [CHZDownloadRecords() count], [CHZDownloadRecords() count] == 1 ? @"" : @"s"]];
    else if (_level == CHZNavLevelRecent) [self setItemsOnMain:CHZRecentDownloadRecords() status:[NSString stringWithFormat:@"%u recent", [CHZRecentDownloadRecords() count]]];
}
- (void)showSearchPrompt { UIAlertView *alert = [[[UIAlertView alloc] initWithTitle:@"Search Navidrome" message:@"Enter song, artist, or album" delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Search", nil] autorelease]; alert.alertViewStyle = UIAlertViewStylePlainTextInput; [[alert textFieldAtIndex:0] setText:_searchQuery ?: @""]; [alert show]; }
- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex { if (buttonIndex != [alertView cancelButtonIndex]) { [_searchQuery release]; _searchQuery = [[alertView textFieldAtIndex:0].text copy]; [self refresh]; } }
- (void)clearDownloads { CHZClearDownloadRecords(); [self refresh]; }
- (void)setStatus:(NSString *)status { [_status release]; _status = [status copy]; }
- (void)setItemsOnMain:(NSArray *)items status:(NSString *)status { [_items release]; _items = [items retain]; [self setStatus:status]; _loading = NO; [[self tableView] reloadData]; }
- (void)setErrorOnMain:(NSError *)error { NSString *msg = [error localizedDescription] ?: @"Load failed"; [self setItemsOnMain:[NSArray array] status:msg]; CHZLog(@"Navidrome UI error: %@", msg); }
- (void)refresh { if (_loading) return; _loading = YES; [self setStatus:@"Loading…"]; [[self tableView] reloadData]; [NSThread detachNewThreadSelector:@selector(loadThread) toTarget:self withObject:nil]; }
- (void)loadThread {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSError *error = nil;
    NSMutableArray *results = [NSMutableArray array];
    if (_level == CHZNavLevelHome) {
        NSDictionary *root = CHZFetchSubsonic(@"getPlaylists", [NSDictionary dictionary], &error);
        NSDictionary *playlists = [root objectForKey:@"playlists"];
        for (NSDictionary *playlist in CHZArrayFromSubsonicObject([playlists objectForKey:@"playlist"])) if ([playlist isKindOfClass:[NSDictionary class]]) [results addObject:playlist];
    } else if (_level == CHZNavLevelDownloads) {
        [results addObjectsFromArray:CHZDownloadRecords()];
    } else if (_level == CHZNavLevelRecent) {
        [results addObjectsFromArray:CHZRecentDownloadRecords()];
    } else if (_level == CHZNavLevelSearch) {
        if (![_searchQuery length]) {
            [self performSelectorOnMainThread:@selector(setItemsAndStatus:) withObject:[NSDictionary dictionaryWithObjectsAndKeys:results, @"items", @"Tap Search to find songs", @"status", nil] waitUntilDone:NO];
            [pool drain];
            return;
        }
        NSDictionary *root = CHZFetchSubsonic(@"search3", [NSDictionary dictionaryWithObjectsAndKeys:_searchQuery, @"query", @"50", @"songCount", @"0", @"artistCount", @"0", @"albumCount", nil], &error);
        NSDictionary *search = [root objectForKey:@"searchResult3"];
        for (NSDictionary *song in CHZArrayFromSubsonicObject([search objectForKey:@"song"])) if ([song isKindOfClass:[NSDictionary class]]) [results addObject:song];
    } else if (_level == CHZNavLevelArtists) {
        NSDictionary *root = CHZFetchSubsonic(@"getArtists", [NSDictionary dictionary], &error);
        NSDictionary *artists = [root objectForKey:@"artists"];
        for (NSDictionary *idx in CHZArrayFromSubsonicObject([artists objectForKey:@"index"])) for (NSDictionary *artist in CHZArrayFromSubsonicObject([idx objectForKey:@"artist"])) if ([artist isKindOfClass:[NSDictionary class]]) [results addObject:artist];
    } else if (_level == CHZNavLevelAlbums) {
        NSDictionary *root = CHZFetchSubsonic(@"getArtist", [NSDictionary dictionaryWithObject:_parentId ?: @"" forKey:@"id"], &error);
        NSDictionary *artist = [root objectForKey:@"artist"];
        for (NSDictionary *album in CHZArrayFromSubsonicObject([artist objectForKey:@"album"])) if ([album isKindOfClass:[NSDictionary class]]) [results addObject:album];
    } else if (_level == CHZNavLevelSongs) {
        NSDictionary *root = CHZFetchSubsonic(@"getAlbum", [NSDictionary dictionaryWithObject:_parentId ?: @"" forKey:@"id"], &error);
        NSDictionary *album = [root objectForKey:@"album"];
        for (NSDictionary *song in CHZArrayFromSubsonicObject([album objectForKey:@"song"])) if ([song isKindOfClass:[NSDictionary class]]) [results addObject:song];
    } else {
        NSDictionary *root = CHZFetchSubsonic(@"getPlaylist", [NSDictionary dictionaryWithObject:_parentId ?: @"" forKey:@"id"], &error);
        NSDictionary *playlist = [root objectForKey:@"playlist"];
        for (NSDictionary *song in CHZArrayFromSubsonicObject([playlist objectForKey:@"entry"])) if ([song isKindOfClass:[NSDictionary class]]) [results addObject:song];
    }
    if (error) [self performSelectorOnMainThread:@selector(setErrorOnMain:) withObject:error waitUntilDone:NO];
    else {
        NSString *status = [NSString stringWithFormat:@"%u item%@", [results count], [results count] == 1 ? @"" : @"s"];
        [self performSelectorOnMainThread:@selector(setItemsAndStatus:) withObject:[NSDictionary dictionaryWithObjectsAndKeys:results, @"items", status, @"status", nil] waitUntilDone:NO];
    }
    [pool drain];
}
- (void)setItemsAndStatus:(NSDictionary *)payload { [self setItemsOnMain:[payload objectForKey:@"items"] status:[payload objectForKey:@"status"]]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _level == CHZNavLevelHome ? 5 : 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_level == CHZNavLevelHome) return section < 4 ? 1 : MAX((NSInteger)[_items count], 1);
    return MAX((NSInteger)[_items count], 1);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (_level == CHZNavLevelHome) { if (section == 0) return @"All Music"; if (section == 1) return @"Search"; if (section == 2) return @"Downloads"; if (section == 3) return @"Recently Downloaded"; return [NSString stringWithFormat:@"Playlists — %@", _status]; }
    return _status;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *ident = (_level == CHZNavLevelSongs || _level == CHZNavLevelPlaylistSongs || _level == CHZNavLevelSearch) ? @"song" : @"nav";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ident];
    if (!cell) cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:ident] autorelease];
    if (_level == CHZNavLevelHome && [indexPath section] < 4) {
        if ([indexPath section] == 0) { cell.textLabel.text = @"All Music"; cell.detailTextLabel.text = @"Browse Artists, Albums, and Songs"; }
        else if ([indexPath section] == 1) { cell.textLabel.text = @"Search Navidrome"; cell.detailTextLabel.text = @"Find songs by title, artist, or album"; }
        else if ([indexPath section] == 2) { cell.textLabel.text = @"Downloads"; cell.detailTextLabel.text = @"View speed, progress, and import status"; }
        else { cell.textLabel.text = @"Recently Downloaded"; cell.detailTextLabel.text = @"Latest completed Navidrome imports"; }
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        return cell;
    }
    if ([_items count] == 0) {
        cell.textLabel.text = _loading ? @"Loading Navidrome…" : (_level == CHZNavLevelHome ? @"No playlists" : @"No items");
        cell.detailTextLabel.text = [_status length] ? _status : [NSString stringWithFormat:@"Configure %@", CHZPrefsPath];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *item = [_items objectAtIndex:[indexPath row]];
    cell.textLabel.text = [item objectForKey:@"name"] ?: [item objectForKey:@"title"] ?: @"Untitled";
    cell.imageView.image = nil;
    NSString *artPath = [item objectForKey:@"artwork"];
    if ([artPath length] && [[NSFileManager defaultManager] fileExistsAtPath:artPath]) cell.imageView.image = [UIImage imageWithContentsOfFile:artPath];
    if (_level == CHZNavLevelDownloads || _level == CHZNavLevelRecent) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ — %@", [item objectForKey:@"state"] ?: @"Status", [item objectForKey:@"detail"] ?: ([item objectForKey:@"artist"] ?: @"")];
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    } else if (_level == CHZNavLevelSongs || _level == CHZNavLevelPlaylistSongs || _level == CHZNavLevelSearch) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ — %@", [item objectForKey:@"artist"] ?: _parentTitle ?: @"Unknown Artist", [item objectForKey:@"album"] ?: @"Navidrome"];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        NSDictionary *record = CHZDownloadRecordForSongId(CHZStringValue([item objectForKey:@"id"]));
        NSString *path = [record objectForKey:@"path"];
        BOOL playable = [path length] && [[NSFileManager defaultManager] fileExistsAtPath:path];
        [button setTitle:(playable ? @"Play" : @"Download") forState:UIControlStateNormal];
        button.frame = CGRectMake(0, 0, 96, 32);
        button.tag = [indexPath row];
        [button addTarget:self action:@selector(downloadButton:) forControlEvents:UIControlEventTouchUpInside];
        cell.accessoryView = button;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        NSString *count = CHZStringValue([item objectForKey:_level == CHZNavLevelArtists ? @"albumCount" : @"songCount"]);
        cell.detailTextLabel.text = [count length] ? [NSString stringWithFormat:@"%@ %@", count, _level == CHZNavLevelArtists ? @"albums" : @"songs"] : (_level == CHZNavLevelHome ? @"Playlist" : @"");
        if (_level == CHZNavLevelHome) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeRoundedRect];
            [button setTitle:@"Download" forState:UIControlStateNormal];
            button.frame = CGRectMake(0, 0, 96, 32);
            button.tag = [indexPath row];
            [button addTarget:self action:@selector(downloadPlaylistButton:) forControlEvents:UIControlEventTouchUpInside];
            cell.accessoryView = button;
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else {
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_level == CHZNavLevelHome && [indexPath section] < 4) {
        CHZNavLevel next = CHZNavLevelArtists;
        NSString *title = @"All Music";
        if ([indexPath section] == 1) { next = CHZNavLevelSearch; title = @"Search"; }
        else if ([indexPath section] == 2) { next = CHZNavLevelDownloads; title = @"Downloads"; }
        else if ([indexPath section] == 3) { next = CHZNavLevelRecent; title = @"Recent"; }
        CHZNavidromeViewController *vc = [[CHZNavidromeViewController alloc] initWithLevel:next parentId:nil title:title];
        [[self navigationController] pushViewController:vc animated:YES];
        [vc release];
        return;
    }
    if ([_items count] == 0) return;
    NSDictionary *item = [_items objectAtIndex:[indexPath row]];
    if (_level == CHZNavLevelDownloads || _level == CHZNavLevelRecent) {
        NSString *path = [item objectForKey:@"path"];
        if (CHZPlayLocalPath(path)) [self setStatus:[NSString stringWithFormat:@"Playing %@", [item objectForKey:@"title"] ?: @"download"]];
        else [self setStatus:@"Could not play file; re-download as MP3"];
        [[self tableView] reloadData];
        return;
    }
    if (_level == CHZNavLevelSongs || _level == CHZNavLevelPlaylistSongs || _level == CHZNavLevelSearch) return;
    NSString *itemId = CHZStringValue([item objectForKey:@"id"]);
    NSString *name = [item objectForKey:@"name"] ?: @"Navidrome";
    CHZNavLevel nextLevel = CHZNavLevelPlaylistSongs;
    if (_level == CHZNavLevelArtists) nextLevel = CHZNavLevelAlbums;
    else if (_level == CHZNavLevelAlbums) nextLevel = CHZNavLevelSongs;
    CHZNavidromeViewController *vc = [[CHZNavidromeViewController alloc] initWithLevel:nextLevel parentId:itemId title:name];
    [[self navigationController] pushViewController:vc animated:YES];
    [vc release];
}
- (void)downloadButton:(UIButton *)button {
    if (button.tag < 0 || button.tag >= (NSInteger)[_items count]) return;
    NSDictionary *song = [_items objectAtIndex:button.tag];
    NSDictionary *record = CHZDownloadRecordForSongId(CHZStringValue([song objectForKey:@"id"]));
    NSString *path = [record objectForKey:@"path"];
    if ([path length] && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (CHZPlayLocalPath(path)) [self setStatus:[NSString stringWithFormat:@"Playing %@", [song objectForKey:@"title"] ?: @"download"]];
        else [self setStatus:@"Could not play file; re-download as MP3"];
        [[self tableView] reloadData];
        return;
    }
    [button setTitle:@"Queued" forState:UIControlStateNormal];
    [NSThread detachNewThreadSelector:@selector(downloadSongThread:) toTarget:self withObject:song];
}
- (void)downloadPlaylistButton:(UIButton *)button {
    if (button.tag < 0 || button.tag >= (NSInteger)[_items count]) return;
    NSDictionary *playlist = [_items objectAtIndex:button.tag];
    [button setTitle:@"Queued" forState:UIControlStateNormal];
    [NSThread detachNewThreadSelector:@selector(downloadPlaylistThread:) toTarget:self withObject:playlist];
}
- (void)downloadSongThread:(NSDictionary *)song {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSError *error = nil;
    CHZDownloadAndImportSong(song, &error);
    if (error) CHZLog(@"download failed: %@", [error localizedDescription]);
    [pool drain];
}

// Historical direct MediaLibrary.sqlitedb write path retained only as reference while
// debugging corrupt stock Music libraries. It is compiled out so this safe build cannot
// modify Apple's private library database or playlist tables.
#if 0
static long long CHZSQLiteScalarInt64(sqlite3 *db, NSString *sql, NSArray *args) {
    sqlite3_stmt *stmt = NULL;
    long long value = 0;
    if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &stmt, NULL) != SQLITE_OK) return 0;
    for (NSUInteger i = 0; i < [args count]; i++) sqlite3_bind_text(stmt, (int)i + 1, [[args objectAtIndex:i] UTF8String], -1, SQLITE_TRANSIENT);
    if (sqlite3_step(stmt) == SQLITE_ROW) value = sqlite3_column_int64(stmt, 0);
    sqlite3_finalize(stmt);
    return value;
}


static NSString *CHZSQLQuote(NSString *s) {
    if (!s) s = @"";
    return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
}


static int CHZSectionForString(NSString *s) {
    if (![s length]) return 0;
    unichar c = [[s uppercaseString] characterAtIndex:0];
    if (c >= 'A' && c <= 'Z') return (int)(c - 'A' + 1);
    return 0;
}

static long long CHZOrderKeyForString(NSString *s) {
    if (![s length]) return 0;
    NSString *u = [s uppercaseString];
    unsigned long long h = 1469598103934665603ULL;
    for (NSUInteger i = 0; i < [u length]; i++) { h ^= [u characterAtIndex:i]; h *= 1099511628211ULL; }
    h &= 0x7fffffffffffffffULL;
    if (h < 1000000ULL) h += 1000000ULL;
    return (long long)h;
}

static long long CHZExistingOrder(sqlite3 *db, NSString *column, NSString *table, NSString *whereColumn, NSString *value) {
    if (![value length]) return 0;
    NSString *sql = [NSString stringWithFormat:@"select i.%@ from item i join %@ t on i.%@=t.%@ where t.%@=? and i.%@>0 limit 1", column, table, [table isEqualToString:@"album"] ? @"album_pid" : ([table isEqualToString:@"album_artist"] ? @"album_artist_pid" : @"item_artist_pid"), [table isEqualToString:@"album"] ? @"album_pid" : ([table isEqualToString:@"album_artist"] ? @"album_artist_pid" : @"item_artist_pid"), whereColumn, column];
    return CHZSQLiteScalarInt64(db, sql, [NSArray arrayWithObject:value]);
}

static long long CHZRandomPID(void) {
    long long pid = (((long long)arc4random()) << 32) ^ (long long)arc4random();
    if (pid == 0) pid = 1;
    return pid;
}

static long long CHZGetOrCreateArtist(sqlite3 *db, NSString *artist) {
    if (![artist length]) artist = @"Unknown Artist";
    sqlite3_stmt *stmt = NULL;
    long long pid = 0;
    if (sqlite3_prepare_v2(db, "select item_artist_pid from item_artist where item_artist=? limit 1", -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, [artist UTF8String], -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) pid = sqlite3_column_int64(stmt, 0);
    }
    sqlite3_finalize(stmt);
    if (pid) return pid;
    pid = CHZRandomPID();
    NSString *sql = [NSString stringWithFormat:@"insert into item_artist (item_artist_pid,item_artist,sort_item_artist,series_name,sort_series_name,cloud_status,representative_item_pid) values (%lld,%@,%@,'','',0,0)", pid, CHZSQLQuote(artist), CHZSQLQuote(artist)];
    CHZExecSQL(db, sql);
    return pid;
}

static long long CHZGetOrCreateAlbumArtist(sqlite3 *db, NSString *artist) {
    if (![artist length]) artist = @"Unknown Artist";
    sqlite3_stmt *stmt = NULL;
    long long pid = 0;
    if (sqlite3_prepare_v2(db, "select album_artist_pid from album_artist where album_artist=? limit 1", -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, [artist UTF8String], -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) pid = sqlite3_column_int64(stmt, 0);
    }
    sqlite3_finalize(stmt);
    if (pid) return pid;
    pid = CHZRandomPID();
    NSString *sql = [NSString stringWithFormat:@"insert into album_artist (album_artist_pid,album_artist,sort_album_artist,cloud_status,representative_item_pid) values (%lld,%@,%@,0,0)", pid, CHZSQLQuote(artist), CHZSQLQuote(artist)];
    CHZExecSQL(db, sql);
    return pid;
}

static long long CHZGetOrCreateGenre(sqlite3 *db, NSString *genre) {
    if (![genre length]) genre = @"Music";
    sqlite3_stmt *stmt = NULL;
    long long gid = 0;
    if (sqlite3_prepare_v2(db, "select genre_id from genre where genre=? limit 1", -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, [genre UTF8String], -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) gid = sqlite3_column_int64(stmt, 0);
    }
    sqlite3_finalize(stmt);
    if (gid) return gid;
    gid = CHZRandomPID();
    NSString *sql = [NSString stringWithFormat:@"insert into genre (genre_id,genre,cloud_status,representative_item_pid) values (%lld,%@,0,0)", gid, CHZSQLQuote(genre)];
    CHZExecSQL(db, sql);
    return gid;
}

static long long CHZGetOrCreateAlbum(sqlite3 *db, NSString *album, long long albumArtistPid) {
    if (![album length]) album = @"Navidrome";
    sqlite3_stmt *stmt = NULL;
    long long pid = 0;
    if (sqlite3_prepare_v2(db, "select album_pid from album where album=? and album_artist_pid=? limit 1", -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, [album UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, 2, albumArtistPid);
        if (sqlite3_step(stmt) == SQLITE_ROW) pid = sqlite3_column_int64(stmt, 0);
    }
    sqlite3_finalize(stmt);
    if (pid) return pid;
    pid = CHZRandomPID();
    NSString *sql = [NSString stringWithFormat:@"insert into album (album_pid,album,sort_album,album_artist_pid,representative_item_pid,cloud_status,artwork_cache_id,user_rating,all_compilations) values (%lld,%@,%@,%lld,0,0,%lld,0,0)", pid, CHZSQLQuote(album), CHZSQLQuote(album), albumArtistPid, pid];
    CHZExecSQL(db, sql);
    return pid;
}

static BOOL CHZDirectImportItem(NSDictionary *item) {
    NSString *srcPath = [item objectForKey:@"path"];
    if (![srcPath length] || ![[NSFileManager defaultManager] fileExistsAtPath:srcPath]) { CHZLog(@"direct import missing file: %@", srcPath); return NO; }
    NSString *dbPath = @"/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb";
    NSString *bakPath = @"/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb.navtunes-direct.bak";
    if (![[NSFileManager defaultManager] fileExistsAtPath:bakPath]) [[NSFileManager defaultManager] copyItemAtPath:dbPath toPath:bakPath error:nil];

    sqlite3 *db = NULL;
    if (sqlite3_open([dbPath UTF8String], &db) != SQLITE_OK) { CHZLog(@"direct import could not open db"); return NO; }
    sqlite3_busy_timeout(db, 5000);

    NSString *title = [item objectForKey:@"title"] ?: [[srcPath lastPathComponent] stringByDeletingPathExtension];
    NSString *artist = [item objectForKey:@"artist"] ?: @"Unknown Artist";
    NSString *album = [item objectForKey:@"album"] ?: @"Navidrome";
    NSString *genre = [item objectForKey:@"genre"] ?: @"Music";
    long long existing = CHZSQLiteScalarInt64(db, @"select i.item_pid from item i join item_extra e on i.item_pid=e.item_pid left join album al on i.album_pid=al.album_pid left join item_artist ar on i.item_artist_pid=ar.item_artist_pid where e.title=? and al.album=? and ar.item_artist=? and e.location like '%.mp3' limit 1", [NSArray arrayWithObjects:title, album, artist, nil]);
    if (existing) { sqlite3_close(db); CHZLog(@"direct import skipped existing item %@", title); return YES; }

    NSArray *folders = [NSArray arrayWithObjects:@"F00",@"F01",@"F02",@"F03",@"F04",@"F05",@"F06",@"F07",@"F08",@"F09",@"F10",@"F11",@"F12",@"F13",@"F14",@"F15",@"F16",@"F17",@"F18",@"F19",@"F20",@"F21",@"F22",@"F23",@"F24",@"F25",@"F26",@"F27",@"F28",@"F29",@"F30",@"F31",@"F32",@"F33",@"F34",@"F35",@"F36",@"F37",@"F38",@"F39",@"F40",@"F41",@"F42",@"F43",@"F44",@"F45",@"F46",@"F47",@"F48",@"F49", nil];
    NSString *folder = [folders objectAtIndex:(arc4random() % [folders count])];
    NSString *baseRel = [@"iTunes_Control/Music" stringByAppendingPathComponent:folder];
    NSString *baseAbs = [@"/var/mobile/Media" stringByAppendingPathComponent:baseRel];
    [[NSFileManager defaultManager] createDirectoryAtPath:baseAbs withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *fileName = nil, *dstPath = nil;
    do {
        fileName = [NSString stringWithFormat:@"%c%c%c%c.mp3", 'A' + (arc4random()%26), 'A' + (arc4random()%26), 'A' + (arc4random()%26), 'A' + (arc4random()%26)];
        dstPath = [baseAbs stringByAppendingPathComponent:fileName];
    } while ([[NSFileManager defaultManager] fileExistsAtPath:dstPath]);
    NSError *copyError = nil;
    if (![[NSFileManager defaultManager] copyItemAtPath:srcPath toPath:dstPath error:&copyError]) { CHZLog(@"direct import copy failed: %@", [copyError localizedDescription]); sqlite3_close(db); return NO; }
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:dstPath error:nil];
    long long fileSize = [[attrs objectForKey:NSFileSize] longLongValue];
    long long itemPid = CHZRandomPID();
    long long artistPid = CHZGetOrCreateArtist(db, artist);
    long long albumArtistPid = CHZGetOrCreateAlbumArtist(db, artist);
    long long genreId = CHZGetOrCreateGenre(db, genre);
    long long albumPid = CHZGetOrCreateAlbum(db, album, albumArtistPid);
    long long baseLoc = CHZSQLiteScalarInt64(db, @"select base_location_id from base_location where path=? limit 1", [NSArray arrayWithObject:baseRel]);
    long long locKind = CHZSQLiteScalarInt64(db, @"select location_kind_id from location_kind where kind='MPEG audio file' limit 1", [NSArray array]);
    if (!baseLoc || !locKind) { CHZLog(@"direct import missing base/location kind base=%lld loc=%lld", baseLoc, locKind); sqlite3_close(db); return NO; }
    long long now = (long long)[[NSDate date] timeIntervalSinceReferenceDate];
    int duration = [[item objectForKey:@"duration"] intValue];
    int year = [[item objectForKey:@"year"] intValue];
    int track = [[item objectForKey:@"track"] intValue];
    int disc = [[item objectForKey:@"discNumber"] intValue];
    int titleSection = CHZSectionForString(title);
    int albumSection = CHZSectionForString(album);
    int artistSection = CHZSectionForString(artist);
    long long titleOrder = CHZOrderKeyForString(title);
    long long albumOrder = CHZExistingOrder(db, @"album_order", @"album", @"album", album); if (!albumOrder) albumOrder = CHZOrderKeyForString(album);
    long long artistOrder = CHZExistingOrder(db, @"item_artist_order", @"item_artist", @"item_artist", artist); if (!artistOrder) artistOrder = CHZOrderKeyForString(artist);
    long long albumArtistOrder = CHZExistingOrder(db, @"album_artist_order", @"album_artist", @"album_artist", artist); if (!albumArtistOrder) albumArtistOrder = artistOrder;

    CHZExecSQL(db, @"begin immediate transaction");
    NSString *sql1 = [NSString stringWithFormat:@"insert into item (item_pid,media_type,title_order,title_order_section,item_artist_pid,item_artist_order,item_artist_order_section,series_name_order,series_name_order_section,album_pid,album_order,album_order_section,album_artist_pid,album_artist_order,album_artist_order_section,genre_id,genre_order,genre_order_section,disc_number,track_number,location_kind_id,base_location_id) values (%lld,8,%lld,%d,%lld,%lld,%d,%lld,%d,%lld,%lld,%d,%lld,%lld,%d,%lld,%lld,%d,%d,%d,%lld,%lld)", itemPid, titleOrder, titleSection, artistPid, artistOrder, artistSection, artistOrder, artistSection, albumPid, albumOrder, albumSection, albumArtistPid, albumArtistOrder, artistSection, genreId, CHZOrderKeyForString(genre), CHZSectionForString(genre), disc, track, locKind, baseLoc];
    NSString *sql2 = [NSString stringWithFormat:@"insert into item_extra (item_pid,title,sort_title,disc_count,track_count,artwork_cache_id,location,media_kind,date_created,file_size,date_modified,year,total_time_ms,duration,audio_format,sample_rate,bit_rate) values (%lld,%@,%@,1,0,%lld,%@,1,%lld,%lld,%lld,%d,%.1f,%d,301,44100,320)", itemPid, CHZSQLQuote(title), CHZSQLQuote(title), itemPid, CHZSQLQuote(fileName), now, fileSize, now, year, (double)duration, duration];
    NSString *sql3 = [NSString stringWithFormat:@"insert into item_search (item_pid,search_title,search_album,search_artist,search_album_artist) values (%lld,%lld,%lld,%lld,%lld)", itemPid, titleOrder, albumOrder, artistOrder, albumArtistOrder];
    NSString *sql4 = [NSString stringWithFormat:@"insert into item_stats (item_pid,is_downloading) values (%lld,0)", itemPid];
    BOOL ok = CHZExecSQL(db, sql1) && CHZExecSQL(db, sql2) && CHZExecSQL(db, sql3) && CHZExecSQL(db, sql4);
    if (ok) {
        CHZExecSQL(db, [NSString stringWithFormat:@"update album set representative_item_pid=%lld, artwork_cache_id=%lld where album_pid=%lld", itemPid, itemPid, albumPid]);
        CHZExecSQL(db, [NSString stringWithFormat:@"update item_artist set representative_item_pid=%lld where item_artist_pid=%lld", itemPid, artistPid]);
        CHZExecSQL(db, [NSString stringWithFormat:@"update album_artist set representative_item_pid=%lld where album_artist_pid=%lld", itemPid, albumArtistPid]);
        CHZExecSQL(db, [NSString stringWithFormat:@"update genre set representative_item_pid=%lld where genre_id=%lld", itemPid, genreId]);
        CHZExecSQL(db, @"commit");
        CHZLog(@"direct imported %@ to %@/%@", title, baseRel, fileName);
    } else {
        CHZExecSQL(db, @"rollback");
        [[NSFileManager defaultManager] removeItemAtPath:dstPath error:nil];
    }
    sqlite3_close(db);
    return ok;
}

static long long CHZFindImportedItemPID(sqlite3 *db, NSDictionary *song) {
    NSString *title = [song objectForKey:@"title"] ?: [song objectForKey:@"name"] ?: @"";
    NSString *album = [song objectForKey:@"album"] ?: @"";
    NSString *artist = [song objectForKey:@"artist"] ?: @"";
    NSString *sql = @"select i.item_pid from item i join item_extra e on i.item_pid=e.item_pid left join album al on i.album_pid=al.album_pid left join item_artist ar on i.item_artist_pid=ar.item_artist_pid where e.title=? and (?='' or al.album=?) and (?='' or ar.item_artist=?) order by e.date_created desc limit 1";
    sqlite3_stmt *stmt = NULL;
    long long pid = 0;
    if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &stmt, NULL) != SQLITE_OK) return 0;
    sqlite3_bind_text(stmt, 1, [title UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, [album UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, [album UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, [artist UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, [artist UTF8String], -1, SQLITE_TRANSIENT);
    if (sqlite3_step(stmt) == SQLITE_ROW) pid = sqlite3_column_int64(stmt, 0);
    sqlite3_finalize(stmt);
    return pid;
}

static BOOL CHZExecSQL(sqlite3 *db, NSString *sql) {
    char *err = NULL;
    int rc = sqlite3_exec(db, [sql UTF8String], NULL, NULL, &err);
    if (rc != SQLITE_OK) { CHZLog(@"sqlite error %d for %@: %s", rc, sql, err ? err : ""); if (err) sqlite3_free(err); return NO; }
    return YES;
}
#endif

static BOOL CHZEnsureMusicPlaylist(NSString *playlistName, NSArray *songs) {
    CHZLog(@"native Music playlist sync disabled for %@ (%u songs); direct MediaLibrary writes are unsafe until verified", playlistName, [songs count]);
    return NO;
#if 0
    if (![playlistName length] || ![songs count]) return NO;
    NSString *dbPath = @"/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb";
    NSString *bakPath = @"/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb.navtunes.bak";
    if (![[NSFileManager defaultManager] fileExistsAtPath:bakPath]) [[NSFileManager defaultManager] copyItemAtPath:dbPath toPath:bakPath error:nil];
    dlopen("/System/Library/PrivateFrameworks/MusicLibrary.framework/MusicLibrary", RTLD_LAZY | RTLD_GLOBAL);
    sqlite3 *db = NULL;
    if (sqlite3_open([dbPath UTF8String], &db) != SQLITE_OK) { CHZLog(@"could not open MediaLibrary db"); return NO; }
    sqlite3_busy_timeout(db, 5000);
    CHZExecSQL(db, @"begin immediate transaction");
    long long container = CHZSQLiteScalarInt64(db, @"select container_pid from container where name=? limit 1", [NSArray arrayWithObject:playlistName]);
    if (!container) {
        container = ((long long)arc4random() << 32) ^ (long long)arc4random();
        if (container < 0) container = -container;
        long long now = (long long)[[NSDate date] timeIntervalSinceReferenceDate];
        NSString *ins = [NSString stringWithFormat:@"insert into container (container_pid, distinguished_kind, date_created, date_modified, name, name_order, parent_pid, media_kinds, is_hidden, filepath, is_saveable, container_type) values (%lld,0,%lld,%lld,'%@',0,0,1,0,'',1,0)", container, now, now, [playlistName stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
        if (!CHZExecSQL(db, ins)) { CHZExecSQL(db, @"rollback"); sqlite3_close(db); return NO; }
    } else {
        NSString *del = [NSString stringWithFormat:@"delete from item_to_container where container_pid=%lld", container];
        CHZExecSQL(db, del);
    }
    NSUInteger added = 0;
    NSUInteger order = 1;
    for (NSDictionary *song in songs) {
        long long item = CHZFindImportedItemPID(db, song);
        if (!item) { order++; continue; }
        NSString *ins = [NSString stringWithFormat:@"insert into item_to_container (item_pid, container_pid, physical_order, shuffle_order) values (%lld,%lld,%u,%u)", item, container, (unsigned int)order, (unsigned int)order];
        if (CHZExecSQL(db, ins)) added++;
        order++;
    }
    CHZExecSQL(db, @"commit");
    sqlite3_close(db);
    CHZLog(@"Music playlist %@ contains %u/%u imported items", playlistName, added, [songs count]);
    return added > 0;
#endif
}

- (void)downloadPlaylistThread:(NSDictionary *)playlistSummary {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSError *error = nil;
    NSString *playlistId = CHZStringValue([playlistSummary objectForKey:@"id"]);
    NSDictionary *root = CHZFetchSubsonic(@"getPlaylist", [NSDictionary dictionaryWithObject:playlistId ?: @"" forKey:@"id"], &error);
    NSDictionary *playlist = [root objectForKey:@"playlist"];
    NSArray *songs = CHZArrayFromSubsonicObject([playlist objectForKey:@"entry"]);
    NSString *playlistName = [playlist objectForKey:@"name"] ?: [playlistSummary objectForKey:@"name"] ?: playlistId;
    CHZRecordPlaylistRequest(playlistName, songs);
    NSUInteger ok = 0;
    NSUInteger index = 0;
    for (NSDictionary *song in songs) {
        index++;
        if ([song isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *playlistSong = [NSMutableDictionary dictionaryWithDictionary:song];
            if ([playlistName length]) [playlistSong setObject:playlistName forKey:@"playlist"];
            CHZSetDownloadRecord(playlistSong, @"Queued", [NSString stringWithFormat:@"Playlist %@ · %u/%u", playlistName, index, [songs count]], nil);
            NSError *songError = nil;
            if (CHZDownloadAndImportSong(playlistSong, &songError)) ok++;
            else CHZLog(@"playlist item download failed: %@", [songError localizedDescription]);
        }
    }
    if (error) CHZLog(@"playlist download failed: %@", [error localizedDescription]);
    else {
        CHZEnsureMusicPlaylist(playlistName, songs);
        CHZLog(@"playlist download queued %u/%u tracks for %@", ok, [songs count], playlistName);
    }
    [pool drain];
}
@end

static UIViewController *CHZNewNavidromeNavigationController(void) {
    CHZNavidromeViewController *root = [[CHZNavidromeViewController alloc] initWithLevel:CHZNavLevelHome parentId:nil title:@"Navidrome"];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.title = @"Navidrome";
    nav.tabBarItem = [[[UITabBarItem alloc] initWithTitle:@"Navidrome" image:nil tag:61333] autorelease];
    [root release];
    return [nav autorelease];
}

static BOOL CHZIsNavidromeController(UIViewController *vc) {
    if ([[vc title] isEqualToString:@"Navidrome"] || [[[vc tabBarItem] title] isEqualToString:@"Navidrome"]) return YES;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *top = [(UINavigationController *)vc topViewController];
        if ([top isKindOfClass:[CHZNavidromeViewController class]]) return YES;
    }
    return NO;
}

static NSArray *CHZControllersByAddingNavidrome(NSArray *controllers) {
    if (![controllers count]) return controllers;
    for (UIViewController *vc in controllers) if (CHZIsNavidromeController(vc)) return controllers;
    NSMutableArray *mut = [NSMutableArray arrayWithArray:controllers];
    [mut addObject:CHZNewNavidromeNavigationController()];
    CHZLog(@"added Navidrome Music tab/page; original=%u new=%u", [controllers count], [mut count]);
    return mut;
}

static BOOL CHZIsRootMusicTabBar(UITabBarController *tab) {
    return [NSStringFromClass([tab class]) isEqualToString:@"IUiPodTabBarController"];
}

static void CHZEnsureNavidromeTab(UITabBarController *tab) {
    if (!CHZIsRootMusicTabBar(tab)) return;
    NSArray *controllers = [tab viewControllers];
    NSArray *updated = CHZControllersByAddingNavidrome(controllers);
    if (updated != controllers) [tab setViewControllers:updated animated:NO];
}

%hook UITabBarController
- (void)setViewControllers:(NSArray *)viewControllers animated:(BOOL)animated {
    if (CHZIsRootMusicTabBar(self)) %orig(CHZControllersByAddingNavidrome(viewControllers), animated);
    else %orig(viewControllers, animated);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    CHZEnsureNavidromeTab(self);
}
%end

static void CHZStartImporter(void) {
    if (CHZTimer) return;
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
    CHZLog(@"Music hook active in %@; queue=%@ prefs=%@", bundle, CHZQueuePath, CHZPrefsPath);
    // Defer work until Music has finished launching; import work is local-only and avoids StoreServices/iTunes Store.
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
