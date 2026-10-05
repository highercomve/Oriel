// Oriel's native renderer, JavaScript side (docs/native-renderer.md).
//
// Runs in QuickJS. The Zig side provides `__host`:
//   log(level, text)            asset(path) → text | undefined
//   invoke(id, cmd, argsJson)   → later __oriel.resolve(id, ok, json)
//   timer(id, ms)               → later __oriel.timer(id)
//   ops(json)                   the frame's operations (render.js)
//   frame(id) → [x, y, w, h]    a node's last layout, in window coordinates
//   now()                       a monotonic clock in ms (performance.now)
//   vsync() → bool              __oriel.vsync(interval) at the display's next
//                               refresh; false: the backend can't (timers)
//   evalScript(name, code)      run a page script at the top level
//   evalModule(name, code)      run a module script (imports load from the assets) → promise
//   focus(id), scrollIntoView(id, block), scrollTo(id, y)
//   fileRead(reqId, handle, offset, length) → later __oriel.fileData(reqId,
//                               ArrayBuffer | null, errorName); fileRelease(handle)
//                               (a dropped file's bytes, blob.js; optional)
//   platform (JSON), label (the window's label), url (the window's URL)
// and calls `__oriel.boot()`, then `__oriel.event/timer/resolve/resize`;
// after each call it runs the pending jobs and `__oriel.render()`.

import { installURL } from "./url.js";
import { openDocument, STYLE_RECORDS, collect, markListens } from "#dom";
import { StyleEngine, viewport, mediaMatches, fontSpecs, splitRules, color as cssColor } from "./css.js";
import { snapBorder, isInputButton, withInputButtons, Renderer, UA_CSS, UA_CSS_WEBKIT, UA_CSS_MAC, UA_CSS_CHROME_ANDROID, uaCssWebkitGtk, setFocusVisible, setFocusRingOS } from "./render.js";
import * as canvas from "./canvas.js";
import { installBlob } from "./blob.js";
import { installDnd } from "./dnd.js";
import { EASES } from "./transitions.js";
// The runtime's own weak caches keyed by nodes: marked so their entries
// don't keep a node's wrapper from being replaced (a page's weak
// references do: dom/store.zig prune).
const internalWeak = (m) => (globalThis.__nuiDom?.internal?.(m), m);


const host = globalThis.__host;
// The runtime's alone: a page reaching it could run strings (evalScript)
// that its CSP refuses to eval. The functions that run text are kept here,
// off `host` too (the page may still meet `host` itself: a getter reading
// what the runtime reads).
delete globalThis.__host;
const hostRun = { script: host.evalScript, module: host.evalModule, handler: host.compileHandler };
delete host.evalScript;
delete host.evalModule;
delete host.compileHandler;

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
// A string is code, run at the top level when the timer fires (as an
// indirect eval: refused, and only logged, under a CSP without 'unsafe-eval').
const timerFn = (fn) => {
  if (typeof fn === "function") return fn;
  // Not a function (a string, a String): its text, as browsers take it.
  const code = String(fn);
  return () => { try { (0, eval)(code); } catch (e) { if (!(e instanceof EvalError)) throw e; } };
};
globalThis.setTimeout = (fn, ms, ...args) => setTimer(timerFn(fn), ms, args, false);
globalThis.setInterval = (fn, ms, ...args) => setTimer(timerFn(fn), Math.max(4, +ms || 0), args, true);
globalThis.clearTimeout = globalThis.clearInterval = (id) => { timers.delete(id); };
globalThis.queueMicrotask ??= (fn) => Promise.resolve().then(fn);
// performance.now(): host.now() is a monotonic clock with sub-millisecond
// resolution (Date.now() has whole milliseconds).
const t0 = host.now ? host.now() : Date.now();
globalThis.performance ??= { now: host.now ? () => host.now() - t0 : () => Date.now() - t0 };

// requestAnimationFrame: as in a browser, every callback asked for before a
// frame runs in that frame, with the same timestamp, and the page renders
// once after all of them. Frames follow the display where the backend can
// (host.vsync: GTK's frame clock…): a 120 Hz panel gets 120 a second, a
// hidden window none. Elsewhere they come at a steady 60 Hz (a grid of
// 16.7 ms slots, as a display's refresh), not 16 ms after the last frame's
// work; a frame whose work overruns its slot skips to the next one.
const FRAME_MS = 1000 / 60;
let rafCallbacks = new Map();
let rafSeq = 1;
let rafPending = false;
let lastSlot = -1;
function runFrame() {
  rafPending = false;
  // This frame's callbacks: one a render below asks for (a transition
  // starting) runs in the next frame, as in a browser.
  const due = rafCallbacks;
  rafCallbacks = new Map();
  try { renderer?.frameStart(); } catch (e) { console.error(e); }
  const now = performance.now();
  lastSlot = Math.max(lastSlot, Math.floor(now / FRAME_MS));
  for (const cb of due.values()) {
    try { cb(now); } catch (e) { console.error(e); }
  }
}
// Display frames (host.vsync); off for good once the backend says it can't.
let vsync = typeof host.vsync === "function";
globalThis.requestAnimationFrame = (cb) => {
  const id = rafSeq++;
  rafCallbacks.set(id, cb);
  if (!rafPending) {
    rafPending = true;
    if (vsync && host.vsync()) return id;
    vsync = false;
    const now = performance.now();
    const slot = Math.max(Math.floor(now / FRAME_MS) + 1, lastSlot + 1);
    setTimer(runFrame, Math.max(0, Math.ceil(slot * FRAME_MS - now)), [], false);
  }
  return id;
};
globalThis.cancelAnimationFrame = (id) => { rafCallbacks.delete(id); };
// The runtime's own frames (a key scroll's glide), out of the page's reach.
const nextFrame = globalThis.requestAnimationFrame;

// ---------------------------------------------------------------------------
// The document

const html = normalizeHtml(host.asset("index.html") || "<!doctype html><html><body></body></html>");
const { window: dom, document } = openDocument(html);

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
// Every element interface too: pages test `x instanceof
// x.ownerDocument.defaultView.HTMLIFrameElement` (React), and the native
// DOM's defaultView is the global.
for (const name of Object.keys(dom)) {
  if (/^(HTML|SVG)\w*Element$/.test(name) && g[name] === undefined) g[name] = dom[name];
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
    for (const k of ["key", "code", "shiftKey", "ctrlKey", "altKey", "metaKey", "repeat"]) this[k] = init[k] ?? (k.endsWith("Key") || k === "repeat" ? false : "");
    this.isComposing = false;
  }
}
class MouseEvent extends Event {
  constructor(type, init = {}) {
    super(type, init);
    for (const k of ["clientX", "clientY", "button", "buttons", "shiftKey", "ctrlKey", "altKey", "metaKey"]) this[k] = init[k] ?? 0;
    // The page doesn't scroll the window: page and screen coordinates are the client's.
    this.pageX = this.screenX = this.x = this.clientX;
    this.pageY = this.screenY = this.y = this.clientY;
  }
  // From the target's box, when asked (a layout read).
  get offsetX() { return this.clientX - (this.target?.getBoundingClientRect?.().left || 0); }
  get offsetY() { return this.clientY - (this.target?.getBoundingClientRect?.().top || 0); }
}
class PointerEvent extends MouseEvent {
  constructor(type, init = {}) {
    super(type, init);
    this.pointerId = init.pointerId ?? 1;
    this.pointerType = init.pointerType ?? "mouse";
    this.isPrimary = init.isPrimary ?? true;
    this.width = init.width ?? 1;
    this.height = init.height ?? 1;
    this.pressure = init.pressure ?? 0;
  }
}
class TouchEvent extends Event {
  constructor(type, init = {}) {
    super(type, init);
    for (const k of ["touches", "targetTouches", "changedTouches"]) this[k] = init[k] ?? [];
    for (const k of ["shiftKey", "ctrlKey", "altKey", "metaKey"]) this[k] = init[k] ?? false;
  }
}
g.KeyboardEvent = KeyboardEvent;
g.MouseEvent = MouseEvent;
g.PointerEvent = PointerEvent;
g.TouchEvent = TouchEvent;
g.InputEvent = g.FocusEvent = g.UIEvent = Event;
// Blob, File, FileList, FileReader (blob.js); DragEvent and DataTransfer
// over the engine's "drag" events (dnd.js).
const blobs = installBlob(g, host);
const dnd = installDnd(g, { MouseEvent, fire: fireAt, files: blobs, editable: dropEditable, dropText });
// No shadow trees here yet: the class pages test against (Alpine checks
// `el.parentNode instanceof ShadowRoot`).
g.ShadowRoot ??= class ShadowRoot {};

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

// The window ends the bubble path: a page may delegate its clicks from there
// (addEventListener("click", …) on window). Forwarded from the document while
// the event still has its target; keys and contextmenu go there on their own.
for (const type of ["click", "dblclick", "mousedown", "mouseup", "pointerdown", "pointerup", "input", "change", "submit"]) {
  document.addEventListener(type, (e) => { if (e.bubbles && !e.cancelBubble) fireWindow(e); });
}

// Mark elements that listen for clicks: they become touchable views.
const ET = Object.getPrototypeOf(Object.getPrototypeOf(document.body)).constructor.prototype;
for (let proto = Object.getPrototypeOf(document.body); proto; proto = Object.getPrototypeOf(proto)) {
  if (Object.prototype.hasOwnProperty.call(proto, "addEventListener")) {
    const orig = proto.addEventListener;
    proto.addEventListener = function (type, fn, opts) {
      if (type === "click" || type === "mousedown" || type === "pointerdown") { this.__listens = true; markListens(this); renderer?.markFlat(this); }
      return orig.call(this, type, fn, opts);
    };
    break;
  }
}
void ET;

// Pointer capture: the element gets the pointer's moves and up (pointerEvent).
{
  let proto = Object.getPrototypeOf(document.createElement("div"));
  while (proto && !Object.prototype.hasOwnProperty.call(proto, "getAttribute")) proto = Object.getPrototypeOf(proto);
  if (proto) {
    const def = (name, fn) => Object.defineProperty(proto, name, { value: fn, writable: true, configurable: true });
    def("setPointerCapture", function (id) { if (captured.has(id)) captured.set(id, this); });
    def("releasePointerCapture", function (id) { if (captured.get(id) === this) captured.delete(id); });
    def("hasPointerCapture", function (id) { return captured.get(id) === this; });
  }
}

