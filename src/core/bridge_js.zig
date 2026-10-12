//! The page bridge script: the `window.oriel` API injected into every
//! WebView, one script for every platform. The API itself is
//! src/core/bridge_api.js, which the native renderer bundles too (with its
//! own transport, src/native_ui/js/src/main.js). A platform supplies only
//! its transport (`script`'s argument): `webkit_transport` (Linux, macOS,
//! iOS) or a `channelTransport` (Windows, Android).

const std = @import("std");
const target = @import("target.zig");
/// `window.oriel.features`: the build's resolved feature flags.
const features = @import("features.zig");

/// The script message handler WebKit pages post to.
pub const handler_name = "oriel";

/// Replaced by `ipc.tokenScript` (which defines `const ipcToken`) in each
/// window's copy of the script.
pub const token_placeholder = "/*__ORIEL_IPC_TOKEN__*/";
/// Replaced by `isolation.bridgeScript` (which defines `invoke`).
pub const isolation_placeholder = "/*__ORIEL_ISOLATION__*/";

/// The bridge script with `transport`: statements that define
/// `rawInvoke(cmd, args)` and `sendSealed(iso)` (both return Promises). They
/// see `listeners`, `pendingEvents` and `ipcToken`, and may `return` to
/// leave a page without the bridge.
pub fn script(comptime transport: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000); // the scans cover the whole script
        const out = head ++ transport ++ "\n" ++ isolation_placeholder ++ "\n" ++ body;
        std.debug.assert(std.mem.count(u8, out, token_placeholder) == 1);
        std.debug.assert(std.mem.count(u8, out, isolation_placeholder) == 1);
        return out;
    }
}

/// WebKit (WebKitGTK, WKWebView): `postMessage` on the script message
/// handler, whose reply resolves the returned Promise.
pub const webkit_transport = "  const handler = window.webkit.messageHandlers." ++ handler_name ++ ";\n" ++
    \\  function rawInvoke(cmd, args) {
    \\    return handler.postMessage(JSON.stringify({ cmd, args: args ?? null, token: ipcToken }));
    \\  }
    \\  function sendSealed(iso) {
    \\    return handler.postMessage(JSON.stringify({ cmd: "oriel:isolated", iso, token: ipcToken }));
    \\  }
;

/// A message channel (WebView2, Android's WebMessageListener).
pub const Channel = struct {
    /// Statements run first; they may `return` (no channel, no bridge).
    setup: []const u8 = "",
    /// An expression with `addEventListener("message", ...)` and
    /// `postMessage(string)`.
    port: []const u8,
    /// Statements that set `data` from the message `event`; they may
    /// `return` to drop it.
    decode: []const u8,
};

/// Requests carry an `id`; replies (`__oriel_reply`) and events
/// (`__oriel_event`) come back on the same channel, so a command's events
/// arrive before its reply. Top-level documents only.
pub fn channelTransport(comptime c: Channel) []const u8 {
    return "  if (window !== window.top) return;\n" ++ c.setup ++
        \\  const pending = new Map();
        \\  let nextId = 1;
        \\
    ++ "  " ++ c.port ++ ".addEventListener('message', (event) => {\n" ++ c.decode ++
        \\    // Events come on the same channel as replies, so a command's
        \\    // events arrive before its reply.
        \\    if (data && typeof data === 'object' && '__oriel_event' in data) {
        \\      window.oriel?.__emit(data.__oriel_event, data.payload);
        \\      return;
        \\    }
        \\    if (data && typeof data === 'object' && '__oriel_reply' in data) {
        \\      const p = pending.get(data.id);
        \\      if (p) {
        \\        pending.delete(data.id);
        \\        if (data.error) {
        \\          p.reject(new Error(data.error));
        \\        } else {
        \\          p.resolve(data.result);
        \\        }
        \\      }
        \\    }
        \\  });
        \\  function send(msg) {
        \\    return new Promise((resolve, reject) => {
        \\      const id = nextId++;
        \\      pending.set(id, { resolve, reject });
        \\
    ++ "      " ++ c.port ++ ".postMessage(JSON.stringify(Object.assign({ id, token: ipcToken }, msg)));\n" ++
        \\    });
        \\  }
        \\  function rawInvoke(cmd, args) {
        \\    return send({ cmd, args: args ?? null });
        \\  }
        \\  function sendSealed(iso) {
        \\    return send({ cmd: "oriel:isolated", iso });
        \\  }
    ;
}

const head =
    \\(() => {
    \\  const listeners = new Map();
    \\  const pendingEvents = new Map();
    \\
++ token_placeholder ++ "\n";

/// `window.oriel` itself: the file the native renderer bundles too
/// (src/core/bridge_api.js), less its `export` line.
const api_js = blk: {
    @setEvalBranchQuota(100_000);
    const src = @embedFile("bridge_api.js");
    const export_line = "export { orielApi };";
    const at = std.mem.lastIndexOf(u8, src, export_line) orelse @compileError("bridge_api.js: no export line");
    if (std.mem.trim(u8, src[at + export_line.len ..], " \r\n").len != 0) @compileError("bridge_api.js: the export line must come last");
    break :blk src[0..at];
};

/// Everything after the transport and the isolation script (`invoke`).
const body = api_js ++
    \\  Object.defineProperty(window, "oriel", { value: orielApi({
    \\    invoke,
    \\    listeners,
    \\    pendingEvents,
    \\    platform:
++ " " ++ target.platform_js ++ ",\n    features: " ++ features.js ++ ",\n" ++
    \\    label: () => window.__oriel_window_label,
    \\  }) });
    \\  // <div data-oriel-drag-region> moves the window when pressed (its buttons,
    \\  // fields and links, and anything under data-oriel-no-drag, keep their clicks).
    \\  window.addEventListener("mousedown", (e) => {
    \\    if (e.button !== 0 || !(e.target instanceof Element)) return;
    \\    if (!e.target.closest("[data-oriel-drag-region]")) return;
    \\    if (e.target.closest("button, input, textarea, select, a, [contenteditable], [data-oriel-no-drag]")) return;
    \\    e.preventDefault();
    \\    Promise.resolve(window.oriel.window.current().startDragging()).catch(() => {});
    \\  }, true);
    \\
++ @import("window_commands.zig").theme_color_js ++
    @import("security.zig").drop_guard_js ++
    \\})();
;

test "bridge script: each transport, one of each placeholder" {
    const scripts = comptime .{
        script(webkit_transport),
        script(channelTransport(.{ .port = "window.chrome.webview", .decode = "    const data = event.data;\n" })),
    };
    inline for (scripts) |s| {
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, s, token_placeholder));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, s, isolation_placeholder));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, s, "function rawInvoke("));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, s, "function sendSealed("));
        // Methods call the closure's invoke, so destructured ones work
        // (`const { openExternal } = oriel`).
        try std.testing.expect(std.mem.indexOf(u8, s, "this.invoke") == null);
        // bridge_api.js, spliced in without its module syntax.
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, s, "function orielApi("));
        try std.testing.expect(std.mem.indexOf(u8, s, "export {") == null);
    }
}
