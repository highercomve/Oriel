//! The Windows Runtime from Zig, without SDK headers or a projection:
//! what oriel.share (DataTransferManager) and oriel.bluetooth
//! (BluetoothLEAdvertisementPublisher) build on.
//!
//! - HSTRINGs (`String`), activation factories and instances (`factory`,
//!   `activate`) and IInspectable's vtable layout (`Inspectable`).
//! - The IIDs of parameterized interfaces and delegates (`piid`): computed
//!   at compile time from their type signature, as the WinRT type system
//!   specifies (a UUIDv5 over the signature), so no IID is copied by hand.
//! - Delegates implemented in Zig (`Delegate`): event handlers and async
//!   completion handlers, agile (IAgileObject), so the runtime may call
//!   them on any thread.
//! - Waiting for nothing: async operations complete through a delegate
//!   (`AsyncOperation.then`); nothing here blocks the UI thread.
//!
//! Interfaces are declared by their consumer as extern structs whose first
//! field is `vtbl`; the vtable starts with `Inspectable.Vtbl`'s six slots,
//! then the interface's methods in metadata order. IIDs and slot orders
//! come from the system's metadata (C:\Windows\System32\WinMetadata\*.winmd).
//!
//! The UI thread is a single-threaded apartment (Shell's CoInitializeEx);
//! the runtime works there without RoInitialize.

const std = @import("std");
const win32 = @import("win32.zig");

pub const GUID = win32.GUID;
pub const HRESULT = win32.HRESULT;
pub const HSTRING = ?*opaque {};

pub const S_OK: HRESULT = 0;
pub const E_NOINTERFACE: HRESULT = win32.E_NOINTERFACE;
pub const E_POINTER: HRESULT = @bitCast(@as(u32, 0x80004003));
pub const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));

extern "api-ms-win-core-winrt-l1-1-0" fn RoGetActivationFactory(class_id: HSTRING, iid: *const GUID, factory: *?*anyopaque) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-l1-1-0" fn RoActivateInstance(class_id: HSTRING, instance: *?*anyopaque) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsCreateString(src: ?[*]const u16, len: u32, out: *HSTRING) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsDeleteString(s: HSTRING) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsGetStringRawBuffer(s: HSTRING, len: ?*u32) callconv(.winapi) ?[*]const u16;

pub const Error = error{ WinRT, OutOfMemory };

/// A failed HRESULT is `error.WinRT` (logged with `what`).
pub fn check(hr: HRESULT, what: []const u8) Error!void {
    if (hr >= 0) return;
    std.log.scoped(.winrt).warn("{s}: 0x{X:0>8}", .{ what, @as(u32, @bitCast(hr)) });
    return error.WinRT;
}

// ---------------------------------------------------------------- strings

/// An owned HSTRING (null is the empty string).
pub const String = struct {
    h: HSTRING = null,

    pub fn fromUtf16(s: []const u16) Error!String {
        var h: HSTRING = null;
        try check(WindowsCreateString(s.ptr, @intCast(s.len), &h), "WindowsCreateString");
        return .{ .h = h };
    }

    pub fn fromUtf8(gpa: std.mem.Allocator, s: []const u8) Error!String {
        const w = std.unicode.utf8ToUtf16LeAlloc(gpa, s) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.WinRT, // not UTF-8
        };
        defer gpa.free(w);
        return fromUtf16(w);
    }

    /// A string the runtime handed over (the caller owns it now).
    pub fn adopt(h: HSTRING) String {
        return .{ .h = h };
    }

    pub fn utf16(s: String) []const u16 {
        var len: u32 = 0;
        const p = WindowsGetStringRawBuffer(s.h, &len) orelse return &.{};
        return p[0..len];
    }

    pub fn toUtf8(s: String, gpa: std.mem.Allocator) Error![]u8 {
        return std.unicode.utf16LeToUtf8Alloc(gpa, s.utf16()) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.WinRT, // unpaired surrogate
        };
    }

    pub fn deinit(s: *String) void {
        _ = WindowsDeleteString(s.h);
        s.h = null;
    }
};

/// A comptime string as UTF-16, for class names.
pub fn L(comptime s: []const u8) []const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

// ------------------------------------------------------------ inspectable

/// IUnknown and IInspectable: the first six slots of every WinRT vtable.
pub const Inspectable = extern struct {
    vtbl: *const Vtbl,

    pub const iid = GUID.parse("{AF86E2E0-B12D-4C6A-9C5A-D7AA65101E90}");

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
        Release: *const fn (*anyopaque) callconv(.winapi) u32,
        GetIids: *const fn (*anyopaque, *u32, *?*GUID) callconv(.winapi) HRESULT,
        GetRuntimeClassName: *const fn (*anyopaque, *HSTRING) callconv(.winapi) HRESULT,
        GetTrustLevel: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    };
};

