// The flattener: the DOM and its computed styles → native nodes (several
// elements per native view where possible), diffed against the last frame
// into operations for the Zig side.
//
// Ops (JSON array):
//   ["c", id, kind]          create a node (view, text, input, textarea, select, icon)
//   ["p", id, props]         its properties (layout, drawing, text, value…)
//   ["k", id, [ids]]         its children, in order
//   ["d", id]                destroy (and its subtree)
//   ["r", id]                the root (the body)

import { StyleEngine, computeStyle, parseInline, length, color, background, shadow, splitSpaces, splitTop, substitute, pctString, maxContent, fitContent, viewport } from "./css.js";
import { Transitions, transitionsOf } from "./transitions.js";
import { Animations, animationsOf } from "./animations.js";
import { iconFor, svgScope, svgDataText, svgSize } from "./icons.js";
import { commandsOf, versionOf, programOf } from "./canvas.js";
import { classStyle, nodeIndex, nodeAt, compileMatch } from "#dom";
// The runtime's own weak caches keyed by nodes: marked so their entries
// don't keep a node's wrapper from being replaced (a page's weak
// references do: dom/store.zig prune).
const internalWeak = (m) => (globalThis.__nuiDom?.internal?.(m), m);


// The user-agent stylesheet: what browsers do without CSS.
export const UA_CSS = `
html, body, div, section, main, header, footer, nav, article, aside, form, fieldset, p, ul, ol, li, dl, dt, dd,
h1, h2, h3, h4, h5, h6, pre, blockquote, figure, figcaption, details, summary, address, hr { display: block; }
head, script, style, template, title, meta, link, noscript, datalist, option, [hidden] { display: none; }
li { display: list-item; }
ul { list-style-type: disc; }
ol { list-style-type: decimal; }
ul ul, ol ul { list-style-type: circle; }
ul ul ul, ul ol ul, ol ul ul, ol ol ul { list-style-type: square; }
button, input, textarea, select, img, svg, canvas, progress, meter { display: inline-block; }
button { padding: 1px 6px; border: 1px solid #767676; border-radius: 3px; background-color: #efefef; color: black; font-size: 13.333px; }
input, textarea, select { padding: 1px 2px; border: 1px solid #767676; border-radius: 2px; background-color: white; color: black; font-size: 13.333px; }
html { font-size: 16px; color: black; }
body { margin: 8px; }
p, ul, ol, dl, blockquote, pre, figure { margin-top: 1em; margin-bottom: 1em; }
ul, ol { padding-left: 40px; }
/* As both browsers' UA sheets: a list in a list has no margins of its own,
   a definition is indented. */
ul ul, ul ol, ol ul, ol ol, ul dl, ol dl, dl ul, dl ol { margin-top: 0; margin-bottom: 0; }
dd { margin-left: 40px; }
/* A fieldset's box, as both browsers'. Its legend sits in the top border
   (browsers draw the border through its middle; here the legend overlaps
   the top padding and border, as wide as its text), the padding below it.
   (No :first-child here: a structural selector in the UA sheet would make
   every text edit restyle.) */
fieldset { margin: 0 2px; padding: .35em .75em .625em; border: 2px groove #c0c0c0; }
fieldset > legend { display: block; width: fit-content; padding: 0 2px; margin-top: calc(-.35em - 2px); margin-bottom: .35em; }
h1 { font-size: 2em; margin: .67em 0; font-weight: bold; }
h2 { font-size: 1.5em; margin: .83em 0; font-weight: bold; }
h3 { font-size: 1.17em; margin: 1em 0; font-weight: bold; }
h4, h5, h6 { font-weight: bold; margin: 1.33em 0; }
b, strong, th { font-weight: bold; }
i, em, cite, var, dfn { font-style: italic; }
small { font-size: .83em; }
mark { background-color: yellow; color: black; }
code, kbd, samp, pre, tt { font-family: monospace; }
/* Controls in the platform's control font, as Chromium (-webkit-small-control:
   Arial on Windows; a backend that doesn't know the name takes system-ui), a
   textarea in monospace. */
button, input, select { font-family: -webkit-small-control, system-ui; }
textarea { font-family: monospace; }
/* As both browsers' UA sheets (their font shorthand): controls don't
   inherit the page's line-height or spacing (a 16px button under
   font: 18px/145% is a normal line high, not 26px). */
button, input, select, textarea { line-height: normal; letter-spacing: normal; word-spacing: normal; text-transform: none; text-indent: 0; }
pre { white-space: pre; }
a { color: #0000ee; text-decoration: underline; cursor: pointer; }
button { padding: 1px 6px; border: 2px outset #ccc; background: #efefef; font-size: 13.33px; text-align: center; }
input, textarea, select { padding: 1px 2px; border: 2px inset #ccc; font-size: 13.33px; background: white; }
textarea { white-space: pre-wrap; }
/* As Chromium: a textarea has a 1px border and 2px padding, a select a 1px
   border and none. */
textarea { padding: 2px; border-width: 1px; }
select { padding: 0; border-width: 1px; }
/* Chromium's margins round a checkbox, a radio and a slider (a page's
   margin: 0 wins). */
input[type=checkbox], input[type=radio] { margin: 3px 3px 3px 4px; }
input[type=range] { margin: 2px; }
hr { border-top: 1px solid #888; margin: .5em 0; }
table { display: table; border-spacing: 2px; border-collapse: separate; }
thead { display: table-header-group; } tbody { display: table-row-group; } tfoot { display: table-footer-group; }
tr { display: table-row; } td, th { display: table-cell; padding: 1px; vertical-align: middle; }
th { text-align: center; } caption { display: table-caption; text-align: center; }
col, colgroup { display: none; }
`;

// WebKit's controls (WKWebView, so the native renderer on macOS and iOS):
// -webkit-small-control is the system font at 11px, a textarea's too
// (measured against WKWebView: an input 19 tall on macOS, a textarea 32).
// macOS's buttons (WebKit's html.css there: 2px 6px 3px, a ButtonFace
// border), their background marked for pushButton (WKWebView's push button
// while the page keeps it); checkboxes and radios 12px, 3px 2px round
// (measured).
export const UA_CSS_MAC = `
button { padding: 2px 6px 3px; background: rgba(239, 239, 239, 0.9999); border-color: rgb(192, 192, 192); border-radius: 0; }
input[type="checkbox"], input[type="radio"] { width: 12px; height: 12px; margin: 3px 2px; }
`;

export const UA_CSS_WEBKIT = `
button, input, textarea, select { font-size: 11px; }
textarea { font-family: -webkit-small-control, system-ui; }
`;

// Chrome's controls on Android (the WebView there), as measured: 16px
// checkboxes and radios, a radio's margin 3px 3px 0 5px. Text fields and
// selects are sized by the backend's measure (android.zig).
export const UA_CSS_CHROME_ANDROID = `
input[type=checkbox], input[type=radio] { width: 16px; height: 16px; }
input[type=radio] { margin: 3px 3px 0 5px; }
`;

// WebKitGTK's controls, as measured (Linux: the WebView there): the GTK
// UI font (gtk-font-name's family, its size in whole px: platform.uiFont)
// on every control, Adwaita's 1px #cdcdcd border rounded 5px, white text
// fields, #f4f4f4 buttons and selects, 12px checkboxes and 20px sliders.
export function uaCssWebkitGtk(font, accent) {
  const [family, px] = Array.isArray(font) && font.length === 2 ? font : ["system-ui", 14];
  // Sliders and checkboxes in the theme's accent color.
  const acc = Array.isArray(accent) && accent.length === 3 ? `input { accent-color: rgb(${accent.map((v) => +v || 0).join(", ")}); }` : "";
  return `${acc}
button, input, textarea, select { font-size: ${+px || 14}px; font-family: ${JSON.stringify(String(family))}, system-ui; }
input, textarea { padding: 2px; border: 1px solid #cdcdcd; border-radius: 5px; background-color: white; color: black; }
button, select { border: 1px solid #cdcdcd; border-radius: 5px; background-color: #f4f4f4; color: rgba(0, 0, 0, 0.8); }
button { padding: 3px 7px 4px; }
select { padding: 5px 6px; }
input[type="checkbox"], input[type="radio"] { width: 12px; height: 12px; margin: 3px 2px; }
input[type="range"] { height: 20px; margin: 2px; }
`;
}

const INLINE_DISPLAY = new Set(["inline"]);
// Elements whose changes can change the page's sheets.
const SHEET_OWNERS = new Set(["style", "link"]);
const NO_PARENTS = { set() {}, get() { return undefined; } };
// Rules changed at once beyond which every element is styled again rather
// than the ones each rule's selector finds.
const SHEET_RULES_INCREMENTAL = 64;
const INTRINSIC_WIDTHS = new Set(["max-content", "fit-content", "-webkit-fit-content", "-moz-fit-content"]);
const ATOMIC_INLINE = new Set(["inline-block", "inline-flex", "inline-grid"]);
// Replaced elements: an image's bottom sits on the line's baseline.
const REPLACED = new Set(["img", "svg", "canvas", "video", "iframe", "object", "embed", "picture"]);

// A line-height other than normal in px at font size `fs`: a number times
// it, a percentage of it, a length.
// A form control's accessible name, as browsers compute it for one (the
// common cases of the HTML-AAM rules): aria-labelledby's elements' text,
// aria-label, its <label>s' text (label[for=id], or the label around it,
// without the control's own text), then title. "" for none.
function accessibleName(el) {
  const clean = (t) => (t || "").replace(/\s+/g, " ").trim();
  const doc = el.ownerDocument;
  const by = el.getAttribute("aria-labelledby");
  if (by && doc) {
    const t = clean(by.split(/\s+/).map((id) => doc.getElementById(id)?.textContent || "").join(" "));
    if (t) return t;
  }
  const aria = clean(el.getAttribute("aria-label"));
  if (aria) return aria;
  // A label's text, the control itself (a <select>'s options) left out.
  const textOf = (label) => {
    let out = "";
    const walk = (n) => {
      for (let c = n.firstChild; c; c = c.nextSibling) {
        if (c === el) continue;
        if (c.nodeType === 3) out += c.data;
        else if (c.nodeType === 1 && !SKIP.has(c.localName) && !CONTROLS.has(c.localName)) walk(c);
      }
    };
    walk(label);
    return out;
  };
  const parts = [];
  const id = el.getAttribute("id");
  if (id && doc) for (const l of doc.querySelectorAll("label[for]")) if (l.getAttribute("for") === id) parts.push(textOf(l));
  const around = el.closest?.("label");
  if (around && !parts.length) parts.push(textOf(around));
  const label = clean(parts.join(" "));
  if (label) return label;
  return clean(el.getAttribute("title"));
}

// vertical-align values a box alone on its line is placed by (imageLine).
const LINE_ALIGNS = new Set(["middle", "top", "bottom"]);

// A box's margin-box height less its margins, when its props say it (a
// px height: content-box sizing adds the vertical padding and border).
function boxHeight(p) {
  if (typeof p.h !== "number") return null;
  if (!p.cb) return p.h;
  const v = (a, i) => (typeof a?.[i] === "number" ? a[i] : 0);
  return p.h + v(p.pad, 0) + v(p.pad, 2) + v(p.bw, 0) + v(p.bw, 2);
}

function lineHeightPx(v, fs) {
  if (/^[\d.]+$/.test(v)) return parseFloat(v) * fs;
  if (v.endsWith("%")) return (parseFloat(v) / 100) * fs;
  return length(v, fs, false) ?? undefined;
}

// How far a line box reaches below its baseline: the strut's descent plus
// half the leading, from the backend's font (host.fontMetrics: ascent,
// descent, line gap), else a typical sans font's (Noto Sans: ascent 1.069,
// descent 0.293 em, no gap). line-height: normal is the three, each
// rounded, as WebKit and Chromium make it.
const fontMetricsCache = new Map();
function lineDescent(cs, fs, host) {
  return lineStrut(cs, fs, host)[1];
}
// A line's strut (CSS 2.2 §10.8.1: an empty inline box with the block's
// font and line-height, in every line): [above, below] its baseline.
function lineStrut(cs, fs, host) {
  const mono = /mono/.test(cs["font-family"] || "");
  const family = familyOf(cs) || "";
  const key = `${fs}|${mono}|${family}`;
  let m = fontMetricsCache.get(key);
  if (!m) {
    try { m = host?.fontMetrics?.(fs, mono, family); } catch { m = null; }
    if (!m) m = [fs * 1.069, fs * 0.293, 0];
    fontMetricsCache.set(key, m);
  }
  const [ascent, descent, gap = 0] = m;
  const normal = Math.round(ascent) + Math.round(descent) + Math.round(gap);
  const v = cs["line-height"];
  const lh = !v || v === "normal" ? normal : lineHeightPx(v, fs) ?? normal;
  // The half-leading above the baseline floored, as WebKit places it (a
  // 30px line-height over a 12+3px font: 7 above, 8 below).
  const above = Math.round(ascent) + Math.floor((lh - Math.round(ascent) - Math.round(descent)) / 2);
  // Its x-height third (vertical-align: middle): the backend's, else half
  // the size.
  return [above, Math.max(0, lh - above), m[3] > 0 ? m[3] : fs / 2];
}
// An inline element with a box of its own (padding, a border, rounded
// corners, a horizontal margin: a "148 MB" badge after a label). At the
// start or end of its line it is an inline box there (Renderer.boxedEnds),
// not a run of the paragraph's text (a run has no padding or margin; only
// its background would show, touching the text before it). Color, weight or
// a background alone stay a run.
const nonZero = (v) => !!v && (/^(thin|medium|thick)$/.test(v) || (parseFloat(v) !== 0 && !Number.isNaN(parseFloat(v))));
function boxedInline(cs) {
  for (const side of ["top", "right", "bottom", "left"]) {
    if (nonZero(cs[`padding-${side}`])) return true;
    const style = cs[`border-${side}-style`];
    if (style && style !== "none" && style !== "hidden" && nonZero(cs[`border-${side}-width`])) return true;
  }
  for (const c of ["top-left", "top-right", "bottom-right", "bottom-left"]) if (nonZero(cs[`border-${c}-radius`])) return true;
  return nonZero(cs["margin-left"]) || nonZero(cs["margin-right"]);
}
const SKIP = new Set(["script", "style", "head", "template", "title", "meta", "link", "noscript"]);
// Node ids of DOM nodes with the native DOM: this plus the node's store
// index (dom_stamp.zig's id_base), so the tree can make a row's children
// itself. Ids counted out here (pseudo-elements, text runs) stay below.
const NATIVE_ID_BASE = 2 ** 30;
// The attributes main.js moves for :hover, :active and :focus (css.js).
const STATE_ATTRS = ["data-nui-hover", "data-nui-active", "data-nui-focus", "data-nui-focus-visible"];

// A selector's compounds, left to right (split at combinators outside
// brackets and parentheses).
function splitCompounds(sel) {
  // A regular expression jumps between the characters that matter
  // (QuickJS runs it natively; a loop over each character is interpreted).
  const out = [];
  const re = /[()[\] >+~]/g;
  let depth = 0, start = 0;
  for (let m; (m = re.exec(sel)); ) {
    const c = m[0];
    if (c === "(" || c === "[") depth++;
    else if (c === ")" || c === "]") depth--;
    else if (depth === 0) {
      const part = sel.slice(start, m.index).trim();
      if (part) out.push(part);
      start = m.index + 1;
    }
  }
  const last = sel.slice(start).trim();
  if (last) out.push(last);
  return out;
}

const TEMPLATE_LEAF = new Set(["div", "span", "p", "b", "i", "strong", "em", "small", "label"]);
const EMPTY = Object.freeze([]);

/** A canvas or image box that a max-width may narrow below its natural
 * width while the parent stretches it: a block in a block, no auto side
 * margins, a max-width in px or a percentage of at least 100% (the
 * stretched width is never wider than the parent anyway). */
function narrowable(props, cs, parentCS) {
  const mw = props.maxw;
  if (mw === undefined || props.maxh !== undefined || !(props.ch > 0)) return false;
  if (typeof mw === "string" && !(/%$/.test(mw) && parseFloat(mw) >= 100)) return false;
  if (cs.display !== "block" || !["block", "flow-root"].includes(parentCS?.display)) return false;
  return cs["margin-left"] !== "auto" && cs["margin-right"] !== "auto";
}

export class Renderer {
  constructor(document, engine, host) {
    this.doc = document;
    this.engine = engine;
    this.host = host;
    this.ids = internalWeak(new WeakMap());      // element / text node → id
    this.owner = new Map();        // id → the element it stands for (events)
    this.prev = new Map();         // id → { kind, props json, kids json }
    this.svgFiles = new Map();     // SVG file or data: URL → its scope (svgFile), or null
    this.tx = new Transitions();   // CSS transitions in progress
    this.specs = new Map();        // id → its element's transitions (this frame)
    this.anim = new Animations();  // @keyframes animations playing
    this.animSpecs = new Map();    // id → its element's animations (this frame)
    this.ticking = false;
    this.nextId = 1;
    this.leafStyles = new Map();   // immutable native leaf templates (bounded)
    this.leafStyleBytes = 0;
    this.dirty = true;
    // Changes the page made outside an animation frame's task (a timer, an
    // event, a command's answer) since the last render: the next frame
    // renders them before its callbacks, as a browser's frame would have.
    // A frame's own changes (rAF loops, transitions) keep the engine's
    // paced frame. main.js sets inFrame for a frame's task.
    this.outside = false;
    this.inFrame = false;
    this.native = new Map();       // id → value the native field holds (inputs)
    this.styleEpoch = 0;           // full restyles invalidate matching, not last-style reads
    // Incremental rendering: what changed since the last frame (marks, from
    // the mutation records and style writes), and what each element made
    // then, reused while nothing in it or above it changed.
    this.marks = new Map();        // element → 1 (its inline style changed) | 2 (match its rules again)
    this.flatMarks = new Set();    // nodes whose own output changed (text, children, a canvas…)
    this.textOnly = true;          // pending mutations changed only text nodes
    this.simpleLeaves = true;      // tests can compare with general flattening
    this.flexLeaves = internalWeak(new WeakMap()); // parent computed style → row shapes
    // Style sharing by ancestry (shareKey): names → ids and ids → matched
    // rules, kept from frame to frame while the styles are (a full render
    // starts them over); the element → id cache is per frame.
    this.keyIds = new Map();
    this.matchShare = new Map();
    this.uids = internalWeak(new WeakMap());     // element → its own sharing id when it can't share (renewed when its attributes change)
    this.uidSeq = 0;
    this.full = true;              // everything again (first frame, the viewport changed)
    this.sc = internalWeak(new WeakMap());       // element → { parent cs, cs, matched rules, frame }
    this.fc = internalWeak(new WeakMap());       // element → what it made (element(), below)
    // node → the element it was last flattened in (removals). The native
    // DOM reports a removed node's parent itself (noteChild), and a map
    // holding parents would keep every removed tree referenced from JS
    // (released only at the next cycle collection, not when removed).
    this.parentOf = nodeIndex ? NO_PARENTS : internalWeak(new WeakMap());
    // An inline element's runs (el → its run objects), and the text node a
    // run ended up in (run → { id, runs }): its line fragments for
    // getClientRects (inlineRects).
    this.spans = internalWeak(new WeakMap());
    this.runOwner = internalWeak(new WeakMap());
    this.volatile = new Set();     // elements whose output can change without a mutation (fields…)
    this.shared = internalWeak(new WeakMap());   // parent cs → Map(specified → cs): siblings with the same rules share one
    this.cascades = new Map();     // matched rules → { normal, important } longhands
    this.frameNo = 0;
    this.cur = null;               // the element being made: { own ids, kids, fixed ids }
    this.gone = [];                // ids to destroy this frame
    this.dropped = [];             // [element, what it made]: gone unless made again this frame
    this.stamps = [];              // [row id, row element, plan] the tree stamps after emit (host.stamp)
    this.noStamp = internalWeak(new WeakSet());  // rows the tree declined: made the general way from now on
    this.listStamps = [];          // [list id, list element, row style, plan, template row, rows made here] (host.stampList)
    this.canvasEls = new Map();    // canvas element → its node id (programs sent apart: host.canvas)
    this.canvasSent = new Map();   // node id → the program version it has
    this.noStampList = internalWeak(new WeakSet()); // lists that aren't (or stopped being) the same row again
    this.declined = false;         // a stamp was declined: render again the general way
    this.structural = false;       // the sheets match by position (:nth-child, +, ~…)
    this.noCache = false;          // the sheets use :has(): any change can restyle anything
    // :hover, :active and :focus (data-nui-* attributes): the compounds
    // that use one above a rule's subject (`.card:hover .title`), the state
    // taken out. A state change on an element matching none of them only
    // changes its own style (noteAttribute).
    this.sheetsDirty = false;      // a <style> or <link> changed: syncSheets() before the next render
    // The <style> and <link> elements seen: a text or attribute change is
    // a sheet's when it's one of theirs (no tag read per mutation).
    this.sheetEls = internalWeak(new WeakSet());
    for (const el of document.querySelectorAll("style, link")) this.sheetEls.add(el);
    this.syncSheets = null;        // main.js: the page's sheets into the engine, true when they changed
    this.rulesChanged();
  }

