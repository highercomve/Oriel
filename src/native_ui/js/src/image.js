// <img> and new Image() for the page: the backends draw images, so the page
// learns an image's size from its file's header (PNG, JPEG, GIF, WebP,
// BMP): naturalWidth/naturalHeight, complete, decode(), and "load" or
// "error" after its src is set, as a browser fires them once it decoded.

// [width, height] from an image file's first bytes, or null.
export function imageSize(b) {
  if (!b || b.length < 24) return null;
  const u16 = (i) => (b[i] << 8) | b[i + 1], u16le = (i) => b[i] | (b[i + 1] << 8);
  const u32 = (i) => ((b[i] << 24) >>> 0) + (b[i + 1] << 16) + (b[i + 2] << 8) + b[i + 3];
  const u32le = (i) => (b[i] | (b[i + 1] << 8) | (b[i + 2] << 16)) + ((b[i + 3] << 24) >>> 0);
  // PNG: the IHDR chunk right after the signature.
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return [u32(16), u32(20)];
  // GIF: the logical screen.
  if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) return [u16le(6), u16le(8)];
  // BMP: the info header (a negative height is a top-down bitmap).
  if (b[0] === 0x42 && b[1] === 0x4d) return [Math.abs(u32le(18) | 0), Math.abs(u32le(22) | 0)];
  // WebP: lossy (VP8), lossless (VP8L) or extended (VP8X).
  if (b[0] === 0x52 && b[1] === 0x49 && b[8] === 0x57 && b[9] === 0x45 && b.length >= 30) {
    const kind = String.fromCharCode(b[12], b[13], b[14], b[15]);
    if (kind === "VP8 ") return [u16le(26) & 0x3fff, u16le(28) & 0x3fff];
    if (kind === "VP8L") { const v = u32le(21); return [(v & 0x3fff) + 1, ((v >> 14) & 0x3fff) + 1]; }
    if (kind === "VP8X") return [1 + (b[24] | (b[25] << 8) | (b[26] << 16)), 1 + (b[27] | (b[28] << 8) | (b[29] << 16))];
    return null;
  }
  // JPEG: the first start-of-frame marker (not DHT, JPG or DAC).
  if (b[0] === 0xff && b[1] === 0xd8) {
    for (let i = 2; i + 9 < b.length;) {
      if (b[i] !== 0xff) { i++; continue; }
      const m = b[i + 1];
      if (m === 0xd8 || m === 0x01 || (m >= 0xd0 && m <= 0xd7) || m === 0xff) { i += m === 0xff ? 1 : 2; continue; }
      if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) return [u16(i + 7), u16(i + 5)];
      i += 2 + u16(i + 2);
    }
  }
  return null;
}

// Install on the page: `bytesOf(src)` gives a URL's bytes (a data: URL's, an
// app asset's), or null; `later(fn)` runs fn after the current task;
// `fire(el, type)` dispatches the browser's event.
export function installImages(g, document, { bytesOf, later, fire }) {
  const proto = Object.getPrototypeOf(document.createElement("img"));
  const sizes = new Map(); // src → [w, h] | null, the last few
  const sizeOf = (src) => {
    if (!src) return null;
    if (sizes.has(src)) return sizes.get(src);
    let size = null;
    try { size = imageSize(bytesOf(src)); } catch {}
    if (sizes.size >= 32) sizes.delete(sizes.keys().next().value);
    sizes.set(src, size);
    return size;
  };
  const isImg = (el) => el.localName === "img";
  const srcDesc = Object.getOwnPropertyDescriptor(proto, "src");
  const def = (name, desc) => Object.defineProperty(proto, name, { ...desc, configurable: true });
  def("naturalWidth", { get() { return isImg(this) ? sizeOf(this.getAttribute("src"))?.[0] ?? 0 : undefined; } });
  def("naturalHeight", { get() { return isImg(this) ? sizeOf(this.getAttribute("src"))?.[1] ?? 0 : undefined; } });
  def("complete", { get() { return isImg(this) ? !this.getAttribute("src") || sizes.has(this.getAttribute("src")) : undefined; } });
  def("src", {
    get() { return srcDesc?.get ? srcDesc.get.call(this) : this.getAttribute("src") || ""; },
    set(v) {
      this.setAttribute("src", String(v));
      if (!isImg(this)) return;
      // Decoded after this task: "load" with its size, else "error".
      const el = this, src = String(v);
      later(() => { if (el.getAttribute("src") === src) fire(el, sizeOf(src) ? "load" : "error"); });
    },
  });
  def("decode", { value: function decode() {
    return new Promise((resolve, reject) => later(() => (sizeOf(this.getAttribute("src")) ? resolve() : reject(new Error("EncodingError")))));
  }, writable: true });
  // new Image(width, height): a detached <img>.
  function Image(width, height) {
    const img = document.createElement("img");
    if (width !== undefined) img.setAttribute("width", String(width));
    if (height !== undefined) img.setAttribute("height", String(height));
    return img;
  }
  Image.prototype = proto;
  g.Image = Image;
}
