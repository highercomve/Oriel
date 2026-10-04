//! The WebView2 bridge script (`window.oriel`), in a file of its own so the
//! Android bridge can derive its script from it without importing the
//! Windows backend.

const target = @import("../../core/target.zig");

/// Replaced by `ipc.tokenScript` (which defines `const ipcToken`).
pub const token_placeholder = "/*__ORIEL_IPC_TOKEN__*/";
/// Replaced by `isolation.bridgeScript` (which defines `invoke`).
pub const isolation_placeholder = "/*__ORIEL_ISOLATION__*/";

/// Injected into allowed pages before their own scripts run.
pub const bridge_js =
    \\(() => {
    \\  const listeners = new Map();
    \\  const pending = new Map();
    \\  const pendingEvents = new Map();
    \\  let nextId = 1;
    \\
++ token_placeholder ++
    \\
    \\  window.chrome.webview.addEventListener('message', (event) => {
    \\    const data = event.data;
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
    \\      window.chrome.webview.postMessage(JSON.stringify(Object.assign({ id, token: ipcToken }, msg)));
    \\    });
    \\  }
    \\  function rawInvoke(cmd, args) {
    \\    return send({ cmd, args: args ?? null });
    \\  }
    \\  function sendSealed(iso) {
    \\    return send({ cmd: "oriel:isolated", iso });
    \\  }
    \\
++ isolation_placeholder ++
    \\
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
++ " " ++ target.platform_js ++ ",\n" ++
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
    \\      }
    \\      return () => set.delete(callback);
    \\    },
    \\    openExternal(url) {
    \\      return this.invoke("open_external", { url });
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
    \\    deepLink: Object.freeze({
    \\      current() {
    \\        return invoke("deep_link:current", {});
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
    \\})();
;
