#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <unistd.h>
#import <sys/wait.h>

#ifndef API_AVAILABLE
#define API_AVAILABLE(...)
#endif
#import <Preferences/PSListController.h>

@interface OptimizedRootListController : PSListController
@end

@implementation OptimizedRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"Root" target:self] retain];
    }
    return _specifiers;
}

- (void)runPath:(NSString *)path argument:(NSString *)argument wait:(BOOL)waitForExit {
    pid_t pid = fork();
    if (pid == 0) {
        if (argument) execl([path UTF8String], [[path lastPathComponent] UTF8String], [argument UTF8String], (char *)NULL);
        else execl([path UTF8String], [[path lastPathComponent] UTF8String], (char *)NULL);
        _exit(127);
    }
    if (waitForExit && pid > 0) {
        int status = 0;
        waitpid(pid, &status, 0);
    }
}

- (void)runOptimizedCtl:(NSString *)argument {
    [self runPath:@"/usr/bin/optimizedctl" argument:argument wait:YES];
}

- (void)applySettings:(id)sender {
    CFPreferencesAppSynchronize(CFSTR("com.ch33ze.optimized"));
    [self runOptimizedCtl:@"apply"];
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Optimized"
                                                    message:@"Settings applied. Respring when ready."
                                                   delegate:nil
                                          cancelButtonTitle:@"OK"
                                          otherButtonTitles:nil];
    [alert show];
    [alert release];
}

- (void)applyAndRespring:(id)sender {
    CFPreferencesAppSynchronize(CFSTR("com.ch33ze.optimized"));
    [self runOptimizedCtl:@"apply"];
    [self runPath:@"/usr/bin/killall" argument:@"SpringBoard" wait:NO];
}

@end
