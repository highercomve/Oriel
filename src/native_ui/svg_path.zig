//! SVG path data (`<path d="...">`) for backends without a parser of their
//! own (CoreGraphics on macOS and iOS): the commands are resolved to absolute
//! move/line/cubic/quadratic/close calls on a sink, arcs as cubic Béziers.
//!
//! Lenient like browsers: parsing stops at the first error and what was read
//! so far is kept.

const std = @import("std");

/// Where the path goes. `ctx` is passed back to every call.
pub fn Sink(comptime Ctx: type) type {
    return struct {
        ctx: Ctx,
        move: *const fn (Ctx, f64, f64) void,
        line: *const fn (Ctx, f64, f64) void,
        cubic: *const fn (Ctx, f64, f64, f64, f64, f64, f64) void,
        quad: *const fn (Ctx, f64, f64, f64, f64) void,
        close: *const fn (Ctx) void,
    };
}

const Reader = struct {
    s: []const u8,
    i: usize = 0,

    fn skipSep(r: *Reader) void {
        while (r.i < r.s.len) : (r.i += 1) switch (r.s[r.i]) {
            ' ', '\t', '\n', '\r', ',' => {},
            else => return,
        };
    }

    fn atEnd(r: *Reader) bool {
        r.skipSep();
        return r.i >= r.s.len;
    }

    /// The next character starts a number (vs a command letter).
    fn atNumber(r: *Reader) bool {
        r.skipSep();
        if (r.i >= r.s.len) return false;
        const c = r.s[r.i];
        return (c >= '0' and c <= '9') or c == '-' or c == '+' or c == '.';
    }

    fn number(r: *Reader) ?f64 {
        r.skipSep();
        const start = r.i;
        if (r.i < r.s.len and (r.s[r.i] == '-' or r.s[r.i] == '+')) r.i += 1;
        var digits = false;
        while (r.i < r.s.len and std.ascii.isDigit(r.s[r.i])) : (r.i += 1) digits = true;
        if (r.i < r.s.len and r.s[r.i] == '.') {
            r.i += 1;
            while (r.i < r.s.len and std.ascii.isDigit(r.s[r.i])) : (r.i += 1) digits = true;
        }
        if (!digits) {
            r.i = start;
            return null;
        }
        if (r.i < r.s.len and (r.s[r.i] == 'e' or r.s[r.i] == 'E')) {
            const save = r.i;
            r.i += 1;
            if (r.i < r.s.len and (r.s[r.i] == '-' or r.s[r.i] == '+')) r.i += 1;
            var exp_digits = false;
            while (r.i < r.s.len and std.ascii.isDigit(r.s[r.i])) : (r.i += 1) exp_digits = true;
            if (!exp_digits) r.i = save;
        }
        return std.fmt.parseFloat(f64, r.s[start..r.i]) catch null;
    }

    /// An arc flag: a single 0 or 1, possibly not separated ("a1 1 0 01 2 3").
    fn flag(r: *Reader) ?bool {
        r.skipSep();
        if (r.i >= r.s.len) return null;
        const c = r.s[r.i];
        if (c != '0' and c != '1') return null;
        r.i += 1;
        return c == '1';
    }
};

