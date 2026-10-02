// Oriel's native renderer, JavaScript side (docs/native-renderer.md).
//
// Runs in QuickJS. The Zig side provides `__host`:
//   log(level, text)            asset(path) → text | undefined
//   invoke(id, cmd, argsJson)   → later __oriel.resolve(id, ok, json)
//   timer(id, ms)               → later __oriel.timer(id)
//   ops(json)                   the frame's operations (render.js)
//   frame(id) → [x, y, w, h]    a node's last layout, in window coordinates
//   evalScript(name, code)      run a page script at the top level
//   evalModule(name, code)      run a module script (imports load from the assets) → promise
//   focus(id), scrollIntoView(id, block), scrollTo(id, y)
//   platform (JSON), label (the window's label), url (the window's URL)
// and calls `__oriel.boot()`, then `__oriel.event/timer/resolve/resize`;
// after each call it runs the pending jobs and `__oriel.render()`.

import { parseHTML } from "linkedom";
import { StyleEngine, viewport, mediaMatches } from "./css.js";
import { Renderer, UA_CSS } from "./render.js";
import * as canvas from "./canvas.js";

const host = globalThis.__host;

// ---------------------------------------------------------------------------
// console

const fmt = (args) => args.map((a) => {
  if (a instanceof Error) return `${a.name}: ${a.message}\n${a.stack || ""}`;
  if (typeof a === "object") { try { return JSON.stringify(a); } catch { return String(a); } }
  return String(a);
}).join(" ");
globalThis.console = {
  log: (...a) => host.log(1, fmt(a)), info: (...a) => host.log(1, fmt(a)), debug: (...a) => host.log(0, fmt(a)),
  warn: (...a) => host.log(2, fmt(a)), error: (...a) => host.log(3, fmt(a)),
};

// ---------------------------------------------------------------------------
// Timers

const timers = new Map();
let timerSeq = 1;
function setTimer(fn, ms, args, repeat) {
  const id = timerSeq++;
  timers.set(id, { fn, ms: Math.max(0, +ms || 0), args, repeat });
  host.timer(id, Math.max(0, +ms || 0));
  return id;
}
globalThis.setTimeout = (fn, ms, ...args) => setTimer(fn, ms, args, false);
globalThis.setInterval = (fn, ms, ...args) => setTimer(fn, Math.max(4, +ms || 0), args, true);
globalThis.clearTimeout = globalThis.clearInterval = (id) => { timers.delete(id); };
globalThis.requestAnimationFrame = (cb) => setTimer(() => cb(performance.now()), 16, [], false);
globalThis.cancelAnimationFrame = globalThis.clearTimeout;
globalThis.queueMicrotask ??= (fn) => Promise.resolve().then(fn);
const t0 = Date.now();
globalThis.performance ??= { now: () => Date.now() - t0 };

// ---------------------------------------------------------------------------
// The document

const html = normalizeHtml(host.asset("index.html") || "<!doctype html><html><body></body></html>");
const { window: dom, document } = parseHTML(html);

// Browsers add the <html>, <head> and <body> a page leaves out; linkedom
// doesn't (it made <meta> the root, and the content no body). The leading
// head elements go in the head, the rest in the body.
function normalizeHtml(src) {
  if (/<body[\s>]/i.test(src)) return src;
  let s = src.replace(/^\s*<!doctype[^>]*>/i, "").replace(/^\s*<html[^>]*>/i, "").replace(/<\/html>\s*$/i, "");
  let head = "";
  const headRe = /^\s*(<!--[\s\S]*?-->|<head\b[^>]*>[\s\S]*?<\/head>|<(?:meta|link|base)\b[^>]*>|<title\b[^>]*>[\s\S]*?<\/title>|<style\b[^>]*>[\s\S]*?<\/style>|<script\b[^>]*>[\s\S]*?<\/script>)/i;
  for (let m; (m = headRe.exec(s)); s = s.slice(m[0].length)) head += m[1].replace(/^<head\b[^>]*>|<\/head>$/gi, "");
  return `<!doctype html><html><head>${head}</head><body>${s}</body></html>`;
}

