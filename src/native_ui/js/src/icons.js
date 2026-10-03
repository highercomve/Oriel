// SVG → a vector icon for the native side: a viewBox and shapes as SVG path
// data with their paint, colors resolved (currentColor, url(#gradient)).
//   { vb: [x, y, w, h], shapes: [{ d, fill, stroke, sw, cap, join }] }

import { color, parseSheet, parseInline, mediaMatches, viewport } from "./css.js";

// `doc` finds ids (a <use>'s symbol, a url(#gradient)): the page, or an SVG
// file's own (svgScope). `files(path)`: an SVG file's scope, for a <use>
// of another file's symbol (`<use href="icons.svg#github">`, a sprite).
// `opts.image`: an SVG drawn as an image (an <img>): its media queries see a
// light color scheme, as a browser's SVG image does (the page's dark mode
// doesn't reach into it).
export function iconFor(svg, cs, doc, files, opts) {
  if (!opts?.image || !viewport.dark) return iconOf(svg, cs, doc, files);
  viewport.dark = false;
  try { return iconOf(svg, cs, doc, files); } finally { viewport.dark = true; }
}

function iconOf(svg, cs, doc, files) {
  const current = color(cs.color) || [0, 0, 0, 1];
  let root = svg;
  const use = svg.querySelector("use");
  if (use) {
    const href = use.getAttribute("href") || use.getAttribute("xlink:href") || "";
    const hash = href.indexOf("#");
    const file = hash < 0 ? href : href.slice(0, hash);
    const id = hash < 0 ? "" : href.slice(hash + 1);
    if (file) doc = files?.(file);
    const sym = id && doc?.getElementById(id);
    if (!sym) return null;
    root = sym;
  }
  const vb = (root.getAttribute("viewBox") || svg.getAttribute("viewBox") || "0 0 24 24").split(/[\s,]+/).map(Number);
  const shapes = [];
  // The SVG's own style sheets (a <style> in it: Vite's logo), for its
  // shapes only; a <use>d symbol's, its file's.
  const sheet = svgSheet(root === svg ? svg : (root.closest?.("svg") || svg));
  // Paint set on <svg> (Feather/Lucide icons: fill="none" stroke="currentColor"
  // stroke-width="2" on the root) and on the <symbol>, inherited by the shapes.
  let paint = paintOf(svg, { fill: "black", stroke: "none", sw: 1, cap: "butt", join: "miter", op: 1, fo: 1, so: 1 }, sheet);
  if (root !== svg) paint = paintOf(root, paint, sheet);
  collect(root, paint, current, doc, shapes, sheet);
  if (!shapes.length) return null;
  return { vb, shapes };
}

// An SVG file's text as an element tree of its own (not in the page) and
// its ids: `{ svg, getElementById }`, or null when it has no <svg>.
export function svgScope(text, doc) {
  const holder = doc.createElement("div");
  holder.innerHTML = text.replace(/^\s*<\?xml[^>]*>/, "");
  const svg = holder.querySelector("svg");
  if (!svg) return null;
  const ids = new Map();
  const walk = (el) => {
    const id = el.getAttribute("id");
    if (id && !ids.has(id)) ids.set(id, el);
    for (const c of el.children) walk(c);
  };
  walk(svg);
  return { svg, getElementById: (id) => ids.get(id) || null };
}

// An SVG image's text from a data: URL (base64 or percent-encoded), or null.
export function svgDataText(src) {
  const m = /^data:image\/svg\+xml(;[^,]*)?,(.*)$/s.exec(src);
  if (!m) return null;
  try {
    if (/;base64/i.test(m[1] || "")) {
      // Its bytes as UTF-8 (QuickJS has atob, not TextDecoder).
      const bin = atob(m[2]);
      try { return decodeURIComponent(escape(bin)); } catch { return bin; }
    }
    return decodeURIComponent(m[2]);
  } catch {
    return null;
  }
}

// An SVG image's own size (its width and height attributes in px, else
// its viewBox's), as a browser sizes an <img> of it.
export function svgSize(svg, vb) {
  const px = (a) => { const v = svg.getAttribute(a); return v && /^[\d.]+(px)?$/.test(v.trim()) ? parseFloat(v) : undefined; };
  let w = px("width"), h = px("height");
  const ratio = vb[2] > 0 && vb[3] > 0 ? vb[2] / vb[3] : 0;
  if (w === undefined && h !== undefined && ratio) w = h * ratio;
  if (h === undefined && w !== undefined && ratio) h = w / ratio;
  if (w === undefined || h === undefined) { w = vb[2] || 300; h = vb[3] || 150; }
  return { w, h, ratio };
}

// Not drawn where they are: definitions, and what's only drawn through a
// reference (masks, clips, filters, patterns, markers), and text.
const SKIP = new Set(["defs", "symbol", "title", "desc", "style", "metadata", "lineargradient", "linearGradient", "radialgradient",
  "radialGradient", "mask", "clippath", "clipPath", "filter", "pattern", "marker", "text"]);

function collect(el, inherited, current, doc, out, sheet) {
  for (const c of el.children) {
    const tag = c.localName;
    if (SKIP.has(tag)) continue;
    // Masked: drawn only through its mask (a logo's glow), which an icon
    // can't do; left out rather than drawn whole over the rest.
    if (c.hasAttribute("mask")) continue;
    const paint = paintOf(c, inherited, sheet);
    if (paint.display === "none") continue;
    if (tag === "g") { collect(c, paint, current, doc, out, sheet); continue; }
    if (paint.visibility === "hidden" || paint.visibility === "collapse") continue;
    const d = pathData(c);
    if (!d) continue;
    out.push({
      d,
      fill: faded(paintColor(paint.fill, current, doc), paint.op * paint.fo),
      stroke: faded(paintColor(paint.stroke, current, doc), paint.op * paint.so),
      sw: paint.sw,
      cap: paint.cap,
      join: paint.join,
      ...(c.getAttribute("fill-rule") === "evenodd" ? { evenodd: true } : {}),
    });
  }
}

