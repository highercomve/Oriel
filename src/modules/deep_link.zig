//! Deep links: the app's custom URL schemes (e.g. `myapp://...`), received
//! at cold start and while running, on every platform.
//!
//! The shells hand each URL the OS gives them to `deep_link/delivery.zig`
//! (one implementation for every platform): it reaches `onOpen` and the
//! page's `deep-link` event.

/// Built for this target (docs/modules.md, "Availability").
pub const available = true;

const target = @import("../core/target.zig");
const common = @import("deep_link/common.zig");
const delivery = @import("deep_link/delivery.zig");

comptime {
    if (target.os == .other) @compileError("deep_link is not supported on " ++ target.name);
}

pub const validate = common.validate;
pub const ValidationError = common.ValidationError;
pub const max_url_len = common.max_url_len;

pub const onOpen = delivery.onOpen;
pub const current = delivery.current;
pub const deliver = delivery.deliver;
pub const check = delivery.check;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(delivery);
}