const g = globalThis;
g.document = document;
g.window = g;
g.self = g;
for (const name of ["Node", "Element", "HTMLElement", "Text", "Comment", "DocumentFragment", "Event", "CustomEvent",
  "EventTarget", "MutationObserver", "DOMParser", "HTMLInputElement", "HTMLTextAreaElement", "HTMLSelectElement",
  "HTMLButtonElement", "HTMLAnchorElement", "SVGElement", "Range", "TreeWalker", "NodeFilter", "HTMLTemplateElement",
  "DocumentType", "Attr", "CharacterData", "HTMLOptionElement", "HTMLImageElement", "HTMLCanvasElement", "CanvasRenderingContext2D"]) {
  if (dom[name] !== undefined && g[name] === undefined) g[name] = dom[name];
}

// <canvas>: getContext records a program the backends replay (canvas.js).
// Its ops mean the page changed, like a style write does.
canvas.install(dom, () => {
  try { if (renderer) renderer.dirty = true; } catch {}
});
const Event = g.Event;
class KeyboardEvent extends Event {
  constructor(type, init = {}) {
    super(type, init);
    for (const k of ["key", "code", "shiftKey", "ctrlKey", "altKey", "metaKey", "repeat"]) this[k] = init[k] ?? (k.endsWith("Key") ? false : "");
    this.isComposing = false;
  }
}
class MouseEvent extends Event {
  constructor(type, init = {}) {
    super(type, init);
    for (const k of ["clientX", "clientY", "button", "shiftKey", "ctrlKey", "altKey", "metaKey"]) this[k] = init[k] ?? 0;
  }
}
g.KeyboardEvent = KeyboardEvent;
g.MouseEvent = g.PointerEvent = MouseEvent;
g.InputEvent = g.FocusEvent = g.UIEvent = Event;

// window events (hashchange, resize, keydown, contextmenu…).
const winListeners = new Map();
g.addEventListener = (type, fn) => { let s = winListeners.get(type); if (!s) winListeners.set(type, (s = new Set())); s.add(fn); };
g.removeEventListener = (type, fn) => winListeners.get(type)?.delete(fn);
g.dispatchEvent = (ev) => { fireWindow(ev); return !ev.defaultPrevented; };
function fireWindow(ev) {
  for (const fn of [...(winListeners.get(ev.type) || [])]) {
    try { fn.call(g, ev); } catch (e) { console.error(e); }
  }
}

// Mark elements that listen for clicks: they become touchable views.
const ET = Object.getPrototypeOf(Object.getPrototypeOf(document.body)).constructor.prototype;
for (let proto = Object.getPrototypeOf(document.body); proto; proto = Object.getPrototypeOf(proto)) {
  if (Object.prototype.hasOwnProperty.call(proto, "addEventListener")) {
    const orig = proto.addEventListener;
    proto.addEventListener = function (type, fn, opts) {
      if (type === "click" || type === "mousedown" || type === "pointerdown") { this.__listens = true; renderer && (renderer.dirty = true); }
      return orig.call(this, type, fn, opts);
    };
    break;
  }
}
void ET;

// el.style.x = … and style.setProperty(…) update the style attribute inside
// linkedom without a mutation record, so the renderer never saw them (a
// requestAnimationFrame loop writing bar heights didn't move). Each
// element's style is wrapped once: writes mark the page for a render.
{
  let proto = Object.getPrototypeOf(document.createElement("div"));
  let desc = null;
  while (proto && !(desc = Object.getOwnPropertyDescriptor(proto, "style"))) proto = Object.getPrototypeOf(proto);
  if (desc?.get) {
    const wrapped = new WeakMap();
    // try: a write before `let renderer` below has run (TDZ) is ignored.
    const touch = () => { try { if (renderer) renderer.dirty = true; } catch {} };
    Object.defineProperty(proto, "style", {
      configurable: true,
      get() {
        const real = desc.get.call(this);
        if (!real || typeof real !== "object") return real;
        let w = wrapped.get(real);
        if (!w) {
          w = new Proxy(real, {
            set(t, k, v) { t[k] = v; touch(); return true; },
            get(t, k) {
              const v = t[k];
              if (k === "setProperty" || k === "removeProperty") return (...a) => { const r = v.apply(t, a); touch(); return r; };
              return typeof v === "function" ? v.bind(t) : v;
            },
          });
          wrapped.set(real, w);
        }
        return w;
      },
      set(v) { desc.set ? desc.set.call(this, v) : this.setAttribute("style", String(v)); touch(); },
    });
  }
}