/// Parse `d` into `sink`. Returns false when the data had an error (what came
/// before it was still emitted).
pub fn parse(comptime Ctx: type, d: []const u8, sink: Sink(Ctx)) bool {
    var r: Reader = .{ .s = d };
    var cx: f64 = 0; // current point
    var cy: f64 = 0;
    var sx: f64 = 0; // subpath start
    var sy: f64 = 0;
    // The last control point, for S/s and T/t.
    var last_cubic: ?[2]f64 = null;
    var last_quad: ?[2]f64 = null;
    var cmd: u8 = 0;
    while (!r.atEnd()) {
        if (!r.atNumber()) {
            cmd = r.s[r.i];
            r.i += 1;
        } else if (cmd == 0) {
            return false; // a number before any command
        }
        const rel = std.ascii.isLower(cmd);
        const ox = if (rel) cx else 0;
        const oy = if (rel) cy else 0;
        switch (std.ascii.toUpper(cmd)) {
            'M' => {
                const x = (r.number() orelse return false) + ox;
                const y = (r.number() orelse return false) + oy;
                sink.move(sink.ctx, x, y);
                cx = x;
                cy = y;
                sx = x;
                sy = y;
                // Further pairs after a moveto are linetos.
                cmd = if (rel) 'l' else 'L';
                last_cubic = null;
                last_quad = null;
            },
            'L' => {
                const x = (r.number() orelse return false) + ox;
                const y = (r.number() orelse return false) + oy;
                sink.line(sink.ctx, x, y);
                cx = x;
                cy = y;
                last_cubic = null;
                last_quad = null;
            },
            'H' => {
                const x = (r.number() orelse return false) + ox;
                sink.line(sink.ctx, x, cy);
                cx = x;
                last_cubic = null;
                last_quad = null;
            },
            'V' => {
                const y = (r.number() orelse return false) + oy;
                sink.line(sink.ctx, cx, y);
                cy = y;
                last_cubic = null;
                last_quad = null;
            },
            'C' => {
                var v: [6]f64 = undefined;
                for (&v, 0..) |*x, i| x.* = (r.number() orelse return false) + (if (i % 2 == 0) ox else oy);
                sink.cubic(sink.ctx, v[0], v[1], v[2], v[3], v[4], v[5]);
                last_cubic = .{ v[2], v[3] };
                last_quad = null;
                cx = v[4];
                cy = v[5];
            },
            'S' => {
                var v: [4]f64 = undefined;
                for (&v, 0..) |*x, i| x.* = (r.number() orelse return false) + (if (i % 2 == 0) ox else oy);
                // The first control point mirrors the last one.
                const c1 = if (last_cubic) |lc| [2]f64{ 2 * cx - lc[0], 2 * cy - lc[1] } else [2]f64{ cx, cy };
                sink.cubic(sink.ctx, c1[0], c1[1], v[0], v[1], v[2], v[3]);
                last_cubic = .{ v[0], v[1] };
                last_quad = null;
                cx = v[2];
                cy = v[3];
            },
            'Q' => {
                var v: [4]f64 = undefined;
                for (&v, 0..) |*x, i| x.* = (r.number() orelse return false) + (if (i % 2 == 0) ox else oy);
                sink.quad(sink.ctx, v[0], v[1], v[2], v[3]);
                last_quad = .{ v[0], v[1] };
                last_cubic = null;
                cx = v[2];
                cy = v[3];
            },
            'T' => {
                const x = (r.number() orelse return false) + ox;
                const y = (r.number() orelse return false) + oy;
                const c = if (last_quad) |lq| [2]f64{ 2 * cx - lq[0], 2 * cy - lq[1] } else [2]f64{ cx, cy };
                sink.quad(sink.ctx, c[0], c[1], x, y);
                last_quad = c;
                last_cubic = null;
                cx = x;
                cy = y;
            },
            'A' => {
                const rx = r.number() orelse return false;
                const ry = r.number() orelse return false;
                const rot = r.number() orelse return false;
                const large = r.flag() orelse return false;
                const sweep = r.flag() orelse return false;
                const x = (r.number() orelse return false) + ox;
                const y = (r.number() orelse return false) + oy;
                arc(Ctx, sink, cx, cy, rx, ry, rot, large, sweep, x, y);
                cx = x;
                cy = y;
                last_cubic = null;
                last_quad = null;
            },
            'Z' => {
                sink.close(sink.ctx);
                cx = sx;
                cy = sy;
                last_cubic = null;
                last_quad = null;
                // A number after Z without a command is an error; any command may follow.
                if (r.atNumber()) return false;
            },
            else => return false,
        }
    }
    return true;
}

