//! The isolation pattern (`Security.isolation`): every IPC call from the
//! app's own pages is approved by the app's isolation hook, running in a
//! sandboxed frame the page can't reach, and signed there with a key the page
//! never sees. A script injected into the page (an XSS, a compromised
//! dependency) can still call `window.oriel.invoke`, but only through the hook.
//!
//! Flow:
//! 1. The bridge adds a hidden `<iframe sandbox="allow-scripts">` loading
//!    `origin` (`app://isolation/`) to the top frame, before page scripts run.
//!    Without `allow-same-origin` its origin is opaque: neither side can reach
//!    the other's globals.
//! 2. Serving that page, the scheme handler mints a fresh key for the
//!    requesting webview (`serve`) and puts it in the page. The page is
//!    cross-origin to the app (no CORS headers, `Cache-Control: no-store`),
//!    so the main page can't read it.
//! 3. `invoke` posts `{cmd, args}` to the frame. The frame runs the hook,
//!    then signs `s = JSON.stringify({seq, cmd, args})` with HMAC-SHA256
//!    (WebCrypto, non-extractable key) and posts `{kid, s, mac}` back.
//! 4. The bridge forwards that as `{cmd: "oriel:isolated", iso, token}`;
//!    `check` verifies the MAC for that webview's key, requires `seq` above
//!    the key's last one (no replay), and hands the inner call on to the
//!    usual token, capability and dispatch path.
//!
//! Why HMAC and not Tauri's AES-GCM: confidentiality from the main page is
//! meaningless here (the main page wrote the arguments); what matters is that
//! a call can't reach Zig without the hook's approval, which is authenticity.
//! A MAC gives exactly that, keeps the payload readable in logs, and makes
//! the native side a verify instead of a decrypt.
//!
//! Scope: isolation covers the app's own pages (`app://app` and the dev
//! server). Remote capability origins keep the token-only path, limited by
//! their capabilities: the isolation page's `frame-ancestors` doesn't let
//! them embed it. Events from Zig to the page are unchanged (as in Tauri).
//!
//! Keys: one per isolation page load, bound to the webview that loaded it,
//! each with its own sequence counter. Keys are never reused, so a replayed
//! call always fails the `seq` check; a page that loads extra isolation frames
//! only gets more hook-gated signers. The table is fixed-size (no allocation):
//! at most `keys_per_view` per webview and `max_keys` in all, least recently
//! used evicted first (a frame whose key was evicted fails closed).

const std = @import("std");
const builtin = @import("builtin");
const security = @import("security.zig");
const ipc = @import("ipc.zig");

const log = std.log.scoped(.oriel);
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// The isolation page's origin (a second host of the app scheme).
pub const origin = if (builtin.os.tag == .windows) "https://isolation.localhost" else "app://isolation";
/// Its host, as the scheme handlers see it.
pub const host = if (builtin.os.tag == .windows) "isolation.localhost" else "isolation";

/// The command name of a signed call (the real one is inside `s`).
pub const sealed_cmd = "oriel:isolated";

/// A signed call, as the bridge forwards it (`Request.iso`).
pub const Sealed = struct {
    kid: []const u8,
    s: []const u8,
    mac: []const u8,
};

// --- Keys ------------------------------------------------------------------------

const kid_len = 16; // hex of 8 random bytes
const key_len = 32;
const mac_hex_len = 64;
pub const keys_per_view = 8;
pub const max_keys = 256;

const Slot = struct {
    live: bool = false,
    view: usize = 0,
    kid: [kid_len]u8 = undefined,
    key: [key_len]u8 = undefined,
    last_seq: u64 = 0,
    used: u64 = 0,
};

var slots: [max_keys]Slot = @splat(.{});
var clock: u64 = 0;
var rng: std.Random.DefaultCsprng = undefined;
var rng_ready = false;
/// Scheme handlers and bridges run on the UI thread on every OS; the lock is
/// cheap insurance (short, allocation-free critical sections).
var busy: std.atomic.Value(bool) = .init(false);

