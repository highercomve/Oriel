// Oriel platform hooks on iOS and macOS (docs/platform-hooks.md): the
// protocol an app's Objective-C (or @objc Swift) class conforms to, to take
// part in Oriel's app delegate, scene delegate, windows and WebKit delegates
// without replacing them. The Android counterpart is OrielAndroidExtension.
//
//   #import "oriel_hooks.h"
//   @interface MyHooks : NSObject <OrielPlatformHooks>
//   @end
//
// Declared in build.zig (the class needs a plain -init):
//   .ios = .{ .hooks = &.{.{ .class = "MyHooks",
//       .sources = &.{b.path("ios/MyHooks.m")} }} },
//   .macos = .{ .hooks = &.{.{ .class = "MyHooks",
//       .sources = &.{b.path("macos/MyHooks.m")} }} },
//
// The model:
// - Oriel constructs each class once at launch (alloc/init), in declaration
//   order, before the first scene or window, and keeps it for the process's
//   life. A class that is also an app extension (OrielAppExtension) and
//   listed in both places is constructed once: both get the same object.
// - Every method is optional and runs on the main thread. Oriel asks
//   respondsToSelector: once per method at launch.
// - Notifications ("...Created", "sceneDid...") go to every hook, in
//   declaration order, and return nothing.
// - Interceptions return BOOL. YES means the hook owns the request: it must
//   call the handler it was given exactly once (now or later, on the main
//   thread), and neither later hooks nor Oriel see the request. NO lets the
//   next hook decide, then Oriel, as if there were no hook. The first YES
//   wins.
// - Don't throw Objective-C exceptions: nothing catches them.
//
// Oriel defines OrielHooksContext at run time (src/platform/apple/hooks.zig):
// only send it messages; don't subclass it or reference its class object.

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

/// What a hook gets at registration. Keep it: its properties are evaluated
/// each time they are read.
@interface OrielHooksContext : NSObject
/// The hook's class name, as declared in build.zig ("MyHooks").
@property (nonatomic, readonly) NSString *name;
#if TARGET_OS_IPHONE
/// The view controller in front (the main window's, or what is presented
/// over it) to present native UI from; nil before the first scene shows
/// the main window.
@property (nonatomic, readonly, nullable) UIViewController *presentingViewController;
#else
/// The key window, else Oriel's main window; nil before it exists.
@property (nonatomic, readonly, nullable) NSWindow *keyWindow;
#endif
@end

@protocol OrielPlatformHooks <NSObject>
@optional

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

/// Once, right after -init, in declaration order, before the first scene
/// (iOS) or window (macOS).
- (void)registered:(OrielHooksContext *)context;

// ---------------------------------------------------------------------------
// WebViews (each Oriel window's WKWebView; `label` is the window's label,
// "main" for the main window). Windows drawn by -Dnative_ui have none.
// ---------------------------------------------------------------------------

/// Before the WKWebView is created, with Oriel's URL scheme handler and
/// bridge already set. Change preferences, the data store, the user agent,
/// add your own script message handlers or user scripts; don't replace the
/// userContentController, remove Oriel's handlers, or register a handler for
/// Oriel's URL scheme.
- (void)webViewConfiguration:(WKWebViewConfiguration *)configuration window:(NSString *)label;

/// After Oriel created the WKWebView and installed its navigation and UI
/// delegates and the bridge, before the first navigation. Keep Oriel's
/// delegates: use the interceptions below instead of replacing them.
- (void)webViewCreated:(WKWebView *)webView window:(NSString *)label;

/// The window is being destroyed: Oriel detaches its delegates and drops the
/// WKWebView right after this returns. Drop your references to it.
- (void)webViewDestroyed:(WKWebView *)webView window:(NSString *)label;

/// Interception: a navigation, before Oriel's policy (the security
/// settings: the app's own pages load, others open in the browser or are
/// blocked). YES: you own it and call decisionHandler exactly once
/// (WKNavigationActionPolicyAllow loads it in this WebView, Cancel drops
/// it). NO: the next hook, then Oriel, decides.
/// Allowing what Oriel would block bypasses its navigation rules (the
/// bridge still checks every call's origin against the app's own).
- (BOOL)webView:(WKWebView *)webView
    handleNavigationAction:(WKNavigationAction *)action
           decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
    NS_SWIFT_NAME(webView(_:handle:decisionHandler:));

