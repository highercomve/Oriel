//! The Objective-C runtime in plain Zig: the part of zig-objc's API the
//! backends use (`Object`, `Class`, `msgSend`, `sel`, class definition,
//! autorelease pools), declared with `extern` functions of libobjc instead of
//! translated SDK headers. Code using it type-checks without an Apple SDK
//! (`zig build check -Dtarget=aarch64-ios` on Linux); linking still needs one.
//!
//! Only arm64 (devices and Apple-silicon simulators) and x86_64 simulators:
//! on x86_64, large struct returns go through `objc_msgSend_stret` and
//! doubles through `objc_msgSend_fpret`, as clang does.

const std = @import("std");
const builtin = @import("builtin");

pub const c = struct {
    pub const id = ?*anyopaque;
    pub const SEL = ?*anyopaque;
    /// `Class` (a raw pointer; `objc.Class` wraps it).
    pub const RawClass = ?*anyopaque;
    pub const IMP = ?*const anyopaque;
    pub const RawProtocol = anyopaque;
    /// `BOOL`: `bool` on arm64, `signed char` on x86_64.
    pub const BOOL = if (builtin.cpu.arch == .aarch64) bool else i8;

    pub extern "objc" fn objc_msgSend() callconv(.c) void;
    pub extern "objc" fn objc_msgSend_stret() callconv(.c) void;
    pub extern "objc" fn objc_msgSend_fpret() callconv(.c) void;
    pub extern "objc" fn objc_getClass(name: [*:0]const u8) RawClass;
    pub extern "objc" fn objc_getProtocol(name: [*:0]const u8) ?*RawProtocol;
    pub extern "objc" fn objc_allocateClassPair(superclass: RawClass, name: [*:0]const u8, extra: usize) RawClass;
    pub extern "objc" fn objc_registerClassPair(cls: RawClass) void;
    pub extern "objc" fn class_addMethod(cls: RawClass, name: SEL, imp: IMP, types: [*:0]const u8) BOOL;
    pub extern "objc" fn class_addProtocol(cls: RawClass, protocol: *RawProtocol) BOOL;
    pub extern "objc" fn class_respondsToSelector(cls: RawClass, sel: SEL) BOOL;
    pub extern "objc" fn object_getClass(obj: id) RawClass;
    pub extern "objc" fn class_getName(cls: RawClass) [*:0]const u8;
    pub extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;
    pub extern "objc" fn objc_autoreleasePoolPush() ?*anyopaque;
    pub extern "objc" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;
    pub extern "objc" fn objc_retain(obj: id) id;
    pub extern "objc" fn objc_release(obj: id) void;
};

pub const Sel = struct {
    value: c.SEL,
};

/// The selector `name` (registered once by the runtime, cheap to repeat).
pub fn sel(name: [:0]const u8) Sel {
    return .{ .value = c.sel_registerName(name.ptr) };
}

pub const Protocol = struct {
    value: *c.RawProtocol,
};

pub fn getProtocol(name: [:0]const u8) ?Protocol {
    return .{ .value = c.objc_getProtocol(name.ptr) orelse return null };
}

pub const Object = struct {
    value: c.id,

    pub fn msgSend(self: Object, comptime Return: type, selector: anytype, args: anytype) Return {
        return send(self.value, Return, selector, args);
    }

    pub fn getClass(self: Object) ?Class {
        return .{ .value = c.object_getClass(self.value) orelse return null };
    }

    pub fn retain(self: Object) Object {
        return .{ .value = c.objc_retain(self.value) };
    }

    pub fn release(self: Object) void {
        c.objc_release(self.value);
    }
};

pub const Class = struct {
    value: *anyopaque,

    pub fn msgSend(self: Class, comptime Return: type, selector: anytype, args: anytype) Return {
        return send(self.value, Return, selector, args);
    }

    pub fn respondsToSelector(self: Class, selector: Sel) bool {
        return isTrue(c.class_respondsToSelector(self.value, selector.value));
    }

    /// Add method `name` implemented by `imp`, a `callconv(.c)` function
    /// taking `(id self, SEL _cmd, ...)`. The type encoding is derived from
    /// its signature.
    pub fn addMethod(self: Class, name: [:0]const u8, imp: anytype) bool {
        const encoding = comptime typeEncoding(@TypeOf(imp));
        return isTrue(c.class_addMethod(self.value, sel(name).value, @ptrCast(&imp), encoding));
    }
};

pub fn getClass(name: [:0]const u8) ?Class {
    return .{ .value = c.objc_getClass(name.ptr) orelse return null };
}

pub fn allocateClassPair(superclass: ?Class, name: [:0]const u8) ?Class {
    return .{ .value = c.objc_allocateClassPair(if (superclass) |s| s.value else null, name.ptr, 0) orelse return null };
}

pub fn registerClassPair(cls: Class) void {
    c.objc_registerClassPair(cls.value);
}

