//! The single-instance mutex (Shell.zig): a launch that finds it already
//! exists hands its arguments to the running instance and quits.

const win32 = @import("win32.zig");

/// Held by the running instance; null when the app isn't single-instance.
pub var mutex: ?win32.HANDLE = null;

/// Stop being the single instance, for the updater's restart: the new
/// process starts while this one is still exiting (which can take a second,
/// e.g. unloading a GPU driver), and would otherwise find the mutex, hand
/// its launch to this dying process and quit, leaving the app not running.
pub fn release() void {
    if (mutex) |m| _ = win32.CloseHandle(m);
    mutex = null;
}
