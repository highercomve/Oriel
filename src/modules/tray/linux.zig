//! System tray icon (Linux: StatusNotifierItem + com.canonical.dbusmenu).
//!
//! GTK4 has no tray API and libayatana-appindicator is GTK3-only, so the tray
//! speaks the D-Bus protocols directly through GIO. Works with any
//! StatusNotifierItem host: KDE, GNOME with the AppIndicator extension,
//! waybar, Quickshell, …
//!
//!     const tray = try oriel.tray.Tray.create(gpa, .{
//!         .id = "com.example.App",
//!         .title = "My App",
//!         .icon = .{ .png = @embedFile("icon.png") },
//!         .menu = &.{
//!             .{ .item = .{ .id = "show", .label = "Show window" } },
//!             .{ .check = .{ .id = "mute", .label = "Mute", .checked = false } },
//!             .separator,
//!             .{ .submenu = .{ .label = "More", .items = &.{ .{ .item = .{ .id = "about", .label = "About" } } } } },
//!             .{ .item = .{ .id = "quit", .label = "Quit" } },
//!         },
//!         .on_menu = onMenu, // fn (id: []const u8, checked: ?bool) void
//!     });
//!
//! Left-clicking the icon calls `on_activate` (default: toggle the main
//! window). Check items toggle themselves before `on_menu` runs. All
//! callbacks run on the main thread.

const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");
const zigimg = @import("zigimg");
const oriel = @import("../../oriel.zig");

const log = std.log.scoped(.tray);

pub const watcher_name = "org.kde.StatusNotifierWatcher";
const item_path = "/StatusNotifierItem";
const menu_path = "/MenuBar";
const item_iface = "org.kde.StatusNotifierItem";
const menu_iface = "com.canonical.dbusmenu";

const common = @import("common.zig");

pub const MenuItem = common.MenuItem;
pub const Icon = common.Icon;
pub const Options = common.Options;
pub const Menu = common.Menu;

/// dbusmenu properties of one item: `a{sv}`.
fn menuProperties(menu: *Menu, id: i32) *glib.Variant {
    const n = menu.node(id) orelse return emptyDict();
    var entries: [6]*glib.Variant = undefined;
    var len: usize = 0;
    switch (n.kind) {
        .separator => {
            entries[len] = entry("type", glib.Variant.newString("separator"));
            len += 1;
        },
        .root => {
            entries[len] = entry("children-display", glib.Variant.newString("submenu"));
            len += 1;
        },
        .item, .check, .submenu => {
            entries[len] = entry("label", glib.Variant.newString(n.label));
            entries[len + 1] = entry("enabled", glib.Variant.newBoolean(@intFromBool(n.enabled)));
            len += 2;
            if (n.kind == .check) {
                entries[len] = entry("toggle-type", glib.Variant.newString("checkmark"));
                entries[len + 1] = entry("toggle-state", glib.Variant.newInt32(@intFromBool(n.checked)));
                len += 2;
            }
            if (n.kind == .submenu) {
                entries[len] = entry("children-display", glib.Variant.newString("submenu"));
                len += 1;
            }
        },
    }
    return glib.Variant.newArray(vt("{sv}"), &entries, len);
}

/// dbusmenu layout of `id` and its descendants down to `depth` (-1 = all):
/// `(ia{sv}av)`.
fn menuLayout(menu: *Menu, id: i32, depth: i32) *glib.Variant {
    var children: std.ArrayList(*glib.Variant) = .empty;
    defer children.deinit(std.heap.smp_allocator);
    if (depth != 0) {
        if (menu.node(id)) |n| {
            for (n.children) |child| {
                children.append(std.heap.smp_allocator, glib.Variant.newVariant(menuLayout(menu, child, depth - 1))) catch break;
            }
        }
    }
    var fields = [_]*glib.Variant{
        glib.Variant.newInt32(id),
        menuProperties(menu, id),
        glib.Variant.newArray(vt("v"), children.items.ptr, children.items.len),
    };
    return glib.Variant.newTuple(&fields, fields.len);
}

// ---------------------------------------------------------------------------
// StatusNotifierItem over D-Bus
// ---------------------------------------------------------------------------

