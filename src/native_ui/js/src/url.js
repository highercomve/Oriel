// URL and URLSearchParams for the page (QuickJS has neither). Bundlers use
// `new URL("asset.png", import.meta.url)` for assets, routers use
// `new URL(location.href)` and searchParams. This covers hierarchical URLs
// (app://, https://, file://) with relative resolution; it doesn't do IDNA
// or percent-encode hosts.

const SPECIAL = { "http:": "80", "https:": "443", "ws:": "80", "wss:": "443", "ftp:": "21", "file:": "", "app:": "" };

function parseAbsolute(s) {
  const m = /^([a-zA-Z][a-zA-Z0-9+.-]*:)(.*)$/.exec(s);
  if (!m) return null;
  const protocol = m[1].toLowerCase();
  let rest = m[2];
  let username = "", password = "", hostname = "", port = "";
  let hasAuthority = false;
  if (rest.startsWith("//")) {
    hasAuthority = true;
    rest = rest.slice(2);
    const end = rest.search(/[/?#]/);
    let auth = end < 0 ? rest : rest.slice(0, end);
    rest = end < 0 ? "" : rest.slice(end);
    const at = auth.lastIndexOf("@");
    if (at >= 0) {
      const cred = auth.slice(0, at);
      auth = auth.slice(at + 1);
      const c = cred.indexOf(":");
      username = c < 0 ? cred : cred.slice(0, c);
      password = c < 0 ? "" : cred.slice(c + 1);
    }
    const pm = /^(\[[^\]]*\]|[^:]*)(?::(\d*))?$/.exec(auth);
    if (!pm) return null;
    hostname = pm[1].toLowerCase();
    port = pm[2] || "";
    if (SPECIAL[protocol] === port) port = "";
  }
  const q = rest.indexOf("?"), h = rest.indexOf("#");
  const pathEnd = q >= 0 ? q : h >= 0 ? h : rest.length;
  let pathname = rest.slice(0, pathEnd);
  let search = "", hash = "";
  if (h >= 0) hash = rest.slice(h);
  if (q >= 0) search = rest.slice(q, h >= 0 && h > q ? h : rest.length);
  if (hasAuthority || protocol in SPECIAL) pathname = normalize(pathname || "/");
  return { protocol, username, password, hostname, port, pathname, search: search === "?" ? "" : search, hash: hash === "#" ? "" : hash, hasAuthority };
}

// Resolves "." and ".." segments.
function normalize(path) {
  const out = [];
  const segs = path.split("/");
  for (let i = 0; i < segs.length; i++) {
    const s = segs[i];
    if (s === "..") { if (out.length > 1) out.pop(); if (i === segs.length - 1) out.push(""); }
    else if (s === ".") { if (i === segs.length - 1) out.push(""); }
    else out.push(s);
  }
  const p = out.join("/");
  return p.startsWith("/") ? p : "/" + p;
}

function resolve(input, base) {
  const abs = parseAbsolute(input);
  if (abs) return abs;
  if (!base) return null;
  const b = typeof base === "string" ? parseAbsolute(base) : base;
  if (!b) return null;
  const r = { ...b, search: "", hash: "" };
  if (input.startsWith("//")) return parseAbsolute(b.protocol + input);
  if (input === "") return { ...b, hash: "" };
  if (input[0] === "#") return { ...b, hash: input === "#" ? "" : input };
  if (input[0] === "?") { const h = input.indexOf("#"); r.search = h < 0 ? input : input.slice(0, h); r.hash = h < 0 ? "" : input.slice(h); if (r.search === "?") r.search = ""; return r; }
  const q = input.search(/[?#]/);
  let path = q < 0 ? input : input.slice(0, q);
  const tail = q < 0 ? "" : input.slice(q);
  if (path[0] !== "/") path = b.pathname.slice(0, b.pathname.lastIndexOf("/") + 1) + path;
  r.pathname = normalize(path);
  if (tail) {
    const h = tail.indexOf("#");
    r.search = h < 0 ? tail : tail.slice(0, h);
    r.hash = h < 0 ? "" : tail.slice(h);
    if (r.search === "?") r.search = "";
    if (r.hash === "#") r.hash = "";
  }
  return r;
}

export class URLSearchParams {
  constructor(init = "") {
    this._list = [];
    this._url = null;
    if (init instanceof URLSearchParams) this._list = init._list.map((p) => [...p]);
    else if (Array.isArray(init)) this._list = init.map(([k, v]) => [String(k), String(v)]);
    else if (init && typeof init === "object") this._list = Object.entries(init).map(([k, v]) => [k, String(v)]);
    else this._parse(String(init));
  }
  _parse(s) {
    this._list = s.replace(/^\?/, "").split("&").filter(Boolean).map((p) => {
      const i = p.indexOf("=");
      const dec = (x) => { try { return decodeURIComponent(x.replace(/\+/g, " ")); } catch { return x; } };
      return i < 0 ? [dec(p), ""] : [dec(p.slice(0, i)), dec(p.slice(i + 1))];
    });
  }
  _update() { if (this._url) { const s = this.toString(); this._url._u.search = s ? "?" + s : ""; } }
  append(k, v) { this._list.push([String(k), String(v)]); this._update(); }
  delete(k) { this._list = this._list.filter(([n]) => n !== k); this._update(); }
  get(k) { const p = this._list.find(([n]) => n === k); return p ? p[1] : null; }
  getAll(k) { return this._list.filter(([n]) => n === k).map(([, v]) => v); }
  has(k) { return this._list.some(([n]) => n === k); }
  set(k, v) {
    const i = this._list.findIndex(([n]) => n === k);
    if (i < 0) this._list.push([String(k), String(v)]);
    else { this._list[i][1] = String(v); this._list = this._list.filter(([n], j) => n !== k || j === i); }
    this._update();
  }
  sort() { this._list.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0)); this._update(); }
  forEach(fn, self) { for (const [k, v] of this._list) fn.call(self, v, k, this); }
  keys() { return this._list.map(([k]) => k)[Symbol.iterator](); }
  values() { return this._list.map(([, v]) => v)[Symbol.iterator](); }
  entries() { return this._list.map((p) => [...p])[Symbol.iterator](); }
  [Symbol.iterator]() { return this.entries(); }
  get size() { return this._list.length; }
  toString() {
    const enc = (x) => encodeURIComponent(x).replace(/%20/g, "+");
    return this._list.map(([k, v]) => enc(k) + "=" + enc(v)).join("&");
  }
}

export class URL {
  constructor(input, base) {
    const b = base === undefined ? null : base instanceof URL ? base._u : String(base);
    const u = resolve(String(input).trim(), b);
    if (!u) throw new TypeError("Invalid URL: " + input);
    this._u = u;
    this._sp = null;
  }
  static canParse(input, base) { try { new URL(input, base); return true; } catch { return false; } }
  static parse(input, base) { try { return new URL(input, base); } catch { return null; } }
  get protocol() { return this._u.protocol; }
  set protocol(v) { this._u.protocol = String(v).replace(/:?$/, ":").toLowerCase(); }
  get username() { return this._u.username; }
  get password() { return this._u.password; }
  get hostname() { return this._u.hostname; }
  set hostname(v) { this._u.hostname = String(v).toLowerCase(); }
  get port() { return this._u.port; }
  set port(v) { this._u.port = String(v); }
  get host() { return this._u.hostname + (this._u.port ? ":" + this._u.port : ""); }
  get origin() { return this._u.hasAuthority && this._u.protocol !== "file:" ? this._u.protocol + "//" + this.host : "null"; }
  get pathname() { return this._u.pathname; }
  set pathname(v) { this._u.pathname = normalize(String(v)[0] === "/" ? String(v) : "/" + v); }
  get search() { return this._u.search; }
  set search(v) { v = String(v); this._u.search = v && v !== "?" ? (v[0] === "?" ? v : "?" + v) : ""; if (this._sp) this._sp._parse(this._u.search); }
  get hash() { return this._u.hash; }
  set hash(v) { v = String(v); this._u.hash = v && v !== "#" ? (v[0] === "#" ? v : "#" + v) : ""; }
  get searchParams() {
    if (!this._sp) { this._sp = new URLSearchParams(this._u.search); this._sp._url = this; }
    return this._sp;
  }
  get href() {
    const u = this._u;
    const auth = u.hasAuthority ? "//" + (u.username ? u.username + (u.password ? ":" + u.password : "") + "@" : "") + this.host : "";
    return u.protocol + auth + u.pathname + u.search + u.hash;
  }
  set href(v) { const n = new URL(v); this._u = n._u; if (this._sp) this._sp._parse(this._u.search); }
  toString() { return this.href; }
  toJSON() { return this.href; }
  // Blob URLs: no Blob store here; a page that needs them gets a clear error.
  static createObjectURL() { throw new Error("URL.createObjectURL isn't supported by the native renderer"); }
  static revokeObjectURL() {}
}

export function installURL(g) {
  if (typeof g.URL !== "function") g.URL = URL;
  if (typeof g.URLSearchParams !== "function" || !g.URLSearchParams.prototype.getAll) g.URLSearchParams = URLSearchParams;
}
