//! Bluetooth LE advertising through BlueZ over the D-Bus system bus.
//!
//! The adapter is found with `org.freedesktop.DBus.ObjectManager` on
//! `org.bluez` (the first object with `org.bluez.LEAdvertisingManager1`,
//! a powered one preferred). Each advertisement is an object at
//! `/dev/oriel/adv<N>` implementing `org.bluez.LEAdvertisement1`, handed to
//! `LEAdvertisingManager1.RegisterAdvertisement` asynchronously: the reply
//! comes as the advertisement's state (`started` or `failed`), and BlueZ's
//! `Release` (it dropped the advertisement: the adapter went off) as
//! `stopped`. The adapter is never powered on here: that's the app's call.
//!
//! Threads: `advertise` and `stop` run on any thread. The object's D-Bus
//! calls (BlueZ reading its properties, `Release`) and the register reply
//! run on the default GLib main context (the GTK main thread), as the rest
//! of Oriel's GIO code does. Flatpak needs `--system-talk-name=org.bluez`.

const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const common = @import("common.zig");

const Advertisement = common.Advertisement;
const Capabilities = common.Capabilities;
const Handle = common.Handle;

const log = std.log.scoped(.bluetooth);

pub const backend = "BlueZ";

const bluez = "org.bluez";
const manager_iface = "org.bluez.LEAdvertisingManager1";
const adapter_iface = "org.bluez.Adapter1";
const advertisement_iface = "org.bluez.LEAdvertisement1";
const path_prefix = "/dev/oriel/adv";
/// GetManagedObjects' timeout: BlueZ answers at once, or isn't there.
const query_timeout_ms = 3000;

// ---------------------------------------------------------------------------
// The API

/// What the adapter can advertise now; `.{}` without bluetoothd or an
/// adapter (or without a system bus).
pub fn capabilities() Capabilities {
    const conn = connection() orelse return .{};
    const adapter = findAdapter(conn) catch return .{};
    return capabilitiesOf(adapter);
}

/// Export `ad` as an LEAdvertisement1 object and ask BlueZ to register it
/// (validated by bluetooth.zig). The handle comes back at once; BlueZ's
/// answer comes as the advertisement's state.
pub fn advertise(ad: Advertisement) common.Error!Handle {
    const conn = connection() orelse return error.Unsupported;
    const adapter = (findAdapter(conn) catch |err| return switch (err) {
        error.PermissionDenied => error.PermissionDenied,
        error.Unavailable => error.Unsupported,
    }) orelse return error.Unsupported;
    try common.checkSize(ad, if (ad.local_name) adapter.alias_len else 0, common.legacy_max);
    if (!adapter.powered) return error.AdapterOff;

    const info = interfaceInfo() orelse return error.Failed;
    const gpa = std.heap.smp_allocator;
    const handle = nextHandle();
    var path_buf: [path_prefix.len + 16]u8 = undefined;
    const path = objectPath(&path_buf, handle);
    const adapter_path = gpa.dupeZ(u8, adapter.path()) catch return error.Failed;
    errdefer gpa.free(adapter_path);

    const object = gpa.create(Object) catch return error.Failed;
    object.* = .{ .handle = handle, .props = glib.Variant.refSink(properties(ad, adapter.txOptions())) };
    var err: ?*glib.Error = null;
    // GDBus frees `object` (freeObject) once it's unregistered and no call
    // to it is still running.
    const reg = conn.registerObject(path, info, &vtable, object, &freeObject, &err);
    if (reg == 0) {
        logError("export the advertisement", err);
        freeObject(object);
        return error.Failed;
    }

    {
        table_mutex.lock();
        defer table_mutex.unlock();
        table.append(gpa, .{ .handle = handle, .conn = conn, .reg = reg, .adapter = adapter_path }) catch {
            _ = conn.unregisterObject(reg);
            return error.Failed;
        };
    }

    var options = [_]*glib.Variant{ glib.Variant.newObjectPath(path), emptyDict() };
    conn.call(bluez, adapter_path, manager_iface, "RegisterAdvertisement", glib.Variant.newTuple(&options, options.len), null, .{}, -1, null, &onRegistered, handleData(handle));
    return handle;
}

/// Unregister the advertisement from BlueZ and drop its object. An unknown
/// (or already stopped) handle is ignored.
pub fn stop(handle: Handle) void {
    const slot = take(handle) orelse return;
    defer std.heap.smp_allocator.free(slot.adapter);
    var path_buf: [path_prefix.len + 16]u8 = undefined;
    var args = [_]*glib.Variant{glib.Variant.newObjectPath(objectPath(&path_buf, handle))};
    // Fire and forget: if the register reply is still pending, BlueZ can't
    // read the (gone) object and fails it, and this answers DoesNotExist.
    slot.conn.call(bluez, slot.adapter, manager_iface, "UnregisterAdvertisement", glib.Variant.newTuple(&args, args.len), null, .{}, -1, null, null, null);
    _ = slot.conn.unregisterObject(slot.reg);
}

// ---------------------------------------------------------------------------
// The adapter

