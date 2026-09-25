//! macOS menu bar extra (NSStatusItem + NSMenu).
//!
//! Left click: `on_activate` (default: toggle the main window, like the
//! other backends). Right click or Control-click: the menu. The NSMenu is
//! rebuilt from the platform-neutral `Menu` model each time it opens, so
//! `setMenu` / `setChecked` changes always show. Menu callbacks run on the
//! main thread. One tray per app (as on Windows).
//!
//! AppKit calls happen on the main thread: `create` and the setters are
//! marshalled there with `Shell.runOnMainThread` when called elsewhere.
//! So are the menu model changes (`setMenu`, `setChecked`, `setTitle`),
//! which the main thread reads while building the menu and on clicks.

const std = @import("std");
const cocoa = @import("../../platform/macos/cocoa.zig");
const ShellMod = @import("../../platform/macos/Shell.zig");
const App = @import("../../core/App.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

const Object = cocoa.Object;
const log = std.log.scoped(.oriel);

pub const MenuItem = common.MenuItem;
pub const Icon = common.Icon;
pub const Options = common.Options;
pub const Menu = common.Menu;

const NSVariableStatusItemLength: f64 = -1;
const icon_points: f64 = 18; // menu bar icon height
const NSEventTypeRightMouseUp: c_ulong = 4;
const NSEventMaskLeftMouseUp: c_ulong = 1 << 2;
const NSEventMaskRightMouseUp: c_ulong = 1 << 4;
const NSEventModifierFlagControl: c_ulong = 1 << 18;
const NSControlStateValueOn: isize = 1;

/// The tray whose clicks the shared target routes (main thread only).
var global_tray: ?*Tray = null;
var target: Object = cocoa.nil;

pub const Tray = struct {
    gpa: std.mem.Allocator,
    menu: Menu,
    strings: std.heap.ArenaAllocator,
    id: []const u8,
    title: []const u8, // owned (gpa); replaced on the main thread
    status_item: Object = cocoa.nil, // retained
    on_menu: ?*const fn (id: []const u8, checked: ?bool) void,
    on_activate: ?*const fn () void,

    pub fn create(gpa: std.mem.Allocator, options: Options) !*Tray {
        const self = try gpa.create(Tray);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .menu = Menu.init(gpa),
            .strings = std.heap.ArenaAllocator.init(gpa),
            .id = "",
            .title = "",
            .on_menu = options.on_menu,
            .on_activate = options.on_activate,
        };
        errdefer self.menu.deinit();
        errdefer self.strings.deinit();
        const a = self.strings.allocator();
        self.id = try a.dupe(u8, options.id);
        self.title = try gpa.dupe(u8, options.title);
        errdefer gpa.free(self.title);
        try self.menu.set(options.menu);

        var params: CreateParams = .{ .tray = self, .options = options };
        try ShellMod.runOnMainThread(CreateParams, &params, createOnMain);
        if (params.err) |err| return err;
        return self;
    }

    pub fn deinit(self: *Tray) void {
        var params: DeinitParams = .{ .tray = self };
        ShellMod.runOnMainThread(DeinitParams, &params, deinitOnMain) catch {
            // The app has stopped: its status bar is gone with it; the item
            // reference is leaked rather than released off the main thread.
            if (global_tray == self) global_tray = null;
        };
        self.menu.deinit();
        self.strings.deinit();
        self.gpa.free(self.title);
        self.gpa.destroy(self);
    }

    pub fn setMenu(self: *Tray, items: []const MenuItem) !void {
        var params: MenuParams = .{ .tray = self, .items = items };
        onMain(MenuParams, &params, setMenuOnMain);
        if (params.err) |err| return err;
    }

    pub fn setChecked(self: *Tray, id: []const u8, checked: bool) void {
        var params: CheckedParams = .{ .tray = self, .id = id, .checked = checked };
        onMain(CheckedParams, &params, setCheckedOnMain);
    }

    pub fn isChecked(self: *Tray, id: []const u8) ?bool {
        // The model is changed on the main thread (setMenu resets its arena):
        // read it there too.
        var params: IsCheckedParams = .{ .tray = self, .id = id };
        onMain(IsCheckedParams, &params, isCheckedOnMain);
        return params.result;
    }

    pub fn setTooltip(self: *Tray, tooltip: []const u8) !void {
        var params: TextParams = .{ .tray = self, .text = tooltip };
        try ShellMod.runOnMainThread(TextParams, &params, setTooltipOnMain);
        if (params.err) |err| return err;
    }

    /// The title isn't shown in the menu bar (only the icon); it names the
    /// item for accessibility.
    pub fn setTitle(self: *Tray, title: []const u8) !void {
        var params: TextParams = .{ .tray = self, .text = try self.gpa.dupe(u8, title) };
        onMain(TextParams, &params, setTitleOnMain);
    }

    pub fn setIcon(self: *Tray, icon: Icon) !void {
        var params: IconParams = .{ .tray = self, .icon = icon };
        try ShellMod.runOnMainThread(IconParams, &params, setIconOnMain);
        if (params.err) |err| return err;
    }

    fn button(self: *Tray) Object {
        return self.status_item.msgSend(Object, "button", .{});
    }
};

