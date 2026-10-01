//! Clang blocks (the block ABI) for Objective-C APIs that take completion
//! handlers, without the compiler's block syntax: global blocks, stack
//! blocks carrying one context pointer, and calling a block received as an
//! `id`. Shared by the iOS backend and Apple-only modules (iOS and macOS).

const std = @import("std");
const objc = @import("objc.zig");

pub const id = objc.c.id;

pub const BlockLiteral = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};

pub const BlockDescriptor = extern struct {
    reserved: c_ulong,
    size: c_ulong,
    /// Only set on managed blocks (the runtime requires BLOCK_HAS_COPY_DISPOSE).
    copy: ?*const anyopaque = null,
    dispose: ?*const anyopaque = null,
};

extern "c" fn _Block_copy(block: ?*const anyopaque) ?*anyopaque;
extern "c" fn _Block_release(block: ?*const anyopaque) void;
extern var _NSConcreteGlobalBlock: [32]usize;

const BLOCK_IS_GLOBAL: c_int = 1 << 28;
/// The descriptor carries copy/dispose helpers the runtime calls.
const BLOCK_HAS_COPY_DISPOSE: c_int = 1 << 25;

/// A block with no captures that calls `invoke` (its first parameter is the
/// block itself). For completion handlers whose state lives elsewhere; the
/// runtime treats global blocks as immortal, so it may be passed and copied
/// freely. `invoke` must be a comptime-known `callconv(.c)` function.
pub fn globalBlock(comptime invoke: anytype) id {
    const S = struct {
        const descriptor: BlockDescriptor = .{ .reserved = 0, .size = @sizeOf(BlockLiteral) };
        var literal: BlockLiteral = .{
            .isa = null,
            .flags = BLOCK_IS_GLOBAL,
            .reserved = 0,
            .invoke = @ptrCast(&invoke),
            .descriptor = &descriptor,
        };
    };
    S.literal.isa = @ptrCast(&_NSConcreteGlobalBlock);
    return @ptrCast(&S.literal);
}

extern var _NSConcreteStackBlock: [32]usize;

/// A block carrying one context pointer: `invoke` receives the block first
/// (`*ContextBlock`, read `.ctx`), then the block's arguments. Build it as a
/// local and pass `ptr()`: callees that keep it copy it (a plain memcpy, the
/// context is a raw pointer the caller owns and frees in `invoke`).
pub const ContextBlock = extern struct {
    lit: BlockLiteral,
    ctx: ?*anyopaque,

    pub fn ptr(self: *ContextBlock) id {
        return @ptrCast(self);
    }
};

pub fn contextBlock(comptime invoke: anytype, ctx: ?*anyopaque) ContextBlock {
    const S = struct {
        const descriptor: BlockDescriptor = .{ .reserved = 0, .size = @sizeOf(ContextBlock) };
    };
    return .{
        .lit = .{
            .isa = @ptrCast(&_NSConcreteStackBlock),
            .flags = 0,
            .reserved = 0,
            .invoke = @ptrCast(&invoke),
            .descriptor = &S.descriptor,
        },
        .ctx = ctx,
    };
}

/// The context is heap-owned by the block: the runtime calls `copyHelper`
/// (receiver, source) for every copy `_Block_copy` makes and
/// `disposeHelper` (source) when a copy's final release runs. The helpers
/// own the refcounting/teardown, so what lives-on is exactly live copies
/// and the invoke path only needs shared, guarded state.
pub const ManagedBlock = extern struct {
    lit: BlockLiteral,
    ctx: ?*anyopaque,

    pub fn ptr(self: *ManagedBlock) id {
        return @ptrCast(self);
    }
};

pub fn managedBlock(
    comptime invoke: anytype,
    ctx: ?*anyopaque,
    comptime copyHelper: fn (*BlockLiteral, *BlockLiteral) callconv(.c) void,
    comptime disposeHelper: fn (*BlockLiteral) callconv(.c) void,
) ManagedBlock {
    const S = struct {
        const descriptor: BlockDescriptor = .{
            .reserved = 0,
            .size = @sizeOf(ManagedBlock),
            .copy = @ptrCast(&copyHelper),
            .dispose = @ptrCast(&disposeHelper),
        };
    };
    return .{
        .lit = .{
            .isa = @ptrCast(&_NSConcreteStackBlock),
            .flags = BLOCK_HAS_COPY_DISPOSE,
            .reserved = 0,
            .invoke = @ptrCast(&invoke),
            .descriptor = &S.descriptor,
        },
        .ctx = ctx,
    };
}

// Layout agreement with clang's ABI: the runtime memcpy's block literals
// and reads the descriptor fields above; assert the sizes/alignment are
// the expected ones whenever anything is changed here.
comptime {
    if (@sizeOf(BlockLiteral) != @sizeOf(usize) * 3 + @sizeOf(c_int) * 2) @compileError("BlockLiteral layout");
    if (@sizeOf(ManagedBlock) != @sizeOf(BlockLiteral) + @sizeOf(?*anyopaque)) @compileError("ManagedBlock layout");
}

/// Call a block received as an `id` with `args`, of the types `params`
/// (its parameters after the implicit block pointer).
pub fn callBlock(block: id, comptime params: []const type, args: @Tuple(params)) void {
    const lit: *BlockLiteral = @ptrCast(@alignCast(block.?));
    const Fn = comptime blk: {
        var types: [params.len + 1]type = undefined;
        types[0] = *BlockLiteral;
        for (params, 0..) |p, i| types[i + 1] = p;
        break :blk @Fn(&types, &@splat(.{}), void, .{ .@"callconv" = .c });
    };
    const f: *const Fn = @ptrCast(@alignCast(lit.invoke));
    @call(.auto, f, .{lit} ++ args);
}

pub fn copyBlock(block: id) id {
    return @ptrCast(@alignCast(_Block_copy(block)));
}

pub fn releaseBlock(block: id) void {
    _Block_release(block);
}

test {
    std.testing.refAllDecls(@This());
}