/// The adapter's state from GetManagedObjects (what `capabilities` and
/// `advertise` need).
pub const Adapter = struct {
    path_buf: [96]u8 = undefined,
    path_len: usize = 0,
    powered: bool = false,
    /// The name BlueZ puts in "local-name" (Alias), in bytes.
    alias_len: usize = 0,
    /// LEAdvertisingManager1.SupportedInstances: null when not reported.
    instances: ?u8 = null,
    /// SupportedIncludes has "local-name".
    local_name: bool = false,
    /// SupportedSecondaryChannels is non-empty (extended advertising).
    secondary_channels: bool = false,
    /// SupportedCapabilities.MaxAdvLen.
    max_adv_len: ?u8 = null,
    /// SupportedFeatures has "CanSetTxPower".
    can_set_tx_power: bool = false,
    min_tx_power: ?i16 = null,
    max_tx_power: ?i16 = null,

    pub fn path(self: *const Adapter) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn txOptions(self: Adapter) TxOptions {
        return .{ .supported = self.can_set_tx_power, .min = self.min_tx_power, .max = self.max_tx_power };
    }
};

/// The adapter to advertise on in GetManagedObjects' `a{oa{sa{sv}}}`: the
/// first with LEAdvertisingManager1, or the first powered one of those.
pub fn pickAdapter(objects: *glib.Variant) ?Adapter {
    var first: ?Adapter = null;
    const n = objects.nChildren();
    for (0..n) |i| {
        const object = objects.getChildValue(i);
        defer object.unref();
        const path_v = object.getChildValue(0);
        defer path_v.unref();
        const ifaces = object.getChildValue(1);
        defer ifaces.unref();

        const manager = lookup(ifaces, manager_iface, vt("a{sv}")) orelse continue;
        defer manager.unref();
        const object_path = std.mem.span(path_v.getString(null));
        var a: Adapter = .{};
        if (object_path.len > a.path_buf.len) continue;
        @memcpy(a.path_buf[0..object_path.len], object_path);
        a.path_len = object_path.len;
        readManager(&a, manager);
        if (lookup(ifaces, adapter_iface, vt("a{sv}"))) |props| {
            defer props.unref();
            readAdapter(&a, props);
        }
        if (a.powered) return a;
        if (first == null) first = a;
    }
    return first;
}

fn readAdapter(a: *Adapter, props: *glib.Variant) void {
    if (lookup(props, "Powered", vt("b"))) |v| {
        defer v.unref();
        a.powered = v.getBoolean() != 0;
    }
    const name = lookup(props, "Alias", vt("s")) orelse lookup(props, "Name", vt("s"));
    if (name) |v| {
        defer v.unref();
        a.alias_len = std.mem.span(v.getString(null)).len;
    }
}

fn readManager(a: *Adapter, props: *glib.Variant) void {
    if (lookup(props, "SupportedInstances", vt("y"))) |v| {
        defer v.unref();
        a.instances = v.getByte();
    }
    a.local_name = hasString(props, "SupportedIncludes", "local-name");
    a.can_set_tx_power = hasString(props, "SupportedFeatures", "CanSetTxPower");
    if (lookup(props, "SupportedSecondaryChannels", vt("as"))) |v| {
        defer v.unref();
        a.secondary_channels = v.nChildren() > 0;
    }
    if (lookup(props, "SupportedCapabilities", vt("a{sv}"))) |caps| {
        defer caps.unref();
        if (lookup(caps, "MaxAdvLen", vt("y"))) |v| {
            defer v.unref();
            a.max_adv_len = v.getByte();
        }
        if (lookup(caps, "MinTxPower", vt("n"))) |v| {
            defer v.unref();
            a.min_tx_power = v.getInt16();
        }
        if (lookup(caps, "MaxTxPower", vt("n"))) |v| {
            defer v.unref();
            a.max_tx_power = v.getInt16();
        }
    }
}

/// `capabilities()` for the adapter found (null: none).
pub fn capabilitiesOf(adapter: ?Adapter) Capabilities {
    const a = adapter orelse return .{};
    const can = (a.instances orelse 1) > 0;
    const f = common.fieldsOf(.linux);
    const max: u16 = a.max_adv_len orelse common.legacy_max;
    return .{
        .advertise = can,
        .service_data = can and f.service_data,
        .local_name = can and f.local_name and a.local_name,
        .connectable = can and f.connectable,
        .non_connectable = can and f.non_connectable,
        .extended = can and (a.secondary_channels or max > common.legacy_max),
        .max_bytes = if (can) max else 0,
        .scan = false, // no scanning API yet
        .scan_service_data = false,
        .powered = a.powered,
    };
}

const QueryError = error{ PermissionDenied, Unavailable };

/// BlueZ's adapter, if any. error.Unavailable: no bluetoothd (it isn't
/// started for this).
fn findAdapter(conn: *gio.DBusConnection) QueryError!?Adapter {
    var err: ?*glib.Error = null;
    const reply = conn.callSync(bluez, "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", null, vt("(a{oa{sa{sv}}})"), .{ .no_auto_start = true }, query_timeout_ms, null, &err) orelse {
        const e = errorOf(err);
        if (err) |ge| {
            log.debug("GetManagedObjects: {s}", .{ge.f_message orelse "unknown error"});
            ge.free();
        }
        return if (e == error.PermissionDenied) error.PermissionDenied else error.Unavailable;
    };
    defer reply.unref();
    const objects = reply.getChildValue(0);
    defer objects.unref();
    return pickAdapter(objects);
}

// ---------------------------------------------------------------------------
// LEAdvertisement1's properties

/// TxPower, when BlueZ can set it (SupportedFeatures "CanSetTxPower"),
/// clamped to the controller's range.
pub const TxOptions = struct { supported: bool = false, min: ?i16 = null, max: ?i16 = null };