// --- Main-thread parts -------------------------------------------------------------

const CreateParams = struct { tray: *Tray, options: Options, err: ?anyerror = null };
const DeinitParams = struct { tray: *Tray };
const TextParams = struct { tray: *Tray, text: []const u8, err: ?anyerror = null };
const MenuParams = struct { tray: *Tray, items: []const MenuItem, err: ?anyerror = null };
const CheckedParams = struct { tray: *Tray, id: []const u8, checked: bool };
const IsCheckedParams = struct { tray: *Tray, id: []const u8, result: ?bool = null };
const IconParams = struct { tray: *Tray, icon: Icon, err: ?anyerror = null };

fn ensureTarget() void {
    if (target.value != null) return;
    target = cocoa.new(cocoa.defineClass("OrielTrayTarget", &.{}, .{
        .{ "statusItemClicked:", statusItemClicked },
        .{ "menuItemClicked:", menuItemClicked },
    }));
}

fn createOnMain(p: *CreateParams) void {
    const pool = cocoa.objc.AutoreleasePool.init();
    defer pool.deinit();
    ensureTarget();
    const bar = cocoa.class("NSStatusBar").msgSend(Object, "systemStatusBar", .{});
    // The status bar only keeps a weak reference: we hold the item.
    const item = bar.msgSend(Object, "statusItemWithLength:", .{NSVariableStatusItemLength});
    if (item.value == null) {
        p.err = error.StatusItemCreateFailed;
        return;
    }
    const tray = p.tray;
    tray.status_item = item.retain();
    const btn = tray.button();
    applyIcon(btn, p.options.icon, tray.title) catch |err| {
        bar.msgSend(void, "removeStatusItem:", .{item});
        tray.status_item.release();
        tray.status_item = cocoa.nil;
        p.err = err;
        return;
    };
    setText(btn, "setToolTip:", p.options.tooltip);
    setText(btn, "setAccessibilityTitle:", tray.title);
    btn.msgSend(void, "setTarget:", .{target});
    btn.msgSend(void, "setAction:", .{cocoa.objc.sel("statusItemClicked:").value});
    _ = btn.msgSend(isize, "sendActionOn:", .{NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp});
    if (global_tray != null) log.warn("a second tray replaces the first one's click handling", .{});
    global_tray = tray;
}

fn deinitOnMain(p: *DeinitParams) void {
    const tray = p.tray;
    if (global_tray == tray) global_tray = null;
    if (tray.status_item.value == null) return;
    const bar = cocoa.class("NSStatusBar").msgSend(Object, "systemStatusBar", .{});
    bar.msgSend(void, "removeStatusItem:", .{tray.status_item});
    tray.status_item.release();
    tray.status_item = cocoa.nil;
}

fn setTooltipOnMain(p: *TextParams) void {
    if (p.tray.status_item.value == null) return;
    setText(p.tray.button(), "setToolTip:", p.text);
}

/// Takes ownership of `p.text`.
fn setTitleOnMain(p: *TextParams) void {
    p.tray.gpa.free(p.tray.title);
    p.tray.title = p.text;
    if (p.tray.status_item.value == null) return;
    setText(p.tray.button(), "setAccessibilityTitle:", p.text);
}

