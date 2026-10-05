//! iOS: the system's privacy permissions.
//!
//! - microphone / camera: AVCaptureDevice authorization; `request` shows
//!   the system prompt (the Info.plist usage key must exist, which
//!   `permissions.request` guarantees by only asking for declared kinds).
//! - location: CLLocationManager ("when in use").
//! - notifications: UNUserNotificationCenter.
//! - bluetooth: CBManager.authorization; `request` asks through a
//!   CBCentralManager (bluetooth_apple.zig).
//! - screen_capture, system_audio, accessibility: not available to iOS
//!   apps: `denied`.
//!
//! `openSettings` opens the app's page in Settings (every kind is there).

const std = @import("std");
const common = @import("common.zig");
const apple = @import("../../platform/ios/apple.zig");
const bluetooth = @import("bluetooth_apple.zig").Bluetooth(apple);

const Object = apple.Object;
const Kind = common.Kind;
const Status = common.Status;
const Done = *const fn (Kind, Status) void;

// AVFoundation
extern const AVMediaTypeAudio: apple.id;
extern const AVMediaTypeVideo: apple.id;
const AVAuthorizationStatusNotDetermined: isize = 0;
const AVAuthorizationStatusRestricted: isize = 1;
const AVAuthorizationStatusDenied: isize = 2;
const AVAuthorizationStatusAuthorized: isize = 3;

// CLAuthorizationStatus
const kCLAuthorizationStatusNotDetermined: i32 = 0;
const kCLAuthorizationStatusRestricted: i32 = 1;
const kCLAuthorizationStatusDenied: i32 = 2;
const kCLAuthorizationStatusAuthorizedAlways: i32 = 3;
const kCLAuthorizationStatusAuthorizedWhenInUse: i32 = 4;

// UNAuthorizationStatus
const UNAuthorizationStatusNotDetermined: isize = 0;
const UNAuthorizationStatusDenied: isize = 1;
const UNAuthorizationStatusAuthorized: isize = 2;
const UNAuthorizationStatusProvisional: isize = 3;
const UNAuthorizationStatusEphemeral: isize = 4;

extern "c" fn dispatch_semaphore_create(value: isize) ?*anyopaque;
extern "c" fn dispatch_semaphore_wait(sem: *anyopaque, timeout: u64) isize;
extern "c" fn dispatch_semaphore_signal(sem: *anyopaque) isize;
extern "c" fn dispatch_release(obj: *anyopaque) void;
extern "c" fn dispatch_time(when: u64, delta: i64) u64;

pub fn status(kind: Kind) Status {
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    return switch (kind) {
        .microphone => captureStatus(AVMediaTypeAudio),
        .camera => captureStatus(AVMediaTypeVideo),
        .location => locationStatus(),
        .notifications => notificationStatus(),
        .screen_capture, .system_audio, .accessibility => .denied,
        .bluetooth => bluetooth.status(),
        // No status API wired yet (the local network probe): the first use
        // asks.
        .local_network => .unknown,
    };
}

pub fn request(kind: Kind, done: Done) void {
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    switch (kind) {
        .microphone => requestCapture(.microphone, AVMediaTypeAudio, done),
        .camera => requestCapture(.camera, AVMediaTypeVideo, done),
        .location => requestLocation(done),
        .notifications => requestNotifications(done),
        .screen_capture, .system_audio, .accessibility => done(kind, .denied),
        .bluetooth => bluetooth.request(done),
        .local_network => done(kind, .unknown),
    }
}

/// The app's page in Settings (`UIApplicationOpenSettingsURLString`).
pub fn openSettings(kind: Kind) bool {
    _ = kind;
    @import("../App.zig").openExternal("app-settings:");
    return true;
}

// --- Camera and microphone -----------------------------------------------------

fn captureStatus(media_type: apple.id) Status {
    const s = apple.class("AVCaptureDevice").msgSend(isize, "authorizationStatusForMediaType:", .{media_type});
    return switch (s) {
        AVAuthorizationStatusAuthorized => .granted,
        AVAuthorizationStatusDenied, AVAuthorizationStatusRestricted => .denied,
        AVAuthorizationStatusNotDetermined => .prompt,
        else => .unknown,
    };
}

fn CaptureAccess(comptime kind: Kind) type {
    return struct {
        fn invoke(block: *apple.ContextBlock, granted: apple.c.BOOL) callconv(.c) void {
            const done: Done = @ptrCast(@alignCast(block.ctx.?));
            done(kind, if (apple.isTrue(granted)) .granted else .denied);
        }
    };
}

fn requestCapture(comptime kind: Kind, media_type: apple.id, done: Done) void {
    // Called on an arbitrary queue; AVFoundation copies the (stack) block.
    var block = apple.contextBlock(CaptureAccess(kind).invoke, @ptrCast(@constCast(done)));
    apple.class("AVCaptureDevice").msgSend(void, "requestAccessForMediaType:completionHandler:", .{ media_type, block.ptr() });
}

// --- Location -----------------------------------------------------------------------