fn lock() void {
    while (busy.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlock() void {
    busy.store(false, .release);
}

/// Seed the key generator (from `ipc.initToken`'s secure random key). Until
/// then no key is minted and every isolated call fails closed.
pub fn init(seed: [32]u8) void {
    lock();
    defer unlock();
    rng = .init(seed);
    rng_ready = true;
}

const Minted = struct {
    kid: [kid_len]u8,
    key: [key_len]u8,
};

/// A fresh key for `view`, evicting that webview's least recently used key
/// past `keys_per_view`, else the least recently used of all.
fn mint(view: usize) ?Minted {
    lock();
    defer unlock();
    if (!rng_ready) return null;
    var count: usize = 0;
    var view_lru: ?usize = null;
    var free: ?usize = null;
    var global_lru: usize = 0;
    for (&slots, 0..) |*s, i| {
        if (!s.live) {
            if (free == null) free = i;
            continue;
        }
        if (s.used < slots[global_lru].used or !slots[global_lru].live) global_lru = i;
        if (s.view != view) continue;
        count += 1;
        if (view_lru == null or s.used < slots[view_lru.?].used) view_lru = i;
    }
    const index = if (count >= keys_per_view) view_lru.? else free orelse global_lru;
    const slot = &slots[index];
    var id: [kid_len / 2]u8 = undefined;
    rng.fill(&id);
    clock += 1;
    slot.* = .{ .live = true, .view = view, .kid = std.fmt.bytesToHex(id, .lower), .last_seq = 0, .used = clock };
    rng.fill(&slot.key);
    return .{ .kid = slot.kid, .key = slot.key };
}

/// Forget every key of a webview (when it is destroyed).
pub fn forget(view: usize) void {
    lock();
    defer unlock();
    for (&slots) |*s| {
        if (!s.live or s.view != view) continue;
        std.crypto.secureZero(u8, &s.key);
        s.* = .{};
    }
}

const Inner = struct {
    seq: u64,
    cmd: []const u8,
    args: std.json.Value = .null,
};

/// Verify a sealed call from `view` and return the call inside it.
fn open(arena: std.mem.Allocator, view: usize, sealed: Sealed) !Inner {
    if (sealed.kid.len != kid_len or sealed.mac.len != mac_hex_len) return error.BadSeal;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&mac, sealed.mac) catch return error.BadSeal;

    lock();
    defer unlock();
    const slot = for (&slots) |*s| {
        if (s.live and s.view == view and std.mem.eql(u8, &s.kid, sealed.kid)) break s;
    } else return error.UnknownKey;
    var want: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&want, sealed.s, &slot.key);
    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, want, mac)) return error.BadSeal;
    // Signed by the frame holding this key: parse it (arena only), then
    // accept each sequence number once, in order.
    const inner = std.json.parseFromSliceLeaky(Inner, arena, sealed.s, .{}) catch return error.BadSeal;
    if (inner.seq <= slot.last_seq) return error.Replayed;
    slot.last_seq = inner.seq;
    clock += 1;
    slot.used = clock;
    return inner;
}

/// A call after `check`: the request to dispatch and its JSON (for the
/// async path, which parses the request again on a worker).
pub const Checked = struct {
    request: ipc.Request,
    json: []const u8,
};

/// The isolation step of a bridge's message handler, after the token check.
/// Without isolation, or for a remote capability origin, the request passes
/// unchanged. From the app's own pages only a sealed call is accepted, and
/// the call inside it replaces the request. `json` is the original message.
/// Errors are logged here; bridges answer "Forbidden".
pub fn check(
    arena: std.mem.Allocator,
    comptime sec: security.Security,
    local: security.Local,
    page_url: []const u8,
    view: usize,
    request: ipc.Request,
    json: []const u8,
) error{ Forbidden, OutOfMemory }!Checked {
    if (comptime sec.isolation == null) return .{ .request = request, .json = json };
    var buf: [512]u8 = undefined;
    const o = security.origin(&buf, page_url) orelse return error.Forbidden;
    const sealed_shape = std.mem.eql(u8, request.cmd, sealed_cmd) or request.iso != null;
    if (!local.contains(o)) {
        // Remote capability origins: token path only (see the file comment).
        if (sealed_shape) return error.Forbidden;
        return .{ .request = request, .json = json };
    }
    const sealed = request.iso orelse {
        log.warn("isolation: refused an unsealed IPC call from the app's page", .{});
        return error.Forbidden;
    };
    if (!std.mem.eql(u8, request.cmd, sealed_cmd)) return error.Forbidden;
    const inner = open(arena, view, sealed) catch |err| {
        log.warn("isolation: refused a sealed IPC call ({s})", .{@errorName(err)});
        return error.Forbidden;
    };
    const unwrapped: ipc.Request = .{ .cmd = inner.cmd, .args = inner.args, .token = request.token };
    return .{
        .request = unwrapped,
        .json = try std.json.Stringify.valueAlloc(arena, unwrapped, .{ .emit_null_optional_fields = false }),
    };
}