// checked reflects the attribute (so :checked styles follow it).
const inputProto = Object.getPrototypeOf(document.createElement("input"));
Object.defineProperty(inputProto, "checked", {
  get() { return this.hasAttribute("checked"); },
  set(v) { if (v) this.setAttribute("checked", ""); else this.removeAttribute("checked"); },
  configurable: true,
});
Object.defineProperty(inputProto, "disabled", {
  get() { return this.hasAttribute("disabled"); },
  set(v) { if (v) this.setAttribute("disabled", ""); else this.removeAttribute("disabled"); },
  configurable: true,
});
for (const tag of ["button", "textarea", "select"]) {
  const proto = Object.getPrototypeOf(document.createElement(tag));
  if (!Object.getOwnPropertyDescriptor(proto, "disabled")?.set) {
    Object.defineProperty(proto, "disabled", {
      get() { return this.hasAttribute("disabled"); },
      set(v) { if (v) this.setAttribute("disabled", ""); else this.removeAttribute("disabled"); },
      configurable: true,
    });
  }
}

// Forms: requestSubmit() fires `submit` (cancelable); submit() doesn't.
const formProto = Object.getPrototypeOf(document.createElement("form"));
formProto.requestSubmit = function () { submit(this); };
formProto.submit = function () {};
formProto.reset = function () {
  for (const f of this.querySelectorAll("input, textarea")) f.value = f.getAttribute("value") || "";
};

// Layout reads, from the native layout.
const elProto = Object.getPrototypeOf(Object.getPrototypeOf(document.createElement("div")));
const frameOf = (el) => (renderer && host.frame(renderer.idOf(el, "el"))) || [0, 0, 0, 0];
Object.defineProperties(elProto, {
  offsetWidth: { get() { return frameOf(this)[2]; }, configurable: true },
  offsetHeight: { get() { return frameOf(this)[3]; }, configurable: true },
  clientWidth: { get() { return frameOf(this)[2]; }, configurable: true },
  clientHeight: { get() { return frameOf(this)[3]; }, configurable: true },
  scrollHeight: { get() { const f = frameOf(this); return f[4] ?? f[3]; }, configurable: true },
  offsetTop: { get() { return frameOf(this)[1]; }, configurable: true },
  offsetLeft: { get() { return frameOf(this)[0]; }, configurable: true },
  scrollTop: { get() { return 0; }, set(y) { renderer && host.scrollTo(renderer.idOf(this, "el"), +y || 0); }, configurable: true },
});
elProto.getBoundingClientRect = function () {
  const [x, y, w, h] = frameOf(this);
  return { x, y, left: x, top: y, width: w, height: h, right: x + w, bottom: y + h };
};
elProto.focus = function () {
  document.__active = this;
  if (renderer) { renderer.render(); host.focus(renderer.idOf(this, "el")); }
};
elProto.blur = function () { if (document.__active === this) document.__active = null; };
elProto.scrollIntoView = function (opts) {
  if (!renderer) return;
  const block = typeof opts === "object" ? opts.block || "start" : opts === false ? "end" : "start";
  // Changes not rendered yet: scroll after the next render, rather than
  // render now. It returns nothing, so the page can't tell, and a page that
  // keeps scrolling to its newest line (a chat streaming tokens) doesn't
  // render the whole document once per token.
  if (renderer.dirty) { renderer.pendingScroll = { el: this, block }; return; }
  host.scrollIntoView(renderer.idOf(this, "el"), block);
};
// linkedom defines its own click() on HTMLElement.prototype (one level
// below elProto), which only fires the event: replace it there too, so a
// page's el.click() also submits forms, follows links and toggles boxes.
Object.getPrototypeOf(document.createElement("div")).click = elProto.click = function () { activate(this, 0); };
// The page scrolls in the window's scroll view (node -1, render.js):
// window.scrollTo(x, y) and scrollTo({ top }).
g.scrollTo = g.scroll = (x, y) => {
  const top = typeof x === "object" && x !== null ? x.top : y;
  if (renderer && top !== undefined) { renderer.render(); host.scrollTo(-1, +top || 0); }
};
// The focused element; it carries data-nui-focus, which the style engine
// matches for :focus (css.js).
let active = null;
Object.defineProperty(document, "__active", {
  get() { return active; },
  set(el) {
    if (el === active) return;
    active?.removeAttribute?.("data-nui-focus");
    active = el || null;
    active?.setAttribute?.("data-nui-focus", "");
  },
  configurable: true,
});
Object.defineProperty(document, "activeElement", { get() { return this.__active || this.body; }, configurable: true });