pub const iid_unknown = GUID.parse("{00000000-0000-0000-C000-000000000046}");
pub const iid_agile = GUID.parse("{94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90}");

/// The `Inspectable.Vtbl` at the start of any interface pointer.
fn base(p: anytype) *const Inspectable.Vtbl {
    const v: *const *const Inspectable.Vtbl = @ptrCast(@alignCast(p));
    return v.*;
}

pub fn release(p: anytype) void {
    _ = base(p).Release(@ptrCast(p));
}

pub fn addRef(p: anytype) void {
    _ = base(p).AddRef(@ptrCast(p));
}

/// `p` as interface `T` (T.iid), a new reference.
pub fn query(comptime T: type, p: anytype) Error!*T {
    var out: ?*anyopaque = null;
    try check(base(p).QueryInterface(@ptrCast(p), &T.iid, &out), "QueryInterface " ++ @typeName(T));
    return @ptrCast(@alignCast(out orelse return error.WinRT));
}

/// The activation factory of runtime class `class` as interface `T`.
pub fn factory(comptime T: type, comptime class: []const u8) Error!*T {
    var name = try String.fromUtf16(L(class));
    defer name.deinit();
    var out: ?*anyopaque = null;
    try check(RoGetActivationFactory(name.h, &T.iid, &out), "RoGetActivationFactory " ++ class);
    return @ptrCast(@alignCast(out orelse return error.WinRT));
}

/// A new instance of `class` (its default constructor) as interface `T`.
pub fn activate(comptime T: type, comptime class: []const u8) Error!*T {
    var name = try String.fromUtf16(L(class));
    defer name.deinit();
    var out: ?*anyopaque = null;
    try check(RoActivateInstance(name.h, &out), "RoActivateInstance " ++ class);
    const obj: *Inspectable = @ptrCast(@alignCast(out orelse return error.WinRT));
    defer release(obj);
    return query(T, obj);
}

// --------------------------------------------------- parameterized IIDs

/// Type signatures, as the WinRT type system writes them, for `piid`.
pub const sig = struct {
    pub const string = "string";
    pub const boolean = "b1";
    pub const object = "cinterface(IInspectable)";

    /// An interface or delegate by its IID.
    pub fn iface(comptime iid: GUID) []const u8 {
        return comptime guidText(iid);
    }

    /// A runtime class: its name and its default interface's signature.
    pub fn class(comptime name: []const u8, comptime default_iid: GUID) []const u8 {
        return comptime "rc(" ++ name ++ ";" ++ guidText(default_iid) ++ ")";
    }

    /// A parameterized type: its generic IID and its arguments' signatures.
    pub fn pinterface(comptime g: GUID, comptime args: []const []const u8) []const u8 {
        return comptime blk: {
            var s: []const u8 = "pinterface(" ++ guidText(g);
            for (args) |a| s = s ++ ";" ++ a;
            break :blk s ++ ")";
        };
    }
};

/// The generic IIDs (from Windows.Foundation.winmd).
pub const generic = struct {
    pub const typed_event_handler = GUID.parse("{9DE1C534-6AE1-11E0-84E1-18A905BCC53F}");
    pub const async_operation = GUID.parse("{9FC2B0BB-E446-44E2-AA61-9CAB8F636AF2}");
    pub const async_operation_completed = GUID.parse("{FCDCF02C-E5D8-4478-915A-4D90B74B83A5}");
    pub const iterable = GUID.parse("{FAA585EA-6214-4217-AFDA-7F46DE5869B3}");
    pub const iterator = GUID.parse("{6A79E863-4300-459A-9966-CBB660963EE1}");
};

/// "{xxxxxxxx-xxxx-...}" in lower case, as signatures spell IIDs.
fn guidText(comptime g: GUID) []const u8 {
    return comptime std.fmt.comptimePrint("{{{x:0>8}-{x:0>4}-{x:0>4}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}}}", .{
        g.Data1,    g.Data2,    g.Data3,
        g.Data4[0], g.Data4[1], g.Data4[2],
        g.Data4[3], g.Data4[4], g.Data4[5],
        g.Data4[6], g.Data4[7],
    });
}

