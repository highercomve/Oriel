//! macOS: TCC, the system's privacy database.
//!
//! - microphone / camera: AVCaptureDevice authorization; `request` shows
//!   the system prompt (the Info.plist usage key must exist, which
//!   `permissions.request` guarantees by only asking for declared kinds).
//! - screen_capture: CGPreflightScreenCaptureAccess /
//!   CGRequestScreenCaptureAccess. macOS can't tell "not asked yet" from
//!   "denied" here, so a missing grant reads as `prompt`.
//! - accessibility: AXIsProcessTrusted; `request` shows the system prompt
//!   (AXIsProcessTrustedWithOptions) and, as macOS gives no callback, polls
//!   for up to two minutes while the user finds the switch in Settings.
//! - notifications: UNUserNotificationCenter (a bundled app only: without a
//!   bundle identifier it raises an exception; unbundled apps notify through
//!   osascript, so the status is `unknown`).
//! - bluetooth: CBManager.authorization; `request` asks through a
//!   CBCentralManager (bluetooth_apple.zig).
//! - location, system_audio: no public status API: `unknown` (the first use
//!   asks).
//!
//! TCC charges a permission to the *responsible* app: an unbundled binary
//! started from a terminal gets the terminal's permissions. Test prompts
//! from the `.app` (`open zig-out/<Name>.app`).

const std = @import("std");
const internal = @import("../internal.zig");
const common = @import("common.zig");
const apple = @import("../../platform/apple/apple.zig");
const bluetooth = @import("bluetooth_apple.zig").Bluetooth;

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

// CoreGraphics / ApplicationServices
extern "c" fn CGPreflightScreenCaptureAccess() bool;
extern "c" fn CGRequestScreenCaptureAccess() bool;
extern "c" fn AXIsProcessTrusted() u8;
extern "c" fn AXIsProcessTrustedWithOptions(options: ?*anyopaque) u8;
extern const kAXTrustedCheckOptionPrompt: apple.id;

// libdispatch
extern "c" fn dispatch_semaphore_create(value: isize) ?*anyopaque;
extern "c" fn dispatch_semaphore_wait(sem: *anyopaque, timeout: u64) isize;
extern "c" fn dispatch_semaphore_signal(sem: *anyopaque) isize;
extern "c" fn dispatch_release(obj: *anyopaque) void;
extern "c" fn dispatch_time(when: u64, delta: i64) u64;
const DISPATCH_TIME_NOW: u64 = 0;

// UNAuthorizationStatus
const UNAuthorizationStatusNotDetermined: isize = 0;
const UNAuthorizationStatusDenied: isize = 1;
const UNAuthorizationStatusAuthorized: isize = 2;
const UNAuthorizationStatusProvisional: isize = 3;
const UNAuthorizationStatusEphemeral: isize = 4;

pub fn status(kind: Kind) Status {
    // Callers may be off the run loop (tests, `oriel check`).
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    return switch (kind) {
        .microphone => captureStatus(AVMediaTypeAudio),
        .camera => captureStatus(AVMediaTypeVideo),
        .screen_capture => if (CGPreflightScreenCaptureAccess()) .granted else .prompt,
        .accessibility => if (AXIsProcessTrusted() != 0) .granted else .prompt,
        .notifications => notificationStatus(),
        .bluetooth => bluetooth.status(),
        // The local network has no status API here yet: the first use asks.
        .location, .system_audio, .local_network => .unknown,
    };
}

pub fn request(kind: Kind, done: Done) void {
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    switch (kind) {
        .microphone => requestCapture(.microphone, AVMediaTypeAudio, done),
        .camera => requestCapture(.camera, AVMediaTypeVideo, done),
        .screen_capture => {
            // Shows the system alert pointing to Settings the first time and
            // returns at once; the grant takes effect after the app restarts,
            // so a missing one is still `prompt` (as `status` says).
            done(kind, if (CGRequestScreenCaptureAccess()) .granted else .prompt);
        },
        .accessibility => requestAccessibility(done),
        .notifications => requestNotifications(done),
        .bluetooth => bluetooth.request(done),
        .location, .system_audio, .local_network => done(kind, .unknown),
    }
}

/// The Privacy & Security pane for `kind` in System Settings.
pub fn openSettings(kind: Kind) bool {
    const url = settingsUrl(kind) orelse return false;
    @import("../App.zig").openExternal(url); // honors App.open_external_hook (tests)
    return true;
}

