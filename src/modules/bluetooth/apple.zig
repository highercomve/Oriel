//! Bluetooth LE advertising on macOS and iOS through CoreBluetooth's
//! CBPeripheralManager: the 16-bit service UUIDs and the device name, no
//! service data (bluetooth.zig rejects it before this runs), always
//! connectable (`connectable = false` is best-effort: no GATT service is
//! published, so a central that connects finds nothing).
//!
//! CoreBluetooth is loaded with dlopen, not linked, like the bluetooth
//! permission (core/permissions/bluetooth_apple.zig): the advertisement
//! keys are its exported NSString globals, found with dlsym.
//!
//! One CBPeripheralManager, created on first use, with its delegate on a
//! private serial dispatch queue: callbacks don't need the main run loop,
//! and every CoreBluetooth call and every piece of state below is touched
//! only on that queue (dispatch_sync from `advertise`/`stop`), so the queue
//! is the lock. The manager is made only once the permission is granted:
//! made while undecided, it doesn't show macOS's prompt. `advertise` while
//! undecided asks through the permission's own request (the prompt shows)
//! and its advertisement waits; it starts once the user allows, or fails
//! with PermissionDenied. Apps should still call
//! `oriel.permissions.request(.bluetooth)` first. `capabilities()` never
//! asks.
//!
//! CBPeripheralManager has one advertisement at a time: a second
//! `advertise` while one is active is error.Failed (stop the first one;
//! replacing it silently would end an advertisement its owner still holds).
//!
//! States (`common.dispatchState`, on the main thread): `started` from
//! `peripheralManagerDidStartAdvertising:error:`, `failed` from it or when
//! Bluetooth turns off / is denied before the start, `stopped` when
//! Bluetooth turns off (or resets) while advertising.

const std = @import("std");
const common = @import("common.zig");
const target = @import("../../core/target.zig");
const apple = @import("../../platform/apple/apple.zig");
const permission = @import("../../core/permissions/bluetooth_apple.zig").Bluetooth;
const permission_common = @import("../../core/permissions/common.zig");

const Object = apple.Object;
const Advertisement = common.Advertisement;
const Capabilities = common.Capabilities;
const Handle = common.Handle;
const Error = common.Error;

pub const backend = "CoreBluetooth";

// CBManagerState
const state_unknown: isize = 0;
const state_resetting: isize = 1;
const state_unsupported: isize = 2;
const state_unauthorized: isize = 3;
const state_powered_off: isize = 4;
const state_powered_on: isize = 5;

const framework = "/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth";
const system_configuration = "/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration";

/// How long `capabilities()` waits for a new manager's first state (it
/// comes at once when the permission is already granted).
const first_state_timeout_ms = 500;

// ---------------------------------------------------------------------------
// What capabilities() can say: the fields and the state

/// What this device can advertise now. Without the permission granted, no
/// manager is created (that would prompt): the state is unknown, so
/// `advertise` is true (CoreBluetooth is here) and `powered` false.
pub fn capabilities() Capabilities {
    if (loadFramework() == null) return .{};
    if (apple.objc.getClass("CBPeripheralManager") == null) return .{};
    switch (permission.status()) {
        // .unknown: before macOS 10.15 / iOS 13.1 there's no authorization
        // to ask (and nothing prompts).
        .granted, .unknown => if (ensureManager()) waitFirstState(),
        else => {},
    }
    return capabilitiesOf(cb_state.load(.acquire));
}

fn capabilitiesOf(state: isize) Capabilities {
    const can = state != state_unsupported;
    const f = common.fieldsOf(target.os);
    return .{
        .advertise = can,
        .service_data = can and f.service_data,
        .local_name = can and f.local_name,
        .connectable = can and f.connectable,
        .non_connectable = can and f.non_connectable,
        .extended = false,
        // 31 bytes; CoreBluetooth always adds the 3-byte Flags structure,
        // so 28 are ours (`advertise` checks that).
        .max_bytes = if (can) @intCast(common.legacy_max) else 0,
        .scan = false, // no scanning API yet
        .scan_service_data = false,
        .powered = state == state_powered_on,
    };
}

