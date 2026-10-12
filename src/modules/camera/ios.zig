//! iOS: UIImagePickerController for `.camera`, PHPickerViewController for
//! `.library` (no photo library permission needed: the picker runs out of
//! process and hands over only what the user picks).
//!
//! - `.camera` is error.Unsupported where there is no camera (the
//!   simulator), and error.PermissionDenied without an
//!   NSCameraUsageDescription (`.permissions.camera` in build.zig) or when
//!   the user refused camera access; a first use shows the system prompt.
//! - The picker is presented over the window in front; the delegate hands
//!   the photo (a UIImage, retained) to the waiting thread, which scales
//!   and encodes it with UIGraphicsImageRenderer (orientation applied).
//!
//! Waiting would freeze the main thread: call it from an async command (a
//! worker thread). On the main thread it returns error.MainThread.

const std = @import("std");
const apple = @import("../../platform/ios/apple.zig");
const ShellMod = @import("../../platform/ios/Shell.zig");
const window = @import("../../platform/ios/window.zig");
const permissions_ios = @import("../../core/permissions/ios.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

const Object = apple.Object;
const log = std.log.scoped(.camera);

/// UIImagePickerControllerSourceTypeCamera.
const source_type_camera: c_long = 1;
/// The photo's key in the camera's info dictionary (the value of
/// UIImagePickerControllerOriginalImage).
const original_image_key = "UIImagePickerControllerOriginalImage";

/// One capture at a time (the pickers are modal anyway).
var busy: std.atomic.Value(bool) = .init(false);

const Outcome = enum { pending, image, cancelled, failed };

var result_mutex: std.c.pthread_mutex_t = .{};
var result_cond: std.c.pthread_cond_t = .{};
var outcome: Outcome = .pending;
/// The photo (+1), taken by the waiting thread.
var result_image: Object = apple.nil;

var camera_delegate: Object = apple.nil; // main thread; lives for the process
var library_delegate: Object = apple.nil;
var picker: Object = apple.nil; // the picker on screen (+1)

/// Hand the waiting thread its answer (`image` +1 or nil); once per capture.
fn finish(o: Outcome, image: Object) void {
    _ = std.c.pthread_mutex_lock(&result_mutex);
    defer _ = std.c.pthread_mutex_unlock(&result_mutex);
    if (outcome != .pending) {
        if (image.value != null) image.release(); // a late or duplicate answer
        return;
    }
    outcome = o;
    result_image = image;
    _ = std.c.pthread_cond_broadcast(&result_cond);
}

/// Dismiss and drop the picker on screen (main thread).
fn dismiss() void {
    if (picker.value == null) return;
    picker.msgSend(void, "dismissViewControllerAnimated:completion:", .{ apple.boolean(true), @as(apple.id, null) });
    picker.release();
    picker = apple.nil;
}

// --- UIImagePickerControllerDelegate (camera) ---------------------------------

fn didFinishPicking(_: apple.id, _: apple.c.SEL, _: apple.id, info: apple.id) callconv(.c) void {
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    dismiss();
    const dict: Object = .{ .value = info };
    const key = apple.nsString(original_image_key) orelse return finish(.failed, apple.nil);
    defer key.release();
    const image = if (dict.value == null) apple.nil else dict.msgSend(Object, "objectForKey:", .{key});
    if (image.value == null) return finish(.failed, apple.nil);
    finish(.image, image.retain());
}

fn didCancel(_: apple.id, _: apple.c.SEL, _: apple.id) callconv(.c) void {
    dismiss();
    finish(.cancelled, apple.nil);
}

// --- PHPickerViewControllerDelegate (library) ---------------------------------

fn pickerDidFinish(_: apple.id, _: apple.c.SEL, _: apple.id, results: apple.id) callconv(.c) void {
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    dismiss();
    const list: Object = .{ .value = results };
    if (list.value == null or list.msgSend(c_ulong, "count", .{}) == 0) return finish(.cancelled, apple.nil);
    const provider = list.msgSend(Object, "objectAtIndex:", .{@as(c_ulong, 0)}).msgSend(Object, "itemProvider", .{});
    const ui_image = apple.class("UIImage");
    if (provider.value == null or !apple.isTrue(provider.msgSend(apple.c.BOOL, "canLoadObjectOfClass:", .{ui_image.value}))) {
        return finish(.failed, apple.nil);
    }
    // The handler runs on a background queue, after this returns: the
    // provider copies the block (a plain copy: it captures nothing).
    var block = apple.contextBlock(loaded, null);
    _ = provider.msgSend(Object, "loadObjectOfClass:completionHandler:", .{ ui_image.value, block.ptr() });
}

fn loaded(_: *apple.ContextBlock, object: apple.id, err: apple.id) callconv(.c) void {
    if (object == null) {
        if (err != null) log.warn("the picked photo could not be loaded", .{});
        return finish(.failed, apple.nil);
    }
    finish(.image, (Object{ .value = object }).retain());
}

// --- Presenting ----------------------------------------------------------------

const Show = struct {
    source: common.Source,
    err: ?common.Error = null,

    fn run(self: *Show) void {
        const pool = apple.objc.AutoreleasePool.init();
        defer pool.deinit();
        const front = window.frontController() orelse {
            self.err = error.CaptureFailed;
            return;
        };
        const p = switch (self.source) {
            .camera => cameraPicker() catch |e| {
                self.err = e;
                return;
            },
            .library => libraryPicker() catch |e| {
                self.err = e;
                return;
            },
        };
        picker = p;
        front.msgSend(void, "presentViewController:animated:completion:", .{ p, apple.boolean(true), @as(apple.id, null) });
    }

    fn cameraPicker() common.Error!Object {
        const cls = apple.class("UIImagePickerController");
        if (!apple.isTrue(cls.msgSend(apple.c.BOOL, "isSourceTypeAvailable:", .{source_type_camera}))) return error.Unsupported;
        if (camera_delegate.value == null) camera_delegate = apple.new(apple.defineClass("OrielImagePickerDelegate", &.{ "UIImagePickerControllerDelegate", "UINavigationControllerDelegate" }, .{
            .{ "imagePickerController:didFinishPickingMediaWithInfo:", didFinishPicking },
            .{ "imagePickerControllerDidCancel:", didCancel },
        }));
        const p = apple.new(cls);
        if (p.value == null) return error.CaptureFailed;
        p.msgSend(void, "setSourceType:", .{source_type_camera});
        p.msgSend(void, "setDelegate:", .{camera_delegate});
        return p;
    }

    fn libraryPicker() common.Error!Object {
        // PhotosUI (iOS 14+), linked when the module is on.
        const config_cls = apple.objc.getClass("PHPickerConfiguration") orelse return error.Unsupported;
        const picker_cls = apple.objc.getClass("PHPickerViewController") orelse return error.Unsupported;
        const filter_cls = apple.objc.getClass("PHPickerFilter") orelse return error.Unsupported;
        if (library_delegate.value == null) library_delegate = apple.new(apple.defineClass("OrielPhotoPickerDelegate", &.{"PHPickerViewControllerDelegate"}, .{
            .{ "picker:didFinishPicking:", pickerDidFinish },
        }));
        const config = apple.new(config_cls);
        if (config.value == null) return error.CaptureFailed;
        defer config.release();
        config.msgSend(void, "setFilter:", .{filter_cls.msgSend(Object, "imagesFilter", .{})});
        config.msgSend(void, "setSelectionLimit:", .{@as(c_long, 1)});
        const p = picker_cls.msgSend(Object, "alloc", .{}).msgSend(Object, "initWithConfiguration:", .{config});
        if (p.value == null) return error.CaptureFailed;
        p.msgSend(void, "setDelegate:", .{library_delegate});
        return p;
    }
};

/// Whether the bundle has the camera's usage text (UIImagePickerController
/// ends the app without it).
fn hasCameraUsage() bool {
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    const key = apple.nsString("NSCameraUsageDescription") orelse return false;
    defer key.release();
    const bundle = apple.class("NSBundle").msgSend(Object, "mainBundle", .{});
    return bundle.msgSend(Object, "objectForInfoDictionaryKey:", .{key}).value != null;
}

pub fn capturePhoto(io: std.Io, arena: std.mem.Allocator, options: common.Options) common.Error!common.Photo {
    _ = io;
    if (apple.isMainThread()) return error.MainThread;
    if (options.source == .camera) {
        if (!hasCameraUsage()) {
            log.warn("capturePhoto(.camera): the app declares no .permissions.camera (NSCameraUsageDescription)", .{});
            return error.PermissionDenied;
        }
        if (permissions_ios.status(.camera) == .denied) return error.PermissionDenied;
    }
    if (busy.swap(true, .acq_rel)) return error.Busy;
    defer busy.store(false, .release);

    _ = std.c.pthread_mutex_lock(&result_mutex);
    outcome = .pending;
    result_image = apple.nil;
    _ = std.c.pthread_mutex_unlock(&result_mutex);

    var show: Show = .{ .source = options.source };
    ShellMod.runOnMainThread(Show, &show, Show.run) catch return error.CaptureFailed;
    if (show.err) |e| return e;

    _ = std.c.pthread_mutex_lock(&result_mutex);
    while (outcome == .pending) _ = std.c.pthread_cond_wait(&result_cond, &result_mutex);
    const o = outcome;
    const image = result_image;
    result_image = apple.nil;
    _ = std.c.pthread_mutex_unlock(&result_mutex);

    switch (o) {
        .image => {},
        .cancelled => return error.Cancelled,
        .pending, .failed => return error.CaptureFailed,
    }
    defer image.release();
    return encode(arena, image, options);
}

/// The image scaled to fit `max_side` (its own orientation applied) and
/// encoded; any thread (UIGraphicsImageRenderer is thread-safe).
fn encode(arena: std.mem.Allocator, image: Object, options: common.Options) common.Error!common.Photo {
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    const points = image.msgSend(apple.CGSize, "size", .{});
    const scale = image.msgSend(f64, "scale", .{});
    const pw = points.width * @max(scale, 1);
    const ph = points.height * @max(scale, 1);
    if (!(pw >= 1 and ph >= 1 and pw < 1 << 20 and ph < 1 << 20)) return error.CaptureFailed;
    const size = common.fitSize(@intFromFloat(pw), @intFromFloat(ph), options.max_side);

    const format = apple.new(apple.class("UIGraphicsImageRendererFormat"));
    defer format.release();
    format.msgSend(void, "setScale:", .{@as(f64, 1)});
    format.msgSend(void, "setOpaque:", .{apple.boolean(options.format == .jpeg)});
    const target: apple.CGSize = .{ .width = @floatFromInt(size.width), .height = @floatFromInt(size.height) };
    const renderer = apple.class("UIGraphicsImageRenderer").msgSend(Object, "alloc", .{})
        .msgSend(Object, "initWithSize:format:", .{ target, format });
    if (renderer.value == null) return error.CaptureFailed;
    defer renderer.release();

    const Draw = struct {
        image: Object,
        rect: apple.CGRect,
        fn invoke(block: *apple.ContextBlock, _: apple.id) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(block.ctx.?));
            self.image.msgSend(void, "drawInRect:", .{self.rect});
        }
    };
    var draw: Draw = .{ .image = image, .rect = .{ .origin = .{ .x = 0, .y = 0 }, .size = target } };
    var block = apple.contextBlock(Draw.invoke, &draw);
    const data = switch (options.format) {
        .jpeg => renderer.msgSend(Object, "JPEGDataWithCompressionQuality:actions:", .{ @as(f64, @floatFromInt(options.quality)) / 100.0, block.ptr() }),
        .png => renderer.msgSend(Object, "PNGDataWithActions:", .{block.ptr()}),
    };
    if (data.value == null) return error.CaptureFailed;
    const len = data.msgSend(c_ulong, "length", .{});
    if (len == 0) return error.CaptureFailed;
    if (len > common.max_bytes) return error.TooLarge;
    const ptr = data.msgSend(?[*]const u8, "bytes", .{}) orelse return error.CaptureFailed;
    return .{
        .bytes = try arena.dupe(u8, ptr[0..len]),
        .width = size.width,
        .height = size.height,
        .mime = options.format.mime(),
    };
}

pub fn check(_: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const library = apple.objc.getClass("PHPickerViewController") != null;
    const camera = apple.isTrue(apple.class("UIImagePickerController").msgSend(apple.c.BOOL, "isSourceTypeAvailable:", .{source_type_camera}));
    return .{
        .module = "camera",
        .ok = library,
        .detail = if (!library) "PHPickerViewController missing (PhotosUI not linked)" else if (camera) "UIImagePickerController (camera), PHPickerViewController (library)" else "PHPickerViewController (library); no camera on this device",
    };
}
