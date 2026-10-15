//! Bluetooth LE advertising on Windows: a
//! Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementPublisher
//! per advertisement, through WinRT (platform/windows/winrt.zig).
//!
//! The advertisement is raw data sections: the 16-bit service UUIDs as
//! section 0x03 (complete list, little-endian) and the service data as
//! section 0x16 ([uuid lo, uuid hi, data...]). No LocalName (the publisher
//! rejects it) and never connectable (legacy publisher advertisements
//! aren't): bluetooth.zig's `validate` refuses both before this runs.
//! `mode` and `tx_power` are hints Windows doesn't take here: the system
//! picks the interval and the power of a legacy advertisement.
//!
//! The publisher's StatusChanged (a Zig delegate, on a thread-pool
//! thread) is the advertisement's state: Started → `started`, Aborted →
//! `failed` (BluetoothError mapped), Stopped not caused by `stop` →
//! `stopped`. Waiting (the radio is off or busy; the publisher starts once
//! it can) reports nothing.
//!
//! Threads: `advertise`, `stop` and `capabilities` may come from any
//! thread. The Bluetooth classes are agile, so a publisher created on one
//! thread is stopped from another; threads that never initialized COM run
//! in the implicit MTA (`winrt.keepMta`). `capabilities` waits for
//! BluetoothAdapter.GetDefaultAsync on a worker thread (never blocking an
//! apartment on its own async operation) and caches the answer briefly.

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const win32 = @import("../../platform/windows/win32.zig");
const winrt = @import("../../platform/windows/winrt.zig");

const Advertisement = common.Advertisement;
const Capabilities = common.Capabilities;
const Handle = common.Handle;
const HRESULT = winrt.HRESULT;
const GUID = winrt.GUID;
const Inspectable = winrt.Inspectable;
const Slot = *const anyopaque;
const gpa = std.heap.smp_allocator;
const log = std.log.scoped(.bluetooth);

pub const backend = "BluetoothLEAdvertisementPublisher";

// ------------------------------------------------------------ interfaces
// IIDs and slot orders from Windows.Devices.winmd, Windows.Security.winmd
// and Windows.Foundation.winmd (cross-checked against the Windows SDK's
// windows.devices.bluetooth*.h and mingw-w64's headers).

const adapter_class = "Windows.Devices.Bluetooth.BluetoothAdapter";
const advertisement_class = "Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisement";
const section_class = "Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementDataSection";
const publisher_class = "Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementPublisher";
const status_args_class = "Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementPublisherStatusChangedEventArgs";
const radio_class = "Windows.Devices.Radios.Radio";
const crypto_buffer_class = "Windows.Security.Cryptography.CryptographicBuffer";

const AdapterStatics = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        GetDeviceSelector: Slot,
        FromIdAsync: Slot,
        GetDefaultAsync: *const fn (*AdapterStatics, *?*AdapterOp) callconv(.winapi) HRESULT,
    },
    pub const iid = GUID.parse("{8B02FB6A-AC4C-4741-8661-8EAB7D17EA9F}");
};

/// IBluetoothAdapter (`boolean` is a byte).
const Adapter = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        get_DeviceId: Slot,
        get_BluetoothAddress: Slot,
        get_IsClassicSupported: Slot,
        get_IsLowEnergySupported: Slot,
        get_IsPeripheralRoleSupported: *const fn (*Adapter, *u8) callconv(.winapi) HRESULT,
        get_IsCentralRoleSupported: Slot,
        get_IsAdvertisementOffloadSupported: Slot,
        GetRadioAsync: *const fn (*Adapter, *?*RadioOp) callconv(.winapi) HRESULT,
    },
    pub const iid = GUID.parse("{7974F04C-5F7A-4A34-9225-A855F84B1A8B}");
    pub const sig = winrt.sig.class(adapter_class, iid);
};

/// IBluetoothAdapter3 (Windows 10 2004+).
const Adapter3 = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        get_IsExtendedAdvertisingSupported: *const fn (*Adapter3, *u8) callconv(.winapi) HRESULT,
        get_MaxAdvertisementDataLength: *const fn (*Adapter3, *u32) callconv(.winapi) HRESULT,
    },
    pub const iid = GUID.parse("{8F8624E0-CBA9-5211-9F89-3AAC62B4C6B8}");
};

