//! Synthetic keyboard input into other apps.
//!
//! - wlroots compositors (Hyprland, Sway…): zwp_virtual_keyboard_v1, which
//!   needs an XKB keymap from libxkbcommon.
//! - X11: XTest.
//! - GNOME/KDE Wayland: libei via the RemoteDesktop portal (future).

const std = @import("std");
const wayland = @import("wayland");
const zwp = wayland.client.zwp;
const wl = wayland.client.wl;
const Globals = @import("wayland_globals.zig").Globals;
const oriel = @import("../oriel.zig");
const global_shortcut = @import("global_shortcut.zig");

pub const xkb = @cImport(@cInclude("xkbcommon/xkbcommon.h"));
pub const x11 = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/keysym.h");
    @cInclude("X11/extensions/XTest.h");
});

pub const EVDEV = struct {
    pub const KEY_RESERVED = 0;
    pub const KEY_ESC = 1;
    pub const KEY_1 = 2;
    pub const KEY_2 = 3;
    pub const KEY_3 = 4;
    pub const KEY_4 = 5;
    pub const KEY_5 = 6;
    pub const KEY_6 = 7;
    pub const KEY_7 = 8;
    pub const KEY_8 = 9;
    pub const KEY_9 = 10;
    pub const KEY_0 = 11;
    pub const KEY_MINUS = 12;
    pub const KEY_EQUAL = 13;
    pub const KEY_BACKSPACE = 14;
    pub const KEY_TAB = 15;
    pub const KEY_Q = 16;
    pub const KEY_W = 17;
    pub const KEY_E = 18;
    pub const KEY_R = 19;
    pub const KEY_T = 20;
    pub const KEY_Y = 21;
    pub const KEY_U = 22;
    pub const KEY_I = 23;
    pub const KEY_O = 24;
    pub const KEY_P = 25;
    pub const KEY_LEFTBRACE = 26;
    pub const KEY_RIGHTBRACE = 27;
    pub const KEY_ENTER = 28;
    pub const KEY_LEFTCTRL = 29;
    pub const KEY_A = 30;
    pub const KEY_S = 31;
    pub const KEY_D = 32;
    pub const KEY_F = 33;
    pub const KEY_G = 34;
    pub const KEY_H = 35;
    pub const KEY_J = 36;
    pub const KEY_K = 37;
    pub const KEY_L = 38;
    pub const KEY_SEMICOLON = 39;
    pub const KEY_APOSTROPHE = 40;
    pub const KEY_GRAVE = 41;
    pub const KEY_LEFTSHIFT = 42;
    pub const KEY_BACKSLASH = 43;
    pub const KEY_Z = 44;
    pub const KEY_X = 45;
    pub const KEY_C = 46;
    pub const KEY_V = 47;
    pub const KEY_B = 48;
    pub const KEY_N = 49;
    pub const KEY_M = 50;
    pub const KEY_COMMA = 51;
    pub const KEY_DOT = 52;
    pub const KEY_SLASH = 53;
    pub const KEY_RIGHTSHIFT = 54;
    pub const KEY_LEFTALT = 56;
    pub const KEY_SPACE = 57;
    pub const KEY_CAPSLOCK = 58;
    pub const KEY_F1 = 59;
    pub const KEY_F2 = 60;
    pub const KEY_F3 = 61;
    pub const KEY_F4 = 62;
    pub const KEY_F5 = 63;
    pub const KEY_F6 = 64;
    pub const KEY_F7 = 65;
    pub const KEY_F8 = 66;
    pub const KEY_F9 = 67;
    pub const KEY_F10 = 68;
    pub const KEY_UP = 103;
    pub const KEY_PAGEUP = 104;
    pub const KEY_LEFT = 105;
    pub const KEY_RIGHT = 106;
    pub const KEY_END = 107;
    pub const KEY_DOWN = 108;
    pub const KEY_PAGEDOWN = 109;
    pub const KEY_INSERT = 110;
    pub const KEY_DELETE = 111;
    pub const KEY_LEFTMETA = 125;
};

