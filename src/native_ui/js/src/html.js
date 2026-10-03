// The runtime's own weak caches keyed by nodes: marked so their entries
// don't keep a node's wrapper from being replaced (a page's weak
// references do: dom/store.zig prune).
const internalWeak = (m) => (globalThis.__nuiDom?.internal?.(m), m);

// el.innerHTML = "…" without linkedom's parser for plain markup.
//
// linkedom parses each assignment into a new Document (htmlparser2), then
// moves the nodes into the page's: costly for the many small fragments a
// page writes (a list's rows). Markup made only of elements with ordinary
// tags, attributes, text, comments and the common entities is built here
// with createElement and append instead. Anything with special parsing
// rules (raw text: script, style, textarea; implied end tags: p, li,
// table parts, option; foreign content: svg, math; templates), an unknown
// entity, a "/>" on a non-void element or unbalanced tags: null, and the
// caller uses linkedom's parser, so what's built is always what it builds.

const VOID = new Set("area base br col embed hr img input keygen link meta param source track wbr".split(" "));
const SPECIAL = new Set(("script style textarea title template svg math p li dt dd option optgroup select table " +
  "caption colgroup thead tbody tfoot tr td th rb rt rp rtc ruby noscript iframe noembed noframes xmp plaintext " +
  "frameset frame head body html pre listing form button a nobr image").split(" "));
const ENTITIES = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };

const TAG = /<(\/?)([a-zA-Z][a-zA-Z0-9-]*)((?:\s+[^\s"'>/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*)\s*(\/?)>/y;
const ATTR = /([^\s"'>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
// Cache syntax, never DOM nodes: repeated small fragments often vary only
// in their text. Validate every static token before constructing anything.
const templates = new Map();

// Entities in text or an attribute: decoded, or undefined for one we don't know.
function decode(s) {
  if (s.indexOf("&") < 0) return s;
  let bad = false;
  const out = s.replace(/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);?/g, (m, e) => {
    if (e[0] === "#") {
      const n = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      if (!(n > 0 && n <= 0x10ffff) || (n >= 0xd800 && n <= 0xdfff)) { bad = true; return m; }
      return String.fromCodePoint(n);
    }
    if (!m.endsWith(";") || !Object.hasOwn(ENTITIES, e)) { bad = true; return m; }
    return ENTITIES[e];
  });
  return bad ? undefined : out;
}

// The markup as a DocumentFragment of `doc`'s nodes, or null (see above).
export function parseSimple(doc, html) {
  if (html.length > 2048) return parseFull(doc, html);
  const lt = html.indexOf("<"), gt = lt < 0 ? -1 : html.indexOf(">", lt);
  const key = lt < 0 ? "" : html.slice(lt, gt < 0 ? lt + 32 : gt + 1);
  const candidates = templates.get(key);
  if (candidates) for (const plan of candidates) {
    const frag = fromTemplate(doc, html, plan);
    if (frag) return frag;
  }
  const plan = [];
  const frag = parseFull(doc, html, plan);
  // Custom-element construction can run page code during parsing. Preserve
  // the ordinary parser's interleaving for those fragments.
  if (frag && !plan.some((token) => token.kind === 1 &&
      (token.tag.includes("-") || token.attrs.some(([name]) => name === "is")))) {
    if (!candidates && templates.size >= 32) templates.delete(templates.keys().next().value);
    const list = candidates || [];
    if (list.length === 4) list.shift();
    list.push(plan);
    templates.set(key, list);
  }
  return frag;
}

function fromTemplate(doc, html, plan) {
  let i = 0;
  const text = [];
  for (const token of plan) {
    if (token.kind === 0) {
      const lt = html.indexOf("<", i), end = lt < 0 ? html.length : lt;
      const value = decode(html.slice(i, end));
      if (value === undefined) return null;
      text.push(value);
      i = end;
    } else {
      if (!html.startsWith(token.raw, i)) return null;
      i += token.raw.length;
    }
  }
  if (i !== html.length) return null;
  const frag = doc.createDocumentFragment(), stack = [frag];
  let ti = 0;
  for (const token of plan) {
    if (token.kind === 0) {
      const value = text[ti++];
      if (value) stack[stack.length - 1].appendChild(doc.createTextNode(value));
    } else if (token.kind === 1) {
      const seed = token.seeds?.get(doc);
      const el = seed ? seed.cloneNode(false) : doc.createElement(token.tag);
      if (!seed) for (let k = token.attrs.length - 1; k >= 0; k--) el.setAttribute(token.attrs[k][0], token.attrs[k][1]);
      stack[stack.length - 1].appendChild(el);
      if (!token.void) stack.push(el);
    } else if (token.kind === 2) stack.pop();
    else stack[stack.length - 1].appendChild(doc.createComment(token.text));
  }
  return frag;
}

function parseFull(doc, html, plan) {
  const frag = doc.createDocumentFragment();
  const stack = [frag];
  let i = 0;
  const n = html.length;
  while (i < n) {
    const lt = html.indexOf("<", i);
    const end = lt < 0 ? n : lt;
    if (plan) plan.push({ kind: 0 });
    if (end > i) {
      const t = decode(html.slice(i, end));
      if (t === undefined) return null;
      stack[stack.length - 1].appendChild(doc.createTextNode(t));
    }
    if (lt < 0) break;
    if (html.startsWith("<!--", lt)) {
      const close = html.indexOf("-->", lt + 4);
      if (close < 0) return null;
      if (plan) plan.push({ kind: 3, raw: html.slice(lt, close + 3), text: html.slice(lt + 4, close) });
      stack[stack.length - 1].appendChild(doc.createComment(html.slice(lt + 4, close)));
      i = close + 3;
      continue;
    }
    TAG.lastIndex = lt;
    const m = TAG.exec(html);
    if (!m) return null;
    i = TAG.lastIndex;
    const tag = m[2].toLowerCase();
    if (SPECIAL.has(tag)) return null;
    if (m[1]) {
      // An end tag: it closes the open element, or this isn't simple.
      if (m[3] || m[4] || stack.length < 2 || stack[stack.length - 1].localName !== tag) return null;
      if (plan) plan.push({ kind: 2, raw: m[0] });
      stack.pop();
      continue;
    }
    const isVoid = VOID.has(tag);
    if (m[4] && !isVoid) return null; // <div/> opens a div in HTML
    const el = doc.createElement(tag);
    const attrs = [];
    if (m[3]) {
      ATTR.lastIndex = 0;
      for (let a; (a = ATTR.exec(m[3]));) {
        const name = a[1].toLowerCase();
        const v = decode(a[2] ?? a[3] ?? a[4] ?? "");
        if (v === undefined || attrs.some((x) => x[0] === name)) return null;
        attrs.push([name, v]);
      }
      // linkedom puts each new attribute first: last to first keeps the order.
      for (let k = attrs.length - 1; k >= 0; k--) el.setAttribute(attrs[k][0], attrs[k][1]);
    }
    if (plan) plan.push({ kind: 1, raw: m[0], tag, attrs, void: isVoid,
      seeds: tag.includes("-") || attrs.some(([name]) => name === "is") ? null : internalWeak(new WeakMap([[doc, el.cloneNode(false)]])) });
    stack[stack.length - 1].appendChild(el);
    if (!isVoid) stack.push(el);
  }
  if (plan && (n === 0 || html.endsWith(">"))) plan.push({ kind: 0 });
  return stack.length === 1 ? frag : null;
}