const Radio = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        SetStateAsync: Slot,
        add_StateChanged: Slot,
        remove_StateChanged: Slot,
        get_State: *const fn (*Radio, *i32) callconv(.winapi) HRESULT,
    },
    pub const iid = GUID.parse("{252118DF-B33E-416A-875F-1CF38AE2D83E}");
    pub const sig = winrt.sig.class(radio_class, iid);
    /// RadioState.On (Unknown 0, Off 2, Disabled 3).
    const state_on: i32 = 1;
};

const AdapterOp = winrt.AsyncOperation(Adapter.sig);
const RadioOp = winrt.AsyncOperation(Radio.sig);

const CryptographicBufferStatics = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        Compare: Slot,
        GenerateRandom: Slot,
        GenerateRandomNumber: Slot,
        /// Returns an IBuffer.
        CreateFromByteArray: *const fn (*CryptographicBufferStatics, u32, [*]const u8, *?*Inspectable) callconv(.winapi) HRESULT,
    },
    pub const iid = GUID.parse("{320B7E22-3CB0-4CDF-8663-1D28910065EB}");
};

/// IBluetoothLEAdvertisement.
const BleAdvertisement = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        get_Flags: Slot,
        put_Flags: Slot,
        get_LocalName: Slot,
        put_LocalName: Slot,
        get_ServiceUuids: Slot,
        get_ManufacturerData: Slot,
        get_DataSections: *const fn (*BleAdvertisement, *?*SectionVector) callconv(.winapi) HRESULT,
        GetManufacturerDataByCompanyId: Slot,
        GetSectionsByType: Slot,
    },
    pub const iid = GUID.parse("{066FB2B7-33D1-4E7D-8367-CF81D0F79653}");
};

/// IVector<BluetoothLEAdvertisementDataSection>, as get_DataSections
/// returns it (only Append is used).
const SectionVector = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        GetAt: Slot,
        get_Size: Slot,
        GetView: Slot,
        IndexOf: Slot,
        SetAt: Slot,
        InsertAt: Slot,
        RemoveAt: Slot,
        Append: *const fn (*SectionVector, *DataSection) callconv(.winapi) HRESULT,
    },
};

/// IBluetoothLEAdvertisementDataSection (only handed around).
const DataSection = extern struct {
    vtbl: *const Inspectable.Vtbl,
    pub const iid = GUID.parse("{D7213314-3A43-40F9-B6F0-92BFEFC34AE3}");
};

const DataSectionFactory = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        Create: *const fn (*DataSectionFactory, u8, *Inspectable, *?*DataSection) callconv(.winapi) HRESULT,
    },
    pub const iid = GUID.parse("{E7A40942-A845-4045-BF7E-3E9971DB8A6B}");
};

const Publisher = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        get_Status: Slot,
        get_Advertisement: Slot,
        Start: *const fn (*Publisher) callconv(.winapi) HRESULT,
        Stop: *const fn (*Publisher) callconv(.winapi) HRESULT,
        add_StatusChanged: *const fn (*Publisher, *anyopaque, *winrt.EventToken) callconv(.winapi) HRESULT,
        remove_StatusChanged: *const fn (*Publisher, winrt.EventToken) callconv(.winapi) HRESULT,
    },
    pub const iid = GUID.parse("{CDE820F9-D9FA-43D6-A264-DDD8B7DA8B78}");
    pub const sig = winrt.sig.class(publisher_class, iid);
};

const PublisherFactory = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        Create: *const fn (*PublisherFactory, *BleAdvertisement, *?*Publisher) callconv(.winapi) HRESULT,
    },
    pub const iid = GUID.parse("{5C5F065E-B863-4981-A1AF-1C544D8B0C0D}");
};

const StatusArgs = extern struct {
    vtbl: *const extern struct {
        base: Inspectable.Vtbl,
        get_Status: *const fn (*StatusArgs, *PublisherStatus) callconv(.winapi) HRESULT,
        get_Error: *const fn (*StatusArgs, *BluetoothError) callconv(.winapi) HRESULT,
    },
    pub const iid = GUID.parse("{09C2BD9F-2DFF-4B23-86EE-0D14FB94AEAE}");
    pub const sig = winrt.sig.class(status_args_class, iid);
};