// --- The isolation page ------------------------------------------------------------

/// Runs in the isolation frame, before the app's hook (see the file comment).
/// Keep in sync with `bridge_js` below (`__oriel_iso` messages).
const runtime_head =
    \\(() => {
    \\  "use strict";
    \\  const parents =
;
const runtime_js =
    \\;
    \\  const parentWin = window.parent;
    \\  if (parentWin === window) return;
    \\  // Only a direct child of the app's own top page: WebKit doesn't enforce
    \\  // this page's frame-ancestors for custom schemes.
    \\  const ao = location.ancestorOrigins;
    \\  if (ao && (ao.length !== 1 || !parents.includes(ao[0]))) return;
    \\  const meta = document.querySelector('meta[name="oriel-isolation"]');
    \\  if (!meta) return;
    \\  const [kid, b64] = String(meta.content).split(".");
    \\  meta.remove();
    \\  const raw = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    \\  const keyP = crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    \\  raw.fill(0);
    \\  const enc = new TextEncoder();
    \\  const hex = (b) => Array.from(new Uint8Array(b), (x) => x.toString(16).padStart(2, "0")).join("");
    \\  const reply = (m) => parentWin.postMessage(Object.assign({ __oriel_iso: true }, m), "*");
    \\  const failed = (id, err) => reply({ id, error: String((err && err.message) || err) });
    \\  let seq = 0;
    \\  let chain = Promise.resolve();
    \\  addEventListener("message", (e) => {
    \\    if (e.source !== parentWin) return;
    \\    const m = e.data;
    \\    if (!m || typeof m !== "object" || typeof m.id !== "number" || typeof m.cmd !== "string" || typeof m.a !== "string") return;
    \\    (async () => {
    \\      const hook = globalThis.__ORIEL_ISOLATION_HOOK__;
    \\      if (typeof hook !== "function") throw new Error("no isolation hook");
    \\      const call = await hook({ cmd: m.cmd, args: JSON.parse(m.a) });
    \\      if (!call || typeof call !== "object" || typeof call.cmd !== "string") throw new Error("the isolation hook rejected the call");
    \\      return call;
    \\    })().then((call) => {
    \\      // Sign in approval order: seq only ever grows on the native side.
    \\      chain = chain.then(async () => {
    \\        const s = JSON.stringify({ seq: ++seq, cmd: call.cmd, args: call.args === undefined ? null : call.args });
    \\        const mac = hex(await crypto.subtle.sign("HMAC", await keyP, enc.encode(s)));
    \\        reply({ id: m.id, kid, s, mac });
    \\      }).catch((err) => failed(m.id, err));
    \\    }, (err) => failed(m.id, err));
    \\  });
    \\  reply({ ready: true });
    \\})();
    \\
;

/// The isolation page's single inline script: the runtime, then the hook.
pub fn script(comptime sec: security.Security, comptime local: security.Local) []const u8 {
    const iso = sec.isolation orelse return "";
    return runtime_head ++ " " ++ localOrigins(local) ++ runtime_js ++ ";\n" ++ iso.hook ++ "\n";
}

/// The app's own origins as a JavaScript array.
fn localOrigins(comptime local: security.Local) []const u8 {
    return std.fmt.comptimePrint("[\"{s}\"{s}{s}{s}]", .{
        security.app_origin,
        if (local.dev_origin != null) ", \"" else "",
        local.dev_origin orelse "",
        if (local.dev_origin != null) "\"" else "",
    });
}

