//! interaction.zig compiled to WebAssembly for the JavaScript tests: their
//! fake hosts (js/test/engine-host.mjs) answer host.tabNext, clickFocuses,
//! activates and focusRing with the engine's own rules, as the real host
//! does (engine_js.zig). `zig build interaction-wasm`.
const std = @import("std");
const interaction = @import("interaction.zig");

const gpa = std.heap.wasm_allocator;
var platform: interaction.Platform = .{};

export fn alloc(len: usize) ?[*]u8 {
    const bytes = gpa.alloc(u8, len) catch return null;
    return bytes.ptr;
}

export fn free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

/// The host's platform JSON (os, fullKeyboardAccess, accent).
export fn set_platform(ptr: [*]const u8, len: usize) void {
    platform = interaction.Platform.parse(gpa, ptr[0..len]);
}

export fn tab_next(ptr: [*]const u8, len: usize, active: i32, back: bool) i32 {
    const at: ?usize = if (active >= 0) @intCast(active) else null;
    const next = interaction.tabNextJson(gpa, interaction.tabRule(platform), ptr[0..len], at, back) catch return -1;
    return if (next) |n| @intCast(n) else -1;
}

export fn is_scroll_key(ptr: [*]const u8, len: usize) bool {
    return interaction.scrollStep(ptr[0..len], false) != null;
}

export fn click_focuses(kind: u32) bool {
    return interaction.clickFocuses(interaction.tabRule(platform), interaction.kindFrom(kind), false);
}

export fn activates(ptr: [*]const u8, len: usize, down: bool, repeat: bool, button: bool, link: bool, checkable: bool) bool {
    return interaction.activates(ptr[0..len], down, repeat, button, link, checkable);
}

var ring_out: [8]f64 = undefined;

/// `[w, o, r, red, green, blue, alpha, halo]`, at the address returned, in
/// the page's accent (`has_accent`: r, g, b).
export fn focus_ring(kind: u32, has_accent: bool, red: f32, green: f32, blue: f32) [*]f64 {
    var p = platform;
    p.accent = if (has_accent) interaction.accentOf(red, green, blue) else null;
    const r = interaction.ring(p, interaction.ringKindFrom(kind));
    ring_out = interaction.ringNumbers(r);
    return &ring_out;
}
