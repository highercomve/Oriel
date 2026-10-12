// The "showcase.echo" app extension on iOS (build.zig, `.extensions`): the
// contract of src/echo_desktop.zig and android/EchoExtension.kt. `reverse`
// takes {"text": "..."}, answers {"text": <reversed>, "platform", "device"}
// and emits it as the `reversed` event. Compiled by zig cc with ARC.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "oriel_extension.h"

@interface ShowcaseEchoExtension : NSObject <OrielAppExtension>
@end

@implementation ShowcaseEchoExtension

- (void)load:(OrielExtensionContext *)context {
    NSLog(@"%@: loaded", context.name);
}

- (nullable NSData *)callMethod:(NSString *)method input:(NSData *)input call:(OrielCall *)call error:(NSError **)error {
    if (![method isEqualToString:@"reverse"]) {
        if (error) *error = [NSError errorWithDomain:@"unknown_method" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"showcase.echo has no method %@", method]}];
        return nil;
    }
    id args = [NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
    NSString *text = [args isKindOfClass:[NSDictionary class]] ? args[@"text"] : nil;
    if (![text isKindOfClass:[NSString class]]) {
        if (error) *error = [NSError errorWithDomain:@"bad_input" code:1 userInfo:@{NSLocalizedDescriptionKey: @"expected {\"text\": \"...\"}"}];
        return nil;
    }
    // By composed character, so emoji stay whole.
    NSMutableString *reversed = [NSMutableString stringWithCapacity:text.length];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences | NSStringEnumerationReverse
                          usingBlock:^(NSString *s, NSRange r, NSRange er, BOOL *stop) { [reversed appendString:s]; }];
    __block NSString *device = @"iOS";
    // UIDevice is main-thread API.
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIDevice *d = [UIDevice currentDevice];
        device = [NSString stringWithFormat:@"%@ (%@ %@)", d.model, d.systemName, d.systemVersion];
    });
    NSDictionary *reply = @{@"text": reversed, @"platform": @"Objective-C on iOS", @"device": device};
    NSData *data = [NSJSONSerialization dataWithJSONObject:reply options:0 error:error];
    if (data) [call emit:@"reversed" data:data];
    return data;
}

- (void)lifecycle:(NSString *)event level:(nullable NSString *)level {
    NSLog(@"showcase.echo: lifecycle %@%@", event, level ? [NSString stringWithFormat:@" (%@)", level] : @"");
}

@end