/// TypedEventHandler<BluetoothLEAdvertisementPublisher,
/// BluetoothLEAdvertisementPublisherStatusChangedEventArgs>. Its context
/// is the advertisement's handle (as a pointer, never dereferenced): a
/// late event for a stopped handle finds nothing in the table.
const status_handler_iid = winrt.piid(winrt.sig.pinterface(winrt.generic.typed_event_handler, &.{ Publisher.sig, StatusArgs.sig }));
const StatusHandler = winrt.Delegate(status_handler_iid, *Publisher, *StatusArgs, anyopaque);

// ------------------------------------------------- data sections (pure)

/// AD types (Bluetooth Assigned Numbers, "Common Data Types").
pub const ad_type_uuids16_complete: u8 = 0x03;
pub const ad_type_service_data16: u8 = 0x16;

/// A data section: its AD type and data (the length and type bytes of the
/// AD structure are the stack's).
pub const Section = struct {
    kind: u8,
    len: u8 = 0,
    buf: [common.legacy_max]u8 = undefined,

    pub fn data(s: *const Section) []const u8 {
        return s.buf[0..s.len];
    }

    fn put(s: *Section, bytes: []const u8) common.Error!void {
        if (s.len + bytes.len > s.buf.len) return error.TooLarge;
        @memcpy(s.buf[s.len..][0..bytes.len], bytes);
        s.len += @intCast(bytes.len);
    }

    fn putU16(s: *Section, v: u16) common.Error!void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .little);
        try s.put(&b);
    }
};

pub const Sections = struct {
    items: [2]Section = undefined,
    len: usize = 0,

    pub fn slice(s: *const Sections) []const Section {
        return s.items[0..s.len];
    }
};

/// `ad` as data sections: the 16-bit UUID list (0x03), then the service
/// data (0x16). error.TooLarge past a legacy payload.
pub fn sections(ad: Advertisement) common.Error!Sections {
    var out: Sections = .{};
    if (ad.service_uuids16.len > 0) {
        var s: Section = .{ .kind = ad_type_uuids16_complete };
        for (ad.service_uuids16) |u| try s.putU16(u);
        out.items[out.len] = s;
        out.len += 1;
    }
    if (ad.service_data) |sd| {
        var s: Section = .{ .kind = ad_type_service_data16 };
        try s.putU16(sd.uuid16);
        try s.put(sd.data);
        out.items[out.len] = s;
        out.len += 1;
    }
    return out;
}

// --------------------------------------------- status mapping (pure)

/// BluetoothLEAdvertisementPublisherStatus.
pub const PublisherStatus = enum(i32) { created = 0, waiting = 1, started = 2, stopping = 3, stopped = 4, aborted = 5, _ };

/// Windows.Devices.Bluetooth.BluetoothError.
pub const BluetoothError = enum(i32) {
    success = 0,
    radio_not_available = 1,
    resource_in_use = 2,
    device_not_connected = 3,
    other_error = 4,
    disabled_by_policy = 5,
    not_supported = 6,
    disabled_by_user = 7,
    consent_required = 8,
    transport_not_supported = 9,
    _,
};

/// An Aborted publisher's error as Oriel's. DisabledByUser and
/// ConsentRequired are the radio privacy settings (an app's access), not
/// the radio being off.
pub fn errorOf(e: BluetoothError) common.Error {
    return switch (e) {
        .radio_not_available => error.AdapterOff,
        .disabled_by_policy, .disabled_by_user, .consent_required => error.PermissionDenied,
        .not_supported, .transport_not_supported => error.Unsupported,
        else => error.Failed,
    };
}

pub const Report = struct { state: common.State, err: ?common.Error = null };

/// What a StatusChanged reports, if anything (Created, Waiting and
/// Stopping don't).
pub fn reportOf(status: PublisherStatus, err: BluetoothError) ?Report {
    return switch (status) {
        .started => .{ .state = .started },
        .aborted => .{ .state = .failed, .err = errorOf(err) },
        .stopped => .{ .state = .stopped },
        else => null,
    };
}