// ---------------------------------------------------------------------------
// advertise / stop

/// Start advertising `ad` (validated by bluetooth.zig): its handle. The
/// start (or a failure after this returns) comes as the advertisement's
/// state. error.Failed while another advertisement is active.
pub fn advertise(ad: Advertisement) Error!Handle {
    // CoreBluetooth's advertisement always carries Flags (it's always
    // connectable). The name isn't counted: CoreBluetooth truncates it (or
    // moves it to the scan response) rather than refusing.
    var sized = ad;
    sized.connectable = true;
    sized.local_name = false;
    try common.checkSize(sized, 0, common.legacy_max);
    if (loadFramework() == null) return error.Unsupported;
    switch (permission.status()) {
        .denied => return error.PermissionDenied,
        // A CBPeripheralManager made while undecided doesn't show macOS's
        // prompt (macOS 15: the advertisement waited forever); the
        // permission's own request (a CBCentralManager on the main queue)
        // does. Ask that way; the manager is made once the user answers,
        // and the advertisement waits for it.
        .prompt => if (!manager_ready.load(.acquire)) {
            if (!ensureQueue()) return error.Failed;
            const handle = try startPending(ad);
            permission.request(&answered);
            return handle;
        },
        .granted, .unknown => {},
    }
    _ = ensureManager();
    if (!manager_ready.load(.acquire)) return error.Failed;
    return startPending(ad);
}

/// startOnQueue on `queue`.
fn startPending(ad: Advertisement) Error!Handle {
    const Ctx = struct {
        ad: *const Advertisement,
        result: Error!Handle = error.Failed,
        fn run(self: *@This()) void {
            self.result = startOnQueue(self.ad.*);
        }
    };
    var ctx: Ctx = .{ .ad = &ad };
    onQueue(Ctx, &ctx, Ctx.run);
    return ctx.result;
}

/// The permission's answer to `advertise`'s request: granted makes the
/// manager (the waiting advertisement starts at its first powered-on
/// state); anything else fails it. On the main thread.
fn answered(_: permission_common.Kind, status: permission_common.Status) void {
    switch (status) {
        .granted, .unknown => if (ensureManager()) return,
        .denied, .prompt => {},
    }
    const Ctx = struct {
        err: Error,
        fn run(self: *@This()) void {
            if (active != 0 and phase == .pending) finish(.failed, self.err);
        }
    };
    var ctx: Ctx = .{ .err = if (status == .denied) error.PermissionDenied else error.Failed };
    onQueue(Ctx, &ctx, Ctx.run);
}

/// Stop the advertisement `handle`; another (or an old) handle is ignored.
pub fn stop(handle: Handle) void {
    if (queue == null) return; // nothing was ever started
    const Ctx = struct {
        handle: Handle,
        fn run(self: *@This()) void {
            if (self.handle != active) return;
            switch (phase) {
                .starting, .advertising => manager.msgSend(void, "stopAdvertising", .{}),
                .pending, .idle => {},
            }
            clear();
        }
    };
    var ctx: Ctx = .{ .handle = handle };
    onQueue(Ctx, &ctx, Ctx.run);
}

// ---------------------------------------------------------------------------
// The advertisement (only touched on `queue`)

const Phase = enum {
    idle,
    /// Waiting for the manager's state (just created, or resetting).
    pending,
    /// startAdvertising: sent, its callback not yet in.
    starting,
    advertising,
};

var active: Handle = 0;
var phase: Phase = .idle;
/// The advertisement data while `pending` (+1).
var pending_data: Object = apple.nil;
var last_handle: Handle = 0;

fn startOnQueue(ad: Advertisement) Error!Handle {
    try admit(active);
    const state = cb_state.load(.acquire);
    if (stateError(state)) |e| return e;
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    const data = advertisementData(ad) orelse return error.Failed;
    last_handle = nextHandle(last_handle);
    active = last_handle;
    if (state == state_powered_on) {
        begin(manager, data);
        data.release();
    } else {
        pending_data = data;
        phase = .pending;
    }
    return active;
}

