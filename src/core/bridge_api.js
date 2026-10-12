// The page API, `window.oriel`: one definition for both renderers. The
// WebView bridge (src/core/bridge_js.zig) splices this file into its
// script, without the `export` line; the native renderer
// (src/native_ui/js/src/main.js) imports it into its bundle. Each supplies
// only its transport:
//   invoke(cmd, args) → Promise      the command channel
//   listeners: Map<event, Set<fn>>   shared with the transport (and the
//                                    permission and share replies here)
//   pendingEvents: Map<event, []>    deep links that came before a listener
//   platform, features               frozen objects: oriel.platform/features
//   label() → string                 this window's label
// Keep it plain ES2020 that every WebView runs: no imports, no globals but
// the page's own (Blob, File, atob, btoa, console, Promise).
function orielApi({ invoke, listeners, pendingEvents, platform, features, label }) {
  function listen(event, callback) {
    let set = listeners.get(event);
    if (!set) listeners.set(event, (set = new Set()));
    set.add(callback);
    const queued = pendingEvents.get(event);
    if (queued && queued.length > 0) {
      pendingEvents.delete(event);
      for (const payload of queued) {
        try { callback(payload); } catch (e) { console.error(e); }
      }
    }
    if (event === "deep-link" || event === "notification:action" || event === "share:received" || event === "lifecycle" || event.startsWith("extension:")) {
      // Deep links, notification clicks and shares that came before the
      // page listened (one that launched the app); lifecycle and app
      // extension events from before it loaded.
      try { Promise.resolve(invoke("events:ready", { event })).catch(() => {}); } catch (_) {}
    }
    return () => set.delete(callback);
  }
  const toBase64 = (bytes) => {
    let bin = "";
    for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(bin);
  };

  class WindowHandle {
    constructor(label) {
      this.label = label;
    }
    close() { return invoke("oriel:window:close", { label: this.label }); }
    show() { return invoke("oriel:window:show", { label: this.label }); }
    hide() { return invoke("oriel:window:hide", { label: this.label }); }
    focus() { return invoke("oriel:window:focus", { label: this.label }); }
    setTitle(title) { return invoke("oriel:window:setTitle", { label: this.label, title }); }
    setSize(width, height) { return invoke("oriel:window:setSize", { label: this.label, width, height }); }
    maximize(maximized = true) { return invoke("oriel:window:maximize", { label: this.label, maximized }); }
    fullscreen(fullscreen = true) { return invoke("oriel:window:fullscreen", { label: this.label, fullscreen }); }
    startDragging() { return invoke("oriel:window:startDragging", { label: this.label }); }
    emit(event, payload) { return windowApi.emitTo(this.label, event, payload); }
  }
  const windowApi = {
    async open(options) {
      const res = await invoke("oriel:window:open", options);
      return new WindowHandle(res.label);
    },
    current() {
      return new WindowHandle(label() || "main");
    },
    async get(label) {
      const res = await invoke("oriel:window:get", { label });
      return res ? new WindowHandle(res.label) : null;
    },
    async all() {
      const list = await invoke("oriel:window:all", {});
      return (list || []).map((w) => new WindowHandle(w.label));
    },
    emitTo(label, event, payload) {
      return invoke("oriel:window:emitTo", { label, event, payload: payload ?? null });
    },
  };

  return Object.freeze({
    platform,
    features,
    invoke,
    listen,
    openExternal(url) {
      return invoke("open_external", { url });
    },
    permissions: Object.freeze({
      query(name) {
        return invoke("permissions:query", { name });
      },
      // Resolves the status once the user answered (a "permission-changed"
      // event), or at once when there was nothing to ask.
      request(name) {
        return new Promise((resolve, reject) => {
          const off = listen("permission-changed", (e) => { if (e && e.name === name) { off(); resolve(e.status); } });
          Promise.resolve(invoke("permissions:request", { name })).then((s) => {
            if (s !== "prompt") { off(); resolve(s); }
          }, (err) => { off(); reject(err); });
        });
      },
      openSettings(name) {
        return invoke("permissions:open_settings", { name });
      },
    }),
    // { type: "background" | "foreground" | "memory_pressure" | "suspend" |
    // "resume" | "terminating", level: "moderate" | "critical" | null }.
    lifecycle: Object.freeze({
      on(callback) {
        return listen("lifecycle", callback);
      },
    }),
    // The app's extensions, as far as Zig exposes them
    // (oriel.extensions.expose): JSON in, JSON out. Native events come as
    // `extension:<name>` with { name, data }.
    extensions: Object.freeze({
      call(name, method, payload) {
        return invoke("extensions:call", { name, method, payload: payload === undefined ? null : payload });
      },
      on(name, callback) {
        return listen("extension:" + name, callback);
      },
    }),
    // The device's own model (oriel.system_ai): Gemini Nano on Android,
    // Foundation Models on iOS 26+. Tokens stream as "system_ai:token"
    // ({ text }), download progress as "system_ai:download".
    systemAi: Object.freeze({
      status() {
        return invoke("system_ai:status", {});
      },
      capabilities() {
        return invoke("system_ai:capabilities", {});
      },
      download(onProgress) {
        const off = onProgress ? listen("system_ai:download", onProgress) : null;
        return Promise.resolve(invoke("system_ai:download", {})).finally(() => off && off());
      },
      async generate(request, onToken) {
        const b64 = async (data) => {
          if (typeof data === "string") return data;
          return toBase64(data instanceof Blob ? new Uint8Array(await data.arrayBuffer()) : data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength));
        };
        const images = [];
        for (const img of request.images || []) images.push({ data: await b64(img.data), mime: img.mime || (img.data && img.data.type) || "image/jpeg" });
        const schema = request.schema == null || typeof request.schema === "string" ? request.schema : JSON.stringify(request.schema);
        const off = onToken ? listen("system_ai:token", (e) => onToken(e.text)) : null;
        try {
          return await invoke("system_ai:generate", { system: request.system || "", prompt: request.prompt, images, temperature: request.temperature, maxTokens: request.maxTokens, schema });
        } finally {
          if (off) off();
        }
      },
      cancel() {
        return invoke("system_ai:cancel", {});
      },
    }),
    // oriel.camera (features.camera): resolves to { dataUrl, width, height, mime }.
    camera: Object.freeze({
      capturePhoto(options) {
        return invoke("camera:capture", options || {});
      },
    }),
    deepLink: Object.freeze({
      current() {
        return invoke("deep_link:current", {});
      },
    }),
    // Where a dropped file lives now, for a trusted app that sends it on
    // (docs/drag-and-drop.md): a path string, or null when the file is
    // gone or changed, or has no drop handle (only the native renderer's
    // dropped Files carry `handle`; a WebView's never do).
    drop: Object.freeze({
      async path(f) {
        const handle = typeof f === "number" ? f : f && f.handle;
        if (typeof handle !== "number") return null;
        return invoke("drop:path", { handle });
      },
    }),
    share: Object.freeze({
      // A received file (from share:received's files, or its handle) as a File.
      async file(f) {
        const info = typeof f === "number" ? { handle: f } : f;
        const chunk = 4 << 20, parts = [];
        for (let offset = 0; ;) {
          const bin = atob(await invoke("share:read", { handle: info.handle, offset, length: chunk }));
          const bytes = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          parts.push(bytes);
          offset += bytes.length;
          if (bytes.length < chunk) break;
        }
        return new File(parts, info.name || "file", { type: info.mime || "" });
      },
      // Opens the system share sheet: { title, text, url, files: [File | Blob |
      // a received file | its handle], anchor }. Resolves { completed, target }.
      async send(item = {}) {
        const files = [];
        for (const f of item.files || []) {
          if (typeof f === "number") { files.push({ handle: f }); continue; }
          if (!(f instanceof Blob)) { files.push({ handle: f.handle }); continue; }
          files.push({ name: f.name || "file", data: toBase64(new Uint8Array(await f.arrayBuffer())) });
        }
        return new Promise((resolve, reject) => {
          const off = listen("share:sent", (r) => { off(); resolve(r); });
          Promise.resolve(invoke("share:send", { title: item.title, text: item.text, url: item.url, files, anchor: item.anchor }))
            .catch((err) => { off(); reject(err); });
        });
      },
      capabilities() {
        return invoke("share:capabilities", {});
      },
    }),
    // The transport's way in: an event from Zig for the page's listeners.
    __emit(event, payload) {
      const set = listeners.get(event);
      if (set && set.size > 0) {
        for (const cb of set) {
          try { cb(payload); } catch (e) { console.error(e); }
        }
      } else if (event === "deep-link") {
        // Only deep links wait for a listener (e.g. across a reload); the
        // native side queues them until the first listen(). Capped.
        let queued = pendingEvents.get(event);
        if (!queued) pendingEvents.set(event, (queued = []));
        queued.push(payload);
        if (queued.length > 16) queued.shift();
      }
    },
    window: Object.freeze(windowApi),
  });
}
export { orielApi };
