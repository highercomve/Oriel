// Blob, File, FileList and FileReader (docs/drag-and-drop-design.md,
// section 2), for files dropped into the page.
//
// A Blob is a list of segments: bytes held here ({ bytes }) or a range of
// a dropped file ({ ref, offset, length }), where `ref` is the file's
// FileRef ({ handle }, the engine's drop table key; never a path). A File
// and its slices share one FileRef; once none is reachable any more, the
// handle goes back to the engine (host.fileRelease).
//
// The host's side (optional: without fileRead, reading a dropped file
// fails with NotReadableError):
//   fileRead(reqId, handle, offset, length)  → later fileData(reqId, ArrayBuffer | null, errorName)
//   fileRelease(handle)
// Reads are always asynchronous, as in a browser's window.

// The engine reads at most this much at once (drop.zig); larger reads go
// in pieces.
const READ_CHUNK = 64 * 1024 * 1024;

// QuickJS has no DOMException: the errors the web gives (a name and a
// message), for the page's checks of `e.name`.
function domException(g) {
  if (typeof g.DOMException === "function") return g.DOMException;
  class DOMException extends Error {
    constructor(message = "", name = "Error") {
      super(message);
      Object.defineProperty(this, "name", { value: String(name), configurable: true, writable: true });
    }
  }
  return (g.DOMException = DOMException);
}

// ---------------------------------------------------------------------------
// UTF-8 (QuickJS has no TextEncoder/TextDecoder)

// A string as UTF-8; a lone surrogate becomes U+FFFD, as Blob does.
export function utf8Encode(s) {
  const out = new Uint8Array(s.length * 3);
  let n = 0;
  for (let i = 0; i < s.length; i++) {
    let c = s.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdfff) {
      const d = c <= 0xdbff && i + 1 < s.length ? s.charCodeAt(i + 1) : 0;
      if (d >= 0xdc00 && d <= 0xdfff) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++; }
      else c = 0xfffd;
    }
    if (c < 0x80) out[n++] = c;
    else if (c < 0x800) { out[n++] = 0xc0 | (c >> 6); out[n++] = 0x80 | (c & 63); }
    else if (c < 0x10000) { out[n++] = 0xe0 | (c >> 12); out[n++] = 0x80 | ((c >> 6) & 63); out[n++] = 0x80 | (c & 63); }
    else { out[n++] = 0xf0 | (c >> 18); out[n++] = 0x80 | ((c >> 12) & 63); out[n++] = 0x80 | ((c >> 6) & 63); out[n++] = 0x80 | (c & 63); }
  }
  return out.slice(0, n);
}

// UTF-8 bytes as a string, as TextDecoder does it: a leading BOM is
// skipped, and each ill-formed sequence (its maximal valid prefix) becomes
// one U+FFFD.
export function utf8Decode(b) {
  let i = b.length >= 3 && b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf ? 3 : 0;
  let out = "";
  let units = [];
  const unit = (u) => {
    units.push(u);
    if (units.length >= 8192) { out += String.fromCharCode.apply(null, units); units = []; }
  };
  const point = (cp) => {
    if (cp < 0x10000) unit(cp);
    else { cp -= 0x10000; unit(0xd800 + (cp >> 10)); unit(0xdc00 + (cp & 0x3ff)); }
  };
  while (i < b.length) {
    const c = b[i];
    if (c < 0x80) { unit(c); i++; continue; }
    let need, cp, lower = 0x80, upper = 0xbf;
    if (c >= 0xc2 && c <= 0xdf) { need = 1; cp = c & 0x1f; }
    else if (c >= 0xe0 && c <= 0xef) { need = 2; cp = c & 0xf; if (c === 0xe0) lower = 0xa0; if (c === 0xed) upper = 0x9f; }
    else if (c >= 0xf0 && c <= 0xf4) { need = 3; cp = c & 7; if (c === 0xf0) lower = 0x90; if (c === 0xf4) upper = 0x8f; }
    else { unit(0xfffd); i++; continue; }
    let j = i + 1, k = 0;
    for (; k < need && j < b.length; k++, j++) {
      const d = b[j];
      if (d < lower || d > upper) break;
      lower = 0x80; upper = 0xbf;
      cp = (cp << 6) | (d & 0x3f);
    }
    // Cut short: one replacement for what was read; the byte that broke
    // the sequence is read again.
    point(k < need ? 0xfffd : cp);
    i = j;
  }
  return out + String.fromCharCode.apply(null, units);
}

