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
  const frag = doc.createDocumentFragment();
  const stack = [frag];
  let i = 0;
  const n = html.length;
  while (i < n) {
    const lt = html.indexOf("<", i);
    const end = lt < 0 ? n : lt;
    if (end > i) {
      const t = decode(html.slice(i, end));
      if (t === undefined) return null;
      stack[stack.length - 1].append(doc.createTextNode(t));
    }
    if (lt < 0) break;
    if (html.startsWith("<!--", lt)) {
      const close = html.indexOf("-->", lt + 4);
      if (close < 0) return null;
      stack[stack.length - 1].append(doc.createComment(html.slice(lt + 4, close)));
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
      stack.pop();
      continue;
    }
    const isVoid = VOID.has(tag);
    if (m[4] && !isVoid) return null; // <div/> opens a div in HTML
    const el = doc.createElement(tag);
    if (m[3]) {
      const attrs = [];
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
    stack[stack.length - 1].append(el);
    if (!isVoid) stack.push(el);
  }
  return stack.length === 1 ? frag : null;
}
