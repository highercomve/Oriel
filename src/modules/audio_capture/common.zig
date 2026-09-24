const std = @import("std");

/// An input the user can capture from.
pub const Source = struct {
    /// Stable id to pass to `Stream.open` (the sound server's source name).
    name: [:0]const u8,
    /// Human-readable name, e.g. "Built-in Audio Analog Stereo".
    description: []const u8,
    /// True for system-audio sources (what the speakers play), false for
    /// microphones and other inputs.
    monitor: bool,
};

/// Free a list returned by `listSources`.
pub fn freeSources(gpa: std.mem.Allocator, sources: []Source) void {
    for (sources) |s| {
        gpa.free(s.name);
        gpa.free(s.description);
    }
    gpa.free(sources);
}

test "freeSources frees names and descriptions" {
    const gpa = std.testing.allocator;
    const list = try gpa.alloc(Source, 1);
    list[0] = .{ .name = try gpa.dupeZ(u8, "mic"), .description = try gpa.dupe(u8, "Mic"), .monitor = false };
    freeSources(gpa, list);
}