// An element's paint, inherited where it sets none: its value from the
// cascade (the SVG's sheet and its style attribute, which beat a
// presentation attribute), else its attribute. Opacity multiplies down
// (an approximation of group opacity: each shape's colors fade by it).
function paintOf(el, inherited, sheet) {
  const st = styleOf(el, sheet);
  const get = (name) => st?.[name] ?? el.getAttribute(name);
  const num = (v, d) => { const x = parseFloat(v); return Number.isFinite(x) ? Math.min(1, Math.max(0, x)) : d; };
  return {
    fill: get("fill") ?? inherited.fill,
    stroke: get("stroke") ?? inherited.stroke,
    sw: parseFloat(get("stroke-width") ?? inherited.sw),
    cap: get("stroke-linecap") ?? inherited.cap,
    join: get("stroke-linejoin") ?? inherited.join,
    op: inherited.op * num(get("opacity"), 1),
    fo: num(get("fill-opacity"), inherited.fo),
    so: num(get("stroke-opacity"), inherited.so),
    display: get("display"),
    visibility: get("visibility") ?? inherited.visibility,
  };
}

// An SVG's own style sheets (its <style> elements): the rules, by
// specificity then order, or null. The page's sheets aren't applied to an
// icon's shapes, only these (as a browser scopes them to that document for
// an <img>, and an inline <svg>'s apply to it as well).
function svgSheet(svg) {
  const texts = [...svg.querySelectorAll("style")].map((s) => s.textContent || "").filter(Boolean);
  if (!texts.length) return null;
  const rules = parseSheet(texts.join("\n"), 0).filter((r) => !r.pseudo);
  const cmp = (a, b) => a.spec[0] - b.spec[0] || a.spec[1] - b.spec[1] || a.spec[2] - b.spec[2] || a.order - b.order;
  return rules.length ? rules.sort(cmp) : null;
}

// What the cascade gives an element: its sheet's matching rules (media
// queries answered for the viewport: prefers-color-scheme), then its style
// attribute; !important wins over either.
function styleOf(el, sheet) {
  const inline = el.getAttribute("style");
  if (!sheet && !inline) return null;
  const out = {}, important = {};
  const put = (d) => {
    if (important[d.prop] && !d.important) return;
    out[d.prop] = d.value;
    if (d.important) important[d.prop] = true;
  };
  if (sheet) {
    for (const r of sheet) {
      if (r.media && !mediaMatches(r.media)) continue;
      let hit = false;
      try { hit = el.matches(r.sel); } catch { hit = false; }
      if (hit) for (const d of r.decls) put(d);
    }
  }
  if (inline) for (const d of parseInline(inline)) put(d);
  return out;
}

function faded(c, alpha) {
  if (!c || alpha >= 1) return c;
  return [c[0], c[1], c[2], c[3] * alpha];
}

function paintColor(p, current, doc) {
  if (!p || p === "none") return null;
  const ref = /^url\(#([^)]+)\)$/.exec(p);
  if (ref) {
    // A gradient: its first stop's color.
    const g = doc.getElementById(ref[1]);
    const stop = g?.querySelector("stop");
    return color(stop?.getAttribute("stop-color") || "", current) || current;
  }
  return color(p, current);
}

const n = (el, a, d = 0) => parseFloat(el.getAttribute(a) ?? d) || 0;

function pathData(el) {
  switch (el.localName) {
    case "path":
      return el.getAttribute("d");
    case "rect": {
      const x = n(el, "x"), y = n(el, "y"), w = n(el, "width"), h = n(el, "height");
      let rx = el.hasAttribute("rx") ? n(el, "rx") : n(el, "ry"), ry = el.hasAttribute("ry") ? n(el, "ry") : rx;
      rx = Math.min(rx, w / 2); ry = Math.min(ry, h / 2);
      if (!rx) return `M${x} ${y}h${w}v${h}h${-w}z`;
      return `M${x + rx} ${y}h${w - 2 * rx}a${rx} ${ry} 0 0 1 ${rx} ${ry}v${h - 2 * ry}a${rx} ${ry} 0 0 1 ${-rx} ${ry}h${-(w - 2 * rx)}a${rx} ${ry} 0 0 1 ${-rx} ${-ry}v${-(h - 2 * ry)}a${rx} ${ry} 0 0 1 ${rx} ${-ry}z`;
    }
    case "circle": case "ellipse": {
      const cx = n(el, "cx"), cy = n(el, "cy");
      const rx = el.localName === "circle" ? n(el, "r") : n(el, "rx"), ry = el.localName === "circle" ? rx : n(el, "ry");
      return `M${cx - rx} ${cy}a${rx} ${ry} 0 1 0 ${2 * rx} 0a${rx} ${ry} 0 1 0 ${-2 * rx} 0z`;
    }
    case "line":
      return `M${n(el, "x1")} ${n(el, "y1")}L${n(el, "x2")} ${n(el, "y2")}`;
    case "polyline": case "polygon": {
      const pts = (el.getAttribute("points") || "").trim().split(/[\s,]+/).map(Number);
      if (pts.length < 4) return null;
      let d = `M${pts[0]} ${pts[1]}`;
      for (let i = 2; i + 1 < pts.length; i += 2) d += `L${pts[i]} ${pts[i + 1]}`;
      return el.localName === "polygon" ? d + "z" : d;
    }
    default:
      return null;
  }
}
