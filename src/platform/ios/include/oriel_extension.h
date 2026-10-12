// Oriel app extensions on iOS (docs/extensions.md): the protocol an app's
// Objective-C (or @objc Swift) class conforms to, and the objects Oriel
// passes it. Oriel defines OrielExtensionContext and OrielCall at run time
// (src/platform/apple/extensions.zig): only send them messages; don't
// subclass them or reference their class objects.
//
//   #import "oriel_extension.h"
//   @interface MyVision : NSObject <OrielAppExtension>
//   @end
//
// Declared in build.zig: .extensions = &.{.{ .name = "app.vision",
//   .ios = .{ .class = "MyVision", .sources = &.{b.path("ios/MyVision.m")} } }}

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What an extension may use outside a call.
@interface OrielExtensionContext : NSObject
/// The extension's name ("app.vision").
@property (nonatomic, readonly) NSString *name;
/// An event for Zig's onEvent handlers and the page (`extension:<name>`
/// with { name, data }; data is parsed when it is JSON). Any thread.
- (void)emit:(NSString *)name data:(NSData *)data;
@end

/// One call.
@interface OrielCall : OrielExtensionContext
/// YES once the caller cancelled or timed out: poll it in long work.
@property (nonatomic, readonly) BOOL cancelled;
@end

@protocol OrielAppExtension <NSObject>
/// One call, on the extension's own worker thread (one at a time unless the
/// build sets .concurrency): block as long as needed. Return the reply
/// (JSON by convention), or nil and an NSError: the caller gets
/// error.ExtensionFailed with "<domain>:<code>" and its description.
/// Don't throw Objective-C exceptions; dispatch to the main queue for UI.
- (nullable NSData *)callMethod:(NSString *)method
                          input:(NSData *)input
                           call:(OrielCall *)call
                          error:(NSError **)error;
@optional
/// Once, on the worker, before the first call.
- (void)load:(OrielExtensionContext *)context;
/// oriel.lifecycle on the main thread: "background", "foreground",
/// "memory_pressure" (level "moderate" or "critical"), "suspend", "resume",
/// "terminating". Return quickly.
- (void)lifecycle:(NSString *)event level:(nullable NSString *)level;
@end

NS_ASSUME_NONNULL_END
