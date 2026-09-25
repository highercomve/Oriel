//! Project templates for `oriel init`, embedded in the binary so scaffolding
//! works offline, and the `@@key@@` placeholder renderer.

const std = @import("std");

pub const Template = enum {
    react,
    vue,
    svelte,
    vanilla,

    /// Whether the frontend is a Vite project (npm install, dev server).
    pub fn usesVite(t: Template) bool {
        return t != .vanilla;
    }
};

/// A file to write, relative to the project root.
pub const File = struct {
    path: []const u8,
    /// Template text; `@@key@@` placeholders are filled by `render`.
    text: []const u8,
    is_template: bool = true,
};

fn embed(comptime dest: []const u8, comptime src: []const u8) File {
    return .{ .path = dest, .text = @embedFile("templates/" ++ src) };
}

fn embedBinary(comptime dest: []const u8, comptime src: []const u8) File {
    return .{ .path = dest, .text = @embedFile("templates/" ++ src), .is_template = false };
}

const common = [_]File{
    embed("build.zig", "common/build.zig"),
    embed("build.zig.zon", "common/build.zig.zon"),
    embed("src/main.zig", "common/src/main.zig"),
    embedBinary("icon.png", "common/icon.png"),
    embed(".gitignore", "common/.gitignore"),
    embed("README.md", "common/README.md"),
};

const react = common ++ [_]File{
    embed("frontend/.gitignore", "react/.gitignore"),
    embed("frontend/package.json", "react/package.json"),
    embed("frontend/index.html", "react/index.html"),
    embed("frontend/vite.config.ts", "react/vite.config.ts"),
    embed("frontend/tsconfig.json", "react/tsconfig.json"),
    embed("frontend/src/main.tsx", "react/src/main.tsx"),
    embed("frontend/src/App.tsx", "react/src/App.tsx"),
    embed("frontend/src/style.css", "shared/style.css"),
};

const vue = common ++ [_]File{
    embed("frontend/.gitignore", "vue/.gitignore"),
    embed("frontend/package.json", "vue/package.json"),
    embed("frontend/index.html", "vue/index.html"),
    embed("frontend/vite.config.ts", "vue/vite.config.ts"),
    embed("frontend/tsconfig.json", "vue/tsconfig.json"),
    embed("frontend/src/env.d.ts", "vue/src/env.d.ts"),
    embed("frontend/src/main.ts", "vue/src/main.ts"),
    embed("frontend/src/App.vue", "vue/src/App.vue"),
    embed("frontend/src/style.css", "shared/style.css"),
};

const svelte = common ++ [_]File{
    embed("frontend/.gitignore", "svelte/.gitignore"),
    embed("frontend/package.json", "svelte/package.json"),
    embed("frontend/index.html", "svelte/index.html"),
    embed("frontend/vite.config.ts", "svelte/vite.config.ts"),
    embed("frontend/svelte.config.js", "svelte/svelte.config.js"),
    embed("frontend/tsconfig.json", "svelte/tsconfig.json"),
    embed("frontend/src/main.ts", "svelte/src/main.ts"),
    embed("frontend/src/App.svelte", "svelte/src/App.svelte"),
    embed("frontend/src/style.css", "shared/style.css"),
};

const vanilla = common ++ [_]File{
    embed("frontend/index.html", "vanilla/index.html"),
    embed("frontend/app.js", "vanilla/app.js"),
    embed("frontend/style.css", "shared/style.css"),
};

/// Every file of a template.
pub fn files(t: Template) []const File {
    return switch (t) {
        .react => &react,
        .vue => &vue,
        .svelte => &svelte,
        .vanilla => &vanilla,
    };
}

pub const Var = struct { key: []const u8, value: []const u8 };

pub const RenderError = error{ UnknownPlaceholder, UnterminatedPlaceholder } || std.mem.Allocator.Error;

/// Replace every `@@key@@` in `text` with its value from `vars`. Values are
/// inserted verbatim: callers escape them for the target file format.
/// Caller owns the result.
pub fn render(gpa: std.mem.Allocator, text: []const u8, vars: []const Var) RenderError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rest = text;
    while (std.mem.indexOf(u8, rest, "@@")) |start| {
        try out.appendSlice(gpa, rest[0..start]);
        const after = rest[start + 2 ..];
        const len = std.mem.indexOf(u8, after, "@@") orelse return error.UnterminatedPlaceholder;
        const key = after[0..len];
        const value = for (vars) |v| {
            if (std.mem.eql(u8, v.key, key)) break v.value;
        } else return error.UnknownPlaceholder;
        try out.appendSlice(gpa, value);
        rest = after[len + 2 ..];
    }
    try out.appendSlice(gpa, rest);
    return out.toOwnedSlice(gpa);
}

test render {
    const gpa = std.testing.allocator;
    const vars = [_]Var{ .{ .key = "name", .value = "demo" }, .{ .key = "x", .value = "" } };
    const out = try render(gpa, "a @@name@@ b @@x@@@@name@@", &vars);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("a demo b demo", out);
    try std.testing.expectError(error.UnknownPlaceholder, render(gpa, "@@nope@@", &vars));
    try std.testing.expectError(error.UnterminatedPlaceholder, render(gpa, "x @@name", &vars));
}

test "templates share the common files and embed a frontend" {
    for (std.enums.values(Template)) |t| {
        var has_index = false;
        for (files(t)) |f| {
            if (std.mem.eql(u8, f.path, "frontend/index.html")) has_index = true;
            try std.testing.expect(f.text.len > 0);
        }
        try std.testing.expect(has_index);
        try std.testing.expectEqualStrings("build.zig", files(t)[0].path);
    }
}