pub fn settingsUrl(kind: Kind) ?[:0]const u8 {
    const privacy = "x-apple.systempreferences:com.apple.preference.security?Privacy_";
    return switch (kind) {
        .microphone => privacy ++ "Microphone",
        .camera => privacy ++ "Camera",
        // "Screen & System Audio Recording" holds both on macOS 14.4+.
        .screen_capture, .system_audio => privacy ++ "ScreenCapture",
        .accessibility => privacy ++ "Accessibility",
        .location => privacy ++ "LocationServices",
        .notifications => "x-apple.systempreferences:com.apple.preference.notifications",
        .bluetooth => privacy ++ "Bluetooth",
        .local_network => privacy ++ "LocalNetwork",
    };
}

// --- Camera and microphone -----------------------------------------------------

fn captureStatus(media_type: apple.id) Status {
    const device = apple.class("AVCaptureDevice");
    const s = device.msgSend(isize, "authorizationStatusForMediaType:", .{media_type});
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

// --- Accessibility ----------------------------------------------------------------

var ax_polling = std.atomic.Value(bool).init(false);

fn requestAccessibility(done: Done) void {
    const dict = apple.class("NSDictionary").msgSend(Object, "dictionaryWithObject:forKey:", .{
        apple.class("NSNumber").msgSend(Object, "numberWithBool:", .{apple.boolean(true)}),
        Object{ .value = kAXTrustedCheckOptionPrompt },
    });
    if (AXIsProcessTrustedWithOptions(dict.value) != 0) return done(.accessibility, .granted);
    // No callback when the user flips the switch: poll (one poller at a time).
    if (ax_polling.swap(true, .acq_rel)) return;
    const thread = std.Thread.spawn(.{}, pollAccessibility, .{done}) catch {
        ax_polling.store(false, .release);
        return done(.accessibility, .prompt);
    };
    thread.detach();
}

fn pollAccessibility(done: Done) void {
    var i: usize = 0;
    const result: Status = while (i < 240) : (i += 1) { // 2 minutes
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 500 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, &ts);
        if (AXIsProcessTrusted() != 0) break .granted;
    } else .prompt;
    // Cleared first, so a request made while `done` runs starts a new poll.
    ax_polling.store(false, .release);
    done(.accessibility, result);
}

// --- Notifications ------------------------------------------------------------------

const bundled = apple.bundled;

fn notificationCenter() ?Object {
    if (!bundled()) return null;
    const center = apple.class("UNUserNotificationCenter").msgSend(Object, "currentNotificationCenter", .{});
    return if (center.value == null) null else center;
}

/// The settings query is asynchronous; `status` waits for it (it completes
/// on a private UN queue, never the main one, so waiting on the main thread
/// can't deadlock; a stalled usernotificationsd makes it `unknown` after 2 s). The state
/// is shared with the block and freed by whichever side finishes last.
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
    const center = notificationCenter() orelse return .unknown;
    const q = std.heap.smp_allocator.create(SettingsQuery) catch return .unknown;
    q.* = .{ .sem = dispatch_semaphore_create(0) orelse {
        std.heap.smp_allocator.destroy(q);
        return .unknown;
    } };
    var block = apple.contextBlock(onSettings, q);
    center.msgSend(void, "getNotificationSettingsWithCompletionHandler:", .{block.ptr()});
    const timed_out = dispatch_semaphore_wait(q.sem, dispatch_time(DISPATCH_TIME_NOW, 2 * std.time.ns_per_s)) != 0;
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
    const center = notificationCenter() orelse return done(.notifications, .unknown);
    const UNAuthorizationOptionSound: c_ulong = 1 << 1;
    const UNAuthorizationOptionAlert: c_ulong = 1 << 2;
    var block = apple.contextBlock(onAuthorization, @ptrCast(@constCast(done)));
    center.msgSend(void, "requestAuthorizationWithOptions:completionHandler:", .{ UNAuthorizationOptionAlert | UNAuthorizationOptionSound, block.ptr() });
}

test settingsUrl {
    try std.testing.expectEqualStrings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone", settingsUrl(.microphone).?);
    for (std.enums.values(Kind)) |k| try std.testing.expect(settingsUrl(k) != null);
}

test "status answers for every kind without prompting" {
    // Unbundled test binary: notifications are `unknown`, the rest answer.
    for (std.enums.values(Kind)) |k| _ = status(k);
    try std.testing.expectEqual(Status.unknown, status(.notifications));
}