/// The IID of a parameterized interface or delegate from its signature
/// (`sig.pinterface`): a version 5 UUID, SHA-1 over the WinRT namespace
/// {11F47AD5-7B73-42C0-ABAE-878B1E16ADEE} and the signature in UTF-8.
pub fn piid(comptime signature: []const u8) GUID {
    @setEvalBranchQuota(100_000);
    const ns = [16]u8{ 0x11, 0xf4, 0x7a, 0xd5, 0x7b, 0x73, 0x42, 0xc0, 0xab, 0xae, 0x87, 0x8b, 0x1e, 0x16, 0xad, 0xee };
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(&ns);
    h.update(signature);
    var d: [20]u8 = undefined;
    h.final(&d);
    d[6] = (d[6] & 0x0f) | 0x50;
    d[8] = (d[8] & 0x3f) | 0x80;
    return .{
        .Data1 = std.mem.readInt(u32, d[0..4], .big),
        .Data2 = std.mem.readInt(u16, d[4..6], .big),
        .Data3 = std.mem.readInt(u16, d[6..8], .big),
        .Data4 = d[8..16].*,
    };
}

// -------------------------------------------------------------- delegates

/// A delegate implemented in Zig: `Invoke(self, a, b)` calls
/// `func(ctx, a, b)`. `iid` is the delegate's (parameterized) IID; `A`
/// and `B` its two argument types (an async completion handler's are the
/// operation and an AsyncStatus).
///
/// Reference counted; `create` returns it with one reference, which the
/// caller releases once it handed the delegate over (the event source or
/// operation keeps its own). Agile: `func` may run on any thread.
pub fn Delegate(comptime iid: GUID, comptime A: type, comptime B: type, comptime Ctx: type) type {
    return extern struct {
        vtbl: *const Vtbl = &vtbl_impl,
        refs: std.atomic.Value(u32) = .init(1),
        ctx: *Ctx,
        /// A `Func` (extern structs hold no Zig-convention pointers).
        func: *const anyopaque,

        const Self = @This();
        pub const Func = fn (ctx: *Ctx, a: A, b: B) void;

        pub const Vtbl = extern struct {
            QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
            AddRef: *const fn (*Self) callconv(.winapi) u32,
            Release: *const fn (*Self) callconv(.winapi) u32,
            Invoke: *const fn (*Self, A, B) callconv(.winapi) HRESULT,
        };

        const vtbl_impl: Vtbl = .{ .QueryInterface = queryInterface, .AddRef = addRefImpl, .Release = releaseImpl, .Invoke = invoke };

        pub fn create(ctx: *Ctx, func: *const Func) Error!*Self {
            const d = std.heap.smp_allocator.create(Self) catch return error.OutOfMemory;
            d.* = .{ .ctx = ctx, .func = @ptrCast(func) };
            return d;
        }

        fn queryInterface(self: *Self, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
            if (win32.isEqualGUID(riid, &iid) or win32.isEqualGUID(riid, &iid_unknown) or win32.isEqualGUID(riid, &iid_agile)) {
                _ = self.refs.fetchAdd(1, .monotonic);
                out.* = self;
                return S_OK;
            }
            out.* = null;
            return E_NOINTERFACE;
        }

        fn addRefImpl(self: *Self) callconv(.winapi) u32 {
            return self.refs.fetchAdd(1, .monotonic) + 1;
        }

        fn releaseImpl(self: *Self) callconv(.winapi) u32 {
            const left = self.refs.fetchSub(1, .acq_rel) - 1;
            if (left == 0) std.heap.smp_allocator.destroy(self);
            return left;
        }

        fn invoke(self: *Self, a: A, b: B) callconv(.winapi) HRESULT {
            const f: *const Func = @ptrCast(@alignCast(self.func));
            f(self.ctx, a, b);
            return S_OK;
        }
    };
}

/// An event registration (`add_X` returns it, `remove_X` takes it).
pub const EventToken = extern struct { value: i64 = 0 };

// ---------------------------------------------------- async operations

pub const AsyncStatus = enum(i32) { started = 0, completed = 1, canceled = 2, failed = 3, _ };