pub const Tray = struct {
    gpa: std.mem.Allocator,
    conn: *gio.DBusConnection,
    menu: Menu,
    strings: std.heap.ArenaAllocator,
    id: [:0]const u8,
    title: [:0]const u8,
    tooltip: [:0]const u8,
    icon_name: [:0]const u8,
    pixmap: ?Pixmap,
    service: [:0]const u8,
    on_menu: ?*const fn (id: []const u8, checked: ?bool) void,
    on_activate: ?*const fn () void,
    owner_id: c_uint = 0,
    watch_id: c_uint = 0,
    item_reg: c_uint = 0,
    menu_reg: c_uint = 0,
    name_owned: bool = false,
    watcher_present: bool = false,

    var instances: u32 = 0;

    pub fn create(gpa: std.mem.Allocator, options: Options) !*Tray {
        var err: ?*glib.Error = null;
        const conn = gio.busGetSync(.session, null, &err) orelse return dbusError(err, error.SessionBusUnavailable);
        errdefer conn.unref();

        const self = try gpa.create(Tray);
        errdefer gpa.destroy(self);
        instances += 1;
        self.* = .{
            .gpa = gpa,
            .conn = conn,
            .menu = .init(gpa),
            .strings = .init(gpa),
            .id = "",
            .title = "",
            .tooltip = "",
            .icon_name = "",
            .pixmap = null,
            .service = "",
            .on_menu = options.on_menu,
            .on_activate = options.on_activate,
        };
        errdefer self.menu.deinit();
        errdefer self.strings.deinit();
        const a = self.strings.allocator();
        self.id = try a.dupeZ(u8, options.id);
        self.title = try a.dupeZ(u8, options.title);
        self.tooltip = try a.dupeZ(u8, options.tooltip);
        self.service = try std.fmt.allocPrintSentinel(a, "org.kde.StatusNotifierItem-{d}-{d}", .{ std.os.linux.getpid(), instances }, 0);
        try self.applyIcon(options.icon);
        try self.menu.set(options.menu);

        const info = try nodeInfo();
        self.item_reg = conn.registerObject(item_path, info.lookupInterface(item_iface).?, &vtable, self, &noFree, &err);
        if (self.item_reg == 0) return dbusError(err, error.RegisterObjectFailed);
        self.menu_reg = conn.registerObject(menu_path, info.lookupInterface(menu_iface).?, &vtable, self, &noFree, &err);
        if (self.menu_reg == 0) return dbusError(err, error.RegisterObjectFailed);

        self.owner_id = gio.busOwnNameOnConnection(conn, self.service, .{}, &onNameAcquired, &onNameLost, self, null);
        self.watch_id = gio.busWatchNameOnConnection(conn, watcher_name, .{}, &onWatcherAppeared, &onWatcherVanished, self, null);
        return self;
    }

    pub fn deinit(self: *Tray) void {
        gio.busUnwatchName(self.watch_id);
        gio.busUnownName(self.owner_id);
        _ = self.conn.unregisterObject(self.item_reg);
        _ = self.conn.unregisterObject(self.menu_reg);
        self.conn.unref();
        if (self.pixmap) |p| p.deinit(self.gpa);
        self.menu.deinit();
        self.strings.deinit();
        self.gpa.destroy(self);
    }

    /// Replace the whole menu.
    pub fn setMenu(self: *Tray, items: []const MenuItem) !void {
        try self.menu.set(items);
        self.layoutUpdated();
    }

    pub fn setChecked(self: *Tray, id: []const u8, checked: bool) void {
        const n = self.menu.find(id) orelse return;
        n.checked = checked;
        self.menu.revision +%= 1;
        self.layoutUpdated();
    }

    pub fn isChecked(self: *Tray, id: []const u8) ?bool {
        const n = self.menu.find(id) orelse return null;
        return if (n.kind == .check) n.checked else null;
    }

    pub fn setTooltip(self: *Tray, tooltip: []const u8) !void {
        self.tooltip = try self.strings.allocator().dupeZ(u8, tooltip);
        self.signal(item_path, item_iface, "NewToolTip", null);
    }

    pub fn setTitle(self: *Tray, title: []const u8) !void {
        self.title = try self.strings.allocator().dupeZ(u8, title);
        self.signal(item_path, item_iface, "NewTitle", null);
    }

    pub fn setIcon(self: *Tray, icon: Icon) !void {
        try self.applyIcon(icon);
        self.signal(item_path, item_iface, "NewIcon", null);
    }

    fn applyIcon(self: *Tray, icon: Icon) !void {
        if (self.pixmap) |p| p.deinit(self.gpa);
        self.pixmap = null;
        self.icon_name = "";
        switch (icon) {
            .png => |bytes| self.pixmap = try pixmapFromImage(self.gpa, bytes),
            .name => |name| self.icon_name = try self.strings.allocator().dupeZ(u8, name),
        }
    }

    fn layoutUpdated(self: *Tray) void {
        var args = [_]*glib.Variant{ glib.Variant.newUint32(self.menu.revision), glib.Variant.newInt32(0) };
        self.signal(menu_path, menu_iface, "LayoutUpdated", glib.Variant.newTuple(&args, args.len));
    }

    fn signal(self: *Tray, path: [:0]const u8, iface: [:0]const u8, name: [:0]const u8, params: ?*glib.Variant) void {
        _ = self.conn.emitSignal(null, path, iface, name, params, null);
    }

    fn register(self: *Tray) void {
        if (!self.name_owned or !self.watcher_present) return;
        var args = [_]*glib.Variant{glib.Variant.newString(self.service)};
        // Async: the watcher calls back into us before replying.
        self.conn.call(watcher_name, "/StatusNotifierWatcher", watcher_name, "RegisterStatusNotifierItem", glib.Variant.newTuple(&args, args.len), null, .{}, -1, null, null, null);
        log.info("registered {s} with the tray host", .{self.service});
    }

    fn onNameAcquired(_: *gio.DBusConnection, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(data));
        self.name_owned = true;
        self.register();
    }

    fn onNameLost(_: *gio.DBusConnection, name: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(data));
        self.name_owned = false;
        log.warn("lost bus name {s}", .{name});
    }

    fn onWatcherAppeared(_: *gio.DBusConnection, _: [*:0]const u8, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(data));
        self.watcher_present = true;
        self.register(); // also re-registers after the tray host restarts
    }

    fn onWatcherVanished(_: *gio.DBusConnection, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(data));
        self.watcher_present = false;
    }

    fn click(self: *Tray, id: i32) void {
        const n = self.menu.node(id) orelse return;
        if (!n.enabled) return;
        const key = n.key;
        var checked: ?bool = null;
        switch (n.kind) {
            .item => {},
            .check => {
                n.checked = !n.checked;
                checked = n.checked;
                self.menu.revision +%= 1;
                self.layoutUpdated();
            },
            else => return,
        }
        // `key` lives in the menu arena: copy it in case on_menu calls setMenu.
        var key_buf: [256]u8 = undefined;
        const key_copy = key_buf[0..@min(key.len, key_buf.len)];
        @memcpy(key_copy, key[0..key_copy.len]);
        if (self.on_menu) |f| f(key_copy, checked);
    }

    // --- D-Bus vtable ----------------------------------------------------

    const vtable: gio.DBusInterfaceVTable = .{
        .f_method_call = &methodCall,
        .f_get_property = &getProperty,
        .f_set_property = null,
        .f_padding = undefined,
    };

    fn methodCall(
        _: *gio.DBusConnection,
        _: ?[*:0]const u8,
        _: [*:0]const u8,
        iface_z: ?[*:0]const u8,
        method_z: [*:0]const u8,
        params: *glib.Variant,
        invocation: *gio.DBusMethodInvocation,
        data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(data));
        const iface = std.mem.span(iface_z orelse "");
        const method = std.mem.span(method_z);

        if (std.mem.eql(u8, iface, item_iface)) {
            if (std.mem.eql(u8, method, "Activate") or std.mem.eql(u8, method, "SecondaryActivate")) {
                if (self.on_activate) |f| f() else oriel.App.toggleWindow();
            }
            invocation.returnValue(null); // ContextMenu/Scroll: nothing to do
            return;
        }

        if (std.mem.eql(u8, method, "GetLayout")) {
            const parent = childInt(params, 0);
            const depth = childInt(params, 1);
            var out = [_]*glib.Variant{ glib.Variant.newUint32(self.menu.revision), menuLayout(&self.menu, parent, depth) };
            invocation.returnValue(glib.Variant.newTuple(&out, out.len));
        } else if (std.mem.eql(u8, method, "GetGroupProperties")) {
            const ids = params.getChildValue(0);
            defer ids.unref();
            var items: std.ArrayList(*glib.Variant) = .empty;
            defer items.deinit(self.gpa);
            for (0..ids.nChildren()) |i| {
                const id = childInt(ids, i);
                var pair = [_]*glib.Variant{ glib.Variant.newInt32(id), menuProperties(&self.menu, id) };
                items.append(self.gpa, glib.Variant.newTuple(&pair, pair.len)) catch break;
            }
            var out = [_]*glib.Variant{glib.Variant.newArray(vt("(ia{sv})"), items.items.ptr, items.items.len)};
            invocation.returnValue(glib.Variant.newTuple(&out, out.len));
        } else if (std.mem.eql(u8, method, "GetProperty")) {
            const props = glib.Variant.refSink(menuProperties(&self.menu, childInt(params, 0)));
            defer props.unref();
            const name = params.getChildValue(1);
            defer name.unref();
            const value = g_variant_lookup_value(props, name.getString(null), null) orelse {
                invocation.returnDbusError("org.freedesktop.DBus.Error.InvalidArgs", "no such property");
                return;
            };
            var out = [_]*glib.Variant{glib.Variant.newVariant(value)};
            value.unref();
            invocation.returnValue(glib.Variant.newTuple(&out, out.len));
        } else if (std.mem.eql(u8, method, "Event")) {
            const event = params.getChildValue(1);
            defer event.unref();
            invocation.returnValue(null);
            if (std.mem.eql(u8, std.mem.span(event.getString(null)), "clicked")) self.click(childInt(params, 0));
        } else if (std.mem.eql(u8, method, "EventGroup")) {
            const group = params.getChildValue(0);
            defer group.unref();
            var none = [_]*glib.Variant{glib.Variant.newArray(vt("i"), null, 0)};
            invocation.returnValue(glib.Variant.newTuple(&none, none.len));
            for (0..group.nChildren()) |i| {
                const ev = group.getChildValue(i);
                defer ev.unref();
                const event = ev.getChildValue(1);
                defer event.unref();
                if (std.mem.eql(u8, std.mem.span(event.getString(null)), "clicked")) self.click(childInt(ev, 0));
            }
        } else if (std.mem.eql(u8, method, "AboutToShow")) {
            var out = [_]*glib.Variant{glib.Variant.newBoolean(0)};
            invocation.returnValue(glib.Variant.newTuple(&out, out.len));
        } else if (std.mem.eql(u8, method, "AboutToShowGroup")) {
            var out = [_]*glib.Variant{ glib.Variant.newArray(vt("i"), null, 0), glib.Variant.newArray(vt("i"), null, 0) };
            invocation.returnValue(glib.Variant.newTuple(&out, out.len));
        } else {
            invocation.returnDbusError("org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
        }
    }

    fn getProperty(
        _: *gio.DBusConnection,
        _: ?[*:0]const u8,
        _: [*:0]const u8,
        iface_z: [*:0]const u8,
        name_z: [*:0]const u8,
        _: **glib.Error,
        data: ?*anyopaque,
    ) callconv(.c) ?*glib.Variant {
        const self: *Tray = @ptrCast(@alignCast(data));
        const iface = std.mem.span(iface_z);
        const name = std.mem.span(name_z);
        const eql = std.mem.eql;

        if (eql(u8, iface, menu_iface)) {
            if (eql(u8, name, "Version")) return glib.Variant.newUint32(3);
            if (eql(u8, name, "TextDirection")) return glib.Variant.newString("ltr");
            if (eql(u8, name, "Status")) return glib.Variant.newString("normal");
            if (eql(u8, name, "IconThemePath")) return glib.Variant.newArray(vt("s"), null, 0);
            return null;
        }
        if (eql(u8, name, "Category")) return glib.Variant.newString("ApplicationStatus");
        if (eql(u8, name, "Id")) return glib.Variant.newString(self.id);
        if (eql(u8, name, "Title")) return glib.Variant.newString(self.title);
        if (eql(u8, name, "Status")) return glib.Variant.newString("Active");
        if (eql(u8, name, "WindowId")) return glib.Variant.newInt32(0);
        if (eql(u8, name, "IconName")) return glib.Variant.newString(self.icon_name);
        if (eql(u8, name, "IconPixmap")) return self.pixmapVariant();
        if (eql(u8, name, "IconThemePath")) return glib.Variant.newString("");
        if (eql(u8, name, "OverlayIconName") or eql(u8, name, "AttentionIconName") or eql(u8, name, "AttentionMovieName"))
            return glib.Variant.newString("");
        if (eql(u8, name, "OverlayIconPixmap") or eql(u8, name, "AttentionIconPixmap"))
            return glib.Variant.newArray(vt("(iiay)"), null, 0);
        if (eql(u8, name, "ToolTip")) {
            var fields = [_]*glib.Variant{
                glib.Variant.newString(""),
                glib.Variant.newArray(vt("(iiay)"), null, 0),
                glib.Variant.newString(self.title),
                glib.Variant.newString(self.tooltip),
            };
            return glib.Variant.newTuple(&fields, fields.len);
        }
        if (eql(u8, name, "ItemIsMenu")) return glib.Variant.newBoolean(0);
        if (eql(u8, name, "Menu")) return glib.Variant.newObjectPath(menu_path);
        return null;
    }

    fn pixmapVariant(self: *Tray) *glib.Variant {
        const p = self.pixmap orelse return glib.Variant.newArray(vt("(iiay)"), null, 0);
        var fields = [_]*glib.Variant{
            glib.Variant.newInt32(@intCast(p.width)),
            glib.Variant.newInt32(@intCast(p.height)),
            glib.Variant.newFixedArray(vt("y"), p.argb.ptr, p.argb.len, 1),
        };
        var one = [_]*glib.Variant{glib.Variant.newTuple(&fields, fields.len)};
        return glib.Variant.newArray(vt("(iiay)"), &one, one.len);
    }
};

