// SVG → a vector icon for the native side: a viewBox and shapes as SVG path
// data with their paint, colors resolved (currentColor, url(#gradient)).
//   { vb: [x, y, w, h], shapes: [{ d, fill, stroke, sw, cap, join }] }

import { color } from "./css.js";

// `doc` finds ids (a <use>'s symbol, a url(#gradient)): the page, or an SVG
// file's own (svgScope). `files(path)`: an SVG file's scope, for a <use>
// of another file's symbol (`<use href="icons.svg#github">`, a sprite).
export function iconFor(svg, cs, doc, files) {
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
  // Paint set on <svg> (Feather/Lucide icons: fill="none" stroke="currentColor"
  // stroke-width="2" on the root) and on the <symbol>, inherited by the shapes.
  let paint = paintOf(svg, { fill: "black", stroke: "none", sw: 1, cap: "butt", join: "miter" });
  if (root !== svg) paint = paintOf(root, paint);
  collect(root, paint, current, doc, shapes);
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

function collect(el, inherited, current, doc, out) {
  for (const c of el.children) {
    const tag = c.localName;
    if (SKIP.has(tag)) continue;
    // Masked: drawn only through its mask (a logo's glow), which an icon
    // can't do; left out rather than drawn whole over the rest.
    if (c.hasAttribute("mask")) continue;
    const paint = paintOf(c, inherited);
    if (tag === "g") { collect(c, paint, current, doc, out); continue; }
    const d = pathData(c);
    if (!d) continue;
    out.push({
      d,
      fill: paintColor(paint.fill, current, doc),
      stroke: paintColor(paint.stroke, current, doc),
      sw: paint.sw,
      cap: paint.cap,
      join: paint.join,
      ...(c.getAttribute("fill-rule") === "evenodd" ? { evenodd: true } : {}),
    });
  }
}

function paintOf(el, inherited) {
  return {
    fill: attr(el, "fill") ?? inherited.fill,
    stroke: attr(el, "stroke") ?? inherited.stroke,
    sw: parseFloat(attr(el, "stroke-width") ?? inherited.sw),
    cap: attr(el, "stroke-linecap") ?? inherited.cap,
    join: attr(el, "stroke-linejoin") ?? inherited.join,
  };
}

function attr(el, name) {
  const v = el.getAttribute(name);
  if (v !== null) return v;
  const style = el.getAttribute("style");
  if (style) {
    const m = new RegExp(`(?:^|;)\\s*${name}\\s*:\\s*([^;]+)`).exec(style);
    if (m) return m[1].trim();
  }
  return null;
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
