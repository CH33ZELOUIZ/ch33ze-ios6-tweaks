#import <Foundation/Foundation.h>
#import <unistd.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <dirent.h>
#import <signal.h>
#import <string.h>

static NSString *const CHZPrefsPath = @"/var/mobile/Library/Preferences/com.ch33ze.optimized.plist";
static NSString *const CHZDisableSuffix = @".optimized-disabled";

typedef struct {
    const char *key;
    const char *title;
    const char *paths[10];
    bool defaultEnabled;
} CHZRule;

static CHZRule CHZRules[] = {
    {"disableOTA", "OTA updates", {
        "/System/Library/LaunchDaemons/com.apple.mobile.softwareupdated.plist",
        "/System/Library/LaunchDaemons/com.apple.softwareupdateservicesd.plist",
        NULL
    }, true},
    {"disableDiagnostics", "diagnostics/logging", {
        "/System/Library/LaunchDaemons/com.apple.ReportCrash.plist",
        "/System/Library/LaunchDaemons/com.apple.ReportCrash.SafetyNet.plist",
        "/System/Library/LaunchDaemons/com.apple.CrashHousekeeping.plist",
        "/System/Library/LaunchDaemons/com.apple.DumpBasebandCrash.plist",
        "/System/Library/LaunchDaemons/com.apple.DumpPanic.plist",
        NULL
    }, true},
    {"disableMailSync", "Mail/account fetch", {
        "/System/Library/LaunchDaemons/com.apple.dataaccess.dataaccessd.plist",
        NULL
    }, true},
    {"disableGameCenter", "Game Center", {
        "/System/Library/LaunchDaemons/com.apple.gamed.plist",
        NULL
    }, false},
    {"disableSpotlight", "Spotlight", {
        "/System/Library/LaunchDaemons/com.apple.searchd.plist",
        "/System/Library/LaunchDaemons/com.apple.spotlightd.plist",
        NULL
    }, false},
    {"disableLocation", "Location Services daemon", {
        "/System/Library/LaunchDaemons/com.apple.locationd.plist",
        NULL
    }, false},
    {"disablePush", "Push/background notification daemon", {
        "/System/Library/LaunchDaemons/com.apple.apsd.plist",
        NULL
    }, false},
    {"disableSSH", "OpenSSH daemon", {
        "/Library/LaunchDaemons/com.openssh.sshd.plist",
        "/Library/LaunchDaemons/org.openssh.sshd.plist",
        NULL
    }, false},
    {NULL, NULL, {NULL}, false}
};

static BOOL CHZFileExists(NSString *path) {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

static int CHZRunWait(const char *path, const char *arg1, const char *arg2, const char *arg3) {
    pid_t pid = fork();
    if (pid == 0) {
        if (arg3) execl(path, path, arg1, arg2, arg3, (char *)NULL);
        else if (arg2) execl(path, path, arg1, arg2, (char *)NULL);
        else if (arg1) execl(path, path, arg1, (char *)NULL);
        else execl(path, path, (char *)NULL);
        _exit(127);
    }
    if (pid < 0) return -1;
    int status = 0;
    waitpid(pid, &status, 0);
    return status;
}

static int CHZRunLaunchctl(NSString *verb, NSString *path) {
    pid_t pid = fork();
    if (pid == 0) {
        execl("/bin/launchctl", "launchctl", [verb UTF8String], "-w", [path UTF8String], (char *)NULL);
        _exit(127);
    }
    if (pid < 0) return -1;
    int status = 0;
    waitpid(pid, &status, 0);
    return status;
}

static void CHZDisablePath(NSString *path) {
    NSString *disabledPath = [path stringByAppendingString:CHZDisableSuffix];
    if (!CHZFileExists(path)) return;
    CHZRunLaunchctl(@"unload", path);
    [[NSFileManager defaultManager] removeItemAtPath:disabledPath error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:path toPath:disabledPath error:nil];
}

static void CHZEnablePath(NSString *path) {
    NSString *disabledPath = [path stringByAppendingString:CHZDisableSuffix];
    if (CHZFileExists(disabledPath) && !CHZFileExists(path)) {
        [[NSFileManager defaultManager] moveItemAtPath:disabledPath toPath:path error:nil];
        chmod([path fileSystemRepresentation], 0644);
    }
    if (CHZFileExists(path)) CHZRunLaunchctl(@"load", path);
}

static NSMutableDictionary *CHZPrefs(void) {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:CHZPrefsPath];
    if (!prefs) prefs = [NSMutableDictionary dictionary];
    return prefs;
}

static BOOL CHZPref(NSDictionary *prefs, NSString *key, BOOL fallback) {
    id value = [prefs objectForKey:key];
    return value ? [value boolValue] : fallback;
}

static void CHZSavePrefs(NSDictionary *prefs) {
    [prefs writeToFile:CHZPrefsPath atomically:YES];
    chown([CHZPrefsPath fileSystemRepresentation], 501, 501);
    chmod([CHZPrefsPath fileSystemRepresentation], 0644);
}

static void CHZApplyRule(CHZRule rule, NSDictionary *prefs) {
    NSString *key = [NSString stringWithUTF8String:rule.key];
    BOOL enabled = CHZPref(prefs, key, rule.defaultEnabled);
    for (int p = 0; rule.paths[p]; p++) {
        NSString *path = [NSString stringWithUTF8String:rule.paths[p]];
        if (enabled) CHZDisablePath(path);
        else CHZEnablePath(path);
    }
}