fn begin(pm: Object, data: Object) void {
    pm.msgSend(void, "startAdvertising:", .{data});
    phase = .starting;
}

/// End the active advertisement with `state` (the platform ended it).
fn finish(state: common.State, err: ?Error) void {
    report(active, state, err);
    clear();
}

fn clear() void {
    if (pending_data.value != null) pending_data.release();
    pending_data = apple.nil;
    active = 0;
    phase = .idle;
}

/// `@{ ServiceUUIDs: @[CBUUID...], LocalName: name }`, retained (+1), or
/// null. Inside an autorelease pool.
fn advertisementData(ad: Advertisement) ?Object {
    const dict = apple.class("NSMutableDictionary").msgSend(Object, "dictionary", .{});
    if (dict.value == null) return null;
    if (ad.service_uuids16.len > 0) {
        const cbuuid = apple.objc.getClass("CBUUID") orelse return null;
        const array = apple.class("NSMutableArray").msgSend(Object, "array", .{});
        for (ad.service_uuids16) |u| {
            var buf: [4]u8 = undefined;
            const s = apple.nsString(uuidString(u, &buf)) orelse return null;
            defer s.release();
            const uuid = cbuuid.msgSend(Object, "UUIDWithString:", .{s});
            if (uuid.value == null) return null;
            array.msgSend(void, "addObject:", .{uuid});
        }
        dict.msgSend(void, "setObject:forKey:", .{ array, key("CBAdvertisementDataServiceUUIDsKey", "kCBAdvDataServiceUUIDs") });
    }
    if (ad.local_name) {
        const name = deviceName();
        if (name.value != null) dict.msgSend(void, "setObject:forKey:", .{ name, key("CBAdvertisementDataLocalNameKey", "kCBAdvDataLocalName") });
    }
    return dict.retain();
}

/// CoreBluetooth's NSString constant `symbol` (its value, `fallback`, if
/// the symbol isn't found; autoreleased then).
fn key(comptime symbol: [:0]const u8, comptime fallback: []const u8) Object {
    if (framework_handle) |h| {
        if (std.c.dlsym(h, symbol)) |p| {
            const ptr: *const apple.id = @ptrCast(@alignCast(p));
            if (ptr.* != null) return .{ .value = ptr.* };
        }
    }
    const s = apple.nsString(fallback) orelse return apple.nil;
    return s.msgSend(Object, "autorelease", .{});
}

/// The device's name as an NSString (autoreleased), or nil. macOS: the
/// computer name (SCDynamicStoreCopyComputerName, looked up with dlsym:
/// NSHost's localizedName can block on DNS), else NSHost's. iOS:
/// UIDevice.name (generic, "iPhone", since iOS 16 without the
/// user-assigned-device-name entitlement).
fn deviceName() Object {
    if (target.os == .ios) {
        return apple.class("UIDevice").msgSend(Object, "currentDevice", .{}).msgSend(Object, "name", .{});
    }
    const CopyComputerName = *const fn (store: ?*anyopaque, encoding: ?*u32) callconv(.c) apple.id;
    if (std.c.dlopen(system_configuration, .{ .LAZY = true })) |h| {
        if (std.c.dlsym(h, "SCDynamicStoreCopyComputerName")) |p| {
            const copy: CopyComputerName = @ptrCast(@alignCast(p));
            const name: Object = .{ .value = copy(null, null) }; // +1, toll-free NSString
            if (name.value != null) return name.msgSend(Object, "autorelease", .{});
        }
    }
    const host = apple.class("NSHost").msgSend(Object, "currentHost", .{});
    return host.msgSend(Object, "localizedName", .{});
}

// ---------------------------------------------------------------------------
// The delegate (runs on `queue`)