const introspection_xml =
    \\<node>
    \\ <interface name="org.kde.StatusNotifierItem">
    \\  <property name="Category" type="s" access="read"/>
    \\  <property name="Id" type="s" access="read"/>
    \\  <property name="Title" type="s" access="read"/>
    \\  <property name="Status" type="s" access="read"/>
    \\  <property name="WindowId" type="i" access="read"/>
    \\  <property name="IconName" type="s" access="read"/>
    \\  <property name="IconPixmap" type="a(iiay)" access="read"/>
    \\  <property name="OverlayIconName" type="s" access="read"/>
    \\  <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
    \\  <property name="AttentionIconName" type="s" access="read"/>
    \\  <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
    \\  <property name="AttentionMovieName" type="s" access="read"/>
    \\  <property name="IconThemePath" type="s" access="read"/>
    \\  <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    \\  <property name="ItemIsMenu" type="b" access="read"/>
    \\  <property name="Menu" type="o" access="read"/>
    \\  <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\  <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\  <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\  <method name="Scroll"><arg name="delta" type="i" direction="in"/><arg name="orientation" type="s" direction="in"/></method>
    \\  <signal name="NewTitle"/>
    \\  <signal name="NewIcon"/>
    \\  <signal name="NewAttentionIcon"/>
    \\  <signal name="NewOverlayIcon"/>
    \\  <signal name="NewToolTip"/>
    \\  <signal name="NewStatus"><arg name="status" type="s"/></signal>
    \\ </interface>
    \\ <interface name="com.canonical.dbusmenu">
    \\  <property name="Version" type="u" access="read"/>
    \\  <property name="TextDirection" type="s" access="read"/>
    \\  <property name="Status" type="s" access="read"/>
    \\  <property name="IconThemePath" type="as" access="read"/>
    \\  <method name="GetLayout"><arg type="i" name="parentId" direction="in"/><arg type="i" name="recursionDepth" direction="in"/><arg type="as" name="propertyNames" direction="in"/><arg type="u" name="revision" direction="out"/><arg type="(ia{sv}av)" name="layout" direction="out"/></method>
    \\  <method name="GetGroupProperties"><arg type="ai" name="ids" direction="in"/><arg type="as" name="propertyNames" direction="in"/><arg type="a(ia{sv})" name="properties" direction="out"/></method>
    \\  <method name="GetProperty"><arg type="i" name="id" direction="in"/><arg type="s" name="name" direction="in"/><arg type="v" name="value" direction="out"/></method>
    \\  <method name="Event"><arg type="i" name="id" direction="in"/><arg type="s" name="eventId" direction="in"/><arg type="v" name="data" direction="in"/><arg type="u" name="timestamp" direction="in"/></method>
    \\  <method name="EventGroup"><arg type="a(isvu)" name="events" direction="in"/><arg type="ai" name="idErrors" direction="out"/></method>
    \\  <method name="AboutToShow"><arg type="i" name="id" direction="in"/><arg type="b" name="needUpdate" direction="out"/></method>
    \\  <method name="AboutToShowGroup"><arg type="ai" name="ids" direction="in"/><arg type="ai" name="updatesNeeded" direction="out"/><arg type="ai" name="idErrors" direction="out"/></method>
    \\  <signal name="ItemsPropertiesUpdated"><arg type="a(ia{sv})" name="updatedProps"/><arg type="a(ias)" name="removedProps"/></signal>
    \\  <signal name="LayoutUpdated"><arg type="u" name="revision"/><arg type="i" name="parent"/></signal>
    \\  <signal name="ItemActivationRequested"><arg type="i" name="id"/><arg type="u" name="timestamp"/></signal>
    \\ </interface>
    \\</node>