static int CHZApply(void) {
    if (geteuid() != 0) {
        fprintf(stderr, "optimizedctl must run as root\n");
        return 1;
    }

    NSDictionary *prefs = CHZPrefs();
    for (int i = 0; CHZRules[i].key; i++) CHZApplyRule(CHZRules[i], prefs);
    return 0;
}

static int CHZSetLowPower(BOOL on) {
    NSMutableDictionary *prefs = CHZPrefs();
    [prefs setObject:[NSNumber numberWithBool:on] forKey:@"lowPowerMode"];
    const char *keys[] = {"disableOTA", "disableDiagnostics", "disableMailSync", "disableGameCenter", "disableSpotlight", "disableLocation", "disablePush", "disableSSH", NULL};
    for (int i = 0; keys[i]; i++) {
        [prefs setObject:[NSNumber numberWithBool:on] forKey:[NSString stringWithUTF8String:keys[i]]];
    }
    CHZSavePrefs(prefs);
    return CHZApply();
}

static int CHZSetSSH(BOOL on) {
    NSMutableDictionary *prefs = CHZPrefs();
    [prefs setObject:[NSNumber numberWithBool:!on] forKey:@"disableSSH"];
    CHZSavePrefs(prefs);
    return CHZApply();
}

static int CHZFreeRAM(void) {
    if (CHZFileExists(@"/usr/bin/purge")) return CHZRunWait("/usr/bin/purge", NULL, NULL, NULL);
    if (CHZFileExists(@"/bin/sync")) CHZRunWait("/bin/sync", NULL, NULL, NULL);
    return 0;
}

static BOOL CHZStringInArray(NSString *value, NSArray *array) {
    for (NSString *item in array) if ([item isEqualToString:value]) return YES;
    return NO;
}

static int CHZClearApps(void) {
    NSArray *skip = [NSArray arrayWithObjects:@"MobilePhone", @"MobileMail", @"MobileSMS", @"MobileSafari", @"Preferences", @"SpringBoard", @"backboardd", @"mediaserverd", @"securityd", @"lockdownd", @"launchd", @"CommCenter", @"configd", @"locationd", @"apsd", @"sshd", nil];
    NSMutableSet *executables = [NSMutableSet set];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *roots = [NSArray arrayWithObjects:@"/var/mobile/Applications", @"/User/Applications", nil];

    for (NSString *root in roots) {
        NSArray *containers = [fm contentsOfDirectoryAtPath:root error:nil];
        for (NSString *container in containers) {
            NSString *containerPath = [root stringByAppendingPathComponent:container];
            NSArray *items = [fm contentsOfDirectoryAtPath:containerPath error:nil];
            for (NSString *item in items) {
                if (![[item pathExtension] isEqualToString:@"app"]) continue;
                NSString *infoPath = [[containerPath stringByAppendingPathComponent:item] stringByAppendingPathComponent:@"Info.plist"];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
                NSString *exe = [info objectForKey:@"CFBundleExecutable"];
                if ([exe length] && !CHZStringInArray(exe, skip)) [executables addObject:exe];
            }
        }
    }

    for (NSString *exe in executables) {
        pid_t pid = fork();
        if (pid == 0) {
            execl("/usr/bin/killall", "killall", [exe UTF8String], (char *)NULL);
            execl("/bin/killall", "killall", [exe UTF8String], (char *)NULL);
            _exit(127);
        }
        if (pid > 0) {
            int status = 0;
            waitpid(pid, &status, 0);
        }
    }
    return 0;
}

static void CHZPrintStatus(void) {
    NSDictionary *prefs = CHZPrefs();
    printf("Low Power Mode: %s\n", CHZPref(prefs, @"lowPowerMode", NO) ? "on" : "off");
    for (int i = 0; CHZRules[i].key; i++) {
        NSString *key = [NSString stringWithUTF8String:CHZRules[i].key];
        BOOL enabled = CHZPref(prefs, key, CHZRules[i].defaultEnabled);
        printf("%s: %s\n", CHZRules[i].title, enabled ? "disabled" : "enabled");
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc >= 2 && strcmp(argv[1], "apply") == 0) return CHZApply();
        if (argc >= 2 && strcmp(argv[1], "status") == 0) { CHZPrintStatus(); return 0; }
        if (argc >= 2 && strcmp(argv[1], "lowpower-on") == 0) return CHZSetLowPower(YES);
        if (argc >= 2 && strcmp(argv[1], "lowpower-off") == 0) return CHZSetLowPower(NO);
        if (argc >= 2 && strcmp(argv[1], "ssh-on") == 0) return CHZSetSSH(YES);
        if (argc >= 2 && strcmp(argv[1], "ssh-off") == 0) return CHZSetSSH(NO);
        if (argc >= 2 && strcmp(argv[1], "free-ram") == 0) return CHZFreeRAM();
        if (argc >= 2 && strcmp(argv[1], "clear-apps") == 0) return CHZClearApps();
        fprintf(stderr, "usage: optimizedctl apply|status|lowpower-on|lowpower-off|ssh-on|ssh-off|free-ram|clear-apps\n");
        return 2;
    }
}
