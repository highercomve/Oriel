// SVG → a vector icon for the native side: a viewBox and shapes as SVG path
// data with their paint, colors resolved (currentColor, url(#gradient)).
//   { vb: [x, y, w, h], shapes: [{ d, fill, stroke, sw, cap, join }] }

import { color } from "./css.js";

export function iconFor(svg, cs, doc) {
  const current = color(cs.color) || [0, 0, 0, 1];
  let root = svg;
  const use = svg.querySelector("use");
  if (use) {
    const href = (use.getAttribute("href") || use.getAttribute("xlink:href") || "").replace(/^#/, "");
    const sym = href && doc.getElementById(href);
    if (!sym) return null;
    root = sym;
  }
  const vb = (root.getAttribute("viewBox") || svg.getAttribute("viewBox") || "0 0 24 24").split(/[\s,]+/).map(Number);
  const shapes = [];
  collect(root, { fill: "black", stroke: "none", sw: 1, cap: "butt", join: "miter" }, current, doc, shapes);
  if (!shapes.length) return null;
  return { vb, shapes };
}

function collect(el, inherited, current, doc, out) {
  for (const c of el.children) {
    const tag = c.localName;
    if (tag === "defs" || tag === "symbol" || tag === "title" || tag === "lineargradient" || tag === "linearGradient") continue;
    const paint = {
      fill: attr(c, "fill") ?? inherited.fill,
      stroke: attr(c, "stroke") ?? inherited.stroke,
      sw: parseFloat(attr(c, "stroke-width") ?? inherited.sw),
      cap: attr(c, "stroke-linecap") ?? inherited.cap,
      join: attr(c, "stroke-linejoin") ?? inherited.join,
    };
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