;

var node_info: ?*gio.DBusNodeInfo = null;

fn nodeInfo() !*gio.DBusNodeInfo {
    if (node_info) |n| return n;
    var err: ?*glib.Error = null;
    node_info = gio.DBusNodeInfo.newForXml(introspection_xml, &err) orelse return dbusError(err, error.BadIntrospectionXml);
    return node_info.?;
}

// --- GVariant helpers ------------------------------------------------------

// The generated binding marks the result non-null; it is NULL for a missing key.
extern fn g_variant_lookup_value(dict: *glib.Variant, key: [*:0]const u8, expected_type: ?*const glib.VariantType) ?*glib.Variant;

fn noFree(_: ?*anyopaque) callconv(.c) void {}

/// `G_VARIANT_TYPE(s)`: a GVariantType is its own type string.
fn vt(comptime s: [:0]const u8) *const glib.VariantType {
    return @ptrCast(s.ptr);
}

fn entry(comptime key: [:0]const u8, value: *glib.Variant) *glib.Variant {
    return glib.Variant.newDictEntry(glib.Variant.newString(key), glib.Variant.newVariant(value));
}

fn emptyDict() *glib.Variant {
    return glib.Variant.newArray(vt("{sv}"), null, 0);
}

fn childInt(v: *glib.Variant, index: usize) i32 {
    const c = v.getChildValue(index);
    defer c.unref();
    return c.getInt32();
}

