//! System-wide hotkeys.
//!
//! - Wayland: org.freedesktop.portal.GlobalShortcuts (over GDBus). The
//!   compositor owns the key bindings: we create a portal session, bind our
//!   shortcuts to it, and react to its `Activated` signal. There is no X11
//!   fallback on Wayland: XGrabKey only fires while an XWayland window has
//!   focus, which is useless for a global hotkey.
//! - X11: XGrabKey + event watch on X connection fd in the GLib main loop.

const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");
const gobject = @import("gobject");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

const log = std.log.scoped(.oriel);

pub const x11 = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/keysym.h");
});

pub const Modifiers = common.Modifiers;
pub const Shortcut = common.Shortcut;
pub const ParsedTrigger = common.ParsedTrigger;
pub const Callback = common.Callback;
pub const parseTrigger = common.parseTrigger;
pub const vkFor = common.vkFor;

pub const Registered = struct {
    shortcut: Shortcut,
    callback: Callback,
    keycode: u8 = 0,
    mask: c_uint = 0,
};

var shortcuts: std.ArrayList(Registered) = .empty;
var x11_display: ?*x11.Display = null;
var x11_source_id: c_uint = 0;

const portal_bus = "org.freedesktop.portal.Desktop";
const portal_path = "/org/freedesktop/portal/desktop";
const portal_iface = "org.freedesktop.portal.GlobalShortcuts";
const request_iface = "org.freedesktop.portal.Request";
const session_iface = "org.freedesktop.portal.Session";

/// Timeout for CreateSession: the portal answers it without user interaction.
const create_session_timeout_ms = 5000;

/// Live GlobalShortcuts portal session (Wayland only).
const Portal = struct {
    conn: *gio.DBusConnection,
    /// Session object path, owned (gpa).
    session: [:0]u8,
    gpa: std.mem.Allocator,
    activated_sub: c_uint = 0,
    /// Idle source that (re)binds the shortcut list; coalesces registrations.
    bind_idle: c_uint = 0,
    /// Response subscription of the BindShortcuts request in flight, if any.
    bind_sub: c_uint = 0,
    /// The shortcut list changed while a bind was in flight: bind again.
    bind_dirty: bool = false,
};
var portal: ?Portal = null;


/// Resolve a key name from a trigger to an X keysym. Accepts keysym names
/// in any case ("space", "Space", "F12", "g", "G") and a few aliases
/// ("enter", "esc", "del"). Letters resolve to their lowercase keysym, which
/// is what both XGrabKey and the portal's trigger format expect.
/// Pure: `XStringToKeysym` needs no X connection.
pub fn keysymFor(name: []const u8) !x11.KeySym {
    const aliases = [_]struct { []const u8, [:0]const u8 }{
        .{ "enter", "Return" },
        .{ "esc", "Escape" },
        .{ "del", "Delete" },
        .{ "backspace", "BackSpace" },
        .{ "pageup", "Prior" },
        .{ "pagedown", "Next" },
    };
    for (aliases) |a| {
        if (std.ascii.eqlIgnoreCase(name, a[0])) return x11.XStringToKeysym(a[1].ptr);
    }
    if (name.len == 0 or name.len > 63) return error.UnknownKey;

    var buf: [64]u8 = undefined;
    if (name.len == 1 and std.ascii.isAlphabetic(name[0])) {
        return x11.XStringToKeysym((try std.fmt.bufPrintZ(&buf, "{c}", .{std.ascii.toLower(name[0])})).ptr);
    }
    // Keysym names are case-sensitive: try as given, lowercase ("space"),
    // then capitalized ("Return", "Tab", "Escape").
    const as_given = try std.fmt.bufPrintZ(&buf, "{s}", .{name});
    var sym = x11.XStringToKeysym(as_given.ptr);
    if (sym != 0) return sym;
    const lower = std.ascii.lowerString(buf[0..name.len], name);
    buf[name.len] = 0;
    sym = x11.XStringToKeysym(@ptrCast(lower.ptr));
    if (sym != 0) return sym;
    buf[0] = std.ascii.toUpper(buf[0]);
    sym = x11.XStringToKeysym(@ptrCast(&buf));
    if (sym != 0) return sym;
    return error.UnknownKey;
}