/// (Named apart from WKNavigationDelegate's and WKUIDelegate's methods, so
/// one class can adopt this protocol and WebKit's.)
///
/// Interception: getUserMedia's camera or microphone, before Oriel's rule
/// (granted when the app declares the device and the page is the app's
/// own). YES: you own it and call decisionHandler exactly once (Grant,
/// Deny or Prompt). NO: the next hook, then Oriel, decides. The OS's own
/// permission (TCC) still applies after a grant.
- (BOOL)webView:(WKWebView *)webView
    handleMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin
                         initiatedByFrame:(WKFrameInfo *)frame
                                     type:(WKMediaCaptureType)type
                          decisionHandler:(void (^)(WKPermissionDecision))decisionHandler
    NS_SWIFT_NAME(webView(_:handleMediaCapturePermissionFor:initiatedBy:type:decisionHandler:));

// ---------------------------------------------------------------------------
// URLs and activities
// ---------------------------------------------------------------------------

/// Interception: a URL the system opens with the app (one of its URL
/// schemes; iOS: scene:openURLContexts: and the URLs a scene connects with,
/// macOS: the GetURL Apple Event and application:openURLs:). File URLs
/// (documents opened with the app) don't come here. YES consumes it; NO
/// leaves it to the next hook, then to oriel.deep_link as without hooks.
- (BOOL)openURL:(NSURL *)url;

/// Interception: a universal link, Handoff or other NSUserActivity (iOS:
/// scene:continueUserActivity: and the activities a scene connects with,
/// after sceneWillConnect:options:; macOS:
/// application:continueUserActivity:restorationHandler:). YES: handled.
/// Oriel itself handles none (its own scene requests never come here).
- (BOOL)continueUserActivity:(NSUserActivity *)activity;

// ---------------------------------------------------------------------------
// Remote notifications: what your own registerForRemoteNotifications call
// (and the aps-environment entitlement) produces, forwarded from Oriel's
// app delegate.
// ---------------------------------------------------------------------------

- (void)didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)token;
- (void)didFailToRegisterForRemoteNotificationsWithError:(NSError *)error;

#if TARGET_OS_IPHONE
// ---------------------------------------------------------------------------
// iOS: the app and its scenes
// ---------------------------------------------------------------------------

/// application:didFinishLaunchingWithOptions:, after registered: and before
/// Oriel opens the main window and runs the app's setup.
- (void)applicationDidFinishLaunching:(UIApplication *)application
                              options:(nullable NSDictionary<UIApplicationLaunchOptionsKey, id> *)options;

/// A scene connected; Oriel has just shown its window in it (when it has
/// one to show). Its URLs and activities follow (openURL:,
/// continueUserActivity:).
- (void)sceneWillConnect:(UIScene *)scene options:(UISceneConnectionOptions *)options;
/// Before Oriel detaches its window from the scene.
- (void)sceneDidDisconnect:(UIScene *)scene;
- (void)sceneDidBecomeActive:(UIScene *)scene;
- (void)sceneWillResignActive:(UIScene *)scene;
- (void)sceneWillEnterForeground:(UIScene *)scene;
- (void)sceneDidEnterBackground:(UIScene *)scene;
#else
// ---------------------------------------------------------------------------
// macOS: the app and its windows
// ---------------------------------------------------------------------------

/// applicationDidFinishLaunching:. AppKit sends it once the run loop starts:
/// after the main window opened and the app's setup ran.
- (void)applicationDidFinishLaunching:(NSNotification *)notification;

/// An Oriel window was created (before its page loads, before
/// webViewCreated:window:); it isn't on screen yet.
- (void)windowCreated:(NSWindow *)window label:(NSString *)label;
/// An Oriel window is closing (not when it is only hidden); after
/// webViewDestroyed:window:.
- (void)windowWillClose:(NSWindow *)window label:(NSString *)label;

/// Interception: a Dock icon click or a relaunch while running. YES:
/// handled (Oriel neither shows the main window nor calls
/// on_second_instance). NO: the next hook, then Oriel.
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)flag;
#endif

@end

NS_ASSUME_NONNULL_END
