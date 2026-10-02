//! The native DOM's tests (zig build dom-test).
test {
    _ = @import("store.zig");
    _ = @import("selector.zig");
    _ = @import("html.zig");
}