/// AdvertiseSettings' intervals on Android, in ms (MinInterval/MaxInterval).
pub fn intervalMs(mode: common.Mode) u32 {
    return switch (mode) {
        .low_latency => 100,
        .balanced => 250,
        .low_power => 1000,
    };
}

/// AdvertiseSettings' power levels on Android, in dBm (TxPower).
pub fn txPowerDbm(power: common.TxPower) i16 {
    return switch (power) {
        .high => 1,
        .medium => -7,
        .low => -15,
        .ultra_low => -21,
    };
}

/// A 16-bit UUID as BlueZ's full form: "0000xxxx-0000-1000-8000-00805f9b34fb".
pub fn uuid128(uuid16: u16) [36:0]u8 {
    var out: [36:0]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "0000{x:0>4}-0000-1000-8000-00805f9b34fb", .{uuid16}) catch unreachable;
    out[36] = 0;
    return out;
}

/// The advertisement's LEAdvertisement1 properties as `a{sv}` (floating).
/// MinInterval/MaxInterval are always set (BlueZ before 5.56 doesn't read
/// them); TxPower only where BlueZ can set it.
pub fn properties(ad: Advertisement, tx: TxOptions) *glib.Variant {
    var entries: [7]*glib.Variant = undefined;
    var n: usize = 0;
    entries[n] = entry("Type", glib.Variant.newString(if (ad.connectable) "peripheral" else "broadcast"));
    n += 1;
    if (ad.service_uuids16.len > 0) {
        // checkSize caps the list well below this (31 bytes: 14 UUIDs).
        var uuids: [16]*glib.Variant = undefined;
        const count = @min(ad.service_uuids16.len, uuids.len);
        for (ad.service_uuids16[0..count], 0..) |u, i| {
            const s = uuid128(u);
            uuids[i] = glib.Variant.newString(&s);
        }
        entries[n] = entry("ServiceUUIDs", glib.Variant.newArray(vt("s"), &uuids, count));
        n += 1;
    }
    if (ad.service_data) |sd| {
        const key = uuid128(sd.uuid16);
        const bytes = glib.Variant.newFixedArray(vt("y"), sd.data.ptr, sd.data.len, 1);
        var one = [_]*glib.Variant{glib.Variant.newDictEntry(glib.Variant.newString(&key), glib.Variant.newVariant(bytes))};
        entries[n] = entry("ServiceData", glib.Variant.newArray(vt("{sv}"), &one, one.len));
        n += 1;
    }
    if (ad.local_name) {
        var includes = [_]*glib.Variant{glib.Variant.newString("local-name")};
        entries[n] = entry("Includes", glib.Variant.newArray(vt("s"), &includes, includes.len));
        n += 1;
    }
    const ms = intervalMs(ad.mode);
    entries[n] = entry("MinInterval", glib.Variant.newUint32(ms));
    entries[n + 1] = entry("MaxInterval", glib.Variant.newUint32(ms));
    n += 2;
    if (tx.supported) {
        var dbm = txPowerDbm(ad.tx_power);
        if (tx.max) |max| dbm = @min(dbm, max);
        if (tx.min) |min| dbm = @max(dbm, min);
        entries[n] = entry("TxPower", glib.Variant.newInt16(dbm));
        n += 1;
    }
    return glib.Variant.newArray(vt("{sv}"), &entries, n);
}

/// A D-Bus error name (BlueZ's or the bus') as Oriel's error.
pub fn errorOfName(name: []const u8) common.Error {
    const map = [_]struct { []const u8, common.Error }{
        .{ "org.bluez.Error.InvalidLength", error.TooLarge },
        .{ "org.bluez.Error.NotPermitted", error.PermissionDenied },
        .{ "org.bluez.Error.NotAuthorized", error.PermissionDenied },
        .{ "org.freedesktop.DBus.Error.AccessDenied", error.PermissionDenied },
        .{ "org.bluez.Error.NotReady", error.AdapterOff },
        .{ "org.bluez.Error.NotSupported", error.Unsupported },
    };
    for (map) |m| if (std.mem.eql(u8, name, m[0])) return m[1];
    return error.Failed;
}

fn errorOf(err: ?*glib.Error) common.Error {
    const e = err orelse return error.Failed;
    const name = g_dbus_error_get_remote_error(e) orelse return error.Failed;
    defer glib.free(name);
    return errorOfName(std.mem.span(name));
}

// ---------------------------------------------------------------------------
// The exported objects and the handle table

/// An exported advertisement: its properties, read by BlueZ. Owned by its
/// GDBus registration (freeObject).
const Object = struct {
    handle: Handle,
    props: *glib.Variant,
};

fn freeObject(data: ?*anyopaque) callconv(.c) void {
    const object: *Object = @ptrCast(@alignCast(data));
    object.props.unref();
    std.heap.smp_allocator.destroy(object);
}

/// A live advertisement.
const Slot = struct {
    handle: Handle,
    conn: *gio.DBusConnection,
    reg: c_uint,
    /// The adapter's object path (owned).
    adapter: [:0]u8,
};

/// Static GMutexes need no g_mutex_init.
var table_mutex: glib.Mutex = .{ .f_p = null };
var table: std.ArrayList(Slot) = .empty;
var next_handle: std.atomic.Value(Handle) = .init(1);

fn nextHandle() Handle {
    while (true) {
        const h = next_handle.fetchAdd(1, .monotonic);
        if (h != 0) return h;
    }
}