pub const AutoreleasePool = struct {
    token: ?*anyopaque,

    pub fn init() AutoreleasePool {
        return .{ .token = c.objc_autoreleasePoolPush() };
    }

    pub fn deinit(self: AutoreleasePool) void {
        c.objc_autoreleasePoolPop(self.token);
    }
};

fn isTrue(v: c.BOOL) bool {
    return if (c.BOOL == bool) v else v != 0;
}

// ---------------------------------------------------------------------------
// objc_msgSend with the right function type
// ---------------------------------------------------------------------------

fn send(target: ?*anyopaque, comptime Return: type, selector: anytype, args: anytype) Return {
    const s: Sel = if (@TypeOf(selector) == Sel) selector else sel(selector);
    const is_object = Return == Object;
    const Real = if (is_object) c.id else Return;
    const Fn = MsgSendFn(Real, @TypeOf(args));
    const ptr: *const Fn = @ptrCast(@alignCast(comptime msgSendPtr(Real)));
    const result = @call(.auto, ptr, .{ target, s.value } ++ unwrapArgs(args));
    return if (is_object) .{ .value = result } else result;
}

fn msgSendPtr(comptime Return: type) *const fn () callconv(.c) void {
    return switch (builtin.cpu.arch) {
        .aarch64 => &c.objc_msgSend,
        .x86_64 => switch (@typeInfo(Return)) {
            .@"struct" => if (@sizeOf(Return) > 16) &c.objc_msgSend_stret else &c.objc_msgSend,
            .float => |f| if (f.bits == 64) &c.objc_msgSend_fpret else &c.objc_msgSend,
            else => &c.objc_msgSend,
        },
        else => @compileError("unsupported Objective-C architecture"),
    };
}

fn MsgSendFn(comptime Return: type, comptime Args: type) type {
    const fields = @typeInfo(Args).@"struct".fields;
    var params: [fields.len + 2]type = undefined;
    params[0] = c.id;
    params[1] = c.SEL;
    for (fields, 0..) |f, i| params[i + 2] = Unwrapped(f.type);
    return @Fn(&params, &@splat(.{}), Return, .{ .@"callconv" = .c });
}

/// `Object`, `Class`, `Sel` and `Protocol` are passed as their raw pointer.
fn Unwrapped(comptime T: type) type {
    if (T == Object) return c.id;
    if (T == Class) return c.RawClass;
    if (T == Sel) return c.SEL;
    if (T == Protocol) return *c.RawProtocol;
    if (T == comptime_int) return isize;
    if (T == comptime_float) return f64;
    return T;
}

fn UnwrappedArgs(comptime Args: type) type {
    const fields = @typeInfo(Args).@"struct".fields;
    var types: [fields.len]type = undefined;
    for (fields, 0..) |f, i| types[i] = Unwrapped(f.type);
    return @Tuple(&types);
}

inline fn unwrapArgs(args: anytype) UnwrappedArgs(@TypeOf(args)) {
    var out: UnwrappedArgs(@TypeOf(args)) = undefined;
    inline for (@typeInfo(@TypeOf(args)).@"struct".fields, 0..) |f, i| {
        const v = @field(args, f.name);
        out[i] = switch (@TypeOf(v)) {
            Object, Class, Sel, Protocol => v.value,
            else => v,
        };
    }
    return out;
}

// ---------------------------------------------------------------------------
// Type encodings for class_addMethod
// ---------------------------------------------------------------------------

/// The Objective-C type encoding of a method implementation's signature,
/// e.g. `fn (id, SEL, id) callconv(.c) void` -> "v@:@".
fn typeEncoding(comptime F: type) [:0]const u8 {
    return comptime blk: {
        const info = @typeInfo(F).@"fn";
        var out: []const u8 = encode(info.return_type.?);
        for (info.params) |p| out = out ++ encode(p.type.?);
        const z = out ++ "\x00";
        break :blk z[0..out.len :0];
    };
}

fn encode(comptime T: type) []const u8 {
    if (T == c.BOOL) return "B";
    return switch (@typeInfo(T)) {
        .void => "v",
        .bool => "B",
        .int => |i| switch (i.bits) {
            8 => if (i.signedness == .signed) "c" else "C",
            16 => if (i.signedness == .signed) "s" else "S",
            32 => if (i.signedness == .signed) "i" else "I",
            64 => if (i.signedness == .signed) "q" else "Q",
            else => "?",
        },
        .float => |f| if (f.bits == 32) "f" else "d",
        // id, SEL and other pointers: the runtime only needs sizes to line up.
        .optional, .pointer => "@",
        .@"struct" => "{?}",
        else => "?",
    };
}

test typeEncoding {
    try std.testing.expectEqualStrings("v@@@", typeEncoding(fn (c.id, c.SEL, c.id) callconv(.c) void));
    try std.testing.expectEqualStrings("B@@", typeEncoding(fn (c.id, c.SEL) callconv(.c) c.BOOL));
    try std.testing.expectEqualStrings("q@@@q", typeEncoding(fn (c.id, c.SEL, c.id, i64) callconv(.c) i64));
}