  // What the engine's rules call for (again, when the page's sheets changed).
  rulesChanged() {
    const engine = this.engine;
    this.structural = false;
    this.noCache = false;
    this.styleAttrRules = false;
    this.stateAbove = new Map();   // attribute → [compound selector]
    for (const r of engine.rules) {
      const compounds = splitCompounds(r.sel);
      for (let i = 0; i < compounds.length - 1; i++) {
        for (const attr of STATE_ATTRS) {
          if (!compounds[i].includes(`[${attr}]`)) continue;
          const rest = compounds[i].split(`[${attr}]`).join("") || "*";
          let list = this.stateAbove.get(attr);
          if (!list) this.stateAbove.set(attr, (list = []));
          if (!list.some((x) => x.sel === rest)) list.push({ sel: rest, match: null });
        }
      }
    }
    for (const r of engine.rules) {
      if (/:(nth-|first-|last-|only-|empty)|[+~]/.test(r.sel)) this.structural = true;
      if (/:has\(/.test(r.sel)) this.noCache = true;
      if (/\[style[\]~|^$*=]/.test(r.sel)) this.styleAttrRules = true;
    }
  }

  // An element added or removed that is or holds a <style> or <link>
  // (noted in sheetEls).
  holdsSheet(n, type = n.nodeType) {
    if (type !== 1) return false;
    if (this.sheetEls.has(n)) return true;
    if (SHEET_OWNERS.has(n.localName)) { this.sheetEls.add(n); return true; }
    if (!n.firstElementChild) return false;
    let found = false;
    for (const el of n.querySelectorAll("style, link")) { this.sheetEls.add(el); found = true; }
    return found;
  }

  // A <style> or <link> was added, removed or changed (or its sheet's
  // rules, CSSOM): the sheets are read again before the next render.
  sheetChanged() {
    if (!this.inFrame) this.outside = true;
    this.sheetsDirty = true;
    this.textOnly = false;
    this.dirty = true;
  }

  // The page's sheets read again. When they changed, the elements the
  // rules that came or went match are styled again (and what's below
  // them); every element when that can't be told (:has(), @keyframes, a
  // selector the DOM can't query) or would cost more (many rules).
  applySheets() {
    this.sheetsDirty = false;
    const change = this.syncSheets?.();
    if (!change) return false;
    this.rulesChanged();
    // Matches shared by ancestry were made with the old rules, and
    // cascades are known by their rules' order, which moved.
    this.matchShare.clear();
    this.cascades.clear();
    const rules = [...change.added, ...change.removed];
    let full = this.noCache || change.keyframes || rules.length > SHEET_RULES_INCREMENTAL;
    const seen = new Set();
    for (const r of full ? [] : rules) {
      if (seen.has(r.sel)) continue;
      seen.add(r.sel);
      let els;
      try { els = this.doc.querySelectorAll(r.sel); } catch { full = true; break; }
      for (const el of els) this.mark(el, 2);
    }
    if (full) this.full = true;
    return true;
  }

  // ---------------------------------------------------------------------
  // What changed

  // An element's style may have changed: 2 when its rules may match
  // differently (its attributes), 1 when only its inline style did.
  mark(el, level) {
    if (!el || el.nodeType !== 1) return;
    // Its attributes changed: what's below it matches again (shareKey).
    if (level === 2) this.uids.delete(el);
    if (!this.inFrame) this.outside = true;
    this.textOnly = false;
    if ((this.marks.get(el) || 0) < level) this.marks.set(el, level);
    this.dirty = true;
  }

  // A node's output changed, not its style: its text, a canvas's program,
  // a click listener.
  markFlat(node, text = false) {
    if (!node) return;
    if (!this.inFrame) this.outside = true;
    if (!text) this.textOnly = false;
    this.flatMarks.add(node);
    this.dirty = true;
  }

  // The viewport or the theme changed: everything again.
  markAll() {
    if (!this.inFrame) this.outside = true;
    this.full = true;
    this.dirty = true;
  }

  // Mutation records (main.js observes the document).
  note(records) {
    for (const r of records) {
      if (r.type === "attributes") {
        const el = r.target;
        if (this.sheetEls.has(el)) this.sheetChanged();
        // The style attribute matters to the rules only through [style].
        this.mark(el, r.attributeName === "style" && !this.styleAttrRules ? 1 : 2);
        // Sibling combinators: the next siblings may match differently.
        if (this.structural && el.parentNode) this.mark(el.parentNode, 2);
        continue;
      }
      // childList (linkedom also reports a text node's new data as its removal).
      if (this.sheetEls.has(r.target)) this.sheetChanged();
      for (const n of r.addedNodes || []) {
        if (this.holdsSheet(n)) this.sheetChanged();
        this.mark(n, 2);
        const parent = n.parentNode;
        if (parent) { this.markFlat(parent, n.nodeType === 3); if (this.structural) this.mark(parent, 2); }
      }
      for (const n of r.removedNodes || []) {
        if (this.holdsSheet(n)) this.sheetChanged();
        const parent = n.parentNode || this.parentOf.get(n);
        if (parent) { this.markFlat(parent, n.nodeType === 3); if (this.structural) this.mark(parent, 2); }
        // Rebuilding a text node's known parent accounts for its removal;
        // retaining the removed node doubles work on textContent writes.
        if (n.nodeType !== 3 || !parent) this.markFlat(n, n.nodeType === 3);
      }
    }
    this.dirty = true;
  }

  // The private document observer can report directly without allocating
  // child-list records and their arrays. Page observers remain queued.
  noteChild(node, removedFrom) {
    const parent = removedFrom || node.parentNode || this.parentOf.get(node);
    const type = node.nodeType;
    if (type === 1 ? this.holdsSheet(node, type) : this.sheetEls.has(parent)) this.sheetChanged();
    if (!removedFrom) this.mark(node, 2);
    if (parent) {
      // Its rows changed: a list the tree declined may be one again.
      if (type === 1) this.noStampList.delete(parent);
      this.markFlat(parent, type === 3);
      if (this.structural) this.mark(parent, 2);
    }
    if (removedFrom && (type !== 3 || !parent)) this.markFlat(node, false);
    this.dirty = true;
  }

  noteAttribute(el, name) {
    if (this.sheetEls.has(el)) this.sheetChanged();
    if (STATE_ATTRS.includes(name) && !this.stateMattersBelow(el, name)) {
      // Hovered, pressed or focused: only its own rules may match
      // differently (1.5: match it again, not what's below it).
      this.mark(el, 1.5);
      if (el.parentNode) this.noStampList.delete(el.parentNode);
      return;
    }
    this.mark(el, name === "style" && !this.styleAttrRules ? 1 : 2);
    // A row's attributes changed: its list may be one the tree stamps again.
    if (el.parentNode) this.noStampList.delete(el.parentNode);
    if (this.structural && el.parentNode) this.mark(el.parentNode, 2);
  }

  // Whether a state attribute on `el` can change what's below it: it
  // matches a compound that has the state above a rule's subject.
  stateMattersBelow(el, attr) {
    const list = this.stateAbove.get(attr);
    if (!list) return false;
    for (const c of list) {
      if (c.match === null) { try { c.match = compileMatch(el, c.sel); } catch { c.match = false; } }
      if (!c.match) return true; // can't tell: as before
      try { if (c.match(el)) return true; } catch { return true; }
    }
    return false;
  }

  idOf(obj, key) {
    // An element's own node: from its store index with the native DOM.
    if (key === "el" && nodeIndex) return NATIVE_ID_BASE + nodeIndex(obj);
    let m = this.ids.get(obj);
    // Ordinary elements have one native node. Keep its id directly rather
    // than allocating a dictionary for every element; expand for pseudos,
    // inline runs or grid rows only when they need additional ids.
    if (typeof m === "number") {
      if (key === "el") return m;
      this.ids.set(obj, (m = { el: m }));
    } else if (!m) {
      if (key === "el") {
        const id = this.nextId++;
        this.ids.set(obj, id);
        return id;
      }
      this.ids.set(obj, (m = {}));
    }
    return m[key] ??= this.nextId++;
  }

  elementFor(id) {
    const el = this.owner.get(id);
    if (el) return el;
    // An element's own node (not in `owner`, see own()).
    return nodeAt && id >= NATIVE_ID_BASE ? nodeAt(id - NATIVE_ID_BASE) : null;
  }

  styleOf(el) {
    return this.sc.get(el)?.cs;
  }

  // ---------------------------------------------------------------------
  // One frame

  render() {
    // Records not delivered yet (a render from inside the page: focus()).
    const pending = this.observer?.takeRecords();
    if (pending?.length) this.note(pending);
    if (!this.dirty || this.rendering) return;
    this.dirty = false;
    this.outside = false;
    this.rendering = true;
    try {
      if (this.sheetsDirty && this.applySheets()) this.renderNow();
      else if (!this.canvasOnly() && !this.updateText() && !this.updateBoxes()) this.renderNow();
      // A row the tree couldn't stamp (its shape changed natively): the
      // general way now, not a frame later.
      if (this.declined) { this.declined = false; this.dirty = false; this.renderNow(); }
    } finally { this.rendering = false; }
  }

  // An animation frame begins (main.js): everything the page changed since
  // the last render is rendered now, before the callbacks, as a browser
  // renders at the end of every frame: changes made outside the frames (a
  // timer, an event) and a previous frame's own (its callbacks or their
  // promise jobs) alike. With frames at the display's rate that is the
  // pacing; a frame's changes don't wait for the engine's paced render.
  frameStart() {
    const pending = this.observer?.takeRecords();
    if (pending?.length) this.note(pending);
    try {
      if (this.dirty) {
        if (this.host.prof) this.host.log(1, `PROF frame start: rendering changes made ${this.outside ? "outside the frames" : "by the last frame"}`);
        this.render();
      }
    } finally {
      this.inFrame = true;
    }
  }

  // A text-only leaf keeps its box, font and parent's layout adjustments.
  // Native layout will measure its new runs after the props operation; its
  // unchanged row, siblings and ancestors need no JS traversal or diff.
  updateText() {
    if (!this.textOnly || this.full || this.noCache || this.structural || this.marks.size || !this.flatMarks.size || this.pendingScroll) return false;
    for (const el of this.volatile) if (el.isConnected) return false;
    const leaves = new Set();
    for (const n of this.flatMarks) {
      const el = n.nodeType === 3 ? n.parentNode || this.parentOf.get(n) : n;
      if (!el || el.nodeType !== 1 || !el.isConnected) return false;
      leaves.add(el);
    }
    const P = this.host.prof ? this.host.now : null, t0 = P && P();
    const nodes = new Map(), updates = [], restamp = [], restamped = new Set();
    for (const el of leaves) {
      const fc = this.fc.get(el), cs = this.styleOf(el);
      if (!fc) {
        // A child of a row the tree stamps (itself, or as a list's row):
        // the tree reads the new text itself (host.stamp), once per row.
        const row = el.parentNode, rf = row && this.fc.get(row);
        let plan = rf?.stamp, rowId = rf?.id;
        if (!rf) {
          const lf = row?.parentNode && this.fc.get(row.parentNode);
          plan = lf?.list;
          rowId = plan && this.idOf(row, "el");
        }
        if (!plan || !row.isConnected) return false;
        if (!restamped.has(row)) { restamped.add(row); restamp.push(row, rowId, plan); }
        continue;
      }
      if (!fc || !cs || fc.root.kind !== "text" || fc.rootSpec || fc.rootAnim || el.firstElementChild ||
          this.tx.targets.has(fc.id) || this.anim.state.has(fc.id)) return false;
      const old = this.prev.get(fc.id);
      if (!old || old.kind !== "text") return false;
      const child = el.firstChild, ws = cs["white-space"] || "normal";
      let runs;
      if (child?.nodeType === 3 && !child.nextSibling && fc.root.props.runs.length === 1 &&
          ws !== "pre" && ws !== "pre-wrap" && ws !== "pre-line") {
        // The font/paint run is unchanged. Normalize its new string once
        // without recomputing run styles or allocating an inline run flow.
        let t = child.data;
        if (cs["text-transform"] === "uppercase") t = t.toUpperCase();
        else if (cs["text-transform"] === "lowercase") t = t.toLowerCase();
        t = t.replace(/\s+/g, " ").trim();
        // Defer changing the existing owned run until every leaf validates.
        // A string marks this case; no run object/array needs allocating.
        runs = t || null;
      } else {
        const raw = [];
        for (let c = child; c; c = c.nextSibling) {
          if (c.nodeType === 3) raw.push(runFor(c.data, cs, cs.__fs));
          else if (c.nodeType !== 8) return false;
        }
        runs = trimRuns(raw);
      }
      // Empty content can change the native kind and the parent's inline
      // flow. Let the general renderer handle that structural change.
      if (!runs || !runs.length) return false;
      updates.push(el, fc, runs, old);
    }
    for (let i = 0; i < restamp.length; i += 3) {
      const row = restamp[i];
      if (!this.host.stamp(restamp[i + 1], row, restamp[i + 2])) {
        // Its shape changed (more text nodes…): the general way.
        const rf = this.fc.get(row);
        if (rf) { rf.stamp = 0; this.noStamp.add(row); } else this.noStampList.add(row.parentNode);
        return false;
      }
    }
    // Validate every leaf before changing any cached output.
    let direct = 0, nativeMs = 0;
    for (let i = 0; i < updates.length; i += 4) {
      const el = updates[i], fc = updates[i + 1], value = updates[i + 2], old = updates[i + 3];
      const str = typeof value === "string";
      const cur = fc.root.props.runs;
      const single = (str || value.length === 1) && cur.length === 1;
      const a = P && P();
      const sent = single && this.host.text && this.host.text(fc.id, str ? value : value[0].t);
      if (P) nativeMs += P() - a;
      // The run is shared with the last sent props: change it in place only
      // once the native side has the text, else the fallback below would
      // diff equal props and never send it.
      let runs = value;
      if (str) {
        if (sent) { cur[0].t = value; runs = cur; } else runs = [{ ...cur[0], t: value }, ...cur.slice(1)];
      }
      if (sent) {
        // Preserve the target props for a later general diff/transition,
        // but defer their JSON encoding until a traversal needs it.
        const props = old.props || JSON.parse(old.p);
        props.runs = runs;
        old.props = props;
        old.p = null;
        direct++;
      } else {
        const props = old.props ? { ...old.props } : JSON.parse(old.p);
        props.runs = runs;
        nodes.set(fc.id, { kind: "text", props, kids: [] });
      }
      fc.root.props.runs = runs;
      for (let child = el.firstChild; child; child = child.nextSibling) this.parentOf.set(child, el);
    }
    this.frameNo++;
    this.flatMarks.clear();
    this.gone = [];
    this.dropped = [];
    this.specs = new Map();
    this.animSpecs = new Map();
    if (nodes.size) this.emit(nodes, false);
    else { this.applyMs = 0; this.schedule(); }
    if (P) this.host.log(1, `PROF text: ${updates.length / 4} leaves, ${direct} direct, prepare ${(P() - t0 - nativeMs - this.applyMs).toFixed(2)}, apply ${(nativeMs + this.applyMs).toFixed(2)}`);
    return true;
  }

  // An animation loop writing transform or opacity (el.style.transform = …)
  // on boxes with no children: their computed styles change in nothing
  // else, so their node's other props, their layout and their ancestors'
  // output stay as they are. Only those props are made again and only
  // those nodes compared and sent, without flattening the page.
  updateBoxes() {
    if (!this.marks.size || this.flatMarks.size || this.full || this.noCache || this.pendingScroll) return false;
    for (const el of this.volatile) if (el.isConnected) return false;
    const P = this.host.prof ? this.host.now : null, t0 = P && P();
    // Every change first checked, then made: a fallback to renderNow finds
    // the styles and outputs as they were.
    const changes = [];
    for (const [el, level] of this.marks) {
      if (level !== 1 || !el.isConnected || el.firstChild) return false;
      const fc = this.fc.get(el), saved = this.sc.get(el);
      if (!fc || !saved || saved.epoch !== this.styleEpoch || fc.parent !== saved.parent || fc.fixed ||
          fc.own.length !== 1 || fc.kids.length || fc.rootSpec || fc.rootAnim ||
          this.tx.targets.has(fc.id) || this.anim.state.has(fc.id)) return false;
      const old = this.prev.get(fc.id);
      if (!old || old.kind !== fc.root.kind) return false;
      // Its style is its own (an inline style over its rules' shared one)
      // and the inline style set only transform/opacity before and now.
      const d = derived.get(saved.cs);
      if (!d?.parts || !d.parts.every((x) => x === "tr" || x === "op")) return false;
      const normal = paintDecls(el.getAttribute("style"));
      if (!normal) return false;
      changes.push(fc, saved, d, normal, this.cascadeOf(saved.m.normal).important, old);
    }
    const t1 = P && P();
    const nodes = new Map();
    const paintOps = this.host.paintOps ? [] : null;
    // The x channel as numbers where the host takes them (host.paint,
    // Tree.applyPaint): per node [1, id, 5, tx, ty, sc, rot, op], NaN unset.
    const nums = paintOps && this.host.paint ? new Float64Array((changes.length / 6) * 8) : null;
    let at = 0;
    for (let i = 0; i < changes.length; i += 6) {
      const fc = changes[i], saved = changes[i + 1], d = changes[i + 2], normal = changes[i + 3], important = changes[i + 4], old = changes[i + 5];
      // The new values in place: as inlineStyle() would make them (a rule's
      // !important beats the inline declaration), the base's where the
      // inline style no longer sets one.
      const cs = saved.cs, parts = new Set();
      for (const k of PAINT_KEYS) {
        if (k in normal && !(k in important)) { cs[k] = substitute(normal[k], cs, 0); parts.add(PART_OF[k]); }
        else if (d.base[k] !== undefined) cs[k] = d.base[k];
        else delete cs[k];
      }
      d.parts = [...parts];
      saved.frame = this.frameNo + 1;
      // Its own node as made (kept for reuse) and as last sent (with what
      // its parent adjusted: emit compares with that).
      const paint = {};
      transformPart(cs, cs.__fs, paint);
      if (cs.opacity !== undefined && cs.opacity !== "1") paint.op = parseFloat(cs.opacity);
      const part = (p) => {
        for (const k of PAINT_PROPS) delete p[k];
        return Object.assign(p, paint);
      };
      // In place: the node as made is this element's own copy (renderNow),
      // and so are the props as sent once this path has sent them (p null);
      // before that they may be emit's, copied once.
      const r = fc.root;
      part(r.props);
      const sent = part(old.p === null && old.props ? old.props : old.props ? { ...old.props } : JSON.parse(old.p));
      if (paintOps) {
        // Just the transform and opacity (the "x" op); the props kept
        // unencoded (a later diff encodes them if it needs to).
        if (nums) {
          nums[at] = 1; nums[at + 1] = fc.id; nums[at + 2] = 5;
          nums[at + 3] = sent.tx ?? NaN; nums[at + 4] = sent.ty ?? NaN; nums[at + 5] = sent.sc ?? NaN;
          nums[at + 6] = sent.rot ?? NaN; nums[at + 7] = sent.op ?? NaN;
          at += 8;
        } else {
          const n = (v) => (v === undefined ? "null" : v);
          paintOps.push(`["x",${fc.id},${n(sent.tx)},${n(sent.ty)},${n(sent.sc)},${n(sent.rot)},${n(sent.op)}]`);
        }
        if (old.p === null && old.props === sent) {} else this.prev.set(fc.id, { kind: old.kind, p: null, props: sent, k: old.k });
      } else nodes.set(fc.id, { kind: r.kind, props: sent, kids: r.kids.slice() });
    }
    const t2 = P && P();
    this.frameNo++;
    this.marks.clear();
    this.textOnly = true;
    this.gone = [];
    this.dropped = [];
    this.specs = new Map();
    this.animSpecs = new Map();
    if (paintOps) {
      this.applyMs = 0;
      const a = P && P();
      if (nums) { if (at) this.host.paint(at === nums.length ? nums : nums.subarray(0, at)); }
      else if (paintOps.length) this.host.ops(`[${paintOps.join(",")}]`);
      if (P) this.applyMs = P() - a;
      this.schedule();
    } else {
      this.emit(nodes, false);
      // The props as sent, beside their JSON: the next frame of the loop
      // starts from them without parsing it.
      for (const [id, n] of nodes) { const e = this.prev.get(id); if (e && e.p !== null) e.props = n.props; }
    }
    if (P) this.host.log(1, `PROF boxes: ${nums ? at / 8 : paintOps ? paintOps.length : nodes.size} nodes, prepare ${(P() - t0 - this.applyMs).toFixed(2)}, apply ${this.applyMs.toFixed(2)}, check ${(t1 - t0).toFixed(2)}, props ${(t2 - t1).toFixed(2)}`);
    return true;
  }

  renderNow() {
    // The nodes made (or copied) this frame, id → { kind, props, kids }:
    // what emit() compares with the last frame. Reused subtrees aren't in it.
    const nodes = new Map();
    this.specs = new Map();
    this.animSpecs = new Map();
    this.frameNo++;
    this.gone = [];
    this.dropped = [];
    const full = this.full || this.noCache;
    // Sharing ids, their matches and the row shapes stay while the styles
    // do (bounded: a page making ever new ancestries starts over).
    if (full || this.keyIds.size > 50000) {
      this.keyIds.clear();
      this.matchShare.clear();
      this.flexLeaves = internalWeak(new WeakMap());
    }
    // Compiled :has() matchers also cache descendant results. A new DOM
    // needs a new matcher, as well as new computed/flattened styles.
    if (this.noCache) for (const r of this.engine.rules) if (/:has\(/.test(r.sel)) r.match = null;
    if (full) {
      this.styleEpoch++;
      this.fc = internalWeak(new WeakMap());
      this.shared = internalWeak(new WeakMap());
      this.cascades.clear();
      this.owner.clear();
    }
    // What has to be made again: the marked nodes and every ancestor (an
    // element whose children changed lays them out again).
    const flat = (this.flat = new Set());
    const up = (n) => { for (; n && !flat.has(n); n = n.parentNode) flat.add(n); };
    for (const el of this.marks.keys()) up(el);
    for (const n of this.flatMarks) up(n);
    for (const el of this.volatile) { if (el.isConnected) up(el); else this.volatile.delete(el); }
    const body = this.doc.body;
    const rootCS = this.style(this.doc.documentElement, null);
    this.cur = { own: [], kids: [], fixed: [] };
    // -Dnative_ui_prof (src/native_ui/prof.zig): each render's stages.
    const P = this.host.prof ? this.host.now : null;
    const t0 = P && P();
    // (rootBody: body is the root's flex item here, but a block in a
    // browser's flow: its margins collapse with its first and last child's.)
    const bodyNode = this.element(body, rootCS, nodes, { blockify: true, textAlign: "left", rootBody: true });
    const fixed = this.cur.fixed;
    this.cur = null;
    this.marks.clear();
    this.flatMarks.clear();
    this.textOnly = true;
    this.full = false;
    // What the changed elements no longer make (or elements gone from the
    // page): destroyed, unless made again elsewhere this frame (moved).
    const goneTree = (el, f) => {
      this.gone.push(...f.own);
      this.fc.delete(el);
      // Its style too: the element may be rendered again later (a list's
      // row the tree stamps meanwhile, which JS doesn't see restyled).
      this.sc.delete(el);
      for (const k of f.kids) {
        const kf = this.fc.get(k);
        if (kf && kf.seen !== this.frameNo) goneTree(k, kf);
      }
    };
    for (const [el, f] of this.dropped) {
      const now = this.fc.get(el);
      if (now && now.seen === this.frameNo) continue;
      goneTree(el, now || f);
    }
    if (!bodyNode) return;
    // The page keeps its height in the window's scroll view (see above).
    const bn = nodes.get(bodyNode);
    if (bn && !this.styleOf(body)?.["flex-shrink"]) bn.props.fs = 0;
    // The window: the page scrolls, fixed elements stay over it.
    const winProps = { scroll: true, fg: 1, fs: 1, ai: "stretch" };
    // The window's scrollbar: <html>'s (or <body>'s) overflow and style.
    const bodyCS = this.styleOf(body);
    scrollbarPart({ ...(bodyCS || {}), ...rootCS, "overflow-y": rootCS["overflow-y"] || bodyCS?.["overflow-y"] }, winProps, true);
    // overflow: hidden on <html> (or <body>'s, which goes to the window when
    // <html>'s is visible): no scrollbar.
    const rootOv = rootCS["overflow-y"] || rootCS.overflow;
    const usedOv = rootOv && rootOv !== "visible" ? rootOv : (bodyCS?.["overflow-y"] || bodyCS?.overflow);
    if (usedOv === "hidden" || usedOv === "clip") { winProps.sbw = "none"; delete winProps.sbs; }
    nodes.set(-1, { kind: "view", props: winProps, kids: [bodyNode] });
    // The window's background: <html>'s, else <body>'s (a browser paints the
    // whole viewport with it, below a short page too).
    const rootBg = bgOf(rootCS) || (this.styleOf(body) ? bgOf(this.styleOf(body)) : null);
    nodes.set(0, { kind: "view", props: { root: true, fd: "column", ai: "stretch", bg: rootBg }, kids: [-1, ...fixed] });
    const t1 = P && P();
    this.emit(nodes, full);
    if (P) {
      const ms = (x) => x.toFixed(2);
      this.host.log(1, `PROF render ${full ? "full" : "incremental"}: ${nodes.size} nodes made, flatten ${ms(t1 - t0)}, emit ${ms(P() - t1 - this.applyMs)}, apply ${ms(this.applyMs)}`);
    }
    // A scrollIntoView that waited for this render (main.js).
    const scroll = this.pendingScroll;
    this.pendingScroll = null;
    if (scroll && scroll.el.isConnected) this.host.scrollIntoView(this.idOf(scroll.el, "el"), scroll.block);
  }

  // An element's computed style: the last frame's while neither it nor its
  // parent's style changed. `rematch`: an ancestor's attributes changed (a
  // descendant selector may match differently).
  style(el, parentCS, rematch = false) {
    const saved = this.sc.get(el);
    const c = saved?.epoch === this.styleEpoch ? saved : null;
    const mk = this.marks.get(el) || 0;
    if (c && c.parent === parentCS && (c.frame === this.frameNo || (!rematch && !mk))) return c.cs;
    // Its rules again: its attributes changed (1.5: a state, 2), or an
    // ancestor's did; an inline style alone (1) keeps them.
    const m = c && !rematch && mk < 1.5 ? c.m : this.matchOf(el);
    const inline = el.getAttribute("style");
    const casc = this.cascadeOf(m.normal);
    let cs;
    if (inline) cs = this.inlineStyle(inline, casc, m, parentCS);
    else if (parentCS && !m.before.length && !m.after.length) {
      // Siblings with the same rules under the same parent: one style.
      let by = this.shared.get(parentCS);
      if (!by) this.shared.set(parentCS, (by = new Map()));
      cs = by.get(casc.spec);
      if (!cs) { cs = computeStyle(casc.spec, parentCS); by.set(casc.spec, cs); }
    } else {
      cs = computeStyle(casc.spec, parentCS);
    }
    // The same values as before: the same object, so what's below can
    // still be reused.
    // Equal CSS strings can resolve to a different size under a changed
    // parent (em/%/inherited relative sizes). Keep style identity only when
    // its previously resolved font size is also unchanged.
    if (c && c.cs !== cs && sameStyle(c.cs, cs) && c.cs.__fs === fontSizeOf(cs, parentCS)) cs = c.cs;
    cs.__rules = m;
    this.sc.set(el, { parent: parentCS, cs, m, frame: this.frameNo, epoch: this.styleEpoch });
    return cs;
  }

  // An element with an inline style: its rules' style (shared with its
  // siblings) with the inline longhands over it, as computeStyle would put
  // them; custom properties (var() everywhere below) take the long way.
  inlineStyle(inline, casc, m, parentCS) {
    const normal = {}, important = {};
    StyleEngine.expandInto(parseInline(inline), normal, important);
    let simple = !!parentCS && !m.before.length && !m.after.length;
    if (simple) for (const k in normal) if (k.startsWith("--")) { simple = false; break; }
    if (simple) for (const k in important) if (k.startsWith("--")) { simple = false; break; }
    if (!simple) {
      const spec = Object.assign({ ...casc.normal }, normal, casc.important, important);
      return computeStyle(spec, parentCS);
    }
    let by = this.shared.get(parentCS);
    if (!by) this.shared.set(parentCS, (by = new Map()));
    let base = by.get(casc.spec);
    if (!base) { base = computeStyle(casc.spec, parentCS); by.set(casc.spec, base); }
    const cs = Object.assign(Object.create(null), base);
    let parts = new Set();
    const put = (k, v) => {
      if (parts && PART_OF[k]) parts.add(PART_OF[k]); else parts = null;
      if (v === "inherit") { if (parentCS[k] !== undefined) cs[k] = parentCS[k]; else delete cs[k]; return; }
      if (v === "initial" || v === "unset") { delete cs[k]; return; }
      cs[k] = substitute(v, cs, 0);
    };
    // A rule's !important beats an inline declaration that isn't.
    for (const k in normal) if (!(k in casc.important)) put(k, normal[k]);
    for (const k in important) put(k, important[k]);
    // An inline width: max-content changes how its text wraps too.
    const mc = maxContent(cs, parentCS);
    const fc = !mc && fitContent(cs, parentCS);
    if (mc !== !!base.__maxc || fc !== !!base.__fitc) parts = null;
    if (mc) cs.__maxc = true; else delete cs.__maxc;
    if (fc) cs.__fitc = true; else delete cs.__fitc;
    derived.set(cs, { base, parts: parts && [...parts] });
    return cs;
  }

  // Matched rules, shared within a frame by elements that selectors can't
  // tell apart: the same tag and class, no other attributes, under parents
  // that share too (or the same parent). A browser's style sharing; off
  // when the sheets match by position (:nth-child, +, ~…).
  matchOf(el) {
    const k = this.structural || this.noCache ? 0 : this.shareKey(el);
    if (k <= 0) return this.engine.matching(el);
    let m = this.matchShare.get(k);
    if (!m) this.matchShare.set(k, (m = this.engine.matching(el)));
    return m;
  }

  // An element's sharing key this frame: > 0 when shareable, else minus
  // its id (still a key for its children).
  shareKey(el) {
    if (this.keyFrame !== this.frameNo) {
      this.keyFrame = this.frameNo;
      this.keys = internalWeak(new WeakMap());
    }
    let k = this.keys.get(el);
    if (k !== undefined) return k;
    const parent = el.parentNode;
    let ok = !!parent && parent.nodeType === 1;
    let cls = "";
    if (ok) {
      const cs = classStyle(el, !this.styleAttrRules);
      if (cs) cls = cs[0] ?? ""; else ok = false;
    }
    if (ok) {
      const name = `${this.shareKey(parent)}|${el.localName}|${cls}`;
      k = this.keyIds.get(name);
      if (k === undefined) this.keyIds.set(name, (k = this.keyIds.size + 1));
    } else {
      // Not shareable (an id, another attribute, the root): its own id,
      // never reused (a node id's store index is, after the node goes),
      // after its parent's key, so what's below it matches again when it
      // or anything above it changes. Negative: matched on its own.
      let u = this.uids.get(el);
      if (!u) this.uids.set(el, (u = ++this.uidSeq));
      const name = `${parent?.nodeType === 1 ? this.shareKey(parent) : 0}|u${u}`;
      k = this.keyIds.get(name);
      if (k === undefined) this.keyIds.set(name, (k = this.keyIds.size + 1));
      k = -k;
    }
    this.keys.set(el, k);
    return k;
  }

  // The longhands of a set of matched rules (many elements match the same).
  cascadeOf(rules) {
    let key = "";
    for (const r of rules) key += r.order + ",";
    let c = this.cascades.get(key);
    if (!c) {
      const sorted = StyleEngine.sorted(rules);
      const normal = {}, important = {};
      StyleEngine.expandInto(sorted.flatMap((r) => r.decls), normal, important);
      c = { normal, important, spec: Object.assign({ ...normal }, important) };
      if (this.cascades.size > 5000) this.cascades.clear();
      this.cascades.set(key, c);
    }
    return c;
  }

  // ---------------------------------------------------------------------
  // What the element being made makes (element(), below).

  // A node made by the element being made.
  put0(nodes, id, node) {
    nodes.set(id, node);
    this.cur.own.push(id);
  }

  own(id, el) {
    // An element's own node finds it from its id (elementFor).
    if (id < NATIVE_ID_BASE || !nodeAt) this.owner.set(id, el);
  }

  spec(id, s) {
    this.specs.set(id, s);
  }

  // An element → a node id (or null when not rendered or fixed).
  //
  // What it made is kept (`fc`): its parent's style, its blockification and
  // table spacing, the ids it made itself (its node, text runs,
  // pseudo-elements, grid rows), the child elements that made nodes, the
  // fixed ids in it, and a copy of its own node as made (its parent adjusts
  // the one it gets). While
  // nothing in it changed (not in `flat`, no ancestor's rules matched
  // again) and its parent's style is the same object, it is reused whole:
  // its nodes stay as they are, only its own node is compared again.
  element(el, parentCS, nodes, ctx) {
    const fc = this.fc.get(el);
    const block = !!ctx.blockify;
    const outer = this.cur;
    // Reused while nothing in it changed, or when made already this frame
    // (listOf made a list's first row before its parent's general loop).
    if (fc && fc.parent === parentCS && fc.block === block && fc.ts === ctx.tableSpacing && !ctx.rematch &&
        (!this.flat.has(el) || fc.seen === this.frameNo)) {
      fc.seen = this.frameNo;
      const r = fc.root;
      nodes.set(fc.id, { kind: r.kind, props: { ...r.props }, kids: r.kids.slice() });
      if (fc.rootSpec) this.specs.set(fc.id, fc.rootSpec);
      if (fc.rootAnim) this.animSpecs.set(fc.id, fc.rootAnim);
      outer.kids.push(el);
      for (const f of fc.fixedIds) outer.fixed.push(f);
      return fc.fixed ? null : fc.id;
    }
    const cur = (this.cur = { own: [], kids: [], fixed: [] });
    let out;
    try { out = this.build(el, parentCS, nodes, ctx); } finally { this.cur = outer; }
    const id = this.idOf(el, "el");
    const own = cur.own.includes(id) ? nodes.get(id) : null;
    if (!own) {
      // Not rendered now: what it made before goes.
      if (fc) { this.fc.delete(el); this.dropped.push([el, fc]); }
      return out;
    }
    const nf = {
      parent: parentCS, block, ts: ctx.tableSpacing, id, fixed: out === null, own: cur.own, kids: cur.kids, fixedIds: cur.fixed, seen: this.frameNo,
      root: { kind: own.kind, props: { ...own.props }, kids: own.kids.slice() },
      rootSpec: this.specs.get(id), rootAnim: this.animSpecs.get(id),
      stamp: cur.stamp, // a row whose children the tree stamps (its plan)
      list: cur.list,   // a list whose rows after the first the tree stamps (their plan)
    };
    if (fc) {
      // Ids it made before and not now; child elements it no longer has.
      if (fc.own.length) {
        const now = new Set(cur.own);
        for (const x of fc.own) if (!now.has(x)) this.gone.push(x);
      }
      if (fc.kids.length) {
        const now = new Set(cur.kids);
        for (const k of fc.kids) if (!now.has(k)) { const kf = this.fc.get(k); if (kf) this.dropped.push([k, kf]); }
      }
    }
    this.fc.set(el, nf);
    outer.kids.push(el);
    for (const f of cur.fixed) outer.fixed.push(f);
    return out;
  }

  // An element → a node id (or null when not rendered).
  keepsContentHeight(el, n) {
    if (!n || (n.kind !== "view" && n.kind !== "text")) return false;
    const p = n.props, cs = this.styleOf(el) || {};
    return p.fs === undefined && p.h === undefined && p.fb === undefined && p.ar === undefined && !p.scroll && !p.clip &&
      !cs["flex-shrink"] && !cs["min-height"] && p.pos !== "absolute";
  }

  // A new flex row with ordinary leaves can reuse the CSS/layout setup of
  // an equivalent row. Attributes that selectors distinguish, positional
  // rules, inline aggregation, controls and existing rows stay general.
  flexShape(el, cs, props, force = false) {
    if (!this.simpleLeaves || this.structural || this.noCache || (!force && this.fc.has(el) && !this.fc.get(el).stamp) ||
        props.fd !== "row" || props.scroll || props.scrollx ||
        cs.__rules.before.length || cs.__rules.after.length) return null;
    const share = this.shareKey(el);
    if (share <= 0) return null;
    const children = [];
    // Sharing ids identify the complete selector ancestry (shareKey).
    // Identical parent styles alone do not imply identical matches.
    let key = `${share}|`;
    for (let child = el.firstChild; child; child = child.nextSibling) {
      if (child.nodeType === 8) continue;
      if (child.nodeType !== 1 || !TEMPLATE_LEAF.has(child.localName) || child.firstElementChild) return null;
      const cs = classStyle(child, true);
      if (!cs) return null;
      const cls = cs[0] ?? "", inline = cs[1] ?? "";
      const tag = child.localName;
      key += `${tag.length}:${tag}${cls.length}:${cls}${inline.length}:${inline}`;
      children.push(child);
      if (children.length > 16) return null;
    }
    if (!children.length) return null;
    let shapes = this.flexLeaves.get(cs);
    if (!shapes) this.flexLeaves.set(cs, (shapes = new Map()));
    return { children, key, shapes, plan: shapes.get(key) };
  }

  // Whether the tree can stamp this row's children: each a leaf with no
  // click of its own, empty or one text node, its white space collapsed
  // (dom_stamp.zig makes the same text as useFlexShape).
  stampable(shape) {
    const entries = shape.plan.entries;
    for (let i = 0; i < shape.children.length; i++) {
      const el = shape.children[i];
      if (el.localName === "label" || listens(el)) return false;
      const c = el.firstChild;
      if (c && (c.nodeType !== 3 || c.nextSibling)) return false;
      const ws = entries[i].cs["white-space"];
      if (ws === "pre" || ws === "pre-wrap" || ws === "pre-line") return false;
    }
    return true;
  }

  // A row plan's id in the tree (host.stampPlan): each child's leaf
  // styles, as useFlexShape's templates make them, its text-transform, and
  // the laid-out order. 0 when the tree won't keep it.
  stampPlanOf(plan) {
    if (plan.stamp !== undefined) return plan.stamp;
    const v = [plan.entries.length];
    let ok = true;
    for (const e of plan.entries) {
      const text = this.leafStyleId(encodeProps({ ...e.textBox, runs: [{ t: "", ...e.run }] }));
      const view = this.leafStyleId(encodeProps({ ...e.box }));
      if (!text || !view) ok = false;
      const tt = e.cs["text-transform"];
      v.push(text, view, tt === "uppercase" ? 1 : tt === "lowercase" ? 2 : 0);
    }
    v.push(...plan.order);
    return (plan.stamp = ok ? this.host.stampPlan(v) : 0);
  }

  // A leaf style's id in the tree for these props (host.leafStyle), made
  // once; 0 past the bounds.
  leafStyleId(json) {
    let style = this.leafStyles.get(json);
    if (style !== undefined) return style;
    if (this.leafStyles.size >= 1024 || this.leafStyleBytes + json.length > 2 * 1024 * 1024) return 0;
    style = this.leafStyles.size + 1;
    if (!this.host.leafStyle(style, json)) style = 0;
    this.leafStyles.set(json, style);
    this.leafStyleBytes += json.length;
    return style;
  }

  useFlexShape(shape, cs, nodes, spacing) {
    const ids = [];
    for (let i = 0; i < shape.children.length; i++) {
      const el = shape.children[i], entry = shape.plan.entries[i], childCS = entry.cs;
      const id = this.idOf(el, "el");
      this.own(id, el);
      const child = el.firstChild, ws = childCS["white-space"];
      let runs;
      if (!child) runs = [];
      else if (child.nodeType === 3 && !child.nextSibling &&
          ws !== "pre" && ws !== "pre-wrap" && ws !== "pre-line") {
        this.parentOf.set(child, el);
        let t = child.data;
        if (childCS["text-transform"] === "uppercase") t = t.toUpperCase();
        else if (childCS["text-transform"] === "lowercase") t = t.toLowerCase();
        t = t.replace(/\s+/g, " ").trim();
        runs = t ? [entry.simpleRun
          ? { t, c: entry.run.c, sz: entry.run.sz, w: entry.run.w }
          : { t, ...entry.run }] : [];
      } else {
        const raw = [];
        for (let c = child; c; c = c.nextSibling) {
          this.parentOf.set(c, el);
          if (c.nodeType === 3 && c.data) raw.push(runFor(c.data, childCS, childCS.__fs));
        }
        runs = trimRuns(raw);
      }
      const kind = runs.length ? "text" : "view";
      const props = { ...(runs.length ? entry.textBox : entry.box) };
      if (runs.length) props.runs = runs;
      // flexShape accepted only class/style attributes and ordinary tags.
      // Labels and listeners are the remaining element-specific click state.
      if (el.localName === "label" || listens(el)) props.click = true;
      let template;
      if (!props.click && (kind === "view" || runs.length === 1)) {
        const key = kind === "text" ? "nativeText" : "nativeView";
        template = entry[key];
        if (!template) {
          const base = { ...props };
          if (kind === "text") base.runs = [{ ...runs[0], t: "" }];
          template = entry[key] = { json: encodeProps(base) };
        }
      }
      // A direct flex leaf has no parent-side layout adjustments. Keep
      // one output record as its snapshot, with shared immutable empties.
      // General reuse still copies props before a new parent can adjust it.
      const node = { kind, props, kids: EMPTY, template };
      nodes.set(id, node);
      // Style and flattening snapshots have the same parent here. Style
      // updates replace their record, so sharing cannot alter this snapshot.
      const cached = {
        parent: cs, cs: childCS, m: entry.m, frame: this.frameNo, epoch: this.styleEpoch,
        block: true, ts: spacing, id, fixed: false, own: [id], kids: EMPTY, fixedIds: EMPTY, seen: this.frameNo,
        root: node, rootSpec: undefined, rootAnim: undefined,
      };
      this.sc.set(el, cached);
      this.fc.set(el, cached);
      this.cur.kids.push(el);
      ids.push(id);
    }
    for (let child = shape.children[0].parentNode.firstChild; child; child = child.nextSibling) this.parentOf.set(child, child.parentNode);
    return shape.plan.order.map((i) => ids[i]);
  }

  saveFlexShape(shape, nodes) {
    const entries = [];
    for (const el of shape.children) {
      const sc = this.sc.get(el), fc = this.fc.get(el), n = fc && nodes.get(fc.id);
      if (!sc || !fc || !n || n.kids.length || !["text", "view"].includes(n.kind) || fc.fixed ||
          fc.rootSpec || fc.rootAnim || this.volatile.has(el) ||
          !["inline", "block", "inline-block"].includes(sc.cs.display || "inline") ||
          sc.cs.__rules.before.length || sc.cs.__rules.after.length) return;
      const fs = sc.cs.__fs;
      const box = boxProps(sc.cs, blockify(sc.cs.display || "inline"), fs, el);
      const run = runStyle(sc.cs, fs);
      // Merge immutable layout/font setup once per shape. Every leaf still
      // gets its own property object and text run.
      entries.push({ cs: sc.cs, m: sc.m, box, textBox: { ...box, ...textProps(sc.cs, fs) }, run, simpleRun: Object.keys(run).length === 3, order: parseInt(sc.cs.order, 10) || 0 });
    }
    const order = entries.map((_, i) => i).sort((a, b) => entries[a].order - entries[b].order || a - b);
    if (shape.shapes.size >= 32) shape.shapes.delete(shape.shapes.keys().next().value);
    const plan = { entries, order };
    shape.shapes.set(shape.key, plan);
    // A list's first row, made the general way before its shape was known:
    // listOf stamps the rest of the list with it at once.
    this.savedShape = { row: shape.children[0].parentNode, children: shape.children, plan };
  }

  build(el, parentCS, nodes, ctx) {
    const tag = el.localName;
    if (SKIP.has(tag)) return null;
    const rematch = !!ctx.rematch || this.marks.get(el) === 2;
    const cs = this.style(el, parentCS, !!ctx.rematch);
    let display = cs.display || "inline";
    if (display === "none") return null;
    if (ctx.blockify) display = blockify(display);
    const fontSize = fontSizeOf(cs, parentCS);
    cs.__fs = fontSize;
    const id = this.idOf(el, "el");
    this.own(id, el);
    const props = boxProps(cs, display, fontSize, el);
    // align-self applies to flex and grid items only: in a block it does
    // nothing (the box fills the line). Inline boxes get theirs below.
    if (!ctx.blockify) delete props.as;
    // A form control or button without a width keeps its own in a block
    // (display: block doesn't stretch it to the line, as it does a div); a
    // flex item still stretches.
    if (!ctx.blockify && display === "block" && CONTROLS.has(tag) && (props.w === undefined || props.w === "auto")) props.as = "flex-start";
    if (isTableDisplay(display) && !tableProps(props, display, cs, fontSize, ctx, el)) return null;
    const transitions = transitionsOf(cs);
    if (transitions) this.spec(id, transitions);
    this.noteAnimations(id, cs, fontSize);
    // A block with auto side margins fills its container (up to max-width)
    // and is centered, where a flex item would shrink to its content.
    const intrinsic = INTRINSIC_WIDTHS.has(cs.width) && props.w === undefined;
    if (!ctx.blockify && !intrinsic && ["block", "flex", "grid", "list-item"].includes(blockify(display)) && props.w === undefined && props.pos !== "absolute" &&
        cs["margin-left"] === "auto" && cs["margin-right"] === "auto") props.w = "100%";
    // width: max-content or fit-content: as wide as its content, not its
    // container (fit-content still wraps within it). Yoga sizes a box that
    // isn't stretched so: in a block or a flex column it isn't stretched
    // (auto side margins still center it). A flex row's item already
    // starts from its content (and shrinks, as in browsers).
    if (intrinsic && props.pos !== "absolute" && !props.as &&
        !(ctx.blockify && !/^column/.test(parentCS?.["flex-direction"] || "row"))) props.as = "flex-start";

    // Position: fixed → in the window's overlay layer.
    let fixedNode = false;
    if (cs.position === "fixed") { props.pos = "absolute"; fixedNode = true; }

    // Replaced elements.
    if (tag === "svg") {
      // <use href="#id"> draws another element: it can change elsewhere.
      if (el.querySelector("use")) this.volatile.add(el);
      const icon = iconFor(el, cs, this.doc, (file) => this.svgFile(file));
      if (!icon) return null;
      props.icon = icon;
      // width/height attributes size the icon when CSS doesn't (presentational
      // hints, as in a browser): <svg width="16" height="16">.
      for (const [k, a] of [["w", "width"], ["h", "height"]]) {
        const v = el.getAttribute(a);
        if (props[k] === undefined && v && /^[\d.]+(px)?$/.test(v.trim())) props[k] = parseFloat(v);
      }
      return this.put(nodes, id, "icon", props, [], fixedNode);
    }
    if (tag === "img") {
      const src = el.getAttribute("src") || "";
      if (!src) return null;
      // An SVG picture (a framework's logo): drawn as an icon, the
      // backends' images being bitmaps.
      const svg = /^data:image\/svg\+xml/.test(src) || /\.svg([?#]|$)/i.test(src) ? this.svgFile(src) : null;
      const icon = svg && iconFor(svg.svg, { color: "black" }, svg, (file) => this.svgFile(file), { image: true });
      if (icon) {
        props.icon = icon;
        for (const k of ["w", "h"]) if (props[k] === "auto") delete props[k];
        for (const [k, a] of [["w", "width"], ["h", "height"]]) {
          const v = el.getAttribute(a);
          if (props[k] === undefined && v && /^[\d.]+(px)?$/.test(v.trim())) props[k] = parseFloat(v);
        }
        // Its own size, or its ratio when CSS sets one side.
        const size = svgSize(svg.svg, icon.vb);
        if (props.w === undefined && props.h === undefined) { props.w = size.w; props.h = size.h; }
        else if ((props.w === undefined || props.h === undefined) && size.ratio) props.ar = size.ratio;
        return this.put(nodes, id, "icon", props, [], fixedNode);
      }
      props.src = src.startsWith("data:") ? src : src.replace(/^(app:\/\/[^/]*)?\.?\//, "");
      if (cs["object-fit"] && cs["object-fit"] !== "fill") props.fit = cs["object-fit"];
      // width/height attributes size it when CSS doesn't (else its natural size).
      for (const [k, a] of [["w", "width"], ["h", "height"]]) {
        const v = el.getAttribute(a);
        if (props[k] === undefined && v && /^[\d.]+(px)?$/.test(v.trim())) props[k] = parseFloat(v);
      }
      return this.put(nodes, id, "image", props, [], fixedNode);
    }
    if (tag === "canvas") {
      // Its program changes without a mutation: sent apart from the props
      // when the backend takes it so (host.canvas, after emit), else made
      // again with them every render.
      if (this.host.canvasOps) this.canvasEls.set(el, id);
      else this.volatile.add(el);
      // The bitmap's size in px (300x150 when the attributes are absent),
      // the drawing's coordinate space; the box scales it.
      props.cw = el.width;
      props.ch = el.height;
      // Its id attribute: what the app's Zig code opens it by (canvas.zig).
      if (el.id) props.eid = el.id;
      // Size: CSS width and height, else the attributes', else the
      // browser's 300x150. One CSS size set: the bitmap's ratio decides
      // the other, as a browser keeps the bitmap's intrinsic ratio.
      // With no CSS size, a column flex parent that stretches (the default)
      // gives it its width and the bitmap's ratio its height; elsewhere it
      // is the bitmap's size. Like any replaced element it doesn't shrink
      // below that in a flex column (CSS min-size: auto).
      const ratio = props.ch > 0 ? props.cw / props.ch : 2;
      const stretched = ctx.blockify && /^column/.test(parentCS?.["flex-direction"] || "") &&
        ["stretch", "normal", undefined].includes(cs["align-self"] && cs["align-self"] !== "auto" ? cs["align-self"] : parentCS?.["align-items"]);
      if (props.w === undefined && props.h === undefined) {
        if (stretched) props.ar = ratio;
        else if (narrowable(props, cs, parentCS)) {
          // A block in a block with a max-width (`max-width: 100%`): the
          // parent's stretch gives its width, capped at the bitmap's, and its
          // ratio the height, capped to match. Yoga takes the ratio from a
          // width before it clamps that width (a set width or a stretched
          // one), so the height cap is what keeps the shape: on a narrow
          // screen it's the stretched width's, on a wide one the cap's.
          const cap = typeof props.maxw === "number" ? Math.min(props.maxw, props.cw) : props.cw;
          props.maxw = cap;
          props.maxh = cap / ratio;
          props.ar = ratio;
        } else { props.w = props.cw; props.h = props.ch; }
      } else if (props.w === undefined || props.h === undefined) props.ar = ratio;
      props.fs = 0;
      // The drawing program so far (a game's last frame; static drawing
      // accumulates). Its children are the fallback content: not shown.
      if (!this.host.canvasOps) {
        const cv = commandsOf(el);
        if (cv.length) props.cv = cv;
      }
      this.putClick(props, el);
      return this.put(nodes, id, "canvas", props, [], fixedNode);
    }
    if (tag === "input" || tag === "textarea" || tag === "select") {
      this.volatile.add(el); // its value changes without a mutation
      const type = (el.getAttribute("type") || "text").toLowerCase();
      // Its accessible name, for the native control (VoiceOver, Narrator…).
      const al = accessibleName(el);
      if (al) props.al = al;
      // macOS: a select is AppKit's pop-up button, as WKWebView draws it,
      // which takes no CSS padding (measured: 55x18 with padding: 4px too).
      if (tag === "select" && pushButtons && (cs.appearance || cs["-webkit-appearance"]) !== "none") delete props.pad;
      if (tag === "input" && (type === "checkbox" || type === "radio")) {
        // The click goes to the label. With appearance: none the page's CSS
        // draws it; else the native side draws the default control, in the
        // browser's 13px box (its margin: UA_CSS), in accent-color when checked.
        props.click = true;
        const app = cs.appearance || cs["-webkit-appearance"];
        if (app !== "none") {
          props.ctl = type;
          // WebKit's on macOS: its baseline 2px over its bottom (measured:
          // a 12px box in a 14px system-ui line, its top 4px down, the
          // line 19px with its 3px margins).
          if (pushButtons) props.blb = 2;
          if (el.hasAttribute("checked")) props.on = true;
          const acc = color(cs["accent-color"] || "");
          if (acc) props.acc = acc;
          if (props.w === undefined || props.w === "auto") props.w = 13;
          if (props.h === undefined || props.h === "auto") props.h = 13;
          delete props.pad; delete props.bw; delete props.bc; delete props.bg; delete props.br;
        }
        return this.put(nodes, id, "view", props, [], fixedNode);
      }
      Object.assign(props, textProps(cs, fontSize));
      if (tag === "select") {
        props.options = [...el.querySelectorAll("option")].map((o) => [o.getAttribute("value") ?? o.textContent, o.textContent]);
        props.val = el.value ?? "";
        props.dis = el.hasAttribute("disabled");
        return this.put(nodes, id, "select", props, [], fixedNode);
      }
      // The value goes to the native field only when the page changed it
      // (never back over what the user is typing).
      const value = el.value ?? "";
      if (this.native.get(id) !== value) props.val = value;
      props.ph = el.getAttribute("placeholder") || "";
      props.dis = el.hasAttribute("disabled");
      // readonly: selectable, not editable (a disabled field is neither).
      if (el.hasAttribute("readonly") && !props.dis) props.ro = true;
      props.pw = type === "password";
      if (tag === "textarea") {
        const cols = parseInt(el.getAttribute("cols") || "", 10);
        props.cols = cols > 0 ? Math.min(cols, 1000) : 20;
        const rows = parseInt(el.getAttribute("rows") || "", 10);
        props.rows = rows > 0 ? Math.min(rows, 1000) : 2;
      } else if (type !== "range") {
        // A text field is `size` characters wide (20 when absent).
        const size = parseInt(el.getAttribute("size") || "", 10);
        props.cols = size > 0 ? Math.min(size, 1000) : 20;
      }
      // A slider: the native side draws one (SeekBar), the value as text,
      // in Chromium's 129x16 box (its 2px margin: UA_CSS).
      if (type === "range") {
        const n = (a, d) => { const v = parseFloat(el.getAttribute(a)); return Number.isFinite(v) ? v : d; };
        props.range = [n("min", 0), n("max", 100), el.getAttribute("step") === "any" ? 0 : n("step", 1)];
        if (props.w === undefined || props.w === "auto") props.w = 129;
        if (props.h === undefined || props.h === "auto") props.h = 16;
        const acc = color(cs["accent-color"] || "");
        if (acc) props.acc = acc;
        delete props.pad; delete props.bw; delete props.bc; delete props.bg; delete props.br;
      }
      return this.put(nodes, id, tag === "textarea" ? "textarea" : "input", props, [], fixedNode);
    }

    // Plain leaves need no inline-flow objects, pseudo nodes or child-layout
    // contexts. This also covers empty decorative elements in large lists.
    const layoutBox = display === "flex" || display === "grid" || display === "inline-flex" || display === "inline-grid";
    const aligns = (layoutBox &&
      (["center", "end", "flex-end"].includes(cs["align-items"]) || ["center", "end", "flex-end", "space-around", "space-evenly"].includes(cs["justify-content"]))) ||
      // A button centers its label in its height (a row stretches it to
      // its tallest sibling's): a box around the text, not a text view.
      (el.localName === "button" && !layoutBox);
    // A scroller or a clipping box keeps its box (a text view neither
    // scrolls, clips nor keeps scrollbar room): its text goes in a child.
    // A list item's marker sits beside its box: it keeps its box too.
    const marker = display === "list-item" ? listMarker(el, cs) : null;
    const keepsBox = props.scroll || props.scrollx || props.clip || !!marker;
    if (this.simpleLeaves && !el.firstElementChild && !cs.__rules.before.length && !cs.__rules.after.length && !aligns && !keepsBox &&
        display !== "grid" && !isTableDisplay(display)) {
      const raw = [];
      for (let child = el.firstChild; child; child = child.nextSibling) {
        this.parentOf.set(child, el);
        if (child.nodeType === 3 && child.data) raw.push(runFor(child.data, cs, fontSize));
      }
      const runs = trimRuns(raw);
      this.putClick(props, el);
      if (runs.length) {
        Object.assign(props, textProps(cs, fontSize));
        props.runs = runs;
        return this.put(nodes, id, "text", props, [], fixedNode);
      }
      return this.put(nodes, id, "view", props, [], fixedNode);
    }

    const shape = display === "flex" && !fixedNode ? this.flexShape(el, cs, props) : null;
    if (shape?.plan) {
      // The tree makes the children itself from the native DOM (host.stamp,
      // after emit): no node, map entry or JSON per child here.
      const plan = this.host.stamp && !this.noStamp.has(el) && this.stampable(shape) ? this.stampPlanOf(shape.plan) : 0;
      if (plan) {
        this.cur.stamp = plan;
        this.stamps.push(id, el, plan);
        this.putClick(props, el);
        return this.put(nodes, id, "view", props, EMPTY);
      }
      const kids = this.useFlexShape(shape, cs, nodes, tableSpacingFor(display, props, ctx));
      this.putClick(props, el);
      return this.put(nodes, id, "view", props, kids);
    }

    // Children: blocks, and inline content collected into text runs.
    const childCtx = { blockify: display === "flex" || display === "grid" || tableHolds(display), parentText: cs["text-align"],
      tableSpacing: tableSpacingFor(display, props, ctx), rematch };
    // A list of the same row again and again: its first row here, the rest
    // stamped by the tree (host.stampList, after emit).
    const listed = this.host.stampList ? this.listOf(el, cs, props, display, childCtx, nodes, id) : null;
    if (listed) {
      this.putClick(props, el);
      return this.put(nodes, id, "view", props, listed, fixedNode);
    }
    const kids = [];
    let orders = null; // CSS order of the element children that set one
    const before = this.pseudo(el, cs, "before", nodes);
    if (before) kids.push(before);
    const flow = [];
    const boxed = childCtx.blockify ? null : this.boxedEnds(el, cs, rematch);
    let runs = [];
    // An inline box before or after a stretch of text (a <code> chip in a
    // sentence): the space between them stays, collapsed to one, as on a
    // browser's line; only the line's own ends drop theirs.
    const inlineBox = (child) => !childCtx.blockify && (ATOMIC_INLINE.has(this.style(child, cs, rematch).display || "inline") || !!boxed?.has(child));
    let afterBox = false;
    const flushRuns = (beforeBox = false) => {
      if (!runs.length) return;
      const trimmed = trimRuns(runs, cs["white-space"], afterBox, beforeBox);
      // Only a space between two inline boxes: the space stays (the next
      // box is that much further on: { space }).
      const spaced = !trimmed.length && afterBox && beforeBox && runs.some((r) => /\s/.test(r.t));
      runs = [];
      if (spaced) flow.push({ space: true });
      if (!trimmed.length) return;
      flow.push({ text: trimmed });
    };
    for (let child = el.firstChild; child; child = child.nextSibling) {
      this.parentOf.set(child, el);
      if (child.nodeType === 3) {
        const t = child.data;
        if (t) runs.push(runFor(t, cs, fontSize));
        continue;
      }
      if (child.nodeType !== 1) continue;
      if (!childCtx.blockify && !boxed?.has(child) && this.isInline(child, cs, rematch)) {
        const from = runs.length;
        this.inlineRuns(child, cs, fontSize, runs, rematch);
        // A block's underline is drawn under its inline children's text.
        if (underlined(cs)) for (let i = from; i < runs.length; i++) runs[i].u = true;
        continue;
      }
      const box = inlineBox(child);
      flushRuns(box);
      flow.push({ el: child });
      afterBox = box;
    }
    flushRuns();

    // An element holding only text becomes one text view, unless it centers
    // that text as a flex/grid box (a round icon button: ⚙ in a 28px circle):
    // a text view is drawn from its top-left, so keep a box with a text child.
    // A button's label spans its width (its text-align applies: a menu
    // item's left-aligned label) and is centered in its height.
    if (el.localName === "button" && props.fd === "column" && flow.length === 1 && flow[0].text) props.ai = "stretch";
    if (flow.length === 1 && flow[0].text && !before && !cs.__rules.after.length && !aligns && !(props.scroll || props.scrollx || props.clip || marker)) {
      Object.assign(props, textProps(cs, fontSize));
      props.runs = flow[0].text;
      this.ownRuns(id, props.runs);
      this.putClick(props, el);
      return this.put(nodes, id, "text", props, [], fixedNode);
    }

    // A line of only images (inline replaced elements on the baseline, the
    // rest of the content out of flow): a browser's line box reaches below
    // them by the font's descent and half-leading (an image in a <div> is
    // a few px shorter than the <div>), unless the page makes them blocks.
    // The images' bottom margins take it (below): a block of auto height
    // grows by it, one of a set height (a flex item, a 100%-high canvas in
    // it) keeps its content box and the gap overflows, as in a browser.
    const imageLine = !childCtx.blockify && props.fd === "column" && display !== "flex" && display !== "grid" &&
      this.imageLine(flow, cs, rematch);

    // A line of inline content with an atomic box in it (a checkbox and its
    // label's text): a row that wraps, as an inline formatting context lays
    // it out, not a column (the text went under the box).
    const atomic = (child) => {
      const ccs = this.style(child, cs, rematch), d = ccs.display || "inline";
      return ATOMIC_INLINE.has(d) || !!boxed?.has(child);
    };
    const inlineLine = !childCtx.blockify && props.fd === "column" && flow.some((f) => f.text) && flow.some((f) => f.el) &&
      flow.every((f) => f.text || f.space || atomic(f.el));
    // Spaces between boxes: kept in a line with text; a row of only boxes
    // spaces them with its column gap (below).
    if (!inlineLine) for (let i = flow.length - 1; i >= 0; i--) if (flow[i].space) flow.splice(i, 1);
    // One box and its text (a checkbox's label): the text shrinks to the
    // room beside the box and wraps there by words (its min width is the
    // longest word, tree.zig). Several boxes, or a box sized in % (a
    // `width: 100%` field under its label): they wrap to new lines.
    if (inlineLine) {
      // On one baseline, as an inline formatting context lines them up
      // (a box's is its first text's: tree.zig baselineFn).
      props.fd = "row"; props.ai = "baseline";
      const boxes = flow.filter((f) => f.el);
      if (boxes.length > 1 || boxes.some((f) => /%\s*$/.test(this.style(f.el, cs, rematch).width || ""))) props.fw = "wrap";
      // A <br> in the line: what follows starts a new line (a full-width
      // break between the pieces of text, in a row that wraps).
      if (splitBreaks(flow)) props.fw = "wrap";
    }
    // Only atomic inline boxes (buttons side by side, inline-block chips):
    // one line that wraps, as in a browser, not a column; the whitespace
    // between them collapses to a space's width (none when they touch).
    // (Positioned ones aside: one box in flow stays a column.)
    const inFlow = (f) => { const p = this.style(f.el, cs, rematch).position; return p !== "absolute" && p !== "fixed"; };
    if (!inlineLine && !childCtx.blockify && props.fd === "column" && flow.length > 1 &&
        flow.every((f) => f.el && atomic(f.el)) && flow.filter(inFlow).length > 1) {
      // On one baseline, as an inline formatting context lines them up: a
      // box's its first text's, one with none its bottom (Yoga's baseline
      // alignment; WKWebView: a 14px <p> beside a 24px one sits 9px down).
      // Images: their bottoms, on the strut (imageLine).
      props.fd = "row"; props.fw = "wrap"; props.ai = imageLine ? "flex-end" : "baseline";
      const nodesIn = [...el.childNodes];
      const spaced = nodesIn.some((n, i) => n.nodeType === 3 && /^\s+$/.test(n.data) && i > 0 && i < nodesIn.length - 1);
      if (spaced && props.cg === undefined) { props.cg = Math.round(fontSize * 0.28 * 10) / 10; }
    }

    // One control alone on its line (a <button> in a <div>): the line has
    // the block's strut, as in a browser, a zero-width text in its font
    // beside the control on one baseline (WKWebView: a button's line 19px
    // in a 14px font, the button 18px and 1px down). text-align places it.
    const controls = flow.filter((f) => f.el && inFlow(f));
    if (!inlineLine && !imageLine && !childCtx.blockify && props.fd === "column" && controls.length === 1 &&
        flow.every((f) => f.space || f.el) && CONTROLS.has(controls[0].el.localName) && controls[0].el.localName !== "textarea" &&
        (this.style(controls[0].el, cs, rematch).display || "inline").startsWith("inline")) {
      props.fd = "row"; props.ai = "baseline";
      const ta = cs["text-align"];
      if (ta === "center") props.jc = "center";
      else if (ta === "right" || ta === "end") props.jc = "flex-end";
      for (let i = flow.length - 1; i >= 0; i--) if (flow[i].space) flow.splice(i, 1);
      flow.unshift({ text: [runFor("\u200b", cs, fontSize)], strut: true });
    }

    // Block flow: the kids whose margins don't collapse (lines of text,
    // inline boxes, pseudo-elements), for collapseMargins.
    const flowBlock = !childCtx.blockify && props.fd === "column" && display !== "grid" && !tableHolds(display);
    // Inline content beside blocks (a <div>, then buttons): CSS wraps each
    // run of it in an anonymous block, one line box that wraps, so the
    // buttons share a line instead of each taking a row of the column.
    if (flowBlock && !inlineLine && flow.some((f) => f.el && !atomic(f.el))) {
      const out = [];
      let run = [];
      const flush = () => {
        const boxes = run.filter((f) => f.el).length;
        if (boxes >= 2 || (boxes >= 1 && run.some((f) => f.text))) out.push({ anon: run });
        else out.push(...run);
        run = [];
      };
      for (const f of flow) {
        if ((f.text && !f.strut) || (f.el && atomic(f.el) && inFlow(f))) run.push(f);
        else { flush(); out.push(f); }
      }
      flush();
      flow.length = 0;
      flow.push(...out);
    }
    const inLine = flowBlock ? new Set() : null;
    if (before) inLine?.add(before);
    let spaceBefore = false;
    for (const [index, item] of flow.entries()) {
      if (item.space) { spaceBefore = true; continue; }
      if (item.anon) {
        kids.push(this.anonLine(nodes, el, cs, fontSize, item.anon, childCtx, kids.length));
        inLine?.add(kids[kids.length - 1]);
        continue;
      }
      if (item.brk) {
        const bid = this.idOf(el, "br" + kids.length);
        this.own(bid, el);
        this.put(nodes, bid, "view", { w: "100%", h: 0 }, []);
        kids.push(bid);
        continue;
      }
      if (item.text) {
        const tid = this.idOf(el, "t" + kids.length);
        this.own(tid, el);
        const tp = { ...textProps(cs, fontSize), runs: item.text };
        this.ownRuns(tid, item.text);
        // A line's strut (above): its height, no width.
        if (item.strut) { tp.w = 0; tp.minw = 0; delete tp.ta; }
        if (transitions) this.spec(tid, transitions);
        tp.fs = (childCtx.blockify || inlineLine) && !props.scroll ? 1 : 0;
        this.put(nodes, tid, "text", tp, []);
        kids.push(tid);
        inLine?.add(tid);
        continue;
      }
      const cid = this.element(item.el, cs, nodes, childCtx);
      if (cid === null) continue;
      this.adjustKid(nodes, cid, item.el, cs, props, display, childCtx);
      if (spaceBefore) {
        spaceBefore = false;
        const n = nodes.get(cid);
        const m = n?.props.m ? [...n.props.m] : [0, 0, 0, 0];
        if (n && typeof m[3] === "number") { m[3] += Math.round(fontSize * 0.28 * 10) / 10; n.props = { ...n.props, m }; }
      }
      // An image alone between blocks (an icon over a heading): a browser
      // puts it in a line of its own, which reaches below its margin box by
      // the font's descent (imageLine, for the whole content).
      if ((imageLine && this.imageLine([item], cs, childCtx.rematch)) || (flowBlock && !imageLine && this.loneImage(flow, index, cs, childCtx.rematch))) {
        const n = nodes.get(cid);
        const [above, gap, xh] = lineStrut(cs, fontSize, this.host);
        const va = this.styleOf(item.el)?.["vertical-align"];
        const hk = n && boxHeight(n.props);
        const mk = n?.props.m ? [...n.props.m] : [0, 0, 0, 0];
        if (n && LINE_ALIGNS.has(va) && hk !== null && typeof mk[0] === "number" && typeof mk[2] === "number") {
          // Alone on its line, aligned to it (WKWebView's, measured): top
          // at the line's top, bottom at its bottom, middle centered on
          // the baseline less half the x-height; the line holds it and the
          // strut, its margins take the rest.
          const H = mk[0] + hk + mk[2];
          const top = va === "middle" ? above - xh / 2 - H / 2 : va === "bottom" ? above + gap - H : 0;
          const lineTop = Math.min(0, top), lineBottom = Math.max(above + gap, top + H);
          mk[0] += top - lineTop;
          mk[2] += lineBottom - (top + H);
          n.props = { ...n.props, m: mk };
        } else if (n && gap > 0) {
          const m = n.props.m ? [...n.props.m] : [0, 0, 0, 0];
          // Its baseline is its bottom margin edge: the line is the
          // strut's height above it at least (a 10px badge in a 12px
          // font's line sits 2px down in it, WKWebView's), when its height
          // is known.
          const h = boxHeight(n.props);
          if (h !== null && typeof m[0] === "number" && typeof m[2] === "number") m[0] += Math.max(0, above - (m[0] + h + m[2]));
          if (typeof m[2] === "number") { m[2] += gap; n.props = { ...n.props, m }; }
          // In a row of them: their bottoms (baselines) line up.
          if (props.fd === "row") n.props = { ...n.props, as: "flex-end" };
        }
      }
      // An inline box at a line's end (a padded <code> chip): its vertical
      // padding and border overflow the line, as an inline box's do in a
      // browser, instead of making the line taller.
      if (boxed?.has(item.el)) {
        const n = nodes.get(cid);
        const pad = n?.props.pad, bw = n?.props.bw;
        const v = (i) => (typeof pad?.[i] === "number" ? pad[i] : 0) + (typeof bw?.[i] === "number" ? bw[i] : 0);
        if (n && (v(0) > 0 || v(2) > 0)) {
          const m = n.props.m ? [...n.props.m] : [0, 0, 0, 0];
          if (typeof m[0] === "number" && typeof m[2] === "number") { m[0] -= v(0); m[2] -= v(2); n.props = { ...n.props, m }; }
        }
      }
      kids.push(cid);
      if (inLine && (ATOMIC_INLINE.has(this.styleOf(item.el)?.display || "inline") || boxed?.has(item.el))) inLine.add(cid);
      const ord = parseInt(this.styleOf(item.el)?.order, 10);
      if (ord) (orders ??= new Map()).set(cid, ord);
    }
    const after = this.pseudo(el, cs, "after", nodes);
    if (after) { kids.push(after); inLine?.add(after); }
    if (flowBlock) collapseMargins(nodes, kids, inLine, props, display, ctx);
    // CSS order: flex/grid items laid out by it, then by source order.
    if (orders && childCtx.blockify) {
      const pos = new Map(kids.map((k, i) => [k, i]));
      kids.sort((a, b) => (orders.get(a) || 0) - (orders.get(b) || 0) || pos.get(a) - pos.get(b));
    }
    if (shape) this.saveFlexShape(shape, nodes);

    if (display === "grid") gridToRows(cs, props, kids, nodes, this, el, fontSize);
    if (marker) kids.push(this.putMarker(nodes, el, cs, fontSize, props, marker));
    this.putClick(props, el);
    return this.put(nodes, id, "view", props, kids, fixedNode);
  }

  // A list item's outside marker ("• ", "3. "): a text beside its first
  // line, its end at the item's start edge, in the item's font.
  putMarker(nodes, el, cs, fontSize, props, text) {
    const mid = this.idOf(el, "marker");
    this.own(mid, el);
    const top = Array.isArray(props.pad) && typeof props.pad[0] === "number" ? props.pad[0] : 0;
    const mp = { ...textProps(cs, fontSize), runs: [{ t: text, ...runStyle(cs, fontSize), ws: "pre" }], pos: "absolute", ins: [top, "100%", null, null] };
    this.put(nodes, mid, "text", mp, []);
    return mid;
  }

  // A list of rows the tree stamps (dom_stamp.stampList): every child an
  // element, the first a row the tree stamps (a flex row of leaves) and the
  // rest the same element again, which the tree checks. The first row is
  // made here as any child is; its node as made (with this parent's
  // adjustments) is every row's. Its id as the list's children, or null
  // (nothing made) when the list doesn't look like one.
  listOf(el, cs, props, display, childCtx, nodes, id) {
    if (this.noStampList.has(el) || this.structural || this.noCache || display === "grid" || tableHolds(display) ||
        cs.__rules.before.length || cs.__rules.after.length) return null;
    // Rows hovered, pressed or focused (their data-nui-* attributes): made
    // here the general way, so their :hover styles apply; the first other
    // row is every stamped row's template.
    let marked = null;
    if (this.stateEls) for (const e of this.stateEls()) if (e.parentNode === el) (marked ??= []).push(e);
    let first = el.firstChild;
    while (first && marked?.includes(first)) first = first.nextSibling;
    let second = first?.nextSibling;
    while (second && marked?.includes(second)) second = second.nextSibling;
    // Cheap looks first: two rows of the same tag and class, of leaves.
    if (first?.nodeType !== 1 || second?.nodeType !== 1 || second.localName !== first.localName ||
        second.className !== first.className || !first.firstElementChild ||
        !TEMPLATE_LEAF.has(first.firstElementChild.localName) || first.firstElementChild.firstElementChild) return null;
    this.savedShape = null;
    const cid = this.element(first, cs, nodes, childCtx);
    const f = this.fc.get(first);
    if (cid === null || !f) return null;
    // Its plan: the row's stamp, or the shape its general build just saved
    // (the list's first render).
    let plan = f.stamp;
    const saved = this.savedShape;
    if (!plan && saved?.row === first && this.host.stamp && !this.noStamp.has(first) &&
        this.stampable({ children: saved.children, plan: saved.plan })) plan = this.stampPlanOf(saved.plan);
    // A first row made the general way before (its list declined once):
    // its shape, if one is known.
    if (!plan && this.host.stamp && !this.noStamp.has(first)) {
      const rcs = this.styleOf(first), made = nodes.get(cid);
      const shape = rcs && made ? this.flexShape(first, rcs, made.props, true) : null;
      if (shape?.plan && this.stampable(shape)) plan = this.stampPlanOf(shape.plan);
    }
    // Not a row the tree stamps (yet): the general way (the loop reuses
    // the first row made here).
    if (!plan) return null;
    if (!childCtx.blockify && this.isInline(first, cs, childCtx.rematch)) { this.noStampList.add(el); return null; }
    this.adjustKid(nodes, cid, first, cs, props, display, childCtx);
    const row = nodes.get(cid);
    if (!row || row.kind !== "view") { this.noStampList.add(el); return null; }
    // Rows in block flow with margins above and below: theirs collapse
    // between them (collapseMargins), which one shared style can't say.
    const rm = row.props.m;
    if (!childCtx.blockify && rm && rm[0] && rm[2]) { this.noStampList.add(el); return null; }
    // Every row's node: the first's props (its children are the tree's).
    const style = this.leafStyleId(encodeProps({ ...row.props }));
    if (!style) { this.noStampList.add(el); return null; }
    // The marked rows, as any child (the tree keeps them in their places).
    const kids = [cid];
    if (marked) for (const m of marked) {
      const mid = this.element(m, cs, nodes, childCtx);
      if (mid === null) return null;
      this.adjustKid(nodes, mid, m, cs, props, display, childCtx);
      kids.push(mid);
    }
    this.cur.list = plan;
    this.listStamps.push(id, el, style, plan, first, marked ?? EMPTY);
    return kids;
  }

  // What a parent makes of a child element's node in its general flow
  // (its flex-shrink, basis, alignment), as build's children loop does.
  // An anonymous line box (inline content beside blocks): a row that wraps,
  // its items on one baseline, the white space between two boxes a space's
  // width (none when they touch).
  anonLine(nodes, el, cs, fontSize, items, childCtx, at) {
    const aid = this.idOf(el, "anon" + at);
    this.own(aid, el);
    const ap = { fd: "row", fw: "wrap", ai: "baseline", fs: 0 };
    const ta = cs["text-align"];
    if (ta === "center") ap.jc = "center";
    else if (ta === "right" || ta === "end") ap.jc = "flex-end";
    const space = Math.round(fontSize * 0.28 * 10) / 10;
    const akids = [];
    let prev = null;
    for (const item of items) {
      if (item.text) {
        const tid = this.idOf(el, "t" + at + "." + akids.length);
        this.own(tid, el);
        const tp = { ...textProps(cs, fontSize), runs: item.text, fs: 1 };
        this.ownRuns(tid, item.text);
        this.put(nodes, tid, "text", tp, []);
        akids.push(tid);
        prev = null;
        continue;
      }
      const cid = this.element(item.el, cs, nodes, childCtx);
      if (cid === null) continue;
      this.adjustKid(nodes, cid, item.el, cs, ap, "flex", childCtx);
      // Two boxes with white space between them: a space apart.
      if (prev) {
        let spaced = false;
        for (let n = prev.nextSibling; n && n !== item.el; n = n.nextSibling) if (n.nodeType === 3 && /\s/.test(n.data)) spaced = true;
        const n = nodes.get(cid);
        if (spaced && n) {
          const m = n.props.m ? [...n.props.m] : [0, 0, 0, 0];
          if (typeof m[3] === "number") { m[3] += space; n.props = { ...n.props, m }; }
        }
      }
      akids.push(cid);
      prev = item.el;
    }
    this.put(nodes, aid, "view", ap, akids);
    return aid;
  }

  adjustKid(nodes, cid, itemEl, cs, props, display, childCtx) {
    // Block layout: children keep their size (a flex column would shrink them).
    if (!childCtx.blockify) { const n = nodes.get(cid); if (n && n.props.fs === undefined) n.props.fs = 0; }
    // A scroll container's children keep their size too: CSS's min-size:
    // auto, which Yoga doesn't have (it would squeeze them to fit, and
    // there would be nothing to scroll).
    else if ((props.scroll || props.scrollx) && !this.styleOf(itemEl)?.["flex-shrink"]) { const n = nodes.get(cid); if (n) n.props.fs = 0; }
    // A column whose height isn't definite (no height, not flexed itself:
    // min-height at most): CSS sizes a percentage flex-basis (`flex: 1`
    // is 1 1 0%) from the content, and min-height: auto keeps the item
    // from shrinking below it, so the column grows and the page scrolls.
    // Yoga would squeeze the item into the min-height instead.
    // A column item sized by its content (no height or basis, overflow
    // visible) doesn't shrink below it either: min-height: auto. The
    // column overflows instead, as in a browser.
    else if (props.fd === "column" && this.keepsContentHeight(itemEl, nodes.get(cid))) nodes.get(cid).props.fs = 0;
    else if (props.fd === "column" && props.h === undefined && props.fg === undefined && !props.scroll && /flex$/.test(display)) {
      const n = nodes.get(cid);
      if (n && typeof n.props.fb === "string" && n.props.fb.includes("%") && !n.props.scroll && !n.props.clip) {
        delete n.props.fb;
        n.props.fs = 0;
      }
    }
    // An inline box (button, chip) in a block: as wide as its content, placed by text-align
    // (in a line of inline content: on the line's baseline, the row's).
    if (!childCtx.blockify && !(props.fd === "row" && props.ai === "baseline")) {
      const n = nodes.get(cid);
      const d = this.styleOf(itemEl)?.display || "inline";
      if (n && (ATOMIC_INLINE.has(d) || INLINE_DISPLAY.has(d)) && !n.props.as && n.props.pos !== "absolute") {
        n.props.as = alignFor(cs["text-align"]);
      }
    }
  }

  // An SVG file of the app's (`icons.svg`, `/assets/vite.svg`) or a data:
  // URL, parsed once: its scope (icons.js svgScope), or null.
  svgFile(src) {
    if (this.svgFiles.has(src)) return this.svgFiles.get(src);
    let text = svgDataText(src);
    if (text === null && !src.startsWith("data:") && !/^[a-z]+:\/\/(?!app)/i.test(src)) {
      const path = src.replace(/^(app:\/\/[^/]*)?\.?\//, "").replace(/[?#].*$/, "");
      text = this.host.asset?.(path) ?? null;
    }
    const scope = text ? svgScope(text, this.doc) : null;
    this.svgFiles.set(src, scope);
    return scope;
  }

  putClick(props, el) {
    if (el.localName === "button" || el.localName === "a" || el.localName === "label" || el.localName === "summary" ||
        el.hasAttribute("onclick") || listens(el)) props.click = true;
    if (el.hasAttribute("disabled")) props.dis = true;
  }

  put(nodes, id, kind, props, kids, fixedNode = false) {
    this.put0(nodes, id, { kind, props, kids });
    if (fixedNode) {
      this.cur.fixed.push(id);
      return null; // not in its parent's flow
    }
    return id;
  }

  // Whether flow[i] is an image on the baseline with no inline content
  // beside it (blocks, or nothing, before and after).
  loneImage(flow, i, cs, rematch) {
    const f = flow[i];
    if (!f.el || !this.imageLine([f], cs, rematch)) return false;
    // The nearest neighbor in `step`'s direction that takes room in the
    // line: a collapsible space (Svelte's templates keep the spaces between
    // tags) and out-of-flow boxes (position: absolute) don't, as
    // in a browser, where `<img> <img style="position:absolute">` is still
    // one image on its line.
    const collapses = !(cs["white-space"] || "").startsWith("pre") && cs["white-space"] !== "break-spaces";
    const inlineFrom = (j, step) => {
      for (; j >= 0 && j < flow.length; j += step) {
        const g = flow[j];
        // The space kept between two inline boxes: it collapses away beside
        // an out-of-flow box or at the line's end.
        if (g.space && collapses) continue;
        if (!g.el) return true;
        const gcs = this.style(g.el, cs, rematch);
        if (gcs.position === "absolute" || gcs.position === "fixed" || gcs.display === "none") continue;
        return (gcs.display || "inline").startsWith("inline");
      }
      return false;
    };
    return !inlineFrom(i - 1, -1) && !inlineFrom(i + 1, 1);
  }

  // An inline-block whose baseline is its bottom margin edge (CSS 2.2
  // §10.8.1): no line of text in it, or overflow other than visible. In a
  // line it sits as an image does (imageLine). Controls have their text's.
  bottomBaseline(el, ccs) {
    const d = ccs.display || "inline";
    if (d !== "inline-block" && d !== "inline-flex" && d !== "inline-grid") return false;
    if (CONTROLS.has(el.localName) || el.localName === "button" || REPLACED.has(el.localName)) return false;
    const ov = ccs.overflow || ccs["overflow-y"] || ccs["overflow-x"];
    if (ov && ov !== "visible") return true;
    if (/\S/.test(el.textContent || "")) return false;
    return !el.querySelector?.("img, svg, canvas, video, input, textarea, select, button");
  }

  // Whether the in-flow content is only images on the baseline (imageLine).
  imageLine(flow, cs, rematch) {
    let any = false;
    // vertical-align other than baseline: one box alone on its line.
    let boxes = 0;
    for (const f of flow) if (f.el) { const c = this.style(f.el, cs, rematch); if (c.position !== "absolute" && c.position !== "fixed" && (c.display || "inline") !== "none") boxes++; }
    for (const f of flow) {
      if (f.space) continue; // a space between the boxes: still a line of them
      if (!f.el) return false;
      const ccs = this.style(f.el, cs, rematch);
      if (ccs.position === "absolute" || ccs.position === "fixed" || (ccs.display || "inline") === "none") continue;
      const d = ccs.display || "inline";
      const va = ccs["vertical-align"];
      const replaced = REPLACED.has(f.el.localName) && (d === "inline" || d === "inline-block");
      if ((!replaced && !this.bottomBaseline(f.el, ccs)) || (va && va !== "baseline" && !(boxes === 1 && LINE_ALIGNS.has(va)))) return false;
      any = true;
    }
    return any;
  }

  isInline(el, parentCS, rematch = false) {
    if (SKIP.has(el.localName)) return true;
    if (el.localName === "svg" || el.localName === "input" || el.localName === "textarea" || el.localName === "select" ||
        el.localName === "button" || el.localName === "img" || el.localName === "canvas") return false;
    const cs = this.style(el, parentCS, rematch);
    const d = cs.display || "inline";
    if (d !== "inline") return false;
    // position: absolute/fixed blockifies the box (CSS): an empty
    // <span class="thumb"> with a background is a box, not text.
    if (cs.position === "absolute" || cs.position === "fixed") return false;
    // Inline only if everything inside is inline too.
    const deeper = rematch || this.marks.get(el) === 2;
    for (let c = el.firstElementChild; c; c = c.nextElementSibling) if (!this.isInline(c, cs, deeper)) return false;
    return true;
  }

  // The inline elements with a box of their own (boxedInline) at the start
  // or end of `el`'s content: inline boxes in its line (a row). One amid the
  // text stays a run: a row can't flow text around a box mid-line (a padded
  // <code> in a paragraph would split it into columns).
  boxedEnds(el, cs, rematch) {
    let out = null;
    const blank = (c) => c.nodeType === 8 || (c.nodeType === 3 && !/\S/.test(c.data));
    const isBoxed = (c) => {
      if (c.nodeType !== 1 || SKIP.has(c.localName)) return false;
      const ccs = this.style(c, cs, rematch);
      if ((ccs.display || "inline") !== "inline" || !boxedInline(ccs)) return false;
      return this.isInline(c, cs, rematch);
    };
    for (const step of ["nextSibling", "previousSibling"]) {
      for (let c = step === "nextSibling" ? el.firstChild : el.lastChild; c; c = c[step]) {
        if (blank(c)) continue;
        if (!isBoxed(c)) break;
        (out ??= new Set()).add(c);
      }
    }
    return out;
  }

  // `outerBg`: an enclosing inline element's background (it covers the
  // text of the inline elements inside it too).
  // The text node `id` holds `runs` (for inlineRects).
  ownRuns(id, runs) {
    const owner = { id, runs };
    for (const r of runs) this.runOwner.set(r, owner);
  }

  // An inline element's text as [text node id, first run, last run] per
  // text node it is in (a <span> amid a paragraph: one); null when it made
  // no runs (not rendered, or not inline). Its runs dropped as collapsed
  // white space aren't in it.
  inlineSpans(el) {
    const span = this.spans.get(el);
    if (!span) return null;
    const out = [];
    for (const r of span) {
      const o = this.runOwner.get(r);
      if (!o) continue;
      const i = o.runs.indexOf(r);
      if (i < 0) continue;
      const last = out[out.length - 1];
      if (last && last[0] === o.id && last[2] === i - 1) last[2] = i;
      else out.push([o.id, i, i]);
    }
    return out.length ? out : null;
  }

  inlineRuns(el, parentCS, parentFs, runs, rematch = false, outerBg = undefined) {
    if (SKIP.has(el.localName)) return;
    const cs = this.style(el, parentCS, rematch);
    if ((cs.display || "inline") === "none") return;
    const fs = fontSizeOf(cs, parentCS);
    cs.__fs = fs;
    if (el.localName === "br") { runs.push({ t: "\n", br: true, ...runStyle(cs, fs) }); return; }
    const bg = (cs.background ? background(cs.background, color(cs.color))?.color : undefined) ?? outerBg;
    const deeper = rematch || this.marks.get(el) === 2;
    const first = runs.length;
    for (let child = el.firstChild; child; child = child.nextSibling) {
      this.parentOf.set(child, el);
      if (child.nodeType === 3) runs.push(runFor(child.data, cs, fs, el, bg));
      else if (child.nodeType === 1) this.inlineRuns(child, cs, fs, runs, deeper, bg);
    }
    this.spans.set(el, runs.slice(first));
    // A padded, bordered or rounded inline element amid the text (a <code>
    // chip): its decoration goes on its runs (`ib`), drawn by the backend
    // over each line fragment; its own background goes with it.
    if (boxedInline(cs) && runs.length > first) {
      const ownBg = cs.background ? background(cs.background, color(cs.color))?.color : undefined;
      const ib = inlineBox(el, cs, fs, ownBg);
      for (let i = first; i < runs.length; i++) {
        if (runs[i].br || runs[i].ib) continue;
        runs[i].ib = ib;
        if (ownBg && runs[i].bg && runs[i].bg.every((v, j) => v === ownBg[j])) delete runs[i].bg;
      }
    }
    // An inline element has no box: its outline (its own, or the focus
    // ring) goes around its text's line fragments, as browsers draw it.
    const ol = inlineOutline(cs, fs, el);
    if (ol) for (let i = first; i < runs.length; i++) if (!runs[i].br) runs[i].ol = ol;
    // Its underline is drawn under its inline children's text too.
    if (underlined(cs)) for (let i = first; i < runs.length; i++) runs[i].u = true;
    // A link (or other clickable element) amid the text has no node of its
    // own: its runs carry its id (`k`), so a backend shows the hand over
    // them and sends their clicks to it. The innermost one wins.
    if (runs.length > first && clickableInline(el, cs, parentCS)) {
      const id = this.idOf(el, "el");
      this.own(id, el);
      for (let i = first; i < runs.length; i++) if (!runs[i].br && runs[i].k === undefined) runs[i].k = id;
    }
  }

  pseudo(el, cs, which, nodes) {
    const rules = cs.__rules[which];
    if (!rules.length) return null;
    const pcs = computeStyle(StyleEngine.cascade(rules, null), cs);
    const content = pcs.content;
    if (!content || content === "none" || content === "normal") return null;
    const fs = fontSizeOf(pcs, cs);
    const display = blockify(pcs.display || "inline");
    const props = boxProps(pcs, display, fs, null);
    const id = this.idOf(el, which);
    const transitions = transitionsOf(pcs);
    if (transitions) this.spec(id, transitions);
    this.noteAnimations(id, pcs, fs);
    this.own(id, el);
    const text = /^["'](.*)["']$/.exec(content)?.[1] ?? "";
    if (text) {
      Object.assign(props, textProps(pcs, fs));
      props.runs = [runFor(text, pcs, fs)];
      return this.put(nodes, id, "text", props, []);
    }
    return this.put(nodes, id, "view", props, []);
  }

  // ---------------------------------------------------------------------
  // Diff against the last frame

  createLeaf(id, n) {
    if (!this.host.leafStyle || !this.host.leaf ||
        (n.kind !== "view" && (n.kind !== "text" || n.props.runs?.length !== 1 || n.kids.length)) ||
        this.specs.has(id) || this.animSpecs.has(id)) return false;
    let json = n.template?.json;
    if (json === undefined) {
      const base = { ...n.props };
      if (n.kind === "text") base.runs = [{ ...n.props.runs[0], t: "" }];
      json = encodeProps(base);
    }
    let style = n.template?.style ?? this.leafStyles.get(json);
    const P = this.host.prof ? this.host.now : null;
    if (style === undefined) {
      if (this.leafStyles.size >= 1024 || this.leafStyleBytes + json.length > 2 * 1024 * 1024) return false;
      style = this.leafStyles.size + 1;
      const t0 = P && P();
      if (!this.host.leafStyle(style, json)) style = 0;
      if (P) this.applyMs += P() - t0;
      this.leafStyles.set(json, style);
      this.leafStyleBytes += json.length;
    }
    if (n.template) n.template.style = style;
    const t0 = P && P();
    const created = style && this.host.leaf(id, style, n.kind === "text" ? n.props.runs[0].t : "", n.kind === "text");
    if (P) this.applyMs += P() - t0;
    return created;
  }

  // `nodes`: what was made this frame; `full`: everything was (else the
  // ids in this.gone are what went away).
  emit(nodes, full) {
    this.applyMs = 0;
    const ops = []; // each op's JSON: the props are encoded once, for the diff and the ops

    const now = Date.now();
    // Nodes made again (a new kind): their parents must attach them again.
    const remade = new Set();
    nodes.forEach((n, id) => {
      const old = this.prev.get(id);
      if (old && old.kind !== n.kind) remade.add(id);
    });
    nodes.forEach((n, id) => {
      const old = this.prev.get(id);
      if (old && old.p === null) { old.p = encodeProps(old.props); old.props = null; }
      if (!old && this.host.leaf && this.createLeaf(id, n)) {
        const k = n.kids.length ? JSON.stringify(n.kids) : "[]";
        if (n.kids.length) ops.push(`["k",${id},${k}]`);
        this.prev.set(id, { kind: n.kind, p: null, props: n.props, k });
        return;
      }
      if (!old || old.kind !== n.kind) this.tx.forget(id);
      // The props to show now: the page's, or on the way to them
      // (transitions, animations). Only nodes that have or had one keep
      // their props in the transitions' bookkeeping.
      const spec = this.specs.get(id) || null, animSpec = this.animSpecs.get(id) || null;
      let shown = n.props;
      if (spec || animSpec || this.tx.anims.has(id) || this.anim.state.has(id)) {
        // A transition that appears with the change runs from the props
        // last shown (not kept while the node had none).
        if (spec && old && old.kind === n.kind && !this.tx.targets.has(id)) this.tx.targets.set(id, JSON.parse(old.p));
        shown = this.anim.apply(id, this.tx.apply(id, n.props, spec, now), animSpec, now);
      } else if (this.tx.targets.has(id)) this.tx.forget(id);
      const p = encodeProps(shown);
      const k = JSON.stringify(n.kids);
      if (!old || old.kind !== n.kind) {
        this.canvasSent.delete(id); // a new node: its program is sent again
        if (old) ops.push(`["d",${id}]`);
        ops.push(`["c",${id},${JSON.stringify(n.kind)}]`, `["p",${id},${p}]`, `["k",${id},${k}]`);
      } else {
        if (old.p !== p) ops.push(`["p",${id},${p}]`);
        if (old.k !== k || n.kids.some((c) => remade.has(c))) ops.push(`["k",${id},${k}]`);
      }
      this.prev.set(id, { kind: n.kind, p, k });
      if (n.props.val !== undefined) this.native.set(id, n.props.val);
    });
    const drop = (id) => {
      if (!this.prev.has(id) || nodes.has(id)) return;
      ops.push(`["d",${id}]`); this.prev.delete(id); this.native.delete(id); this.tx.forget(id); this.anim.forget(id); this.owner.delete(id);
    };
    if (full) { for (const id of [...this.prev.keys()]) drop(id); }
    else for (const id of this.gone) drop(id);
    if (!this.rootSent) { ops.push(`["r",0]`); this.rootSent = true; }
    const P = this.host.prof ? this.host.now : null, t0 = P && P();
    if (ops.length) this.host.ops(`[${ops.join(",")}]`);
    // Rows the tree stamps from the DOM, now that they exist there.
    if (this.stamps.length || this.listStamps.length) this.stampRows();
    if (this.canvasEls.size) this.sendCanvases();
    if (P) this.applyMs += P() - t0;
    this.schedule();
  }

  // The canvases whose program the tree doesn't have yet (host.canvas):
  // numbers and strings, no JSON.
  sendCanvases() {
    for (const [el, id] of this.canvasEls) {
      if (!el.isConnected || this.idOf(el, "el") !== id || !this.prev.has(id)) {
        this.canvasEls.delete(el);
        this.canvasSent.delete(id);
        continue;
      }
      const v = versionOf(el);
      if (this.canvasSent.get(id) === v) continue;
      const P = this.host.prof ? this.host.now : null, t0 = P && P();
      const [nums, strs] = programOf(el);
      const t1 = P && P();
      if (this.host.canvas(id, nums, strs)) this.canvasSent.set(id, v);
      if (P) this.host.log(1, `PROF canvas: ${nums.length} numbers, encode ${(t1 - t0).toFixed(2)}, send ${(P() - t1).toFixed(2)}`);
    }
  }

  // Only canvases drew since the last render (nothing marked, no fields
  // whose state changes without mutations): send their programs, flatten
  // nothing.
  canvasOnly() {
    if (!this.host.canvasOps || !this.canvasEls.size || this.marks.size || this.flatMarks.size || this.full || this.pendingScroll) return false;
    for (const el of this.volatile) if (el.isConnected) return false;
    this.sendCanvases();
    return true;
  }

  // host.stamp for this frame's stamped rows. One the tree declines (its
  // children changed shape in a way only the tree saw): no longer stamped,
  // and render() goes the general way at once.
  stampRows() {
    const st = this.stamps;
    this.stamps = [];
    for (let i = 0; i < st.length; i += 3) {
      if (this.host.stamp(st[i], st[i + 1], st[i + 2])) continue;
      const f = this.fc.get(st[i + 1]);
      if (f) f.stamp = 0;
      this.flatMarks.add(st[i + 1]);
      this.noStamp.add(st[i + 1]);
      this.dirty = this.declined = true;
    }
    // Lists after their first rows (stamped above).
    const ls = this.listStamps;
    this.listStamps = [];
    for (let i = 0; i < ls.length; i += 6) {
      if (this.host.stampList(ls[i], ls[i + 1], ls[i + 2], ls[i + 3], ls[i + 4], ls[i + 5])) continue;
      const f = this.fc.get(ls[i + 1]);
      if (f) f.list = 0;
      this.flatMarks.add(ls[i + 1]);
      this.noStampList.add(ls[i + 1]);
      this.dirty = this.declined = true;
    }
  }

  // An element's @keyframes animations: their frames as node props
  // (resolved with the element's style: var(), currentColor, em).
  noteAnimations(id, cs, fs) {
    const list = animationsOf(cs, this.engine.keyframes);
    if (!list) return;
    const frames = list.map((a) => this.engine.keyframes[a.name].map((f) => ({ offset: f.offset, props: animProps(f.decls, cs, fs) })));
    const spec = { key: cs.animation || list.map((a) => `${a.name} ${a.dur}`).join(","), list, frames };
    this.animSpecs.set(id, spec);
  }

  // While transitions or animations run: a frame every ~16 ms that sends
  // the animated nodes' props alone (no styles, no flattening).
  schedule() {
    if (this.ticking || (!this.tx.active && !this.anim.active)) return;
    this.ticking = true;
    // On the page's frames (main.js), with its requestAnimationFrame callbacks.
    requestAnimationFrame(() => { this.ticking = false; this.tick(); });
  }

  tick() {
    const now = Date.now();
    const ops = [];
    const ids = new Set(this.tx.anims.keys());
    for (const [id, st] of this.anim.state) if (st.running) ids.add(id);
    for (const id of ids) {
      const prev = this.prev.get(id);
      const target = this.tx.targets.get(id);
      if (!prev || !target) { this.tx.forget(id); this.anim.forget(id); continue; }
      const shown = this.anim.apply(id, this.tx.apply(id, target, null, now), undefined, now);
      const p = encodeProps(shown);
      if (p !== prev.p) { ops.push(["p", id, shown]); prev.p = p; }
    }
    if (ops.length) this.host.ops(JSON.stringify(ops));
    this.schedule();
  }
}

// Two computed styles with the same values (the bookkeeping keys aside).
// An inline style of transform/opacity declarations only (no !important,
// var() or keywords): { property: value }, else null. As parseInline and
// expandInto would make it (these properties are no shorthands), cheaper.
function paintDecls(text) {
  const out = {};
  if (!text) return out;
  for (const part of text.split(";")) {
    const i = part.indexOf(":");
    if (i < 0) { if (part.trim()) return null; continue; }
    const prop = part.slice(0, i).trim().toLowerCase(), value = part.slice(i + 1).trim();
    if (!PAINT_KEYS.has(prop)) return null;
    if (!value) continue;
    if (value.includes("!") || value.includes("var(") || value === "inherit" || value === "initial" || value === "unset") return null;
    out[prop] = value;
  }
  return out;
}

// What a transform/opacity-only change touches (updateBoxes).
const PAINT_KEYS = new Set(["transform", "translate", "scale", "rotate", "opacity"]);
const PAINT_PROPS = ["tx", "ty", "sc", "rot", "op"];

function sameStyle(a, b) {
  let n = 0;
  for (const k in a) {
    if (k === "__rules" || k === "__fs") continue;
    if (a[k] !== b[k]) return false;
    n++;
  }
  for (const k in b) if (k !== "__rules" && k !== "__fs") n--;
  return n === 0;
}

function listens(el) {
  return !!el.__listens;
}

// An inline element whose text takes clicks (render.js inlineRuns' `k`):
// as putClick, plus its own cursor: pointer (not one inherited from a link
// around it); never a disabled one.
function clickableInline(el, cs, parentCS) {
  if (el.hasAttribute("disabled")) return false;
  const n = el.localName;
  return (n === "a" && el.hasAttribute("href")) || n === "button" || n === "label" || n === "summary" ||
    el.hasAttribute("onclick") || listens(el) || (cs.cursor === "pointer" && parentCS?.cursor !== "pointer");
}

// ---------------------------------------------------------------------------
// Tables: the table and its row groups are flex columns, a row is a flex
// row of cells, and tree.zig sizes the columns (each cell's natural width,
// the widest per column) after the first layout. border-spacing becomes the
// gaps (and the table's inner padding).

const TABLE_GROUPS = new Set(["table-row-group", "table-header-group", "table-footer-group"]);

function isTableDisplay(d) {
  return d === "table" || d === "inline-table" || d === "table-row" || d === "table-cell" ||
    d === "table-column" || d === "table-column-group" || TABLE_GROUPS.has(d);
}

// A table box whose children are laid out as flex items (rows, cells).
// Adjoining vertical margins as one (CSS 2.2 §8.3.1): the largest
// positive plus the most negative.
function collapsed(...ms) {
  return Math.max(...ms, 0) + Math.min(...ms, 0);
}

// A block its margins collapse through: a view with no children, no
// height, min-height, vertical padding or border (CSS 2.2 §8.3.1).
function emptyBlock(n) {
  if (n.kind !== "view" || (n.kids && n.kids.length)) return false;
  const p = n.props;
  const zero = (v) => v === undefined || v === 0;
  return (p.h === undefined || p.h === 0) && !p.minh && zero(p.pad?.[0]) && zero(p.pad?.[2]) && zero(p.bw?.[0]) && zero(p.bw?.[2]) &&
    !p.scroll && !p.clip && !p.root;
}

// A margin in px, or null when it can't collapse here (a percentage).
function pxMargin(n, side) {
  const v = n.props.m ? n.props.m[side] : 0;
  return typeof v === "number" ? v : null;
}

function setMargin(n, side, v) {
  // A new array: the props' own may be shared (memoized boxProps, a
  // reused element's saved node).
  const m = n.props.m ? n.props.m.slice() : [0, 0, 0, 0];
  m[side] = v;
  n.props.m = m;
}

// Block flow's vertical margins, where Yoga adds them: adjacent blocks
// get the larger of the two (the lower one's goes to 0), and the first
// and last block's margin collapses through `props`'s (the container's)
// own when no padding or border separates them and the container isn't
// a formatting context of its own (a flex or grid item, scrolled or
// clipped, positioned, an inline-block or a cell). `inLine`: kids in
// lines (text, inline boxes, pseudo-elements), which separate blocks.
function collapseMargins(nodes, kids, inLine, props, display, ctx) {
  // `prev` holds the margin slot below it, the adjoining margins there so
  // far (`adj`), and how much of their collapse is already placed above
  // that slot (`placed`: an empty block's own collapsed part, before it).
  let prev = null, adj = [], placed = 0, first = null, last = null, lastLine = false, seen = false;
  for (const id of kids) {
    const n = nodes.get(id);
    if (!n || n.props.pos === "absolute") continue;
    if (inLine.has(id)) { prev = null; seen = true; lastLine = true; continue; }
    if (!seen) first = n;
    seen = true;
    lastLine = false;
    last = n;
    const t = pxMargin(n, 0), b = pxMargin(n, 2);
    // An empty block (no content, height, padding or border between its
    // margins): its own top and bottom margins collapse together, and with
    // the ones around it (WebKit's: 12px and 18px between two blocks, 18).
    if (emptyBlock(n) && t !== null && b !== null) {
      if (prev) {
        const x = collapsed(...adj, t);
        setMargin(prev, 2, x - placed);
        setMargin(n, 0, 0);
        adj = [...adj, t, b];
        placed = x;
      } else {
        adj = [t, b];
        placed = t;
      }
      setMargin(n, 2, 0);
      prev = n;
      continue;
    }
    if (prev && t !== null && adj.every((v) => v !== null)) {
      const total = collapsed(...adj, t);
      if (total !== placed || t) {
        setMargin(prev, 2, total - placed);
        setMargin(n, 0, 0);
      }
    } else if (prev && emptyBlock(prev)) setMargin(prev, 2, collapsed(...adj) - placed);
    prev = n;
    adj = [b];
    placed = 0;
  }
  // An empty block last: what it carries goes below it.
  if (prev && emptyBlock(prev) && adj.length > 2) setMargin(prev, 2, collapsed(...adj) - placed);
  const own = { props };
  const through = (display === "block" || display === "list-item") && (!ctx.blockify || ctx.rootBody) && !props.scroll && !props.scrollx &&
    !props.clip && props.pos !== "absolute";
  if (!through) return;
  const side = (n, s) => !(props.pad?.[s]) && !(props.bw?.[s]) && n;
  if (side(first, 0)) {
    const a = pxMargin(own, 0), b = pxMargin(first, 0);
    if (a !== null && b !== null && b) {
      props.m = (own.props.m ?? [0, 0, 0, 0]).slice();
      props.m[0] = collapsed(a, b);
      setMargin(first, 0, 0);
    }
  }
  if (!lastLine && side(last, 2) && props.h === undefined && !props.minh) {
    const a = pxMargin(own, 2), b = pxMargin(last, 2);
    if (a !== null && b !== null && b) {
      props.m = (props.m ?? [0, 0, 0, 0]).slice();
      props.m[2] = collapsed(a, b);
      setMargin(last, 2, 0);
    }
  }
}

function tableHolds(d) {
  return d === "table" || d === "inline-table" || d === "table-row" || TABLE_GROUPS.has(d);
}

// The spacing a table box's children use: the table's own, passed down.
function tableSpacingFor(d, props, ctx) {
  if (d === "table" || d === "inline-table") return props.table;
  return tableHolds(d) ? ctx.tableSpacing : undefined;
}

// A table element's props; false when it isn't drawn (columns).
function tableProps(props, display, cs, fontSize, ctx, el) {
  if (display === "table" || display === "inline-table") {
    const sp = tableSpacing(cs, fontSize);
    props.table = sp;
    if (sp) {
      props.rg = sp;
      // The spacing also runs between the table's border and its cells.
      props.pad = (props.pad || [0, 0, 0, 0]).map((v) => (typeof v === "number" ? v : 0) + sp);
    }
    // A table without a width is as wide as its columns.
    if (props.w === undefined && !ctx.blockify && !props.as) props.as = "flex-start";
  } else if (TABLE_GROUPS.has(display)) {
    if (ctx.tableSpacing) props.rg = ctx.tableSpacing;
  } else if (display === "table-row") {
    props.trow = true;
    props.fd = "row";
    props.ai = "stretch";
    if (ctx.tableSpacing) props.cg = ctx.tableSpacing;
  } else if (display === "table-cell") {
    const span = parseInt(el.getAttribute("colspan") || "1", 10);
    props.tcell = Number.isFinite(span) && span > 1 ? Math.min(span, 1000) : 1;
    props.fs = 0;
    const va = cs["vertical-align"];
    props.jc = va === "middle" ? "center" : va === "bottom" ? "flex-end" : "flex-start";
  } else return false; // table-column, table-column-group
  return true;
}

// border-spacing in px (its first value), 0 with collapsed borders.
function tableSpacing(cs, fs) {
  if (cs["border-collapse"] === "collapse") return 0;
  const first = String(cs["border-spacing"] || "0").trim().split(/\s+/)[0];
  const v = num(first, fs);
  return typeof v === "number" && v > 0 ? v : 0;
}

function blockify(d) {
  if (d === "inline" || d === "inline-block" || d === "list-item" || d === "table-caption") return "block";
  if (d === "inline-table") return "table";
  if (d === "inline-flex") return "flex";
  if (d === "inline-grid") return "grid";
  return d;
}

function alignFor(ta) {
  return ta === "center" ? "center" : ta === "right" || ta === "end" ? "flex-end" : "flex-start";
}

const fontSizes = internalWeak(new WeakMap());
function fontSizeOf(cs, parentCS) {
  const pfs = parentCS?.__fs ?? 16;
  const cached = fontSizes.get(cs);
  if (cached && cached.parent === pfs) return cached.size;
  const size = resolveFontSize(cs, pfs);
  fontSizes.set(cs, { parent: pfs, size });
  return size;
}

function resolveFontSize(cs, pfs) {
  const v = cs["font-size"];
  if (!v) return pfs;
  if (v.endsWith("em") && !v.endsWith("rem")) return parseFloat(v) * pfs;
  if (v.endsWith("%")) return parseFloat(v) / 100 * pfs;
  const map = { small: 13, medium: 16, large: 18, "x-large": 24, smaller: pfs * 0.83, larger: pfs * 1.2 };
  if (map[v]) return map[v];
  const l = length(v, pfs, false);
  return typeof l === "number" ? l : pfs;
}

// A scroller's scrollbar, for backends that draw one (tree.zig's
// Tree.scrollbar): always (overflow-y: scroll, scrollbar-gutter: stable),
// its scrollbar-width (thin, none), dark (its color-scheme: dark, or light
// dark with a dark preference; the window's own also with none, as
// WebView2's follows the system), its scrollbar-color [thumb, track].
function scrollbarPart(cs, p, root) {
  if (cs["overflow-y"] === "scroll" || (!cs["overflow-y"] && cs.overflow === "scroll") || /^stable/.test(cs["scrollbar-gutter"] || "")) p.sbs = true;
  const sw = cs["scrollbar-width"];
  if (sw === "thin" || sw === "none") p.sbw = sw;
  const scheme = cs["color-scheme"] || "normal";
  const dark = /dark/.test(scheme) ? (!/light/.test(scheme) || viewport.dark) : root && !/light/.test(scheme) && viewport.dark;
  if (dark) p.dk = true;
  const sc = cs["scrollbar-color"];
  if (sc && sc !== "auto") {
    const [thumb, track] = splitSpaces(sc).map((v) => color(v, color(cs.color)));
    if (thumb && track) p.sbc = [thumb, track];
  }
}

function bgOf(cs) {
  return background(cs.background, color(cs.color)) || null;
}

const num = (v, fs) => {
  const l = length(v, fs);
  return l === null ? undefined : l;
};

// Per computed style (shared by siblings with the same rules, kept while
// it doesn't change): what its props come to, by the other arguments.
const memo = internalWeak(new WeakMap());
function memoized(cs, key, make) {
  let m = memo.get(cs);
  if (!m) memo.set(cs, (m = new Map()));
  let v = m.get(key);
  if (v === undefined) m.set(key, (v = make()));
  return v;
}

// Layout and drawing properties of a box (a copy: the caller adds to it).
function boxProps(cs, display, fs, el) {
  const button = el?.localName === "button";
  const bb = borderBoxByDefault(el);
  // (The dpr too: border widths snap to its device pixels.)
  const key = `b${display}|${fs}|${button}|${bb}|${viewport.dpr}`;
  const d = derived.get(cs);
  // (A mac button's background decides its whole box: pushButton.)
  if (d?.parts && !(button && pushButtons && d.parts.includes("bg"))) {
    const p = { ...memoized(d.base, key, () => makeBoxProps(d.base, display, fs, button, bb)) };
    for (const part of d.parts) {
      const [keys, make] = PARTS[part];
      for (const k of keys) delete p[k];
      make(cs, fs, p);
    }
    // An inline width or height: the box may have a size now.
    contentBox(cs, p, bb);
    return focusRing(cs, el, p);
  }
  return focusRing(cs, el, { ...memoized(cs, key, () => makeBoxProps(cs, display, fs, button, bb)) });
}

// Browsers' own focus ring on :focus-visible (keyboard focus, a text
// field), unless the page styles the outline. Here rather than a rule in
// UA_CSS, which every element would be matched against.
// main.js says which element matches :focus-visible (one at most).
// The ring is the platform's browser's (setFocusRingOS, at boot):
// - WebKitGTK's: blue, 2px, 1px out.
// - Chromium's (WebView2, Android's WebView): a 2px band inside a 1px
//   white halo (h), its corners at least r round (its outer edge's). As
//   WebView2 draws it: over a control's own border (o -2, r 3), 1px over a
//   box's edge (o -1, r 4), just outside a link (o 0) and 1px off a
//   checkbox or radio (o 1, r 3). The band is #101010 on Windows and
//   Android's orange #E59700 there (both measured).
// - WKWebView's (measured), the system blue at half alpha (macOS's
//   accent, rgb(0, 103, 244); iOS's, rgb(0, 122, 255)): on macOS 4px,
//   1px off a box or link (o 1, r 2) and 1px over a control's edge (o -1;
//   r 2, AppKit's bezel rings 5); on iOS 3px, just outside a box (o 0)
//   and 2px over a control's edge (o -2, r 8).
const FOCUS_RING = { w: 2, c: [0, 103, 244, 1], o: 1 };
const chromiumRings = (c) => {
  const ring = (o, r) => ({ w: 2, c, o, h: [255, 255, 255, 1], r });
  return { control: ring(-2, 3), check: ring(1, 3), link: ring(0, 4), box: ring(-1, 4) };
};
const WINDOWS_RINGS = chromiumRings([16, 16, 16, 1]);
const ANDROID_RINGS = chromiumRings([229, 151, 0, 1]);
// (In the system's accent color, platform.accent, at half alpha; its
// default blue without one.)
function macRings(accent) {
  const c = Array.isArray(accent) && accent.length === 3 ? [...accent.map((v) => +v || 0), 0.5] : [0, 103, 244, 0.5];
  const ring = (o, r) => ({ w: 4, c, o, r });
  return { field: ring(-1, 2), control: ring(-1, 5), check: ring(-1, 5), link: ring(1, 2), box: ring(1, 2) };
}
function iosRings(accent) {
  const c = Array.isArray(accent) && accent.length === 3 ? [...accent.map((v) => +v || 0), 0.5] : [0, 122, 255, 0.5];
  const ring = (o, r) => ({ w: 3, c, o, r });
  return { field: ring(-2, 8), control: ring(-2, 8), check: ring(-2, 8), link: ring(0, 0), box: ring(0, 0) };
}
// WebKitGTK (Linux): 2px in the theme's accent color at 0.8 alpha (WebKit's
// own blue without one), over a control's border (its 5px corners), just
// outside a link or another box (measured). No halo.
const webkitGtkRings = (accent) => {
  const c = [...(Array.isArray(accent) && accent.length === 3 ? accent : [52, 132, 228]), 0.8];
  const ring = (o, r) => ({ w: 2, c, o, r });
  return { control: ring(-2, 5), check: ring(0, 3), link: ring(1, 3), box: ring(1, 3) };
};
let osRings = null;
// A color's shade for an outset or inset border's dark sides (WebKit's and
// Blink's Color::dark).
function darkColor(c) {
  const v = Math.max(c[0], c[1], c[2]) / 255;
  const k = v === 0 ? 0 : Math.max(0, (v - 0.33) / v);
  return [Math.round(c[0] * k), Math.round(c[1] * k), Math.round(c[2] * k), c[3]];
}

// macOS: buttons as WKWebView draws them there (measured), AppKit's push
// button: while the page leaves its background, border and appearance
// alone (UA_CSS_MAC marks the background), no border (WebKit's computed
// border is 0: a 14px button is 24 high, not 28; its 2px a side still
// taken), white, 4px corners and a hairline edge just outside it;
// otherwise the CSS box on WebKit's ButtonFace (rgb(192, 192, 192)). (A
// button taller than AppKit's push button, WebKit draws as a square bevel
// button; here it stays a push button.)
let pushButtons = false;
// (A ButtonFace no page writes: its background shorthand as UA_CSS_MAC left it.)
const PUSH_MARK = "rgba(239, 239, 239, 0.9999)";
// Border widths as browsers snap them to device pixels (measured in
// WKWebView on macOS at 1x and the iOS simulator at 3x; Chromium's from
// the Android session): a width under one device pixel is one, any other
// is floored to whole device pixels (a 1px border at dpr 2.625: 0.762;
// 3px: 2.667). WebKit floors the width as its layout unit (1/64 px) holds
// it, so 0.34px at 3x is 0 and 2.67px is 2.333 there.
let webkitBorders = false;
export function snapBorder(w) {
  if (!(w > 0)) return 0;
  const dpr = viewport.dpr || 1;
  if (w * dpr < 1) return 1 / dpr;
  const v = webkitBorders ? Math.trunc(w * 64) / 64 : w;
  return Math.floor(v * dpr + 1e-6) / dpr;
}

function pushButton(cs, p) {
  if (cs.background !== PUSH_MARK || (cs["background-color"] && cs["background-color"] !== PUSH_MARK)) return;
  const app = cs.appearance || cs["-webkit-appearance"];
  const uaBorder = cs["border-top-style"] === "outset" && cs["border-right-style"] === "outset" &&
    cs["border-bottom-style"] === "outset" && cs["border-left-style"] === "outset";
  if (app === "none" || !uaBorder) {
    // WebKit's ButtonFace on macOS (measured; UA_CSS_MAC's border is it too).
    p.bg = { ...(p.bg || {}), color: [192, 192, 192, 1] };
    return;
  }
  delete p.bw; delete p.bc; delete p.bs;
  // The bezel keeps the border's 2px a side (WebKit's computed border is 0
  // but a push button is that much wider than its padding and text).
  const pad = p.pad ? p.pad.slice() : [0, 0, 0, 0];
  for (const i of [1, 3]) if (typeof pad[i] === "number" || pad[i] === undefined) pad[i] = (pad[i] || 0) + 2;
  p.pad = pad;
  p.bg = { ...(p.bg || {}), color: [255, 255, 255, 1] };
  if (!p.br) p.br = [4, 4, 4, 4];
  if (!p.sh) p.sh = { x: 0, y: 0.5, blur: 0, spread: 1, color: [0, 0, 0, 0.075] };
}

export function setFocusRingOS(os, accent) {
  pushButtons = os === "macos";
  webkitBorders = os === "macos" || os === "ios" || os === "linux";
  osRings = os === "linux" ? webkitGtkRings(accent) : os === "macos" ? macRings(accent) : os === "ios" ? iosRings(accent) : { windows: WINDOWS_RINGS, android: ANDROID_RINGS }[os] || null;
}
let focusVisible = null;
export function setFocusVisible(el) { focusVisible = el; }
// An inline element's outline for its runs: the page's, else the focus
// ring when it has :focus-visible.
function inlineOutline(cs, fs, el) {
  if (cs["outline-style"] !== undefined || cs["outline-width"] !== undefined) {
    const p = {};
    outlinePart(cs, fs, p);
    return p.ol || null;
  }
  if (el !== focusVisible) return null;
  return osRings ? ringFor(osRings, el) : FOCUS_RING;
}

function focusRing(cs, el, p) {
  if (el === focusVisible && el && !p.ol && cs["outline-style"] === undefined && cs["outline-width"] === undefined) p.ol = osRings ? ringFor(osRings, el) : FOCUS_RING;
  return p;
}
function ringFor(rings, el) {
  switch (el.localName) {
    case "input": {
      const type = (el.getAttribute("type") || "").toLowerCase();
      if (type === "checkbox" || type === "radio") return rings.check;
      return ["button", "submit", "reset", "range", "color", "file", "image"].includes(type) ? rings.control : rings.field || rings.control;
    }
    case "textarea": return rings.field || rings.control;
    case "button": case "select": return rings.control;
    case "a": return el.hasAttribute("href") ? rings.link : rings.box;
    default: return rings.box;
  }
}

// outline: drawn outside the border box (offset + width), around its
// rounded corners, over the box and its children, taking no room. Sent
// only when there is one: ol { w, o (offset), c, s ("dashed"/"dotted";
// absent: solid) }.
function outlinePart(cs, fs, p) {
  const style = cs["outline-style"];
  if (!style || style === "none" || style === "hidden") return;
  const wv = cs["outline-width"] || "medium";
  const w = wv === "thin" ? 1 : wv === "medium" ? 3 : wv === "thick" ? 5 : num(wv, fs);
  if (typeof w !== "number" || !(w > 0)) return;
  const c = color(cs["outline-color"] || "currentcolor", color(cs.color));
  if (!c || c[3] <= 0) return;
  const o = num(cs["outline-offset"] || "0", fs);
  const ol = { w, c };
  if (typeof o === "number" && o) ol.o = o;
  if (style === "dashed" || style === "dotted") ol.s = style;
  p.ol = ol;
}

// A width, height or basis that sets a size (px or a percentage; not auto).
function isSize(v) {
  return typeof v === "number" || (typeof v === "string" && v.endsWith("%"));
}

// Form controls are border-box unless the page says otherwise, as in
// browsers' own style sheets (a rule in UA_CSS would cost every element's
// matching a little).
const CONTROLS = new Set(["input", "textarea", "select", "button"]);
const BORDER_BOX_INPUTS = new Set(["button", "submit", "reset", "checkbox", "radio", "color", "file", "range", "image"]);
function borderBoxByDefault(el) {
  const t = el?.localName;
  if (t === "button" || t === "select" || t === "meter" || t === "progress") return true;
  return t === "input" && BORDER_BOX_INPUTS.has((el.getAttribute("type") || "").toLowerCase());
}

// box-sizing: content-box (CSS's default; Yoga's is border-box): sizes
// without the padding and border. Said (cb) only where it matters, a box
// with a size and padding or a border.
const SIZE_KEYS = ["w", "h", "minw", "minh", "maxw", "maxh", "fb"];
function contentBox(cs, p, borderBox) {
  const sizing = cs["box-sizing"] ?? (borderBox ? "border-box" : "content-box");
  if ((p.pad || p.bw) && sizing !== "border-box" && SIZE_KEYS.some((k) => isSize(p[k]))) p.cb = true;
  else delete p.cb;
}

function makeBoxProps(cs, display, fs, button, borderBox) {
  const p = {};
  if (display === "inline-flex") display = "flex";
  if (display === "inline-grid") display = "grid";
  const set = (k, v) => { if (v !== undefined && v !== null) p[k] = typeof v === "object" ? pctString(v) : v; };
  // Layout
  if (display === "flex") {
    p.fd = cs["flex-direction"] || "row";
    if (cs["flex-wrap"] && cs["flex-wrap"] !== "nowrap") p.fw = cs["flex-wrap"];
    p.ai = cs["align-items"] && cs["align-items"] !== "normal" ? cs["align-items"] : "stretch";
  } else if (display === "grid") {
    p.fd = "column";
    p.ai = "stretch";
    if (cs["align-items"] || cs["justify-items"]) {
      // place-items: center on a one-child grid (an icon button) → centered.
      if (cs["align-items"] === "center" && cs["justify-items"] === "center") { p.fd = "row"; p.ai = "center"; p.jc = "center"; }
    }
  } else {
    p.fd = "column";
    p.ai = "stretch";
  }
  if (cs["justify-content"] && cs["justify-content"] !== "normal" && !p.jc) p.jc = cs["justify-content"];
  // A browser centers a button's content, until the page lays the button
  // out itself (display: flex or grid: then flex-start, like any box).
  if (button && display !== "flex" && display !== "grid") {
    p.ai = "center";
    if (!p.jc) p.jc = "center";
  }
  if (cs["align-self"] && cs["align-self"] !== "auto") p.as = cs["align-self"];
  if (cs["align-content"]) p.ac = cs["align-content"];
  if (cs["flex-grow"]) p.fg = parseFloat(cs["flex-grow"]);
  if (cs["flex-shrink"]) p.fs = parseFloat(cs["flex-shrink"]);
  if (cs["flex-basis"] && cs["flex-basis"] !== "auto") set("fb", num(cs["flex-basis"], fs));
  set("w", num(cs.width, fs));
  set("h", num(cs.height, fs));
  set("minw", num(cs["min-width"], fs));
  set("minh", num(cs["min-height"], fs));
  set("maxw", num(cs["max-width"], fs));
  set("maxh", num(cs["max-height"], fs));
  const sides = ["top", "right", "bottom", "left"];
  const m = sides.map((s) => { const v = cs[`margin-${s}`]; const l = num(v, fs); return l === undefined ? 0 : typeof l === "object" ? `${l.pct}%` : l; });
  if (m.some((x) => x)) p.m = m;
  const pad = sides.map((s) => { const l = num(cs[`padding-${s}`], fs); return l === undefined || l === "auto" ? 0 : typeof l === "object" ? `${l.pct}%` : l; });
  if (pad.some((x) => x)) p.pad = pad;
  const bw = sides.map((s) => { const l = num(cs[`border-${s}-width`], fs); return snapBorder(typeof l === "number" ? l : (cs[`border-${s}-width`] === "thin" ? 1 : cs[`border-${s}-width`] === "medium" ? 3 : 0)); });
  if (bw.some((x) => x)) {
    p.bw = bw;
    const cur = color(cs.color);
    p.bc = sides.map((s) => color(cs[`border-${s}-color`] || "currentcolor", cur) || [0, 0, 0, 0]);
    // outset and inset: the shaded sides darker, as WebKit and Blink shade
    // them (Color::dark: each channel × (v - 0.33) / v, v the brightest;
    // ButtonFace's 192 is 108): outset the bottom and right, inset the top
    // and left.
    p.bc = p.bc.map((c, i) => {
      const st = cs[`border-${sides[i]}-style`];
      const shaded = st === "outset" ? i === 1 || i === 2 : st === "inset" ? i === 0 || i === 3 : false;
      return shaded ? darkColor(c) : c;
    });
    // Dashed or dotted: the first side drawn so (the backends draw one
    // style for the box).
    const style = sides.map((s, i) => bw[i] ? cs[`border-${s}-style`] : null).find((st) => st === "dashed" || st === "dotted");
    if (style) p.bs = style;
  }
  contentBox(cs, p, borderBox);
  outlinePart(cs, fs, p);
  const rg = num(cs["row-gap"], fs), cg = num(cs["column-gap"], fs);
  if (typeof rg === "number" && rg) p.rg = rg;
  if (typeof cg === "number" && cg) p.cg = cg;
  positionPart(cs, fs, p);
  const ov = cs["overflow-y"] || cs.overflow;
  if (ov === "auto" || ov === "scroll") p.scroll = true;
  if (p.scroll) scrollbarPart(cs, p, false);
  const ovx = cs["overflow-x"];
  if (ovx === "auto" || ovx === "scroll") p.scrollx = true;
  if (cs["overflow-x"] === "hidden" || cs["overflow-y"] === "hidden" || cs.overflow === "hidden") p.clip = true;
  if (cs["aspect-ratio"]) p.ar = parseFloat(cs["aspect-ratio"]);
  transformPart(cs, fs, p);
  // Drawing
  const cur = color(cs.color);
  backgroundPart(cs, p);
  // Each corner: one length (both axes), or [x, y] when they differ ("10px
  // 20px", or border-radius: a / b); a percentage is the backend's to
  // resolve (x of the width, y of the height).
  const one = (v) => {
    if (!v) return 0;
    if (v.endsWith("%")) return `${parseFloat(v) || 0}%`;
    const l = length(v, fs, false);
    return typeof l === "number" ? Math.max(0, Math.min(l, 9999)) : 0;
  };
  const r = ["top-left", "top-right", "bottom-right", "bottom-left"].map((c) => {
    const v = cs[`border-${c}-radius`];
    if (!v) return 0;
    const [a, b] = splitSpaces(String(v));
    const x = one(a);
    const y = b === undefined ? x : one(b);
    return x === y ? x : [x, y];
  });
  if (r.some((x) => x && x !== "0%")) p.br = r;
  if (cs.opacity !== undefined && cs.opacity !== "1") p.op = parseFloat(cs.opacity);
  const sh = shadow(cs["box-shadow"], cur);
  if (sh) p.sh = sh;
  if (cs.visibility === "hidden") p.vis = false;
  if (cs.cursor === "pointer") p.click = true;
  if (cs["z-index"] && cs["z-index"] !== "auto") p.z = parseInt(cs["z-index"], 10);
  if (button && pushButtons) pushButton(cs, p);
  return p;
}

function positionPart(cs, fs, p) {
  const sides = ["top", "right", "bottom", "left"];
  if (cs.position === "absolute" || cs.position === "fixed") {
    p.pos = "absolute";
    const ins = sides.map((s) => { const l = num(cs[s], fs); return l === undefined || l === "auto" ? null : typeof l === "object" ? `${l.pct}%` : l; });
    p.ins = ins;
  } else if (cs.position === "sticky") {
    // In the flow, then kept inside its scroll container's view (tree.zig).
    const ins = sides.map((s) => { const l = num(cs[s], fs); return typeof l === "number" ? l : null; });
    if (ins.some((x) => x !== null)) p.sticky = ins;
  } else if (cs.position === "relative") {
    const ins = sides.map((s) => { const l = num(cs[s], fs); return typeof l === "number" ? l : null; });
    if (ins.some((x) => x !== null)) p.rel = ins;
  }
}

// Transforms: translate moves the box; scale and rotate are drawn around its center.
// translate(Xpx, Ypx) alone: what an animation loop writes each frame.
const TRANSLATE_PX = /^translate\(\s*(-?(?:\d+\.?\d*|\.\d+))px\s*,\s*(-?(?:\d+\.?\d*|\.\d+))px\s*\)$/;

function transformPart(cs, fs, p) {
  const t = cs.transform;
  if (t !== undefined && cs.translate === undefined && cs.scale === undefined && cs.rotate === undefined) {
    const m = TRANSLATE_PX.exec(t);
    if (m) {
      const x = +m[1], y = +m[2];
      if (x) p.tx = x;
      if (y) p.ty = y;
      return;
    }
  }
  const tr = transformOf(cs, fs);
  if (tr.tx) p.tx = tr.tx;
  if (tr.ty) p.ty = tr.ty;
  if (tr.sc !== 1) p.sc = tr.sc;
  if (tr.rot) p.rot = tr.rot;
}

function backgroundPart(cs, p) {
  const bg = background(cs.background, color(cs.color));
  // backdrop-filter: blur() isn't drawn: a see-through bar over the page
  // (a 92% background) would show the text behind it sharp. Opaque
  // instead, which is what the blur looks like.
  if (bg?.color && bg.color[3] < 1 && /blur\(/.test(cs["backdrop-filter"] || cs["-webkit-backdrop-filter"] || "")) {
    bg.color = [...bg.color.slice(0, 3), 1];
  }
  if (bg) p.bg = bg;
}

// An inline style that sets only these (an animation writing transform,
// opacity, left/top…): the box props are its rules' ones with that part
// done again. Each: the props it makes, and how.
const set1 = (k, v, p) => { if (v !== undefined && v !== null) p[k] = typeof v === "object" ? pctString(v) : v; };
const PARTS = {
  tr: [["tx", "ty", "sc", "rot"], transformPart],
  pos: [["pos", "ins", "sticky", "rel"], positionPart],
  op: [["op"], (cs, fs, p) => { if (cs.opacity !== undefined && cs.opacity !== "1") p.op = parseFloat(cs.opacity); }],
  w: [["w"], (cs, fs, p) => set1("w", num(cs.width, fs), p)],
  h: [["h"], (cs, fs, p) => set1("h", num(cs.height, fs), p)],
  bg: [["bg"], (cs, fs, p) => backgroundPart(cs, p)],
};
const PART_OF = {
  transform: "tr", translate: "tr", scale: "tr", rotate: "tr",
  position: "pos", top: "pos", right: "pos", bottom: "pos", left: "pos",
  opacity: "op", width: "w", height: "h", background: "bg",
};

// Computed styles made from a shared one plus an inline style (style()):
// cs → { base, parts } (null parts: something else changed).
export const derived = internalWeak(new WeakMap());

// Text properties (shared: callers copy them).
function textProps(cs, fs) {
  return memoized(cs, `t${fs}`, () => makeTextProps(cs, fs));
}

function makeTextProps(cs, fs) {
  const p = {};
  p.col = color(cs.color) || [0, 0, 0, 1];
  p.fz = fs;
  p.fwt = weight(cs["font-weight"]);
  if (cs["font-style"] === "italic") p.it = true;
  if (/mono/.test(cs["font-family"] || "")) p.mono = true;
  const ff = familyOf(cs);
  if (ff) p.ff = ff;
  const lh = cs["line-height"];
  if (lh && lh !== "normal") p.lh = lineHeightPx(lh, fs);
  const ta = cs["text-align"];
  if (ta && ta !== "start" && ta !== "left") p.ta = ta === "end" ? "right" : ta;
  const ws = cs["white-space"];
  if (ws === "nowrap" || ws === "pre" || (cs.__maxc && (!ws || ws === "normal"))) p.nowrap = true;
  if (cs.__maxc) p.mc = true;
  else if (cs.__fitc) p.fc = true;
  if (cs["letter-spacing"] && cs["letter-spacing"] !== "normal") p.ls = length(cs["letter-spacing"], fs, false) ?? undefined;
  return p;
}

function weight(w) {
  if (!w || w === "normal") return 400;
  if (w === "bold" || w === "bolder") return 700;
  if (w === "lighter") return 300;
  return parseInt(w, 10) || 400;
}

// A text run's style (shared: callers copy it).
// A list item's marker text (outside markers only), or null: its
// list-style-type, and for numbers its place among its
// list's items (start, value, reversed), as browsers count them.
function listMarker(el, cs) {
  const type = cs["list-style-type"], position = cs["list-style-position"];
  if (!type || type === "none" || position === "inside") return null;
  const bullet = { disc: "\u2022", circle: "\u25e6", square: "\u25aa" }[type];
  if (bullet) return bullet + " ";
  const list = el.parentNode;
  const items = list ? [...list.children].filter((c) => c.localName === "li") : [el];
  const reversed = list?.localName === "ol" && list.hasAttribute("reversed");
  const start = list?.localName === "ol" && list.hasAttribute("start") ? parseInt(list.getAttribute("start"), 10) : NaN;
  let n = Number.isFinite(start) ? start : reversed ? items.length : 1;
  for (const li of items) {
    const v = parseInt(li.getAttribute("value"), 10);
    if (Number.isFinite(v)) n = v;
    if (li === el) break;
    n += reversed ? -1 : 1;
  }
  return counterText(n, type) + ". ";
}

function counterText(n, type) {
  const alpha = (k, a) => { let s = ""; for (; k > 0; k = Math.floor((k - 1) / 26)) s = String.fromCharCode(a + ((k - 1) % 26)) + s; return s; };
  const roman = (k) => {
    if (k <= 0 || k >= 4000) return String(k);
    let s = "";
    for (const [v, r] of [[1000, "m"], [900, "cm"], [500, "d"], [400, "cd"], [100, "c"], [90, "xc"], [50, "l"], [40, "xl"], [10, "x"], [9, "ix"], [5, "v"], [4, "iv"], [1, "i"]]) for (; k >= v; k -= v) s += r;
    return s;
  };
  switch (type) {
    case "lower-alpha": case "lower-latin": return n > 0 ? alpha(n, 97) : String(n);
    case "upper-alpha": case "upper-latin": return n > 0 ? alpha(n, 65) : String(n);
    case "lower-roman": return roman(n);
    case "upper-roman": return roman(n).toUpperCase();
    case "decimal-leading-zero": return (n >= 0 && n < 10 ? "0" : "") + n;
    default: return String(n);
  }
}

function runStyle(cs, fs) {
  return memoized(cs, `r${fs}`, () => makeRunStyle(cs, fs));
}

// The font-family list for the backend (Pango and fontconfig, like the
// WebView, resolve CSS's generic and system names: system-ui, monospace),
// unquoted, comma-separated. Form controls are in the
// platform's control font (UA_CSS: -webkit-small-control, system-ui).
// Always sent. "default" (a CSS keyword, never a family's name): the page
// sets none, and the backend uses its WebView's default face (WebKitGTK's
// is sans-serif; Chromium's and WKWebView's, Times), not "serif" itself.
function familyOf(cs) {
  const f = cs["font-family"];
  if (!f) return "default";
  const list = splitTop(f, ",").map((x) => x.trim().replace(/^["']|["']$/g, "")).filter(Boolean);
  return list.length ? list.join(", ") : "default";
}

function makeRunStyle(cs, fs) {
  const r = { c: color(cs.color) || [0, 0, 0, 1], sz: fs, w: weight(cs["font-weight"]) };
  if (cs["font-style"] === "italic") r.i = true;
  if (/mono/.test(cs["font-family"] || "")) r.mono = true;
  const ff = familyOf(cs);
  if (ff) r.ff = ff;
  if (underlined(cs)) r.u = true;
  // Its own line-height (a unitless one is its font size's: a 28px span
  // in a line-height: 1.5 paragraph is 42px tall), for the line it's on.
  const lh = cs["line-height"];
  if (lh && lh !== "normal") r.lh = lineHeightPx(lh, fs);
  return r;
}

// A text run. `bg`: the background of the inline elements it is in (a
// <mark>, a highlighted <span>), painted behind its glyphs; never the box
// that holds the text, which paints its own (a run's band would spill out
// of a line box shorter than the font).
// text-decoration: underline (it isn't inherited, but it decorates the
// text of the inline content inside).
const underlined = (cs) => /\bunderline\b/.test(cs["text-decoration-line"] || "");

// An inline box's decoration for its runs (docs: "Inline boxes"): `k` tells
// one box from a like one next to it; padding, border widths and margins
// [top, right, bottom, left] in px, one border color (the top's, or the
// first side's that has one), circular corner radii in px, and its
// background. Horizontal padding, border and margin take room in the line;
// the backend draws the box over each line fragment (box-decoration-break:
// slice: the start side on the first fragment, the end side on the last).
// (k stays an element's across renders: a changed one would remeasure the text.)
const inlineBoxKeys = internalWeak(new WeakMap());
let inlineBoxKey = 0;
function inlineBox(el, cs, fs, bg) {
  let k = inlineBoxKeys.get(el);
  if (k === undefined) inlineBoxKeys.set(el, (k = ++inlineBoxKey));
  const sides = ["top", "right", "bottom", "left"];
  const px = (v) => { const n = num(v || "0", fs); return typeof n === "number" && n > 0 ? n : 0; };
  const shown = (side) => { const st = cs[`border-${side}-style`]; return st && st !== "none" && st !== "hidden"; };
  const ib = { k, p: sides.map((d) => px(cs[`padding-${d}`])), m: [0, px(cs["margin-right"]), 0, px(cs["margin-left"])] };
  const bw = sides.map((d) => (shown(d) ? snapBorder(px(cs[`border-${d}-width`] ?? "medium")) : 0));
  if (bw.some((w) => w > 0)) {
    ib.bw = bw;
    const side = sides.find((d, i) => bw[i] > 0);
    ib.bc = color(cs[`border-${side}-color`] || "currentcolor", color(cs.color)) || [0, 0, 0, 1];
  }
  const br = ["top-left", "top-right", "bottom-right", "bottom-left"].map((c) => px(splitSpaces(cs[`border-${c}-radius`] || "0")[0]));
  if (br.some((r) => r > 0)) ib.br = br;
  if (bg && bg[3] > 0) ib.bg = bg;
  return ib;
}

function runFor(text, cs, fs, src, bg) {
  let t = text;
  const tt = cs["text-transform"];
  if (tt === "uppercase") t = t.toUpperCase();
  else if (tt === "lowercase") t = t.toLowerCase();
  const r = { t, ...runStyle(cs, fs), ws: cs["white-space"] || "normal" };
  if (bg) r.bg = bg;
  if (src) Object.defineProperty(r, "src", { value: src, enumerable: false });
  return r;
}

// Collapse whitespace like HTML (except in pre / pre-wrap) and drop empty runs.
// `keepStart`, `keepEnd`: an inline box comes before / after these runs on
// the same line: a space there stays (collapsed to one).
// A row of inline content (text and inline boxes): its text split at its
// <br>s into pieces with a break between them ({ brk }), in place; none at
// the very end (a last <br> starts no line). True when there was one.
function splitBreaks(flow) {
  let found = false;
  const out = [];
  for (const item of flow) {
    if (!item.text || !item.text.some((r) => r.t === "\n")) { out.push(item); continue; }
    found = true;
    let piece = [];
    for (const r of item.text) {
      if (r.t !== "\n") { piece.push(r); continue; }
      if (piece.length) out.push({ text: piece });
      out.push({ brk: true });
      piece = [];
    }
    if (piece.length) out.push({ text: piece });
  }
  while (out.length && out[out.length - 1].brk) out.pop();
  flow.length = 0;
  flow.push(...out);
  return found;
}

function trimRuns(runs, _ws, keepStart = false, keepEnd = false) {
  const out = [];
  let lastSpace = !keepStart;
  let brAt = -1; // the last <br>'s run in out
  for (const r of runs) {
    let t = r.t;
    // A <br>: the line ends there (a space before it goes, as browsers
    // hang it; spaces after it start no line).
    if (r.br) {
      const prev = out[out.length - 1];
      if (prev && prev.ws === undefined && prev.t.endsWith(" ")) {
        prev.t = prev.t.slice(0, -1);
        if (!prev.t) out.pop();
      }
      r.br = undefined;
      brAt = out.length;
      out.push(strip(r, "\n"));
      lastSpace = true;
      continue;
    }
    if (r.ws === "pre" || r.ws === "pre-wrap" || r.ws === "pre-line") {
      if (t) { out.push(strip(r, t)); lastSpace = /\s$/.test(t); }
      continue;
    }
    t = t.replace(/\s+/g, " ");
    if (lastSpace) t = t.replace(/^ /, "");
    if (!t) continue;
    lastSpace = t.endsWith(" ");
    out.push(strip(r, t));
  }
  // Only a space (between two boxes): the row of boxes spaces them itself.
  if ((keepStart || keepEnd) && out.every((r) => !r.t.trim() && r.ws === undefined)) return [];
  // A <br> that ends the content starts no line.
  if (!keepEnd && brAt === out.length - 1) out.pop();
  if (out.length && !keepEnd) {
    const last = out[out.length - 1];
    if (last.ws !== "pre" && last.ws !== "pre-wrap") last.t = last.t.replace(/ $/, "");
    if (!last.t) out.pop();
  }
  return out;
}

function strip(r, t) {
  // These runs belong to this traversal; the style cache holds only
  // their font/paint values. Finish them without a second allocation.
  r.ws = undefined;
  r.t = t;
  return r;
}

// Layout consumes these defaults when a property is absent. Keep them
// while flattening (parents inspect fd/ai), omit them on the wire.
function encodeProps(props) {
  if (props.fd === "column") props.fd = undefined;
  if (props.ai === "stretch") props.ai = undefined;
  return JSON.stringify(props);
}

// (A lone UTF-16 surrogate, text cut inside an emoji, comes out of
// JSON.stringify as an escape std.json rejects: the tree makes it U+FFFD,
// tree.wellFormedEscapes, where scanning costs little.)

// A minmax()'s first argument, with any commas inside its own
// parentheses (minmax(min(8em, 30%), 1fr) → "min(8em, 30%)"); null without one.
function minmaxMin(track) {
  const at = track.indexOf("minmax(");
  if (at < 0) return null;
  let depth = 0;
  for (let i = at + 7; i < track.length; i++) {
    const ch = track[i];
    if (ch === "(") depth++;
    else if (ch === ")") { if (depth === 0) return null; depth--; }
    else if (ch === "," && depth === 0) return track.slice(at + 7, i).trim();
  }
  return null;
}

// display: grid → rows of flex items (the column count from the template
// and, for auto-fit, the container's last width).
function gridToRows(cs, props, kids, nodes, renderer, el, fs) {
  // The grid's align-items, for each row (a label centered beside a
  // taller textarea, as browsers align grid items in their row).
  const ALIGN = { center: "center", start: "flex-start", "flex-start": "flex-start", "self-start": "flex-start", end: "flex-end", "flex-end": "flex-end", "self-end": "flex-end", baseline: "baseline", "first baseline": "baseline" };
  const rowAlign = props.ai === "center" ? "center" : ALIGN[cs["align-items"]] || "stretch";
  const tpl = cs["grid-template-columns"];
  if (!tpl || tpl === "none") return; // one column: a flex column with gaps
  let cols = [];
  const rep = /^repeat\(\s*([^,]+),\s*(.*)\)$/.exec(tpl.trim());
  if (rep) {
    const what = rep[2].trim();
    if (/^auto-(fit|fill)$/.test(rep[1].trim())) {
      renderer.volatile.add(el); // its column count follows its laid-out width
      // The columns share the content box: the frame less padding and borders.
      const frameW = renderer.host.frame(renderer.idOf(el, "el"))?.[2] || 0;
      const pad = props.pad || [0, 0, 0, 0], bw = props.bw || [0, 0, 0, 0];
      const width = frameW ? Math.max(0, frameW - (+pad[1] || 0) - (+pad[3] || 0) - (+bw[1] || 0) - (+bw[3] || 0)) : 0;
      const minW = (() => {
        // minmax(min(8em, 30%), 1fr): the first argument whole (its own
        // commas inside parentheses), its percentages of the content width.
        const track = minmaxMin(what) ?? what;
        const l = length(width ? track.replace(/(-?[\d.]+)%/g, (_, n) => `${(n * width) / 100}px`) : track, fs, false);
        return typeof l === "number" ? l : 120;
      })();
      const gap = props.cg || 0;
      const n = width ? Math.max(1, Math.floor((width + gap) / (minW + gap))) : Math.min(kids.length, 3);
      cols = Array(Math.max(1, Math.min(n, Math.max(kids.length, 1)))).fill("1fr");
    } else {
      cols = Array(parseInt(rep[1], 10) || 1).fill(what);
    }
  } else {
    cols = splitSpaces(tpl);
  }
  if (cols.length <= 1) return;
  const rows = [];
  const flat = kids.slice();
  kids.length = 0;
  for (let i = 0; i < flat.length; i += cols.length) {
    const rowId = renderer.idOf(el, "row" + i);
    const rowKids = flat.slice(i, i + cols.length);
    rowKids.forEach((kid, j) => {
      const n = nodes.get(kid);
      if (!n) return;
      const c = cols[j];
      if (/fr$|minmax/.test(c)) { n.props.fg = parseFloat(/([\d.]+)fr/.exec(c)?.[1] || "1"); n.props.fb = 0; n.props.minw ??= 0; }
      else if (c === "auto" || c === "min-content" || c === "max-content") { n.props.fs = 0; }
      else { const l = length(c, fs, false); if (typeof l === "number") { n.props.w = l; n.props.fs = 0; } }
    });
    // A partial last row keeps its cells the same width.
    for (let j = rowKids.length; j < cols.length && /fr$|minmax/.test(cols[j]); j++) {
      const filler = renderer.idOf(el, `fill${i}-${j}`);
      renderer.put0(nodes, filler, { kind: "view", props: { fg: 1, fb: 0 }, kids: [] });
      rowKids.push(filler);
    }
    renderer.put0(nodes, rowId, { kind: "view", props: { fd: "row", ai: rowAlign, cg: props.cg, ...(props.cg ? {} : {}) }, kids: rowKids });
    rows.push(rowId);
  }
  props.fd = "column";
  props.ai = "stretch";
  kids.push(...rows);
}

// A plain number, also from calc() (`scale(calc(1 + 0.4 * .18))`, its
// var()s already substituted).
function numberOf(v) {
  if (v === undefined || v === null) return NaN;
  const t = String(v).trim().replace(/calc\(/g, "(");
  if (/^[\d.+\-*/()\s]+$/.test(t)) return arithmetic(t);
  return parseFloat(t);
}

// + - * / and parentheses over plain numbers (a calc() of numbers), or NaN.
// Parsed here, not compiled (the app's CSP may refuse the page's eval, and
// the runtime runs as the page).
export function arithmetic(src) {
  const toks = src.match(/\d*\.?\d+(?:e[+-]?\d+)?|[-+*/()]/gi) || [];
  let i = 0;
  const atom = () => {
    const t = toks[i++];
    if (t === "(") { const v = sum(); if (toks[i++] !== ")") return NaN; return v; }
    if (t === "-") return -atom();
    if (t === "+") return atom();
    return t === undefined ? NaN : parseFloat(t);
  };
  const product = () => { let v = atom(); while (toks[i] === "*" || toks[i] === "/") v = toks[i++] === "*" ? v * atom() : v / atom(); return v; };
  const sum = () => { let v = product(); while (toks[i] === "+" || toks[i] === "-") v = toks[i++] === "+" ? v + product() : v - product(); return v; };
  const v = sum();
  return i === toks.length ? v : NaN;
}

function angleOf(v) {
  const m = /^(-?[\d.]+)(deg|turn|rad|grad)?$/.exec(String(v || "").trim());
  if (!m) return 0;
  const n = parseFloat(m[1]);
  return m[2] === "turn" ? n * 360 : m[2] === "rad" ? (n * 180) / Math.PI : m[2] === "grad" ? n * 0.9 : n;
}

// A transform made of plain functions with px, number and angle arguments
// (an animation's translate(12.5px, 40px)): added to `out` without the
// general parse; false for anything else (calc(), em, %…), which the
// general parse handles.
const SIMPLE_FN = /\s*([a-zA-Z]+)\(([^()]*)\)\s*/y;
const PX = /^\s*(-?(?:\d+\.?\d*|\.\d+))(px)?\s*$/;
function simpleTransform(t, out, fs) {
  SIMPLE_FN.lastIndex = 0;
  while (SIMPLE_FN.lastIndex < t.length) {
    const m = SIMPLE_FN.exec(t);
    if (!m) return false;
    const args = m[2].split(",");
    const px = (i) => { const a = PX.exec(args[i]); return a && (a[2] || +a[1] === 0) ? +a[1] : null; };
    switch (m[1]) {
      case "translateX": case "translateY": case "translate": {
        if (m[1] !== "translate" && args.length !== 1) return false;
        const x = px(0), y = args.length > 1 ? px(1) : 0;
        if (x === null || y === null || args.length > 2) return false;
        if (m[1] === "translateY") out.ty += x; else { out.tx += x; out.ty += y; }
        break;
      }
      case "scale": case "scaleX": {
        const a = PX.exec(args[0]);
        if (!a || a[2] || args.length > (m[1] === "scale" ? 2 : 1)) return false;
        if (args.length === 2) { const b = PX.exec(args[1]); if (!b || b[2]) return false; }
        out.sc *= +a[1];
        break;
      }
      case "rotate": case "rotateZ":
        if (args.length !== 1) return false;
        out.rot += angleOf(args[0]);
        break;
      default: return false;
    }
  }
  return true;
}

// transform plus the translate, scale and rotate properties → { tx, ty, sc, rot }.
function transformOf(cs, fs) {
  const out = { tx: 0, ty: 0, sc: 1, rot: 0 };
  const len = (v) => { const l = length(v, fs, false); return typeof l === "number" ? l : 0; };
  const t = cs.transform;
  if (t && t !== "none" && !simpleTransform(t, out, fs)) {
    out.tx = out.ty = out.rot = 0;
    out.sc = 1;
    for (const m of t.matchAll(/([a-zA-Z]+)\(((?:[^()]|\([^()]*\))*)\)/g)) {
      const args = splitTop(m[2], ",").map((x) => x.trim());
      switch (m[1]) {
        case "translateX": out.tx += len(args[0]); break;
        case "translateY": out.ty += len(args[0]); break;
        case "translate": out.tx += len(args[0]); if (args[1]) out.ty += len(args[1]); break;
        case "scale": case "scaleX": { const n = numberOf(args[0]); if (Number.isFinite(n)) out.sc *= n; break; }
        case "rotate": case "rotateZ": out.rot += angleOf(args[0]); break;
      }
    }
  }
  if (cs.translate && cs.translate !== "none") { const a = splitSpaces(cs.translate); out.tx += len(a[0]); if (a[1]) out.ty += len(a[1]); }
  if (cs.scale && cs.scale !== "none") { const n = numberOf(splitSpaces(cs.scale)[0]); if (Number.isFinite(n)) out.sc *= n; }
  if (cs.rotate && cs.rotate !== "none") out.rot += angleOf(cs.rotate);
  return out;
}

// A keyframe's declarations → the node props they animate.
function animProps(decls, cs, fs) {
  const out = {};
  const cur = color(cs.color);
  const val = (v) => substitute(v, cs, 0);
  let transformed = null;
  for (const [prop, raw] of Object.entries(decls)) {
    const v = val(raw);
    switch (prop) {
      case "opacity": { const n = numberOf(v); if (Number.isFinite(n)) out.op = n; break; }
      case "transform": case "translate": case "scale": case "rotate":
        (transformed ||= {})[prop] = v; break;
      case "background": { const bg = background(v, cur); out.bg = bg || null; break; }
      case "color": { const c = color(v, cur); if (c) out.col = c; break; }
      case "box-shadow": out.sh = shadow(v, cur); break;
      case "width": case "height": { const l = length(v, fs, false); if (l !== null && l !== undefined) out[prop[0]] = typeof l === "object" ? `${l.pct}%` : l; break; }
    }
  }
  if (transformed) {
    const tr = transformOf(transformed, fs);
    if ("transform" in transformed || "translate" in transformed) { out.tx = tr.tx; out.ty = tr.ty; }
    if ("transform" in transformed || "scale" in transformed) out.sc = tr.sc;
    if ("transform" in transformed || "rotate" in transformed) out.rot = tr.rot;
  }
  return out;
}