/// Convert our trigger syntax ("CTRL+ALT+G", "super+shift+Space") to the
/// XDG shortcuts spec format used for `preferred_trigger`
/// ("CTRL+ALT+g", "LOGO+SHIFT+space"): CTRL/ALT/SHIFT/LOGO modifiers and an
/// xkb keysym name.
pub fn triggerToPortal(buf: []u8, trigger_str: []const u8) ![:0]const u8 {
    const parsed = try parseTrigger(trigger_str);
    const sym = try keysymFor(parsed.key);
    const sym_name = x11.XKeysymToString(sym) orelse return error.UnknownKey;
    return std.fmt.bufPrintZ(buf, "{s}{s}{s}{s}{s}", .{
        if (parsed.modifiers.ctrl) "CTRL+" else "",
        if (parsed.modifiers.alt) "ALT+" else "",
        if (parsed.modifiers.shift) "SHIFT+" else "",
        if (parsed.modifiers.super) "LOGO+" else "",
        std.mem.span(sym_name),
    });
}

/// Object path of a portal request (or session) created by the connection
/// with `unique_name` using `token`:
/// `<base>/<unique name without ':' and with '.' -> '_'>/<token>`.
/// E.g. ":1.42" + "t" -> "/org/freedesktop/portal/desktop/request/1_42/t".
pub fn handlePath(buf: []u8, comptime kind: enum { request, session }, unique_name: []const u8, token: []const u8) ![:0]const u8 {
    const sender = if (std.mem.startsWith(u8, unique_name, ":")) unique_name[1..] else unique_name;
    const prefix = portal_path ++ "/" ++ @tagName(kind) ++ "/";
    if (prefix.len + sender.len + 1 + token.len + 1 > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[0..prefix.len], prefix);
    var i: usize = prefix.len;
    for (sender) |c| {
        buf[i] = if (c == '.') '_' else c;
        i += 1;
    }
    buf[i] = '/';
    i += 1;
    @memcpy(buf[i..][0..token.len], token);
    i += token.len;
    buf[i] = 0;
    return buf[0..i :0];
}

var token_counter: std.atomic.Value(u32) = .init(0);

/// A fresh handle token; tokens must be valid object path elements
/// (`[A-Za-z0-9_]`) and unique for this connection.
fn nextToken(buf: []u8) ![:0]const u8 {
    return std.fmt.bufPrintZ(buf, "oriel_{d}_{d}", .{ std.c.getpid(), token_counter.fetchAdd(1, .monotonic) });
}

/// `G_VARIANT_TYPE(s)`: a GVariantType is its own type string.
fn vt(comptime s: [:0]const u8) *const glib.VariantType {
    return @ptrCast(s.ptr);
}

fn entry(key: [*:0]const u8, value: *glib.Variant) *glib.Variant {
    return glib.Variant.newDictEntry(glib.Variant.newString(key), glib.Variant.newVariant(value));
}

/// Build the `(oa(sa{sv})sa{sv})` parameters of BindShortcuts: each shortcut
/// with its `description` and `preferred_trigger`, parent window "" and the
/// request's `handle_token`. Returns a floating reference.
pub fn buildBindShortcutsParams(gpa: std.mem.Allocator, session: [:0]const u8, list: []const Shortcut, handle_token: [:0]const u8) !*glib.Variant {
    // Validate everything first: floating variants built before an error
    // would leak.
    for (list) |s| {
        var trigger_buf: [128]u8 = undefined;
        _ = try triggerToPortal(&trigger_buf, s.trigger);
    }
    const Strings = struct { id: [:0]u8, desc: [:0]u8 };
    const strings = try gpa.alloc(Strings, list.len);
    defer gpa.free(strings);
    var n_strings: usize = 0;
    defer for (strings[0..n_strings]) |z| {
        gpa.free(z.id);
        gpa.free(z.desc);
    };
    for (list, strings) |s, *z| {
        const id_z = try gpa.dupeZ(u8, s.id);
        errdefer gpa.free(id_z);
        z.* = .{ .id = id_z, .desc = try gpa.dupeZ(u8, if (s.description.len > 0) s.description else s.id) };
        n_strings += 1;
    }
    const items = try gpa.alloc(*glib.Variant, list.len);
    defer gpa.free(items);
    for (list, strings, items) |s, z, *item| {
        const id_z = z.id;
        const desc_z = z.desc;
        var trigger_buf: [128]u8 = undefined;
        const trigger_z = triggerToPortal(&trigger_buf, s.trigger) catch unreachable; // validated above

        var props = [_]*glib.Variant{
            entry("description", glib.Variant.newString(desc_z)),
            entry("preferred_trigger", glib.Variant.newString(trigger_z)),
        };
        var pair = [_]*glib.Variant{ glib.Variant.newString(id_z), glib.Variant.newArray(vt("{sv}"), &props, props.len) };
        item.* = glib.Variant.newTuple(&pair, pair.len);
    }
    var options = [_]*glib.Variant{entry("handle_token", glib.Variant.newString(handle_token))};
    var params = [_]*glib.Variant{
        glib.Variant.newObjectPath(session),
        glib.Variant.newArray(vt("(sa{sv})"), items.ptr, items.len),
        glib.Variant.newString(""),
        glib.Variant.newArray(vt("{sv}"), &options, options.len),
    };
    return glib.Variant.newTuple(&params, params.len);
}

