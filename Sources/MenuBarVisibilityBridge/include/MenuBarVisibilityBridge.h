#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Always delivers asynchronously on the main queue. This function only dispatches
/// a callback; it never loads MenuBarClientCore or changes menu bar visibility.
FOUNDATION_EXPORT void DMDeliverMenuBarVisibilityCompletionOnMainQueue(
    NSError * _Nullable error, void (^completion)(NSError * _Nullable))
    NS_SWIFT_NAME(deliverMenuBarVisibilityCompletionOnMainQueue(error:completion:));

/// Owns one native menu bar visibility request. Calling invalidate more than once is safe.
@interface DMMenuBarVisibilityAssertion : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (void)invalidate;
@end

@interface DMMenuBarVisibility : NSObject
+ (BOOL)supportsHiding NS_SWIFT_NAME(supportsHiding());
+ (NSString *)diagnosticSummary NS_SWIFT_NAME(diagnosticSummary());
/// The completion is always invoked asynchronously on the main queue, including failures.
+ (nullable DMMenuBarVisibilityAssertion *)beginAllowingBundles:(NSArray<NSString *> *)bundleIDs
                                                   systemItems:(NSArray<NSNumber *> *)systemItems
                                                    completion:(void (^)(NSError * _Nullable))completion
    NS_SWIFT_NAME(begin(allowing:systemItems:completion:));
@end

NS_ASSUME_NONNULL_END