/// Compile error for a hook that could end or confuse the inline `<script>`.
pub fn checkHook(comptime sec: security.Security) void {
    comptime {
        const hook = if (sec.isolation) |iso| iso.hook else "";
        @setEvalBranchQuota(10_000 + hook.len * 40);
        for (0..hook.len) |i| {
            const rest = hook[i..];
            if (startsWithIgnoreCase(rest, "</script") or startsWithIgnoreCase(rest, "<!--"))
                @compileError("security.isolation.hook: must not contain \"</script\" or \"<!--\" (it is inlined into the isolation page); write e.g. \"<\\/script\"");
        }
    }
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// The CSP of the isolation page: only its own inline script, and only the
/// app's own pages may frame it.
pub fn pageCsp(gpa: std.mem.Allocator, comptime sec: security.Security, comptime local: security.Local) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(comptime script(sec, local), &digest, .{});
    var b64: [std.base64.standard.Encoder.calcSize(digest.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&b64, &digest);
    return std.fmt.allocPrint(gpa, "default-src 'none'; script-src 'sha256-{s}'; base-uri 'none'; form-action 'none'; frame-ancestors {s}{s}{s}", .{
        &b64, security.app_origin, if (local.dev_origin != null) " " else "", local.dev_origin orelse "",
    });
}

/// Response headers of the isolation page besides Content-Type and its CSP.
pub const page_headers = [_][2][]const u8{
    .{ "X-Content-Type-Options", "nosniff" },
    .{ "Cache-Control", "no-store" },
    .{ "Referrer-Policy", "no-referrer" },
};

/// `page_headers` as "Name: value\r\n" lines.
pub const page_header_lines = blk: {
    var out: []const u8 = "";
    for (page_headers) |h| out = out ++ h[0] ++ ": " ++ h[1] ++ "\r\n";
    break :blk out;
};

/// Whether `path` (of a request to `host`) is the isolation page.
pub fn isPagePath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "") or std.mem.eql(u8, path, "/index.html");
}

/// The isolation page for a request from `view`, with a key minted for it.
/// Null if no key can be minted (before `init`). Caller frees; the key only
/// lives in the returned page (and the key table).
pub fn servePage(gpa: std.mem.Allocator, comptime sec: security.Security, comptime local: security.Local, view: usize) !?[]u8 {
    var minted = mint(view) orelse return null;
    defer std.crypto.secureZero(u8, &minted.key);
    var key_b64: [std.base64.standard.Encoder.calcSize(key_len)]u8 = undefined;
    defer std.crypto.secureZero(u8, &key_b64);
    _ = std.base64.standard.Encoder.encode(&key_b64, &minted.key);
    return try std.fmt.allocPrint(gpa,
        \\<!doctype html><html><head><meta charset="utf-8"><meta name="oriel-isolation" content="{s}.{s}"><script>{s}</script></head><body></body></html>
    , .{ &minted.kid, &key_b64, comptime script(sec, local) });
}

// --- The page side (bridge) ----------------------------------------------------------

/// JavaScript for the bridges defining `invoke`: `rawInvoke` without
/// isolation, on remote origins and in frames; otherwise calls go through the
/// isolation frame and are forwarded with `sendSealed(iso)`. Both functions
/// are defined by each bridge before this script.
pub fn bridgeScript(comptime sec: security.Security, comptime local: security.Local) []const u8 {
    if (sec.isolation == null) return "  const invoke = rawInvoke;\n";
    return "  const isoOrigin = \"" ++ origin ++ "\";\n  const isoLocal = " ++ localOrigins(local) ++ ";\n" ++ bridge_js;
}

