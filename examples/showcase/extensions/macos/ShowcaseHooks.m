// The showcase's macOS platform hooks (build.zig, `.macos.hooks`): logs what
// Oriel's app delegate, windows and WebViews report, and owns navigation to
// example.com (the App tab's "Platform hooks" link): it opens in the default
// browser from here, with a log line, instead of through Oriel's policy.
// Compiled by zig cc with ARC against the macOS SDK. The log lines start
// with "showcase.hooks:".

#import "oriel_hooks.h"

@interface ShowcaseHooks : NSObject <OrielPlatformHooks>
@property (nonatomic, strong) OrielHooksContext *context;
@end

@implementation ShowcaseHooks

- (void)registered:(OrielHooksContext *)context {
    self.context = context;
    NSLog(@"showcase.hooks: registered %@", context.name);
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSLog(@"showcase.hooks: applicationDidFinishLaunching (key window: %@)", self.context.keyWindow.title);
}

- (void)windowCreated:(NSWindow *)window label:(NSString *)label {
    NSLog(@"showcase.hooks: windowCreated window=%@", label);
}

- (void)windowWillClose:(NSWindow *)window label:(NSString *)label {
    NSLog(@"showcase.hooks: windowWillClose window=%@", label);
}

- (void)webViewConfiguration:(WKWebViewConfiguration *)configuration window:(NSString *)label {
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
    decidePolicyForNavigationAction:(WKNavigationAction *)action
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL;
    if (![url.host isEqualToString:@"example.com"]) return NO; // Oriel decides
    decisionHandler(WKNavigationActionPolicyCancel);
    NSLog(@"showcase.hooks: owned navigation to %@", url.absoluteString);
    [[NSWorkspace sharedWorkspace] openURL:url];
    return YES;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)flag {
    NSLog(@"showcase.hooks: applicationShouldHandleReopen visible=%d (left to Oriel)", flag);
    return NO;
}

- (BOOL)openURL:(NSURL *)url {
    NSLog(@"showcase.hooks: openURL %@ (left to oriel.deep_link)", url.absoluteString);
    return NO;
}

@end
