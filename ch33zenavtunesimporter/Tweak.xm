#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <dlfcn.h>

static NSString * const CHZQueuePath = @"/var/mobile/Library/NavTunesImportQueue.plist";
static NSString * const CHZLogPath = @"/var/mobile/Library/Logs/NavTunesImporter.log";
static NSString * const CHZPrefsPath = @"/var/mobile/Library/Preferences/com.ch33ze.navtunes.plist";
static NSString * const CHZDownloadRoot = @"/var/mobile/Media/Downloads/NavTunes";
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
            if (![item isKindOfClass:[NSDictionary class]] || !CHZImportItem(item)) [remaining addObject:item];
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
    NSURL *url = CHZSubsonicURL(@"stream", [NSDictionary dictionaryWithObject:songId forKey:@"id"]);
    if (!url) {
        if (outError) *outError = [NSError errorWithDomain:@"CH33ZENavTunes" code:401 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"Configure %@ before downloading.", CHZPrefsPath] forKey:NSLocalizedDescriptionKey]];
        return NO;
    }

    NSError *error = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:[NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:300.0] returningResponse:nil error:&error];
    if (![data length] || error) {
        if (outError) *outError = error ?: [NSError errorWithDomain:@"CH33ZENavTunes" code:502 userInfo:[NSDictionary dictionaryWithObject:@"No audio data returned by Navidrome stream." forKey:NSLocalizedDescriptionKey]];
        return NO;
    }

    NSString *artist = [song objectForKey:@"artist"] ?: @"Unknown Artist";
    NSString *album = [song objectForKey:@"album"] ?: @"Navidrome";
    NSString *title = [song objectForKey:@"title"] ?: [song objectForKey:@"name"] ?: songId;
    NSString *suffix = [song objectForKey:@"suffix"] ?: @"mp3";
    NSString *dir = [[CHZDownloadRoot stringByAppendingPathComponent:CHZSafePathComponent(artist)] stringByAppendingPathComponent:CHZSafePathComponent(album)];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", CHZSafePathComponent(title), suffix]];
    if (![data writeToFile:path atomically:YES]) {
        if (outError) *outError = [NSError errorWithDomain:@"CH33ZENavTunes" code:500 userInfo:[NSDictionary dictionaryWithObject:@"Could not save downloaded track" forKey:NSLocalizedDescriptionKey]];
        return NO;
    }

    NSMutableDictionary *import = [NSMutableDictionary dictionaryWithObjectsAndKeys:path, @"path", title, @"title", artist, @"artist", album, @"album", @"song", @"kind", nil];
    if ([song objectForKey:@"genre"]) [import setObject:[song objectForKey:@"genre"] forKey:@"genre"];
    if ([song objectForKey:@"duration"]) [import setObject:[NSNumber numberWithInt:[[song objectForKey:@"duration"] intValue] * 1000] forKey:@"duration"];
    if ([song objectForKey:@"year"]) [import setObject:[song objectForKey:@"year"] forKey:@"year"];
    CHZEnqueueImport(import);
    CHZLog(@"downloaded Navidrome track to %@", path);
    CHZProcessQueue();
    return YES;
}

typedef enum { CHZNavLevelHome = 0, CHZNavLevelArtists = 1, CHZNavLevelAlbums = 2, CHZNavLevelSongs = 3, CHZNavLevelPlaylistSongs = 4 } CHZNavLevel;

@interface CHZNavidromeViewController : UITableViewController {
    CHZNavLevel _level;
    NSString *_parentId;
    NSString *_parentTitle;
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
- (void)dealloc { [_parentId release]; [_parentTitle release]; [_items release]; [_status release]; [super dealloc]; }
- (void)viewDidLoad { [super viewDidLoad]; self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refresh)] autorelease]; [self refresh]; }
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
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _level == CHZNavLevelHome ? 2 : 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_level == CHZNavLevelHome) return section == 0 ? 1 : MAX((NSInteger)[_items count], 1);
    return MAX((NSInteger)[_items count], 1);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (_level == CHZNavLevelHome) return section == 0 ? @"All Music" : [NSString stringWithFormat:@"Playlists — %@", _status];
    return _status;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *ident = (_level == CHZNavLevelSongs || _level == CHZNavLevelPlaylistSongs) ? @"song" : @"nav";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ident];
    if (!cell) cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:ident] autorelease];
    if (_level == CHZNavLevelHome && [indexPath section] == 0) {
        cell.textLabel.text = @"All Music";
        cell.detailTextLabel.text = @"Browse Artists, Albums, and Songs";
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
    if (_level == CHZNavLevelSongs || _level == CHZNavLevelPlaylistSongs) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ — %@", [item objectForKey:@"artist"] ?: _parentTitle ?: @"Unknown Artist", [item objectForKey:@"album"] ?: @"Navidrome"];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        [button setTitle:@"Download" forState:UIControlStateNormal];
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
    if (_level == CHZNavLevelHome && [indexPath section] == 0) {
        CHZNavidromeViewController *vc = [[CHZNavidromeViewController alloc] initWithLevel:CHZNavLevelArtists parentId:nil title:@"All Music"];
        [[self navigationController] pushViewController:vc animated:YES];
        [vc release];
        return;
    }
    if ([_items count] == 0 || _level == CHZNavLevelSongs || _level == CHZNavLevelPlaylistSongs) return;
    NSDictionary *item = [_items objectAtIndex:[indexPath row]];
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
- (void)downloadPlaylistThread:(NSDictionary *)playlistSummary {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSError *error = nil;
    NSString *playlistId = CHZStringValue([playlistSummary objectForKey:@"id"]);
    NSDictionary *root = CHZFetchSubsonic(@"getPlaylist", [NSDictionary dictionaryWithObject:playlistId ?: @"" forKey:@"id"], &error);
    NSDictionary *playlist = [root objectForKey:@"playlist"];
    NSArray *songs = CHZArrayFromSubsonicObject([playlist objectForKey:@"entry"]);
    NSUInteger ok = 0;
    for (NSDictionary *song in songs) {
        if ([song isKindOfClass:[NSDictionary class]]) {
            NSError *songError = nil;
            if (CHZDownloadAndImportSong(song, &songError)) ok++;
            else CHZLog(@"playlist item download failed: %@", [songError localizedDescription]);
        }
    }
    if (error) CHZLog(@"playlist download failed: %@", [error localizedDescription]);
    else CHZLog(@"playlist download queued %u/%u tracks for %@", ok, [songs count], [playlistSummary objectForKey:@"name"] ?: playlistId);
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

static void CHZEnsureNavidromeTab(UITabBarController *tab) {
    NSArray *controllers = [tab viewControllers];
    NSArray *updated = CHZControllersByAddingNavidrome(controllers);
    if (updated != controllers) [tab setViewControllers:updated animated:NO];
}

%hook UITabBarController
- (void)setViewControllers:(NSArray *)viewControllers animated:(BOOL)animated {
    %orig(CHZControllersByAddingNavidrome(viewControllers), animated);
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