/// Version of the GlobalShortcuts portal, or null when no backend provides it.
pub fn portalVersion() !?u32 {
    var err: ?*glib.Error = null;
    const proxy = gio.DBusProxy.newForBusSync(
        .session,
        .{},
        null,
        portal_bus,
        portal_path,
        portal_iface,
        null,
        &err,
    ) orelse {
        if (err) |e| e.free();
        return error.PortalProxy;
    };
    defer proxy.unref();
    const version = proxy.getCachedProperty("version") orelse return null;
    defer version.unref();
    return version.getUint32();
}

/// A Wayland session. `WAYLAND_DISPLAY`, not `XDG_SESSION_TYPE`: the
/// headless test runner clears the former but inherits the latter.
fn isWayland() bool {
    return std.c.getenv("WAYLAND_DISPLAY") != null;
}

// The generated binding marks the result non-null, but it is NULL when the
// key is missing.
extern fn g_variant_lookup_value(dict: *glib.Variant, key: [*:0]const u8, expected_type: ?*const glib.VariantType) ?*glib.Variant;

/// Create a GlobalShortcuts session and return its object path (gpa-owned).
///
/// Waits for the request's `Response` on a private main context pushed as
/// the thread default, so the app's main loop is never re-entered: only the
/// Response subscription and the timeout are dispatched meanwhile.
pub fn createSession(gpa: std.mem.Allocator, conn: *gio.DBusConnection) ![:0]u8 {
    const unique = conn.getUniqueName() orelse return error.NoUniqueName;
    var token_buf: [64]u8 = undefined;
    const token = try nextToken(&token_buf);
    var session_token_buf: [64]u8 = undefined;
    const session_token = try nextToken(&session_token_buf);
    var path_buf: [256]u8 = undefined;
    const request_path = try handlePath(&path_buf, .request, std.mem.span(unique), token);

    const Wait = struct {
        done: bool = false,
        timed_out: bool = false,
        response: u32 = 2,
        results: ?*glib.Variant = null,

        fn onResponse(_: *gio.DBusConnection, _: ?[*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, params: *glib.Variant, data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(data));
            if (self.done) return;
            const code = params.getChildValue(0);
            defer code.unref();
            self.response = code.getUint32();
            self.results = params.getChildValue(1);
            self.done = true;
        }

        fn onTimeout(data: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.timed_out = true;
            return 0;
        }
    };
    var wait: Wait = .{};

    const ctx = glib.MainContext.new();
    defer ctx.unref();
    ctx.pushThreadDefault();
    defer ctx.popThreadDefault();

    // Subscribe before calling: the Response may arrive before the reply.
    const sub = conn.signalSubscribe(portal_bus, request_iface, "Response", request_path, null, .{}, &Wait.onResponse, &wait, null);
    defer conn.signalUnsubscribe(sub);

    var options = [_]*glib.Variant{
        entry("handle_token", glib.Variant.newString(token)),
        entry("session_handle_token", glib.Variant.newString(session_token)),
    };
    var params = [_]*glib.Variant{glib.Variant.newArray(vt("{sv}"), &options, options.len)};
    var err: ?*glib.Error = null;
    const reply = conn.callSync(portal_bus, portal_path, portal_iface, "CreateSession", glib.Variant.newTuple(&params, params.len), vt("(o)"), .{}, create_session_timeout_ms, null, &err) orelse {
        if (err) |e| {
            log.err("GlobalShortcuts.CreateSession: {s}", .{e.f_message orelse "unknown error"});
            e.free();
        }
        return error.CreateSessionFailed;
    };
    reply.unref();

    const timeout = glib.timeoutSourceNew(create_session_timeout_ms);
    defer {
        timeout.destroy();
        timeout.unref();
    }
    timeout.setCallback(&Wait.onTimeout, &wait, null);
    _ = timeout.attach(ctx);
    while (!wait.done and !wait.timed_out) _ = ctx.iteration(1);

    const results = wait.results orelse return error.CreateSessionTimeout;
    defer results.unref();
    if (wait.response != 0) {
        log.err("GlobalShortcuts.CreateSession: portal response {d}", .{wait.response});
        return error.CreateSessionDenied;
    }
    // The spec says `o`, xdg-desktop-portal sends `s`: accept both.
    const handle = g_variant_lookup_value(results, "session_handle", null) orelse return error.NoSessionHandle;
    defer handle.unref();
    const type_str = std.mem.span(handle.getTypeString());
    if (!std.mem.eql(u8, type_str, "s") and !std.mem.eql(u8, type_str, "o")) return error.NoSessionHandle;
    return gpa.dupeZ(u8, std.mem.span(handle.getString(null)));
}

