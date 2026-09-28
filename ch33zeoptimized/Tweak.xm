#import <UIKit/UIKit.h>
#import <substrate.h>
#import <mach/mach.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <sys/wait.h>

@interface SBAppSwitcherBarView : UIView
- (void)addAuxiliaryViews:(id)views;
@end

@interface SBAppSwitcherController : UIViewController
@end

static UIView *CHZOptimizerPage = nil;
static UILabel *CHZRAMLabel = nil;
static UILabel *CHZStatusLabel = nil;
static BOOL CHZAddingOptimizerPage = NO;
static const NSInteger CHZOptimizerPageTag = 0xC6330;
static const NSInteger CHZBrightnessPageTag = 0xC633B;
static NSString *const CHZPrefsPath = @"/var/mobile/Library/Preferences/com.ch33ze.optimized.plist";

static BOOL CHZOptimizedBool(NSString *key, BOOL fallback) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:CHZPrefsPath];
    id value = [prefs objectForKey:key];
    return value ? [value boolValue] : fallback;
}

static void CHZRunOptimizedCtl(NSString *argument) {
    pid_t pid = fork();
    if (pid == 0) {
        execl("/usr/bin/optimizedctl", "optimizedctl", [argument UTF8String], (char *)NULL);
        _exit(127);
    }
}

static NSString *CHZRAMSummary(void) {
    mach_msg_type_number_t count = HOST_VM_INFO_COUNT;
    vm_statistics_data_t vmstat;
    kern_return_t kr = host_statistics(mach_host_self(), HOST_VM_INFO, (host_info_t)&vmstat, &count);
    if (kr != KERN_SUCCESS) return @"RAM: unavailable";

    vm_size_t pageSize = 0;
    host_page_size(mach_host_self(), &pageSize);

    uint64_t freeBytes = ((uint64_t)vmstat.free_count + (uint64_t)vmstat.inactive_count) * (uint64_t)pageSize;
    uint64_t usedBytes = ((uint64_t)vmstat.active_count + (uint64_t)vmstat.wire_count) * (uint64_t)pageSize;
    uint64_t totalBytes = freeBytes + usedBytes;

    int mib[2] = { CTL_HW, HW_MEMSIZE };
    uint64_t hwMem = 0;
    size_t hwLen = sizeof(hwMem);
    if (sysctl(mib, 2, &hwMem, &hwLen, NULL, 0) == 0 && hwMem > 0) totalBytes = hwMem;

    unsigned int freeMB = (unsigned int)(freeBytes / 1024ULL / 1024ULL);
    unsigned int usedMB = (unsigned int)(usedBytes / 1024ULL / 1024ULL);
    unsigned int totalMB = (unsigned int)(totalBytes / 1024ULL / 1024ULL);
    return [NSString stringWithFormat:@"RAM  Free: %u MB   Used: %u MB   Total: %u MB", freeMB, usedMB, totalMB];
}

static void CHZUpdateLabels(void) {
    if (CHZRAMLabel) [CHZRAMLabel setText:CHZRAMSummary()];
    if (CHZStatusLabel) {
        BOOL lowPower = CHZOptimizedBool(@"lowPowerMode", NO);
        BOOL sshOff = CHZOptimizedBool(@"disableSSH", NO);
        [CHZStatusLabel setText:[NSString stringWithFormat:@"Low Power: %@   SSH: %@", lowPower ? @"ON" : @"OFF", sshOff ? @"OFF" : @"ON"]];
    }
}

@interface CHZOptimizerTarget : NSObject
- (void)freeRAM:(id)sender;
- (void)clearApps:(id)sender;
- (void)lowPowerOn:(id)sender;
- (void)lowPowerOff:(id)sender;
- (void)sshOn:(id)sender;
- (void)sshOff:(id)sender;
@end

@implementation CHZOptimizerTarget
- (void)flash:(NSString *)message {
    if (CHZStatusLabel) [CHZStatusLabel setText:message];
    [self performSelector:@selector(refresh) withObject:nil afterDelay:2.0];
}
- (void)refresh { CHZUpdateLabels(); }
- (void)freeRAM:(id)sender { CHZRunOptimizedCtl(@"free-ram"); [self flash:@"Free RAM requested…"] ; }
- (void)clearApps:(id)sender { CHZRunOptimizedCtl(@"clear-apps"); [self flash:@"Clearing user apps…"] ; }
- (void)lowPowerOn:(id)sender { CHZRunOptimizedCtl(@"lowpower-on"); [self flash:@"Low Power ON: stopping background tasks/location/SSH…"] ; }
- (void)lowPowerOff:(id)sender { CHZRunOptimizedCtl(@"lowpower-off"); [self flash:@"Low Power OFF: restoring services…"] ; }
- (void)sshOn:(id)sender { CHZRunOptimizedCtl(@"ssh-on"); [self flash:@"Turning SSH ON…"] ; }
- (void)sshOff:(id)sender { CHZRunOptimizedCtl(@"ssh-off"); [self flash:@"Turning SSH OFF…"] ; }
@end

static CHZOptimizerTarget *CHZTarget = nil;