fn setMenuOnMain(p: *MenuParams) void {
    p.tray.menu.set(p.items) catch |err| {
        p.err = err;
    };
}

fn isCheckedOnMain(p: *IsCheckedParams) void {
    const n = p.tray.menu.find(p.id) orelse return;
    p.result = if (n.kind == .check) n.checked else null;
}

fn setCheckedOnMain(p: *CheckedParams) void {
    const n = p.tray.menu.find(p.id) orelse return;
    n.checked = p.checked;
    p.tray.menu.revision +%= 1;
}

/// Model changes: on the main thread while the app runs; directly before
/// it starts or after it stopped (nothing reads the model then).
fn onMain(comptime Ctx: type, ctx: *Ctx, comptime func: fn (*Ctx) void) void {
    ShellMod.runOnMainThread(Ctx, ctx, func) catch func(ctx);
}

fn setIconOnMain(p: *IconParams) void {
    if (p.tray.status_item.value == null) return;
    const pool = cocoa.objc.AutoreleasePool.init();
    defer pool.deinit();
    applyIcon(p.tray.button(), p.icon, p.tray.title) catch |err| {
        p.err = err;
    };
}

fn setText(obj: Object, comptime setter: [:0]const u8, text: []const u8) void {
    const str = cocoa.nsString(text) orelse return;
    defer str.release();
    obj.msgSend(void, setter, .{str});
}

/// An 18 pt NSImage from PNG bytes (autoreleased), or null if AppKit can't
/// decode them.
fn imageFromPng(png: []const u8) ?Object {
    const data = cocoa.class("NSData").msgSend(Object, "dataWithBytes:length:", .{ png.ptr, @as(c_ulong, png.len) });
    const image = cocoa.class("NSImage").msgSend(Object, "alloc", .{}).msgSend(Object, "initWithData:", .{data});
    if (image.value == null) return null;
    _ = image.msgSend(Object, "autorelease", .{});
    image.msgSend(void, "setSize:", .{cocoa.NSSize{ .width = icon_points, .height = icon_points }});
    return image;
}

fn applyIcon(btn: Object, icon: Icon, title: []const u8) !void {
    const image: ?Object = switch (icon) {
        .png => |bytes| imageFromPng(bytes) orelse return error.InvalidIcon,
        // Icon theme names are a Linux concept: try an app/system image of
        // that name, else show the title as text.
        .name => |name| blk: {
            const name_ns = cocoa.nsString(name) orelse break :blk null;
            defer name_ns.release();
            const img = cocoa.class("NSImage").msgSend(Object, "imageNamed:", .{name_ns});
            break :blk if (img.value == null) null else img;
        },
    };
    if (image) |img| {
        btn.msgSend(void, "setImage:", .{img});
        setText(btn, "setTitle:", "");
    } else {
        btn.msgSend(void, "setImage:", .{cocoa.nil});
        setText(btn, "setTitle:", title);
    }
}

fn statusItemClicked(_: cocoa.id, _: cocoa.c.SEL, _: cocoa.id) callconv(.c) void {
    const tray = global_tray orelse return;
    const event = ShellMod.sharedApplication().msgSend(Object, "currentEvent", .{});
    const secondary = event.value != null and (event.msgSend(c_ulong, "type", .{}) == NSEventTypeRightMouseUp or
        event.msgSend(c_ulong, "modifierFlags", .{}) & NSEventModifierFlagControl != 0);
    if (!secondary) {
        if (tray.on_activate) |act| act() else App.toggleWindow();
        return;
    }
    const pool = cocoa.objc.AutoreleasePool.init();
    defer pool.deinit();
    const menu = buildMenu(tray, 0) orelse return;
    // Deprecated but still the simple way to show a menu for a status item
    // whose clicks we handle ourselves.
    tray.status_item.msgSend(void, "popUpStatusItemMenu:", .{menu});
}