/// Close a portal session. Synchronous so the message is out before the
/// connection is dropped; the portal answers without user interaction.
fn closeSession(conn: *gio.DBusConnection, session: [:0]const u8) void {
    var err: ?*glib.Error = null;
    if (conn.callSync(portal_bus, session, session_iface, "Close", null, null, .{}, 2000, null, &err)) |reply| {
        reply.unref();
    } else if (err) |e| {
        log.err("GlobalShortcuts: closing session {s}: {s}", .{ session, e.f_message orelse "unknown error" });
        e.free();
    }
}

/// A private session bus connection for the portal. xdg-desktop-portal ties
/// a connection to an app id at its first portal call, and GTK already
/// talks to portals (e.g. Settings) on the shared connection before we
/// could register ours.
fn openPortalConnection() !*gio.DBusConnection {
    var err: ?*glib.Error = null;
    const address = gio.dbusAddressGetForBusSync(.session, null, &err) orelse {
        if (err) |e| e.free();
        return error.DBusConnection;
    };
    defer glib.free(address);
    return gio.DBusConnection.newForAddressSync(address, .{ .authentication_client = true, .message_bus_connection = true }, null, null, &err) orelse {
        if (err) |e| {
            log.err("GlobalShortcuts: connecting to the session bus: {s}", .{e.f_message orelse "unknown error"});
            e.free();
        }
        return error.DBusConnection;
    };
}

/// The app id to register with the portal: the running GApplication's id
/// (`App.Config.id`), else the program name.
fn defaultAppId() ?[*:0]const u8 {
    if (gio.Application.getDefault()) |app| {
        if (app.getApplicationId()) |id| return id;
    }
    return glib.getPrgname();
}

/// Tell the portal which app `conn` belongs to (host apps only: sandboxed
/// ones already have an id). GlobalShortcuts refuses connections without
/// one, and xdg-desktop-portal only accepts ids with an installed
/// `<app_id>.desktop` file.
fn registerAppId(conn: *gio.DBusConnection, app_id: [*:0]const u8) !void {
    var params = [_]*glib.Variant{ glib.Variant.newString(app_id), glib.Variant.newArray(vt("{sv}"), null, 0) };
    var err: ?*glib.Error = null;
    if (conn.callSync(portal_bus, portal_path, "org.freedesktop.host.portal.Registry", "Register", glib.Variant.newTuple(&params, params.len), null, .{}, create_session_timeout_ms, null, &err)) |reply| {
        reply.unref();
        return;
    }
    const e = err orelse return error.RegisterAppIdFailed;
    defer e.free();
    if (gio.DBusError.getRemoteError(e)) |name| {
        defer glib.free(name);
        // Portals before the host registry (< 1.19) derive the id themselves.
        const n = std.mem.span(name);
        if (std.mem.eql(u8, n, "org.freedesktop.DBus.Error.UnknownMethod") or
            std.mem.eql(u8, n, "org.freedesktop.DBus.Error.UnknownInterface")) return;
    }
    log.err("GlobalShortcuts: registering app id '{s}' with the portal: {s} (is {s}.desktop installed?)", .{ app_id, e.f_message orelse "unknown error", app_id });
    return error.AppIdNotRegistered;
}

