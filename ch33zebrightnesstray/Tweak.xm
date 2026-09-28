#import <UIKit/UIKit.h>
#import <substrate.h>

@interface SBBrightnessController : NSObject
+ (id)sharedBrightnessController;
- (void)setBrightnessLevel:(float)level;
- (void)_setBrightnessLevel:(float)level showHUD:(BOOL)hud;
@end

@interface SBAppSwitcherBarView : UIView
- (void)addAuxiliaryViews:(id)views;
@end

@interface SBAppSwitcherController : UIViewController
@end

static UIView *CHZBrightnessPage = nil;
static UISlider *CHZBrightnessSlider = nil;
static BOOL CHZAddingPage = NO;
static const NSInteger CHZBrightnessPageTag = 0xC633B;

static float CHZCurrentBrightness(void) {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.apple.springboard.plist"];
    id raw = [plist objectForKey:@"SBBacklightLevel2"];
    if (raw && [raw respondsToSelector:@selector(floatValue)]) {
        float value = [raw floatValue];
        if (value >= 0.0f && value <= 1.0f) return value;
    }
    return 0.5f;
}

static void CHZSetBrightness(float value) {
    if (value < 0.0f) value = 0.0f;
    if (value > 1.0f) value = 1.0f;

    Class controllerClass = NSClassFromString(@"SBBrightnessController");
    id controller = [controllerClass sharedBrightnessController];

    if ([controller respondsToSelector:@selector(_setBrightnessLevel:showHUD:)]) {
        [controller _setBrightnessLevel:value showHUD:YES];
    } else if ([controller respondsToSelector:@selector(setBrightnessLevel:)]) {
        [controller setBrightnessLevel:value];
    } else {
        [[UIScreen mainScreen] setBrightness:value];
    }
}

@interface CHZBrightnessTarget : NSObject
- (void)sliderChanged:(UISlider *)slider;
@end

@implementation CHZBrightnessTarget
- (void)sliderChanged:(UISlider *)slider {
    CHZSetBrightness([slider value]);
}
@end

static CHZBrightnessTarget *CHZTarget = nil;

static UIView *CHZMakeBrightnessPage(CGRect frame) {
    UIView *page = [[UIView alloc] initWithFrame:frame];
    [page setTag:CHZBrightnessPageTag];
    [page setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    [page setBackgroundColor:[UIColor clearColor]];
    [page setUserInteractionEnabled:YES];

    CGFloat width = frame.size.width > 0 ? frame.size.width : 320.0f;
    CGFloat y = 28.0f;

    UIImageView *less = [[UIImageView alloc] initWithImage:[UIImage imageWithContentsOfFile:@"/Applications/Preferences.app/LessBright.png"]];
    [less setFrame:CGRectMake(20.0f, y + 2.0f, 20.0f, 20.0f)];
    [less setContentMode:UIViewContentModeCenter];
    [page addSubview:less];
    [less release];

    UIImageView *more = [[UIImageView alloc] initWithImage:[UIImage imageWithContentsOfFile:@"/Applications/Preferences.app/MoreBright.png"]];
    [more setFrame:CGRectMake(width - 40.0f, y + 2.0f, 20.0f, 20.0f)];
    [more setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin];
    [more setContentMode:UIViewContentModeCenter];
    [page addSubview:more];
    [more release];

    CHZBrightnessSlider = [[UISlider alloc] initWithFrame:CGRectMake(48.0f, y, width - 96.0f, 23.0f)];
    [CHZBrightnessSlider setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
    [CHZBrightnessSlider setMinimumValue:0.0f];
    [CHZBrightnessSlider setMaximumValue:1.0f];
    [CHZBrightnessSlider setContinuous:YES];
    [CHZBrightnessSlider setValue:CHZCurrentBrightness() animated:NO];

    if (!CHZTarget) CHZTarget = [[CHZBrightnessTarget alloc] init];
    [CHZBrightnessSlider addTarget:CHZTarget action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [page addSubview:CHZBrightnessSlider];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0.0f, y + 28.0f, width, 20.0f)];
    [label setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
    [label setText:@"Brightness"];
    [label setTextAlignment:NSTextAlignmentCenter];
    [label setTextColor:[UIColor whiteColor]];
    [label setShadowColor:[UIColor blackColor]];
    [label setShadowOffset:CGSizeMake(0.0f, -1.0f)];
    [label setBackgroundColor:[UIColor clearColor]];
    [label setFont:[UIFont boldSystemFontOfSize:12.0f]];
    [page addSubview:label];
    [label release];

    return page;
}

static void CHZAttachBrightnessPage(SBAppSwitcherController *controller) {
    if (CHZAddingPage) return;
    CHZAddingPage = YES;

    SBAppSwitcherBarView *barView = nil;
    @try {
        barView = MSHookIvar<SBAppSwitcherBarView *>(controller, "_bottomBar");
    } @catch (NSException *exception) {
        barView = nil;
    }

    if (barView && [barView respondsToSelector:@selector(addAuxiliaryViews:)]) {
        if (CHZBrightnessPage) {
            [CHZBrightnessPage removeFromSuperview];
            [CHZBrightnessPage release];
            CHZBrightnessPage = nil;
            CHZBrightnessSlider = nil;
        }

        CGRect frame = [barView bounds];
        if (frame.size.width <= 0.0f) frame.size.width = [[UIScreen mainScreen] bounds].size.width;
        if (frame.size.height <= 0.0f) frame.size.height = 88.0f;

        NSMutableArray *auxViews = [NSMutableArray array];
        @try {
            NSMutableArray *existingAuxViews = MSHookIvar<NSMutableArray *>(barView, "_auxViews");
            for (UIView *view in existingAuxViews) {
                if (view != CHZBrightnessPage && [view tag] != CHZBrightnessPageTag) {
                    [auxViews addObject:view];
                }
            }
        } @catch (NSException *exception) {
        }

        CHZBrightnessPage = CHZMakeBrightnessPage(frame);
        [auxViews addObject:CHZBrightnessPage];
        [barView addAuxiliaryViews:auxViews];
    }

    CHZAddingPage = NO;
}

%hook SBAppSwitcherController

- (void)viewWillAppear {
    %orig;
    CHZAttachBrightnessPage(self);
}

- (void)viewDidAppear {
    %orig;
    if (CHZBrightnessSlider) [CHZBrightnessSlider setValue:CHZCurrentBrightness() animated:NO];
}

- (void)appSwitcherBarRemovedFromSuperview:(id)superview {
    if (CHZBrightnessPage) {
        [CHZBrightnessPage removeFromSuperview];
        [CHZBrightnessPage release];
        CHZBrightnessPage = nil;
        CHZBrightnessSlider = nil;
    }
    %orig;
}

%end

%hook SBBrightnessController

- (void)setBrightnessLevel:(float)level {
    if (CHZBrightnessSlider) [CHZBrightnessSlider setValue:level animated:NO];
    %orig;
}

- (void)_setBrightnessLevel:(float)level showHUD:(BOOL)hud {
    if (CHZBrightnessSlider) [CHZBrightnessSlider setValue:level animated:NO];
    %orig;
}

%end
