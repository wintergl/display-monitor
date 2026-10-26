#import "MenuBarVisibilityBridge.h"
#import <dlfcn.h>
#import <objc/message.h>

// Keep the private framework out of the link graph. Availability is determined
// entirely at runtime, and the owning Swift layer decides which OS versions may use it.
static NSString * const DMMenuBarVisibilityErrorDomain =
    @"com.hanshuai.DisplayMonitor.MenuBarVisibilityBridge";

void DMDeliverMenuBarVisibilityCompletionOnMainQueue(
    NSError *error,
    void (^completion)(NSError *)) {
    // Swift 6 closures created by MainActor-isolated code can assert isolation
    // before their body executes. The native API replies on a private queue, so
    // this queue hop must happen before crossing back into Swift.
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(error);
    });
}

static NSError *DMMenuBarVisibilityError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:DMMenuBarVisibilityErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static Class DMMenuBarVisibilityConfigurationClass(void) {
    static Class result;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *framework = dlopen(
            "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore",
            RTLD_LOCAL | RTLD_LAZY);
        if (framework != NULL) {
            result = NSClassFromString(@"MBAssessmentModeConfiguration");
        }
        // Keep the framework loaded until process exit while requests may still exist.
    });
    return result;
}

static Class DMMenuBarVisibilityAssertionClass(void) {
    if (DMMenuBarVisibilityConfigurationClass() == Nil) return Nil;
    return NSClassFromString(@"MBAssessmentModeAssertion");
}

static SEL DMMenuBarVisibilityConfigurationSelector(void) {
    return NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:");
}

static SEL DMMenuBarVisibilityActivationSelector(void) {
    return NSSelectorFromString(@"activateWithConfiguration:completionHandler:");
}

@protocol DMMenuBarVisibilityConfigurationConstruction <NSObject>
- (instancetype)initWithAllowedSystemItems:(NSArray<NSNumber *> *)items
                  allowedBundleIdentifiers:(NSArray<NSString *> *)bundles;
@end

@interface DMMenuBarVisibilityCancellation : NSObject
@property(atomic) BOOL cancelled;
@end

@implementation DMMenuBarVisibilityCancellation
@end

static void DMInvalidateRawMenuBarVisibilityAssertion(id raw) {
    if (raw == nil) return;

    @try {
        SEL selector = NSSelectorFromString(@"invalidate");
        if ([raw respondsToSelector:selector]) {
            ((void (*)(id, SEL))objc_msgSend)(raw, selector);
        }
    } @catch (NSException *exception) {
        NSLog(@"[DisplayMonitor] Restoring menu bar visibility raised: %@", exception.name);
    }
}

@interface DMMenuBarVisibilityAssertion ()
@property(nonatomic, strong, nullable) id rawAssertion;
@property(nonatomic, strong) DMMenuBarVisibilityCancellation *cancellation;
- (instancetype)initWithRawAssertion:(id)rawAssertion;
@end

@implementation DMMenuBarVisibilityAssertion

- (instancetype)initWithRawAssertion:(id)rawAssertion {
    self = [super init];
    if (self) {
        _rawAssertion = rawAssertion;
        _cancellation = [[DMMenuBarVisibilityCancellation alloc] init];
    }
    return self;
}

- (void)invalidate {
    self.cancellation.cancelled = YES;
    id raw = self.rawAssertion;
    self.rawAssertion = nil;
    DMInvalidateRawMenuBarVisibilityAssertion(raw);
}

- (void)dealloc {
    [self invalidate];
}

@end

@implementation DMMenuBarVisibility

+ (BOOL)supportsHiding {
    Class configuration = DMMenuBarVisibilityConfigurationClass();
    Class assertion = DMMenuBarVisibilityAssertionClass();
    return configuration != Nil && assertion != Nil
        && [configuration instancesRespondToSelector:DMMenuBarVisibilityConfigurationSelector()]
        && [assertion instancesRespondToSelector:DMMenuBarVisibilityActivationSelector()]
        && [assertion instancesRespondToSelector:NSSelectorFromString(@"invalidate")];
}

+ (NSString *)diagnosticSummary {
    return [self supportsHiding]
        ? @"菜单栏隐藏接口及恢复方法可解析（尚未验证本次隐藏效果）"
        : @"当前系统未提供完整的菜单栏隐藏与恢复接口";
}

+ (DMMenuBarVisibilityAssertion *)beginAllowingBundles:(NSArray<NSString *> *)bundleIDs
                                           systemItems:(NSArray<NSNumber *> *)systemItems
                                            completion:(void (^)(NSError * _Nullable))completion {
    if (![self supportsHiding]) {
        DMDeliverMenuBarVisibilityCompletionOnMainQueue(
            DMMenuBarVisibilityError(1, @"当前系统的菜单栏隐藏接口不可用。"),
            completion);
        return nil;
    }

    DMMenuBarVisibilityAssertion *owner = nil;
    @try {
        Class configurationClass = DMMenuBarVisibilityConfigurationClass();
        id<DMMenuBarVisibilityConfigurationConstruction> allocated =
            (id<DMMenuBarVisibilityConfigurationConstruction>)[configurationClass alloc];
        id configuration = [allocated initWithAllowedSystemItems:systemItems
                                        allowedBundleIdentifiers:bundleIDs];
        if (configuration == nil) {
            DMDeliverMenuBarVisibilityCompletionOnMainQueue(
                DMMenuBarVisibilityError(2, @"系统没有创建菜单栏隐藏配置。"),
                completion);
            return nil;
        }

        id raw = [[DMMenuBarVisibilityAssertionClass() alloc] init];
        if (raw == nil) {
            DMDeliverMenuBarVisibilityCompletionOnMainQueue(
                DMMenuBarVisibilityError(3, @"系统没有创建菜单栏隐藏请求。"),
                completion);
            return nil;
        }

        // Wrap before activation so an Objective-C exception can still restore it.
        owner = [[DMMenuBarVisibilityAssertion alloc] initWithRawAssertion:raw];
        DMMenuBarVisibilityCancellation *cancellation = owner.cancellation;
        __weak id weakRaw = raw;
        void (^safeCompletion)(NSError *) = ^(NSError *error) {
            DMDeliverMenuBarVisibilityCompletionOnMainQueue(error, ^(NSError *deliveredError) {
                // Serialize late restoration with UI state, and invalidate only this
                // request if its owner was cancelled while activation was in flight.
                if (cancellation.cancelled) {
                    DMInvalidateRawMenuBarVisibilityAssertion(weakRaw);
                }
                completion(deliveredError);
            });
        };
        ((void (*)(id, SEL, id, void (^)(NSError *)))objc_msgSend)(
            raw,
            DMMenuBarVisibilityActivationSelector(),
            configuration,
            safeCompletion);
        return owner;
    } @catch (NSException *exception) {
        [owner invalidate];
        DMDeliverMenuBarVisibilityCompletionOnMainQueue(
            DMMenuBarVisibilityError(
                4,
                [NSString stringWithFormat:@"菜单栏系统接口异常：%@。已请求恢复。", exception.name]),
            completion);
        return nil;
    }
}

@end