/// Open a portal connection registered as `app_id` and create a session on it.
fn openSession(gpa: std.mem.Allocator, app_id: [*:0]const u8, session: *[:0]u8) !*gio.DBusConnection {
    const conn = try openPortalConnection();
    errdefer conn.unref();
    try registerAppId(conn, app_id);
    session.* = try createSession(gpa, conn);
    return conn;
}

fn ensurePortal(gpa: std.mem.Allocator) !*Portal {
    if (portal) |*p| return p;
    _ = (portalVersion() catch null) orelse return error.PortalUnavailable;

    const app_id = defaultAppId() orelse return error.NoAppId;
    var session: [:0]u8 = undefined;
    const conn = try openSession(gpa, app_id, &session);
    portal = .{ .conn = conn, .session = session, .gpa = gpa };
    const p = &portal.?;
    // The portal sends Activated only to the session's owner, but filter on
    // our session handle anyway (another library in the process may own a
    // session too).
    p.activated_sub = conn.signalSubscribe(portal_bus, portal_iface, "Activated", portal_path, null, .{}, &onPortalActivated, null, null);
    return p;
}

/// Schedule a BindShortcuts of the current list; several registrations in a
/// row (e.g. in `setup`) end up in one call.
fn scheduleBind(p: *Portal) void {
    if (p.bind_sub != 0) {
        p.bind_dirty = true;
        return;
    }
    if (p.bind_idle == 0) p.bind_idle = glib.idleAdd(&bindIdle, null);
}

fn bindIdle(_: ?*anyopaque) callconv(.c) c_int {
    const p = &(portal orelse return 0);
    p.bind_idle = 0;
    bindNow(p) catch |err| log.err("GlobalShortcuts.BindShortcuts: {s}", .{@errorName(err)});
    return 0;
}

fn bindNow(p: *Portal) !void {
    const list = try p.gpa.alloc(Shortcut, shortcuts.items.len);
    defer p.gpa.free(list);
    for (shortcuts.items, list) |r, *s| s.* = r.shortcut;

    const unique = p.conn.getUniqueName() orelse return error.NoUniqueName;
    var token_buf: [64]u8 = undefined;
    const token = try nextToken(&token_buf);
    var path_buf: [256]u8 = undefined;
    const request_path = try handlePath(&path_buf, .request, std.mem.span(unique), token);

    const params = try buildBindShortcutsParams(p.gpa, p.session, list, token);
    // Subscribe before calling: the Response may arrive before the reply.
    p.bind_sub = p.conn.signalSubscribe(portal_bus, request_iface, "Response", request_path, null, .{}, &onBindResponse, null, null);
    // No timeout: the portal may show a dialog and wait for the user.
    p.conn.call(portal_bus, portal_path, portal_iface, "BindShortcuts", params, vt("(o)"), .{}, std.math.maxInt(c_int), null, &onBindReply, null);
}

/// The method reply of BindShortcuts; the outcome comes with `Response`.
fn onBindReply(source: ?*gobject.Object, res: *gio.AsyncResult, _: ?*anyopaque) callconv(.c) void {
    const conn: *gio.DBusConnection = @ptrCast(source orelse return);
    var err: ?*glib.Error = null;
    if (conn.callFinish(res, &err)) |reply| {
        reply.unref();
        return;
    }
    if (err) |e| {
        log.err("GlobalShortcuts.BindShortcuts: {s}", .{e.f_message orelse "unknown error"});
        e.free();
    }
    // No Response will come for a failed call.
    finishBind();
}