/// A failed Start() (or construction) as Oriel's error.
pub fn errorOfHresult(hr: HRESULT) common.Error {
    return switch (@as(u32, @bitCast(hr))) {
        0x80070005 => error.PermissionDenied, // E_ACCESSDENIED
        0x80070032, 0x80004001 => error.Unsupported, // ERROR_NOT_SUPPORTED, E_NOTIMPL
        0x800710DF, 0x8007048F => error.AdapterOff, // ERROR_DEVICE_NOT_AVAILABLE, ERROR_DEVICE_NOT_CONNECTED
        else => error.Failed,
    };
}

// --------------------------------------------------------- capabilities

/// How long an answer is reused (the root's `advertise` asks each time).
const refresh_ms = 2000;
/// How long a caller waits for a fresh answer before using the last one.
const answer_timeout_ms = 3000;
/// Each async operation's budget on the worker.
const op_timeout_ms = 2500;

var caps_lock: win32.SRWLOCK = win32.SRWLOCK_INIT;
var cached: ?Capabilities = null;
var cached_at: u64 = 0;
var inflight: ?*Query = null;

/// One adapter query on a worker thread, shared by the callers waiting
/// for it; freed by whichever of them (and the worker) lets go last.
const Query = struct {
    refs: std.atomic.Value(u32),
    event: win32.HANDLE,
    result: Capabilities = .{},

    fn unref(q: *Query) void {
        if (q.refs.fetchSub(1, .acq_rel) != 1) return;
        _ = win32.CloseHandle(q.event);
        gpa.destroy(q);
    }

    fn run(q: *Query) void {
        const c = queryAdapter();
        q.result = c;
        win32.AcquireSRWLockExclusive(&caps_lock);
        cached = c;
        cached_at = win32.GetTickCount64();
        if (inflight == q) inflight = null;
        win32.ReleaseSRWLockExclusive(&caps_lock);
        _ = win32.SetEvent(q.event);
        q.unref();
    }
};

/// The default adapter's capabilities: no adapter, or any failure, is
/// `.{}`. Cached for `refresh_ms`.
pub fn capabilities() Capabilities {
    winrt.keepMta();
    win32.AcquireSRWLockExclusive(&caps_lock);
    if (cached) |c| {
        if (win32.GetTickCount64() -% cached_at < refresh_ms) {
            win32.ReleaseSRWLockExclusive(&caps_lock);
            return c;
        }
    }
    const last = cached orelse Capabilities{};
    const q = inflight orelse startQuery() orelse {
        win32.ReleaseSRWLockExclusive(&caps_lock);
        return last;
    };
    _ = q.refs.fetchAdd(1, .monotonic);
    win32.ReleaseSRWLockExclusive(&caps_lock);
    defer q.unref();
    if (win32.WaitForSingleObject(q.event, answer_timeout_ms) != win32.WAIT_OBJECT_0) {
        log.warn("bluetooth: the adapter took over {d} ms to answer", .{answer_timeout_ms});
        return last;
    }
    return q.result;
}

/// Under `caps_lock`: a query running on its own thread (one reference,
/// the worker's), now `inflight`.
fn startQuery() ?*Query {
    const event = win32.CreateEventW(null, win32.TRUE, win32.FALSE, null) orelse return null;
    const q = gpa.create(Query) catch {
        _ = win32.CloseHandle(event);
        return null;
    };
    q.* = .{ .refs = .init(1), .event = event };
    const thread = std.Thread.spawn(.{}, Query.run, .{q}) catch {
        _ = win32.CloseHandle(event);
        gpa.destroy(q);
        return null;
    };
    thread.detach();
    inflight = q;
    return q;
}

