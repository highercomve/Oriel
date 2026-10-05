// The style engine: CSS text → rules; per element the cascade (selectors,
// specificity, !important, inline styles), custom properties, inheritance and
// media queries; values resolved to numbers, colors and keywords for layout.

import { compileMatch } from "#dom";

// ---------------------------------------------------------------------------
// Parsing

function stripComments(css) {
  return css.replace(/\/\*[\s\S]*?\*\//g, "");
}

// Split at a separator outside parentheses and quotes. A regular
// expression jumps between the characters that matter (QuickJS runs it
// natively; a loop over each character is interpreted).
const specials = { ",": /["'()[\],]/g, ";": /["'()[\];]/g };
export function splitTop(s, sep) {
  // Nothing to step over: a plain split.
  if (!/["'()[\]]/.test(s)) return s.split(sep);
  const re = specials[sep] ?? new RegExp(`["'()[\\]${sep.replace(/[\\\]^-]/g, "\\$&")}]`, "g");
  const out = [];
  let depth = 0, start = 0;
  re.lastIndex = 0;
  for (let m; (m = re.exec(s)); ) {
    const k = m.index, c = s.charCodeAt(k);
    if (c === 34 || c === 39) {
      // A quoted run, to its closing quote (not an escaped one).
      let e = k;
      do e = s.indexOf(m[0], e + 1); while (e > 0 && s.charCodeAt(e - 1) === 92);
      if (e < 0) break;
      re.lastIndex = e + 1;
    } else if (c === 40 || c === 91) depth++; // ( [
    else if (c === 41 || c === 93) depth--; // ) ]
    else if (depth === 0) { out.push(s.slice(start, k)); start = k + 1; }
  }
  out.push(s.slice(start));
  return out;
}

// Whitespace-separated tokens outside parentheses.
export function splitSpaces(s) {
  s = s.trim();
  if (!s.includes("(") && !s.includes(")")) return s ? s.split(/\s+/) : [];
  const out = [];
  const re = /[()\s]/g;
  let depth = 0, start = 0;
  for (let m; (m = re.exec(s)); ) {
    const c = m[0];
    if (c === "(") depth++;
    else if (c === ")") depth--;
    else if (depth === 0) {
      if (m.index > start) out.push(s.slice(start, m.index));
      start = m.index + 1;
    }
  }
  if (start < s.length) out.push(s.slice(start));
  return out;
}

function parseDecls(text) {
  const decls = [];
  for (const part of splitTop(text, ";")) {
    const i = part.indexOf(":");
    if (i < 0) continue;
    const prop = part.slice(0, i).trim().toLowerCase();
    let value = part.slice(i + 1).trim();
    if (!prop || !value) continue;
    let important = false;
    const m = value.includes("!") ? /!\s*important\s*$/i.exec(value) : null;
    if (m) { important = true; value = value.slice(0, m.index).trim(); }
    decls.push({ prop: prop.startsWith("--") ? part.slice(0, i).trim() : prop, value, important });
  }
  return decls;
}

export function parseInline(text) {
  return parseDecls(text || "");
}

// Rules of a stylesheet: { sel, pseudo, spec, decls, media, order }.
export function parseSheet(css, orderBase = 0) {
  css = stripComments(css);
  const rules = [];
  rules.keyframes = {}; // name → [{ offset 0…1, decls: { prop: value } }]
  let order = orderBase;
  function block(text, media) {
    let i = 0;
    while (i < text.length) {
      const open = text.indexOf("{", i);
      if (open < 0) break;
      const prelude = text.slice(i, open).trim();
      // Find the matching brace (j: just past it, or the end).
      let depth = 1, j = open + 1, nextOpen = text.indexOf("{", j);
      while (depth) {
        const close = text.indexOf("}", j);
        if (close < 0) { j = text.length; break; }
        if (nextOpen >= 0 && nextOpen < close) { depth++; j = nextOpen + 1; nextOpen = text.indexOf("{", j); }
        else { depth--; j = close + 1; }
      }
      const body = text.slice(open + 1, j - 1);
      i = j;
      if (prelude.startsWith("@media")) {
        const q = prelude.slice(6).trim();
        block(body, media ? `${media} and ${q}` : q);
      } else if (/^@(-webkit-)?keyframes\s/.test(prelude)) {
        rules.keyframes[prelude.split(/\s+/)[1]] = keyframes(body);
      } else if (prelude.startsWith("@")) {
        continue; // @font-face, @supports…: not yet
      } else {
        const decls = parseDecls(body);
        for (let sel of splitTop(prelude, ",")) {
          sel = sel.trim();
          if (!sel) continue;
          let pseudo = null;
          if (sel.includes(":")) {
            const pm = /::?(before|after)\s*$/.exec(sel);
            if (pm) { pseudo = pm[1]; sel = sel.slice(0, pm.index).trim() || "*"; }
            // :focus, :hover and :active are attributes the runtime moves
            // with the focus, the pointer and the press (main.js).
            sel = sel.replace(/:focus-visible(?![-\w])/g, "[data-nui-focus-visible]").replace(/:focus(?![-\w])/g, "[data-nui-focus]").replace(/:hover(?![-\w])/g, "[data-nui-hover]").replace(/:active(?![-\w])/g, "[data-nui-active]");
            if (/::|:hover|:focus|:active|:visited|:empty\b/.test(sel)) continue; // states we don't track yet
          }
          rules.push({ sel, pseudo, spec: specificity(sel), decls, media, order: order++, match: null });
        }
      }
    }
  }
  block(css, null);
  return rules;
}

// A @keyframes body: its frames by offset, each with its declarations
// expanded to longhands.
function keyframes(body) {
  const frames = [];
  let i = 0;
  while (i < body.length) {
    const open = body.indexOf("{", i);
    if (open < 0) break;
    const close = body.indexOf("}", open);
    if (close < 0) break;
    const decls = {};
    for (const d of parseDecls(body.slice(open + 1, close))) expand(d.prop, d.value, decls);
    for (const sel of body.slice(i, open).split(",")) {
      const t = sel.trim();
      const offset = t === "from" ? 0 : t === "to" ? 1 : parseFloat(t) / 100;
      if (Number.isFinite(offset)) frames.push({ offset, decls });
    }
    i = close + 1;
  }
  return frames.sort((a, b) => a.offset - b.offset);
}

function specificity(sel) {
  let a = 0, b = 0, c = 0;
  const s = !sel.includes("(") ? sel : sel.replace(/:(not|is|has|where)\(([^)]*)\)/g, (_, fn, inner) => {
    if (fn !== "where") { const sp = specificity(inner); a += sp[0]; b += sp[1]; c += sp[2]; }
    return "";
  });
  a += (s.match(/#[\w-]+/g) || []).length;
  b += (s.match(/\.[\w-]+|\[[^\]]*\]|:(?!:)[\w-]+/g) || []).length;
  c += (s.match(/(^|[\s>+~])[a-zA-Z][\w-]*/g) || []).length;
  return [a, b, c];
}

function cmpSpec(x, y) {
  return x[0] - y[0] || x[1] - y[1] || x[2] - y[2];
}

// ---------------------------------------------------------------------------
// Media queries

// `forced`: forced colors mode (the system's high contrast theme), null
// when off: { dark, colors: { canvas: "rgb(…)", … } } (platform.forcedColors).
export const viewport = { width: 1024, height: 768, dark: true, coarse: false, reducedMotion: false, dpr: 1, forced: null };

// The scheme the system asks for: its high contrast theme's while forced.
export function systemDark() {
  return viewport.forced ? !!viewport.forced.dark : viewport.dark;
}

// CSS system colors (CSS Color 4 §6.2): browsers' defaults, [light, dark]
// (Chromium's), or the platform's own in forced colors mode.
export const SYSTEM_COLORS = {
  canvas: ["#ffffff", "#121212"], canvastext: ["#000000", "#ffffff"],
  linktext: ["#0000ee", "#9e9eff"], visitedtext: ["#551a8b", "#d0adf0"], activetext: ["#ff0000", "#ff9e9e"],
  buttonface: ["#efefef", "#6b6b6b"], buttontext: ["#000000", "#ffffff"], buttonborder: ["#767676", "#6b6b6b"],
  field: ["#ffffff", "#3b3b3b"], fieldtext: ["#000000", "#ffffff"],
  highlight: ["#3390ff", "#3390ff"], highlighttext: ["#ffffff", "#ffffff"],
  selecteditem: ["#3390ff", "#3390ff"], selecteditemtext: ["#ffffff", "#ffffff"],
  mark: ["#ffff00", "#ffff00"], marktext: ["#000000", "#000000"], graytext: ["#808080", "#8e8e8e"],
  accentcolor: ["#0075ff", "#99c8ff"], accentcolortext: ["#ffffff", "#000000"],
};
// As rgb() strings, as computed styles keep colors.
for (const k in SYSTEM_COLORS) SYSTEM_COLORS[k] = SYSTEM_COLORS[k].map((h) => `rgb(${parseInt(h.slice(1, 3), 16)}, ${parseInt(h.slice(3, 5), 16)}, ${parseInt(h.slice(5, 7), 16)})`);
// Longest first, so "canvas" doesn't take "canvastext"'s place.
const SYSTEM_NAMES = Object.keys(SYSTEM_COLORS).sort((a, b) => b.length - a.length).join("|");
const SYSTEM_ANY = new RegExp(`\\b(?:${SYSTEM_NAMES})\\b`, "i");
const SYSTEM_ALL = new RegExp(`\\b(?:${SYSTEM_NAMES})\\b`, "gi");

// A system color by name (any case), for a light or dark used scheme: the
// platform's while forced, else the defaults.
export function systemColor(name, dark) {
  const k = name.toLowerCase();
  const forced = viewport.forced?.colors?.[k];
  if (forced) return forced;
  const d = SYSTEM_COLORS[k];
  return d ? d[dark ? 1 : 0] : name;
}

// The properties whose values can name a system color.
const COLOR_PROPS = ["color", "background", "border-top-color", "border-right-color", "border-bottom-color", "border-left-color",
  "outline-color", "text-decoration-color", "caret-color", "column-rule-color", "accent-color", "fill", "stroke", "box-shadow", "text-shadow", "scrollbar-color"];

// Media Queries 4 ranges: (width <= 720px), (400px < width <= 720px),
// (height >= 30em) — what Vite/lightningcss turns max-width/min-width into.
function rangeMatches(part) {
  const inner = /^\(([^()]*)\)$/.exec(part)?.[1];
  if (!inner || !/[<>=]/.test(inner) || inner.includes(":")) return null;
  const tokens = inner.split(/(<=|>=|<|>|=)/).map((t) => t.trim()).filter(Boolean);
  const valueOf = (t) => {
    if (t === "width") return viewport.width;
    if (t === "height") return viewport.height;
    if (t === "resolution") return viewport.dpr;
    if (/^[\d.]+(dppx|x|dpi|dpcm)$/.test(t)) return dppx(t);
    const n = parseFloat(t);
    if (!Number.isFinite(n)) return NaN;
    return t.endsWith("rem") || t.endsWith("em") ? n * 16 : n;
  };
  if (tokens.length < 3 || tokens.length % 2 === 0) return false;
  for (let i = 0; i + 2 < tokens.length; i += 2) {
    const a = valueOf(tokens[i]), op = tokens[i + 1], b = valueOf(tokens[i + 2]);
    if (!Number.isFinite(a) || !Number.isFinite(b)) return false;
    const ok = op === "<" ? a < b : op === "<=" ? a <= b : op === ">" ? a > b : op === ">=" ? a >= b : a === b;
    if (!ok) return false;
  }
  return true;
}

// A resolution in dots per px (devicePixelRatio's unit): 2dppx, 2x,
// 192dpi, 75.6dpcm; a bare number (a device-pixel-ratio's) as is.
function dppx(t) {
  const n = parseFloat(t);
  if (!Number.isFinite(n)) return NaN;
  if (t.endsWith("dpcm")) return (n * 2.54) / 96;
  if (t.endsWith("dpi")) return n / 96;
  return n;
}

// Each query's answer for the viewport as it is (main.js assigns its
// fields on resize and theme changes): matching asks for every candidate
// rule of every element, and parsing the query each time was ~14% of a
// settings page's JavaScript.
const mediaAnswers = new Map();
const mediaFor = { width: NaN, height: NaN, dark: null, coarse: null, reducedMotion: null, dpr: NaN };

// The fonts a page's rules can ask for: [size px, weight, italic, mono],
// at most `max`, for the backend to load while idle (host.warmFonts): the
// first text in a new size or weight costs a font match and load (~2.5 ms
// on GTK), paid when a tab is first shown otherwise. Sizes in px, rem
// (of the root's) and em (of 16); weights as given; italic and monospace
// when some rule uses them.
export function fontSpecs(rules, max = 48) {
  const sizes = new Set([16]), weights = new Set([400]);
  let italic = false, mono = false, root = 16;
  const sizeOf = (v) => {
    const m = /^([\d.]+)(px|rem|em)$/.exec(String(v || "").trim());
    if (!m) return null;
    const n = parseFloat(m[1]);
    return m[2] === "px" ? n : m[2] === "rem" ? n * root : n * 16;
  };
  // The root's size first (rem).
  for (const r of rules) {
    if (r.sel !== "html" && r.sel !== ":root") continue;
    const d = {};
    StyleEngine.expandInto(r.decls, d, d);
    const px = /^[\d.]+px$/.test(d["font-size"] || "") ? parseFloat(d["font-size"]) : null;
    if (px) root = px;
  }
  sizes.add(root);
  for (const r of rules) {
    const d = {};
    StyleEngine.expandInto(r.decls, d, d);
    const size = sizeOf(d["font-size"]);
    if (size && size >= 6 && size <= 96) sizes.add(Math.round(size * 2) / 2);
    const w = d["font-weight"];
    if (w) weights.add(w === "bold" ? 700 : w === "normal" ? 400 : parseInt(w, 10) || 400);
    if (/italic|oblique/.test(d["font-style"] || "")) italic = true;
    if (/mono|courier|consolas|menlo/i.test(d["font-family"] || "")) mono = true;
  }
  const out = [];
  // Common sizes first: the root's and the default, then the others.
  const order = [...sizes].sort((a, b) => (b === root) - (a === root) || (b === 16) - (a === 16) || a - b);
  for (const size of order) {
    for (const w of weights) out.push([size, w, 0, 0]);
    if (italic) out.push([size, 400, 1, 0]);
    if (mono) out.push([size, 400, 0, 1]);
  }
  return out.slice(0, max);
}

export function mediaMatches(q) {
  if (!q) return true;
  const v = viewport, f = mediaFor;
  if (v.width !== f.width || v.height !== f.height || v.dark !== f.dark || v.coarse !== f.coarse || v.reducedMotion !== f.reducedMotion || v.dpr !== f.dpr || v.forced !== f.forced) {
    mediaAnswers.clear();
    Object.assign(f, { width: v.width, height: v.height, dark: v.dark, coarse: v.coarse, reducedMotion: v.reducedMotion, dpr: v.dpr, forced: v.forced });
  }
  let answer = mediaAnswers.get(q);
  if (answer === undefined) {
    if (mediaAnswers.size > 512) mediaAnswers.clear();
    mediaAnswers.set(q, (answer = evalMedia(q)));
  }
  return answer;
}

function evalMedia(q) {
  return splitTop(q, ",").some((alt) => {
    alt = alt.trim();
    let negate = false;
    if (/^not\s/i.test(alt)) { negate = true; alt = alt.slice(4); }
    alt = alt.replace(/^only\s+/i, "");
    const all = alt.split(/\band\b/).every((part) => {
      part = part.trim();
      if (!part || part === "screen" || part === "all") return true;
      if (part === "print") return false;
      const range = rangeMatches(part);
      if (range !== null) return range;
      const m = /^\(\s*([\w-]+)\s*(?::\s*([^)]+))?\)$/.exec(part);
      if (!m) return false;
      const [, feat, raw] = m;
      const val = (raw || "").trim();
      const px = () => parseFloat(val) * (val.endsWith("em") ? 16 : 1);
      switch (feat) {
        case "min-width": return viewport.width >= px();
        case "max-width": return viewport.width <= px();
        case "min-height": return viewport.height >= px();
        case "max-height": return viewport.height <= px();
        case "prefers-color-scheme": return val === (systemDark() ? "dark" : "light");
        // High contrast: the system's colors forced (Windows), and a
        // preference for more contrast while they are.
        case "forced-colors": return val === (viewport.forced ? "active" : "none");
        case "prefers-contrast": return val === "more" ? !!viewport.forced : val === "no-preference" ? !viewport.forced : false;
        case "prefers-reduced-motion": return val === "reduce" ? viewport.reducedMotion : !viewport.reducedMotion;
        case "pointer": return val === (viewport.coarse ? "coarse" : "fine");
        case "hover": return val === (viewport.coarse ? "none" : "hover");
        case "orientation": return val === (viewport.width >= viewport.height ? "landscape" : "portrait");
        // The screen's pixels per CSS px (devicePixelRatio), WebKit's
        // prefixed device-pixel-ratio too (a bare number).
        case "resolution": case "-webkit-device-pixel-ratio": return Math.abs(viewport.dpr - dppx(val)) < 1e-3;
        case "min-resolution": case "-webkit-min-device-pixel-ratio": case "min--moz-device-pixel-ratio": return viewport.dpr >= dppx(val) - 1e-3;
        case "max-resolution": case "-webkit-max-device-pixel-ratio": case "max--moz-device-pixel-ratio": return viewport.dpr <= dppx(val) + 1e-3;
        default: return false;
      }
    });
    return negate ? !all : all;
  });
}

// ---------------------------------------------------------------------------
// The cascade

const INHERITED = new Set([
  "color", "font-family", "font-size", "font-style", "font-weight", "font-variant-numeric", "line-height",
  "letter-spacing", "text-align", "text-transform", "white-space", "visibility", "cursor", "word-break",
  "overflow-wrap", "list-style-type", "list-style-position", "color-scheme", "text-decoration-color",
]);

// Shorthands → longhands.
function expand(prop, value, out) {
  const box = (name, fmt) => {
    const v = splitSpaces(value);
    const [t, r = t, b = t, l = r] = v;
    out[fmt("top", name)] = t; out[fmt("right", name)] = r; out[fmt("bottom", name)] = b; out[fmt("left", name)] = l;
  };
  switch (prop) {
    case "margin": case "padding":
      return box(prop, (side, n) => `${n}-${side}`);
    // Omitted parts take their initial values (disc, outside), as in CSS.
    case "list-style": {
      let type, position;
      for (const w of splitSpaces(value)) {
        if (w === "inside" || w === "outside") position = w;
        else if (!/^url\(/i.test(w)) type = w;
      }
      out["list-style-type"] = type ?? "disc";
      out["list-style-position"] = position ?? "outside";
      return;
    }
    case "inset":
      return box(prop, (side) => side);
    // Horizontal writing: inline is left and right, block top and bottom.
    case "inset-inline": case "inset-block": {
      const [a, b = a] = splitSpaces(value);
      const [s, e] = prop === "inset-inline" ? ["left", "right"] : ["top", "bottom"];
      out[s] = a; out[e] = b;
      return;
    }
    case "border-width":
      return box(prop, (side) => `border-${side}-width`);
    case "border-style":
      return box(prop, (side) => `border-${side}-style`);
    case "border-color":
      return box(prop, (side) => `border-${side}-color`);
    case "border-radius": {
      // "a b c d / e f g h": horizontal radii, then vertical ones (the same
      // when there's no slash); a corner whose two differ gets both.
      const [hv, vv] = value.split("/");
      const four = (s) => { const [a, b = a, c = a, d = b] = splitSpaces(s.trim()); return [a, b, c, d]; };
      const h = four(hv);
      const v = vv === undefined ? h : four(vv);
      const corners = ["top-left", "top-right", "bottom-right", "bottom-left"];
      for (let i = 0; i < 4; i++) out[`border-${corners[i]}-radius`] = h[i] === v[i] ? h[i] : `${h[i]} ${v[i]}`;
      return;
    }
    case "border": case "border-top": case "border-right": case "border-bottom": case "border-left": {
      const sides = prop === "border" ? ["top", "right", "bottom", "left"] : [prop.slice(7)];
      let width = "medium", style = "none", color = "currentcolor";
      for (const t of splitSpaces(value)) {
        if (/^(none|hidden|solid|dashed|dotted|double|groove|ridge|inset|outset)$/.test(t)) style = t;
        else if (/^[\d.]|^(thin|medium|thick)$/.test(t)) width = t;
        else color = t;
      }
      if (value === "0" || value === "none") { width = "0"; style = "none"; }
      for (const s of sides) {
        out[`border-${s}-width`] = style === "none" ? "0" : width;
        out[`border-${s}-color`] = color;
        out[`border-${s}-style`] = style;
      }
      return;
    }
    case "outline": {
      let width = "medium", style = "none", color = "currentcolor";
      for (const t of splitSpaces(value)) {
        if (/^(none|hidden|auto|solid|dashed|dotted|double|groove|ridge|inset|outset)$/.test(t)) style = t;
        else if (/^[\d.]|^(thin|medium|thick)$/.test(t)) width = t;
        else color = t;
      }
      if (value === "0") { width = "0"; style = "none"; }
      out["outline-width"] = width;
      out["outline-style"] = style;
      out["outline-color"] = color;
      return;
    }
    case "flex": {
      const v = splitSpaces(value);
      if (value === "none") { out["flex-grow"] = "0"; out["flex-shrink"] = "0"; out["flex-basis"] = "auto"; return; }
      if (value === "auto") { out["flex-grow"] = "1"; out["flex-shrink"] = "1"; out["flex-basis"] = "auto"; return; }
      if (v.length === 1 && /^[\d.]+$/.test(v[0])) { out["flex-grow"] = v[0]; out["flex-shrink"] = "1"; out["flex-basis"] = "0%"; return; }
      // One width (`flex: 200px`, `flex: calc(50% - 8px)`): `1 1 <width>`.
      if (v.length === 1) { out["flex-grow"] = "1"; out["flex-shrink"] = "1"; out["flex-basis"] = v[0]; return; }
      out["flex-grow"] = v[0] ?? "0";
      if (v.length === 2) { if (/^[\d.]+$/.test(v[1])) out["flex-shrink"] = v[1]; else out["flex-basis"] = v[1]; return; }
      out["flex-shrink"] = v[1] ?? "1"; out["flex-basis"] = v[2] ?? "0%";
      return;
    }
    case "flex-flow": {
      for (const t of splitSpaces(value)) {
        if (/wrap/.test(t)) out["flex-wrap"] = t; else out["flex-direction"] = t;
      }
      return;
    }
    case "gap": {
      const [r, c = r] = splitSpaces(value);
      out["row-gap"] = r; out["column-gap"] = c;
      return;
    }
    case "place-items": {
      const [a, j = a] = splitSpaces(value);
      out["align-items"] = a; out["justify-items"] = j;
      return;
    }
    case "place-content": {
      const [a, j = a] = splitSpaces(value);
      out["align-content"] = a; out["justify-content"] = j;
      return;
    }
    case "place-self": {
      const [a, j = a] = splitSpaces(value);
      out["align-self"] = a; out["justify-self"] = j;
      return;
    }
    case "background":
      out["background"] = value; // kept whole: layers are resolved later
      return;
    case "background-color":
      out["background"] = value;
      return;
    case "font": {
      if (value === "inherit") { for (const p of ["font-family", "font-size", "font-weight", "font-style", "line-height"]) out[p] = "inherit"; return; }
      // [style] [weight] size[/line-height] family
      const v = splitSpaces(value);
      let i = 0;
      for (; i < v.length; i++) {
        if (/^(italic|oblique)$/.test(v[i])) out["font-style"] = v[i];
        else if (/^(bold|bolder|lighter|normal|\d{3})$/.test(v[i])) out["font-weight"] = v[i];
        else break;
      }
      if (i < v.length) {
        const [size, lh] = v[i].split("/");
        out["font-size"] = size;
        if (lh) out["line-height"] = lh;
        out["font-family"] = v.slice(i + 1).join(" ");
      }
      return;
    }
    case "overflow": {
      const [x, y = x] = splitSpaces(value);
      out["overflow-x"] = x; out["overflow-y"] = y;
      return;
    }
    case "grid-column": case "grid-row":
      out[prop] = value;
      return;
    case "text-decoration":
      out["text-decoration-line"] = splitSpaces(value).find((t) => /underline|line-through|none|overline/.test(t)) || "none";
      return;
    default:
      out[prop] = value;
  }
}

export class StyleEngine {
  constructor() {
    this.rules = [];
    this.index = { id: new Map(), cls: new Map(), tag: new Map(), any: [] };
    this.order = 0;
    this.keyframes = {};
    // In cascade order: { owner (the page's <style> or <link>; null for
    // the user agent's), css, rules, keyframes }.
    this.sheets = [];
  }

  // `cache`: { get(css, path) → JSON | undefined, keep(css, json) } (the
  // native one keeps a sheet's parsed rules for the process: a second
  // window doesn't parse and index them again; and finds the ones the app
  // was built with, by the sheet's asset `path`: tools/qjs_modules.zig).
  // `ua`: the user agent's sheet, which every page rule overrides whatever
  // its specificity (the cascade's origins).
  addSheet(css, cache, path, owner = null, ua = false) {
    const sheet = StyleEngine.parsed(css, cache, path, owner);
    sheet.ua = ua;
    this.sheets.push(sheet);
    this.indexSheet(sheet);
  }

  // A sheet: its parts (one, read whole, or its top-level rules, for a
  // sheet that may change), their rules in order, their @keyframes.
  static parsed(css, cache, path, owner) {
    let parsed = null;
    const kept = cache?.get(css, path);
    if (kept) { try { parsed = JSON.parse(kept); } catch { parsed = null; } }
    if (!parsed) {
      parsed = sheetData(css);
      try { cache?.keep(css, JSON.stringify(parsed)); } catch {}
    }
    return StyleEngine.sheetOf(owner, css, [StyleEngine.part(css, parsed)]);
  }

  static part(text, parsed = sheetData(text)) {
    const rules = parsed.rules.map(([sel, pseudo, spec, decls, media, key]) => ({ sel, pseudo, spec, decls, media, key, order: 0, match: null }));
    return { text, rules, keyframes: parsed.keyframes || {} };
  }

  static sheetOf(owner, css, parts) {
    const keyframes = {};
    for (const p of parts) Object.assign(keyframes, p.keyframes);
    return { owner, css, parts, rules: parts.length === 1 ? parts[0].rules : parts.flatMap((p) => p.rules), keyframes };
  }

  // A sheet's new text, rule by rule: a rule whose text it had before
  // keeps its parsed form (one inserted rule parses one rule).
  static changed(owner, css, was) {
    const pool = new Map();
    for (const p of was?.parts || []) {
      let l = pool.get(p.text);
      if (!l) pool.set(p.text, (l = []));
      l.push(p);
    }
    const parts = splitRules(css).map((text) => pool.get(text)?.shift() || StyleEngine.part(text));
    return StyleEngine.sheetOf(owner, css, parts);
  }

  indexSheet(sheet) {
    Object.assign(this.keyframes, sheet.keyframes);
    for (const r of sheet.rules) {
      r.order = this.order++;
      r.ua = !!sheet.ua;
      this.rules.push(r);
      if (r.key[0] === "any") this.index.any.push(r);
      else push(this.index[r.key[0]], r.key[1], r);
    }
  }

  // The page's sheets now ([{ owner, css, path }], in document order; the
  // user agent's stay first). A sheet whose owner and text are the same
  // keeps its parsed rules (and their compiled matchers); the rest are
  // parsed (with `cache`, as addSheet). Null when nothing changed, else
  // the rules that came and went and whether @keyframes did.
  syncSheets(list, cache) {
    const old = new Map();
    for (const sh of this.sheets) if (sh.owner) old.set(sh.owner, sh);
    const next = this.sheets.filter((sh) => !sh.owner);
    for (const { owner, css, path } of list) {
      const was = old.get(owner);
      next.push(was && was.css === css ? was : was ? StyleEngine.changed(owner, css, was) : StyleEngine.parsed(css, cache, path, owner));
    }
    if (next.length === this.sheets.length && next.every((sh, i) => sh === this.sheets[i])) return null;
    // What came and went, part by part.
    const before = new Set();
    for (const sh of this.sheets) for (const p of sh.parts) before.add(p);
    const after = new Set();
    for (const sh of next) for (const p of sh.parts) after.add(p);
    const change = { added: [], removed: [], keyframes: false };
    for (const p of after) if (!before.has(p)) { change.added.push(...p.rules); if (Object.keys(p.keyframes).length) change.keyframes = true; }
    for (const p of before) if (!after.has(p)) { change.removed.push(...p.rules); if (Object.keys(p.keyframes).length) change.keyframes = true; }
    this.sheets = next;
    this.rules = [];
    this.index = { id: new Map(), cls: new Map(), tag: new Map(), any: [] };
    this.order = 0;
    this.keyframes = {};
    for (const sh of next) this.indexSheet(sh);
    return change;
  }


  // Matching rules for an element: { normal: [...], before: [...], after: [...] }.
  matching(el) {
    const cand = new Set(this.index.any);
    const add = (list) => { if (list) for (const r of list) cand.add(r); };
    add(this.index.tag.get(el.localName));
    if (el.id) add(this.index.id.get(el.id));
    const cl = el.getAttribute("class");
    if (cl) for (const c of cl.split(/\s+/)) if (c) add(this.index.cls.get(c));
    const out = { normal: [], before: [], after: [] };
    for (const r of cand) {
      if (!mediaMatches(r.media)) continue;
      let m = r.match;
      if (m === null) {
        try { m = r.match = compileMatch(el, r.sel); } catch { m = r.match = false; }
      }
      if (!m) continue;
      let ok = false;
      try { ok = m(el); } catch {}
      if (ok) (r.pseudo ? out[r.pseudo] : out.normal).push(r);
    }
    return out;
  }

  // Specified values (longhands) for one element from its rules and inline style.
  static cascade(rules, inline) {
    const normal = {}, important = {};
    StyleEngine.expandInto(StyleEngine.sorted(rules).flatMap((r) => r.decls), normal, important);
    if (inline) StyleEngine.expandInto(inline, normal, important);
    return Object.assign(normal, important);
  }

  // Rules in cascade order: the user agent's before the page's (origin),
  // then specificity, then source order.
  static sorted(rules) {
    return rules.slice().sort((x, y) => (y.ua ? 1 : 0) - (x.ua ? 1 : 0) || cmpSpec(x.spec, y.spec) || x.order - y.order);
  }

  // Declarations → longhands, into `normal` or (!important) `important`.
  static expandInto(decls, normal, important) {
    for (const d of decls) expand(d.prop, d.value, d.important ? important : normal);
  }
}

// A sheet's text as its top-level rules (statements and blocks, comments
// dropped): what CSSOM's cssRules indexes, and the parts a changing sheet
// is parsed in.
export function splitRules(css) {
  const out = [];
  let depth = 0, start = 0, quote = "";
  for (let i = 0; i < css.length; i++) {
    const c = css[i];
    if (quote) { if (c === "\\") i++; else if (c === quote) quote = ""; continue; }
    if (c === "/" && css[i + 1] === "*") { const end = css.indexOf("*/", i + 2); i = end < 0 ? css.length : end + 1; continue; }
    if (c === '"' || c === "'") quote = c;
    else if (c === "{") depth++;
    else if (c === "}" || (c === ";" && depth === 0)) {
      if (c === "}" && --depth > 0) continue;
      const rule = css.slice(start, i + 1).replace(/^(\s|\/\*[\s\S]*?\*\/)+/, "").trim();
      if (rule && rule !== ";") out.push(rule);
      start = i + 1;
      depth = Math.max(depth, 0);
    }
  }
  return out;
}

// A sheet's rules as addSheet keeps them (and the build compiles them:
// sheet-compiler.js): [sel, pseudo, spec, decls, media, index key] each.
export function sheetData(css) {
  const rules = parseSheet(css, 0);
  return { rules: rules.map((r) => [r.sel, r.pseudo, r.spec, r.decls, r.media, indexKey(r.sel)]), keyframes: rules.keyframes };
}

// A rule's index key: the rightmost compound selector's id, class or tag.
// (Ignoring pseudo-class arguments: section:not(.active) is about sections.)
function indexKey(sel) {
  const last = (sel.includes("(") ? sel.replace(/:[\w-]+\((?:[^()]|\([^()]*\))*\)/g, "") : sel).split(/[\s>+~]+/).filter(Boolean).pop() || "*";
  const id = /#([\w-]+)/.exec(last), cls = /\.([\w-]+)/.exec(last), tag = /^([a-zA-Z][\w-]*)/.exec(last);
  if (id) return ["id", id[1]];
  if (cls) return ["cls", cls[1]];
  if (tag) return ["tag", tag[1].toLowerCase()];
  return ["any"];
}

function push(map, k, v) {
  let l = map.get(k);
  if (!l) map.set(k, (l = []));
  l.push(v);
}

// Computed style: inherited values from the parent, var() substituted.
export function computeStyle(specified, parent) {
  const cs = Object.create(null);
  if (parent) {
    for (const k in parent) if (INHERITED.has(k) || k.startsWith("--")) cs[k] = parent[k];
    // A line-height in % or em is a length computed where it's declared
    // (its element's font size) and inherited as that length; only a
    // number is inherited as a ratio (h1 { font-size: 36px } under
    // :root { font: 16px/145% } is 23.2px high, not 52). The parent's font
    // size (__fs, render.js) is resolved before its children's styles.
    const lh = parent["line-height"];
    if (lh && parent.__fs !== undefined && relativeUnit(lh)) cs["line-height"] = `${relativeLength(lh, parent.__fs)}px`;
    // So is a font size (a span in an h1 is the h1's 32px, not 2em of it).
    if (parent.__fs !== undefined && parent["font-size"] !== undefined) cs["font-size"] = `${parent.__fs}px`;
  }
  // Custom properties first (they may refer to inherited ones).
  for (const k in specified) if (k.startsWith("--")) cs[k] = specified[k];
  for (const k in cs) if (k.startsWith("--")) cs[k] = substitute(cs[k], cs, 0);
  for (const k in specified) {
    if (k.startsWith("--")) continue;
    let v = specified[k];
    if (v === "inherit") { if (parent && parent[k] !== undefined) cs[k] = parent[k]; else delete cs[k]; continue; }
    if (v === "initial" || v === "unset") { delete cs[k]; continue; }
    cs[k] = substitute(v, cs, 0);
  }
  // System colors (CanvasText, the UA's text color on <html>; Field,
  // ButtonFace, …): the defaults for the used color-scheme (dark with
  // color-scheme: dark, or light dark with a dark system), or the system's
  // own while forced; inherited as the resolved colors.
  let dark;
  for (const k of COLOR_PROPS) {
    const v = cs[k];
    if (!v || !SYSTEM_ANY.test(v)) continue;
    if (dark === undefined) {
      const scheme = cs["color-scheme"] || "normal";
      dark = viewport.forced ? !!viewport.forced.dark : /dark/.test(scheme) && (!/light/.test(scheme) || viewport.dark);
    }
    cs[k] = v.replace(SYSTEM_ALL, (name) => systemColor(name, dark));
  }
  if (maxContent(cs, parent)) cs.__maxc = true;
  else if (fitContent(cs, parent)) cs.__fitc = true;
  return cs;
}

// In a width: fit-content box, text that has to wrap takes the whole
// width it's offered (the box is then that wide, as in browsers), not just
// its longest line.
export function fitContent(cs, parent) {
  const w = cs.width;
  return INTRINSIC_FIT.has(w) || (!!parent?.__fitc && (w === undefined || w === "auto"));
}
const INTRINSIC_FIT = new Set(["fit-content", "-webkit-fit-content", "-moz-fit-content"]);

// In a width: max-content box, lines are as long as their content: they
// don't wrap at the container (render.js textProps), down to a box with a
// width of its own.
export function maxContent(cs, parent) {
  const w = cs.width;
  return w === "max-content" || (!!parent?.__maxc && (w === undefined || w === "auto" || w === "fit-content"));
}

// A length in %, em, ex or ch (by its last characters: this runs for every
// element, and most line-heights are a number or px).
function relativeUnit(v) {
  const last = v.charCodeAt(v.length - 1);
  if (last === 37) return true; // %
  if (v.length < 3) return false;
  const prev = v.charCodeAt(v.length - 2);
  if (last === 109) return prev === 101 && v.charCodeAt(v.length - 3) !== 114; // em, not rem
  if (last === 120) return prev === 101; // ex (not px)
  if (last === 104) return prev === 99; // ch
  return false;
}

// A % or em-like length at font size `fs`, in px.
function relativeLength(v, fs) {
  const n = parseFloat(v);
  if (v.endsWith("%")) return (n / 100) * fs;
  if (v.endsWith("ex") || v.endsWith("ch")) return n * fs * 0.5;
  return n * fs;
}

export function substitute(v, cs, depth = 0) {
  if (depth > 8 || !v.includes("var(")) return v;
  return substitute(v.replace(/var\(\s*(--[\w-]+)\s*(?:,\s*((?:[^()]|\([^()]*\))*))?\)/g, (_, name, fb) =>
    cs[name] !== undefined ? cs[name] : (fb !== undefined ? fb.trim() : "")), cs, depth + 1);
}

// ---------------------------------------------------------------------------
// Values

// A length → px (number), or { pct } for percentages, or "auto"/null.
export function length(v, fontSize, pctOk = true) {
  if (v === undefined || v === null || v === "") return null;
  v = String(v).trim();
  if (v === "auto" || v === "none" || v === "normal") return v === "auto" ? "auto" : null;
  if (v === "0") return 0;
  let m = /^(-?[\d.]+)(px|rem|em|%|[sdl]?vh|[sdl]?vw|vmin|vmax|pt|ch|ex)?$/.exec(v);
  if (m) {
    const n = parseFloat(m[1]);
    switch (m[2]) {
      case undefined: case "px": return n;
      case "rem": return n * 16;
      case "em": return n * fontSize;
      case "ch": case "ex": return n * fontSize * 0.5;
      case "pt": return n * 4 / 3;
      // The small, dynamic and large viewport units: a window has one viewport.
      case "vh": case "svh": case "dvh": case "lvh": return n * viewport.height / 100;
      case "vw": case "svw": case "dvw": case "lvw": return n * viewport.width / 100;
      case "vmin": return n * Math.min(viewport.width, viewport.height) / 100;
      case "vmax": return n * Math.max(viewport.width, viewport.height) / 100;
      case "%": return pctOk ? { pct: n } : null;
    }
  }
  m = /^(min|max|clamp|calc)\((.*)\)$/.exec(v);
  if (m) {
    const args = splitTop(m[2], ",").map((a) => a.trim());
    if (m[1] === "calc") return calc(m[2], fontSize, pctOk);
    const vals = args.map((a) => length(a, fontSize, false)).filter((x) => typeof x === "number");
    if (!vals.length) return length(args.find((a) => a.endsWith("%")), fontSize, pctOk);
    if (m[1] === "min") return Math.min(...vals);
    if (m[1] === "max") return Math.max(...vals);
    if (m[1] === "clamp" && vals.length === 3) return Math.min(Math.max(vals[0], vals[1]), vals[2]);
  }
  return null;
}

// calc() with + - * / over lengths and percentages: px (a number), or
// { pct, px } when a percentage stays (calc(50% - 8px)), resolved against
// the container at layout (tree.zig Dim.calc); null when it can't be
// (a percentage where none is allowed, % times %).
function calc(expr, fontSize, pctOk = true) {
  const toks = expr.match(/-?[\d.]+[a-z%]*|[-+*/()]|calc|min|max/g) || [];
  let i = 0;
  // Each value as [percent, px].
  const bad = [NaN, NaN];
  const num = () => {
    const t = toks[i++];
    if (t === "(") { const v = add(); i++; return v; }
    if (t === "calc") return num();
    const l = length(t, fontSize, true);
    return typeof l === "number" ? [0, l] : l && typeof l === "object" && l.px === undefined ? [l.pct, 0] : bad;
  };
  const mul = () => {
    let v = num();
    while (toks[i] === "*" || toks[i] === "/") {
      const op = toks[i++];
      const r = num();
      // One side is a plain number: a length times a percentage isn't one.
      if (op === "*") v = r[0] === 0 ? [v[0] * r[1], v[1] * r[1]] : v[0] === 0 ? [r[0] * v[1], r[1] * v[1]] : bad;
      else v = r[0] === 0 ? [v[0] / r[1], v[1] / r[1]] : bad;
    }
    return v;
  };
  const add = () => { let v = mul(); while (toks[i] === "+" || toks[i] === "-") { const op = toks[i++]; const r = mul(); v = op === "+" ? [v[0] + r[0], v[1] + r[1]] : [v[0] - r[0], v[1] - r[1]]; } return v; };
  const [pct, px] = add();
  if (!Number.isFinite(pct) || !Number.isFinite(px)) return null;
  if (pct === 0) return px;
  if (!pctOk) return null;
  return px === 0 ? { pct } : { pct, px };
}

// A length object as a prop's string: "50%", or "50%-8px" for a calc()
// with a percentage (tree.zig Dim.fromString).
export function pctString(l) {
  return l.px ? `${l.pct}%${l.px >= 0 ? "+" : ""}${l.px}px` : `${l.pct}%`;
}

const NAMED = {
  transparent: [0, 0, 0, 0], white: [255, 255, 255, 1], black: [0, 0, 0, 1], red: [255, 0, 0, 1],
  green: [0, 128, 0, 1], blue: [0, 0, 255, 1], gray: [128, 128, 128, 1], grey: [128, 128, 128, 1],
  orange: [255, 165, 0, 1], yellow: [255, 255, 0, 1], purple: [128, 0, 128, 1], none: [0, 0, 0, 0],
};

// A color → [r, g, b, a] (0-255, alpha 0-1), or null.
export function color(v, current) {
  if (!v) return null;
  v = v.trim().toLowerCase();
  if (v === "currentcolor") return current || [0, 0, 0, 1];
  if (NAMED[v]) return NAMED[v].slice();
  let m = /^#([0-9a-f]{3,8})$/.exec(v);
  if (m) {
    let h = m[1];
    if (h.length <= 4) h = [...h].map((c) => c + c).join("");
    const n = (i) => parseInt(h.slice(i, i + 2), 16);
    return [n(0), n(2), n(4), h.length === 8 ? n(6) / 255 : 1];
  }
  m = /^rgba?\((.*)\)$/.exec(v);
  if (m) {
    const p = m[1].split(/[\s,/]+/).filter(Boolean).map((x, i) => !x.endsWith("%") ? parseFloat(x) : parseFloat(x) * (i === 3 ? 0.01 : 2.55));
    return [p[0], p[1], p[2], p[3] ?? 1];
  }
  m = /^hsla?\((.*)\)$/.exec(v);
  if (m) {
    const p = m[1].split(/[\s,/]+/).filter(Boolean).map(parseFloat);
    return [...hsl(p[0], p[1] / 100, p[2] / 100), p[3] ?? 1];
  }
  m = /^color-mix\(in srgb,\s*(.*)\)$/.exec(v);
  if (m) {
    const [a, b] = splitTop(m[1], ",").map((s) => s.trim());
    const pa = /\s([\d.]+)%$/.exec(a), pb = /\s([\d.]+)%$/.exec(b);
    const ca = color(pa ? a.slice(0, pa.index) : a, current), cb = color(pb ? b.slice(0, pb.index) : b, current);
    if (!ca || !cb) return ca || cb;
    const wa = pa ? parseFloat(pa[1]) / 100 : pb ? 1 - parseFloat(pb[1]) / 100 : 0.5;
    const alpha = ca[3] * wa + cb[3] * (1 - wa);
    const mix = (i) => alpha ? (ca[i] * ca[3] * wa + cb[i] * cb[3] * (1 - wa)) / alpha : 0;
    return [mix(0), mix(1), mix(2), alpha];
  }
  return null;
}

function hsl(h, s, l) {
  const k = (n) => (n + h / 30) % 12;
  const a = s * Math.min(l, 1 - l);
  const f = (n) => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
  return [f(0) * 255, f(8) * 255, f(4) * 255];
}

// Gradient stops: [r, g, b, a, pos]. A transparent stop takes its
// neighbour's color, so the fade doesn't go through black (CSS interpolates
// premultiplied; Cairo and Android don't).
// Positions: a percentage is a fraction of the gradient line. With a px
// position anywhere (or `rep`, a repeating gradient) they can't all be
// resolved without the box: `out.su` then says each stop's unit ("%": a
// fraction, "p": px, "a": none given) and tree.zig's Gradient.resolve
// finishes them; otherwise missing ones are filled in here as CSS does
// (evenly between their neighbours) and there is no su. A stop with two
// positions ("red 0 10px") is two stops. A calc() with both
// ("calc(100% - 20px)") is unit "c": its fraction in pos and its px in
// `out.sp` (one per stop, 0 for the others), which resolve adds.
function stopsOf(parts, current, out = {}, rep = false) {
  const raw = [];
  for (const p of parts) {
    const t = splitSpaces(p);
    const c = color(t[0], current);
    if (!c) continue;
    const at = t.slice(1, 3).map(stopAt);
    if (!at.length) raw.push({ c, at: null });
    for (const a of at) raw.push({ c: c.slice(), at: a });
  }
  let stops;
  if (rep || raw.some((s) => s.at && "px" in s.at)) {
    out.su = raw.map((s) => (!s.at ? "a" : "f" in s.at && "px" in s.at ? "c" : "px" in s.at ? "p" : "%")).join("");
    stops = raw.map((s) => [...s.c, !s.at ? 0 : "f" in s.at ? s.at.f : s.at.px]);
    if (out.su.includes("c")) out.sp = raw.map((s) => (s.at && "f" in s.at && "px" in s.at ? s.at.px : 0));
  } else {
    const pos = raw.map((s) => s.at?.f ?? null);
    if (pos.length && pos[0] == null) pos[0] = 0;
    if (pos.length && pos[pos.length - 1] == null) pos[pos.length - 1] = 1;
    for (let i = 1; i < pos.length; i++) {
      if (pos[i] != null) { pos[i] = Math.max(pos[i], pos[i - 1]); continue; }
      let j = i;
      while (pos[j] == null) j++;
      for (let k = i; k < j; k++) pos[k] = pos[i - 1] + (pos[j] - pos[i - 1]) * (k - i + 1) / (j - i + 1);
    }
    stops = raw.map((s, i) => [...s.c, pos[i]]);
  }
  stops.forEach((st, i) => {
    if (st[3] > 0) return;
    const n = stops[i - 1]?.[3] > 0 ? stops[i - 1] : stops[i + 1]?.[3] > 0 ? stops[i + 1] : null;
    if (n) { st[0] = n[0]; st[1] = n[1]; st[2] = n[2]; }
  });
  return stops;
}

// A stop's position: { f } a fraction of the line, { px }, or both (a
// calc() with a percentage and px); a length that doesn't parse is 0px.
function stopAt(v) {
  const l = length(v, 16, true);
  if (l === 0) return { f: 0 };
  if (typeof l === "number") return { px: l };
  if (l && typeof l === "object") return l.px ? { f: l.pct / 100, px: l.px } : { f: l.pct / 100 };
  return { px: 0 };
}

// radial-gradient([<shape> || <size>]? [at <position>]?, stops):
// { radial: [cx, cy, rx, ry], stops }, each length a number (px) or "50%"
// (of the box's width for x, of its height for y). A size keyword
// (closest-side, farthest-side, closest-corner, farthest-corner: the
// default) depends on the box, so it goes as `ext` (with `circle` for a
// circle) and the painters resolve it (tree.zig's Gradient.radialIn);
// rx and ry are then placeholders.
function radial(args, current, rep = false) {
  const parts = splitTop(args, ",").map((s) => s.trim());
  let cx = "50%", cy = "50%", rx = "71%", ry = "71%", ext = "farthest-corner", circle = false;
  if (!color(splitSpaces(parts[0])[0], current)) {
    const [size, at] = parts.shift().split(/\bat\b/).map((x) => (x || "").trim());
    const len = (v) => /%$/.test(v) ? v : length(v, 16, false);
    const words = splitSpaces(size);
    const lens = words.filter((v) => /^[-\d.]/.test(v));
    const kws = words.filter((w) => /^(closest|farthest)-(side|corner)$/.test(w));
    const shapes = words.filter((w) => w === "circle" || w === "ellipse");
    // Invalid (the whole background is dropped, as CSS does): anything
    // else, two shapes or sizes, a size keyword with lengths.
    if (lens.length + kws.length + shapes.length !== words.length || shapes.length > 1 || kws.length > 1 || (kws.length && lens.length) || lens.length > 2) return null;
    // One length is a circle's radius (CSS), two an ellipse's.
    circle = shapes[0] === "circle" || (lens.length === 1 && !shapes.length);
    if (kws.length) ext = kws[0];
    else if (lens.length) {
      // A circle: one length, not a percentage; an ellipse: two. None negative.
      if (circle ? lens.length !== 1 || /%$/.test(lens[0]) : lens.length !== 2) return null;
      const a = len(lens[0]), b = circle ? a : len(lens[1]);
      if (a == null || b == null || parseFloat(a) < 0 || parseFloat(b) < 0) return null;
      rx = a; ry = b; ext = null;
    }
    if (at) {
      const a = splitSpaces(at);
      // "top right" as well as "right top": a vertical keyword first swaps.
      if (/^(top|bottom)$/.test(a[0]) || /^(left|right)$/.test(a[1] ?? "")) a.reverse();
      if (a.length === 1 && /^(top|bottom)$/.test(a[0])) a.unshift("center");
      const pos = (v, dflt) => ({ left: "0%", top: "0%", center: "50%", right: "100%", bottom: "100%" })[v] ?? (v == null ? dflt : len(v) ?? dflt);
      cx = pos(a[0], cx); cy = pos(a[1] ?? "center", cy);
    }
  }
  const extra = {};
  const stops = stopsOf(parts, current, extra, rep);
  if (!stops.length) return null;
  const g = { radial: [cx, cy, rx, ry], stops, ...extra };
  if (rep) g.rep = true;
  if (ext) g.ext = ext;
  if (circle) g.circle = true;
  return g;
}

// background → { color, gradient } from its layers (the last solid color,
// the first gradient; the color is drawn under the gradient).
export function background(v, current) {
  if (!v || v === "none" || v === "transparent") return null;
  let out = null;
  for (const layer of splitTop(v, ",").map((s) => s.trim())) {
    const g = /^(repeating-)?linear-gradient\((.*)\)/.exec(layer);
    if (g) {
      if (out?.gradient) continue;
      const parts = splitTop(g[2], ",").map((s) => s.trim());
      let angle = 180;
      if (/deg$/.test(parts[0])) angle = parseFloat(parts.shift());
      else if (/^to /.test(parts[0])) {
        const dir = parts.shift();
        angle = { "to right": 90, "to left": 270, "to top": 0, "to bottom": 180, "to bottom right": 135, "to top right": 45 }[dir] ?? 180;
      }
      const extra = {};
      const stops = stopsOf(parts, current, extra, !!g[1]);
      if (stops.length) (out ||= {}).gradient = { angle, stops, ...extra, ...(g[1] ? { rep: true } : {}) };
      continue;
    }
    const r = /^(repeating-)?radial-gradient\((.*)\)/.exec(layer);
    if (r) {
      if (out?.gradient) continue;
      const gr = radial(r[2], current, !!r[1]);
      if (gr) (out ||= {}).gradient = gr;
      continue;
    }
    if (/gradient\(/.test(layer)) continue; // conic: not yet
    const c = color(splitSpaces(layer).find((t) => color(t, current)) || "", current);
    if (c) (out ||= {}).color = c;
  }
  return out;
}

export function shadow(v, current) {
  if (!v || v === "none") return null;
  const first = splitTop(v, ",")[0].trim();
  const t = splitSpaces(first);
  const nums = [], rest = [];
  for (const x of t) (/^-?[\d.]/.test(x) ? nums : rest).push(x);
  const c = color(rest.find((x) => x !== "inset") || "rgba(0,0,0,.3)", current);
  if (rest.includes("inset") || !c) return null;
  const [x = 0, y = 0, blur = 0, spread = 0] = nums.map((n) => length(n, 16, false) ?? 0);
  return { x, y, blur, spread, color: c };
}