/// The default XKB keymap as text, ready to hand to the virtual keyboard.
pub fn defaultKeymap(gpa: std.mem.Allocator) ![]u8 {
    const ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse return error.XkbContext;
    defer xkb.xkb_context_unref(ctx);
    const keymap = xkb.xkb_keymap_new_from_names(ctx, null, xkb.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return error.XkbKeymap;
    defer xkb.xkb_keymap_unref(keymap);
    const text = xkb.xkb_keymap_get_as_string(keymap, xkb.XKB_KEYMAP_FORMAT_TEXT_V1) orelse return error.XkbKeymapString;
    defer std.c.free(text);
    return gpa.dupe(u8, std.mem.span(text));
}

/// Whether the X server (or XWayland) supports XTest.
pub fn xtestAvailable() bool {
    const display = x11.XOpenDisplay(null) orelse return false;
    defer _ = x11.XCloseDisplay(display);
    var ev: c_int = 0;
    var er: c_int = 0;
    var major: c_int = 0;
    var minor: c_int = 0;
    return x11.XTestQueryExtension(display, &ev, &er, &major, &minor) != 0;
}

pub fn evdevForKey(name: []const u8) ?u32 {
    if (std.ascii.eqlIgnoreCase(name, "a")) return EVDEV.KEY_A;
    if (std.ascii.eqlIgnoreCase(name, "b")) return EVDEV.KEY_B;
    if (std.ascii.eqlIgnoreCase(name, "c")) return EVDEV.KEY_C;
    if (std.ascii.eqlIgnoreCase(name, "d")) return EVDEV.KEY_D;
    if (std.ascii.eqlIgnoreCase(name, "e")) return EVDEV.KEY_E;
    if (std.ascii.eqlIgnoreCase(name, "f")) return EVDEV.KEY_F;
    if (std.ascii.eqlIgnoreCase(name, "g")) return EVDEV.KEY_G;
    if (std.ascii.eqlIgnoreCase(name, "h")) return EVDEV.KEY_H;
    if (std.ascii.eqlIgnoreCase(name, "i")) return EVDEV.KEY_I;
    if (std.ascii.eqlIgnoreCase(name, "j")) return EVDEV.KEY_J;
    if (std.ascii.eqlIgnoreCase(name, "k")) return EVDEV.KEY_K;
    if (std.ascii.eqlIgnoreCase(name, "l")) return EVDEV.KEY_L;
    if (std.ascii.eqlIgnoreCase(name, "m")) return EVDEV.KEY_M;
    if (std.ascii.eqlIgnoreCase(name, "n")) return EVDEV.KEY_N;
    if (std.ascii.eqlIgnoreCase(name, "o")) return EVDEV.KEY_O;
    if (std.ascii.eqlIgnoreCase(name, "p")) return EVDEV.KEY_P;
    if (std.ascii.eqlIgnoreCase(name, "q")) return EVDEV.KEY_Q;
    if (std.ascii.eqlIgnoreCase(name, "r")) return EVDEV.KEY_R;
    if (std.ascii.eqlIgnoreCase(name, "s")) return EVDEV.KEY_S;
    if (std.ascii.eqlIgnoreCase(name, "t")) return EVDEV.KEY_T;
    if (std.ascii.eqlIgnoreCase(name, "u")) return EVDEV.KEY_U;
    if (std.ascii.eqlIgnoreCase(name, "v")) return EVDEV.KEY_V;
    if (std.ascii.eqlIgnoreCase(name, "w")) return EVDEV.KEY_W;
    if (std.ascii.eqlIgnoreCase(name, "x")) return EVDEV.KEY_X;
    if (std.ascii.eqlIgnoreCase(name, "y")) return EVDEV.KEY_Y;
    if (std.ascii.eqlIgnoreCase(name, "z")) return EVDEV.KEY_Z;
    if (std.ascii.eqlIgnoreCase(name, "1")) return EVDEV.KEY_1;
    if (std.ascii.eqlIgnoreCase(name, "2")) return EVDEV.KEY_2;
    if (std.ascii.eqlIgnoreCase(name, "3")) return EVDEV.KEY_3;
    if (std.ascii.eqlIgnoreCase(name, "4")) return EVDEV.KEY_4;
    if (std.ascii.eqlIgnoreCase(name, "5")) return EVDEV.KEY_5;
    if (std.ascii.eqlIgnoreCase(name, "6")) return EVDEV.KEY_6;
    if (std.ascii.eqlIgnoreCase(name, "7")) return EVDEV.KEY_7;
    if (std.ascii.eqlIgnoreCase(name, "8")) return EVDEV.KEY_8;
    if (std.ascii.eqlIgnoreCase(name, "9")) return EVDEV.KEY_9;
    if (std.ascii.eqlIgnoreCase(name, "0")) return EVDEV.KEY_0;
    if (std.ascii.eqlIgnoreCase(name, "space")) return EVDEV.KEY_SPACE;
    if (std.ascii.eqlIgnoreCase(name, "enter") or std.ascii.eqlIgnoreCase(name, "return")) return EVDEV.KEY_ENTER;
    if (std.ascii.eqlIgnoreCase(name, "tab")) return EVDEV.KEY_TAB;
    if (std.ascii.eqlIgnoreCase(name, "backspace")) return EVDEV.KEY_BACKSPACE;
    if (std.ascii.eqlIgnoreCase(name, "escape") or std.ascii.eqlIgnoreCase(name, "esc")) return EVDEV.KEY_ESC;
    if (std.ascii.eqlIgnoreCase(name, "insert")) return EVDEV.KEY_INSERT;
    if (std.ascii.eqlIgnoreCase(name, "delete") or std.ascii.eqlIgnoreCase(name, "del")) return EVDEV.KEY_DELETE;
    if (std.ascii.eqlIgnoreCase(name, "up")) return EVDEV.KEY_UP;
    if (std.ascii.eqlIgnoreCase(name, "down")) return EVDEV.KEY_DOWN;
    if (std.ascii.eqlIgnoreCase(name, "left")) return EVDEV.KEY_LEFT;
    if (std.ascii.eqlIgnoreCase(name, "right")) return EVDEV.KEY_RIGHT;
    return null;
}

pub const WaylandInput = struct {
    globals: Globals,
    manager: *zwp.VirtualKeyboardManagerV1,
    seat: *wl.Seat,
    vk: *zwp.VirtualKeyboardV1,

    /// Initialize in place: `Globals.init` registers a registry listener
    /// that points at `self.globals`, so the struct must not be moved (or
    /// returned by value) afterwards.
    pub fn init(self: *WaylandInput, gpa: std.mem.Allocator) !void {
        try self.globals.init(gpa);
        errdefer self.globals.deinit();

        self.manager = (try self.globals.bind(zwp.VirtualKeyboardManagerV1, 1)) orelse return error.NoVirtualKeyboardManager;
        errdefer self.manager.destroy();

        self.seat = (try self.globals.bind(wl.Seat, 7)) orelse return error.NoSeat;
        errdefer self.seat.destroy();

        self.vk = try self.manager.createVirtualKeyboard(self.seat);
        errdefer self.vk.destroy();

        const keymap_str = try defaultKeymap(gpa);
        defer gpa.free(keymap_str);

        const fd = try std.posix.memfd_create("oriel-keymap", 0);
        defer _ = std.c.close(fd);
        const written = std.c.write(fd, keymap_str.ptr, keymap_str.len);
        if (written < 0) return error.KeymapWriteFailed;

        self.vk.keymap(.xkb_v1, fd, @intCast(keymap_str.len));
        if (self.globals.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    }

    pub fn deinit(self: *WaylandInput) void {
        self.vk.destroy();
        self.seat.destroy();
        self.manager.destroy();
        self.globals.deinit();
    }
};

/// Inject a key combo into the active application.
pub fn keyCombo(combo: []const u8) !void {
    const is_wayland = std.c.getenv("WAYLAND_DISPLAY") != null;
    if (is_wayland) {
        var wl_input: WaylandInput = undefined;
        wl_input.init(std.heap.c_allocator) catch |err| {
            if (xtestAvailable()) return keyComboX11(combo);
            return err;
        };
        defer wl_input.deinit();

        const parsed = try global_shortcut.parseTrigger(combo);
        const ev_key = evdevForKey(parsed.key) orelse return error.UnknownKey;

        if (parsed.modifiers.ctrl) wl_input.vk.key(0, EVDEV.KEY_LEFTCTRL, 1);
        if (parsed.modifiers.alt) wl_input.vk.key(0, EVDEV.KEY_LEFTALT, 1);
        if (parsed.modifiers.shift) wl_input.vk.key(0, EVDEV.KEY_LEFTSHIFT, 1);
        if (parsed.modifiers.super) wl_input.vk.key(0, EVDEV.KEY_LEFTMETA, 1);

        wl_input.vk.key(0, ev_key, 1);
        wl_input.vk.key(0, ev_key, 0);

        if (parsed.modifiers.super) wl_input.vk.key(0, EVDEV.KEY_LEFTMETA, 0);
        if (parsed.modifiers.shift) wl_input.vk.key(0, EVDEV.KEY_LEFTSHIFT, 0);
        if (parsed.modifiers.alt) wl_input.vk.key(0, EVDEV.KEY_LEFTALT, 0);
        if (parsed.modifiers.ctrl) wl_input.vk.key(0, EVDEV.KEY_LEFTCTRL, 0);

        _ = wl_input.globals.display.flush();
        return;
    }

    return keyComboX11(combo);
}

pub fn keyComboX11(combo: []const u8) !void {
    const disp = x11.XOpenDisplay(null) orelse return error.XOpenDisplay;
    defer _ = x11.XCloseDisplay(disp);

    const parsed = try global_shortcut.parseTrigger(combo);

    var key_buf: [64]u8 = undefined;
    const key_z = try std.fmt.bufPrintSentinel(&key_buf, "{s}", .{parsed.key}, 0);
    var sym = x11.XStringToKeysym(key_z.ptr);
    if (sym == 0 and parsed.key.len == 1) {
        sym = parsed.key[0];
    }
    if (sym == 0) return error.UnknownKey;

    const kc = x11.XKeysymToKeycode(disp, sym);
    if (kc == 0) return error.KeycodeNotFound;

    const ctrl_kc = x11.XKeysymToKeycode(disp, x11.XK_Control_L);
    const alt_kc = x11.XKeysymToKeycode(disp, x11.XK_Alt_L);
    const shift_kc = x11.XKeysymToKeycode(disp, x11.XK_Shift_L);
    const super_kc = x11.XKeysymToKeycode(disp, x11.XK_Super_L);

    if (parsed.modifiers.ctrl and ctrl_kc != 0) _ = x11.XTestFakeKeyEvent(disp, ctrl_kc, 1, 0);
    if (parsed.modifiers.alt and alt_kc != 0) _ = x11.XTestFakeKeyEvent(disp, alt_kc, 1, 0);
    if (parsed.modifiers.shift and shift_kc != 0) _ = x11.XTestFakeKeyEvent(disp, shift_kc, 1, 0);
    if (parsed.modifiers.super and super_kc != 0) _ = x11.XTestFakeKeyEvent(disp, super_kc, 1, 0);

    _ = x11.XTestFakeKeyEvent(disp, kc, 1, 0);
    _ = x11.XTestFakeKeyEvent(disp, kc, 0, 0);

    if (parsed.modifiers.super and super_kc != 0) _ = x11.XTestFakeKeyEvent(disp, super_kc, 0, 0);
    if (parsed.modifiers.shift and shift_kc != 0) _ = x11.XTestFakeKeyEvent(disp, shift_kc, 0, 0);
    if (parsed.modifiers.alt and alt_kc != 0) _ = x11.XTestFakeKeyEvent(disp, alt_kc, 0, 0);
    if (parsed.modifiers.ctrl and ctrl_kc != 0) _ = x11.XTestFakeKeyEvent(disp, ctrl_kc, 0, 0);

    _ = x11.XFlush(disp);
}

/// Type plain text into the currently focused window.
pub fn typeText(text: []const u8) !void {
    const is_wayland = std.c.getenv("WAYLAND_DISPLAY") != null;
    if (is_wayland) {
        var wl_input: WaylandInput = undefined;
        wl_input.init(std.heap.c_allocator) catch |err| {
            if (xtestAvailable()) return typeTextX11(text);
            return err;
        };
        defer wl_input.deinit();

        for (text) |c| {
            var ev_key: u32 = 0;
            var need_shift = false;
            if (c >= 'a' and c <= 'z') {
                ev_key = evdevForKey(&[1]u8{c}) orelse continue;
            } else if (c >= 'A' and c <= 'Z') {
                ev_key = evdevForKey(&[1]u8{std.ascii.toLower(c)}) orelse continue;
                need_shift = true;
            } else if (c >= '0' and c <= '9') {
                ev_key = evdevForKey(&[1]u8{c}) orelse continue;
            } else if (c == ' ') {
                ev_key = EVDEV.KEY_SPACE;
            } else if (c == '\n') {
                ev_key = EVDEV.KEY_ENTER;
            } else if (c == '\t') {
                ev_key = EVDEV.KEY_TAB;
            } else {
                continue;
            }

            if (need_shift) wl_input.vk.key(0, EVDEV.KEY_LEFTSHIFT, 1);
            wl_input.vk.key(0, ev_key, 1);
            wl_input.vk.key(0, ev_key, 0);
            if (need_shift) wl_input.vk.key(0, EVDEV.KEY_LEFTSHIFT, 0);
        }
        _ = wl_input.globals.display.flush();
        return;
    }

    return typeTextX11(text);
}

pub fn typeTextX11(text: []const u8) !void {
    const disp = x11.XOpenDisplay(null) orelse return error.XOpenDisplay;
    defer _ = x11.XCloseDisplay(disp);

    const shift_kc = x11.XKeysymToKeycode(disp, x11.XK_Shift_L);

    for (text) |c| {
        var sym: x11.KeySym = 0;
        var need_shift = false;

        if (c == '\n') {
            sym = x11.XK_Return;
        } else if (c == '\t') {
            sym = x11.XK_Tab;
        } else if (c >= 'A' and c <= 'Z') {
            sym = c;
            need_shift = true;
        } else if (c >= 'a' and c <= 'z') {
            sym = c;
        } else if (c >= '0' and c <= '9') {
            sym = c;
        } else if (c == ' ') {
            sym = x11.XK_space;
        } else {
            sym = c;
            const shifted_chars = "!@#$%^&*()_+{}|:\"<>?~";
            if (std.mem.indexOfScalar(u8, shifted_chars, c) != null) {
                need_shift = true;
            }
        }

        const kc = x11.XKeysymToKeycode(disp, sym);
        if (kc == 0) continue;

        if (need_shift and shift_kc != 0) _ = x11.XTestFakeKeyEvent(disp, shift_kc, 1, 0);
        _ = x11.XTestFakeKeyEvent(disp, kc, 1, 0);
        _ = x11.XTestFakeKeyEvent(disp, kc, 0, 0);
        if (need_shift and shift_kc != 0) _ = x11.XTestFakeKeyEvent(disp, shift_kc, 0, 0);
    }
    _ = x11.XFlush(disp);
}

fn sleepMs(ms: u64) void {
    const ts: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}

/// Synthesize a copy command (Ctrl+C).
pub fn copy() !void {
    try keyCombo("ctrl+c");
    sleepMs(80);
}

/// Synthesize a paste command (Ctrl+V).
pub fn paste() !void {
    try keyCombo("ctrl+v");
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const keymap = try defaultKeymap(gpa);
    defer gpa.free(keymap);

    var globals: Globals = undefined;
    const wayland_ok = if (globals.init(gpa)) |_| true else |_| false;
    defer if (wayland_ok) globals.deinit();

    var vk_bound = false;
    if (wayland_ok) {
        if (try globals.bind(zwp.VirtualKeyboardManagerV1, 1)) |manager| {
            vk_bound = true;
            manager.destroy();
        }
    }
    const xtest = xtestAvailable();

    return .{
        .module = "input",
        .ok = vk_bound or xtest,
        .detail = try std.fmt.allocPrint(gpa, "xkbcommon keymap {d} B; zwp_virtual_keyboard_manager_v1 {s}; XTest {s}", .{
            keymap.len,
            if (vk_bound) "bound" else if (wayland_ok) "not offered" else "no Wayland session",
            if (xtest) "available" else "unavailable",
        }),
    };
}

test "evdev key mapping" {
    try std.testing.expectEqual(@as(?u32, EVDEV.KEY_C), evdevForKey("c"));
    try std.testing.expectEqual(@as(?u32, EVDEV.KEY_V), evdevForKey("V"));
    try std.testing.expectEqual(@as(?u32, EVDEV.KEY_ENTER), evdevForKey("enter"));
    try std.testing.expectEqual(@as(?u32, EVDEV.KEY_INSERT), evdevForKey("Insert"));
    try std.testing.expect(evdevForKey("unknown_key_xyz") == null);
}

test "headless x11 xtest input synthesis" {
    // Only run when headlessly running in Xvfb
    if (std.c.getenv("ORIEL_HEADLESS_INNER") == null) return;
    if (!xtestAvailable()) return;

    const disp = x11.XOpenDisplay(null) orelse return;
    defer _ = x11.XCloseDisplay(disp);

    const root = x11.XDefaultRootWindow(disp);
    const win = x11.XCreateSimpleWindow(disp, root, 0, 0, 100, 100, 0, 0, 0);
    defer _ = x11.XDestroyWindow(disp, win);

    _ = x11.XSelectInput(disp, win, x11.KeyPressMask | x11.KeyReleaseMask);
    _ = x11.XMapWindow(disp, win);
    _ = x11.XSetInputFocus(disp, win, x11.RevertToParent, x11.CurrentTime);
    _ = x11.XFlush(disp);

    try keyComboX11("ctrl+v");

    var received_v_press = false;
    var received_ctrl_press = false;

    var count: usize = 0;
    while (count < 20) : (count += 1) {
        while (x11.XPending(disp) > 0) {
            var ev: x11.XEvent = undefined;
            _ = x11.XNextEvent(disp, &ev);
            if (ev.type == x11.KeyPress) {
                const sym = x11.XLookupKeysym(&ev.xkey, 0);
                if (sym == 'v' or sym == 'V') received_v_press = true;
                if (sym == x11.XK_Control_L) received_ctrl_press = true;
            }
        }
        if (received_v_press and received_ctrl_press) break;
        sleepMs(10);
    }

    try std.testing.expect(received_v_press);
    try std.testing.expect(received_ctrl_press);
}