fn onBindResponse(_: *gio.DBusConnection, _: ?[*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, params: *glib.Variant, _: ?*anyopaque) callconv(.c) void {
    const code = params.getChildValue(0);
    defer code.unref();
    const response = code.getUint32();
    if (response != 0) {
        log.err("GlobalShortcuts.BindShortcuts: portal response {d} ({s})", .{ response, if (response == 1) "cancelled by the user" else "failed" });
    } else {
        const results = params.getChildValue(1);
        defer results.unref();
        const bound: usize = if (g_variant_lookup_value(results, "shortcuts", null)) |list| blk: {
            defer list.unref();
            break :blk list.nChildren();
        } else 0;
        log.info("GlobalShortcuts: {d} shortcut(s) bound", .{bound});
    }
    finishBind();
}

fn finishBind() void {
    const p = &(portal orelse return);
    if (p.bind_sub != 0) {
        p.conn.signalUnsubscribe(p.bind_sub);
        p.bind_sub = 0;
    }
    if (p.bind_dirty) {
        p.bind_dirty = false;
        scheduleBind(p);
    }
}

fn onPortalActivated(
    _: *gio.DBusConnection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    params: *glib.Variant,
    _: ?*anyopaque,
) callconv(.c) void {
    // Parameters: (o session_handle, s shortcut_id, t timestamp, a{sv} options)
    const p = portal orelse return;
    const session = params.getChildValue(0);
    defer session.unref();
    if (!std.mem.eql(u8, std.mem.span(session.getString(null)), p.session)) return;
    const child = params.getChildValue(1);
    defer child.unref();
    var len: usize = 0;
    const str = child.getString(&len);
    _ = trigger(str[0..len]);
}

fn deinitPortal() void {
    var p = portal orelse return;
    portal = null;
    if (p.bind_idle != 0) _ = glib.Source.remove(p.bind_idle);
    if (p.bind_sub != 0) p.conn.signalUnsubscribe(p.bind_sub);
    if (p.activated_sub != 0) p.conn.signalUnsubscribe(p.activated_sub);
    closeSession(p.conn, p.session);
    p.gpa.free(p.session);
    p.conn.unref();
}

pub fn x11Available() bool {
    const display = x11.XOpenDisplay(null) orelse return false;
    _ = x11.XCloseDisplay(display);
    return true;
}

fn initX11() !*x11.Display {
    if (x11_display) |d| return d;
    const d = x11.XOpenDisplay(null) orelse return error.XOpenDisplay;
    x11_display = d;

    const fd = x11.ConnectionNumber(d);
    const channel = glib.IOChannel.unixNew(fd);
    defer channel.unref();
    x11_source_id = glib.ioAddWatch(channel, .{ .@"in" = true }, &onX11Data, null);
    return d;
}

fn onX11Data(_: *glib.IOChannel, _: glib.IOCondition, _: ?*anyopaque) callconv(.c) c_int {
    const disp = x11_display orelse return 0;
    while (x11.XPending(disp) > 0) {
        var ev: x11.XEvent = undefined;
        _ = x11.XNextEvent(disp, &ev);
        if (ev.type == x11.KeyPress) {
            const keycode = @as(u8, @intCast(ev.xkey.keycode));
            const state = ev.xkey.state & (x11.ControlMask | x11.Mod1Mask | x11.ShiftMask | x11.Mod4Mask);
            for (shortcuts.items) |entry_| {
                if (entry_.keycode == keycode and entry_.mask == state) {
                    entry_.callback(entry_.shortcut.id);
                }
            }
        }
    }
    return 1;
}

/// Register a global shortcut. Calls `callback` on the main thread when
/// activated. Call it on the main thread.
///
/// On Wayland the shortcut is bound through the GlobalShortcuts portal
/// asynchronously (the compositor may ask the user to confirm); a failed or
/// refused bind is logged. Returns `error.PortalUnavailable` on Wayland
/// without the portal.
pub fn register(gpa: std.mem.Allocator, shortcut: Shortcut, callback: Callback) !void {
    const parsed = try parseTrigger(shortcut.trigger);

    if (isWayland()) {
        var trigger_buf: [128]u8 = undefined;
        _ = try triggerToPortal(&trigger_buf, shortcut.trigger); // reject bad keys now, not in the idle bind
        const p = try ensurePortal(gpa);
        try shortcuts.append(gpa, .{ .shortcut = shortcut, .callback = callback });
        scheduleBind(p);
        return;
    }

    const disp = try initX11();
    var mask: c_uint = 0;
    if (parsed.modifiers.ctrl) mask |= x11.ControlMask;
    if (parsed.modifiers.alt) mask |= x11.Mod1Mask;
    if (parsed.modifiers.shift) mask |= x11.ShiftMask;
    if (parsed.modifiers.super) mask |= x11.Mod4Mask;

    const sym = try keysymFor(parsed.key);
    const kc = x11.XKeysymToKeycode(disp, sym);
    if (kc == 0) return error.KeycodeNotFound;

    const root = x11.XDefaultRootWindow(disp);
    for (lockVariants(mask)) |m| {
        _ = x11.XGrabKey(disp, kc, m, root, 1, x11.GrabModeAsync, x11.GrabModeAsync);
    }
    _ = x11.XFlush(disp);

    try shortcuts.append(gpa, .{
        .shortcut = shortcut,
        .callback = callback,
        .keycode = kc,
        .mask = mask,
    });
}

/// `mask` with and without CapsLock / NumLock, which would otherwise make
/// the grab miss.
fn lockVariants(mask: c_uint) [4]c_uint {
    return .{
        mask,
        mask | x11.LockMask,
        mask | x11.Mod2Mask,
        mask | x11.LockMask | x11.Mod2Mask,
    };
}

/// Manually trigger a registered shortcut by ID (useful in tests and dev mode).
pub fn trigger(id: []const u8) bool {
    for (shortcuts.items) |entry_| {
        if (std.mem.eql(u8, entry_.shortcut.id, id)) {
            entry_.callback(id);
            return true;
        }
    }
    return false;
}

/// Unregister a shortcut by its ID.
pub fn unregister(id: []const u8) bool {
    for (shortcuts.items, 0..) |entry_, i| {
        if (std.mem.eql(u8, entry_.shortcut.id, id)) {
            if (x11_display) |disp| {
                if (entry_.keycode != 0) {
                    const root = x11.XDefaultRootWindow(disp);
                    for (lockVariants(entry_.mask)) |m| {
                        _ = x11.XUngrabKey(disp, entry_.keycode, m, root);
                    }
                    _ = x11.XFlush(disp);
                }
            }
            _ = shortcuts.swapRemove(i);
            // The portal binds a whole list: bind the remaining ones.
            if (portal) |*p| scheduleBind(p);
            return true;
        }
    }
    return false;
}

/// Clean up registered shortcuts, the portal session and X11 resources.
pub fn deinit(gpa: std.mem.Allocator) void {
    deinitPortal();
    if (x11_display) |disp| {
        const root = x11.XDefaultRootWindow(disp);
        for (shortcuts.items) |entry_| {
            if (entry_.keycode != 0) {
                for (lockVariants(entry_.mask)) |m| {
                    _ = x11.XUngrabKey(disp, entry_.keycode, m, root);
                }
            }
        }
        _ = x11.XFlush(disp);
        if (x11_source_id != 0) {
            _ = glib.Source.remove(x11_source_id);
            x11_source_id = 0;
        }
        _ = x11.XCloseDisplay(disp);
        x11_display = null;
    }
    shortcuts.deinit(gpa);
    shortcuts = .empty;
}

/// On Wayland: the portal creates a session for `ctx.app_id` (then it is
/// closed again; no BindShortcuts, which could prompt the user). On X11: a
/// key grab works.
pub fn check(gpa: std.mem.Allocator, ctx: oriel.CheckContext) !oriel.Check {
    if (isWayland()) {
        const version = (portalVersion() catch null) orelse return .{
            .module = "global_shortcut",
            .ok = false,
            .detail = try std.fmt.allocPrint(gpa, "Wayland session without the GlobalShortcuts portal", .{}),
        };
        const app_id = if (ctx.app_id) |id| id.ptr else defaultAppId() orelse return error.NoAppId;
        var session: [:0]u8 = undefined;
        const conn = openSession(gpa, app_id, &session) catch |e| return .{
            .module = "global_shortcut",
            .ok = false,
            .detail = try std.fmt.allocPrint(gpa, "GlobalShortcuts portal v{d}: CreateSession as '{s}' failed: {s}", .{ version, app_id, @errorName(e) }),
        };
        defer conn.unref();
        defer gpa.free(session);
        closeSession(conn, session);
        return .{
            .module = "global_shortcut",
            .ok = true,
            .detail = try std.fmt.allocPrint(gpa, "GlobalShortcuts portal v{d}: CreateSession ok ({s})", .{ version, session }),
        };
    }

    // X11: verify a grab works.
    var x11_ok = false;
    if (x11.XOpenDisplay(null)) |disp| {
        defer _ = x11.XCloseDisplay(disp);
        const root = x11.XDefaultRootWindow(disp);
        const kc = x11.XKeysymToKeycode(disp, x11.XK_F12);
        if (kc != 0) {
            _ = x11.XGrabKey(disp, kc, x11.ControlMask, root, 1, x11.GrabModeAsync, x11.GrabModeAsync);
            _ = x11.XUngrabKey(disp, kc, x11.ControlMask, root);
            _ = x11.XFlush(disp);
            x11_ok = true;
        }
    }
    return .{
        .module = "global_shortcut",
        .ok = x11_ok,
        .detail = try std.fmt.allocPrint(gpa, "X11 XGrabKey {s}", .{if (x11_ok) "available" else "unavailable"}),
    };
}


test "triggerToPortal converts to the XDG shortcuts format" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("CTRL+ALT+g", try triggerToPortal(&buf, "CTRL+ALT+G"));
    try std.testing.expectEqualStrings("SHIFT+LOGO+space", try triggerToPortal(&buf, "super+shift+Space"));
    try std.testing.expectEqualStrings("CTRL+F12", try triggerToPortal(&buf, "ctrl+f12"));
    try std.testing.expectEqualStrings("ALT+Return", try triggerToPortal(&buf, "alt+enter"));
    try std.testing.expectEqualStrings("CTRL+Tab", try triggerToPortal(&buf, "Control+tab"));
    try std.testing.expectEqualStrings("CTRL+1", try triggerToPortal(&buf, "ctrl+1"));
    try std.testing.expectError(error.UnknownKey, triggerToPortal(&buf, "ctrl+nosuchkey"));
}