static UIButton *CHZButton(NSString *title, CGRect frame, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    [button setFrame:frame];
    [button setTitle:title forState:UIControlStateNormal];
    [[button titleLabel] setFont:[UIFont boldSystemFontOfSize:11.0f]];
    if (!CHZTarget) CHZTarget = [[CHZOptimizerTarget alloc] init];
    [button addTarget:CHZTarget action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

static UILabel *CHZLabel(CGRect frame, UIFont *font) {
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    [label setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
    [label setTextColor:[UIColor whiteColor]];
    [label setShadowColor:[UIColor blackColor]];
    [label setShadowOffset:CGSizeMake(0.0f, -1.0f)];
    [label setBackgroundColor:[UIColor clearColor]];
    [label setTextAlignment:NSTextAlignmentCenter];
    [label setFont:font];
    return label;
}

static UIView *CHZMakeOptimizerPage(CGRect frame) {
    UIView *page = [[UIView alloc] initWithFrame:frame];
    [page setTag:CHZOptimizerPageTag];
    [page setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    [page setBackgroundColor:[UIColor clearColor]];
    [page setUserInteractionEnabled:YES];

    CGFloat width = frame.size.width > 0 ? frame.size.width : 320.0f;
    CGFloat margin = 8.0f;
    CGFloat gap = 5.0f;
    CGFloat buttonWidth = (width - (margin * 2.0f) - (gap * 2.0f)) / 3.0f;

    UILabel *title = CHZLabel(CGRectMake(0.0f, 4.0f, width, 15.0f), [UIFont boldSystemFontOfSize:12.0f]);
    [title setText:@"CH33ZE Optimizer"];
    [page addSubview:title];
    [title release];

    CHZRAMLabel = CHZLabel(CGRectMake(0.0f, 19.0f, width, 15.0f), [UIFont systemFontOfSize:10.0f]);
    [page addSubview:CHZRAMLabel];

    [page addSubview:CHZButton(@"Free RAM", CGRectMake(margin, 36.0f, buttonWidth, 24.0f), @selector(freeRAM:))];
    [page addSubview:CHZButton(@"Clear Apps", CGRectMake(margin + buttonWidth + gap, 36.0f, buttonWidth, 24.0f), @selector(clearApps:))];
    [page addSubview:CHZButton(@"LP On", CGRectMake(margin + (buttonWidth + gap) * 2.0f, 36.0f, buttonWidth, 24.0f), @selector(lowPowerOn:))];
    [page addSubview:CHZButton(@"LP Off", CGRectMake(margin, 62.0f, buttonWidth, 24.0f), @selector(lowPowerOff:))];
    [page addSubview:CHZButton(@"SSH On", CGRectMake(margin + buttonWidth + gap, 62.0f, buttonWidth, 24.0f), @selector(sshOn:))];
    [page addSubview:CHZButton(@"SSH Off", CGRectMake(margin + (buttonWidth + gap) * 2.0f, 62.0f, buttonWidth, 24.0f), @selector(sshOff:))];

    CHZStatusLabel = CHZLabel(CGRectMake(0.0f, 87.0f, width, 14.0f), [UIFont systemFontOfSize:9.0f]);
    [page addSubview:CHZStatusLabel];

    CHZUpdateLabels();
    return page;
}

static void CHZAttachOptimizerPage(SBAppSwitcherController *controller) {
    if (CHZAddingOptimizerPage) return;
    CHZAddingOptimizerPage = YES;

    SBAppSwitcherBarView *barView = nil;
    @try {
        barView = MSHookIvar<SBAppSwitcherBarView *>(controller, "_bottomBar");
    } @catch (NSException *exception) {
        barView = nil;
    }

    if (barView && [barView respondsToSelector:@selector(addAuxiliaryViews:)]) {
        if (CHZOptimizerPage) {
            [CHZOptimizerPage removeFromSuperview];
            [CHZOptimizerPage release];
            CHZOptimizerPage = nil;
            CHZRAMLabel = nil;
            CHZStatusLabel = nil;
        }

        CGRect frame = [barView bounds];
        if (frame.size.width <= 0.0f) frame.size.width = [[UIScreen mainScreen] bounds].size.width;
        if (frame.size.height <= 0.0f) frame.size.height = 104.0f;

        CHZOptimizerPage = CHZMakeOptimizerPage(frame);
        NSMutableArray *auxViews = [NSMutableArray array];
        BOOL inserted = NO;
        @try {
            NSMutableArray *existingAuxViews = MSHookIvar<NSMutableArray *>(barView, "_auxViews");
            for (UIView *view in existingAuxViews) {
                if ([view tag] == CHZOptimizerPageTag) continue;
                if (!inserted && [view tag] == CHZBrightnessPageTag) {
                    [auxViews addObject:CHZOptimizerPage];
                    inserted = YES;
                }
                [auxViews addObject:view];
            }
        } @catch (NSException *exception) {
        }
        if (!inserted) [auxViews insertObject:CHZOptimizerPage atIndex:0];
        [barView addAuxiliaryViews:auxViews];
    }

    CHZAddingOptimizerPage = NO;
}

%hook UIView

+ (void)setAnimationsEnabled:(BOOL)enabled {
    if (CHZOptimizedBool(@"disableAnimations", NO)) {
        %orig(NO);
    } else {
        %orig(enabled);
    }
}

%end

%hook SBAppSwitcherController

- (void)viewWillAppear {
    %orig;
    CHZAttachOptimizerPage(self);
}

- (void)viewDidAppear {
    %orig;
    CHZUpdateLabels();
}

- (void)appSwitcherBarRemovedFromSuperview:(id)superview {
    if (CHZOptimizerPage) {
        [CHZOptimizerPage removeFromSuperview];
        [CHZOptimizerPage release];
        CHZOptimizerPage = nil;
        CHZRAMLabel = nil;
        CHZStatusLabel = nil;
    }
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        if (CHZOptimizedBool(@"disableAnimations", NO)) {
            [UIView setAnimationsEnabled:NO];
        }
    }
}