// ---------------------------------------------------------------------------
// location, history, matchMedia, storage, navigator

// The window's own URL ("index.html#/settings", "index.html?second=1"): its
// query and fragment, as a WebView window loading that URL would see them.
const startUrl = String(host.url || "");
const hashAt = startUrl.indexOf("#");
let hash = hashAt >= 0 ? startUrl.slice(hashAt) : "";
const beforeHash = hashAt >= 0 ? startUrl.slice(0, hashAt) : startUrl;
let search = beforeHash.indexOf("?") >= 0 ? beforeHash.slice(beforeHash.indexOf("?")) : "";
if (hash === "#") hash = "";
const fireHash = () => setTimeout(() => fireWindow(new Event("hashchange")), 0);
// Text selection: native fields keep their own; the page has none to read
// (an empty, collapsed selection, as in a browser with nothing selected).
const emptySelection = () => ({
  isCollapsed: true, rangeCount: 0, type: "None", anchorNode: null, focusNode: null,
  toString() { return ""; }, removeAllRanges() {}, addRange() {}, getRangeAt() { throw new RangeError("No range"); },
  collapse() {}, selectAllChildren() {}, containsNode() { return false; },
});
g.getSelection = emptySelection;
if (typeof document !== "undefined" && !document.getSelection) document.getSelection = emptySelection;

g.location = {
  get hash() { return hash; },
  set hash(v) { v = String(v); if (v && !v.startsWith("#")) v = "#" + v; if (v !== hash) { hash = v; history.push(v); fireHash(); } },
  get search() { return search; },
  get href() { return `app://localhost/index.html${search}${hash}`; },
  set href(v) { const i = String(v).indexOf("#"); if (i >= 0) this.hash = String(v).slice(i); },
  get pathname() { return "/index.html"; },
  get origin() { return "app://localhost"; },
  get protocol() { return "app:"; },
  get host() { return "localhost"; },
  replace(v) { const i = String(v).indexOf("#"); if (i >= 0) { const nv = String(v).slice(i); if (nv !== hash) { hash = nv; fireHash(); } } },
  assign(v) { this.href = v; },
  reload() {},
  toString() { return this.href; },
};
const history = [];
g.history = {
  get length() { return history.length + 1; },
  back() { history.pop(); const v = history[history.length - 1] || ""; if (v !== hash) { hash = v; fireHash(); } },
  pushState() {}, replaceState() {}, go() {}, forward() {},
};
// Links like <a href="#chat"> point the tabs at their sections.
for (const a of document.querySelectorAll("a[href]")) {
  Object.defineProperty(a, "hash", { get() { const h = this.getAttribute("href") || ""; const i = h.indexOf("#"); return i >= 0 ? h.slice(i) : ""; }, configurable: true });
}
const aProto = Object.getPrototypeOf(document.createElement("a"));
if (!Object.getOwnPropertyDescriptor(aProto, "hash")) {
  Object.defineProperty(aProto, "hash", { get() { const h = this.getAttribute("href") || ""; const i = h.indexOf("#"); return i >= 0 ? h.slice(i) : ""; }, configurable: true });
}