test "handlePath derives portal request and session paths" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/org/freedesktop/portal/desktop/request/1_42/oriel_7_0",
        try handlePath(&buf, .request, ":1.42", "oriel_7_0"),
    );
    try std.testing.expectEqualStrings(
        "/org/freedesktop/portal/desktop/session/1_2345/tok",
        try handlePath(&buf, .session, ":1.2345", "tok"),
    );
    var small: [16]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, handlePath(&small, .request, ":1.42", "t"));
}

test "nextToken is a unique object path element" {
    var a_buf: [64]u8 = undefined;
    var b_buf: [64]u8 = undefined;
    const a = try nextToken(&a_buf);
    const b = try nextToken(&b_buf);
    try std.testing.expect(!std.mem.eql(u8, a, b));
    for (a) |c| try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '_');
}

test "buildBindShortcutsParams" {
    const params = (try buildBindShortcutsParams(std.testing.allocator, "/org/freedesktop/portal/desktop/session/1_42/s", &.{
        .{ .id = "rewrite", .description = "Rewrite selection", .trigger = "CTRL+ALT+G" },
        .{ .id = "other", .trigger = "super+Space" },
    }, "tok")).refSink();
    defer params.unref();

    try std.testing.expectEqualStrings("(oa(sa{sv})sa{sv})", std.mem.span(params.getTypeString()));
    const text = params.print(0);
    defer glib.free(text);
    try std.testing.expectEqualStrings(
        "('/org/freedesktop/portal/desktop/session/1_42/s', " ++
            "[('rewrite', {'description': <'Rewrite selection'>, 'preferred_trigger': <'CTRL+ALT+g'>}), " ++
            "('other', {'description': <'other'>, 'preferred_trigger': <'LOGO+space'>})], " ++
            "'', {'handle_token': <'tok'>})",
        std.mem.span(text),
    );
    try std.testing.expectError(error.UnknownKey, buildBindShortcutsParams(std.testing.allocator, "/s", &.{
        .{ .id = "bad", .trigger = "ctrl+nosuchkey" },
    }, "tok"));
}

test "trigger registered shortcut" {
    const H = struct {
        var triggered: bool = false;
        fn cb(_: []const u8) void {
            triggered = true;
        }
    };
    try shortcuts.append(std.testing.allocator, .{
        .shortcut = .{ .id = "test_hotkey", .trigger = "ctrl+alt+t" },
        .callback = &H.cb,
    });
    defer shortcuts.deinit(std.testing.allocator);

    try std.testing.expect(trigger("test_hotkey"));
    try std.testing.expect(H.triggered);
    try std.testing.expect(!trigger("non_existent"));
}

test {
    std.testing.refAllDecls(@This());
}
