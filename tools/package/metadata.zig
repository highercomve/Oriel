//! Architecture mappings and package metadata utilities.

const std = @import("std");

/// Map CPU architecture to Debian architecture name.
pub fn targetToDebArch(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .arm, .armeb => "armhf",
        .riscv64 => "riscv64",
        .x86 => "i386",
        else => @tagName(arch),
    };
}

/// Map CPU architecture to RPM architecture name.
pub fn targetToRpmArch(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm, .armeb => "armhfp",
        .riscv64 => "riscv64",
        .x86 => "i686",
        else => @tagName(arch),
    };
}

/// Map CPU architecture to AppImage architecture suffix.
pub fn targetToAppImageArch(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm, .armeb => "armhf",
        .riscv64 => "riscv64",
        .x86 => "i686",
        else => @tagName(arch),
    };
}

test "targetToArch mappings" {
    const testing = std.testing;

    try testing.expectEqualStrings("amd64", targetToDebArch(.x86_64));
    try testing.expectEqualStrings("arm64", targetToDebArch(.aarch64));
    try testing.expectEqualStrings("armhf", targetToDebArch(.arm));
    try testing.expectEqualStrings("riscv64", targetToDebArch(.riscv64));
    try testing.expectEqualStrings("i386", targetToDebArch(.x86));

    try testing.expectEqualStrings("x86_64", targetToRpmArch(.x86_64));
    try testing.expectEqualStrings("aarch64", targetToRpmArch(.aarch64));
    try testing.expectEqualStrings("armhfp", targetToRpmArch(.arm));
    try testing.expectEqualStrings("riscv64", targetToRpmArch(.riscv64));
    try testing.expectEqualStrings("i686", targetToRpmArch(.x86));

    try testing.expectEqualStrings("x86_64", targetToAppImageArch(.x86_64));
    try testing.expectEqualStrings("aarch64", targetToAppImageArch(.aarch64));
    try testing.expectEqualStrings("armhf", targetToAppImageArch(.arm));
    try testing.expectEqualStrings("riscv64", targetToAppImageArch(.riscv64));
    try testing.expectEqualStrings("i686", targetToAppImageArch(.x86));
}