fn dbusError(err: ?*glib.Error, fallback: anyerror) anyerror {
    if (err) |e| {
        log.err("{s}", .{e.f_message orelse "D-Bus error"});
        e.free();
    }
    return fallback;
}

// ---------------------------------------------------------------------------
// Icons
// ---------------------------------------------------------------------------

/// An icon in the format StatusNotifierItem's `IconPixmap` expects:
/// ARGB32 pixels in network (big-endian) byte order.
pub const Pixmap = struct {
    width: u32,
    height: u32,
    argb: []u8,

    pub fn deinit(self: Pixmap, gpa: std.mem.Allocator) void {
        gpa.free(self.argb);
    }
};

/// Decode a PNG (or any format zigimg supports) into an SNI pixmap.
pub fn pixmapFromImage(gpa: std.mem.Allocator, bytes: []const u8) !Pixmap {
    var image = try zigimg.Image.fromMemory(gpa, bytes);
    defer image.deinit(gpa);
    try image.convert(gpa, .rgba32);

    const pixels = image.pixels.rgba32;
    const argb = try gpa.alloc(u8, pixels.len * 4);
    for (pixels, 0..) |p, i| {
        argb[i * 4 + 0] = p.a;
        argb[i * 4 + 1] = p.r;
        argb[i * 4 + 2] = p.g;
        argb[i * 4 + 3] = p.b;
    }
    return .{ .width = @intCast(image.width), .height = @intCast(image.height), .argb = argb };
}

