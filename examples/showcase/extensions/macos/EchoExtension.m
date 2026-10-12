// "showcase.echo" in Objective-C on macOS (build.zig, -Dobjc_echo: the
// extension's `.macos = .{ .objc = ... }` instead of the Zig desktop one):
// the contract of src/echo_desktop.zig and ios/EchoExtension.m, through the
// same OrielAppExtension protocol and runtime as on iOS. Compiled by zig cc
// with ARC against the macOS SDK.

#import <Foundation/Foundation.h>
#import "oriel_extension.h"

@interface ShowcaseMacEchoExtension : NSObject <OrielAppExtension>
@end

@implementation ShowcaseMacEchoExtension

- (void)load:(OrielExtensionContext *)context {
    NSLog(@"%@: loaded (Objective-C on macOS)", context.name);
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
    NSMutableString *reversed = [NSMutableString stringWithCapacity:text.length];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences | NSStringEnumerationReverse
                          usingBlock:^(NSString *s, NSRange r, NSRange er, BOOL *stop) { [reversed appendString:s]; }];
    NSString *device = [NSString stringWithFormat:@"macOS %@", [NSProcessInfo processInfo].operatingSystemVersionString];
    NSDictionary *reply = @{@"text": reversed, @"platform": @"Objective-C on macOS", @"device": device};
    NSData *data = [NSJSONSerialization dataWithJSONObject:reply options:0 error:error];
    if (data) [call emit:@"reversed" data:data];
    return data;
}

@end
