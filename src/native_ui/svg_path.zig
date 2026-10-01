//! SVG path data (`<path d="...">`) for backends without a parser of their
//! own (Win32; GTK has GskPath, Android PathParser). Commands come out in
//! absolute coordinates, with H/V turned into lines and S/T's reflected
//! control points resolved, so a backend only maps six calls onto its
//! geometry API.

const std = @import("std");

/// `sink` has: move(x, y), line(x, y), cubic(x1, y1, x2, y2, x, y),
/// quad(x1, y1, x, y), arc(rx, ry, rotation_deg, large, sweep, x, y),
/// close(). Parsing stops at the first malformed command (as browsers do,
/// everything before it is drawn).
pub fn parse(d: []const u8, sink: anytype) void {
    var p: Parser = .{ .s = d };
    var cmd: u8 = 0;
    var x: f32 = 0;
    var y: f32 = 0;
    var start_x: f32 = 0;
    var start_y: f32 = 0;
    // The last control point, for S and T.
    var cx: f32 = 0;
    var cy: f32 = 0;
    var last: u8 = 0;
    while (true) {
        p.skipSpace();
        if (p.i >= p.s.len) return;
        const ch = p.s[p.i];
        if (std.ascii.isAlphabetic(ch)) {
            cmd = ch;
            p.i += 1;
        } else if (cmd == 0) {
            return; // numbers before any command
        } else if (cmd == 'M') {
            cmd = 'L'; // more pairs after a moveto are linetos
        } else if (cmd == 'm') {
            cmd = 'l';
        } else if (cmd == 'Z' or cmd == 'z') {
            return;
        }
        const rel = std.ascii.isLower(cmd);
        const ox: f32 = if (rel) x else 0;
        const oy: f32 = if (rel) y else 0;
        switch (std.ascii.toUpper(cmd)) {
            'M' => {
                x = ox + (p.num() orelse return);
                y = oy + (p.num() orelse return);
                start_x = x;
                start_y = y;
                sink.move(x, y);
            },
            'L' => {
                x = ox + (p.num() orelse return);
                y = oy + (p.num() orelse return);
                sink.line(x, y);
            },
            'H' => {
                x = ox + (p.num() orelse return);
                sink.line(x, y);
            },
            'V' => {
                y = oy + (p.num() orelse return);
                sink.line(x, y);
            },
            'C' => {
                const x1 = ox + (p.num() orelse return);
                const y1 = oy + (p.num() orelse return);
                const x2 = ox + (p.num() orelse return);
                const y2 = oy + (p.num() orelse return);
                x = ox + (p.num() orelse return);
                y = oy + (p.num() orelse return);
                sink.cubic(x1, y1, x2, y2, x, y);
                cx = x2;
                cy = y2;
            },
            'S' => {
                const reflect = last == 'C' or last == 'S';
                const x1 = if (reflect) 2 * x - cx else x;
                const y1 = if (reflect) 2 * y - cy else y;
                const x2 = ox + (p.num() orelse return);
                const y2 = oy + (p.num() orelse return);
                x = ox + (p.num() orelse return);
                y = oy + (p.num() orelse return);
                sink.cubic(x1, y1, x2, y2, x, y);
                cx = x2;
                cy = y2;
            },
            'Q' => {
                const x1 = ox + (p.num() orelse return);
                const y1 = oy + (p.num() orelse return);
                x = ox + (p.num() orelse return);
                y = oy + (p.num() orelse return);
                sink.quad(x1, y1, x, y);
                cx = x1;
                cy = y1;
            },
            'T' => {
                const reflect = last == 'Q' or last == 'T';
                const x1 = if (reflect) 2 * x - cx else x;
                const y1 = if (reflect) 2 * y - cy else y;
                x = ox + (p.num() orelse return);
                y = oy + (p.num() orelse return);
                sink.quad(x1, y1, x, y);
                cx = x1;
                cy = y1;
            },
            'A' => {
                const rx = p.num() orelse return;
                const ry = p.num() orelse return;
                const rot = p.num() orelse return;
                const large = p.flag() orelse return;
                const sweep = p.flag() orelse return;
                x = ox + (p.num() orelse return);
                y = oy + (p.num() orelse return);
                sink.arc(@abs(rx), @abs(ry), rot, large, sweep, x, y);
            },
            'Z' => {
                sink.close();
                x = start_x;
                y = start_y;
            },
            else => return,
        }
        last = std.ascii.toUpper(cmd);
    }
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn skipSpace(p: *Parser) void {
        while (p.i < p.s.len and (std.ascii.isWhitespace(p.s[p.i]) or p.s[p.i] == ',')) p.i += 1;
    }

    /// A number: "-1.5", ".5", "1e-3"; "1.5.5" is two numbers and "1-2" too.
    fn num(p: *Parser) ?f32 {
        p.skipSpace();
        const start = p.i;
        if (p.i < p.s.len and (p.s[p.i] == '-' or p.s[p.i] == '+')) p.i += 1;
        var digits = false;
        var dot = false;
        while (p.i < p.s.len) : (p.i += 1) {
            const c = p.s[p.i];
            if (std.ascii.isDigit(c)) {
                digits = true;
            } else if (c == '.' and !dot) {
                dot = true;
            } else break;
        }
        if (!digits) {
            p.i = start;
            return null;
        }
        if (p.i < p.s.len and (p.s[p.i] == 'e' or p.s[p.i] == 'E')) {
            const save = p.i;
            p.i += 1;
            if (p.i < p.s.len and (p.s[p.i] == '-' or p.s[p.i] == '+')) p.i += 1;
            if (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) {
                while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
            } else p.i = save;
        }
        return std.fmt.parseFloat(f32, p.s[start..p.i]) catch null;
    }

    /// An arc flag: a single 0 or 1, which may run into the next number
    /// ("a1 1 0 011 1": large 0, sweep 1, then 1 1).
    fn flag(p: *Parser) ?bool {
        p.skipSpace();
        if (p.i >= p.s.len) return null;
        const c = p.s[p.i];
        if (c != '0' and c != '1') return null;
        p.i += 1;
        return c == '1';
    }
};