const mediaLists = new Set();
g.matchMedia = (q) => {
  const ml = {
    media: q,
    get matches() { return mediaMatches(q.replace(/^\s*(only\s+)?(screen|all)\s+and\s+/, "")); },
    listeners: new Set(),
    addEventListener(_t, fn) { this.listeners.add(fn); mediaLists.add(this); },
    removeEventListener(_t, fn) { this.listeners.delete(fn); },
    addListener(fn) { this.addEventListener("change", fn); },
    removeListener(fn) { this.removeEventListener("change", fn); },
  };
  return ml;
};
const store = (name) => {
  const m = new Map();
  return {
    getItem: (k) => (m.has(String(k)) ? m.get(String(k)) : null),
    setItem: (k, v) => { m.set(String(k), String(v)); },
    removeItem: (k) => { m.delete(String(k)); },
    clear: () => m.clear(),
    key: (i) => [...m.keys()][i] ?? null,
    get length() { return m.size; },
    name,
  };
};
g.localStorage = store("local");
g.sessionStorage = store("session");
const platform = JSON.parse(host.platform || "{}");
g.navigator = { userAgent: `Oriel native (${platform.os || "unknown"})`, platform: platform.os || "", language: "en-US", languages: ["en-US"], clipboard: undefined, maxTouchPoints: viewport.coarse ? 5 : 0 };
Object.defineProperty(g, "innerWidth", { get: () => viewport.width });
Object.defineProperty(g, "innerHeight", { get: () => viewport.height });
g.devicePixelRatio = 1;
g.getComputedStyle = (el) => {
  const cs = renderer?.cs.get(el) || {};
  return new Proxy({}, { get: (_, k) => (k === "getPropertyValue" ? (p) => cs[p] ?? "" : cs[String(k).replace(/[A-Z]/g, (c) => "-" + c.toLowerCase())] ?? "") });
};
g.ResizeObserver ??= class { observe() {} unobserve() {} disconnect() {} };
g.IntersectionObserver ??= class { observe() {} unobserve() {} disconnect() {} };
if (typeof g.URLSearchParams === "undefined") {
  g.URLSearchParams = class {
    constructor(s = "") { this.m = new Map(String(s).replace(/^\?/, "").split("&").filter(Boolean).map((p) => p.split("=").map(decodeURIComponent))); }
    has(k) { return this.m.has(k); }
    get(k) { return this.m.has(k) ? this.m.get(k) : null; }
  };
}

// ---------------------------------------------------------------------------
// window.oriel: the same API as the WebView bridge

const pending = new Map();
let callSeq = 1;
function invoke(cmd, args) {
  return new Promise((resolve, reject) => {
    const id = callSeq++;
    pending.set(id, { resolve, reject });
    host.invoke(id, String(cmd), JSON.stringify(args ?? null));
  });
}
const listeners = new Map();
const pendingEvents = new Map();
class WindowHandle {
  constructor(label) { this.label = label; }
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
  async open(options) { const res = await invoke("oriel:window:open", options); return new WindowHandle(res.label); },
  current() { return new WindowHandle(host.label || "main"); },
  async get(label) { const res = await invoke("oriel:window:get", { label }); return res ? new WindowHandle(res.label) : null; },
  async all() { const list = await invoke("oriel:window:all", {}); return (list || []).map((w) => new WindowHandle(w.label)); },
  emitTo(label, event, payload) { return invoke("oriel:window:emitTo", { label, event, payload: payload ?? null }); },
};
g.oriel = Object.freeze({
  platform: Object.freeze(platform),
  native: true,
  invoke,
  listen(event, callback) {
    let set = listeners.get(event);
    if (!set) listeners.set(event, (set = new Set()));
    set.add(callback);
    const queued = pendingEvents.get(event);
    if (queued?.length) { pendingEvents.delete(event); for (const p of queued) { try { callback(p); } catch (e) { console.error(e); } } }
    if (event === "deep-link") invoke("deep_link:ready", {}).catch(() => {});
    return () => set.delete(callback);
  },
  openExternal(url) { return invoke("open_external", { url }); },
  permissions: Object.freeze({
    query(name) { return invoke("permissions:query", { name }); },
    request(name) {
      return new Promise((resolve, reject) => {
        let set = listeners.get("permission-changed");
        if (!set) listeners.set("permission-changed", (set = new Set()));
        const cb = (e) => { if (e && e.name === name) { set.delete(cb); resolve(e.status); } };
        set.add(cb);
        invoke("permissions:request", { name }).then((s) => { if (s !== "prompt") { set.delete(cb); resolve(s); } }, (err) => { set.delete(cb); reject(err); });
      });
    },
    openSettings(name) { return invoke("permissions:open_settings", { name }); },
  }),
  deepLink: Object.freeze({ current() { return invoke("deep_link:current", {}); } }),
  __emit(event, payload) {
    const set = listeners.get(event);
    if (set?.size) { for (const cb of set) { try { cb(payload); } catch (e) { console.error(e); } } }
    else if (event === "deep-link") {
      let q = pendingEvents.get(event);
      if (!q) pendingEvents.set(event, (q = []));
      q.push(payload);
      if (q.length > 16) q.shift();
    }
  },
  window: Object.freeze(windowApi),
});

