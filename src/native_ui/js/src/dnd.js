// Drag and drop into the page (docs/drag-and-drop-design.md, section 2):
// DataTransfer, DataTransferItemList, DataTransferItem, DragEvent, and the
// HTML spec's processing model over the engine's "drag" events.
//
// __oriel.event(id, "drag", data) on the hit-tested node (none: the body),
// coordinates in CSS px, operations a mask (copy 1, move 2, link 4),
// modifiers as the pointer's (shift 1, ctrl 2, alt 4, meta 8):
//   ["enter", x, y, allowed, suggested, mods, session, items]  items [[kind, type]]  → effect
//   ["over", x, y, allowed, suggested, mods, session]                                 → effect
//   ["leave", session]                                                                → 0
//   ["drop", x, y, allowed, suggested, mods, session, items]                          → effect performed
// with the drop's items ["string", type, value] or
// ["file", type, name, size, lastModifiedMs, handle].

const COPY = 1, MOVE = 2, LINK = 4;
const OP_NAMES = { none: 0, copy: COPY, move: MOVE, link: LINK };
const opName = (bit) => (bit === COPY ? "copy" : bit === MOVE ? "move" : bit === LINK ? "link" : "none");
// effectAllowed's values and the operations each allows.
const ALLOWED = { none: 0, copy: COPY, move: MOVE, link: LINK, copyMove: COPY | MOVE, copyLink: COPY | LINK, linkMove: LINK | MOVE, all: COPY | MOVE | LINK, uninitialized: COPY | MOVE | LINK };
const allowedName = (mask) => Object.keys(ALLOWED).find((k) => ALLOWED[k] === (mask & 7)) || "none";

