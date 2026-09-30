//! The allocator Oriel's own code uses for its internal state (window
//! registry, IPC and task queues, JNI strings), apart from the app's `gpa`.
//!
//! Desktop: `smp_allocator`. Android: bionic's malloc (`c_allocator`), the
//! process heap that the app's `gpa` (`std.process.Init`), ART, WebView and
//! the NDK already use. A second heap would hold its own slabs and
//! per-thread caches, which it never gives back, while bionic's allocator
//! returns freed pages when Android trims memory.

const std = @import("std");
const target = @import("target.zig");

pub const gpa: std.mem.Allocator = if (target.is_android) std.heap.c_allocator else std.heap.smp_allocator;