// An ArrayBuffer from any realm (the host's, a test's).
const isArrayBuffer = (v) => Object.prototype.toString.call(v) === "[object ArrayBuffer]";

const B64 ="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function base64(b) {
  let out = "";
  let chunk = [];
  let i = 0;
  for (; i + 2 < b.length; i += 3) {
    const n = (b[i] << 16) | (b[i + 1] << 8) | b[i + 2];
    chunk.push(B64[n >> 18], B64[(n >> 12) & 63], B64[(n >> 6) & 63], B64[n & 63]);
    if (chunk.length >= 32768) { out += chunk.join(""); chunk = []; }
  }
  if (i < b.length) {
    const n = (b[i] << 16) | ((b[i + 1] ?? 0) << 8);
    chunk.push(B64[n >> 18], B64[(n >> 12) & 63], i + 1 < b.length ? B64[(n >> 6) & 63] : "=", "=");
  }
  return out + chunk.join("");
}

// ---------------------------------------------------------------------------

// Installs Blob, File, FileList and FileReader on `g` (where it has none)
// and returns the runtime's side: fileData (the host's answers) and
// droppedFile/fileList (dnd.js).
export function installBlob(g, host) {
  const DOMException = domException(g);
  const notReadable = () => new DOMException("The file could not be read", "NotReadableError");

  // Each Blob's segments, size and type (kept off the object: a page may
  // define what it likes on a File, file-selector adds `path`).
  const state = new WeakMap();
  const internal = Symbol("internal");

  // A dropped file's handle goes back to the engine once no File or slice
  // holds its FileRef.
  const released = new FinalizationRegistry((handle) => {
    try { host.fileRelease?.(handle); } catch (e) { console.error(e); }
  });

  // Reads the host is answering: reqId → { resolve, reject, ref } (the ref
  // stays alive until the answer).
  const reads = new Map();
  let readSeq = 1;
  function readHandle(ref, offset, length) {
    return new Promise((resolve, reject) => {
      if (typeof host.fileRead !== "function") { reject(notReadable()); return; }
      const id = readSeq++;
      reads.set(id, { resolve, reject, ref, length });
      try { host.fileRead(id, ref.handle, offset, length); }
      catch (e) { reads.delete(id); console.error(e); reject(notReadable()); }
    });
  }
  // The host's answer to fileRead: the bytes, or null and the error's name.
  // A short answer means the file changed (snapshot semantics).
  function fileData(reqId, buf, errorName) {
    const r = reads.get(reqId);
    if (!r) return;
    reads.delete(reqId);
    const bytes = isArrayBuffer(buf) ? new Uint8Array(buf) : ArrayBuffer.isView(buf) ? new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength) : null;
    if (!bytes || bytes.length !== r.length) {
      r.reject(errorName ? new DOMException("The file could not be read", String(errorName)) : notReadable());
      return;
    }
    r.resolve(bytes);
  }

  // All of a blob's bytes, one segment after another.
  async function readAll(blob) {
    const s = state.get(blob);
    const out = new Uint8Array(s.size);
    let at = 0;
    for (const seg of s.segs) {
      if (seg.bytes) { out.set(seg.bytes, at); at += seg.bytes.length; continue; }
      for (let off = 0; off < seg.length; off += READ_CHUNK) {
        const n = Math.min(READ_CHUNK, seg.length - off);
        out.set(await readHandle(seg.ref, seg.offset + off, n), at);
        at += n;
      }
    }
    return out;
  }

  const bytesOf = (part) => {
    if (isArrayBuffer(part)) return new Uint8Array(part.slice(0));
    if (ArrayBuffer.isView(part)) return new Uint8Array(part.buffer.slice(part.byteOffset, part.byteOffset + part.byteLength));
    return null;
  };
  // A type as Blob keeps it: lowercased, "" when not printable ASCII.
  const cleanType = (t) => {
    const s = t === undefined ? "" : String(t);
    return /^[\x20-\x7e]*$/.test(s) ? s.toLowerCase() : "";
  };
  function segmentsOf(parts) {
    const segs = [];
    if (parts === undefined || parts === null) return segs;
    if (typeof parts !== "object" || typeof parts[Symbol.iterator] !== "function") throw new TypeError("Blob: the parts must be a sequence");
    for (const part of parts) {
      const own = part && typeof part === "object" ? state.get(part) : undefined;
      if (own) { segs.push(...own.segs); continue; }
      const bytes = bytesOf(part) || utf8Encode(String(part));
      if (bytes.length) segs.push({ bytes });
    }
    return segs;
  }
  const sizeOf = (segs) => segs.reduce((n, s) => n + (s.bytes ? s.bytes.length : s.length), 0);

  class Blob {
    constructor(parts, options = {}) {
      // Internal construction (slices, dropped files): the segments as given.
      const segs = parts?.[internal] ? parts.segs : segmentsOf(parts);
      state.set(this, { segs, size: sizeOf(segs), type: cleanType(options?.type) });
    }
    get size() { return state.get(this).size; }
    get type() { return state.get(this).type; }
    // Bytes [start, end) as a new Blob: no reading, a dropped file's
    // segments narrow. Negative offsets count from the end.
    slice(start, end, type) {
      const { segs, size } = state.get(this);
      const rel = (v, d) => {
        if (v === undefined) return d;
        const n = Math.trunc(+v) || 0;
        return n < 0 ? Math.max(size + n, 0) : Math.min(n, size);
      };
      const from = rel(start, 0), to = Math.max(rel(end, size), from);
      const out = [];
      let at = 0;
      for (const seg of segs) {
        const len = seg.bytes ? seg.bytes.length : seg.length;
        const a = Math.max(from - at, 0), b = Math.min(to - at, len);
        if (b > a) out.push(seg.bytes ? { bytes: seg.bytes.subarray(a, b) } : { ref: seg.ref, offset: seg.offset + a, length: b - a });
        at += len;
        if (at >= to) break;
      }
      return new Blob({ [internal]: true, segs: out }, { type });
    }
    arrayBuffer() { return readAll(this).then((b) => b.buffer); }
    bytes() { return readAll(this); }
    text() { return readAll(this).then(utf8Decode); }
    get [Symbol.toStringTag]() { return "Blob"; }
  }

  class File extends Blob {
    constructor(bits, name, options = {}) {
      if (arguments.length < 2) throw new TypeError("File: a name is required");
      super(bits, options);
      // Plain data properties: the File stays extensible and configurable.
      this.name = String(name);
      const lm = options?.lastModified;
      this.lastModified = lm === undefined ? Date.now() : Math.trunc(+lm) || 0;
      this.webkitRelativePath = "";
    }
    get [Symbol.toStringTag]() { return "File"; }
  }

  // A dropped file: its bytes are in the engine, under `handle`.
  function droppedFile(name, type, size, lastModified, handle) {
    const ref = { handle };
    released.register(ref, handle);
    const length = Math.max(0, Math.trunc(+size) || 0);
    const segs = length ? [{ ref, offset: 0, length }] : [];
    const f = new File({ [internal]: true, segs }, name, { type, lastModified });
    // An empty file still holds its handle until it goes.
    if (!length) state.get(f).ref = ref;
    return f;
  }

  // FileList: length, item(i) and [i]. Not constructible by the page.
  const listToken = Symbol("FileList");
  class FileList {
    constructor(token, files) {
      if (token !== listToken) throw new TypeError("Illegal constructor");
      files.forEach((f, i) => Object.defineProperty(this, i, { value: f, enumerable: true }));
      Object.defineProperty(this, "length", { value: files.length });
    }
    item(i) { return this[i >>> 0] ?? null; }
    *[Symbol.iterator]() { for (let i = 0; i < this.length; i++) yield this[i]; }
    get [Symbol.toStringTag]() { return "FileList"; }
  }
  const fileList = (files) => new FileList(listToken, files);

  // FileReader: an EventTarget (loadstart, progress, load or error or
  // abort, then loadend; and their on* properties).
  const Base = typeof g.EventTarget === "function" ? g.EventTarget : class {};
  const EVENTS = ["loadstart", "progress", "load", "abort", "error", "loadend"];
  class FileReader extends Base {
    constructor() {
      super();
      this.readyState = 0;
      this.result = null;
      this.error = null;
      this.__gen = 0; // a read's number: abort() and a newer read drop older answers
    }
    readAsArrayBuffer(blob) { this.__read(blob, (b) => b.buffer); }
    readAsText(blob, _encoding) { this.__read(blob, utf8Decode); } // UTF-8 only
    readAsDataURL(blob) { this.__read(blob, (b) => `data:${blob.type || "application/octet-stream"};base64,${base64(b)}`); }
    readAsBinaryString(blob) {
      this.__read(blob, (b) => { let s = ""; for (let i = 0; i < b.length; i += 8192) s += String.fromCharCode.apply(null, b.subarray(i, i + 8192)); return s; });
    }
    abort() {
      if (this.readyState !== 1) return;
      this.__gen++;
      this.readyState = 2;
      this.result = null;
      this.__fire("abort");
      this.__fire("loadend");
    }
    __read(blob, convert) {
      if (!state.has(blob)) throw new TypeError("FileReader: not a Blob");
      if (this.readyState === 1) throw new DOMException("A read is in progress", "InvalidStateError");
      const gen = ++this.__gen;
      this.readyState = 1;
      this.result = null;
      this.error = null;
      const total = blob.size;
      queueMicrotask(() => { if (gen === this.__gen) this.__fire("loadstart", 0, total); });
      readAll(blob).then((bytes) => {
        if (gen !== this.__gen) return;
        let result;
        try { result = convert(bytes); } catch (e) { result = null; console.error(e); }
        this.readyState = 2;
        this.result = result;
        this.__fire("progress", total, total);
        this.__fire("load", total, total);
        if (this.readyState !== 1) this.__fire("loadend", total, total);
      }, (err) => {
        if (gen !== this.__gen) return;
        this.readyState = 2;
        this.error = err;
        this.__fire("error");
        if (this.readyState !== 1) this.__fire("loadend");
      });
    }
    // A ProgressEvent (lengthComputable, loaded, total).
    __fire(type, loaded = 0, total = 0) {
      const ev = new g.Event(type);
      Object.defineProperties(ev, {
        lengthComputable: { value: total > 0, configurable: true },
        loaded: { value: loaded, configurable: true },
        total: { value: total, configurable: true },
      });
      try { this.dispatchEvent(ev); } catch (e) { console.error(e); }
    }
  }
  for (const [i, name] of ["EMPTY", "LOADING", "DONE"].entries()) {
    Object.defineProperty(FileReader, name, { value: i });
    Object.defineProperty(FileReader.prototype, name, { value: i });
  }
  // Without the base's own, a small listener list.
  if (typeof Base.prototype.dispatchEvent !== "function") {
    Object.assign(FileReader.prototype, {
      addEventListener(type, fn) { ((this.__listeners ||= new Map()).get(type) || this.__listeners.set(type, new Set()).get(type)).add(fn); },
      removeEventListener(type, fn) { this.__listeners?.get(type)?.delete(fn); },
      dispatchEvent(ev) {
        Object.defineProperty(ev, "target", { value: this, configurable: true });
        Object.defineProperty(ev, "currentTarget", { value: this, configurable: true });
        for (const fn of [...(this.__listeners?.get(ev.type) || [])]) {
          try { typeof fn === "function" ? fn.call(this, ev) : fn.handleEvent(ev); } catch (e) { console.error(e); }
        }
        return !ev.defaultPrevented;
      },
    });
  }
  // reader.onload = fn: a listener, so it sees the event's target as
  // addEventListener's do.
  for (const type of EVENTS) {
    Object.defineProperty(FileReader.prototype, "on" + type, {
      get() { return this.__on?.get(type)?.fn ?? null; },
      set(fn) {
        const on = (this.__on ||= new Map());
        const old = on.get(type);
        if (old) { this.removeEventListener(type, old.listener); on.delete(type); }
        if (typeof fn !== "function") return;
        const listener = function (event) { return fn.call(this, event); };
        this.addEventListener(type, listener);
        on.set(type, { fn, listener });
      },
      configurable: true,
    });
  }

  g.Blob ??= Blob;
  g.File ??= File;
  g.FileList ??= FileList;
  g.FileReader ??= FileReader;
  return { fileData, droppedFile, fileList, isBlob: (b) => state.has(b) };
}
