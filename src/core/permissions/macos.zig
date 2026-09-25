//! Placeholder backend: reports `unknown` and asks nothing yet.

const common = @import("common.zig");

pub fn status(kind: common.Kind) common.Status {
    _ = kind;
    return .unknown;
}

pub fn request(kind: common.Kind, done: *const fn (common.Kind, common.Status) void) void {
    done(kind, status(kind));
}

pub fn openSettings(kind: common.Kind) bool {
    _ = kind;
    return false;
}
