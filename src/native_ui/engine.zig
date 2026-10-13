//! Select the UI engine at build time; the Zig mode has no JavaScript runtime.
const implementation = if (@import("build_options").zig_ui) @import("engine_zig.zig") else @import("engine_js.zig");
pub const Engine = implementation.Engine;
pub const Backend = implementation.Backend;
pub const Asset = implementation.Asset;
pub const FontSpec = implementation.FontSpec;
pub const Node = implementation.Node;
pub const Tree = implementation.Tree;
pub const drop = implementation.drop;
pub const inlineRefusal = if (@import("build_options").zig_ui) void else implementation.inlineRefusal;
pub const evalRefusal = if (@import("build_options").zig_ui) void else implementation.evalRefusal;
test {
    _ = implementation;
}
