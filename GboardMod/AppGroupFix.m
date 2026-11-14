#import "AppGroupFix.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *g_validAppGroup = nil;

static NSString *DetectValidAppGroupFromProvisioning(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @try {
            NSString *provPath = [[NSBundle mainBundle] pathForResource:@"embedded" ofType:@"mobileprovision"];
            if (!provPath) {
                // If in extension, check parent bundle
                NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
                if ([bundlePath hasSuffix:@".appex"]) {
                    NSString *parentPath = [[bundlePath stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
                    provPath = [parentPath stringByAppendingPathComponent:@"embedded.mobileprovision"];
                }
            }

            if (provPath && [[NSFileManager defaultManager] fileExistsAtPath:provPath]) {
                NSData *data = [NSData dataWithContentsOfFile:provPath options:NSDataReadingMappedIfSafe error:nil];
                if (data) {
                    NSString *raw = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
                    if (raw) {
                        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"<string>(group\\.[^<]+)</string>" options:0 error:nil];
                        NSArray *matches = [re matchesInString:raw options:0 range:NSMakeRange(0, raw.length)];
                        for (NSTextCheckingResult *m in matches) {
                            if (m.numberOfRanges > 1) {
                                NSString *grp = [raw substringWithRange:[m rangeAtIndex:1]];
                                if (![grp containsString:@"*"] && ![grp isEqualToString:@"group.com.google.keyboard"] && ![grp isEqualToString:@"group.com.google.common"]) {
                                    g_validAppGroup = grp;
                                    NSLog(@"[AppGroupFix] Detected valid certificate App Group: %@", g_validAppGroup);
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[AppGroupFix] Exception reading mobileprovision: %@", e);
        }
    });
    return g_validAppGroup;
}

#pragma mark - NSFileManager Hooks

static NSURL *(*orig_containerURLForSecurityApplicationGroupIdentifier)(id self, SEL _cmd, NSString *groupId) = NULL;
static NSURL *my_containerURLForSecurityApplicationGroupIdentifier(id self, SEL _cmd, NSString *groupId) {
    NSURL *url = nil;
    @try {
        if (orig_containerURLForSecurityApplicationGroupIdentifier) {
            url = orig_containerURLForSecurityApplicationGroupIdentifier(self, _cmd, groupId);
        }
    } @catch (NSException *e) {}

    if (url) return url;

    // Try mapping to user certificate's real App Group
    NSString *realGrp = DetectValidAppGroupFromProvisioning();
    if (realGrp && orig_containerURLForSecurityApplicationGroupIdentifier) {
        @try {
            url = orig_containerURLForSecurityApplicationGroupIdentifier(self, _cmd, realGrp);
            if (url) return url;
        } @catch (NSException *e) {}
    }

    // Persistent fallback container in sandbox (NEVER return nil!)
    @try {
        NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        if (!base) base = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!base) base = NSTemporaryDirectory();

        NSString *safeName = [groupId stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        NSString *dir = [base stringByAppendingPathComponent:[NSString stringWithFormat:@"AppGroup_%@", safeName]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        return [NSURL fileURLWithPath:dir isDirectory:YES];
    } @catch (NSException *e) {
        return [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    }
}

#pragma mark - NSUserDefaults Hooks

static NSUserDefaults *(*orig_initWithSuiteName)(id self, SEL _cmd, NSString *suiteName) = NULL;
static NSUserDefaults *my_initWithSuiteName(id self, SEL _cmd, NSString *suiteName) {
    NSUserDefaults *res = nil;
    @try {
        if (orig_initWithSuiteName) {
            res = orig_initWithSuiteName(self, _cmd, suiteName);
        }
    } @catch (NSException *e) {}

    if (res) return res;

    // Try real provisioned app group
    NSString *realGrp = DetectValidAppGroupFromProvisioning();
    if (realGrp && orig_initWithSuiteName) {
        @try {
            res = orig_initWithSuiteName(self, _cmd, realGrp);
            if (res) return res;
        } @catch (NSException *e) {}
    }

    // Fallback: return standardUserDefaults so it NEVER returns nil
    return [NSUserDefaults standardUserDefaults];
}

#pragma mark - AppDelegate Crash Guard

static BOOL (*orig_didFinishLaunchingWithOptions)(id self, SEL _cmd, UIApplication *app, NSDictionary *opts) = NULL;
static BOOL my_didFinishLaunchingWithOptions(id self, SEL _cmd, UIApplication *app, NSDictionary *opts) {
    BOOL res = YES;
    @try {
        if (orig_didFinishLaunchingWithOptions) {
            res = orig_didFinishLaunchingWithOptions(self, _cmd, app, opts);
        }
    } @catch (NSException *e) {
        NSLog(@"[AppGroupFix] Suppressed exception in application:didFinishLaunchingWithOptions: %@", e);
        res = YES;
    }
    return res;
}

@implementation AppGroupFix

+ (nullable NSString *)detectedValidAppGroup {
    return DetectValidAppGroupFromProvisioning();
}

+ (void)installAppGroupHooks {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[AppGroupFix] Installing NSFileManager & NSUserDefaults AppGroup redirection hooks...");

        // 1. Hook NSFileManager containerURLForSecurityApplicationGroupIdentifier:
        Method mContainer = class_getInstanceMethod([NSFileManager class], @selector(containerURLForSecurityApplicationGroupIdentifier:));
        if (mContainer) {
            orig_containerURLForSecurityApplicationGroupIdentifier = (void *)method_getImplementation(mContainer);
            method_setImplementation(mContainer, (IMP)my_containerURLForSecurityApplicationGroupIdentifier);
        }

        // 2. Hook NSUserDefaults initWithSuiteName:
        Method mSuite = class_getInstanceMethod([NSUserDefaults class], @selector(initWithSuiteName:));
        if (mSuite) {
            orig_initWithSuiteName = (void *)method_getImplementation(mSuite);
            method_setImplementation(mSuite, (IMP)my_initWithSuiteName);
        }

        // 3. Hook AppDelegate application:didFinishLaunchingWithOptions: in main app
        Class appDelegateCls = objc_getClass("AppDelegate");
        if (appDelegateCls) {
            Method mLaunch = class_getInstanceMethod(appDelegateCls, @selector(application:didFinishLaunchingWithOptions:));
            if (mLaunch) {
                orig_didFinishLaunchingWithOptions = (void *)method_getImplementation(mLaunch);
                method_setImplementation(mLaunch, (IMP)my_didFinishLaunchingWithOptions);
            }
        }

        NSLog(@"[AppGroupFix] AppGroup hooks installed successfully.");
    });
}

@end
