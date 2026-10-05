//! Files dropped into a native-renderer page (docs/drag-and-drop-design.md,
//! section 3): one table per engine (`Engine.drops`).
//!
//! The table is core/file_handles.zig, shared with oriel.share's received
//! files: read-only descriptors behind u32 handles, with snapshot checks.

const file_handles = @import("../core/file_handles.zig");

pub const DropFiles = file_handles.FileHandles;
pub const Entry = file_handles.Entry;
pub const Error = file_handles.Error;
pub const max_read = file_handles.max_read;

test {
    _ = file_handles;
}