// el.style.x = … and style.setProperty(…) update the style attribute inside
// linkedom without a mutation record, so the renderer never saw them (a
// requestAnimationFrame loop writing bar heights didn't move). Each
// element's style is wrapped once: writes mark the page for a render. (The
// native DOM's style writes are attribute writes, which it reports.)
if (!STYLE_RECORDS) {
  let proto = Object.getPrototypeOf(document.createElement("div"));
  let desc = null;
  while (proto && !(desc = Object.getOwnPropertyDescriptor(proto, "style"))) proto = Object.getPrototypeOf(proto);
  if (desc?.get) {
    const wrapped = internalWeak(new WeakMap());
    // try: a write before `let renderer` below has run (TDZ) is ignored.
    const touch = (el) => { try { if (renderer && el.isConnected) renderer.mark(el, 1); } catch {} };
    Object.defineProperty(proto, "style", {
      configurable: true,
      get() {
        const real = desc.get.call(this);
        if (!real || typeof real !== "object") return real;
        let w = wrapped.get(real);
        if (!w) {
          const el = this;
          w = new Proxy(real, {
            set(t, k, v) { t[k] = v; touch(el); return true; },
            get(t, k) {
              const v = t[k];
              if (k === "setProperty" || k === "removeProperty") return (...a) => { const r = v.apply(t, a); touch(el); return r; };
              return typeof v === "function" ? v.bind(t) : v;
            },
          });
          wrapped.set(real, w);
        }
        return w;
      },
      set(v) { desc.set ? desc.set.call(this, v) : this.setAttribute("style", String(v)); touch(this); },
    });
  }
}

// Set a field's value or checked as the user would: through the setter on
// its prototype, not the element. React wraps value/checked on each element
// to remember what it rendered, and an `input` event whose value went
// through that wrapper looks unchanged to it (onChange never runs).
// An InputEvent as browsers fire them on a field: inputType ("insertText",
// "deleteContentBackward", "insertFromPaste"...), data (the text inserted,
// or null), isComposing.
function inputEvent(type, inputType, data, cancelable) {
  const ev = new Event(type, { bubbles: true, cancelable });
  Object.defineProperties(ev, {
    inputType: { value: inputType ?? "", configurable: true },
    data: { value: data ?? null, configurable: true },
    isComposing: { value: false, configurable: true },
  });
  return ev;
}

function setNative(el, prop, v) {
  for (let p = Object.getPrototypeOf(el); p; p = Object.getPrototypeOf(p)) {
    const d = Object.getOwnPropertyDescriptor(p, prop);
    if (d?.set) { d.set.call(el, v); return; }
  }
  el[prop] = v;
}

// checked reflects the attribute (so :checked styles follow it). The first
// time the state is set (a click, or the page's .checked), its default (the
// attribute as authored) is kept: defaultChecked and form reset use it.
const inputProto = Object.getPrototypeOf(document.createElement("input"));
const checkedDefaults = new WeakMap(); // input → its default checkedness, once its state changed
Object.defineProperty(inputProto, "checked", {
  get() { return this.hasAttribute("checked"); },
  set(v) {
    if (!checkedDefaults.has(this)) checkedDefaults.set(this, this.hasAttribute("checked"));
    if (v) this.setAttribute("checked", ""); else this.removeAttribute("checked");
  },
  configurable: true,
});
// indeterminate: a state of its own (no attribute in HTML); kept as a
// runtime attribute so the box re-renders as mixed.
Object.defineProperty(inputProto, "indeterminate", {
  get() { return this.hasAttribute("data-nui-mix"); },
  set(v) { if (v) this.setAttribute("data-nui-mix", ""); else this.removeAttribute("data-nui-mix"); },
  configurable: true,
});
Object.defineProperty(inputProto, "defaultChecked", {
  get() { return checkedDefaults.has(this) ? checkedDefaults.get(this) : this.hasAttribute("checked"); },
  set(v) { if (checkedDefaults.has(this)) checkedDefaults.set(this, !!v); else setNative(this, "checked", !!v), checkedDefaults.delete(this); },
  configurable: true,
});
// type: the attribute when it is a known type, else "text", as in a
// browser (React only treats known types as text fields).
const INPUT_TYPES = new Set(("button checkbox color date datetime-local email file hidden image month number password " +
  "radio range reset search submit tel text time url week").split(" "));