fn fromLocation(s: i32) Status {
    return switch (s) {
        kCLAuthorizationStatusAuthorizedAlways, kCLAuthorizationStatusAuthorizedWhenInUse => .granted,
        kCLAuthorizationStatusDenied, kCLAuthorizationStatusRestricted => .denied,
        kCLAuthorizationStatusNotDetermined => .prompt,
        else => .unknown,
    };
}

fn locationStatus() Status {
    return fromLocation(apple.class("CLLocationManager").msgSend(i32, "authorizationStatus", .{}));
}

/// The manager asking (main thread): it must live until the answer.
var location_manager: Object = apple.nil;
var location_done: ?Done = null;
var location_delegate_class: ?apple.Class = null;

fn didChangeAuthorization(_: apple.id, _: apple.c.SEL, manager: apple.id) callconv(.c) void {
    const s = fromLocation((Object{ .value = manager }).msgSend(i32, "authorizationStatus", .{}));
    // The delegate is also told the current status when it is set.
    if (s == .prompt) return;
    const done = location_done orelse return;
    location_done = null;
    done(.location, s);
}

fn requestLocation(done: Done) void {
    const current = locationStatus();
    if (current != .prompt) return done(.location, current);
    const Ctx = struct {
        done: Done,
        fn run(self: *@This()) void {
            if (location_delegate_class == null) location_delegate_class = apple.defineClass("OrielLocationDelegate", &.{"CLLocationManagerDelegate"}, .{
                .{ "locationManagerDidChangeAuthorization:", didChangeAuthorization },
            });
            if (location_manager.value == null) {
                location_manager = apple.new(apple.class("CLLocationManager"));
                // The manager's delegate is weak: the delegate lives for the run.
                location_manager.msgSend(void, "setDelegate:", .{apple.new(location_delegate_class.?)});
            }
            location_done = self.done;
            location_manager.msgSend(void, "requestWhenInUseAuthorization", .{});
        }
    };
    var ctx: Ctx = .{ .done = done };
    const ShellMod = @import("../../platform/ios/Shell.zig");
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch done(.location, .unknown);
}

// --- Notifications ------------------------------------------------------------------

fn notificationCenter() Object {
    return apple.class("UNUserNotificationCenter").msgSend(Object, "currentNotificationCenter", .{});
}

/// The settings query is asynchronous; `status` waits for it (it completes
/// on a private queue, so waiting on the main thread can't deadlock; after
/// 2 s it is `unknown`). The state is shared with the block and freed by
/// whichever side finishes last.
const SettingsQuery = struct {
    sem: *anyopaque,
    result: std.atomic.Value(isize) = .init(-1),
    refs: std.atomic.Value(u8) = .init(2),

    fn release(q: *SettingsQuery) void {
        if (q.refs.fetchSub(1, .acq_rel) == 1) {
            dispatch_release(q.sem);
            std.heap.smp_allocator.destroy(q);
        }
    }
};

fn onSettings(block: *apple.ContextBlock, settings: apple.id) callconv(.c) void {
    const q: *SettingsQuery = @ptrCast(@alignCast(block.ctx.?));
    if (settings != null) q.result.store((Object{ .value = settings }).msgSend(isize, "authorizationStatus", .{}), .release);
    _ = dispatch_semaphore_signal(q.sem);
    q.release();
}

fn notificationStatus() Status {
    const center = notificationCenter();
    if (center.value == null) return .unknown;
    const q = std.heap.smp_allocator.create(SettingsQuery) catch return .unknown;
    q.* = .{ .sem = dispatch_semaphore_create(0) orelse {
        std.heap.smp_allocator.destroy(q);
        return .unknown;
    } };
    var block = apple.contextBlock(onSettings, q);
    center.msgSend(void, "getNotificationSettingsWithCompletionHandler:", .{block.ptr()});
    const timed_out = dispatch_semaphore_wait(q.sem, dispatch_time(0, 2 * std.time.ns_per_s)) != 0;
    const s = q.result.load(.acquire);
    q.release();
    if (timed_out) return .unknown;
    return switch (s) {
        UNAuthorizationStatusAuthorized, UNAuthorizationStatusProvisional, UNAuthorizationStatusEphemeral => .granted,
        UNAuthorizationStatusDenied => .denied,
        UNAuthorizationStatusNotDetermined => .prompt,
        else => .unknown,
    };
}

fn onAuthorization(block: *apple.ContextBlock, granted: apple.c.BOOL, _: apple.id) callconv(.c) void {
    const done: Done = @ptrCast(@alignCast(block.ctx.?));
    done(.notifications, if (apple.isTrue(granted)) .granted else .denied);
}

fn requestNotifications(done: Done) void {
    const center = notificationCenter();
    if (center.value == null) return done(.notifications, .unknown);
    const UNAuthorizationOptionBadge: c_ulong = 1 << 0;
    const UNAuthorizationOptionSound: c_ulong = 1 << 1;
    const UNAuthorizationOptionAlert: c_ulong = 1 << 2;
    var block = apple.contextBlock(onAuthorization, @ptrCast(@constCast(done)));
    center.msgSend(void, "requestAuthorizationWithOptions:completionHandler:", .{ UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge, block.ptr() });
}

test {
    std.testing.refAllDecls(@This());
}