/// An elliptical arc from (x1, y1) to (x2, y2) (SVG's endpoint form) as
/// cubic Béziers of at most a quarter turn each (SVG 1.1, F.6.5 and F.6.6).
fn arc(comptime Ctx: type, sink: Sink(Ctx), x1: f64, y1: f64, rx_in: f64, ry_in: f64, rot_deg: f64, large: bool, sweep: bool, x2: f64, y2: f64) void {
    if (x1 == x2 and y1 == y2) return;
    var rx = @abs(rx_in);
    var ry = @abs(ry_in);
    if (rx == 0 or ry == 0) return sink.line(sink.ctx, x2, y2);
    const phi = rot_deg * std.math.pi / 180.0;
    const cos_phi = @cos(phi);
    const sin_phi = @sin(phi);
    // Step 1: the midpoint in the rotated frame.
    const dx = (x1 - x2) / 2;
    const dy = (y1 - y2) / 2;
    const x1p = cos_phi * dx + sin_phi * dy;
    const y1p = -sin_phi * dx + cos_phi * dy;
    // Radii too small: scale them up.
    const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1) {
        const s = @sqrt(lambda);
        rx *= s;
        ry *= s;
    }
    // Step 2: the center in the rotated frame.
    const num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    var coef = if (den == 0) 0 else @sqrt(@max(0, num / den));
    if (large == sweep) coef = -coef;
    const cxp = coef * rx * y1p / ry;
    const cyp = -coef * ry * x1p / rx;
    // Step 3: the center.
    const ccx = cos_phi * cxp - sin_phi * cyp + (x1 + x2) / 2;
    const ccy = sin_phi * cxp + cos_phi * cyp + (y1 + y2) / 2;
    // Step 4: the start angle and the sweep.
    const theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
    var dtheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
    if (!sweep and dtheta > 0) dtheta -= 2 * std.math.pi;
    if (sweep and dtheta < 0) dtheta += 2 * std.math.pi;

    const segments: usize = @max(1, @as(usize, @intFromFloat(@ceil(@abs(dtheta) / (std.math.pi / 2.0) - 1e-9))));
    const delta = dtheta / @as(f64, @floatFromInt(segments));
    // Control point distance for a circular arc of `delta`.
    const t = 4.0 / 3.0 * @tan(delta / 4);
    var th = theta1;
    var i: usize = 0;
    while (i < segments) : (i += 1) {
        const c0 = @cos(th);
        const s0 = @sin(th);
        const c1 = @cos(th + delta);
        const s1 = @sin(th + delta);
        // On the unit circle, then scaled, rotated and moved.
        const p = [_][2]f64{
            .{ c0 - t * s0, s0 + t * c0 },
            .{ c1 + t * s1, s1 - t * c1 },
            .{ c1, s1 },
        };
        var out: [3][2]f64 = undefined;
        for (p, 0..) |q, k| {
            const ex = q[0] * rx;
            const ey = q[1] * ry;
            out[k] = .{ cos_phi * ex - sin_phi * ey + ccx, sin_phi * ex + cos_phi * ey + ccy };
        }
        // The last point exactly at the end (no drift).
        if (i == segments - 1) out[2] = .{ x2, y2 };
        sink.cubic(sink.ctx, out[0][0], out[0][1], out[1][0], out[1][1], out[2][0], out[2][1]);
        th += delta;
    }
}

/// The signed angle from vector u to vector v.
fn angle(ux: f64, uy: f64, vx: f64, vy: f64) f64 {
    return std.math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
}

// ---------------------------------------------------------------------------