/// Remove `handle` from the table (the caller owns the slot's adapter path).
fn take(handle: Handle) ?Slot {
    table_mutex.lock();
    defer table_mutex.unlock();
    for (table.items, 0..) |s, i| {
        if (s.handle == handle) return table.swapRemove(i);
    }
    return null;
}

fn contains(handle: Handle) bool {
    table_mutex.lock();
    defer table_mutex.unlock();
    for (table.items) |s| {
        if (s.handle == handle) return true;
    }
    return false;
}

/// Drop `handle`'s object without telling BlueZ (it already dropped it, or
/// refused it). False if it was already gone (stopped).
fn drop(handle: Handle) bool {
    const slot = take(handle) orelse return false;
    _ = slot.conn.unregisterObject(slot.reg);
    std.heap.smp_allocator.free(slot.adapter);
    return true;
}

fn objectPath(buf: []u8, handle: Handle) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, path_prefix ++ "{d}", .{handle}) catch unreachable;
}

fn handleData(handle: Handle) ?*anyopaque {
    return @ptrFromInt(@as(usize, handle));
}

/// RegisterAdvertisement's reply: the advertisement started, or failed.
fn onRegistered(source: ?*gobject.Object, res: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const handle: Handle = @intCast(@intFromPtr(data));
    const conn: *gio.DBusConnection = @ptrCast(source orelse return);
    var err: ?*glib.Error = null;
    if (conn.callFinish(res, &err)) |reply| {
        reply.unref();
        // Stopped before BlueZ answered: nothing to report.
        if (contains(handle)) common.dispatchState(handle, .started, null);
        return;
    }
    const e = errorOf(err);
    if (err) |ge| {
        log.debug("RegisterAdvertisement: {s}", .{ge.f_message orelse "unknown error"});
        ge.free();
    }
    if (drop(handle)) common.dispatchState(handle, .failed, e);
}

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
    _: ?[*:0]const u8,
    method_z: [*:0]const u8,
    _: *glib.Variant,
    invocation: *gio.DBusMethodInvocation,
    data: ?*anyopaque,
) callconv(.c) void {
    const object: *Object = @ptrCast(@alignCast(data));
    if (!std.mem.eql(u8, std.mem.span(method_z), "Release")) {
        invocation.returnDbusError("org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
        return;
    }
    invocation.returnValue(null);
    // BlueZ dropped it (the adapter went off, bluetoothd stopped): it's
    // already unregistered there. `object` stays valid until this returns.
    const handle = object.handle;
    if (drop(handle)) common.dispatchState(handle, .stopped, null);
}

fn getProperty(
    _: *gio.DBusConnection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    name_z: [*:0]const u8,
    err: **glib.Error,
    data: ?*anyopaque,
) callconv(.c) ?*glib.Variant {
    const object: *Object = @ptrCast(@alignCast(data));
    // Absent (an optional property this advertisement doesn't set): GetAll
    // skips it, Get needs the error.
    return lookup(object.props, name_z, null) orelse {
        g_set_error_literal(err, gio.DBusError.quark(), @intFromEnum(gio.DBusError.invalid_args), "property not set");
        return null;
    };
}

const introspection_xml =
    \\<node>
    \\ <interface name="org.bluez.LEAdvertisement1">
    \\  <method name="Release"/>
    \\  <property name="Type" type="s" access="read"/>
    \\  <property name="ServiceUUIDs" type="as" access="read"/>
    \\  <property name="ServiceData" type="a{sv}" access="read"/>
    \\  <property name="Includes" type="as" access="read"/>
    \\  <property name="MinInterval" type="u" access="read"/>
    \\  <property name="MaxInterval" type="u" access="read"/>
    \\  <property name="TxPower" type="n" access="read"/>
    \\ </interface>
    \\</node>
;

var node_info: ?*gio.DBusNodeInfo = null;

/// LEAdvertisement1's interface info (parsed once, kept for the process).
fn interfaceInfo() ?*gio.DBusInterfaceInfo {
    table_mutex.lock();
    defer table_mutex.unlock();
    if (node_info == null) {
        var err: ?*glib.Error = null;
        node_info = gio.DBusNodeInfo.newForXml(introspection_xml, &err) orelse {
            logError("LEAdvertisement1 introspection", err);
            return null;
        };
    }
    return node_info.?.lookupInterface(advertisement_iface);
}

// ---------------------------------------------------------------------------
// The system bus

var bus_mutex: glib.Mutex = .{ .f_p = null };
var bus: ?*gio.DBusConnection = null;
/// Tests: a private bus with a mock BlueZ instead of the system bus.
var bus_override: ?*gio.DBusConnection = null;

/// The system bus (a reference kept for the process), or null without one.
fn connection() ?*gio.DBusConnection {
    bus_mutex.lock();
    defer bus_mutex.unlock();
    if (bus_override) |c| return c;
    // A closed connection (the bus restarted) is leaked, not unreffed: a
    // slot or another thread may still hold it.
    if (bus) |c| if (c.isClosed() == 0) return c;
    var err: ?*glib.Error = null;
    bus = gio.busGetSync(.system, null, &err);
    if (bus == null) if (err) |e| {
        log.debug("no system bus: {s}", .{e.f_message orelse "unknown error"});
        e.free();
    };
    return bus;
}

// ---------------------------------------------------------------------------
// GVariant helpers

// The generated bindings mark these results non-null; they are NULL for a
// missing key / a local error.
extern fn g_variant_lookup_value(dict: *glib.Variant, key: [*:0]const u8, expected_type: ?*const glib.VariantType) ?*glib.Variant;
extern fn g_dbus_error_get_remote_error(err: *const glib.Error) ?[*:0]u8;
extern fn g_set_error_literal(err: ?**glib.Error, domain: glib.Quark, code: c_int, message: [*:0]const u8) void;

fn lookup(dict: *glib.Variant, key: [*:0]const u8, expected: ?*const glib.VariantType) ?*glib.Variant {
    return g_variant_lookup_value(dict, key, expected);
}

/// The `as` property `key` of `dict` lists `value`.
fn hasString(dict: *glib.Variant, key: [*:0]const u8, value: []const u8) bool {
    const list = lookup(dict, key, vt("as")) orelse return false;
    defer list.unref();
    for (0..list.nChildren()) |i| {
        const s = list.getChildValue(i);
        defer s.unref();
        if (std.mem.eql(u8, std.mem.span(s.getString(null)), value)) return true;
    }
    return false;
}

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

fn logError(what: []const u8, err: ?*glib.Error) void {
    const e = err orelse return log.warn("{s} failed", .{what});
    log.warn("{s}: {s}", .{ what, e.f_message orelse "unknown error" });
    e.free();
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn printVariant(v: *glib.Variant) ![]u8 {
    const sunk = glib.Variant.refSink(v);
    defer sunk.unref();
    const text = sunk.print(0);
    defer glib.free(text);
    return testing.allocator.dupe(u8, std.mem.span(text));
}

fn parse(comptime type_string: [:0]const u8, text: [:0]const u8) !*glib.Variant {
    var err: ?*glib.Error = null;
    const v = glib.Variant.parse(vt(type_string), text, null, null, &err) orelse {
        if (err) |e| {
            std.debug.print("parse: {s}\n", .{e.f_message orelse "?"});
            e.free();
        }
        return error.ParseFailed;
    };
    return v; // non-floating
}

test uuid128 {
    try testing.expectEqualStrings("0000fe2c-0000-1000-8000-00805f9b34fb", &uuid128(0xFE2C));
    try testing.expectEqualStrings("0000180f-0000-1000-8000-00805f9b34fb", &uuid128(0x180F));
    try testing.expectEqualStrings("00000001-0000-1000-8000-00805f9b34fb", &uuid128(1));
}

test errorOfName {
    try testing.expectEqual(error.TooLarge, errorOfName("org.bluez.Error.InvalidLength"));
    try testing.expectEqual(error.PermissionDenied, errorOfName("org.bluez.Error.NotPermitted"));
    try testing.expectEqual(error.PermissionDenied, errorOfName("org.freedesktop.DBus.Error.AccessDenied"));
    try testing.expectEqual(error.AdapterOff, errorOfName("org.bluez.Error.NotReady"));
    try testing.expectEqual(error.Unsupported, errorOfName("org.bluez.Error.NotSupported"));
    try testing.expectEqual(error.Failed, errorOfName("org.bluez.Error.Failed"));
    try testing.expectEqual(error.Failed, errorOfName(""));
}

test "properties: the FE2C beacon, broadcast" {
    const payload = [_]u8{ 1, 2, 3 };
    const text = try printVariant(properties(.{ .service_data = .{ .uuid16 = 0xFE2C, .data = &payload } }, .{}));
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("{'Type': <'broadcast'>, " ++
        "'ServiceData': <{'0000fe2c-0000-1000-8000-00805f9b34fb': <[byte 0x01, 0x02, 0x03]>}>, " ++
        "'MinInterval': <uint32 250>, 'MaxInterval': <uint32 250>}", text);
}

test "properties: uuids, local name, connectable, tx power clamped" {
    const uuids = [_]u16{ 0x180F, 0x181C };
    const ad: Advertisement = .{ .service_uuids16 = &uuids, .local_name = true, .connectable = true, .mode = .low_latency, .tx_power = .high };
    const text = try printVariant(properties(ad, .{ .supported = true, .min = -20, .max = 0 }));
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("{'Type': <'peripheral'>, " ++
        "'ServiceUUIDs': <['0000180f-0000-1000-8000-00805f9b34fb', '0000181c-0000-1000-8000-00805f9b34fb']>, " ++
        "'Includes': <['local-name']>, 'MinInterval': <uint32 100>, 'MaxInterval': <uint32 100>, 'TxPower': <int16 0>}", text);

    const low = try printVariant(properties(.{ .local_name = true, .tx_power = .ultra_low }, .{ .supported = true, .min = -20 }));
    defer testing.allocator.free(low);
    try testing.expect(std.mem.indexOf(u8, low, "'TxPower': <int16 -20>") != null);
}

const two_adapters =
    \\({objectpath '/org/bluez/hci0': {'org.bluez.Adapter1': {'Powered': <false>, 'Alias': <'off'>},
    \\    'org.bluez.LEAdvertisingManager1': {'SupportedInstances': <byte 4>}},
    \\  '/org/bluez/hci0/dev_00_11_22_33_44_55': {'org.bluez.Device1': {'Alias': <'phone'>}},
    \\  '/org/bluez/hci1': {'org.bluez.Adapter1': {'Powered': <true>, 'Alias': <'laptop'>},
    \\    'org.bluez.LEAdvertisingManager1': {'SupportedInstances': <byte 5>, 'SupportedIncludes': <['tx-power', 'local-name']>,
    \\      'SupportedSecondaryChannels': <['1M', '2M']>, 'SupportedFeatures': <['CanSetTxPower']>,
    \\      'SupportedCapabilities': <{'MaxAdvLen': <byte 251>, 'MinTxPower': <int16 -34>, 'MaxTxPower': <int16 10>}>}}},)
;

test "pickAdapter: prefers a powered adapter" {
    const reply = try parse("(a{oa{sa{sv}}})", two_adapters);
    defer reply.unref();
    const objects = reply.getChildValue(0);
    defer objects.unref();
    const a = pickAdapter(objects).?;
    try testing.expectEqualStrings("/org/bluez/hci1", a.path());
    try testing.expect(a.powered and a.local_name and a.secondary_channels and a.can_set_tx_power);
    try testing.expectEqual(@as(usize, 6), a.alias_len);
    try testing.expectEqual(@as(?u8, 5), a.instances);
    try testing.expectEqual(@as(?u8, 251), a.max_adv_len);
    try testing.expectEqual(@as(?i16, -34), a.min_tx_power);
    try testing.expectEqual(@as(?i16, 10), a.max_tx_power);

    const c = capabilitiesOf(a);
    try testing.expect(c.advertise and c.service_data and c.local_name and c.connectable and c.non_connectable and c.extended and c.powered);
    try testing.expectEqual(@as(u16, 251), c.max_bytes);
}

test "pickAdapter: an adapter that is off, a legacy one, none" {
    const off = try parse("(a{oa{sa{sv}}})",
        \\({objectpath '/org/bluez/hci0': {'org.bluez.Adapter1': {'Powered': <false>, 'Alias': <'off'>},
        \\  'org.bluez.LEAdvertisingManager1': {'SupportedInstances': <byte 0>}}},)
    );
    defer off.unref();
    const off_objects = off.getChildValue(0);
    defer off_objects.unref();
    const a = pickAdapter(off_objects).?;
    try testing.expectEqualStrings("/org/bluez/hci0", a.path());
    try testing.expect(!a.powered and !a.local_name);
    // No instances left: nothing to advertise with.
    try testing.expectEqual(Capabilities{}, capabilitiesOf(a));

    // An older BlueZ: no SupportedInstances, no SupportedCapabilities.
    var legacy: Adapter = .{ .powered = true };
    const c = capabilitiesOf(legacy);
    try testing.expect(c.advertise and !c.local_name and !c.extended and c.powered);
    try testing.expectEqual(@as(u16, 31), c.max_bytes);
    legacy.local_name = true;
    try testing.expect(capabilitiesOf(legacy).local_name);

    const none = try parse("(a{oa{sa{sv}}})", "({objectpath '/org/bluez': {'org.bluez.AgentManager1': @a{sv} {}}},)");
    defer none.unref();
    const none_objects = none.getChildValue(0);
    defer none_objects.unref();
    try testing.expect(pickAdapter(none_objects) == null);
    try testing.expectEqual(Capabilities{}, capabilitiesOf(null));
}

test "capabilities and stop without BlueZ don't fail" {
    // On this host there may be no system bus, no bluetoothd or no adapter:
    // whatever it is, nothing crashes and the answer is consistent.
    const c = capabilities();
    if (!c.advertise) try testing.expectEqual(@as(u16, 0), c.max_bytes);
    stop(0xFFFF_FFF0); // unknown: ignored
}

// --- A mock BlueZ on a private bus (GTestDBus) ------------------------------

/// org.bluez on the test bus, on its own thread and main context (as
/// bluetoothd is another process: `capabilities()` blocks on it).
const Mock = struct {
    address: [*:0]const u8,
    /// GetManagedObjects' reply.
    objects: std.atomic.Value([*:0]const u8),
    /// RegisterAdvertisement answers this D-Bus error, if set.
    fail_with: std.atomic.Value(?[*:0]const u8) = .init(null),
    /// The last registered advertisement's properties as read back (GetAll)
    /// and its path; written before `registered` counts it.
    props: ?[]u8 = null,
    registered_path: [64]u8 = undefined,
    registered_len: usize = 0,
    registered: std.atomic.Value(u32) = .init(0),
    unregistered: std.atomic.Value(u32) = .init(0),
    /// The RegisterAdvertisement waiting for its GetAll.
    pending: ?*gio.DBusMethodInvocation = null,
    conn: ?*gio.DBusConnection = null,
    ready: std.atomic.Value(bool) = .init(false),
    setup_failed: bool = false,
    quit: std.atomic.Value(bool) = .init(false),

    const xml =
        \\<node>
        \\ <interface name="org.freedesktop.DBus.ObjectManager">
        \\  <method name="GetManagedObjects"><arg type="a{oa{sa{sv}}}" direction="out"/></method>
        \\ </interface>
        \\ <interface name="org.bluez.LEAdvertisingManager1">
        \\  <method name="RegisterAdvertisement"><arg type="o" direction="in"/><arg type="a{sv}" direction="in"/></method>
        \\  <method name="UnregisterAdvertisement"><arg type="o" direction="in"/></method>
        \\ </interface>
        \\</node>
    ;

    fn run(self: *Mock) void {
        const ctx = glib.MainContext.new();
        defer ctx.unref();
        ctx.pushThreadDefault();
        defer ctx.popThreadDefault();
        var regs: [2]c_uint = .{ 0, 0 };
        var info: ?*gio.DBusNodeInfo = null;
        self.setup(&regs, &info) catch {
            self.setup_failed = true;
        };
        self.ready.store(true, .release);
        while (!self.quit.load(.acquire)) {
            while (ctx.iteration(0) != 0) {}
            glib.usleep(500);
        }
        if (self.conn) |c| {
            for (regs) |r| if (r != 0) {
                _ = c.unregisterObject(r);
            };
            _ = c.closeSync(null, null);
            c.unref();
        }
        if (info) |i| i.unref();
        while (ctx.iteration(0) != 0) {}
    }

    fn setup(self: *Mock, regs: *[2]c_uint, info_out: *?*gio.DBusNodeInfo) !void {
        const conn = try connect(self.address);
        self.conn = conn;
        var err: ?*glib.Error = null;
        const info = gio.DBusNodeInfo.newForXml(xml, &err) orelse return error.BadXml;
        info_out.* = info;
        regs[0] = conn.registerObject("/", info.lookupInterface("org.freedesktop.DBus.ObjectManager").?, &mock_vtable, self, &noFree, &err);
        if (regs[0] == 0) return error.RegisterFailed;
        regs[1] = conn.registerObject("/org/bluez/hci0", info.lookupInterface(manager_iface).?, &mock_vtable, self, &noFree, &err);
        if (regs[1] == 0) return error.RegisterFailed;
        var args = [_]*glib.Variant{ glib.Variant.newString(bluez), glib.Variant.newUint32(4) }; // DO_NOT_QUEUE
        const reply = conn.callSync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", glib.Variant.newTuple(&args, args.len), vt("(u)"), .{}, -1, null, &err) orelse return error.RequestNameFailed;
        reply.unref();
    }

    const mock_vtable: gio.DBusInterfaceVTable = .{
        .f_method_call = &mockCall,
        .f_get_property = null,
        .f_set_property = null,
        .f_padding = undefined,
    };

    fn mockCall(
        conn: *gio.DBusConnection,
        sender: ?[*:0]const u8,
        _: [*:0]const u8,
        _: ?[*:0]const u8,
        method_z: [*:0]const u8,
        params: *glib.Variant,
        invocation: *gio.DBusMethodInvocation,
        data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Mock = @ptrCast(@alignCast(data));
        const method = std.mem.span(method_z);
        if (std.mem.eql(u8, method, "GetManagedObjects")) {
            const v = glib.Variant.parse(vt("(a{oa{sa{sv}}})"), self.objects.load(.acquire), null, null, null).?;
            defer v.unref();
            invocation.returnValue(v);
        } else if (std.mem.eql(u8, method, "RegisterAdvertisement")) {
            if (self.fail_with.load(.acquire)) |name| return invocation.returnDbusError(name, "mock refused it");
            const path_v = params.getChildValue(0);
            defer path_v.unref();
            const path = std.mem.span(path_v.getString(null));
            @memcpy(self.registered_path[0..path.len], path);
            self.registered_len = path.len;
            self.pending = invocation;
            // As bluetoothd does: read the advertisement's properties back
            // before answering.
            var args = [_]*glib.Variant{glib.Variant.newString(advertisement_iface)};
            conn.call(sender, path_v.getString(null), "org.freedesktop.DBus.Properties", "GetAll", glib.Variant.newTuple(&args, args.len), vt("(a{sv})"), .{}, -1, null, &onGetAll, self);
        } else if (std.mem.eql(u8, method, "UnregisterAdvertisement")) {
            _ = self.unregistered.fetchAdd(1, .release);
            invocation.returnValue(null);
        } else {
            invocation.returnDbusError("org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
        }
    }

    fn onGetAll(source: ?*gobject.Object, res: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Mock = @ptrCast(@alignCast(data));
        const conn: *gio.DBusConnection = @ptrCast(source.?);
        const invocation = self.pending.?;
        self.pending = null;
        var err: ?*glib.Error = null;
        const reply = conn.callFinish(res, &err) orelse {
            logError("mock GetAll", err);
            return invocation.returnDbusError("org.bluez.Error.Failed", "can't read the advertisement");
        };
        defer reply.unref();
        const props = reply.getChildValue(0);
        if (self.props) |p| testing.allocator.free(p);
        self.props = printVariant(props) catch null;
        _ = self.registered.fetchAdd(1, .release);
        invocation.returnValue(null);
    }
};

const Seen = struct { handle: Handle, state: common.State, err: ?common.Error };
var seen: [8]Seen = undefined;
var seen_len: usize = 0;

fn onState(handle: Handle, state: common.State, err: ?common.Error) void {
    if (seen_len < seen.len) seen[seen_len] = .{ .handle = handle, .state = state, .err = err };
    seen_len += 1;
}

/// Run the default main context (the app's side) until `done(arg)`, or 5 s.
fn pump(arg: anytype, comptime done: fn (@TypeOf(arg)) bool) !void {
    const ctx = glib.MainContext.default();
    var i: usize = 0;
    while (!done(arg)) : (i += 1) {
        if (i > 5000) return error.Timeout;
        while (ctx.iteration(0) != 0) {}
        glib.usleep(1000);
    }
}

fn seenAtLeast(n: usize) bool {
    return seen_len >= n;
}

fn connect(address: [*:0]const u8) !*gio.DBusConnection {
    var err: ?*glib.Error = null;
    return gio.DBusConnection.newForAddressSync(address, .{ .authentication_client = true, .message_bus_connection = true }, null, null, &err) orelse {
        logError("connect to the test bus", err);
        return error.ConnectFailed;
    };
}

const powered_adapter =
    \\({objectpath '/org/bluez/hci0': {'org.bluez.Adapter1': {'Powered': <true>, 'Alias': <'oriel-test'>},
    \\  'org.bluez.LEAdvertisingManager1': {'SupportedInstances': <byte 5>, 'SupportedIncludes': <['local-name']>}}},)
;

const adapter_off =
    \\({objectpath '/org/bluez/hci0': {'org.bluez.Adapter1': {'Powered': <false>},
    \\  'org.bluez.LEAdvertisingManager1': {'SupportedInstances': <byte 5>}}},)
;

test "advertise against a mock BlueZ on a private bus" {
    const daemon = glib.findProgramInPath("dbus-daemon") orelse return error.SkipZigTest;
    glib.free(daemon);

    const test_bus = gio.TestDBus.new(.{});
    defer test_bus.unref();
    test_bus.up();
    defer test_bus.down();
    const address = test_bus.getBusAddress() orelse return error.SkipZigTest;

    var mock: Mock = .{ .address = address, .objects = .init(powered_adapter) };
    defer if (mock.props) |p| testing.allocator.free(p);
    const thread = try std.Thread.spawn(.{}, Mock.run, .{&mock});
    defer thread.join();
    defer mock.quit.store(true, .release);
    while (!mock.ready.load(.acquire)) glib.usleep(1000);
    if (mock.setup_failed) return error.MockSetupFailed;

    const app_conn = try connect(address);
    defer app_conn.unref();
    defer _ = app_conn.closeSync(null, null);
    bus_override = app_conn;
    defer bus_override = null;
    common.onAdvertiseState(&onState);
    defer common.onAdvertiseState(null);
    seen_len = 0;

    const caps = capabilities();
    try testing.expect(caps.advertise and caps.service_data and caps.local_name and caps.powered and !caps.extended);
    try testing.expectEqual(@as(u16, 31), caps.max_bytes);

    // Started: BlueZ read the object's properties back.
    const payload = [_]u8{0xAB} ** 4;
    const h = try advertise(.{ .service_data = .{ .uuid16 = 0xFE2C, .data = &payload }, .local_name = true });
    try pump(@as(usize, 1), seenAtLeast);
    try testing.expectEqual(Seen{ .handle = h, .state = .started, .err = null }, seen[0]);
    try testing.expectEqual(@as(u32, 1), mock.registered.load(.acquire));
    var path_buf: [path_prefix.len + 16]u8 = undefined;
    try testing.expectEqualStrings(objectPath(&path_buf, h), mock.registered_path[0..mock.registered_len]);
    try testing.expectEqualStrings("{'Type': <'broadcast'>, " ++
        "'ServiceData': <{'0000fe2c-0000-1000-8000-00805f9b34fb': <[byte 0xab, 0xab, 0xab, 0xab]>}>, " ++
        "'Includes': <['local-name']>, 'MinInterval': <uint32 250>, 'MaxInterval': <uint32 250>}", mock.props.?);

    // stop: UnregisterAdvertisement; a second stop is ignored.
    stop(h);
    stop(h);
    try pump(&mock, struct {
        fn done(m: *Mock) bool {
            return m.unregistered.load(.acquire) >= 1;
        }
    }.done);
    try testing.expect(!contains(h));

    // BlueZ refuses it: failed, with its error mapped.
    mock.fail_with.store("org.bluez.Error.InvalidLength", .release);
    const h2 = try advertise(.{ .service_uuids16 = &.{0x180F} });
    try pump(@as(usize, 2), seenAtLeast);
    try testing.expectEqual(Seen{ .handle = h2, .state = .failed, .err = error.TooLarge }, seen[1]);
    try testing.expect(!contains(h2));
    mock.fail_with.store(null, .release);

    // BlueZ drops it (Release): stopped.
    const h3 = try advertise(.{ .service_uuids16 = &.{0x180F}, .connectable = true });
    try pump(@as(usize, 3), seenAtLeast);
    try testing.expectEqual(Seen{ .handle = h3, .state = .started, .err = null }, seen[2]);
    try testing.expectEqual(@as(u32, 2), mock.registered.load(.acquire));
    try testing.expect(std.mem.startsWith(u8, mock.props.?, "{'Type': <'peripheral'>, 'ServiceUUIDs': <['0000180f-0000-1000-8000-00805f9b34fb']>"));
    mock.conn.?.call(app_conn.getUniqueName(), objectPath(&path_buf, h3), advertisement_iface, "Release", null, null, .{}, -1, null, null, null);
    try pump(@as(usize, 4), seenAtLeast);
    try testing.expectEqual(Seen{ .handle = h3, .state = .stopped, .err = null }, seen[3]);
    try testing.expect(!contains(h3));
    stop(h3); // already gone: no UnregisterAdvertisement

    // Too large with the adapter's name (10 bytes): 2+2+24 + 2+10 > 31.
    const big = [_]u8{0} ** 24;
    try testing.expectError(error.TooLarge, advertise(.{ .service_data = .{ .uuid16 = 0xFE2C, .data = &big }, .local_name = true }));

    // The adapter is off.
    mock.objects.store(adapter_off, .release);
    try testing.expect(!capabilities().powered);
    try testing.expectError(error.AdapterOff, advertise(.{ .service_uuids16 = &.{0x180F} }));

    // Let any late call land, then check nothing else was reported.
    try pump(@as(usize, 4), seenAtLeast);
    try testing.expectEqual(@as(usize, 4), seen_len);
    try testing.expectEqual(@as(u32, 1), mock.unregistered.load(.acquire));
}

fn noFree(_: ?*anyopaque) callconv(.c) void {}