// ---------------------------------------------------------------------------
// Events from the native views

// A click: the event, then the browser's default action.
function activate(el, flags) {
  const ev = new MouseEvent("click", { bubbles: true, cancelable: true, shiftKey: !!(flags & 1), ctrlKey: !!(flags & 2) });
  el.dispatchEvent(ev);
  if (ev.defaultPrevented) return;
  for (let n = el; n && n.nodeType === 1; n = n.parentNode) {
    const tag = n.localName;
    if (tag === "a") {
      const href = n.getAttribute("href") || "";
      if (href.startsWith("#")) location.hash = href;
      else if (/^https?:|^mailto:/.test(href)) g.oriel.openExternal(href).catch(() => {});
      return;
    }
    if (tag === "label") {
      const ctl = n.htmlFor ? document.getElementById(n.getAttribute("for")) : n.querySelector("input, textarea, select");
      if (ctl && ctl !== el && !ctl.contains?.(el)) {
        if (ctl.localName === "input" && /checkbox|radio/.test(ctl.getAttribute("type") || "")) toggle(ctl);
        else ctl.focus();
      }
      return;
    }
    if (tag === "input" && /checkbox|radio/.test(n.getAttribute("type") || "")) { toggle(n); return; }
    if (tag === "button") {
      if (n.hasAttribute("disabled")) return;
      const type = (n.getAttribute("type") || "submit").toLowerCase();
      const form = n.closest("form");
      if (type === "submit" && form) submit(form);
      return;
    }
  }
}
function toggle(input) {
  if (input.hasAttribute("disabled")) return;
  if (input.getAttribute("type") === "radio") input.checked = true;
  else input.checked = !input.checked;
  input.dispatchEvent(new Event("input", { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
}
function submit(form) {
  const ev = new Event("submit", { bubbles: true, cancelable: true });
  form.dispatchEvent(ev);
}

function keyEvent(el, data) {
  const [key, flags] = data;
  const init = { key, code: key, bubbles: true, cancelable: true, shiftKey: !!(flags & 1), ctrlKey: !!(flags & 2), altKey: !!(flags & 4), metaKey: !!(flags & 8) };
  const ev = new KeyboardEvent("keydown", init);
  (el || document.body).dispatchEvent(ev);
  if (!ev.defaultPrevented) fireWindow(ev);
  // Enter in a one-line field submits its form.
  if (!ev.defaultPrevented && key === "Enter" && el?.localName === "input") {
    const form = el.closest("form");
    if (form) { submit(form); return true; }
  }
  return ev.defaultPrevented;
}

let renderer = null;

// :hover and :active: an attribute on the element and its ancestors.
const marked = new Map(); // attribute → the elements that have it
function markChain(attr, el) {
  const next = [];
  for (let n = el; n && n.nodeType === 1; n = n.parentNode) next.push(n);
  const prev = marked.get(attr) || [];
  if (prev.length === next.length && prev.every((x, i) => x === next[i])) return;
  for (const n of prev) if (!next.includes(n)) n.removeAttribute(attr);
  for (const n of next) if (!prev.includes(n)) n.setAttribute(attr, "");
  marked.set(attr, next);
}

// The pointer moved from element `from` to `to` (either may be null): the
// events a browser fires, so React's onMouseEnter/onMouseLeave (built from
// bubbling mouseover/mouseout and their relatedTarget) and plain
// mouseenter/mouseleave listeners run.
function hoverEvents(from, to) {
  if (from === to) return;
  const chain = (n) => { const out = []; for (; n && n.nodeType === 1; n = n.parentNode) out.push(n); return out; };
  const fromChain = chain(from), toChain = chain(to);
  const fire = (target, type, bubbles, related) => {
    if (!target) return;
    const ev = new Event(type, { bubbles, cancelable: bubbles });
    Object.defineProperty(ev, "relatedTarget", { value: related, configurable: true });
    for (const k of ["clientX", "clientY", "pageX", "pageY", "screenX", "screenY", "button", "buttons"]) Object.defineProperty(ev, k, { value: 0, configurable: true });
    target.dispatchEvent(ev);
  };
  for (const prefix of ["pointer", "mouse"]) {
    fire(from, prefix + "out", true, to);
    for (const n of fromChain) if (!toChain.includes(n)) fire(n, prefix + "leave", false, to);
    fire(to, prefix + "over", true, from);
    for (const n of [...toChain].reverse()) if (!fromChain.includes(n)) fire(n, prefix + "enter", false, from);
  }
}

// Inline handlers (onclick="…"): linkedom keeps them as attributes only.
// Each becomes a listener running the code with `event` and `this`, like a
// browser's; returning false prevents the default.
function bindInline(el) {
  const bound = (el.__inline ||= new Map());
  for (const attr of [...(el.attributes || [])]) {
    const name = attr.name.toLowerCase();
    if (!name.startsWith("on") || name.length < 3) continue;
    const type = name.slice(2);
    const old = bound.get(type);
    if (old && old.code === attr.value) continue;
    if (old) el.removeEventListener(type, old.fn);
    let compiled;
    try { compiled = new Function("event", attr.value); } catch (e) { console.error(`${name}: ${e}`); continue; }
    const fn = function (event) { if (compiled.call(el, event) === false) event.preventDefault(); };
    el.addEventListener(type, fn);
    bound.set(type, { code: attr.value, fn });
  }
}
function bindInlineHandlers(root) {
  bindInline(root);
  for (const el of root.querySelectorAll?.("*") || []) bindInline(el);
}

function guard(fn) {
  try { return fn(); } catch (e) { console.error(e); return false; }
}

g.__oriel = {
  boot(w, h, dark, coarse) {
    return guard(() => {
      Object.assign(viewport, { width: w, height: h, dark: !!dark, coarse: !!coarse });
      const engine = new StyleEngine();
      engine.addSheet(UA_CSS);
      for (const link of document.querySelectorAll('link[rel="stylesheet"][href], style')) {
        const css = link.localName === "style" ? link.textContent : host.asset(link.getAttribute("href").replace(/^\.?\//, ""));
        if (css) engine.addSheet(css);
        else console.warn(`stylesheet not found: ${link.getAttribute("href")}`);
      }
      renderer = new Renderer(document, engine, host);
      new MutationObserver(() => { renderer.dirty = true; }).observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
      // The page's scripts, in order, at the top level (like <script> tags).
      for (const s of document.querySelectorAll("script")) {
        const src = s.getAttribute("src");
        const code = src ? host.asset(src.replace(/^\.?\//, "")) : s.textContent;
        if (!code) { if (src) console.warn(`script not found: ${src}`); continue; }
        if (s.getAttribute("type") === "module") {
          // An ES module (Vite's output): its imports and import() load from
          // the app's assets; a failure shows up as a rejected promise.
          try {
            Promise.resolve(host.evalModule(src ? src.replace(/^\.?\//, "") : "inline.js", code)).catch((e) => console.error(e));
          } catch (e) { console.error(e); }
          continue;
        }
        // As a global script (not eval): top-level let/const are shared between scripts.
        try { host.evalScript(src || "inline", code); } catch (e) { console.error(e); }
      }
      bindInlineHandlers(document.documentElement);
      new MutationObserver((records) => {
        for (const r of records) {
          if (r.type === "attributes" && /^on/.test(r.attributeName || "")) bindInline(r.target);
          for (const n of r.addedNodes || []) if (n.nodeType === 1) bindInlineHandlers(n);
        }
      }).observe(document, { subtree: true, childList: true, attributes: true });
      document.dispatchEvent(new Event("DOMContentLoaded", { bubbles: true }));
      fireWindow(new Event("load"));
      return true;
    });
  },
  // A native event on node `id`. Returns true when the page prevented the default.
  event(id, type, data) {
    return guard(() => {
      const el = renderer?.elementFor(id);
      switch (type) {
        case "click": if (el) activate(el, data | 0); return false;
        case "input": {
          if (!el) return false;
          renderer.native.set(id, data);
          el.value = data;
          el.dispatchEvent(new Event("input", { bubbles: true }));
          return false;
        }
        case "change": {
          if (!el) return false;
          renderer.native.set(id, data);
          el.value = data;
          el.dispatchEvent(new Event("change", { bubbles: true }));
          return false;
        }
        case "key": return keyEvent(el || document.__active, data);
        case "focus": if (el) document.__active = el; return false;
        case "blur": if (el && document.__active === el) document.__active = null; return false;
        case "contextmenu": {
          const ev = new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: data[0], clientY: data[1] });
          (el || document.body).dispatchEvent(ev);
          if (!ev.defaultPrevented) fireWindow(ev);
          return ev.defaultPrevented;
        }
        // The system back button: true when the page went back.
        // The pointer over a node (or none), a press and its release: the
        // element and its ancestors match :hover and :active.
        case "hover": {
          const before = marked.get("data-nui-hover") || [];
          markChain("data-nui-hover", el);
          hoverEvents(before[0] || null, el || null);
          return false;
        }
        case "press": markChain("data-nui-active", el); return false;
        case "release": markChain("data-nui-active", null); return false;
        case "back": if (!history.length) return false; g.history.back(); return true;
      }
      return false;
    });
  },
  timer(id) {
    guard(() => {
      const t = timers.get(id);
      if (!t) return;
      if (t.repeat) host.timer(id, t.ms); else timers.delete(id);
      t.fn(...(t.args || []));
    });
  },
  resolve(id, ok, json) {
    guard(() => {
      const p = pending.get(id);
      if (!p) return;
      pending.delete(id);
      if (ok) p.resolve(json === undefined || json === "" ? null : JSON.parse(json));
      else p.reject(new Error(json || "command failed"));
    });
  },
  resize(w, h, dark) {
    guard(() => {
      const before = mediaSnapshot();
      Object.assign(viewport, { width: w, height: h, dark: !!dark });
      if (renderer) renderer.dirty = true;
      fireWindow(new Event("resize"));
      for (const ml of mediaLists) {
        const m = ml.matches;
        if (before.get(ml) !== m) for (const fn of ml.listeners) { try { fn({ matches: m, media: ml.media }); } catch (e) { console.error(e); } }
      }
    });
  },
  // A message for the page from a platform that posts JSON (Android's
  // events: {"__oriel_event": name, "payload": p}).
  message(m) {
    guard(() => {
      if (m && m.__oriel_event !== undefined) g.oriel.__emit(m.__oriel_event, m.payload);
    });
  },
  render() {
    guard(() => renderer?.render());
  },
  dirty() {
    if (renderer) renderer.dirty = true;
  },
};

function mediaSnapshot() {
  const m = new Map();
  for (const ml of mediaLists) m.set(ml, ml.matches);
  return m;
}