const bridge_js =
    \\  const invoke = (() => {
    \\    if (!isoLocal.includes(location.origin) || window !== window.top) return rawInvoke;
    \\    const pending = new Map();
    \\    let queue = [];
    \\    let frame = null;
    \\    let ready = false;
    \\    let nextId = 1;
    \\    let readyTimer = 0;
    \\    function rejectAll(ids, msg) {
    \\      for (const id of ids) {
    \\        const p = pending.get(id);
    \\        if (p) { pending.delete(id); p.reject(new Error(msg)); }
    \\      }
    \\    }
    \\    function attach(f) {
    \\      const root = document.documentElement;
    \\      if (root) { root.appendChild(f); return; }
    \\      const mo = new MutationObserver(() => {
    \\        if (document.documentElement) { mo.disconnect(); if (f === frame) attach(f); }
    \\      });
    \\      mo.observe(document, { childList: true });
    \\    }
    \\    function mount() {
    \\      // Calls sent to a removed frame never come back.
    \\      if (frame) rejectAll([...pending.keys()].filter((id) => !queue.some((m) => m.id === id)), "the isolation frame was removed");
    \\      ready = false;
    \\      frame = document.createElement("iframe");
    \\      frame.setAttribute("sandbox", "allow-scripts");
    \\      frame.setAttribute("aria-hidden", "true");
    \\      frame.tabIndex = -1;
    \\      frame.style.cssText = "display:none!important";
    \\      frame.src = isoOrigin + "/";
    \\      attach(frame);
    \\      clearTimeout(readyTimer);
    \\      readyTimer = setTimeout(() => {
    \\        if (ready) return;
    \\        const ids = queue.map((m) => m.id);
    \\        queue = [];
    \\        rejectAll(ids, "the isolation frame did not load");
    \\      }, 10000);
    \\    }
    \\    window.addEventListener("message", (e) => {
    \\      if (!frame || !e.source || e.source !== frame.contentWindow) return;
    \\      const d = e.data;
    \\      if (!d || typeof d !== "object" || d.__oriel_iso !== true) return;
    \\      e.stopImmediatePropagation();
    \\      if (d.ready === true) {
    \\        ready = true;
    \\        clearTimeout(readyTimer);
    \\        const q = queue;
    \\        queue = [];
    \\        for (const m of q) frame.contentWindow.postMessage(m, "*");
    \\        return;
    \\      }
    \\      const p = pending.get(d.id);
    \\      if (!p) return;
    \\      pending.delete(d.id);
    \\      if (typeof d.error === "string") { p.reject(new Error(d.error)); return; }
    \\      // Forwarded in the order the frame signed them (seq order).
    \\      Promise.resolve(sendSealed({ kid: d.kid, s: d.s, mac: d.mac })).then(p.resolve, p.reject);
    \\    }, true);
    \\    mount();
    \\    return (cmd, args) => new Promise((resolve, reject) => {
    \\      let a;
    \\      try { a = JSON.stringify(args ?? null); } catch (err) { reject(err); return; }
    \\      const id = nextId++;
    \\      pending.set(id, { resolve, reject });
    \\      const m = { id, cmd: String(cmd), a };
    \\      if (!frame.isConnected) mount();
    \\      if (ready && frame.contentWindow) frame.contentWindow.postMessage(m, "*");
    \\      else queue.push(m);
    \\    });
    \\  })();
    \\
;

/// The app page's CSP with the isolation frame allowed: `frame-src` gets
/// `origin` (derived from `default-src` when the CSP has no `frame-src`).
/// A `child-src` without `frame-src`, or a `frame-src` without the isolation
/// origin, is a compile error: Oriel doesn't rewrite a policy the app wrote.
pub fn appCsp(comptime sec: security.Security) ?[]const u8 {
    const csp = sec.csp orelse return null;
    if (sec.isolation == null) return csp;
    @setEvalBranchQuota(100_000);
    if (directive(csp, "frame-src")) |v| {
        if (!hasSource(v, origin)) @compileError("security.csp: with isolation on, frame-src must allow " ++ origin);
        return csp;
    }
    if (directive(csp, "child-src") != null) @compileError("security.csp: with isolation on and a child-src, add a frame-src allowing " ++ origin);
    const base = directive(csp, "default-src") orelse return csp; // no default: frames aren't restricted
    const sources = if (hasSource(base, "'none'")) "" else base ++ " ";
    const trimmed = std.mem.trimEnd(u8, csp, " ;");
    return trimmed ++ "; frame-src " ++ sources ++ origin;
}

/// The value of a CSP directive, or null.
fn directive(comptime csp: []const u8, comptime name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, csp, ';');
    while (it.next()) |part| {
        const d = std.mem.trim(u8, part, " \t");
        const end = std.mem.indexOfAny(u8, d, " \t") orelse d.len;
        if (std.ascii.eqlIgnoreCase(d[0..end], name)) return std.mem.trim(u8, d[end..], " \t");
    }
    return null;
}

fn hasSource(value: []const u8, source: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, value, " \t");
    while (it.next()) |s| if (std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, s, "/"), source)) return true;
    return false;
}

// --- Tests -----------------------------------------------------------------------------

fn sealFor(buf: []u8, key: [key_len]u8, s: []const u8) []const u8 {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, s, &key);
    const hex = std.fmt.bytesToHex(mac, .lower);
    @memcpy(buf[0..hex.len], &hex);
    return buf[0..hex.len];
}