// Installs DragEvent, DataTransfer and its items on `g` (where it has none).
// `env`: MouseEvent (main.js's), fire(target, ev) (dispatch, then the
// window's listeners; true when prevented), files (blob.js's
// droppedFile/fileList), editable(el) and dropText(el, text) (the default
// insertion into a field). Returns the engine's entry point, dragEvent.
export function installDnd(g, env) {
  const { MouseEvent, fire, files, editable, dropText } = env;
  const DOMException = g.DOMException;

  // ---------------------------------------------------------------------
  // DataTransfer

  // The drag data store's modes: "rw" (a page's own DataTransfer, and
  // dragstart later), "ro" (drop), "protected" (enter, over, leave), and
  // "disabled" once its event is over (as the spec's, a kept DataTransfer
  // reads nothing).
  // Each DataTransfer's state: { mode, items: [{ kind, type, data | file }],
  // dropEffect, effectAllowed, version, types (cached) }.
  const state = new WeakMap();
  const token = Symbol("DataTransfer");
  const readable = (s) => s.mode === "rw" || s.mode === "ro";
  const changed = (s) => { s.version++; s.types = null; };
  // getData/setData's format: lowercased; "text" is text/plain, "url" text/uri-list.
  const formatOf = (f) => {
    const t = String(f).toLowerCase();
    return t === "text" ? "text/plain" : t === "url" ? "text/uri-list" : t;
  };

  class DataTransfer {
    constructor(own) {
      const s = own?.[token] ? own.state : { mode: "rw", items: [], dropEffect: "none", effectAllowed: "none" };
      s.version = 0;
      s.types = null;
      state.set(this, s);
    }
    get dropEffect() { return state.get(this).dropEffect; }
    set dropEffect(v) { if (Object.hasOwn(OP_NAMES, v)) state.get(this).dropEffect = v; }
    get effectAllowed() { return state.get(this).effectAllowed; }
    set effectAllowed(v) {
      const s = state.get(this);
      if (s.mode === "rw" && Object.hasOwn(ALLOWED, v)) s.effectAllowed = v;
    }
    // A frozen array, the same one until the items change: each string
    // item's type, and "Files" when any item is a file.
    get types() {
      const s = state.get(this);
      if (!s.types) {
        const out = [];
        if (s.mode !== "disabled") {
          for (const it of s.items) if (it.kind === "string") out.push(it.type);
          if (s.items.some((it) => it.kind === "file")) out.push("Files");
        }
        s.types = Object.freeze(out);
      }
      return s.types;
    }
    getData(format) {
      const s = state.get(this);
      if (!readable(s)) return "";
      const type = formatOf(format);
      const it = s.items.find((i) => i.kind === "string" && i.type === type);
      if (!it) return "";
      // "url": the list's first URL (not a # comment).
      if (String(format).toLowerCase() === "url") return it.data.split(/\r?\n/).find((l) => l && !l.startsWith("#")) ?? "";
      return it.data;
    }
    setData(format, data) {
      const s = state.get(this);
      if (s.mode !== "rw") return;
      const type = formatOf(format);
      s.items = s.items.filter((i) => !(i.kind === "string" && i.type === type));
      s.items.push({ kind: "string", type, data: String(data) });
      changed(s);
    }
    clearData(format) {
      const s = state.get(this);
      if (s.mode !== "rw") return;
      const type = format === undefined ? null : formatOf(format);
      s.items = s.items.filter((i) => i.kind !== "string" || (type !== null && i.type !== type));
      changed(s);
    }
    // The dropped files (none while the drag is only passing over).
    get files() {
      const s = state.get(this);
      return files.fileList(readable(s) ? s.items.filter((i) => i.kind === "file").map((i) => i.file) : []);
    }
    get items() {
      const s = state.get(this);
      return (s.list ||= new DataTransferItemList(token, this));
    }
    setDragImage() {} // no drag image here
    get [Symbol.toStringTag]() { return "DataTransfer"; }
  }

  // DataTransferItemList: length, [i], add, remove, clear. Its indexes are
  // own properties, made again when the items change.
  class DataTransferItemList {
    constructor(t, dt) {
      if (t !== token) throw new TypeError("Illegal constructor");
      Object.defineProperty(this, "__dt", { value: dt });
      Object.defineProperty(this, "__seen", { value: { version: -1, count: 0 }, writable: true });
      this.__sync();
    }
    // The index properties, after a change.
    __sync() {
      const s = state.get(this.__dt);
      if (this.__seen.version === s.version && this.__seen.mode === s.mode) return s;
      const items = s.mode === "disabled" ? [] : s.items;
      for (let i = items.length; i < this.__seen.count; i++) delete this[i];
      items.forEach((it, i) => {
        it.item ||= new DataTransferItem(token, this.__dt, it);
        Object.defineProperty(this, i, { value: it.item, enumerable: true, configurable: true });
      });
      this.__seen = { version: s.version, mode: s.mode, count: items.length };
      return s;
    }
    get length() { const s = this.__sync(); return s.mode === "disabled" ? 0 : s.items.length; }
    add(data, type) {
      const s = this.__sync();
      if (s.mode !== "rw") return null;
      let entry;
      if (files.isBlob(data) && data instanceof g.File) entry = { kind: "file", type: data.type, file: data };
      else {
        if (type === undefined) throw new TypeError("DataTransferItemList.add: a string needs its type");
        const t = String(type).toLowerCase();
        if (s.items.some((i) => i.kind === "string" && i.type === t)) throw new DOMException(`An item of type ${t} exists`, "NotSupportedError");
        entry = { kind: "string", type: t, data: String(data) };
      }
      s.items.push(entry);
      changed(s);
      this.__sync();
      return (entry.item ||= new DataTransferItem(token, this.__dt, entry));
    }
    remove(i) {
      const s = this.__sync();
      if (s.mode !== "rw") throw new DOMException("The DataTransfer is not writable", "InvalidStateError");
      if (i >= 0 && i < s.items.length) { s.items.splice(i, 1); changed(s); this.__sync(); }
    }
    clear() {
      const s = this.__sync();
      if (s.mode !== "rw") return;
      s.items = [];
      changed(s);
      this.__sync();
    }
    *[Symbol.iterator]() { for (let i = 0; i < this.length; i++) yield this[i]; }
    get [Symbol.toStringTag]() { return "DataTransferItemList"; }
  }

  class DataTransferItem {
    constructor(t, dt, entry) {
      if (t !== token) throw new TypeError("Illegal constructor");
      Object.defineProperty(this, "__dt", { value: dt });
      Object.defineProperty(this, "__entry", { value: entry });
    }
    get kind() { return state.get(this.__dt).mode === "disabled" ? "" : this.__entry.kind; }
    get type() { return state.get(this.__dt).mode === "disabled" ? "" : this.__entry.type; }
    // The string, to `cb` as a microtask (nothing while it is protected).
    getAsString(cb) {
      if (typeof cb !== "function" || this.__entry.kind !== "string" || !readable(state.get(this.__dt))) return;
      const data = this.__entry.data;
      queueMicrotask(() => cb(data));
    }
    getAsFile() {
      return this.__entry.kind === "file" && readable(state.get(this.__dt)) ? this.__entry.file : null;
    }
    get [Symbol.toStringTag]() { return "DataTransferItem"; }
  }

  // A DataTransfer over the session's store, in `mode`.
  const transfer = (mode, items, effectAllowed, dropEffect) =>
    new DataTransfer({ [token]: true, state: { mode, items, effectAllowed, dropEffect } });

  // ---------------------------------------------------------------------
  // DragEvent

  class DragEvent extends MouseEvent {
    constructor(type, init = {}) {
      super(type, init);
      this.dataTransfer = init.dataTransfer ?? null;
      this.relatedTarget = init.relatedTarget ?? null;
    }
  }

  // ---------------------------------------------------------------------
  // The processing model

  // The OS drag over the window: { id (the engine's session), target (the
  // current target element), items (the store: enter's kinds and types),
  // op (the last over's effect) }.
  let session = null;

  // An initial dropEffect, from what the source allows and what the OS
  // suggests (the spec's table: copy before link before move when it
  // leaves the choice open).
  function initialEffect(allowed, suggested) {
    const s = suggested & allowed;
    if (s === COPY || s === MOVE || s === LINK) return s;
    for (const bit of [COPY, LINK, MOVE]) if (allowed & bit) return bit;
    return 0;
  }

  const hasText = (items) => items.some((i) => i.kind === "string" && i.type === "text/plain");

  // One DragEvent at `target`, with its DataTransfer readable only while it
  // is dispatched. True when it was canceled.
  function dispatch(target, type, init, dt, cancelable) {
    const ev = new DragEvent(type, { bubbles: true, cancelable, ...init, dataTransfer: dt });
    try { return fire(target, ev); } finally { state.get(dt).mode = "disabled"; changed(state.get(dt)); }
  }

  // enter and over: the target follows the pointer (dragenter on the new
  // one, then dragleave on the old), then dragover; returns the effect.
  function over(el, x, y, allowed, suggested, mods) {
    const target = el || g.document.body;
    const init = { clientX: x, clientY: y, buttons: 1, ...mods };
    const effectAllowed = allowedName(allowed);
    const protectedDt = () => transfer("protected", session.items, effectAllowed, opName(initialEffect(allowed, suggested)));
    const old = session.target;
    if (target !== old || !old?.isConnected) {
      session.target = target;
      dispatch(target, "dragenter", { ...init, relatedTarget: old }, protectedDt(), true);
      if (old?.isConnected && old !== target) dispatch(old, "dragleave", { ...init, relatedTarget: target }, protectedDt(), false);
    }
    const now = session.target;
    if (!now.isConnected) return (session.op = 0);
    const dt = protectedDt();
    let op;
    if (dispatch(now, "dragover", init, dt, true)) {
      // The page took it: its dropEffect, if the source allows it.
      op = OP_NAMES[state.get(dt).dropEffect] & allowed;
    } else {
      // Not taken: a field accepts it (text goes in; a file's drop still
      // reaches the page, as WebKit and Chromium deliver it, but inserts
      // nothing), else nothing.
      op = editable(now) && session.items.length ? (allowed & COPY ? COPY : allowed & MOVE) : 0;
    }
    return (session.op = op);
  }

  function start(id, items) {
    session = { id, target: null, items, op: 0 };
  }
  // enter's [[kind, type]] as store items (types not readable yet).
  const kinds = (list) => (Array.isArray(list) ? list : []).map(([kind, type]) => ({ kind: kind === "file" ? "file" : "string", type: String(type ?? "").toLowerCase() }));
  // The drop's payload as store items; repeated string types keep the first.
  function payload(list) {
    const out = [];
    for (const it of Array.isArray(list) ? list : []) {
      const type = String(it[1] ?? "").toLowerCase();
      if (it[0] === "file") out.push({ kind: "file", type: type, file: files.droppedFile(String(it[2] ?? ""), type, it[3], it[4], it[5]) });
      else if (!out.some((i) => i.kind === "string" && i.type === type)) out.push({ kind: "string", type, data: String(it[2] ?? "") });
    }
    return out;
  }

  function dragEvent(el, data) {
    if (!Array.isArray(data)) return 0;
    const phase = data[0];
    if (phase === "leave") {
      // A late leave (an older drag's) changes nothing.
      if (!session || session.id !== data[1]) return 0;
      const { target, items } = session;
      session = null;
      if (target?.isConnected) dispatch(target, "dragleave", { buttons: 1 }, transfer("protected", items, "none", "none"), false);
      return 0;
    }
    const [, x, y, allowed, suggested, flags, id, items] = data;
    const mods = { shiftKey: !!(flags & 1), ctrlKey: !!(flags & 2), altKey: !!(flags & 4), metaKey: !!(flags & 8) };
    const mask = allowed & 7;
    if (phase === "enter") {
      if (!session || session.id !== id) start(id, kinds(items));
      else session.items = kinds(items);
      return over(el, x, y, mask, suggested, mods);
    }
    if (phase === "over") {
      if (!session || session.id !== id) start(id, []);
      return over(el, x, y, mask, suggested, mods);
    }
    if (phase !== "drop") return 0;
    const dropped = payload(items);
    // A drop without its drag's state (a leave came first, the overs went
    // elsewhere, the target left the document): its enter and over first,
    // at the drop's point.
    if (!session || session.id !== id || !session.target?.isConnected) {
      start(id, dropped.map(({ kind, type }) => ({ kind, type })));
      over(el, x, y, mask, suggested, mods);
    }
    const { target, op } = session;
    session = null;
    const init = { clientX: x, clientY: y, buttons: 0, ...mods };
    // The last over's effect was none: no drop, only the leave.
    if (!op) {
      if (target.isConnected) dispatch(target, "dragleave", init, transfer("protected", dropped, allowedName(mask), "none"), false);
      return 0;
    }
    const dt = transfer("ro", dropped, allowedName(mask), opName(op));
    let effect = 0;
    if (dispatch(target, "drop", init, dt, true)) effect = OP_NAMES[state.get(dt).dropEffect] & mask;
    else if (editable(target) && hasText(dropped)) {
      // The default: the text goes into the field, as a native edit.
      const text = dropped.find((i) => i.kind === "string" && i.type === "text/plain").data;
      if (dropText(target, text)) effect = mask & COPY ? COPY : mask & MOVE;
    }
    return effect;
  }

  g.DragEvent ??= DragEvent;
  g.DataTransfer ??= DataTransfer;
  g.DataTransferItemList ??= DataTransferItemList;
  g.DataTransferItem ??= DataTransferItem;
  return { dragEvent };
}