fn didUpdateState(_: apple.id, _: apple.c.SEL, peripheral: apple.id) callconv(.c) void {
    on_queue = true;
    defer on_queue = false;
    const pm: Object = .{ .value = peripheral };
    const s = pm.msgSend(isize, "state", .{});
    cb_state.store(s, .release);
    if (!first_state_seen.swap(true, .acq_rel)) dispatch_group_leave(first_state.?);
    if (active == 0) return;
    switch (phase) {
        .idle => {},
        .pending => if (s == state_powered_on) {
            begin(pm, pending_data);
            pending_data.release();
            pending_data = apple.nil;
        } else if (stateError(s)) |e| finish(.failed, e),
        // Off, reset or revoked: CoreBluetooth drops the advertisement and
        // doesn't bring it back.
        .starting => if (s != state_powered_on) finish(.failed, stateError(s) orelse error.Failed),
        .advertising => if (s != state_powered_on) finish(.stopped, stateError(s)),
    }
}

fn didStartAdvertising(_: apple.id, _: apple.c.SEL, _: apple.id, err: apple.id) callconv(.c) void {
    on_queue = true;
    defer on_queue = false;
    // Stopped (or failed) meanwhile: not ours to report.
    if (active == 0 or phase != .starting) return;
    if (err == null) {
        phase = .advertising;
        report(active, .started, null);
    } else {
        finish(.failed, nsErrorOf(.{ .value = err }));
    }
}

fn nsErrorOf(err: Object) Error {
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    const domain = apple.utf8(err.msgSend(Object, "domain", .{})) orelse return error.Failed;
    return errorOf(std.mem.eql(u8, domain, "CBErrorDomain"), err.msgSend(isize, "code", .{}));
}

/// Report on the main thread (common.StateHandler's contract), so a
/// handler may call `advertise`/`stop` (a dispatch_sync onto `queue` from
/// the delegate would deadlock).
fn report(handle: Handle, state: common.State, err: ?Error) void {
    apple.asyncMain(@ptrFromInt(pack(handle, state, err)), deliver);
}

fn deliver(ctx: ?*anyopaque) callconv(.c) void {
    const r = unpack(@intFromPtr(ctx));
    common.dispatchState(r.handle, r.state, r.err);
}

// ---------------------------------------------------------------------------
// The manager, its queue and the framework

var init_mutex: std.c.pthread_mutex_t = .{};
var framework_handle: ?*anyopaque = null;
var manager_ready: std.atomic.Value(bool) = .init(false);
/// The CBPeripheralManager and its delegate (+1 each, for the process's
/// lifetime: the manager keeps its delegate weakly).
var manager: Object = apple.nil;
var delegate: Object = apple.nil;
/// The private serial queue: the delegate's, and the lock for the state above.
var queue: ?*anyopaque = null;
var cb_state: std.atomic.Value(isize) = .init(state_unknown);
/// Left by the first state update: `capabilities()` waits on it.
var first_state: ?*anyopaque = null;
var first_state_seen: std.atomic.Value(bool) = .init(false);
/// Set while running on `queue` (our work or a delegate method).
threadlocal var on_queue: bool = false;

fn loadFramework() ?*anyopaque {
    _ = std.c.pthread_mutex_lock(&init_mutex);
    defer _ = std.c.pthread_mutex_unlock(&init_mutex);
    if (framework_handle == null) framework_handle = std.c.dlopen(framework, .{ .LAZY = true });
    return framework_handle;
}