/// BluetoothAdapter.GetDefaultAsync and its properties (worker thread,
/// implicit MTA: blocking here holds up no apartment).
fn queryAdapter() Capabilities {
    const statics = winrt.factory(AdapterStatics, adapter_class) catch return .{};
    defer winrt.release(statics);
    var op: ?*AdapterOp = null;
    winrt.check(statics.vtbl.GetDefaultAsync(statics, &op), "BluetoothAdapter.GetDefaultAsync") catch return .{};
    const o = op orelse return .{};
    defer winrt.release(o);
    // Null: no Bluetooth adapter.
    const raw = o.wait(op_timeout_ms) orelse return .{};
    const adapter: *Adapter = @ptrCast(@alignCast(raw));
    defer winrt.release(adapter);

    var peripheral: u8 = 0;
    if (adapter.vtbl.get_IsPeripheralRoleSupported(adapter, &peripheral) < 0) return .{};
    var extended = false;
    var max: u32 = common.legacy_max;
    if (winrt.queryOptional(Adapter3, adapter)) |a3| {
        defer winrt.release(a3);
        var b: u8 = 0;
        if (a3.vtbl.get_IsExtendedAdvertisingSupported(a3, &b) >= 0) extended = b != 0;
        var m: u32 = 0;
        if (a3.vtbl.get_MaxAdvertisementDataLength(a3, &m) >= 0 and m > 0) max = m;
    }
    const can = peripheral != 0;
    const f = common.fieldsOf(.windows);
    return .{
        .advertise = can,
        .service_data = can and f.service_data,
        .local_name = can and f.local_name,
        .connectable = can and f.connectable,
        .non_connectable = can and f.non_connectable,
        .extended = can and extended,
        .max_bytes = if (can) @intCast(@min(max, std.math.maxInt(u16))) else 0,
        .scan = false, // no scanning API yet
        .scan_service_data = false,
        .powered = radioOn(adapter),
    };
}

/// The adapter's radio is on; true when its state can't be read (an
/// adapter exists).
fn radioOn(adapter: *Adapter) bool {
    var op: ?*RadioOp = null;
    if (adapter.vtbl.GetRadioAsync(adapter, &op) < 0) return true;
    const o = op orelse return true;
    defer winrt.release(o);
    const raw = o.wait(op_timeout_ms) orelse return true;
    const radio: *Radio = @ptrCast(@alignCast(raw));
    defer winrt.release(radio);
    var state: i32 = 0;
    if (radio.vtbl.get_State(radio, &state) < 0) return true;
    return state == Radio.state_on;
}

// ------------------------------------------------------------ advertise

const Entry = struct {
    handle: Handle,
    publisher: *Publisher,
    token: winrt.EventToken,
    /// Failed or stopped was reported: nothing more is.
    ended: bool = false,
};

var table_lock: win32.SRWLOCK = win32.SRWLOCK_INIT;
var table: std.ArrayList(Entry) = .empty;
var next_handle: std.atomic.Value(u32) = .init(1);

fn newHandle() Handle {
    while (true) {
        const h = next_handle.fetchAdd(1, .monotonic);
        if (h != 0) return h;
    }
}

/// Start advertising `ad` (validated by bluetooth.zig): its handle. The
/// start, or a failure after this returns, comes as the advertisement's
/// state.
pub fn advertise(ad: Advertisement) common.Error!Handle {
    try common.checkSize(ad, 0, common.legacy_max);
    const secs = try sections(ad);
    winrt.keepMta();

    const publisher = buildPublisher(secs.slice()) catch |e| {
        log.warn("bluetooth: the publisher couldn't be built: {s}", .{@errorName(e)});
        return error.Failed;
    };
    const handle = newHandle();
    const handler = StatusHandler.create(@ptrFromInt(handle), onStatus) catch {
        winrt.release(publisher);
        return error.Failed;
    };
    defer winrt.release(handler);
    var token: winrt.EventToken = .{};
    winrt.check(publisher.vtbl.add_StatusChanged(publisher, handler, &token), "add_StatusChanged") catch {
        winrt.release(publisher);
        return error.Failed;
    };

    // In the table before Start: Started may come before Start returns.
    win32.AcquireSRWLockExclusive(&table_lock);
    table.append(gpa, .{ .handle = handle, .publisher = publisher, .token = token }) catch {
        win32.ReleaseSRWLockExclusive(&table_lock);
        _ = publisher.vtbl.remove_StatusChanged(publisher, token);
        winrt.release(publisher);
        return error.Failed;
    };
    win32.ReleaseSRWLockExclusive(&table_lock);

    const hr = publisher.vtbl.Start(publisher);
    if (hr < 0) {
        winrt.check(hr, "BluetoothLEAdvertisementPublisher.Start") catch {};
        if (take(handle)) |e| teardown(e, false);
        return errorOfHresult(hr);
    }
    return handle;
}

