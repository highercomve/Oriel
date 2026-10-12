// The bridging header of an app's Swift sources on iOS and macOS
// (`.ios.hooks[].swift_sources`, `.macos.hooks[].swift_sources`,
// `AppOptions.extensions[].ios.swift_sources`): both of Oriel's protocols,
// so one Swift class can conform to OrielAppExtension and
// OrielPlatformHooks. build/swift.zig passes it to swiftc.

#import "oriel_extension.h"
#import "oriel_hooks.h"
