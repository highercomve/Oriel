// The style engine: CSS text → rules; per element the cascade (selectors,
// specificity, !important, inline styles), custom properties, inheritance and
// media queries; values resolved to numbers, colors and keywords for layout.

import { compileMatch } from "#dom";

// ---------------------------------------------------------------------------
// Parsing

function stripComments(css) {
  return css.replace(/\/\*[\s\S]*?\*\//g, "");
}

// Split at a separator outside parentheses and quotes.
export function splitTop(s, sep) {
  const out = [];
  let depth = 0, quote = null, start = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (quote) { if (c === quote && s[i - 1] !== "\\") quote = null; continue; }
    if (c === '"' || c === "'") quote = c;
    else if (c === "(" || c === "[") depth++;
    else if (c === ")" || c === "]") depth--;
    else if (depth === 0 && c === sep) { out.push(s.slice(start, i)); start = i + 1; }
  }
  out.push(s.slice(start));
  return out;
}

// Whitespace-separated tokens outside parentheses.
export function splitSpaces(s) {
  const out = [];
  let depth = 0, cur = "";
  for (const c of s.trim()) {
    if (c === "(") depth++;
    if (c === ")") depth--;
    if (depth === 0 && /\s/.test(c)) { if (cur) out.push(cur); cur = ""; } else cur += c;
  }
  if (cur) out.push(cur);
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
    const m = /!\s*important\s*$/i.exec(value);
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
      // Find the matching brace.
      let depth = 1, j = open + 1;
      for (; j < text.length && depth; j++) {
        if (text[j] === "{") depth++;
        else if (text[j] === "}") depth--;
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
          const pm = /::?(before|after)\s*$/.exec(sel);
          if (pm) { pseudo = pm[1]; sel = sel.slice(0, pm.index).trim() || "*"; }
          // :focus, :hover and :active are attributes the runtime moves
          // with the focus, the pointer and the press (main.js).
          sel = sel.replace(/:focus(?![-\w])/g, "[data-nui-focus]").replace(/:hover(?![-\w])/g, "[data-nui-hover]").replace(/:active(?![-\w])/g, "[data-nui-active]");
          if (/::|:hover|:focus|:active|:visited|:empty\b/.test(sel)) continue; // states we don't track yet
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
  const s = sel.replace(/:(not|is|has|where)\(([^)]*)\)/g, (_, fn, inner) => {
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

export const viewport = { width: 1024, height: 768, dark: true, coarse: false, reducedMotion: false };

// Media Queries 4 ranges: (width <= 720px), (400px < width <= 720px),
// (height >= 30em) — what Vite/lightningcss turns max-width/min-width into.
function rangeMatches(part) {
  const inner = /^\(([^()]*)\)$/.exec(part)?.[1];
  if (!inner || !/[<>=]/.test(inner) || inner.includes(":")) return null;
  const tokens = inner.split(/(<=|>=|<|>|=)/).map((t) => t.trim()).filter(Boolean);
  const valueOf = (t) => {
    if (t === "width") return viewport.width;
    if (t === "height") return viewport.height;
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

// Each query's answer for the viewport as it is (main.js assigns its
// fields on resize and theme changes): matching asks for every candidate
// rule of every element, and parsing the query each time was ~14% of a
// settings page's JavaScript.
const mediaAnswers = new Map();
const mediaFor = { width: NaN, height: NaN, dark: null, coarse: null, reducedMotion: null };

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
  if (v.width !== f.width || v.height !== f.height || v.dark !== f.dark || v.coarse !== f.coarse || v.reducedMotion !== f.reducedMotion) {
    mediaAnswers.clear();
    Object.assign(f, { width: v.width, height: v.height, dark: v.dark, coarse: v.coarse, reducedMotion: v.reducedMotion });
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
        case "prefers-color-scheme": return val === (viewport.dark ? "dark" : "light");
        case "prefers-reduced-motion": return val === "reduce" ? viewport.reducedMotion : !viewport.reducedMotion;
        case "pointer": return val === (viewport.coarse ? "coarse" : "fine");
        case "hover": return val === (viewport.coarse ? "none" : "hover");
        case "orientation": return val === (viewport.width >= viewport.height ? "landscape" : "portrait");
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
  "overflow-wrap", "list-style", "color-scheme", "text-decoration-color",
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
    case "inset":
      return box(prop, (side) => side);
    case "border-width":
      return box(prop, (side) => `border-${side}-width`);
    case "border-style":
      return box(prop, (side) => `border-${side}-style`);
    case "border-color":
      return box(prop, (side) => `border-${side}-color`);
    case "border-radius": {
      const v = splitSpaces(value.split("/")[0]);
      const [a, b = a, c = a, d = b] = v;
      out["border-top-left-radius"] = a; out["border-top-right-radius"] = b;
      out["border-bottom-right-radius"] = c; out["border-bottom-left-radius"] = d;
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
    case "flex": {
      const v = splitSpaces(value);
      if (value === "none") { out["flex-grow"] = "0"; out["flex-shrink"] = "0"; out["flex-basis"] = "auto"; return; }
      if (value === "auto") { out["flex-grow"] = "1"; out["flex-shrink"] = "1"; out["flex-basis"] = "auto"; return; }
      if (v.length === 1 && /^[\d.]+$/.test(v[0])) { out["flex-grow"] = v[0]; out["flex-shrink"] = "1"; out["flex-basis"] = "0%"; return; }
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
  }

  // `cache`: { get(css) → JSON | undefined, keep(css, json) } (the native
  // one keeps a sheet's parsed rules for the process: a second window
  // doesn't parse and index them again).
  addSheet(css, cache) {
    let parsed = null;
    const kept = cache?.get(css);
    if (kept) { try { parsed = JSON.parse(kept); } catch { parsed = null; } }
    if (!parsed) {
      const rules = parseSheet(css, 0);
      parsed = { rules: rules.map((r) => [r.sel, r.pseudo, r.spec, r.decls, r.media, indexKey(r.sel)]), keyframes: rules.keyframes };
      try { cache?.keep(css, JSON.stringify(parsed)); } catch {}
    }
    Object.assign(this.keyframes, parsed.keyframes);
    for (const [sel, pseudo, spec, decls, media, key] of parsed.rules) {
      const r = { sel, pseudo, spec, decls, media, order: this.order++, match: null };
      this.rules.push(r);
      if (key[0] === "any") this.index.any.push(r);
      else push(this.index[key[0]], key[1], r);
    }
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

  // Rules in cascade order: specificity, then source order.
  static sorted(rules) {
    return rules.slice().sort((x, y) => cmpSpec(x.spec, y.spec) || x.order - y.order);
  }

  // Declarations → longhands, into `normal` or (!important) `important`.
  static expandInto(decls, normal, important) {
    for (const d of decls) expand(d.prop, d.value, d.important ? important : normal);
  }
}

// A rule's index key: the rightmost compound selector's id, class or tag.
// (Ignoring pseudo-class arguments: section:not(.active) is about sections.)
function indexKey(sel) {
  const last = sel.replace(/:[\w-]+\((?:[^()]|\([^()]*\))*\)/g, "").split(/[\s>+~]+/).filter(Boolean).pop() || "*";
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
  return cs;
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
  let m = /^(-?[\d.]+)(px|rem|em|%|vh|vw|vmin|vmax|pt|ch|ex)?$/.exec(v);
  if (m) {
    const n = parseFloat(m[1]);
    switch (m[2]) {
      case undefined: case "px": return n;
      case "rem": return n * 16;
      case "em": return n * fontSize;
      case "ch": case "ex": return n * fontSize * 0.5;
      case "pt": return n * 4 / 3;
      case "vh": return n * viewport.height / 100;
      case "vw": return n * viewport.width / 100;
      case "vmin": return n * Math.min(viewport.width, viewport.height) / 100;
      case "vmax": return n * Math.max(viewport.width, viewport.height) / 100;
      case "%": return pctOk ? { pct: n } : null;
    }
  }
  m = /^(min|max|clamp|calc)\((.*)\)$/.exec(v);
  if (m) {
    const args = splitTop(m[2], ",").map((a) => a.trim());
    if (m[1] === "calc") return calc(m[2], fontSize);
    const vals = args.map((a) => length(a, fontSize, false)).filter((x) => typeof x === "number");
    if (!vals.length) return length(args.find((a) => a.endsWith("%")), fontSize, pctOk);
    if (m[1] === "min") return Math.min(...vals);
    if (m[1] === "max") return Math.max(...vals);
    if (m[1] === "clamp" && vals.length === 3) return Math.min(Math.max(vals[0], vals[1]), vals[2]);
  }
  return null;
}

// calc() with + - * / over lengths (percentages unsupported: null).
function calc(expr, fontSize) {
  const toks = expr.match(/-?[\d.]+[a-z%]*|[-+*/()]|calc|min|max/g) || [];
  let i = 0;
  const num = () => {
    const t = toks[i++];
    if (t === "(") { const v = add(); i++; return v; }
    if (t === "calc") return num();
    const l = length(t, fontSize, false);
    return typeof l === "number" ? l : NaN;
  };
  const mul = () => { let v = num(); while (toks[i] === "*" || toks[i] === "/") { const op = toks[i++]; const r = num(); v = op === "*" ? v * r : v / r; } return v; };
  const add = () => { let v = mul(); while (toks[i] === "+" || toks[i] === "-") { const op = toks[i++]; const r = mul(); v = op === "+" ? v + r : v - r; } return v; };
  const v = add();
  return Number.isFinite(v) ? v : null;
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
function stopsOf(parts, current) {
  const stops = parts.map((p, i) => {
    const t = splitSpaces(p);
    const c = color(t[0], current);
    const pos = t[1] ? parseFloat(t[1]) / 100 : i / Math.max(parts.length - 1, 1);
    return c ? [...c, pos] : null;
  }).filter(Boolean);
  stops.forEach((st, i) => {
    if (st[3] > 0) return;
    const n = stops[i - 1]?.[3] > 0 ? stops[i - 1] : stops[i + 1]?.[3] > 0 ? stops[i + 1] : null;
    if (n) { st[0] = n[0]; st[1] = n[1]; st[2] = n[2]; }
  });
  return stops;
}

// radial-gradient([<shape> || <size>]? [at <position>]?, stops):
// { radial: [cx, cy, rx, ry], stops }, each length a number (px) or "50%"
// (of the box's width for x, of its height for y). A size keyword
// (closest-side, farthest-side, closest-corner, farthest-corner: the
// default) depends on the box, so it goes as `ext` (with `circle` for a
// circle) and the painters resolve it (tree.zig's Gradient.radialIn);
// rx and ry are then placeholders.
function radial(args, current) {
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
  const stops = stopsOf(parts, current);
  if (!stops.length) return null;
  const g = { radial: [cx, cy, rx, ry], stops };
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
      const stops = stopsOf(parts, current);
      if (stops.length) (out ||= {}).gradient = { angle, stops };
      continue;
    }
    const r = /^radial-gradient\((.*)\)/.exec(layer);
    if (r) {
      if (out?.gradient) continue;
      const gr = radial(r[1], current);
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