/// A publisher of `secs` (a new BluetoothLEAdvertisement with them as its
/// data sections).
fn buildPublisher(secs: []const Section) winrt.Error!*Publisher {
    const adv = try winrt.activate(BleAdvertisement, advertisement_class);
    defer winrt.release(adv);
    var vec: ?*SectionVector = null;
    try winrt.check(adv.vtbl.get_DataSections(adv, &vec), "get_DataSections");
    const v = vec orelse return error.WinRT;
    defer winrt.release(v);

    const buffers = try winrt.factory(CryptographicBufferStatics, crypto_buffer_class);
    defer winrt.release(buffers);
    const section_factory = try winrt.factory(DataSectionFactory, section_class);
    defer winrt.release(section_factory);
    for (secs) |*s| {
        const bytes = s.data();
        var buf: ?*Inspectable = null;
        try winrt.check(buffers.vtbl.CreateFromByteArray(buffers, @intCast(bytes.len), bytes.ptr, &buf), "CryptographicBuffer.CreateFromByteArray");
        const b = buf orelse return error.WinRT;
        defer winrt.release(b);
        var sec: ?*DataSection = null;
        try winrt.check(section_factory.vtbl.Create(section_factory, s.kind, b, &sec), "BluetoothLEAdvertisementDataSection.Create");
        const sc = sec orelse return error.WinRT;
        defer winrt.release(sc);
        try winrt.check(v.vtbl.Append(v, sc), "DataSections.Append");
    }

    const publisher_factory = try winrt.factory(PublisherFactory, publisher_class);
    defer winrt.release(publisher_factory);
    var out: ?*Publisher = null;
    try winrt.check(publisher_factory.vtbl.Create(publisher_factory, adv, &out), "BluetoothLEAdvertisementPublisher.Create");
    return out orelse error.WinRT;
}

/// StatusChanged (a thread-pool thread).
fn onStatus(ctx: *anyopaque, _: *Publisher, args: *StatusArgs) void {
    const handle: Handle = @intCast(@intFromPtr(ctx));
    var status: PublisherStatus = .created;
    if (args.vtbl.get_Status(args, &status) < 0) return;
    var err: BluetoothError = .success;
    if (args.vtbl.get_Error(args, &err) < 0) err = .other_error;
    const r = reportOf(status, err) orelse return;

    win32.AcquireSRWLockExclusive(&table_lock);
    const report = for (table.items) |*e| {
        if (e.handle != handle) continue;
        if (e.ended) break false;
        if (r.state != .started) e.ended = true;
        break true;
    } else false; // stopped by `stop`
    win32.ReleaseSRWLockExclusive(&table_lock);
    if (!report) return;
    if (r.err) |e| log.info("bluetooth: advertisement {d} aborted ({s}): {s}", .{ handle, @tagName(err), @errorName(e) });
    common.dispatchState(handle, r.state, r.err);
}

/// Removes `handle`'s entry from the table.
fn take(handle: Handle) ?Entry {
    win32.AcquireSRWLockExclusive(&table_lock);
    defer win32.ReleaseSRWLockExclusive(&table_lock);
    for (table.items, 0..) |e, i| if (e.handle == handle) return table.swapRemove(i);
    return null;
}

fn teardown(e: Entry, stop_it: bool) void {
    // The handler first: the Stopped this causes isn't reported.
    _ = e.publisher.vtbl.remove_StatusChanged(e.publisher, e.token);
    if (stop_it) winrt.check(e.publisher.vtbl.Stop(e.publisher), "BluetoothLEAdvertisementPublisher.Stop") catch {};
    winrt.release(e.publisher);
}

/// Stop an advertisement (unknown handles are ignored).
pub fn stop(handle: Handle) void {
    const e = take(handle) orelse return;
    winrt.keepMta();
    teardown(e, true);
}

// ----------------------------------------------------------------- tests