/// Whether a StatusNotifierWatcher (the tray host) owns its bus name.
pub fn watcherAvailable() !bool {
    var err: ?*glib.Error = null;
    const bus = gio.busGetSync(.session, null, &err) orelse return dbusError(err, error.SessionBusUnavailable);
    defer bus.unref();

    var name_arg = [_]*glib.Variant{glib.Variant.newString(watcher_name)};
    const reply = bus.callSync(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "NameHasOwner",
        glib.Variant.newTuple(&name_arg, name_arg.len),
        null,
        .{},
        1000,
        null,
        &err,
    ) orelse return dbusError(err, error.DBusCallFailed);
    defer reply.unref();
    return childBool(reply, 0);
}

fn childBool(v: *glib.Variant, index: usize) bool {
    const c = v.getChildValue(index);
    defer c.unref();
    return c.getBoolean() != 0;
}

fn printVariant(gpa: std.mem.Allocator, v: *glib.Variant) ![]u8 {
    const sunk = glib.Variant.refSink(v);
    defer sunk.unref();
    const text = sunk.print(0);
    defer glib.free(text);
    return gpa.dupe(u8, std.mem.span(text));
}

pub fn check(gpa: std.mem.Allocator, ctx: oriel.CheckContext) !oriel.Check {
    const pixmap = try pixmapFromImage(gpa, ctx.icon_png);
    defer pixmap.deinit(gpa);
    var menu: Menu = .init(gpa);
    defer menu.deinit();
    try menu.set(&.{
        .{ .item = .{ .id = "show", .label = "Show" } },
        .separator,
        .{ .item = .{ .id = "quit", .label = "Quit" } },
    });
    const layout = try printVariant(gpa, menuLayout(&menu, 0, -1));
    defer gpa.free(layout);
    const watcher = try watcherAvailable();
    return .{
        .module = "tray",
        .ok = std.mem.indexOf(u8, layout, "'Quit'") != null,
        .detail = try std.fmt.allocPrint(gpa, "icon {d}x{d} ARGB32; dbusmenu layout with {d} items; tray host {s}", .{
            pixmap.width,
            pixmap.height,
            menu.nodes.items.len - 1,
            if (watcher) "present" else "absent",
        }),
    };
}