/// IAsyncOperation<T> for a T that is an interface or runtime class with
/// signature `result_sig`: `then` calls back with the result.
pub fn AsyncOperation(comptime result_sig: []const u8) type {
    return extern struct {
        vtbl: *const Vtbl,

        const Self = @This();
        pub const iid = piid(sig.pinterface(generic.async_operation, &.{result_sig}));
        pub const handler_iid = piid(sig.pinterface(generic.async_operation_completed, &.{result_sig}));

        pub const Vtbl = extern struct {
            base: Inspectable.Vtbl,
            put_Completed: *const fn (*Self, *anyopaque) callconv(.winapi) HRESULT,
            get_Completed: *const fn (*Self, *?*anyopaque) callconv(.winapi) HRESULT,
            GetResults: *const fn (*Self, *?*anyopaque) callconv(.winapi) HRESULT,
        };

        /// Calls `done(ctx, result)` once the operation ends, on whatever
        /// thread completes it: `result` is a new reference (the callee
        /// releases it), null when the operation failed or was canceled.
        pub fn then(op: *Self, comptime Ctx: type, ctx: *Ctx, comptime done: fn (ctx: *Ctx, result: ?*Inspectable) void) Error!void {
            const H = Delegate(handler_iid, *Self, AsyncStatus, Ctx);
            const Glue = struct {
                fn completed(c: *Ctx, o: *Self, status: AsyncStatus) void {
                    if (status != .completed) return done(c, null);
                    var r: ?*anyopaque = null;
                    if (o.vtbl.GetResults(o, &r) < 0) return done(c, null);
                    done(c, @ptrCast(@alignCast(r)));
                }
            };
            const h = try H.create(ctx, Glue.completed);
            defer release(h);
            try check(op.vtbl.put_Completed(op, h), "IAsyncOperation.put_Completed");
        }
    };
}

// ------------------------------------------------- iterables from Zig

/// IIterable<T> over a fixed list of interface pointers (each with
/// signature `elem_sig`), implemented in Zig: what APIs that take a
/// collection (DataPackage.SetStorageItems) are given. Holds a reference
/// to each item; `create` returns one reference.
pub fn Iterable(comptime elem_sig: []const u8) type {
    return extern struct {
        vtbl: *const Vtbl = &vtbl_impl,
        refs: std.atomic.Value(u32) = .init(1),
        items: [*]*Inspectable,
        len: u32,

        const Self = @This();
        pub const iid = piid(sig.pinterface(generic.iterable, &.{elem_sig}));
        pub const iterator_iid = piid(sig.pinterface(generic.iterator, &.{elem_sig}));
        const gpa = std.heap.smp_allocator;

        const Vtbl = extern struct {
            base: Inspectable.Vtbl,
            First: *const fn (*Self, *?*anyopaque) callconv(.winapi) HRESULT,
        };
        const vtbl_impl: Vtbl = .{
            .base = Common(Self, iid).vtbl,
            .First = first,
        };

        /// Takes a new reference to each of `items`.
        pub fn create(items: []const *Inspectable) Error!*Self {
            const copy = gpa.dupe(*Inspectable, items) catch return error.OutOfMemory;
            errdefer gpa.free(copy);
            const self = gpa.create(Self) catch return error.OutOfMemory;
            for (copy) |it| addRef(it);
            self.* = .{ .items = copy.ptr, .len = @intCast(copy.len) };
            return self;
        }

        pub fn destroy(self: *Self) void {
            for (self.items[0..self.len]) |it| release(it);
            gpa.free(self.items[0..self.len]);
            gpa.destroy(self);
        }

        fn first(self: *Self, out: *?*anyopaque) callconv(.winapi) HRESULT {
            const it = gpa.create(Iterator) catch return E_FAIL;
            _ = self.refs.fetchAdd(1, .monotonic);
            it.* = .{ .list = self };
            out.* = it;
            return S_OK;
        }

        const Iterator = extern struct {
            vtbl: *const IVtbl = &ivtbl_impl,
            refs: std.atomic.Value(u32) = .init(1),
            list: *Self,
            at: u32 = 0,

            const IVtbl = extern struct {
                base: Inspectable.Vtbl,
                get_Current: *const fn (*Iterator, *?*anyopaque) callconv(.winapi) HRESULT,
                get_HasCurrent: *const fn (*Iterator, *u8) callconv(.winapi) HRESULT,
                MoveNext: *const fn (*Iterator, *u8) callconv(.winapi) HRESULT,
                GetMany: *const fn (*Iterator, u32, [*]?*anyopaque, *u32) callconv(.winapi) HRESULT,
            };
            const ivtbl_impl: IVtbl = .{
                .base = Common(Iterator, iterator_iid).vtbl,
                .get_Current = current,
                .get_HasCurrent = hasCurrent,
                .MoveNext = moveNext,
                .GetMany = getMany,
            };

            pub fn destroy(it: *Iterator) void {
                release(it.list);
                gpa.destroy(it);
            }

            fn current(it: *Iterator, out: *?*anyopaque) callconv(.winapi) HRESULT {
                if (it.at >= it.list.len) {
                    out.* = null;
                    return @bitCast(@as(u32, 0x8000000B)); // E_BOUNDS
                }
                const p = it.list.items[it.at];
                addRef(p);
                out.* = p;
                return S_OK;
            }

            fn hasCurrent(it: *Iterator, out: *u8) callconv(.winapi) HRESULT {
                out.* = @intFromBool(it.at < it.list.len);
                return S_OK;
            }

            fn moveNext(it: *Iterator, out: *u8) callconv(.winapi) HRESULT {
                if (it.at < it.list.len) it.at += 1;
                out.* = @intFromBool(it.at < it.list.len);
                return S_OK;
            }

            fn getMany(it: *Iterator, cap: u32, out: [*]?*anyopaque, n: *u32) callconv(.winapi) HRESULT {
                var k: u32 = 0;
                while (k < cap and it.at < it.list.len) : (k += 1) {
                    const p = it.list.items[it.at];
                    addRef(p);
                    out[k] = p;
                    it.at += 1;
                }
                n.* = k;
                return S_OK;
            }
        };
    };
}