/// The AD structures (length, type, data) the stack sends for `s`.
fn wire(s: *const Sections, out: []u8) []const u8 {
    var n: usize = 0;
    for (s.slice()) |*sec| {
        out[n] = @intCast(1 + sec.len);
        out[n + 1] = sec.kind;
        @memcpy(out[n + 2 ..][0..sec.len], sec.data());
        n += 2 + sec.len;
    }
    return out[0..n];
}

test "sections: 16-bit UUIDs as a complete list (0x03), little-endian" {
    const t = std.testing;
    const uuids = [_]u16{ 0x180F, 0xFE2C };
    const s = try sections(.{ .service_uuids16 = &uuids });
    try t.expectEqual(@as(usize, 1), s.len);
    try t.expectEqual(@as(u8, 0x03), s.items[0].kind);
    try t.expectEqualSlices(u8, &.{ 0x0F, 0x18, 0x2C, 0xFE }, s.items[0].data());
    var buf: [64]u8 = undefined;
    try t.expectEqualSlices(u8, &.{ 0x05, 0x03, 0x0F, 0x18, 0x2C, 0xFE }, wire(&s, &buf));
}

test "sections: service data (0x16) as [uuid lo, uuid hi, data...]" {
    const t = std.testing;
    const s = try sections(.{ .service_data = .{ .uuid16 = 0xFE2C, .data = &.{ 0xAA, 0xBB, 0xCC } } });
    try t.expectEqual(@as(usize, 1), s.len);
    try t.expectEqual(@as(u8, 0x16), s.items[0].kind);
    try t.expectEqualSlices(u8, &.{ 0x2C, 0xFE, 0xAA, 0xBB, 0xCC }, s.items[0].data());
    var buf: [64]u8 = undefined;
    try t.expectEqualSlices(u8, &.{ 0x06, 0x16, 0x2C, 0xFE, 0xAA, 0xBB, 0xCC }, wire(&s, &buf));
}

test "sections: both, in order, and the wire size is common.encodedSize" {
    const t = std.testing;
    const uuids = [_]u16{0x181C};
    const payload = [_]u8{0x42} ** 20;
    const ad: Advertisement = .{ .service_uuids16 = &uuids, .service_data = .{ .uuid16 = 0xFE2C, .data = &payload } };
    const s = try sections(ad);
    try t.expectEqual(@as(usize, 2), s.len);
    try t.expectEqual(@as(u8, 0x03), s.items[0].kind);
    try t.expectEqual(@as(u8, 0x16), s.items[1].kind);
    var buf: [64]u8 = undefined;
    const w = wire(&s, &buf);
    try t.expectEqual(common.encodedSize(ad, 0), w.len);
    try t.expectEqualSlices(u8, &.{ 0x03, 0x03, 0x1C, 0x18, 0x17, 0x16, 0x2C, 0xFE, 0x42 }, w[0..9]);
    // The FE2C wake-up beacon: 28 bytes on the wire.
    const beacon = [_]u8{0} ** 24;
    const b = try sections(.{ .service_data = .{ .uuid16 = 0xFE2C, .data = &beacon } });
    try t.expectEqual(@as(usize, 28), wire(&b, &buf).len);
    // Nothing fits past 31 bytes.
    const big = [_]u8{0} ** 30;
    try t.expectError(error.TooLarge, sections(.{ .service_data = .{ .uuid16 = 1, .data = &big } }));
}

test reportOf {
    const t = std.testing;
    try t.expectEqual(Report{ .state = .started }, reportOf(.started, .success).?);
    try t.expectEqual(Report{ .state = .stopped }, reportOf(.stopped, .success).?);
    try t.expectEqual(Report{ .state = .failed, .err = error.AdapterOff }, reportOf(.aborted, .radio_not_available).?);
    try t.expect(reportOf(.waiting, .success) == null);
    try t.expect(reportOf(.created, .success) == null);
    try t.expect(reportOf(.stopping, .success) == null);
    try t.expect(reportOf(@enumFromInt(42), .success) == null);
}