test "menu layout" {
    var menu: Menu = .init(std.testing.allocator);
    defer menu.deinit();
    try menu.set(&.{
        .{ .item = .{ .id = "show", .label = "Show" } },
        .{ .check = .{ .id = "mute", .label = "Mute", .checked = true } },
        .separator,
        .{ .submenu = .{ .label = "More", .items = &.{.{ .item = .{ .id = "about", .label = "About", .enabled = false } }} } },
    });
    try std.testing.expectEqual(6, menu.nodes.items.len);
    try std.testing.expectEqualStrings("about", menu.find("about").?.key);

    const text = try printVariant(std.testing.allocator, menuLayout(&menu, 0, -1));
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "(0, {'children-display': <'submenu'>}, [<(1, {'label': <'Show'>, 'enabled': <true>}, @av [])>, " ++
            "<(2, {'label': <'Mute'>, 'enabled': <true>, 'toggle-type': <'checkmark'>, 'toggle-state': <1>}, @av [])>, " ++
            "<(3, {'type': <'separator'>}, @av [])>, " ++
            "<(4, {'label': <'More'>, 'enabled': <true>, 'children-display': <'submenu'>}, [<(5, {'label': <'About'>, 'enabled': <false>}, @av [])>])>])",
        text,
    );

    // Depth 0: the item itself, no children.
    const shallow = try printVariant(std.testing.allocator, menuLayout(&menu, 4, 0));
    defer std.testing.allocator.free(shallow);
    try std.testing.expectEqualStrings("(4, {'label': <'More'>, 'enabled': <true>, 'children-display': <'submenu'>}, [])", shallow);
}
