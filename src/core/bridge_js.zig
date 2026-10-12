//! The page bridge script: the `window.oriel` API injected into every
//! WebView, one script for every platform. A platform supplies only its
//! transport (`script`'s argument): `webkit_transport` (Linux, macOS, iOS)
//! or a `channelTransport` (Windows, Android).

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

/// Everything after the transport and the isolation script (`invoke`).
const body =
    \\  class WindowHandle {
    \\    constructor(label) {
    \\      this.label = label;
    \\    }
    \\    close() {
    \\      return invoke("oriel:window:close", { label: this.label });
    \\    }
    \\    show() {
    \\      return invoke("oriel:window:show", { label: this.label });
    \\    }
    \\    hide() {
    \\      return invoke("oriel:window:hide", { label: this.label });
    \\    }
    \\    focus() {
    \\      return invoke("oriel:window:focus", { label: this.label });
    \\    }
    \\    setTitle(title) {
    \\      return invoke("oriel:window:setTitle", { label: this.label, title });
    \\    }
    \\    setSize(width, height) {
    \\      return invoke("oriel:window:setSize", { label: this.label, width, height });
    \\    }
    \\    maximize(maximized = true) {
    \\      return invoke("oriel:window:maximize", { label: this.label, maximized });
    \\    }
    \\    fullscreen(fullscreen = true) {
    \\      return invoke("oriel:window:fullscreen", { label: this.label, fullscreen });
    \\    }
    \\    startDragging() {
    \\      return invoke("oriel:window:startDragging", { label: this.label });
    \\    }
    \\    emit(event, payload) {
    \\      return windowApi.emitTo(this.label, event, payload);
    \\    }
    \\  }
    \\  const windowApi = {
    \\    async open(options) {
    \\      const res = await invoke("oriel:window:open", options);
    \\      return new WindowHandle(res.label);
    \\    },
    \\    current() {
    \\      return new WindowHandle(window.__oriel_window_label || "main");
    \\    },
    \\    async get(label) {
    \\      const res = await invoke("oriel:window:get", { label });
    \\      return res ? new WindowHandle(res.label) : null;
    \\    },
    \\    async all() {
    \\      const list = await invoke("oriel:window:all", {});
    \\      return (list || []).map(w => new WindowHandle(w.label));
    \\    },
    \\    emitTo(label, event, payload) {
    \\      return invoke("oriel:window:emitTo", { label, event, payload: payload ?? null });
    \\    }
    \\  };
    \\  Object.defineProperty(window, "oriel", { value: Object.freeze({
    \\    platform:
++ " " ++ target.platform_js ++ ",\n    features: " ++ features.js ++ ",\n" ++
    \\    invoke,
    \\    listen(event, callback) {
    \\      let set = listeners.get(event);
    \\      if (!set) listeners.set(event, (set = new Set()));
    \\      set.add(callback);
    \\      const queued = pendingEvents.get(event);
    \\      if (queued && queued.length > 0) {
    \\        pendingEvents.delete(event);
    \\        for (const payload of queued) {
    \\          try { callback(payload); } catch (e) { console.error(e); }
    \\        }
    \\      }
    \\      if (event === "deep-link") {
    \\        try { Promise.resolve(invoke("deep_link:ready", {})).catch(() => {}); } catch (_) {}
    \\      } else if (event === "notification:action") {
    \\        // A click that came before the page listened (one that launched the app).
    \\        try { Promise.resolve(invoke("notification:ready", {})).catch(() => {}); } catch (_) {}
    \\      } else if (event === "share:received" || event === "lifecycle" || event.startsWith("extension:")) {
    \\        // Shares that came before the page listened (one that launched the
    \\        // app); lifecycle and app extension events from before it loaded.
    \\        try { Promise.resolve(invoke("events:ready", { event })).catch(() => {}); } catch (_) {}
    \\      }
    \\      return () => set.delete(callback);
    \\    },
    \\    openExternal(url) {
    \\      return invoke("open_external", { url });
    \\    },
    \\    permissions: Object.freeze({
    \\      query(name) {
    \\        return invoke("permissions:query", { name });
    \\      },
    \\      request(name) {
    \\        return new Promise((resolve, reject) => {
    \\          let set = listeners.get("permission-changed");
    \\          if (!set) listeners.set("permission-changed", (set = new Set()));
    \\          const cb = (e) => { if (e && e.name === name) { set.delete(cb); resolve(e.status); } };
    \\          set.add(cb);
    \\          Promise.resolve(invoke("permissions:request", { name })).then((s) => {
    \\            if (s !== "prompt") { set.delete(cb); resolve(s); }
    \\          }, (err) => { set.delete(cb); reject(err); });
    \\        });
    \\      },
    \\      openSettings(name) {
    \\        return invoke("permissions:open_settings", { name });
    \\      },
    \\    }),
    \\    // { type: "background" | "foreground" | "memory_pressure" | "suspend" |
    \\    // "resume" | "terminating", level: "moderate" | "critical" | null }.
    \\    lifecycle: Object.freeze({
    \\      on(callback) {
    \\        return window.oriel.listen("lifecycle", callback);
    \\      },
    \\    }),
    \\    // The app's extensions, as far as Zig exposes them
    \\    // (oriel.extensions.expose): JSON in, JSON out. Native events come as
    \\    // `extension:<name>` with { name, data }.
    \\    extensions: Object.freeze({
    \\      call(name, method, payload) {
    \\        return invoke("extensions:call", { name, method, payload: payload === undefined ? null : payload });
    \\      },
    \\      on(name, callback) {
    \\        return window.oriel.listen("extension:" + name, callback);
    \\      },
    \\    }),
    \\    // oriel.camera (features.camera): resolves to { dataUrl, width, height, mime }.
    \\    camera: Object.freeze({
    \\      capturePhoto(options) {
    \\        return invoke("camera:capture", options || {});
    \\      },
    \\    }),
++ @import("../modules/system_ai/bridge.zig").js ++
    \\    deepLink: Object.freeze({
    \\      current() {
    \\        return invoke("deep_link:current", {});
    \\      },
    \\    }),
    \\    share: Object.freeze({
    \\      // A received file (from share:received's files, or its handle) as a File.
    \\      async file(f) {
    \\        const info = typeof f === "number" ? { handle: f } : f;
    \\        const chunk = 4 << 20, parts = [];
    \\        for (let offset = 0; ; ) {
    \\          const bin = atob(await invoke("share:read", { handle: info.handle, offset, length: chunk }));
    \\          const bytes = new Uint8Array(bin.length);
    \\          for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    \\          parts.push(bytes);
    \\          offset += bytes.length;
    \\          if (bytes.length < chunk) break;
    \\        }
    \\        return new File(parts, info.name || "file", { type: info.mime || "" });
    \\      },
    \\      // Opens the system share sheet: { title, text, url, files: [File | Blob |
    \\      // a received file | its handle], anchor }. Resolves { completed, target }.
    \\      async send(item = {}) {
    \\        const files = [];
    \\        for (const f of item.files || []) {
    \\          if (typeof f === "number") { files.push({ handle: f }); continue; }
    \\          if (!(f instanceof Blob)) { files.push({ handle: f.handle }); continue; }
    \\          const u = new Uint8Array(await f.arrayBuffer());
    \\          let bin = "";
    \\          for (let i = 0; i < u.length; i += 0x8000) bin += String.fromCharCode.apply(null, u.subarray(i, i + 0x8000));
    \\          files.push({ name: f.name || "file", data: btoa(bin) });
    \\        }
    \\        return new Promise((resolve, reject) => {
    \\          let set = listeners.get("share:sent");
    \\          if (!set) listeners.set("share:sent", (set = new Set()));
    \\          const cb = (r) => { set.delete(cb); resolve(r); };
    \\          set.add(cb);
    \\          Promise.resolve(invoke("share:send", { title: item.title, text: item.text, url: item.url, files, anchor: item.anchor }))
    \\            .catch((err) => { set.delete(cb); reject(err); });
    \\        });
    \\      },
    \\      capabilities() {
    \\        return invoke("share:capabilities", {});
    \\      },
    \\    }),
    \\    __emit(event, payload) {
    \\      const set = listeners.get(event);
    \\      if (set && set.size > 0) {
    \\        for (const cb of set) {
    \\          try { cb(payload); } catch (e) { console.error(e); }
    \\        }
    \\      } else if (event === "deep-link") {
    \\        // Only deep links wait for a listener (e.g. across a reload); the
    \\        // native side queues them until the first listen(). Capped.
    \\        let queued = pendingEvents.get(event);
    \\        if (!queued) pendingEvents.set(event, (queued = []));
    \\        queued.push(payload);
    \\        if (queued.length > 16) queued.shift();
    \\      }
    \\    },
    \\    window: Object.freeze(windowApi),
    \\  }) });
    \\  // <div data-oriel-drag-region> moves the window when pressed (its buttons,
    \\  // fields and links, and anything under data-oriel-no-drag, keep their clicks).
    \\  window.addEventListener("mousedown", (e) => {
    \\    if (e.button !== 0 || !(e.target instanceof Element)) return;
    \\    if (!e.target.closest("[data-oriel-drag-region]")) return;
    \\    if (e.target.closest("button, input, textarea, select, a, [contenteditable], [data-oriel-no-drag]")) return;
    \\    e.preventDefault();
    \\    Promise.resolve(windowApi.current().startDragging()).catch(() => {});
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
    }
}