/// The NSMenu for model node `parent_id` (autoreleased).
fn buildMenu(tray: *Tray, parent_id: i32) ?Object {
    const menu = cocoa.new(cocoa.class("NSMenu"));
    _ = menu.msgSend(Object, "autorelease", .{});
    menu.msgSend(void, "setAutoenablesItems:", .{cocoa.boolean(false)});
    const parent = tray.menu.node(parent_id) orelse return menu;
    for (parent.children) |child_id| {
        const n = tray.menu.node(child_id) orelse continue;
        if (n.kind == .separator) {
            menu.msgSend(void, "addItem:", .{cocoa.class("NSMenuItem").msgSend(Object, "separatorItem", .{})});
            continue;
        }
        const title = cocoa.nsString(n.label) orelse continue;
        defer title.release();
        const empty = cocoa.nsString("") orelse continue;
        defer empty.release();
        const action: cocoa.c.SEL = if (n.kind == .submenu) null else cocoa.objc.sel("menuItemClicked:").value;
        const item = cocoa.class("NSMenuItem").msgSend(Object, "alloc", .{})
            .msgSend(Object, "initWithTitle:action:keyEquivalent:", .{ title, action, empty });
        if (item.value == null) continue;
        defer item.release();
        item.msgSend(void, "setEnabled:", .{cocoa.boolean(n.enabled)});
        item.msgSend(void, "setTag:", .{@as(isize, child_id)});
        if (n.kind == .submenu) {
            if (buildMenu(tray, child_id)) |sub| item.msgSend(void, "setSubmenu:", .{sub});
        } else {
            item.msgSend(void, "setTarget:", .{target});
            if (n.kind == .check) item.msgSend(void, "setState:", .{@as(isize, if (n.checked) NSControlStateValueOn else 0)});
        }
        menu.msgSend(void, "addItem:", .{item});
    }
    return menu;
}

fn menuItemClicked(_: cocoa.id, _: cocoa.c.SEL, sender: cocoa.id) callconv(.c) void {
    const tray = global_tray orelse return;
    const tag = (Object{ .value = sender }).msgSend(isize, "tag", .{});
    const n = tray.menu.node(std.math.cast(i32, tag) orelse return) orelse return;
    if (n.kind == .check) {
        n.checked = !n.checked;
        tray.menu.revision +%= 1;
    }
    if (tray.on_menu) |f| {
        // `n.key` lives in the menu arena: copy it in case on_menu calls setMenu.
        var key_buf: [256]u8 = undefined;
        f(common.copyKey(&key_buf, n.key), if (n.kind == .check) n.checked else null);
    }
}

pub fn check(gpa: std.mem.Allocator, ctx: oriel.CheckContext) !oriel.Check {
    const pool = cocoa.objc.AutoreleasePool.init();
    defer pool.deinit();
    var menu: Menu = .init(gpa);
    defer menu.deinit();
    try menu.set(&.{
        .{ .item = .{ .id = "show", .label = "Show" } },
        .separator,
        .{ .item = .{ .id = "quit", .label = "Quit" } },
    });
    if (imageFromPng(ctx.icon_png) == null) return .{ .module = "tray", .ok = false, .detail = "the icon PNG didn't decode" };
    if (!ShellMod.isRunning() or global_tray != null) {
        return .{ .module = "tray", .ok = true, .detail = try std.fmt.allocPrint(gpa, "icon {d} B PNG decodes; {d} menu items (no running app: no status item)", .{ ctx.icon_png.len, menu.nodes.items.len - 1 }) };
    }
    // In a running app: add a real status item, then remove it.
    var tray = try Tray.create(gpa, .{ .id = "dev.oriel.Check", .title = "check", .icon = .{ .png = ctx.icon_png }, .menu = &.{
        .{ .item = .{ .id = "show", .label = "Show" } },
        .separator,
        .{ .check = .{ .id = "dnd", .label = "Do not disturb", .checked = true } },
    } });
    const checked = tray.isChecked("dnd") orelse false;
    tray.deinit();
    return .{
        .module = "tray",
        .ok = checked,
        .detail = try std.fmt.allocPrint(gpa, "NSStatusItem created with an 18 pt icon ({d} B PNG) and removed; menu model ok", .{ctx.icon_png.len}),
    };
}

test {
    std.testing.refAllDecls(@This());
}