/// Create the manager if there's none: true once it exists. (May show the
/// permission prompt, see the top.)
fn ensureManager() bool {
    if (manager_ready.load(.acquire)) return true;
    _ = std.c.pthread_mutex_lock(&init_mutex);
    defer _ = std.c.pthread_mutex_unlock(&init_mutex);
    if (manager_ready.load(.acquire)) return true;
    if (framework_handle == null) return false;
    const cls = apple.objc.getClass("CBPeripheralManager") orelse return false;
    if (!makeQueue()) return false;
    if (first_state == null) {
        first_state = dispatch_group_create() orelse return false;
        dispatch_group_enter(first_state.?);
    }
    const delegate_class = apple.defineClass("OrielBluetoothAdvertiser", &.{"CBPeripheralManagerDelegate"}, .{
        .{ "peripheralManagerDidUpdateState:", didUpdateState },
        .{ "peripheralManagerDidStartAdvertising:error:", didStartAdvertising },
    });
    delegate = apple.new(delegate_class);
    manager = cls.msgSend(Object, "alloc", .{}).msgSend(Object, "initWithDelegate:queue:", .{ delegate, queue });
    if (manager.value == null) return false;
    manager_ready.store(true, .release);
    return true;
}

/// The private queue the advertisement's state lives on, made once.
fn ensureQueue() bool {
    _ = std.c.pthread_mutex_lock(&init_mutex);
    defer _ = std.c.pthread_mutex_unlock(&init_mutex);
    return makeQueue();
}

/// ensureQueue with `init_mutex` held.
fn makeQueue() bool {
    if (queue == null) queue = dispatch_queue_create("dev.oriel.bluetooth", null);
    return queue != null;
}

fn waitFirstState() void {
    if (first_state_seen.load(.acquire)) return;
    const group = first_state orelse return;
    _ = dispatch_group_wait(group, dispatch_time(0, first_state_timeout_ms * std.time.ns_per_ms));
}

/// Run `work(ctx)` on `queue` and wait for it (inline when already there).
fn onQueue(comptime Ctx: type, ctx: *Ctx, comptime work: fn (*Ctx) void) void {
    if (on_queue) return work(ctx);
    const Wrap = struct {
        fn run(p: ?*anyopaque) callconv(.c) void {
            on_queue = true;
            defer on_queue = false;
            work(@ptrCast(@alignCast(p.?)));
        }
    };
    dispatch_sync_f(queue.?, ctx, &Wrap.run);
}

extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) ?*anyopaque;
extern "c" fn dispatch_sync_f(queue: *anyopaque, ctx: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn dispatch_group_create() ?*anyopaque;
extern "c" fn dispatch_group_enter(group: *anyopaque) void;
extern "c" fn dispatch_group_leave(group: *anyopaque) void;
extern "c" fn dispatch_group_wait(group: *anyopaque, timeout: u64) isize;
extern "c" fn dispatch_time(when: u64, delta: i64) u64;

// ---------------------------------------------------------------------------
// Pure logic (no Objective-C)

/// One advertisement at a time (CBPeripheralManager has one).
fn admit(current: Handle) Error!void {
    if (current != 0) return error.Failed;
}

/// The next handle after `last` (never 0).
fn nextHandle(last: Handle) Handle {
    const n = last +% 1;
    return if (n == 0) 1 else n;
}

/// `[CBUUID UUIDWithString:]`'s 16-bit form: four hex digits.
fn uuidString(uuid16: u16, buf: *[4]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{X:0>4}", .{uuid16}) catch unreachable;
}

/// A CBManagerState that can't advertise, as Oriel's error (null: on, or
/// not known yet).
fn stateError(state: isize) ?Error {
    return switch (state) {
        state_unsupported => error.Unsupported,
        state_unauthorized => error.PermissionDenied,
        state_powered_off => error.AdapterOff,
        else => null, // unknown, resetting, powered on
    };
}

/// `peripheralManagerDidStartAdvertising:error:`'s NSError as Oriel's
/// (`cb_domain`: CBErrorDomain).
fn errorOf(cb_domain: bool, code: isize) Error {
    if (!cb_domain) return error.Failed;
    return switch (code) {
        4 => error.TooLarge, // CBErrorOutOfSpace
        8, 13 => error.Unsupported, // CBErrorUUIDNotAllowed, CBErrorOperationNotSupported
        else => error.Failed, // Unknown, InvalidParameters, AlreadyAdvertising...
    };
}

/// A state report packed into a pointer-sized context for dispatch_async_f:
/// the handle, the state and the error (0: none).
const reportable = [_]Error{ error.Unsupported, error.PermissionDenied, error.AdapterOff, error.TooLarge, error.Failed };

fn pack(handle: Handle, state: common.State, err: ?Error) usize {
    var code: usize = 0;
    if (err) |e| for (reportable, 1..) |r, i| {
        if (r == e) code = i;
    };
    return @as(usize, handle) | (@as(usize, @intFromEnum(state)) << 32) | (code << 40);
}

const Report = struct { handle: Handle, state: common.State, err: ?Error };

fn unpack(v: usize) Report {
    const code = (v >> 40) & 0xff;
    return .{
        .handle = @truncate(v),
        .state = @enumFromInt((v >> 32) & 0xff),
        .err = if (code == 0 or code > reportable.len) null else reportable[code - 1],
    };
}

test admit {
    try admit(0);
    try std.testing.expectError(error.Failed, admit(3));
}

test nextHandle {
    try std.testing.expectEqual(@as(Handle, 1), nextHandle(0));
    try std.testing.expectEqual(@as(Handle, 8), nextHandle(7));
    try std.testing.expectEqual(@as(Handle, 1), nextHandle(std.math.maxInt(Handle)));
}

test uuidString {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("180F", uuidString(0x180F, &buf));
    try std.testing.expectEqualStrings("FE2C", uuidString(0xFE2C, &buf));
    try std.testing.expectEqualStrings("000A", uuidString(0x000A, &buf));
}

test stateError {
    try std.testing.expectEqual(@as(?Error, error.Unsupported), stateError(state_unsupported));
    try std.testing.expectEqual(@as(?Error, error.PermissionDenied), stateError(state_unauthorized));
    try std.testing.expectEqual(@as(?Error, error.AdapterOff), stateError(state_powered_off));
    try std.testing.expectEqual(@as(?Error, null), stateError(state_powered_on));
    try std.testing.expectEqual(@as(?Error, null), stateError(state_unknown));
    try std.testing.expectEqual(@as(?Error, null), stateError(state_resetting));
}

test errorOf {
    try std.testing.expectEqual(error.TooLarge, errorOf(true, 4));
    try std.testing.expectEqual(error.Unsupported, errorOf(true, 8));
    try std.testing.expectEqual(error.Failed, errorOf(true, 9));
    try std.testing.expectEqual(error.Failed, errorOf(false, 4));
}

test pack {
    const r = unpack(pack(42, .failed, error.AdapterOff));
    try std.testing.expectEqual(@as(Handle, 42), r.handle);
    try std.testing.expectEqual(common.State.failed, r.state);
    try std.testing.expectEqual(@as(?Error, error.AdapterOff), r.err);
    const s = unpack(pack(std.math.maxInt(Handle), .started, null));
    try std.testing.expectEqual(std.math.maxInt(Handle), s.handle);
    try std.testing.expectEqual(common.State.started, s.state);
    try std.testing.expectEqual(@as(?Error, null), s.err);
}

test capabilitiesOf {
    const on = capabilitiesOf(state_powered_on);
    try std.testing.expect(on.advertise and on.powered and on.local_name and on.connectable);
    try std.testing.expect(!on.service_data and !on.non_connectable and !on.extended);
    try std.testing.expectEqual(@as(u16, 31), on.max_bytes);
    const off = capabilitiesOf(state_powered_off);
    try std.testing.expect(off.advertise and !off.powered);
    const none = capabilitiesOf(state_unsupported);
    try std.testing.expect(!none.advertise and none.max_bytes == 0);
    // Apple's advertisement carries Flags: 13 UUIDs fit, 14 don't.
    const uuids = [_]u16{0x180F} ** 14;
    try common.checkSize(.{ .service_uuids16 = uuids[0..13], .connectable = true }, 0, common.legacy_max);
    try std.testing.expectError(error.TooLarge, common.checkSize(.{ .service_uuids16 = &uuids, .connectable = true }, 0, common.legacy_max));
}