test errorOf {
    const t = std.testing;
    try t.expectEqual(error.AdapterOff, errorOf(.radio_not_available));
    try t.expectEqual(error.PermissionDenied, errorOf(.disabled_by_policy));
    try t.expectEqual(error.PermissionDenied, errorOf(.disabled_by_user));
    try t.expectEqual(error.PermissionDenied, errorOf(.consent_required));
    try t.expectEqual(error.Unsupported, errorOf(.not_supported));
    try t.expectEqual(error.Unsupported, errorOf(.transport_not_supported));
    try t.expectEqual(error.Failed, errorOf(.resource_in_use));
    try t.expectEqual(error.Failed, errorOf(.other_error));
    try t.expectEqual(error.Failed, errorOf(@enumFromInt(99)));
}

test errorOfHresult {
    const t = std.testing;
    try t.expectEqual(error.PermissionDenied, errorOfHresult(@bitCast(@as(u32, 0x80070005))));
    try t.expectEqual(error.Unsupported, errorOfHresult(@bitCast(@as(u32, 0x80070032))));
    try t.expectEqual(error.AdapterOff, errorOfHresult(@bitCast(@as(u32, 0x800710DF))));
    try t.expectEqual(error.Failed, errorOfHresult(winrt.E_FAIL));
}

test "parameterized IIDs: the Windows SDK's and mingw-w64's" {
    const t = std.testing;
    // TypedEventHandler<BluetoothLEAdvertisementPublisher,
    // BluetoothLEAdvertisementPublisherStatusChangedEventArgs>
    // (windows.devices.bluetooth.advertisement.h, SDK 10.0.16299).
    try t.expectEqual(GUID.parse("{C2FFA4F1-5893-54A8-BD94-AA1198B05D07}"), status_handler_iid);
    // IAsyncOperation<BluetoothAdapter> and its completion handler
    // (windows.devices.bluetooth.h).
    try t.expectEqual(GUID.parse("{46FCE70C-6C07-5A3A-B775-26F99402553F}"), AdapterOp.iid);
    try t.expectEqual(GUID.parse("{10A10A88-90E0-511A-9A08-D75FEB52A19F}"), AdapterOp.handler_iid);
    // IAsyncOperation<Radio> and its handler (windows.devices.radios.h).
    try t.expectEqual(GUID.parse("{EAC62C40-8DBC-5854-8BA0-B7B9940E7389}"), RadioOp.iid);
    try t.expectEqual(GUID.parse("{8A5C7E3A-80E2-585B-8630-7A8E777F0354}"), RadioOp.handler_iid);
}

fn VtblOf(comptime T: type) type {
    return @typeInfo(@FieldType(T, "vtbl")).pointer.child;
}

test "vtable slots" {
    // Windows only: elsewhere a winapi function pointer may not be declarable.
    if (builtin.os.tag == .windows) try checkSlots() else return error.SkipZigTest;
}

fn checkSlots() !void {
    const t = std.testing;
    const p = @sizeOf(usize);
    // IInspectable's six slots, then the interface's in metadata order.
    try t.expectEqual(6 * p, @offsetOf(VtblOf(Publisher), "get_Status"));
    try t.expectEqual(8 * p, @offsetOf(VtblOf(Publisher), "Start"));
    try t.expectEqual(11 * p, @offsetOf(VtblOf(Publisher), "remove_StatusChanged"));
    try t.expectEqual(12 * p, @offsetOf(VtblOf(BleAdvertisement), "get_DataSections"));
    try t.expectEqual(13 * p, @offsetOf(VtblOf(SectionVector), "Append"));
    try t.expectEqual(10 * p, @offsetOf(VtblOf(Adapter), "get_IsPeripheralRoleSupported"));
    try t.expectEqual(13 * p, @offsetOf(VtblOf(Adapter), "GetRadioAsync"));
    try t.expectEqual(8 * p, @offsetOf(VtblOf(AdapterStatics), "GetDefaultAsync"));
    try t.expectEqual(9 * p, @offsetOf(VtblOf(CryptographicBufferStatics), "CreateFromByteArray"));
    try t.expectEqual(9 * p, @offsetOf(VtblOf(Radio), "get_State"));
    try t.expectEqual(7 * p, @offsetOf(VtblOf(StatusArgs), "get_Error"));
}