test "sealed calls: accepted once, in order, only by their webview" {
    init(@splat(7));
    defer forget(1);
    defer forget(2);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const m = mint(1).?;
    var mb: [64]u8 = undefined;
    const s1 = "{\"seq\":1,\"cmd\":\"ping\",\"args\":{\"a\":1}}";
    const got = try open(arena, 1, .{ .kid = &m.kid, .s = s1, .mac = sealFor(&mb, m.key, s1) });
    try std.testing.expectEqualStrings("ping", got.cmd);
    try std.testing.expectEqual(@as(u64, 1), got.seq);
    // Replay of the same call, or an older one.
    try std.testing.expectError(error.Replayed, open(arena, 1, .{ .kid = &m.kid, .s = s1, .mac = sealFor(&mb, m.key, s1) }));
    // Another webview can't use this key.
    const s2 = "{\"seq\":2,\"cmd\":\"ping\"}";
    try std.testing.expectError(error.UnknownKey, open(arena, 2, .{ .kid = &m.kid, .s = s2, .mac = sealFor(&mb, m.key, s2) }));
    // A wrong key or a tampered payload.
    try std.testing.expectError(error.BadSeal, open(arena, 1, .{ .kid = &m.kid, .s = s2, .mac = sealFor(&mb, @splat(1), s2) }));
    const mac2 = sealFor(&mb, m.key, s2);
    try std.testing.expectError(error.BadSeal, open(arena, 1, .{ .kid = &m.kid, .s = "{\"seq\":2,\"cmd\":\"pong\"}", .mac = mac2 }));
    try std.testing.expectError(error.BadSeal, open(arena, 1, .{ .kid = &m.kid, .s = s2, .mac = "zz" }));
    // Seq 2 is still unused: the rejected attempts didn't consume it.
    _ = try open(arena, 1, .{ .kid = &m.kid, .s = s2, .mac = sealFor(&mb, m.key, s2) });
    // A second key for the same webview has its own counter.
    const m2 = mint(1).?;
    try std.testing.expect(!std.mem.eql(u8, &m.key, &m2.key));
    _ = try open(arena, 1, .{ .kid = &m2.kid, .s = s1, .mac = sealFor(&mb, m2.key, s1) });
    // Forgotten webview: its keys are gone.
    forget(1);
    const s3 = "{\"seq\":3,\"cmd\":\"ping\"}";
    try std.testing.expectError(error.UnknownKey, open(arena, 1, .{ .kid = &m.kid, .s = s3, .mac = sealFor(&mb, m.key, s3) }));
}

test "per-webview key cap evicts the least recently used" {
    init(@splat(9));
    defer forget(5);
    defer forget(6);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var first = mint(5).?;
    const other = mint(6).?;
    for (0..keys_per_view) |_| _ = mint(5).?;
    var mb: [64]u8 = undefined;
    const s = "{\"seq\":1,\"cmd\":\"x\"}";
    try std.testing.expectError(error.UnknownKey, open(arena_state.allocator(), 5, .{ .kid = &first.kid, .s = s, .mac = sealFor(&mb, first.key, s) }));
    // Other webviews keep theirs.
    _ = try open(arena_state.allocator(), 6, .{ .kid = &other.kid, .s = s, .mac = sealFor(&mb, other.key, s) });
    var n: usize = 0;
    for (slots) |sl| {
        if (sl.live and sl.view == 5) n += 1;
    }
    try std.testing.expectEqual(@as(usize, keys_per_view), n);
    std.crypto.secureZero(u8, &first.key);
}

