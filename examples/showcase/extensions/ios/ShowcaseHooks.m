// The showcase's iOS platform hooks (build.zig, `.ios.hooks`): logs what
// Oriel's app and scene delegates and WebViews report, and owns navigation
// to example.com (the App tab's "Platform hooks" link) by showing it in an
// in-app Safari sheet instead of Oriel's default (Safari, the app). Compiled
// by zig cc with ARC. The log lines start with "showcase.hooks:".

#import <SafariServices/SafariServices.h>
#import "oriel_hooks.h"

@interface ShowcaseHooks : NSObject <OrielPlatformHooks>
@property (nonatomic, strong) OrielHooksContext *context;
@end

@implementation ShowcaseHooks

- (void)registered:(OrielHooksContext *)context {
    self.context = context;
    NSLog(@"showcase.hooks: registered %@", context.name);
}

- (void)applicationDidFinishLaunching:(UIApplication *)application options:(NSDictionary *)options {
    NSLog(@"showcase.hooks: applicationDidFinishLaunching (%lu launch options)", (unsigned long)options.count);
}

- (void)sceneWillConnect:(UIScene *)scene options:(UISceneConnectionOptions *)options {
    NSLog(@"showcase.hooks: sceneWillConnect %@", scene.session.persistentIdentifier);
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    NSLog(@"showcase.hooks: sceneDidBecomeActive");
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    NSLog(@"showcase.hooks: sceneDidEnterBackground");
}

- (void)webViewConfiguration:(WKWebViewConfiguration *)configuration window:(NSString *)label {
    // An app-specific user agent suffix, for every window.
    configuration.applicationNameForUserAgent = @"OrielShowcase";
    NSLog(@"showcase.hooks: webViewConfiguration window=%@", label);
}

- (void)webViewCreated:(WKWebView *)webView window:(NSString *)label {
    NSLog(@"showcase.hooks: webViewCreated window=%@", label);
}

- (void)webViewDestroyed:(WKWebView *)webView window:(NSString *)label {
    NSLog(@"showcase.hooks: webViewDestroyed window=%@", label);
}

- (BOOL)webView:(WKWebView *)webView
    handleNavigationAction:(WKNavigationAction *)action
           decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL;
    if (![url.host isEqualToString:@"example.com"]) return NO; // Oriel decides
    decisionHandler(WKNavigationActionPolicyCancel);
    UIViewController *front = self.context.presentingViewController;
    NSLog(@"showcase.hooks: owned navigation to %@", url.absoluteString);
    if (front) [front presentViewController:[[SFSafariViewController alloc] initWithURL:url] animated:YES completion:nil];
    return YES;
}

- (BOOL)openURL:(NSURL *)url {
    NSLog(@"showcase.hooks: openURL %@ (left to oriel.deep_link)", url.absoluteString);
    return NO;
}

- (BOOL)continueUserActivity:(NSUserActivity *)activity {
    NSLog(@"showcase.hooks: continueUserActivity %@", activity.activityType);
    return NO;
}

@end