Object.defineProperty(inputProto, "type", {
  get() { const t = (this.getAttribute("type") || "").toLowerCase(); return INPUT_TYPES.has(t) ? t : "text"; },
  set(v) { this.setAttribute("type", v); },
  configurable: true,
});
// A range's value as browsers sanitize it: halfway between min and max when
// it's missing or not a number, else clamped to them and on a step.
const valueDesc = Object.getOwnPropertyDescriptor(inputProto, "value");
const rangeValue = (el, raw) => {
  const num = (a, d) => { const v = parseFloat(el.getAttribute(a)); return Number.isFinite(v) ? v : d; };
  const min = num("min", 0), max = Math.max(num("max", 100), min);
  const step = el.getAttribute("step")?.toLowerCase() === "any" ? 0 : (num("step", 1) > 0 ? num("step", 1) : 1);
  let v = raw.trim() === "" ? NaN : Number(raw);
  if (!Number.isFinite(v)) v = min + (max - min) / 2;
  v = Math.min(Math.max(v, min), max);
  if (step) {
    v = min + Math.round((v - min) / step) * step;
    if (v > max) v -= step;
    v = +v.toFixed(12);
  }
  return String(v);
};
// The value as authored, kept the first time the value is set (the DOM may
// reflect value into its attribute): defaultValue and form reset use it.
const valueDefaults = new WeakMap();
Object.defineProperty(inputProto, "value", {
  get() {
    const raw = valueDesc.get.call(this);
    return this.type === "range" ? rangeValue(this, raw ?? "") : raw;
  },
  set(v) {
    if (!valueDefaults.has(this)) valueDefaults.set(this, this.getAttribute("value") ?? "");
    valueDesc.set.call(this, v);
  },
  configurable: true,
});
Object.defineProperty(inputProto, "defaultValue", {
  get() { return valueDefaults.has(this) ? valueDefaults.get(this) : this.getAttribute("value") ?? ""; },
  set(v) { if (valueDefaults.has(this)) valueDefaults.set(this, String(v)); else this.setAttribute("value", String(v)); },
  configurable: true,
});
// A text field's selection (UTF-16 offsets into its value): the native
// field's own (host.selection), else what the page last set or the end.
// Setting it moves the native field's too (host.setSelection).
const SELECTABLE = new Set(["", "text", "search", "url", "tel", "password"]);
const selectable = (el) => el.localName === "textarea" || SELECTABLE.has((el.getAttribute("type") || "").toLowerCase());
const lastSelection = internalWeak(new WeakMap());
function selectionOf(el) {
  const len = String(el.value ?? "").length;
  if (renderer && host.selection) {
    const r = host.selection(renderer.idOf(el, "el"));
    if (r) return [Math.min(r[0], len), Math.min(r[1], len)];
  }
  const s = lastSelection.get(el);
  return s ? [Math.min(s[0], len), Math.min(s[1], len)] : [len, len];
}
for (const proto of [inputProto, Object.getPrototypeOf(document.createElement("textarea"))]) {
  Object.defineProperties(proto, {
    selectionStart: {
      get() { return selectable(this) ? selectionOf(this)[0] : null; },
      set(v) { const end = selectionOf(this)[1]; this.setSelectionRange(v, Math.max(v, end)); },
      configurable: true,
    },
    selectionEnd: {
      get() { return selectable(this) ? selectionOf(this)[1] : null; },
      set(v) { const start = selectionOf(this)[0]; this.setSelectionRange(Math.min(start, v), v); },
      configurable: true,
    },
    selectionDirection: { get() { return selectable(this) ? "forward" : null; }, set() {}, configurable: true },
  });
  proto.setSelectionRange = function (start, end) {
    if (!selectable(this)) return;
    const len = String(this.value ?? "").length;
    const e = Math.min(Math.max(0, Math.trunc(+end) || 0), len);
    const s = Math.min(Math.max(0, Math.trunc(+start) || 0), e);
    lastSelection.set(this, [s, e]);
    if (renderer && host.setSelection) { renderer.render(); host.setSelection(renderer.idOf(this, "el"), s, e); }
  };
  proto.select = function () { this.setSelectionRange(0, String(this.value ?? "").length); };
}
Object.defineProperty(inputProto, "disabled", {
  get() { return this.hasAttribute("disabled"); },
  set(v) { if (v) this.setAttribute("disabled", ""); else this.removeAttribute("disabled"); },
  configurable: true,
});
// A select's value: linkedom only reads it (undefined without a [selected]
// option). As in a browser, it's the selected option's value or else the
// first's, and setting it selects the option with that value, so a native
// change reaches React's onChange with the new value.
const selectProto = Object.getPrototypeOf(document.createElement("select"));
const optionValue = (o) => o.getAttribute("value") ?? o.textContent;
Object.defineProperty(selectProto, "value", {
  get() {
    const opts = this.options;
    for (const o of opts) if (o.hasAttribute("selected")) return optionValue(o);
    return opts.length ? optionValue(opts[0]) : "";
  },
  set(v) {
    const want = String(v);
    let found = false;
    for (const o of this.options) {
      if (!found && optionValue(o) === want) { o.setAttribute("selected", ""); found = true; }
      else o.removeAttribute("selected");
    }
  },
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
formProto.reset = function () { reset(this); };

// Layout reads, from the native layout.
const elProto = Object.getPrototypeOf(Object.getPrototypeOf(document.createElement("div")));
// isContentEditable as browsers have it (the native DOM has none; linkedom's
// counts contenteditable="false" as editable): "", "true" or
// "plaintext-only" makes an element editable, "false" not, anything else
// (or no attribute) inherits its parent's.
{
  const isContentEditable = {
    get() {
      for (let el = this; el && el.getAttribute; el = el.parentElement) {
        const v = el.getAttribute("contenteditable");
        if (v === null) continue;
        const s = v.toLowerCase();
        if (s === "" || s === "true" || s === "plaintext-only") return true;
        if (s === "false") return false;
      }
      return false;
    },
    configurable: true,
  };
  // On elProto, and over linkedom's own nearer the elements.
  Object.defineProperty(elProto, "isContentEditable", isContentEditable);
  for (let p = Object.getPrototypeOf(document.createElement("div")); p && p !== elProto; p = Object.getPrototypeOf(p))
    if (Object.prototype.hasOwnProperty.call(p, "isContentEditable")) Object.defineProperty(p, "isContentEditable", isContentEditable);
}
// As in a browser, a layout read renders what changed first (the page just
// added these elements: their size, not 0).
// An inline element (a <span> amid text: no box of its own) is its line
// fragments' union.
const frameOf = (el) => {
  if (!renderer) return [0, 0, 0, 0];
  if (!renderer.rendering) renderer.render();
  const f = host.frame(renderer.idOf(el, "el"));
  if (f) return f;
  const rects = inlineRects(el);
  if (!rects?.length) return [0, 0, 0, 0];
  const x0 = Math.min(...rects.map((r) => r[0])), y0 = Math.min(...rects.map((r) => r[1]));
  const x1 = Math.max(...rects.map((r) => r[0] + r[2])), y1 = Math.max(...rects.map((r) => r[1] + r[3]));
  return [x0, y0, x1 - x0, y1 - y0];
};
// An inline element's line fragments ([x, y, w, h] each, as frames are):
// the backend's (host.runRects: each line's piece of its text), else the
// text node they are in, whole. Null when it has no runs.
function inlineRects(el) {
  const spans = renderer?.inlineSpans?.(el);
  if (!spans) return null;
  const out = [];
  for (const [id, first, last] of spans) {
    const rects = typeof host.runRects === "function" ? host.runRects(id, first, last) : undefined;
    if (rects) { out.push(...rects); continue; }
    const f = host.frame(id);
    if (f) out.push([f[0], f[1], f[2], f[3]]);
  }
  return out;
}
const rectOf = ([x, y, w, h]) => ({ x, y, left: x, top: y, width: w, height: h, right: x + w, bottom: y + h });
// An element's border widths (top, right, bottom, left), for its client
// box: as the box has them, snapped to device pixels (render.js snapBorder).
function borderOf(el) {
  const cs = renderer?.styleOf?.(el);
  if (!cs) return [0, 0, 0, 0];
  return ["top", "right", "bottom", "left"].map((s) => borderWidth(cs, s));
}
function borderWidth(cs, side) {
  const style = cs[`border-${side}-style`];
  if (!style || style === "none" || style === "hidden") return 0;
  const w = cs[`border-${side}-width`] ?? "medium";
  return snapBorder(({ thin: 1, medium: 3, thick: 5 })[w] ?? (parseFloat(w) || 0));
}
const BORDER_WIDTH = /^border-(top|right|bottom|left)-width$/;
Object.defineProperties(elProto, {
  offsetWidth: { get() { return frameOf(this)[2]; }, configurable: true },
  offsetHeight: { get() { return frameOf(this)[3]; }, configurable: true },
  // The root element's client box is the viewport (innerWidth less the
  // window's scrollbar), as in browsers; a scroller's leaves its
  // scrollbar's room out (the frame's sixth value). Whole px, as browsers
  // give them (a box 20px wide in a 1/3px border at 3x: 20).
  clientWidth: {
    get() {
      if (this === document.documentElement) return viewport.width - ((renderer && host.frame(-1)?.[5]) || 0);
      const f = frameOf(this);
      const b = borderOf(this);
      return Math.max(0, Math.round(f[2] - b[1] - b[3] - (f[5] || 0)));
    },
    configurable: true,
  },
  // The padding box's height (no horizontal scrollbar here).
  clientHeight: {
    get() {
      if (this === document.documentElement) return viewport.height;
      const b = borderOf(this);
      return Math.max(0, Math.round(frameOf(this)[3] - b[0] - b[2]));
    },
    configurable: true,
  },
  scrollHeight: { get() { const f = frameOf(this); return f[4] ?? f[3]; }, configurable: true },
  // (The frame's ninth value; a host without it: the box's width.)
  scrollWidth: { get() { const f = frameOf(this); return f[8] ?? f[2]; }, configurable: true },
  offsetTop: { get() { return frameOf(this)[1]; }, configurable: true },
  offsetLeft: { get() { return frameOf(this)[0]; }, configurable: true },
  // The scroll offsets (the frame's seventh and eighth values); the
  // root's and the scrolling element's are the window's (node -1).
  scrollTop: {
    get() { return scrollPx((renderer && host.frame(scrollIdOf(this))?.[6]) || 0); },
    set(y) { if (renderer) { renderer.render(); pageScroll(scrollIdOf(this), +y || 0); } },
    configurable: true,
  },
  scrollLeft: {
    get() { return scrollPx((renderer && host.frame(scrollIdOf(this))?.[7]) || 0); },
    set(x) { if (renderer) { renderer.render(); pageScroll(scrollIdOf(this), NaN, +x || 0); } },
    configurable: true,
  },
});
const scrollIdOf = (el) => (el === document.documentElement || el === document.scrollingElement ? -1 : renderer.idOf(el, "el"));
// element.scrollTo / scroll / scrollBy: (x, y) or { top, left }.
const scrollArgs = (x, y) => (typeof x === "object" && x !== null ? [x.left, x.top] : [x, y]);
elProto.scrollTo = elProto.scroll = function (x, y) {
  const [left, top] = scrollArgs(x, y);
  if (!renderer) return;
  renderer.render();
  pageScroll(scrollIdOf(this), top === undefined ? NaN : +top || 0, left === undefined ? NaN : +left || 0);
};
elProto.scrollBy = function (x, y) {
  const [left, top] = scrollArgs(x, y);
  this.scrollTo({ top: this.scrollTop + (+top || 0), left: this.scrollLeft + (+left || 0) });
};
elProto.getBoundingClientRect = function () {
  return rectOf(frameOf(this));
};
// One rect for a box, one per line fragment for an inline element, none
// for an element not rendered.
elProto.getClientRects = function () {
  if (!renderer) return [];
  if (!renderer.rendering) renderer.render();
  const f = host.frame(renderer.idOf(this, "el"));
  const list = (f ? [f] : inlineRects(this) || []).map(rectOf);
  list.item = (i) => list[i] ?? null;
  return list;
};
elProto.focus = function () {
  document.__active = this;
  if (renderer) { renderer.render(); host.focus(renderer.idOf(this, "el")); }
};
// linkedom's HTMLElement.prototype has a blur() that only fires the event.
Object.getPrototypeOf(document.createElement("div")).blur = elProto.blur = function () {
  if (document.__active === this) document.__active = null;
};
elProto.scrollIntoView = function (opts) {
  if (!renderer) return;
  const block = typeof opts === "object" ? opts.block || "start" : opts === false ? "end" : "start";
  // Changes not rendered yet: scroll after the next render, rather than
  // render now. It returns nothing, so the page can't tell, and a page that
  // keeps scrolling to its newest line (a chat streaming tokens) doesn't
  // render the whole document once per token.
  glide = null;
  if (renderer.dirty) { renderer.pendingScroll = { el: this, block }; return; }
  host.scrollIntoView(renderer.idOf(this, "el"), block);
};
// linkedom defines its own click() on HTMLElement.prototype (one level
// below elProto), which only fires the event: replace it there too, so a
// page's el.click() also submits forms, follows links and toggles boxes.
// As in browsers, a click() on an element whose click is in progress does
// nothing (a handler on a parent that clicks its child again would recurse).
const clicking = internalWeak(new WeakSet());
Object.getPrototypeOf(document.createElement("div")).click = elProto.click = function () {
  if (clicking.has(this)) return;
  clicking.add(this);
  try { activate(this, 0); } finally { clicking.delete(this); }
};
// The page scrolls in the window's scroll view (node -1, render.js):
// window.scrollTo(x, y) and scrollTo({ top }).
g.scrollTo = g.scroll = (x, y) => {
  const [left, top] = scrollArgs(x, y);
  if (renderer) { renderer.render(); pageScroll(-1, top === undefined ? NaN : +top || 0, left === undefined ? NaN : +left || 0); }
};
g.scrollBy = (x, y) => {
  const [left, top] = scrollArgs(x, y);
  g.scrollTo({ top: g.scrollY + (+top || 0), left: g.scrollX + (+left || 0) });
};
// Scroll offsets as the platform's WebView gives them: WebKit's in whole
// px (a touch fling or a trackpad leaves the view between pixels).
function scrollPx(v) { return platform.os === "macos" || platform.os === "ios" ? Math.round(v) : v; }
// The window's scroll offsets: node -1's (the page's scroll view).
for (const [names, i] of [[["scrollY", "pageYOffset"], 6], [["scrollX", "pageXOffset"], 7]]) {
  for (const name of names) Object.defineProperty(g, name, { get: () => scrollPx((renderer && host.frame(-1)?.[i]) || 0), configurable: true });
}
Object.defineProperty(document, "scrollingElement", { get() { return this.documentElement; }, configurable: true });
// The focused element; it carries data-nui-focus, which the style engine
// matches for :focus (css.js).
// :focus-visible (data-nui-focus-visible) as browsers decide it: focus
// that came by the keyboard, or a text field (it shows a caret either way).
// Before any pointer press, a script's focus() counts as the keyboard's
// (WebKit and Chromium show the ring for it then).
let active = null;
let keyboardFocus = true;
const TEXT_INPUTS = new Set(["", "text", "search", "email", "url", "tel", "password", "number", "date", "time", "datetime-local", "month", "week"]);
const textField = (el) => el?.localName === "textarea" || el?.isContentEditable ||
  (el?.localName === "input" && TEXT_INPUTS.has((el.getAttribute("type") || "").toLowerCase()));
// A text field's change, as browsers fire it: when it loses the focus,
// and on Enter in a one-line field, if the user edited it (the backend's
// input) and its value differs from what it was at focus or at the last
// change. A script's value doesn't count (browsers fire nothing for it).
const changeBase = internalWeak(new WeakMap()); // field → its value at focus or the last change
const edited = internalWeak(new WeakSet());
const changeField = (el) => el?.localName === "textarea" ||
  (el?.localName === "input" && TEXT_INPUTS.has((el.getAttribute("type") || "").toLowerCase()));
function fireChange(el) {
  if (!changeField(el) || !edited.has(el)) return;
  edited.delete(el);
  if (el.value === changeBase.get(el)) return;
  changeBase.set(el, el.value);
  el.dispatchEvent(new Event("change", { bubbles: true }));
}
// Where dropped text goes by default (dnd.js): an enabled, writable text
// field or textarea, or contenteditable.
const DROP_INPUTS = new Set(["", "text", "search", "url", "tel", "password", "email"]);
function dropEditable(el) {
  if (!el || el.nodeType !== 1) return false;
  if (el.localName === "textarea" || el.localName === "input") {
    if (el.localName === "input" && !DROP_INPUTS.has((el.getAttribute("type") || "").toLowerCase())) return false;
    return !el.hasAttribute("disabled") && !el.hasAttribute("readonly");
  }
  return !!el.isContentEditable;
}
// Text dropped on such an element and not taken by the page: as a native
// edit, beforeinput (insertFromDrop, cancelable), the new value (a field's
// at its selection, a one-line field's without line breaks), then input.
// The field takes the focus first, as in a browser. False when the page
// prevented it.
function dropText(el, text) {
  if (active !== el) el.focus();
  const before = inputEvent("beforeinput", "insertFromDrop", text, true);
  el.dispatchEvent(before);
  if (before.defaultPrevented) return false;
  if (el.localName === "input" || el.localName === "textarea") {
    const t = el.localName === "input" ? text.replace(/[\r\n]+/g, "") : text;
    const value = String(el.value ?? "");
    const [start, end] = selectionOf(el);
    setNative(el, "value", value.slice(0, start) + t + value.slice(end));
    edited.add(el);
    el.setSelectionRange(start + t.length, start + t.length);
    el.dispatchEvent(inputEvent("input", "insertFromDrop", t, false));
    return true;
  }
  el.appendChild(document.createTextNode(text));
  el.dispatchEvent(inputEvent("input", "insertFromDrop", text, false));
  return true;
}
const focusEvent = (type, bubbles, relatedTarget) => {
  const ev = new Event(type, { bubbles });
  Object.defineProperty(ev, "relatedTarget", { value: relatedTarget || null, configurable: true });
  return ev;
};
Object.defineProperty(document, "__active", {
  get() { return active; },
  set(el) {
    if (el === active) return;
    const old = active;
    // As browsers do: first the old one loses the focus (blur, then
    // focusout; activeElement is the body meanwhile), then the new one gets
    // it (focus, then focusin). Focus and blur don't bubble. A listener that
    // moves the focus itself wins.
    if (old) {
      // Its change first (an edited text field), then blur, as browsers.
      fireChange(old);
      if (active !== old) return;
      old.removeAttribute?.("data-nui-focus");
      old.removeAttribute?.("data-nui-focus-visible");
      active = null;
      setFocusVisible(null);
      if (old.dispatchEvent) {
        old.dispatchEvent(focusEvent("blur", false, el || null));
        old.dispatchEvent(focusEvent("focusout", true, el || null));
      }
      if (active !== null) return;
    }
    if (!el) return;
    active = el;
    if (changeField(el)) { changeBase.set(el, el.value); edited.delete(el); }
    el.setAttribute?.("data-nui-focus", "");
    const visible = keyboardFocus || textField(el);
    if (visible) el.setAttribute?.("data-nui-focus-visible", "");
    setFocusVisible(visible ? el : null);
    if (el.dispatchEvent) {
      el.dispatchEvent(focusEvent("focus", false, old));
      if (active === el) el.dispatchEvent(focusEvent("focusin", true, old));
    }
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
    removeEventListener(_t, fn) { this.listeners.delete(fn); if (!this.listeners.size) mediaLists.delete(this); },
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
setFocusRingOS(platform.os, platform.accent);
g.navigator = { userAgent: `Oriel native (${platform.os || "unknown"})`, platform: platform.os || "", language: "en-US", languages: ["en-US"], clipboard: undefined, maxTouchPoints: viewport.coarse ? 5 : 0 };
Object.defineProperty(g, "innerWidth", { get: () => viewport.width });
Object.defineProperty(g, "innerHeight", { get: () => viewport.height });
// The screen's pixels per CSS px: the backend's scale (platform.dpr:
// Apple's backing scale, GTK's scale factor, Win32's DPI / 96, Android's
// density), 1 without one; resolution media queries ask the same.
viewport.dpr = platform.dpr > 0 ? +platform.dpr : 1;
Object.defineProperty(g, "devicePixelRatio", { get: () => viewport.dpr, configurable: true });
// (A border width as the box has it: snapped, in px, as WebKit's
// "0.333333px".)
g.getComputedStyle = (el) => {
  const cs = renderer?.styleOf(el) || {};
  const value = (p) => { const m = BORDER_WIDTH.exec(p); return m && renderer ? `${+borderWidth(cs, m[1]).toFixed(6)}px` : cs[p] ?? ""; };
  return new Proxy({}, { get: (_, k) => (k === "getPropertyValue" ? value : value(String(k).replace(/[A-Z]/g, (c) => "-" + c.toLowerCase()))) });
};
g.ResizeObserver ??= class { observe() {} unobserve() {} disconnect() {} };
g.IntersectionObserver ??= class { observe() {} unobserve() {} disconnect() {} };
installURL(g);

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
    // A notification click that came before the page listened (one that launched the app).
    if (event === "notification:action") invoke("notification:ready", {}).catch(() => {});
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
const isCheckable = (n) => n?.localName === "input" && /^(checkbox|radio)$/.test(n.type);

// A button's type: <button> (submit by default) and <input type=button|submit|reset|image>.
function buttonType(el) {
  if (el.localName === "button") { const t = (el.getAttribute("type") || "submit").toLowerCase(); return t === "reset" || t === "button" ? t : "submit"; }
  if (el.localName === "input" && /^(button|submit|reset|image)$/.test(el.type)) return el.type === "image" ? "submit" : el.type;
  return null;
}
// A form control that's disabled (itself, or in a disabled fieldset not in its first legend): it takes no clicks.
function disabledControl(el) {
  if (!CONTROLS.has(el?.localName)) return false;
  if (el.hasAttribute("disabled")) return true;
  for (let f = el.parentNode?.closest?.("fieldset[disabled]"); f; f = f.parentNode?.closest?.("fieldset[disabled]")) {
    const legend = [...f.children].find((c) => c.localName === "legend");
    if (!legend || !legend.contains(el)) return true;
  }
  return false;
}

function activate(el, flags) {
  // A disabled control gets no click (nor from its label), as in a browser.
  if (disabledControl(el)) return;
  // A checkbox or radio changes before its click is dispatched (and goes
  // back if a listener cancels it), as in a browser: React's onChange for
  // them reads the new state during the click.
  const wasMixed = el.localName === "input" && el.type === "checkbox" && el.indeterminate;
  if (wasMixed) el.indeterminate = false;
  const undo0 = isCheckable(el) && !el.hasAttribute("disabled") ? check(el) : null;
  const undo = undo0 && (() => { undo0(); if (wasMixed) el.indeterminate = true; });
  // Where the pointer went up (the press that made this click), when the backend sends pointers.
  const [clientX, clientY] = lastPointer;
  lastPointer = [0, 0]; // one click's (a keyboard's or el.click()'s has none)
  const ev = new MouseEvent("click", { bubbles: true, cancelable: true, clientX, clientY, shiftKey: !!(flags & 1), ctrlKey: !!(flags & 2) });
  el.dispatchEvent(ev);
  if (undo) {
    if (ev.defaultPrevented) undo();
    else {
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
    }
    return;
  }
  if (ev.defaultPrevented || isCheckable(el)) return;
  for (let n = el; n && n.nodeType === 1; n = n.parentNode) {
    const tag = n.localName;
    if (tag === "a") {
      const href = n.getAttribute("href") || "";
      if (href.startsWith("#")) location.hash = href;
      else if (/^https?:|^mailto:/.test(href)) g.oriel.openExternal(href).catch(() => {});
      return;
    }
    if (tag === "label") {
      // The label clicks its control (which toggles a checkbox or radio).
      const ctl = n.htmlFor ? document.getElementById(n.getAttribute("for")) : n.querySelector("input, textarea, select, button");
      if (ctl && ctl !== el && !ctl.contains?.(el) && !disabledControl(ctl)) {
        if (isCheckable(ctl)) activate(ctl, flags);
        else ctl.focus();
      }
      return;
    }
    const type = buttonType(n);
    if (type) {
      if (disabledControl(n)) return;
      const form = n.closest("form");
      if (type === "submit" && form) submit(form);
      else if (type === "reset" && form) reset(form);
      return;
    }
  }
}
// Toggle a checkbox, or check a radio and uncheck the rest of its group;
// returns what puts them back.
function check(input) {
  const before = [[input, input.checked]];
  if (input.type === "radio") {
    const name = input.getAttribute("name");
    if (name) {
      const scope = input.closest("form") || document;
      for (const r of scope.querySelectorAll('input[type="radio"]')) {
        if (r !== input && r.getAttribute("name") === name && r.checked) { before.push([r, true]); setNative(r, "checked", false); }
      }
    }
    setNative(input, "checked", true);
  } else setNative(input, "checked", !input.checked);
  return () => { for (const [n, v] of before) setNative(n, "checked", v); };
}
function submit(form) {
  const ev = new Event("submit", { bubbles: true, cancelable: true });
  form.dispatchEvent(ev);
}
// Form reset: the "reset" event, then (unless cancelled) each control back
// to its default: a field's value attribute (a textarea's text), a box's
// checkedness as authored, a select's selected options.
function reset(form) {
  const ev = new Event("reset", { bubbles: true, cancelable: true });
  form.dispatchEvent(ev);
  if (ev.defaultPrevented) return;
  for (const c of form.querySelectorAll("input, textarea, select")) {
    if (isCheckable(c)) {
      const d = c.defaultChecked;
      setNative(c, "checked", d);
      checkedDefaults.delete(c);
    } else if (c.localName === "select") {
      const opts = [...c.querySelectorAll("option")];
      const sel = opts.findIndex((o) => o.hasAttribute("selected"));
      setNative(c, "value", (opts[sel < 0 ? 0 : sel] || {}).value ?? "");
    } else if (c.localName === "textarea") setNative(c, "value", c.textContent);
    else if (!buttonType(c)) { setNative(c, "value", c.defaultValue); valueDefaults.delete(c); }
  }
}


// A key went down (`type` "keydown", data [key, modifiers, repeat]) or up
// ("keyup", [key, modifiers]).
const MODIFIER_KEYS = new Set(["Shift", "Control", "Alt", "Meta", "AltGraph", "CapsLock"]);
let spacePress = null; // the control a Space keydown went to, activated by its keyup
// A radio's group: the radios of its name in its form (or the document).
function radioGroup(input) {
  const name = input.getAttribute("name");
  if (!name) return [input];
  const scope = input.closest("form") || document;
  return [...scope.querySelectorAll('input[type="radio"]')].filter((r) => r.getAttribute("name") === name && (r.closest("form") || document) === scope);
}
function keyEvent(el, data, type = "keydown") {
  const [key, flags, repeat] = data;
  const init = { key, code: key, bubbles: true, cancelable: true, repeat: !!repeat, shiftKey: !!(flags & 1), ctrlKey: !!(flags & 2), altKey: !!(flags & 4), metaKey: !!(flags & 8) };
  const ev = new KeyboardEvent(type, init);
  (el || document.body).dispatchEvent(ev);
  if (!ev.defaultPrevented) fireWindow(ev);
  // keypress after a keydown let through, for a character or Enter (not
  // with Control or Command); WebKit's also for Escape, and on macOS with
  // Command. Preventing it keeps the character out too.
  if (type === "keydown" && !ev.defaultPrevented && keypressFor(key, init)) {
    const press = new KeyboardEvent("keypress", init);
    (el || document.body).dispatchEvent(press);
    if (!press.defaultPrevented) fireWindow(press);
    if (press.defaultPrevented) return true;
  }
  // The browsers' default actions for keys on a focused control: Enter
  // activates a button, a link or a summary on keydown; Space a button, a
  // checkbox or a radio on keyup (a keydown prevented cancels it); the
  // arrows move a radio group's check.
  const mods = init.ctrlKey || init.altKey || init.metaKey;
  if (el && !mods && !disabledControl(el)) {
    if (type === "keydown" && key === " ") spacePress = ev.defaultPrevented ? null : el;
    if (!ev.defaultPrevented) {
      if (type === "keydown" && key === "Enter" && !repeat && (buttonType(el) || (el.localName === "a" && el.hasAttribute("href")) || el.localName === "summary")) { activate(el, flags); return true; }
      if (type === "keyup" && key === " " && spacePress === el && (buttonType(el) || isCheckable(el))) { spacePress = null; activate(el, flags); return true; }
      if (type === "keydown" && el.type === "radio" && el.localName === "input" && /^Arrow(Up|Down|Left|Right)$/.test(key)) {
        const group = radioGroup(el).filter((r) => !disabledControl(r) && shown(r));
        const at = group.indexOf(el);
        if (group.length > 1 && at >= 0) {
          const next = group[(at + (key === "ArrowDown" || key === "ArrowRight" ? 1 : -1) + group.length) % group.length];
          keyboardFocus = true;
          next.focus();
          activate(next, flags);
          return true;
        }
      }
    }
  }
  if (type === "keyup" && key === " ") spacePress = null;
  // Tab moves the focus, Shift+Tab back, unless the page took the key.
  if (type === "keydown" && !ev.defaultPrevented && key === "Tab" && !(init.ctrlKey || init.altKey || init.metaKey)) {
    return tabFocus(init.shiftKey) || false;
  }
  // Enter in a one-line field: Chromium's beforeinput (insertLineBreak,
  // which changes nothing there), the field's change, then its form is
  // submitted.
  if (type === "keydown" && !ev.defaultPrevented && key === "Enter" && el?.localName === "input") {
    if (changeField(el)) {
      el.dispatchEvent(inputEvent("beforeinput", "insertLineBreak", null, true));
      fireChange(el);
    }
    const form = el.closest("form");
    if (form) { submit(form); return true; }
  }
  // Keys that scroll, as browsers' default: the focused element's nearest
  // scroller, else the window (never from a field, which uses them).
  if (type === "keydown" && !ev.defaultPrevented && !(init.ctrlKey || init.altKey || init.metaKey) && scrollKey(el || document.__active, key, init.shiftKey)) return true;
  return ev.defaultPrevented;
}

// ArrowUp/Down 40px, PageUp/Down and Space (Shift: up) 87.5% of the view,
// Home/End to the ends, as Chromium. True when a scroller took it. The
// scroller glides there (glideTo).
function scrollKey(from, key, shift) {
  if (!renderer || !host.frame) return false;
  if (from && (textField(from) || from.localName === "select" || from.localName === "textarea" || from.isContentEditable)) return false;
  if (key === " " && from && (from.localName === "button" || from.localName === "input" || from.localName === "a")) return false;
  const steps = { ArrowDown: 40, ArrowUp: -40, PageDown: 0.875, PageUp: -0.875, " ": shift ? -0.875 : 0.875, Home: -Infinity, End: Infinity };
  const step = steps[key];
  if (step === undefined) return false;
  renderer.render();
  // The nearest ancestor that scrolls (overflow-y auto or scroll, taller
  // inside than it shows), else the window.
  // (f[4] is the scrollHeight: compared with the clientHeight, the frame's
  // height less the borders.)
  let target = -1, targetEl = null;
  const clientH = (f, el) => { const b = el ? borderOf(el) : [0, 0, 0, 0]; return f[3] - b[0] - b[2]; };
  for (let n = from; n && n.nodeType === 1 && n !== document.body && n !== document.documentElement; n = n.parentNode) {
    const cs = getComputedStyle(n);
    const ov = cs["overflow-y"] || cs.overflowY || cs.overflow;
    if (ov !== "auto" && ov !== "scroll") continue;
    const f = host.frame(renderer.idOf(n, "el"));
    if (f && f[4] > clientH(f, n) + 0.5) { target = renderer.idOf(n, "el"); targetEl = n; break; }
  }
  const f = host.frame(target);
  if (!f) return false;
  const view = clientH(f, targetEl);
  // A key while it glides: on from where that glide was going, as browsers.
  const top = glide?.target === target ? glide.to : f[6] || 0;
  const by = Math.abs(step) <= 1 ? Math.round(step * view) : step;
  const want = Math.max(0, Math.min(f[4] - view, top + by));
  if (want === top) return false;
  glideTo(target, f[6] || 0, want, Math.abs(step) === 40 ? "line" : "page");
  return true;
}

// A key scroll glides as WKWebView's does (measured on macOS, a scroll
// event a frame): a page, Space, Home or End over 200 ms on CSS's
// \`ease\`, however far; an arrow's 40px over 256 ms on \`ease-out\`, 20 ms
// in (to within a pixel). Chromium's (Windows, Android) is to be measured
// there; until then the same. A page's own scroll (scrollTo, scrollTop,
// scrollIntoView), a touch or a wheel stops it where it is: the wheel, as
// the scroller then reports an offset this glide didn't set (scrolled).
const GLIDES = { page: [200, 0, EASES.ease], line: [256, 20, EASES["ease-out"]] };
let glide = null; // { target, from, to, t0, ms, delay, ease, set: offsets set lately }
function glideTo(target, from, to, kind) {
  const [ms, delay, ease] = GLIDES[kind];
  const g1 = { target, from, to, t0: performance.now(), ms, delay, ease, set: [from] };
  glide = g1;
  const step = (now) => {
    if (glide !== g1) return;
    const p = Math.min(1, Math.max(0, (now - g1.t0 - delay) / ms));
    const y = from + (to - from) * ease(p);
    g1.set = [...g1.set.slice(-2), y];
    host.scrollTo(target, y);
    if (p < 1) nextFrame(step); else glide = null;
  };
  nextFrame(step);
}
// The page's scrolls: a key scroll's glide stops.
function pageScroll(id, top, left) {
  glide = null;
  host.scrollTo(id, top, left);
}

const WEBKIT_KEYPRESS = platform.os === "macos" || platform.os === "ios";
function keypressFor(key, init) {
  if (init.ctrlKey || (init.metaKey && platform.os !== "macos")) return false;
  if (key === "Enter" || (WEBKIT_KEYPRESS && key === "Escape")) return true;
  return [...key].length === 1;
}

// Sequential focus, as browsers order it: positive tabindex first
// (ascending, then document order), then the rest in document order.
// Focusable: links with href, enabled form controls, contenteditable, and
// anything with tabindex >= 0; shown ones only (rendered, not
// visibility: hidden). True when the focus moved (the key is used); at the
// end it wraps, as a page alone in its window has nowhere else to go.
const FOCUSABLE = "a[href], button, input, select, textarea, summary, [tabindex], [contenteditable]";
function tabOrder() {
  const positive = [];
  const rest = [];
  for (const el of document.querySelectorAll(FOCUSABLE)) {
    // A missing or invalid tabindex: 0 if the element is focusable itself.
    let index = parseInt(el.getAttribute("tabindex"), 10);
    if (Number.isNaN(index)) {
      if (!naturallyFocusable(el) || (tabRule !== "all" && !textLike(el))) continue;
      index = 0;
    } else if (tabRule === "ios" && CONTROLS.has(el.localName) && !textLike(el)) continue;
    if (index < 0 || disabledControl(el) || !shown(el)) continue;
    // A radio group is one stop: its checked radio (else the one with the
    // focus, else its first), as in browsers and Windows.
    if (el.localName === "input" && el.type === "radio" && el.getAttribute("name")) {
      const group = radioGroup(el).filter((r) => !disabledControl(r) && shown(r));
      const stop = group.find((r) => r.checked) || group.find((r) => r === active) || group[0];
      if (stop !== el) continue;
    }
    (index > 0 ? positive : rest).push([index, el]);
  }
  positive.sort((a, b) => a[0] - b[0]);
  return [...positive, ...rest].map((e) => e[1]);
}
const CONTROLS = new Set(["input", "button", "select", "textarea"]);
// Which elements Tab visits, as the platform's WebView does (measured):
// - "mac": macOS without Full Keyboard Access (the system's keyboard
//   navigation setting, off by default): text fields, selects, textareas
//   and contenteditable, plus anything with an explicit tabindex >= 0 (a
//   button or link without one is skipped);
// - "ios": the same, but a tabindex doesn't bring in a button, checkbox
//   or range (WKWebView skipped a tabindex="0" button);
// - "all": browsers' order (Full Keyboard Access, other platforms).
const tabRule = platform.os === "ios" ? "ios" : platform.os === "macos" && !platform.fullKeyboardAccess ? "mac" : "all";
function textLike(el) {
  return el.localName === "select" || textField(el) || ["", "true", "plaintext-only"].includes(el.getAttribute("contenteditable"));
}
function naturallyFocusable(el) {
  switch (el.localName) {
    case "a": return el.hasAttribute("href");
    case "input": return (el.getAttribute("type") || "").toLowerCase() !== "hidden";
    case "button": case "select": case "textarea": return true;
    case "summary": return el.parentElement?.localName === "details";
    default: return ["", "true", "plaintext-only"].includes(el.getAttribute("contenteditable"));
  }
}
function shown(el) {
  if (!renderer) return false;
  if (!renderer.rendering) renderer.render();
  if (getComputedStyle(el).visibility === "hidden") return false;
  if (host.frame(renderer.idOf(el, "el"))) return true;
  // No box of its own (an inline element is part of its text's runs):
  // shown unless it or an ancestor is display: none.
  for (let e = el; e && e !== document.documentElement; e = e.parentElement) {
    if (getComputedStyle(e).display === "none") return false;
  }
  return true;
}
// A press focuses what it's on, as a browser's mousedown does: the
// nearest focusable element from its target up (a field's padding or
// border too, outside the native control), or, on nothing focusable, the
// focus leaves. A mouse or pen on its press (not prevented); a touch at
// its tap, before the click (a scroll that starts on a field doesn't
// focus it).
// WebKit on macOS and iOS focuses no button, link or checkbox on a click
// (only text fields, selects and what has a tabindex). A label leaves it
// to its click, which focuses its control.
function pressFocus(target) {
  for (let n = target; n && n.nodeType === 1; n = n.parentElement) {
    if (n.localName === "label") return;
    const index = parseInt(n.getAttribute("tabindex"), 10);
    const focusable = Number.isNaN(index) ? naturallyFocusable(n) && (tabRule === "all" || textLike(n)) : true;
    if (!focusable || (CONTROLS.has(n.localName) && n.hasAttribute("disabled"))) continue;
    if (active !== n) n.focus();
    return;
  }
  if (active) active.blur();
}
let tapFocus = null; // a touch's target, focused at its tap

function tabFocus(back) {
  const order = tabOrder();
  if (!order.length) return false;
  const at = order.indexOf(active);
  const next = at < 0
    ? (back ? order[order.length - 1] : order[0])
    : order[(at + (back ? -1 : 1) + order.length) % order.length];
  keyboardFocus = true;
  next.focus();
  next.scrollIntoView({ block: "nearest" });
  return true;
}

let renderer = null;

// Pointers (docs/native-renderer.md, "Pointer events"): the element each
// pointer went down on gets its moves and its up until then, wherever it
// goes (implicit capture, as a browser does for touch; setPointerCapture
// keeps the same element).
const captured = new Map(); // pointerId → element
let lastPointer = [0, 0]; // the last pointer event's clientX/Y (a click's)
const POINTER_TYPES = { down: ["pointerdown", "mousedown", "touchstart"], move: ["pointermove", "mousemove", "touchmove"], up: ["pointerup", "mouseup", "touchend"], cancel: ["pointercancel", null, "touchcancel"] };
// Types the document already forwards to the window (above).
const FORWARDED = new Set(["mousedown", "mouseup", "pointerdown", "pointerup"]);
// The buttons each pointer held after its last event: a press or release
// changes one bit, which is the event's `button` (backends send only buttons).
const heldButtons = new Map(); // pointerId → buttons
const blankPress = new Map(); // pointerId → went down on blank space with the primary button
let lastPointerType = "mouse";
// `buttons` bit → MouseEvent.button: primary 0, secondary 2, auxiliary 1, back 3, forward 4.
const BUTTON_OF_BIT = [[1, 0], [2, 2], [4, 1], [8, 3], [16, 4]];
function changedButton(bits) {
  for (const [bit, button] of BUTTON_OF_BIT) if (bits & bit) return button;
  return 0;
}

// An engine's event at `target`, then at the window's listeners while it
// still bubbles (unless the document forwards its type there already).
// True when it was prevented.
function fireAt(target, ev) {
  target.dispatchEvent(ev);
  if (!FORWARDED.has(ev.type) && ev.bubbles && !ev.cancelBubble) {
    // The dispatch is over (the native DOM clears its target then): the
    // window's listeners still see the element, as in a browser.
    if (ev.target !== target) Object.defineProperty(ev, "target", { value: target, configurable: true });
    fireWindow(ev);
  }
  return ev.defaultPrevented;
}

function pointerEvent(el, data) {
  const [phase, x, y, buttons, pointerId, pointerType, flags] = data;
  const names = POINTER_TYPES[phase];
  if (!names) return false;
  lastPointer = [x, y];
  let target = captured.get(pointerId);
  // Nothing under the pointer (blank space below the content): the root
  // element, as in a browser.
  if (phase === "down" || !target?.isConnected) target = el || document.documentElement || document.body;
  if (phase === "down") blankPress.set(pointerId, !el && buttons === 1);
  if (phase === "down") captured.set(pointerId, target);
  else if (phase === "up" || phase === "cancel") captured.delete(pointerId);
  const mods = { shiftKey: !!(flags & 1), ctrlKey: !!(flags & 2), altKey: !!(flags & 4), metaKey: !!(flags & 8) };
  const held = heldButtons.get(pointerId) || 0;
  const button = phase === "move" ? -1 : changedButton(phase === "down" ? buttons & ~held : held & ~buttons);
  if (phase === "up" || phase === "cancel") heldButtons.delete(pointerId);
  else heldButtons.set(pointerId, buttons);
  lastPointerType = pointerType || "mouse";
  const init = { bubbles: true, cancelable: phase !== "cancel", clientX: x, clientY: y, button, buttons, ...mods };
  const fire = (ev) => fireAt(target, ev);
  let prevented = fire(new PointerEvent(names[0], { ...init, pointerId, pointerType, isPrimary: true, pressure: buttons ? 0.5 : 0 }));
  if (phase === "cancel") tapFocus = null;
  if (pointerType === "touch") {
    const touch = { identifier: pointerId, target, clientX: x, clientY: y, pageX: x, pageY: y, screenX: x, screenY: y, radiusX: 1, radiusY: 1, force: 0.5 };
    const on = phase === "down" || phase === "move" ? [touch] : [];
    if (fire(new TouchEvent(names[2], { bubbles: true, cancelable: phase !== "cancel", touches: on, targetTouches: on, changedTouches: [touch], ...mods }))) prevented = true;
  } else {
    if (names[1] && fire(new MouseEvent(names[1], { ...init, button: Math.max(button, 0) }))) prevented = true;
    // A non-primary button's release: auxclick (the primary's click comes
    // from the backend as "click").
    if (phase === "up" && button > 0) fire(new MouseEvent("auxclick", { ...init, cancelable: true }));
  }
  // A primary press and release on blank space: a click on the root element
  // (backends send clicks only for nodes they hit).
  if (phase === "up" || phase === "cancel") {
    const blank = blankPress.get(pointerId) && !el && phase === "up" && button === 0;
    blankPress.delete(pointerId);
    if (blank) activate(document.documentElement, flags);
  }
  if (phase === "down" && !prevented) {
    if (pointerType === "touch") tapFocus = target;
    else { tapFocus = null; pressFocus(target); }
  }
  // A press: the page takes the drag (no scrolling) when it said so in CSS.
  if (phase === "down" && !prevented) {
    for (let n = target; n && n.nodeType === 1; n = n.parentNode) {
      const ta = renderer?.styleOf(n)?.["touch-action"];
      if (ta === "none" || ta === "pinch-zoom") { prevented = true; break; }
    }
  }
  return prevented;
}

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

// Event handler properties (el.oninput = fn, "oninput" in document): a
// browser has them for every event. React checks for them to tell whether
// the `input` event exists, and without them falls back to an old-IE path
// that never sees a field's input (onChange never ran).
const HANDLER_EVENTS = ("abort animationend auxclick beforeinput blur change click contextmenu dblclick error focus focusin focusout " +
  "drag dragend dragenter dragleave dragover dragstart drop input invalid keydown keypress keyup load mousedown " +
  "mouseenter mouseleave mousemove mouseout mouseover mouseup " +
  "pointercancel pointerdown pointermove pointerup reset resize scroll select submit toggle touchcancel touchend " +
  "touchmove touchstart transitionend wheel").split(" ");
for (const proto of [elProto, Object.getPrototypeOf(document)]) {
  for (const type of HANDLER_EVENTS) {
    if (Object.getOwnPropertyDescriptor(proto, "on" + type)) continue;
    Object.defineProperty(proto, "on" + type, {
      get() { return this.__handlers?.get(type)?.fn ?? null; },
      set(fn) {
        const handlers = (this.__handlers ||= new Map());
        const old = handlers.get(type);
        if (old) { this.removeEventListener(type, old.listener); handlers.delete(type); }
        if (typeof fn !== "function") return;
        const listener = function (event) { if (fn.call(this, event) === false) event.preventDefault(); };
        this.addEventListener(type, listener);
        handlers.set(type, { fn, listener });
      },
      configurable: true,
    });
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
    // Through the host (its own compile, not the page's eval: an inline
    // handler is the page's markup, which its CSP's eval rule doesn't cover).
    try { compiled = hostRun.handler ? hostRun.handler(name, attr.value) : new Function("event", attr.value); } catch (e) { console.error(`${name}: ${e}`); continue; }
    if (typeof compiled !== "function") continue;
    const fn = function (event) { if (compiled.call(el, event) === false) event.preventDefault(); };
    el.addEventListener(type, fn);
    bound.set(type, { code: attr.value, fn });
  }
}
// Bound when an event is dispatched, on the elements it reaches (not on
// every element a page adds: a second document-wide mutation observer
// that walked each added subtree made building pages slower).
{
  let proto = Object.getPrototypeOf(document.body);
  while (proto && !Object.prototype.hasOwnProperty.call(proto, "dispatchEvent")) proto = Object.getPrototypeOf(proto);
  if (proto) {
    const orig = proto.dispatchEvent;
    proto.dispatchEvent = function (event) {
      for (let n = this; n && n.nodeType === 1; n = n.parentNode) if (hasInline(n)) bindInline(n);
      return orig.call(this, event);
    };
  }
}
function hasInline(el) {
  if (el.__inline) return true;
  for (const a of el.attributes || []) if (a.name.length > 2 && a.name[0] === "o" && a.name[1] === "n") return true;
  return false;
}

// Each call from the host starts a new task: an animation frame's task
// (runFrame, its callbacks and their microtasks) ends there.
let guardDepth = 0;
function guard(fn) {
  if (guardDepth++ === 0 && renderer) renderer.inFrame = false;
  try { return fn(); } catch (e) { console.error(e); return false; } finally { guardDepth--; }
}

// ---------------------------------------------------------------------------
// The page's style sheets: <style> and <link rel="stylesheet">, in document
// order, read at boot and again whenever one changes (render.js
// sheetChanged), with a CSSOM over them (element.sheet,
// document.styleSheets, insertRule/deleteRule, disabled).

const linkCss = internalWeak(new WeakMap()); // <link> → { href, css } (its asset, read once)
// Per-node state kept on the node's wrapper (a symbol property, not
// enumerable) rather than in a WeakMap: a wrapper holding state is one the
// native DOM keeps while its tree lives; one without any may be replaced
// by an equal new one (dom/store.zig prune).
const ownSlot = (name) => {
  const key = Symbol(name);
  // A frozen or non-extensible target (a page's own EventTarget) keeps its
  // state beside it instead.
  const aside = internalWeak(new WeakMap());
  return {
    get: (o) => (Object.prototype.hasOwnProperty.call(o, key) ? o[key] : aside.get(o)),
    set: (o, v) => {
      if (Object.prototype.hasOwnProperty.call(o, key) || Object.isExtensible(o)) {
        try { Object.defineProperty(o, key, { value: v, writable: true, configurable: true }); return; } catch {}
      }
      aside.set(o, v);
    },
  };
};
const sheetOf = ownSlot("sheet"); // <style>/<link> → its CSSStyleSheet

function isSheetLink(el) {
  const rel = el.getAttribute("rel") || "";
  return /(^|\s)stylesheet(\s|$)/i.test(rel) && !/(^|\s)alternate(\s|$)/i.test(rel) && el.hasAttribute("href");
}

// A sheet owner's own text: a <style>'s, or its <link>'s asset (null when
// it isn't one); a link's load or error event fires once, after boot.
function ownText(el, booting) {
  if (el.localName === "style") return el.textContent;
  const href = el.getAttribute("href");
  let got = linkCss.get(el);
  if (!got || got.href !== href) {
    const css = host.asset(href.replace(/^\.?\//, "")) ?? null;
    linkCss.set(el, (got = { href, css }));
    if (css === null) console.warn(`stylesheet not found: ${href}`);
    if (!booting) queueMicrotask(() => el.dispatchEvent(new Event(css === null ? "error" : "load")));
  }
  return got.css;
}

function pageSheets(booting) {
  const out = [];
  for (const el of document.querySelectorAll("link[rel][href], style")) {
    if (el.localName === "link" && (!isSheetLink(el) || el.hasAttribute("disabled"))) continue;
    const sheet = sheetOf.get(el);
    if (sheet?.disabled) continue;
    const text = ownText(el, booting);
    if (text === null) continue;
    // Rules the page inserted or deleted (CSSOM) stand for the text until
    // the text changes.
    const css = sheet ? sheet.__css(text) : text;
    if (!css) continue;
    const path = el.localName === "link" ? el.getAttribute("href").replace(/^\.?\//, "") : undefined;
    out.push({ owner: el, css, path });
  }
  return out;
}

const sheetsChanged = () => renderer?.sheetChanged();
const indexError = (msg) => (typeof DOMException === "function" ? new DOMException(msg, "IndexSizeError") : new RangeError(msg));

class CSSRule {
  constructor(text, sheet) { this.cssText = text; this.parentStyleSheet = sheet; }
  get selectorText() { const at = this.cssText.indexOf("{"); return at < 0 ? "" : this.cssText.slice(0, at).trim(); }
}

class CSSStyleSheet {
  constructor(owner = null) {
    this.ownerNode = owner;
    this.__text = null;   // the owner's text the rules came from
    this.__rules = null;  // its rules, with the page's insertions and deletions
    this.__list = null;   // cssRules (made again after a change)
    this.__disabled = false;
  }
  get type() { return "text/css"; }
  get href() { return this.ownerNode?.localName === "link" ? this.ownerNode.getAttribute("href") : null; }
  get media() { return { mediaText: this.ownerNode?.getAttribute("media") || "", length: 0 }; }
  get disabled() { return this.__disabled; }
  set disabled(v) { if (this.__disabled !== !!v) { this.__disabled = !!v; sheetsChanged(); } }
  __own() {
    const text = this.ownerNode ? (ownText(this.ownerNode, false) ?? "") : (this.__text ?? "");
    if (this.__rules === null || text !== this.__text) { this.__text = text; this.__rules = splitRules(text); this.__list = null; }
    return this.__rules;
  }
  // The CSS the engine reads: the owner's text while the page hasn't
  // changed the rules, else the rules.
  __css(text) {
    if (this.__rules === null || text !== this.__text) return text;
    return this.__rules.join("\n");
  }
  get cssRules() {
    const rules = this.__own();
    if (!this.__list) {
      this.__list = rules.map((t) => new CSSRule(t, this));
      this.__list.item = (i) => this.__list[i] ?? null;
    }
    return this.__list;
  }
  get rules() { return this.cssRules; }
  insertRule(rule, index = 0) {
    const rules = this.__own();
    if (index < 0 || index > rules.length) throw indexError(`insertRule: index ${index} is beyond ${rules.length} rules`);
    const text = String(rule).trim();
    if (splitRules(text).length !== 1) throw new SyntaxError(`insertRule: not one rule: ${text.slice(0, 60)}`);
    rules.splice(index, 0, text);
    this.__list = null;
    sheetsChanged();
    return index;
  }
  deleteRule(index) {
    const rules = this.__own();
    if (index < 0 || index >= rules.length) throw indexError(`deleteRule: no rule ${index}`);
    rules.splice(index, 1);
    this.__list = null;
    sheetsChanged();
  }
  addRule(sel, style, index) {
    this.insertRule(`${sel} { ${style} }`, index ?? this.__own().length);
    return -1;
  }
  removeRule(index = 0) { this.deleteRule(index); }
  // Constructed sheets only (new CSSStyleSheet()), as in browsers.
  replaceSync(text) {
    if (this.ownerNode) throw new Error("NotAllowedError: replaceSync on a sheet of the document");
    this.__text = String(text);
    this.__rules = splitRules(this.__text);
    this.__list = null;
  }
  replace(text) { this.replaceSync(text); return Promise.resolve(this); }
}
g.CSSStyleSheet = CSSStyleSheet;
g.CSSRule = CSSRule;

function sheetFor(el) {
  if (el.localName === "link" && !isSheetLink(el)) return null;
  let sheet = sheetOf.get(el);
  if (!sheet) sheetOf.set(el, (sheet = new CSSStyleSheet(el)));
  return sheet;
}
for (const tag of ["style", "link"]) {
  const proto = Object.getPrototypeOf(document.createElement(tag));
  Object.defineProperty(proto, "sheet", { get() { return this.isConnected ? sheetFor(this) : null; }, configurable: true });
  if (tag === "style") {
    Object.defineProperty(proto, "disabled", {
      get() { return sheetOf.get(this)?.disabled ?? false; },
      set(v) { const sheet = sheetFor(this); if (sheet) sheet.disabled = v; },
      configurable: true,
    });
  } else {
    Object.defineProperty(proto, "disabled", {
      get() { return this.hasAttribute("disabled"); },
      set(v) { if (v) this.setAttribute("disabled", ""); else this.removeAttribute("disabled"); },
      configurable: true,
    });
  }
}
Object.defineProperty(document, "styleSheets", {
  get() {
    const list = [];
    for (const el of document.querySelectorAll("link[rel][href], style")) {
      const sheet = sheetFor(el);
      if (sheet) list.push(sheet);
    }
    list.item = (i) => list[i] ?? null;
    return list;
  },
  configurable: true,
});

// The engine's way in: read-only for the page (which would otherwise
// replace it and hear every native event), and boot runs once (it runs the
// document's scripts: again, any the page added).
let booted = false;
const oriel = {
  boot(w, h, dark, coarse) {
    if (booted) return;
    booted = true;
    return guard(() => {
      Object.assign(viewport, { width: w, height: h, dark: !!dark, coarse: !!coarse });
      // -Dnative_ui_prof: boot's stages (styles, scripts, events).
      const P = host.prof ? host.now : null, b0 = P && P();
      const engine = new StyleEngine();
      // Parsed sheets kept for the process (host.sheetCache/sheetKeep).
      const sheets = host.sheetCache ? { get: (css, path) => host.sheetCache(css, path), keep: (css, json) => host.sheetKeep(css, json) } : null;
      engine.addSheet(withInputButtons(UA_CSS), sheets, undefined, null, true);
      // Where the WebView is WebKit's, its controls' look; Chrome's on Android.
      if (platform.os === "macos" || platform.os === "ios") engine.addSheet(withInputButtons(UA_CSS_WEBKIT), sheets, undefined, null, true);
      if (platform.os === "macos") engine.addSheet(withInputButtons(UA_CSS_MAC), sheets, undefined, null, true);
      else if (platform.os === "linux") engine.addSheet(withInputButtons(uaCssWebkitGtk(platform.uiFont, platform.accent)), sheets, undefined, null, true);
      else if (platform.os === "android") engine.addSheet(withInputButtons(UA_CSS_CHROME_ANDROID), sheets, undefined, null, true);
      for (const { owner, css, path } of pageSheets(true)) engine.addSheet(css, sheets, path, owner);
      const b1 = P && P();
      renderer = new Renderer(document, engine, host);
      // A <style> or <link> added, removed or changed later (CSS-in-JS,
      // a dev server's styles): read at the next render. Only the boot's
      // sheets go through the process's parsed-sheet cache.
      renderer.syncSheets = () => engine.syncSheets(pageSheets(false), null);
      // The elements marked for :hover, :active and :focus (their
      // data-nui-* attributes): a list the tree stamps renders those rows
      // itself.
      renderer.stateEls = () => {
        const out = [];
        for (const chain of marked.values()) for (const e of chain) out.push(e);
        if (active) out.push(active);
        return out;
      };
      // What changed, for the next render (render.js: only that is made again).
      renderer.observer = new MutationObserver((records) => renderer.note(records));
      renderer.observer.__nuiConnectedOnly = true;
      renderer.observer.__nuiChild = (node, parent) => renderer.noteChild(node, parent);
      renderer.observer.__nuiAttribute = (node, name) => renderer.noteAttribute(node, name);
      renderer.observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
      const b2 = P && P();
      // Templates hold their markup in their content, not as children.
      for (const t of document.querySelectorAll("template")) t.content;
      // The page's scripts, in order, at the top level (like <script> tags).
      for (const s of document.querySelectorAll("script")) {
        const src = s.getAttribute("src");
        const code = src ? host.asset(src.replace(/^\.?\//, "")) : s.textContent;
        if (!code) { if (src) console.warn(`script not found: ${src}`); continue; }
        if (s.getAttribute("type") === "module") {
          // An ES module (Vite's output): its imports and import() load from
          // the app's assets; a failure shows up as a rejected promise.
          try {
            Promise.resolve(hostRun.module(src ? src.replace(/^\.?\//, "") : "inline.js", code)).catch((e) => console.error(e));
          } catch (e) { console.error(e); }
          continue;
        }
        // As a global script (not eval): top-level let/const are shared between scripts.
        try { hostRun.script(src || "inline", code); } catch (e) { console.error(e); }
      }
      // The fonts the rules use, loaded while the window is idle.
      if (host.warmFonts) { try { host.warmFonts(fontSpecs(engine.rules)); } catch (e) { console.error(e); } }
      const b3 = P && P();
      document.dispatchEvent(new Event("DOMContentLoaded", { bubbles: true }));
      fireWindow(new Event("load"));
      watchThemeColor();
      if (P) host.log(1, `PROF boot: styles ${(b1 - b0).toFixed(2)} (${engine.rules.length} rules), renderer ${(b2 - b1).toFixed(2)}, scripts ${(b3 - b2).toFixed(2)}, events ${(P() - b3).toFixed(2)}`);
      return true;
    });
  },
  // A native event on node `id`. Returns true when the page prevented the default.
  event(id, type, data) {
    return guard(() => {
      const el = renderer?.elementFor(id);
      switch (type) {
        case "click": {
          keyboardFocus = false;
          // A touch's focus comes with its tap.
          if (tapFocus && el) pressFocus(el);
          tapFocus = null;
          if (el) activate(el, data | 0);
          return false;
        }
        // A native field's edit: data its new value, or [value, inputType,
        // data] (the edit as beforeinput had it, docs/native-renderer.md).
        case "input": {
          if (!el) return false;
          const [value, inputType, text] = Array.isArray(data) ? data : [data, undefined, undefined];
          renderer.native.set(id, value);
          setNative(el, "value", value);
          edited.add(el);
          el.dispatchEvent(inputEvent("input", inputType, text, false));
          return false;
        }
        // An edit a native field is about to make: data [inputType, data].
        // True when the page prevented it (the field doesn't make it).
        case "beforeinput": {
          if (!el || !Array.isArray(data)) return false;
          const ev = inputEvent("beforeinput", data[0], data[1], true);
          el.dispatchEvent(ev);
          return ev.defaultPrevented;
        }
        case "change": {
          if (!el) return false;
          renderer.native.set(id, data);
          setNative(el, "value", data);
          el.dispatchEvent(new Event("change", { bubbles: true }));
          return false;
        }
        case "key": {
          keyboardFocus = true;
          // A key (not a modifier alone) while an element has focus from a
          // pointer makes it :focus-visible, as browsers do.
          const a = document.__active;
          if (a && !MODIFIER_KEYS.has(data?.[0]) && !a.hasAttribute?.("data-nui-focus-visible")) {
            a.setAttribute?.("data-nui-focus-visible", "");
            setFocusVisible(a);
          }
          return keyEvent(el || a, data);
        }
        case "keyup": return keyEvent(el || document.__active, data, "keyup");
        // A pointer went down, moved, went up or was taken by the system:
        // data [phase, x, y, buttons, pointerId, pointerType, modifiers].
        // True on "down" when the page takes the drag (touch-action: none,
        // or a listener prevented the default): the backend doesn't scroll.
        case "pointer":
          if (data?.[0] === "down" || data?.[0] === 0) {
            keyboardFocus = false;
            if (data[5] === "touch") glide = null;
          }
          return pointerEvent(el, data);
        // The window went to a screen with another scale (data: the new
        // devicePixelRatio): resolution queries' listeners hear it.
        case "dpr": {
          const dpr = +data;
          if (!(dpr > 0) || dpr === viewport.dpr) return false;
          const before = mediaSnapshot();
          viewport.dpr = dpr;
          renderer?.markAll();
          mediaChanged(before);
          return false;
        }
        // The system's accent color changed (data: [r, g, b]): the focus
        // ring and accent-colored controls follow it.
        case "accent": {
          if (!Array.isArray(data) || data.length !== 3) return false;
          platform.accent = data;
          setFocusRingOS(platform.os, data);
          renderer?.markAll();
          return false;
        }
        case "focus": if (el) document.__active = el; return false;
        case "blur": if (el && document.__active === el) document.__active = null; return false;
        case "contextmenu": {
          // data [x, y, button?, buttons?, modifiers?]: the backend's (macOS's
          // Control-click is the primary button's), else from a mouse the
          // secondary button (a touch's long press has none).
          const mouse = lastPointerType !== "touch";
          const [button, buttons] = data.length >= 4 ? [data[2], data[3]] : mouse ? [2, 2] : [0, 0];
          const f = data[4] | 0;
          const ev = new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: data[0], clientY: data[1], button, buttons, shiftKey: !!(f & 1), ctrlKey: !!(f & 2), altKey: !!(f & 4), metaKey: !!(f & 8) });
          const on = el || document.body;
          on.dispatchEvent(ev);
          // The window's listeners see the element (as pointerEvent's fire).
          if (ev.target !== on) Object.defineProperty(ev, "target", { value: on, configurable: true });
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
        // A drag from the system over the page, or its drop (dnd.js): an
        // effect mask (copy 1, move 2, link 4), not a bool.
        case "drag": {
          try { return dnd.dragEvent(el, data) | 0; } catch (e) { console.error(e); return 0; }
        }
      }
      return false;
    });
  },
  // The host's answer to fileRead: the bytes, or null and an error name.
  fileData(reqId, buf, errorName) {
    guard(() => blobs.fileData(reqId, buf, errorName));
  },
  // Scrollers moved (the engine, at most once a frame): [[id, top, left]].
  // "scroll" on each, as browsers fire it (it doesn't bubble; the
  // window's goes to the document, then the window).
  scrolled(list) {
    guard(() => {
      for (const [id, top] of list) {
        // An offset the key scroll's glide didn't set: a wheel took over.
        if (glide?.target === id && typeof top === "number" && !glide.set.some((y) => Math.abs(y - top) <= 1.5)) glide = null;
        if (id === -1) {
          const ev = new Event("scroll", { bubbles: true });
          document.dispatchEvent(ev);
          fireWindow(ev);
          continue;
        }
        const el = renderer?.elementFor(id);
        if (el) el.dispatchEvent(new Event("scroll", { bubbles: false }));
      }
    });
  },
  // The display refreshed (host.vsync): the animation frame.
  vsync(_intervalMs) {
    guard(() => { if (rafPending) runFrame(); });
  },
  timer(id) {
    guard(() => {
      const t = timers.get(id);
      if (!t) return;
      const started = t.repeat ? performance.now() : 0;
      if (!t.repeat) timers.delete(id);
      try { t.fn(...(t.args || [])); }
      finally {
        // A repeating callback can clear itself. Avoid posting a native
        // timeout that would wake the app only to find a canceled timer.
        if (t.repeat && timers.get(id) === t) host.timer(id, Math.max(0, t.ms - (performance.now() - started)));
      }
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
      if (renderer) renderer.markAll();
      fireWindow(new Event("resize"));
      mediaChanged(before);
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
    guard(() => {
      collect();
      renderer?.render();
    });
  },
  dirty() {
    guard(() => renderer?.markAll());
  },
};
Object.defineProperty(g, "__oriel", { value: Object.freeze(oriel), writable: false, configurable: false, enumerable: false });

// <meta name="theme-color"> (the first whose media matches) → the window's
// caption, as the WebView bridge does (core/window_commands.zig): [r, g, b, a]
// 0-255, or null. Sent again only when it changes.
let themeColorSent = "unset";
function updateThemeColor() {
  const meta = [...document.querySelectorAll('meta[name="theme-color"]')].find((m) => !m.getAttribute("media") || mediaMatches(m.getAttribute("media")));
  const c = cssColor(meta?.getAttribute("content") || "");
  const value = c ? [c[0], c[1], c[2], c[3] * 255].map((x) => Math.max(0, Math.min(255, Math.round(x)))) : null;
  const key = JSON.stringify(value);
  if (key === themeColorSent) return;
  themeColorSent = key;
  invoke("oriel:window:setThemeColor", { label: host.label || "main", color: value }).catch(() => {});
}
function watchThemeColor() {
  updateThemeColor();
  const head = document.head || document.documentElement;
  new MutationObserver(() => updateThemeColor()).observe(head, { subtree: true, childList: true, attributes: true });
}

// matchMedia lists whose answer changed since `before` (mediaSnapshot):
// their change listeners.
function mediaChanged(before) {
  if (themeColorSent !== "unset") updateThemeColor();
  for (const ml of mediaLists) {
    const m = ml.matches;
    if (before.get(ml) !== m) for (const fn of ml.listeners) { try { fn({ matches: m, media: ml.media }); } catch (e) { console.error(e); } }
  }
}

function mediaSnapshot() {
  const m = new Map();
  for (const ml of mediaLists) m.set(ml, ml.matches);
  return m;
}