test check {
    init(@splat(3));
    defer forget(9);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sec: security.Security = comptime .{
        .isolation = .{ .hook = "globalThis.__ORIEL_ISOLATION_HOOK__ = (c) => c;" },
        .capabilities = &.{.{ .origin = "https://partner.example", .commands = &.{"ping"} }},
    };
    const local: security.Local = .{};
    const app_page = security.app_origin ++ "/index.html";

    // Unsealed from the app's page: refused, even a built-in.
    try std.testing.expectError(error.Forbidden, check(arena, sec, local, app_page, 9, .{ .cmd = "open_external" }, "{}"));
    // Remote capability origin: token path, unchanged; a sealed shape is refused there.
    const remote = try check(arena, sec, local, "https://partner.example/", 9, .{ .cmd = "ping" }, "{\"cmd\":\"ping\"}");
    try std.testing.expectEqualStrings("ping", remote.request.cmd);
    try std.testing.expectError(error.Forbidden, check(arena, sec, local, "https://partner.example/", 9, .{ .cmd = sealed_cmd }, "{}"));

    const m = mint(9).?;
    var mb: [64]u8 = undefined;
    const s = "{\"seq\":1,\"cmd\":\"greet\",\"args\":{\"name\":\"x\"}}";
    const req: ipc.Request = .{ .cmd = sealed_cmd, .token = "t", .iso = .{ .kid = &m.kid, .s = s, .mac = sealFor(&mb, m.key, s) } };
    const ok = try check(arena, sec, local, app_page, 9, req, "{}");
    try std.testing.expectEqualStrings("greet", ok.request.cmd);
    try std.testing.expectEqualStrings("t", ok.request.token.?);
    const again = try ipc.parseRequest(arena, ok.json);
    try std.testing.expectEqualStrings("greet", again.cmd);
    try std.testing.expect(again.iso == null);
    try std.testing.expectError(error.Forbidden, check(arena, sec, local, app_page, 9, req, "{}"));
    // Without isolation nothing changes.
    const plain = try check(arena, .{}, local, app_page, 9, .{ .cmd = "ping" }, "{\"cmd\":\"ping\"}");
    try std.testing.expectEqualStrings("{\"cmd\":\"ping\"}", plain.json);
}

test appCsp {
    const hook: security.Isolation = .{ .hook = "" };
    try std.testing.expectEqualStrings(
        "default-src 'self'; frame-src 'self' " ++ origin,
        comptime appCsp(.{ .csp = "default-src 'self';", .isolation = hook }).?,
    );
    try std.testing.expectEqualStrings(
        "default-src 'none'; frame-src " ++ origin,
        comptime appCsp(.{ .csp = "default-src 'none'", .isolation = hook }).?,
    );
    const own = "default-src 'self'; frame-src 'self' " ++ origin ++ "/";
    try std.testing.expectEqualStrings(own, comptime appCsp(.{ .csp = own, .isolation = hook }).?);
    try std.testing.expectEqualStrings("script-src 'self'", comptime appCsp(.{ .csp = "script-src 'self'", .isolation = hook }).?);
    try std.testing.expectEqualStrings(security.default_csp, comptime appCsp(.{}).?);
    try std.testing.expect(comptime appCsp(.{ .csp = null, .isolation = hook }) == null);
    // The default CSP gets a frame-src from its default-src.
    try std.testing.expect(comptime directive(appCsp(.{ .isolation = hook }).?, "frame-src") != null);
}

test "isolation page" {
    init(@splat(4));
    defer forget(11);
    const sec: security.Security = comptime .{ .isolation = .{ .hook = "globalThis.__ORIEL_ISOLATION_HOOK__ = (c) => c;" } };
    const local: security.Local = .{ .dev_origin = "http://localhost:5173" };
    const page = (try servePage(std.testing.allocator, sec, local, 11)).?;
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "<meta name=\"oriel-isolation\" content=\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "__ORIEL_ISOLATION_HOOK__ = (c) => c;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "const parents = [\"" ++ security.app_origin ++ "\", \"http://localhost:5173\"];") != null);
    const csp = try pageCsp(std.testing.allocator, sec, local);
    defer std.testing.allocator.free(csp);
    try std.testing.expect(std.mem.startsWith(u8, csp, "default-src 'none'; script-src 'sha256-"));
    try std.testing.expect(std.mem.endsWith(u8, csp, "frame-ancestors " ++ security.app_origin ++ " http://localhost:5173"));
    // The CSP hash is of exactly the inline script.
    const start = std.mem.indexOf(u8, page, "<script>").? + "<script>".len;
    const end = std.mem.indexOf(u8, page, "</script>").?;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(page[start..end], &digest, .{});
    var b64: [44]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&b64, &digest);
    try std.testing.expect(std.mem.indexOf(u8, csp, &b64) != null);
    try std.testing.expect(isPagePath("/") and !isPagePath("/x.js"));
    checkHook(sec);
}
