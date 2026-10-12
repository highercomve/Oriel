//! App extensions (`oriel.extensions`): an app's own native code, named in
//! build.zig (`AppOptions.extensions`) and implemented per platform in
//! Kotlin (Android), Objective-C or Swift (iOS and macOS), or Zig. Zig calls
//! them by name; the page reaches them only through Zig, via an app command
//! or `expose` (docs/extensions.md). The runtime is extensions/runtime.zig.

const runtime = @import("extensions/runtime.zig");

pub const max_extensions = runtime.max_extensions;
pub const default_max_bytes = runtime.default_max_bytes;
pub const max_concurrency = runtime.max_concurrency;
pub const queue_capacity = runtime.queue_capacity;
pub const default_timeout_ms = runtime.default_timeout_ms;
pub const max_timeout_ms = runtime.max_timeout_ms;

pub const Error = runtime.Error;
pub const CancelToken = runtime.CancelToken;
pub const CallOptions = runtime.CallOptions;
pub const Diagnostics = runtime.Diagnostics;
pub const Context = runtime.Context;
pub const Event = runtime.Event;
pub const EventHandler = runtime.EventHandler;
pub const Expose = runtime.Expose;
pub const PageRequest = runtime.PageRequest;
pub const Filter = runtime.Filter;

/// Extensions this app declares (with Oriel's own).
pub const count = runtime.count;
pub const declared = runtime.declared;
pub const get = runtime.get;
pub const expose = runtime.expose;

test {
    @import("std").testing.refAllDecls(runtime);
}