const Recorder = struct {
    out: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,

    fn put(r: *Recorder, comptime fmt: []const u8, args: anytype) void {
        r.out.print(r.a, fmt, args) catch {};
    }
    fn move(r: *Recorder, x: f32, y: f32) void {
        r.put("M{d} {d} ", .{ x, y });
    }
    fn line(r: *Recorder, x: f32, y: f32) void {
        r.put("L{d} {d} ", .{ x, y });
    }
    fn cubic(r: *Recorder, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) void {
        r.put("C{d} {d} {d} {d} {d} {d} ", .{ x1, y1, x2, y2, x, y });
    }
    fn quad(r: *Recorder, x1: f32, y1: f32, x: f32, y: f32) void {
        r.put("Q{d} {d} {d} {d} ", .{ x1, y1, x, y });
    }
    fn arc(r: *Recorder, rx: f32, ry: f32, rot: f32, large: bool, sweep: bool, x: f32, y: f32) void {
        r.put("A{d} {d} {d} {d} {d} {d} {d} ", .{ rx, ry, rot, @intFromBool(large), @intFromBool(sweep), x, y });
    }
    fn close(r: *Recorder) void {
        r.put("Z ", .{});
    }
};

fn expectPath(d: []const u8, want: []const u8) !void {
    var r: Recorder = .{ .a = std.testing.allocator };
    defer r.out.deinit(std.testing.allocator);
    parse(d, &r);
    try std.testing.expectEqualStrings(want, std.mem.trimEnd(u8, r.out.items, " "));
}

test "absolute and relative commands, implicit linetos" {
    try expectPath("M10 10 L20 10 L20 20 Z", "M10 10 L20 10 L20 20 Z");
    try expectPath("m10,10 10,0 0,10z", "M10 10 L20 10 L20 20 Z");
    try expectPath("M5 5h10v10H5V5", "M5 5 L15 5 L15 15 L5 15 L5 5");
}

test "compact numbers" {
    try expectPath("M1.5.5L-1-2", "M1.5 0.5 L-1 -2");
    try expectPath("M1e1 2E-1", "M10 0.2");
}

test "curves: S and T reflect the last control point" {
    try expectPath("M0 0C1 2 3 4 5 6S9 10 11 12", "M0 0 C1 2 3 4 5 6 C7 8 9 10 11 12");
    try expectPath("M0 0Q2 2 4 0T8 0", "M0 0 Q2 2 4 0 Q6 -2 8 0");
    // S without a previous C: the first control point is the current point.
    try expectPath("M1 1S3 3 5 5", "M1 1 C1 1 3 3 5 5");
}

test "arcs with run-together flags" {
    try expectPath("M10 10a5 5 0 011 1", "M10 10 A5 5 0 0 1 11 11");
    try expectPath("M0 0A2,3 45 1,0 4,4", "M0 0 A2 3 45 1 0 4 4");
}

test "close returns to the subpath's start; malformed input stops" {
    try expectPath("M2 2l3 0zl0 3", "M2 2 L5 2 Z L2 5");
    try expectPath("M0 0L1", "M0 0");
    try expectPath("5 5", "");
}