const Rec = struct {
    out: std.ArrayList(u8) = .empty,
    fn sink(self: *Rec) Sink(*Rec) {
        return .{ .ctx = self, .move = move, .line = line, .cubic = cubic, .quad = quad, .close = close };
    }
    fn put(self: *Rec, comptime fmt: []const u8, args: anytype) void {
        self.out.print(std.testing.allocator, fmt, args) catch unreachable;
    }
    fn move(self: *Rec, x: f64, y: f64) void {
        self.put("M{d:.2},{d:.2} ", .{ x, y });
    }
    fn line(self: *Rec, x: f64, y: f64) void {
        self.put("L{d:.2},{d:.2} ", .{ x, y });
    }
    fn cubic(self: *Rec, a: f64, b: f64, c: f64, d: f64, e: f64, f: f64) void {
        self.put("C{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2} ", .{ a, b, c, d, e, f });
    }
    fn quad(self: *Rec, a: f64, b: f64, c: f64, d: f64) void {
        self.put("Q{d:.2},{d:.2},{d:.2},{d:.2} ", .{ a, b, c, d });
    }
    fn close(self: *Rec) void {
        self.put("Z ", .{});
    }
};

fn expectPath(d: []const u8, want: []const u8, ok: bool) !void {
    var rec: Rec = .{};
    defer rec.out.deinit(std.testing.allocator);
    try std.testing.expectEqual(ok, parse(*Rec, d, rec.sink()));
    try std.testing.expectEqualStrings(want, std.mem.trimEnd(u8, rec.out.items, " "));
}

test "lines, relative commands, implicit repeats" {
    try expectPath("M10 10 L20 10 h5 v-5 z", "M10.00,10.00 L20.00,10.00 L25.00,10.00 L25.00,5.00 Z", true);
    // Pairs after a moveto are linetos; relative after a relative moveto.
    try expectPath("m1 1 2 2 3 3", "M1.00,1.00 L3.00,3.00 L6.00,6.00", true);
    try expectPath("M0 0L1 1 2 2", "M0.00,0.00 L1.00,1.00 L2.00,2.00", true);
    // After Z, the current point is the subpath's start.
    try expectPath("M5 5 l1 0 z l2 2", "M5.00,5.00 L6.00,5.00 Z L7.00,7.00", true);
}

test "compact numbers" {
    try expectPath("M1.5.5L-1-2", "M1.50,0.50 L-1.00,-2.00", true);
    try expectPath("M1e1,2E-1", "M10.00,0.20", true);
    try expectPath("M0,0 L.5,.25", "M0.00,0.00 L0.50,0.25", true);
}

test "curves and their reflections" {
    try expectPath("M0 0 C1 2 3 4 5 6 S9 10 11 12", "M0.00,0.00 C1.00,2.00,3.00,4.00,5.00,6.00 C7.00,8.00,9.00,10.00,11.00,12.00", true);
    try expectPath("M0 0 Q1 1 2 0 T4 0", "M0.00,0.00 Q1.00,1.00,2.00,0.00 Q3.00,-1.00,4.00,0.00", true);
    // S without a previous C: the first control point is the current point.
    try expectPath("M0 0 S1 1 2 2", "M0.00,0.00 C0.00,0.00,1.00,1.00,2.00,2.00", true);
}

test "arcs: compact flags, ends exactly, degenerate radii" {
    var rec: Rec = .{};
    defer rec.out.deinit(std.testing.allocator);
    // A half circle of radius 5 from (0,0) to (10,0): two quarter cubics.
    try std.testing.expect(parse(*Rec, "M0 0a5 5 0 0110 0", rec.sink()));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rec.out.items, "C"));
    try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, rec.out.items, " "), "10.00,0.00"));
    // Zero radius: a line.
    try expectPath("M0 0 A0 5 0 0 1 3 4", "M0.00,0.00 L3.00,4.00", true);
    // Same start and end: nothing.
    try expectPath("M1 1 A5 5 0 0 1 1 1", "M1.00,1.00", true);
}

test "errors keep what came before" {
    try expectPath("M0 0 L1 1 X 2 2", "M0.00,0.00 L1.00,1.00", false);
    try expectPath("10 10", "", false);
    try expectPath("M0 0 L1", "M0.00,0.00", false);
    try expectPath("", "", true);
}