/// IUnknown and IInspectable for an object of type `T` (fields `refs` and
/// a `destroy` method) whose only interface is `iid`. Agile.
fn Common(comptime T: type, comptime iid: GUID) type {
    return struct {
        const vtbl: Inspectable.Vtbl = .{
            .QueryInterface = @ptrCast(&queryInterface),
            .AddRef = @ptrCast(&addRefImpl),
            .Release = @ptrCast(&releaseImpl),
            .GetIids = @ptrCast(&getIids),
            .GetRuntimeClassName = @ptrCast(&getRuntimeClassName),
            .GetTrustLevel = @ptrCast(&getTrustLevel),
        };

        fn queryInterface(self: *T, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
            if (win32.isEqualGUID(riid, &iid) or win32.isEqualGUID(riid, &iid_unknown) or
                win32.isEqualGUID(riid, &Inspectable.iid) or win32.isEqualGUID(riid, &iid_agile))
            {
                _ = self.refs.fetchAdd(1, .monotonic);
                out.* = self;
                return S_OK;
            }
            out.* = null;
            return E_NOINTERFACE;
        }

        fn addRefImpl(self: *T) callconv(.winapi) u32 {
            return self.refs.fetchAdd(1, .monotonic) + 1;
        }

        fn releaseImpl(self: *T) callconv(.winapi) u32 {
            const left = self.refs.fetchSub(1, .acq_rel) - 1;
            if (left == 0) self.destroy();
            return left;
        }

        fn getIids(_: *T, n: *u32, out: *?*GUID) callconv(.winapi) HRESULT {
            n.* = 0;
            out.* = null;
            return S_OK;
        }

        fn getRuntimeClassName(_: *T, out: *HSTRING) callconv(.winapi) HRESULT {
            out.* = null;
            return S_OK;
        }

        fn getTrustLevel(_: *T, out: *i32) callconv(.winapi) HRESULT {
            out.* = 0; // BaseTrust
            return S_OK;
        }
    };
}

test "piid: the IIDs Windows' own headers give parameterized types" {
    const t = std.testing;
    // IIterable<String>, IVector<String>, IAsyncOperation<Boolean>
    // (windows.foundation.collections.h, windows.foundation.h).
    try t.expectEqual(GUID.parse("{E2FCC7C1-3BFC-5A0B-B2B0-72E769D1CB7E}"), piid(sig.pinterface(generic.iterable, &.{sig.string})));
    try t.expectEqual(GUID.parse("{98B9ACC1-4B56-532E-AC73-03D5291CCA90}"), piid(sig.pinterface(GUID.parse("{913337E9-11A1-4345-A3A2-4E7F956E222D}"), &.{sig.string})));
    try t.expectEqual(GUID.parse("{CDB5EFB3-5788-509D-9BE1-71CCB8A3362A}"), piid(sig.pinterface(generic.async_operation, &.{sig.boolean})));
}

test "signatures" {
    const t = std.testing;
    try t.expectEqualStrings("{9de1c534-6ae1-11e0-84e1-18a905bcc53f}", sig.iface(generic.typed_event_handler));
    try t.expectEqualStrings(
        "rc(Windows.Storage.StorageFile;{fa3f6186-4214-428c-a64c-14c9ac7315ea})",
        sig.class("Windows.Storage.StorageFile", GUID.parse("{FA3F6186-4214-428C-A64C-14C9AC7315EA}")),
    );
}
