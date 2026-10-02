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

import { StyleEngine, computeStyle, parseInline, length, color, background, shadow, splitSpaces, splitTop, substitute } from "./css.js";
import { Transitions, transitionsOf } from "./transitions.js";
import { Animations, animationsOf } from "./animations.js";
import { iconFor } from "./icons.js";
import { commandsOf } from "./canvas.js";

// The user-agent stylesheet: what browsers do without CSS.
export const UA_CSS = `
html, body, div, section, main, header, footer, nav, article, aside, form, fieldset, p, ul, ol, li, dl, dt, dd,
h1, h2, h3, h4, h5, h6, pre, blockquote, figure, figcaption, details, summary, address, hr { display: block; }
head, script, style, template, title, meta, link, noscript, datalist, option, [hidden] { display: none; }
li { display: list-item; }
button, input, textarea, select, img, svg, canvas, progress, meter { display: inline-block; }
button { padding: 1px 6px; border: 1px solid #767676; border-radius: 3px; background-color: #efefef; color: black; font-size: 13.333px; }
input, textarea, select { padding: 1px 2px; border: 1px solid #767676; border-radius: 2px; background-color: white; color: black; font-size: 13.333px; }
body { margin: 8px; font-size: 16px; line-height: 1.2; color: black; }
p, ul, ol, dl, blockquote, pre, figure { margin-top: 1em; margin-bottom: 1em; }
ul, ol { padding-left: 40px; }
h1 { font-size: 2em; margin: .67em 0; font-weight: bold; }
h2 { font-size: 1.5em; margin: .83em 0; font-weight: bold; }
h3 { font-size: 1.17em; margin: 1em 0; font-weight: bold; }
h4, h5, h6 { font-weight: bold; margin: 1.33em 0; }
b, strong, th { font-weight: bold; }
i, em, cite, var, dfn { font-style: italic; }
small { font-size: .83em; }
code, kbd, samp, pre, tt { font-family: monospace; }
pre { white-space: pre; }
a { color: #0645ad; text-decoration: underline; cursor: pointer; }
button { padding: 1px 6px; border: 2px outset #ccc; background: #efefef; font-size: 13.33px; text-align: center; }
input, textarea, select { padding: 1px 2px; border: 2px inset #ccc; font-size: 13.33px; background: white; }
textarea { white-space: pre-wrap; }
hr { border-top: 1px solid #888; margin: .5em 0; }
table { display: table; border-spacing: 2px; border-collapse: separate; }
thead { display: table-header-group; } tbody { display: table-row-group; } tfoot { display: table-footer-group; }
tr { display: table-row; } td, th { display: table-cell; padding: 1px; vertical-align: middle; }
th { text-align: center; } caption { display: table-caption; text-align: center; }
col, colgroup { display: none; }
`;

const INLINE_DISPLAY = new Set(["inline"]);
const ATOMIC_INLINE = new Set(["inline-block", "inline-flex", "inline-grid"]);
const SKIP = new Set(["script", "style", "head", "template", "title", "meta", "link", "noscript"]);

export class Renderer {
  constructor(document, engine, host) {
    this.doc = document;
    this.engine = engine;
    this.host = host;
    this.ids = new WeakMap();      // element / text node → id
    this.owner = new Map();        // id → the element it stands for (events)
    this.prev = new Map();         // id → { kind, props json, kids json }
    this.tx = new Transitions();   // CSS transitions in progress
    this.specs = new Map();        // id → its element's transitions (this frame)
    this.anim = new Animations();  // @keyframes animations playing
    this.animSpecs = new Map();    // id → its element's animations (this frame)
    this.ticking = false;
    this.nextId = 1;
    this.dirty = true;
    this.native = new Map();       // id → value the native field holds (inputs)
    this.cs = new WeakMap();       // element → computed style of the last frame
    // Incremental rendering: what changed since the last frame (marks, from
    // the mutation records and style writes), and what each element made
    // then, reused while nothing in it or above it changed.
    this.marks = new Map();        // element → 1 (its inline style changed) | 2 (match its rules again)
    this.flatMarks = new Set();    // nodes whose own output changed (text, children, a canvas…)
    this.full = true;              // everything again (first frame, the viewport changed)
    this.sc = new WeakMap();       // element → { parent cs, cs, matched rules, frame }
    this.fc = new WeakMap();       // element → what it made (element(), below)
    this.parentOf = new WeakMap(); // node → the element it was last flattened in (removals)
    this.volatile = new Set();     // elements whose output can change without a mutation (fields…)
    this.shared = new WeakMap();   // parent cs → Map(specified → cs): siblings with the same rules share one
    this.cascades = new Map();     // matched rules → { normal, important } longhands
    this.frameNo = 0;
    this.cur = null;               // the element being made: { own ids, kids, fixed ids }
    this.gone = [];                // ids to destroy this frame
    this.dropped = [];             // [element, what it made]: gone unless made again this frame
    this.structural = false;       // the sheets match by position (:nth-child, +, ~…)
    this.noCache = false;          // the sheets use :has(): any change can restyle anything
    for (const r of engine.rules) {
      if (/:(nth-|first-|last-|only-|empty)|[+~]/.test(r.sel)) this.structural = true;
      if (/:has\(/.test(r.sel)) this.noCache = true;
      if (/\[style[\]~|^$*=]/.test(r.sel)) this.styleAttrRules = true;
    }
  }

  // ---------------------------------------------------------------------
  // What changed

  // An element's style may have changed: 2 when its rules may match
  // differently (its attributes), 1 when only its inline style did.
  mark(el, level) {
    if (!el || el.nodeType !== 1) return;
    if ((this.marks.get(el) || 0) < level) this.marks.set(el, level);
    this.dirty = true;
  }

  // A node's output changed, not its style: its text, a canvas's program,
  // a click listener.
  markFlat(node) {
    if (!node) return;
    this.flatMarks.add(node);
    this.dirty = true;
  }

  // The viewport or the theme changed: everything again.
  markAll() {
    this.full = true;
    this.dirty = true;
  }

  // Mutation records (main.js observes the document).
  note(records) {
    for (const r of records) {
      if (r.type === "attributes") {
        const el = r.target;
        // The style attribute matters to the rules only through [style].
        this.mark(el, r.attributeName === "style" && !this.styleAttrRules ? 1 : 2);
        // Sibling combinators: the next siblings may match differently.
        if (this.structural && el.parentNode) this.mark(el.parentNode, 2);
        continue;
      }
      // childList (linkedom also reports a text node's new data as its removal).
      for (const n of r.addedNodes || []) {
        this.mark(n, 2);
        const parent = n.parentNode;
        if (parent) { this.markFlat(parent); if (this.structural) this.mark(parent, 2); }
      }
      for (const n of r.removedNodes || []) {
        const parent = n.parentNode || this.parentOf.get(n);
        if (parent) { this.markFlat(parent); if (this.structural) this.mark(parent, 2); }
        this.markFlat(n);
      }
    }
    this.dirty = true;
  }

  idOf(obj, key) {
    let m = this.ids.get(obj);
    if (!m) this.ids.set(obj, (m = {}));
    return m[key] ??= this.nextId++;
  }

  elementFor(id) {
    return this.owner.get(id) || null;
  }

  // ---------------------------------------------------------------------
  // One frame

  render() {
    // Records not delivered yet (a render from inside the page: focus()).
    const pending = this.observer?.takeRecords();
    if (pending?.length) this.note(pending);
    if (!this.dirty || this.rendering) return;
    this.dirty = false;
    this.rendering = true;
    try { this.renderNow(); } finally { this.rendering = false; }
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
    if (full) {
      this.sc = new WeakMap();
      this.fc = new WeakMap();
      this.shared = new WeakMap();
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
    const bodyNode = this.element(body, rootCS, nodes, { blockify: true, textAlign: "left" });
    const fixed = this.cur.fixed;
    this.cur = null;
    this.marks.clear();
    this.flatMarks.clear();
    this.full = false;
    // What the changed elements no longer make (or elements gone from the
    // page): destroyed, unless made again elsewhere this frame (moved).
    const goneTree = (el, f) => {
      this.gone.push(...f.own);
      this.fc.delete(el);
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
    if (bn && !this.cs.get(body)?.["flex-shrink"]) bn.props.fs = 0;
    // The window: the page scrolls, fixed elements stay over it.
    nodes.set(-1, { kind: "view", props: { scroll: true, fg: 1, fs: 1, ai: "stretch" }, kids: [bodyNode] });
    // The window's background: <html>'s, else <body>'s (a browser paints the
    // whole viewport with it, below a short page too).
    const rootBg = bgOf(rootCS) || (this.cs.get(body) ? bgOf(this.cs.get(body)) : null);
    nodes.set(0, { kind: "view", props: { root: true, fd: "column", ai: "stretch", bg: rootBg }, kids: [-1, ...fixed] });
    this.emit(nodes, full);
    // A scrollIntoView that waited for this render (main.js).
    const scroll = this.pendingScroll;
    this.pendingScroll = null;
    if (scroll && scroll.el.isConnected) this.host.scrollIntoView(this.idOf(scroll.el, "el"), scroll.block);
  }

  // An element's computed style: the last frame's while neither it nor its
  // parent's style changed. `rematch`: an ancestor's attributes changed (a
  // descendant selector may match differently).
  style(el, parentCS, rematch = false) {
    const c = this.sc.get(el);
    const mk = this.marks.get(el) || 0;
    if (c && c.parent === parentCS && (c.frame === this.frameNo || (!rematch && !mk))) return c.cs;
    const m = c && !rematch && mk < 2 ? c.m : this.engine.matching(el);
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
    if (c && c.cs !== cs && sameStyle(c.cs, cs)) cs = c.cs;
    cs.__rules = m;
    this.sc.set(el, { parent: parentCS, cs, m, frame: this.frameNo });
    this.cs.set(el, cs);
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
    derived.set(cs, { base, parts: parts && [...parts] });
    return cs;
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
    this.owner.set(id, el);
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
    if (fc && fc.parent === parentCS && fc.block === block && fc.ts === ctx.tableSpacing && !ctx.rematch && !this.flat.has(el)) {
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
    const p = n.props, cs = this.cs.get(el) || {};
    return p.fs === undefined && p.h === undefined && p.fb === undefined && p.ar === undefined && !p.scroll && !p.clip &&
      !cs["flex-shrink"] && !cs["min-height"] && p.pos !== "absolute";
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
    if (isTableDisplay(display) && !tableProps(props, display, cs, fontSize, ctx, el)) return null;
    const transitions = transitionsOf(cs);
    if (transitions) this.spec(id, transitions);
    this.noteAnimations(id, cs, fontSize);
    // A block with auto side margins fills its container (up to max-width)
    // and is centered, where a flex item would shrink to its content.
    if (!ctx.blockify && ["block", "flex", "grid", "list-item"].includes(blockify(display)) && props.w === undefined && props.pos !== "absolute" &&
        cs["margin-left"] === "auto" && cs["margin-right"] === "auto") props.w = "100%";

    // Position: fixed → in the window's overlay layer.
    let fixedNode = false;
    if (cs.position === "fixed") { props.pos = "absolute"; fixedNode = true; }

    // Replaced elements.
    if (tag === "svg") {
      // <use href="#id"> draws another element: it can change elsewhere.
      if (el.querySelector("use")) this.volatile.add(el);
      const icon = iconFor(el, cs, this.doc);
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
      this.volatile.add(el); // its program changes without a mutation
      // The bitmap's size in px (300x150 when the attributes are absent),
      // the drawing's coordinate space; the box scales it.
      props.cw = el.width;
      props.ch = el.height;
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
        else { props.w = props.cw; props.h = props.ch; }
      } else if (props.w === undefined || props.h === undefined) props.ar = ratio;
      props.fs = 0;
      // The drawing program so far (a game's last frame; static drawing
      // accumulates). Its children are the fallback content: not shown.
      const cv = commandsOf(el);
      if (cv.length) props.cv = cv;
      this.putClick(props, el);
      return this.put(nodes, id, "canvas", props, [], fixedNode);
    }
    if (tag === "input" || tag === "textarea" || tag === "select") {
      this.volatile.add(el); // its value changes without a mutation
      const type = (el.getAttribute("type") || "text").toLowerCase();
      if (tag === "input" && (type === "checkbox" || type === "radio")) {
        // The click goes to the label. With appearance: none the page's CSS
        // draws it; else the native side draws the default control, in the
        // browser's 13px box with its 3px margin, in accent-color when checked.
        props.click = true;
        const app = cs.appearance || cs["-webkit-appearance"];
        if (app !== "none") {
          props.ctl = type;
          if (el.hasAttribute("checked")) props.on = true;
          const acc = color(cs["accent-color"] || "");
          if (acc) props.acc = acc;
          if (props.w === undefined || props.w === "auto") props.w = 13;
          if (props.h === undefined || props.h === "auto") props.h = 13;
          if (!props.m) props.m = [3, 3, 3, 3];
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
      props.pw = type === "password";
      if (tag === "textarea") {
        const cols = parseInt(el.getAttribute("cols") || "", 10);
        props.cols = cols > 0 ? Math.min(cols, 1000) : 20;
      }
      // A slider: the native side draws one (SeekBar), the value as text.
      if (type === "range") {
        const n = (a, d) => { const v = parseFloat(el.getAttribute(a)); return Number.isFinite(v) ? v : d; };
        props.range = [n("min", 0), n("max", 100), el.getAttribute("step") === "any" ? 0 : n("step", 1)];
        if (props.h === undefined || props.h === "auto") props.h = 24;
        const acc = color(cs["accent-color"] || "");
        if (acc) props.acc = acc;
        delete props.pad; delete props.bw; delete props.bc; delete props.bg; delete props.br;
      }
      return this.put(nodes, id, tag === "textarea" ? "textarea" : "input", props, [], fixedNode);
    }

    // Children: blocks, and inline content collected into text runs.
    const childCtx = { blockify: display === "flex" || display === "grid" || tableHolds(display), parentText: cs["text-align"],
      tableSpacing: tableSpacingFor(display, props, ctx), rematch };
    const kids = [];
    let orders = null; // CSS order of the element children that set one
    const before = this.pseudo(el, cs, "before", nodes);
    if (before) kids.push(before);
    const flow = [];
    let runs = [];
    const flushRuns = () => {
      if (!runs.length) return;
      const trimmed = trimRuns(runs, cs["white-space"]);
      runs = [];
      if (!trimmed.length) return;
      flow.push({ text: trimmed });
    };
    for (const child of el.childNodes) {
      this.parentOf.set(child, el);
      if (child.nodeType === 3) {
        const t = child.data;
        if (t) runs.push(runFor(t, cs, fontSize));
        continue;
      }
      if (child.nodeType !== 1) continue;
      if (!childCtx.blockify && this.isInline(child, cs, rematch)) {
        this.inlineRuns(child, cs, fontSize, runs, rematch);
        continue;
      }
      flushRuns();
      flow.push({ el: child });
    }
    flushRuns();

    // An element holding only text becomes one text view, unless it centers
    // that text as a flex/grid box (a round icon button: ⚙ in a 28px circle):
    // a text view is drawn from its top-left, so keep a box with a text child.
    const aligns = (display === "flex" || display === "grid" || display === "inline-flex" || display === "inline-grid") &&
      (["center", "end", "flex-end"].includes(cs["align-items"]) || ["center", "end", "flex-end", "space-around", "space-evenly"].includes(cs["justify-content"]));
    if (flow.length === 1 && flow[0].text && !before && !cs.__rules.after.length && !aligns) {
      Object.assign(props, textProps(cs, fontSize));
      props.runs = flow[0].text;
      this.putClick(props, el);
      return this.put(nodes, id, "text", props, [], fixedNode);
    }

    // A line of inline content with an atomic box in it (a checkbox and its
    // label's text): a row that wraps, as an inline formatting context lays
    // it out, not a column (the text went under the box).
    const inlineLine = !childCtx.blockify && props.fd === "column" && flow.some((f) => f.text) && flow.some((f) => f.el) &&
      flow.every((f) => f.text || ATOMIC_INLINE.has(this.style(f.el, cs).display || ""));
    if (inlineLine) { props.fd = "row"; props.fw = "wrap"; props.ai = "center"; }

    for (const item of flow) {
      if (item.text) {
        const tid = this.idOf(el, "t" + kids.length);
        this.own(tid, el);
        const tp = { ...textProps(cs, fontSize), runs: item.text };
        if (transitions) this.spec(tid, transitions);
        tp.fs = (childCtx.blockify || inlineLine) && !props.scroll ? 1 : 0;
        this.put(nodes, tid, "text", tp, []);
        kids.push(tid);
        continue;
      }
      const cid = this.element(item.el, cs, nodes, childCtx);
      if (cid === null) continue;
      // Block layout: children keep their size (a flex column would shrink them).
      if (!childCtx.blockify) { const n = nodes.get(cid); if (n && n.props.fs === undefined) n.props.fs = 0; }
      // A scroll container's children keep their size too: CSS's min-size:
      // auto, which Yoga doesn't have (it would squeeze them to fit, and
      // there would be nothing to scroll).
      else if ((props.scroll || props.scrollx) && !this.cs.get(item.el)?.["flex-shrink"]) { const n = nodes.get(cid); if (n) n.props.fs = 0; }
      // A column whose height isn't definite (no height, not flexed itself:
      // min-height at most): CSS sizes a percentage flex-basis (`flex: 1`
      // is 1 1 0%) from the content, and min-height: auto keeps the item
      // from shrinking below it, so the column grows and the page scrolls.
      // Yoga would squeeze the item into the min-height instead.
      // A column item sized by its content (no height or basis, overflow
      // visible) doesn't shrink below it either: min-height: auto. The
      // column overflows instead, as in a browser.
      else if (props.fd === "column" && this.keepsContentHeight(item.el, nodes.get(cid))) nodes.get(cid).props.fs = 0;
      else if (props.fd === "column" && props.h === undefined && props.fg === undefined && !props.scroll && /flex$/.test(display)) {
        const n = nodes.get(cid);
        if (n && typeof n.props.fb === "string" && n.props.fb.endsWith("%") && !n.props.scroll && !n.props.clip) {
          delete n.props.fb;
          n.props.fs = 0;
        }
      }
      // An inline box (button, chip) in a block: as wide as its content, placed by text-align.
      if (!childCtx.blockify) {
        const n = nodes.get(cid);
        const d = this.cs.get(item.el)?.display || "inline";
        if (n && (ATOMIC_INLINE.has(d) || INLINE_DISPLAY.has(d)) && !n.props.as && n.props.pos !== "absolute") {
          n.props.as = alignFor(cs["text-align"]);
        }
      }
      kids.push(cid);
      const ord = parseInt(this.cs.get(item.el)?.order, 10);
      if (ord) (orders ??= new Map()).set(cid, ord);
    }
    const after = this.pseudo(el, cs, "after", nodes);
    if (after) kids.push(after);
    // CSS order: flex/grid items laid out by it, then by source order.
    if (orders && childCtx.blockify) {
      const pos = new Map(kids.map((k, i) => [k, i]));
      kids.sort((a, b) => (orders.get(a) || 0) - (orders.get(b) || 0) || pos.get(a) - pos.get(b));
    }

    if (display === "grid") gridToRows(cs, props, kids, nodes, this, el, fontSize);
    this.putClick(props, el);
    return this.put(nodes, id, "view", props, kids, fixedNode);
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
    for (const c of el.children) if (!this.isInline(c, cs, deeper)) return false;
    return true;
  }

  inlineRuns(el, parentCS, parentFs, runs, rematch = false) {
    if (SKIP.has(el.localName)) return;
    const cs = this.style(el, parentCS, rematch);
    if ((cs.display || "inline") === "none") return;
    const fs = fontSizeOf(cs, parentCS);
    cs.__fs = fs;
    if (el.localName === "br") { runs.push({ t: "\n", ...runStyle(cs, fs) }); return; }
    const deeper = rematch || this.marks.get(el) === 2;
    for (const child of el.childNodes) {
      this.parentOf.set(child, el);
      if (child.nodeType === 3) runs.push(runFor(child.data, cs, fs, el));
      else if (child.nodeType === 1) this.inlineRuns(child, cs, fs, runs, deeper);
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

  // `nodes`: what was made this frame; `full`: everything was (else the
  // ids in this.gone are what went away).
  emit(nodes, full) {
    const ops = []; // each op's JSON: the props are encoded once, for the diff and the ops

    const now = Date.now();
    // Nodes made again (a new kind): their parents must attach them again.
    const remade = new Set();
    for (const [id, n] of nodes) {
      const old = this.prev.get(id);
      if (old && old.kind !== n.kind) remade.add(id);
    }
    for (const [id, n] of nodes) {
      const old = this.prev.get(id);
      if (!old || old.kind !== n.kind) this.tx.forget(id);
      // The props to show now: the page's, or on the way to them (transitions).
      const shown = this.anim.apply(id, this.tx.apply(id, n.props, this.specs.get(id) || null, now), this.animSpecs.get(id) || null, now);
      const p = JSON.stringify(shown);
      const k = JSON.stringify(n.kids);
      if (!old || old.kind !== n.kind) {
        if (old) ops.push(`["d",${id}]`);
        ops.push(`["c",${id},${JSON.stringify(n.kind)}]`, `["p",${id},${p}]`, `["k",${id},${k}]`);
      } else {
        if (old.p !== p) ops.push(`["p",${id},${p}]`);
        if (old.k !== k || n.kids.some((c) => remade.has(c))) ops.push(`["k",${id},${k}]`);
      }
      this.prev.set(id, { kind: n.kind, p, k });
      if (n.props.val !== undefined) this.native.set(id, n.props.val);
    }
    const drop = (id) => {
      if (!this.prev.has(id) || nodes.has(id)) return;
      ops.push(`["d",${id}]`); this.prev.delete(id); this.native.delete(id); this.tx.forget(id); this.anim.forget(id); this.owner.delete(id);
    };
    if (full) { for (const id of [...this.prev.keys()]) drop(id); }
    else for (const id of this.gone) drop(id);
    if (!this.rootSent) { ops.push(`["r",0]`); this.rootSent = true; }
    if (ops.length) this.host.ops(`[${ops.join(",")}]`);
    this.schedule();
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
      const p = JSON.stringify(shown);
      if (p !== prev.p) { ops.push(["p", id, shown]); prev.p = p; }
    }
    if (ops.length) this.host.ops(JSON.stringify(ops));
    this.schedule();
  }
}

// Two computed styles with the same values (the bookkeeping keys aside).
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

function fontSizeOf(cs, parentCS) {
  const pfs = parentCS?.__fs ?? 16;
  const v = cs["font-size"];
  if (!v) return pfs;
  if (v.endsWith("em") && !v.endsWith("rem")) return parseFloat(v) * pfs;
  if (v.endsWith("%")) return parseFloat(v) / 100 * pfs;
  const map = { small: 13, medium: 16, large: 18, "x-large": 24, smaller: pfs * 0.83, larger: pfs * 1.2 };
  if (map[v]) return map[v];
  const l = length(v, pfs, false);
  return typeof l === "number" ? l : pfs;
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
const memo = new WeakMap();
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
  const key = `b${display}|${fs}|${button}`;
  const d = derived.get(cs);
  if (d?.parts) {
    const p = { ...memoized(d.base, key, () => makeBoxProps(d.base, display, fs, button)) };
    for (const part of d.parts) {
      const [keys, make] = PARTS[part];
      for (const k of keys) delete p[k];
      make(cs, fs, p);
    }
    return p;
  }
  return { ...memoized(cs, key, () => makeBoxProps(cs, display, fs, button)) };
}

function makeBoxProps(cs, display, fs, button) {
  const p = {};
  if (display === "inline-flex") display = "flex";
  if (display === "inline-grid") display = "grid";
  const set = (k, v) => { if (v !== undefined && v !== null) p[k] = typeof v === "object" ? `${v.pct}%` : v; };
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
  const bw = sides.map((s) => { const l = num(cs[`border-${s}-width`], fs); return typeof l === "number" ? l : (cs[`border-${s}-width`] === "thin" ? 1 : cs[`border-${s}-width`] === "medium" ? 3 : 0); });
  if (bw.some((x) => x)) {
    p.bw = bw;
    const cur = color(cs.color);
    p.bc = sides.map((s) => color(cs[`border-${s}-color`] || "currentcolor", cur) || [0, 0, 0, 0]);
  }
  const rg = num(cs["row-gap"], fs), cg = num(cs["column-gap"], fs);
  if (typeof rg === "number" && rg) p.rg = rg;
  if (typeof cg === "number" && cg) p.cg = cg;
  positionPart(cs, fs, p);
  const ov = cs["overflow-y"] || cs.overflow;
  if (ov === "auto" || ov === "scroll") p.scroll = true;
  const ovx = cs["overflow-x"];
  if (ovx === "auto" || ovx === "scroll") p.scrollx = true;
  if (cs["overflow-x"] === "hidden" || cs["overflow-y"] === "hidden" || cs.overflow === "hidden") p.clip = true;
  if (cs["aspect-ratio"]) p.ar = parseFloat(cs["aspect-ratio"]);
  transformPart(cs, fs, p);
  // Drawing
  const cur = color(cs.color);
  backgroundPart(cs, p);
  const r = ["top-left", "top-right", "bottom-right", "bottom-left"].map((c) => {
    const v = cs[`border-${c}-radius`];
    if (!v) return 0;
    if (v.endsWith("%")) return { pct: parseFloat(v) };
    return length(v, fs, false) ?? 0;
  });
  if (r.some((x) => x)) p.br = r.map((x) => (typeof x === "object" ? `${x.pct}%` : Math.min(x, 9999)));
  if (cs.opacity !== undefined && cs.opacity !== "1") p.op = parseFloat(cs.opacity);
  const sh = shadow(cs["box-shadow"], cur);
  if (sh) p.sh = sh;
  if (cs.visibility === "hidden") p.vis = false;
  if (cs.cursor === "pointer") p.click = true;
  if (cs["z-index"] && cs["z-index"] !== "auto") p.z = parseInt(cs["z-index"], 10);
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
function transformPart(cs, fs, p) {
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
const set1 = (k, v, p) => { if (v !== undefined && v !== null) p[k] = typeof v === "object" ? `${v.pct}%` : v; };
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
export const derived = new WeakMap();

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
  const lh = cs["line-height"];
  if (lh && lh !== "normal") p.lh = /^[\d.]+$/.test(lh) ? parseFloat(lh) * fs : length(lh, fs, false) ?? undefined;
  const ta = cs["text-align"];
  if (ta && ta !== "start" && ta !== "left") p.ta = ta === "end" ? "right" : ta;
  const ws = cs["white-space"];
  if (ws === "nowrap" || ws === "pre") p.nowrap = true;
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
function runStyle(cs, fs) {
  return memoized(cs, `r${fs}`, () => makeRunStyle(cs, fs));
}

function makeRunStyle(cs, fs) {
  const r = { c: color(cs.color) || [0, 0, 0, 1], sz: fs, w: weight(cs["font-weight"]) };
  if (cs["font-style"] === "italic") r.i = true;
  if (/mono/.test(cs["font-family"] || "")) r.mono = true;
  if ((cs["text-decoration-line"] || "") === "underline") r.u = true;
  const bg = background(cs.background, r.c);
  if (bg?.color) r.bg = bg.color;
  return r;
}

function runFor(text, cs, fs, src) {
  let t = text;
  const tt = cs["text-transform"];
  if (tt === "uppercase") t = t.toUpperCase();
  else if (tt === "lowercase") t = t.toLowerCase();
  const r = { t, ...runStyle(cs, fs), ws: cs["white-space"] || "normal" };
  if (src) Object.defineProperty(r, "src", { value: src, enumerable: false });
  return r;
}

// Collapse whitespace like HTML (except in pre / pre-wrap) and drop empty runs.
function trimRuns(runs) {
  const out = [];
  let lastSpace = true;
  for (const r of runs) {
    let t = r.t;
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
  if (out.length) {
    const last = out[out.length - 1];
    if (last.ws !== "pre" && last.ws !== "pre-wrap") last.t = last.t.replace(/ $/, "");
    if (!last.t) out.pop();
  }
  return out;
}

function strip(r, t) {
  const { ws, ...rest } = r;
  return { ...rest, t };
}

// display: grid → rows of flex items (the column count from the template
// and, for auto-fit, the container's last width).
function gridToRows(cs, props, kids, nodes, renderer, el, fs) {
  const tpl = cs["grid-template-columns"];
  if (!tpl || tpl === "none") return; // one column: a flex column with gaps
  let cols = [];
  const rep = /^repeat\(\s*([^,]+),\s*(.*)\)$/.exec(tpl.trim());
  if (rep) {
    const what = rep[2].trim();
    if (/^auto-(fit|fill)$/.test(rep[1].trim())) {
      const minW = (() => {
        const mm = /minmax\(\s*([^,]+(?:\([^)]*\))?)\s*,/.exec(what);
        const l = length(mm ? mm[1] : what, fs, false);
        return typeof l === "number" ? l : 120;
      })();
      renderer.volatile.add(el); // its column count follows its laid-out width
      const width = renderer.host.frame(renderer.idOf(el, "el"))?.[2] || 0;
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
    renderer.put0(nodes, rowId, { kind: "view", props: { fd: "row", ai: props.ai === "center" ? "center" : "stretch", cg: props.cg, ...(props.cg ? {} : {}) }, kids: rowKids });
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
  if (/^[\d.+\-*/()\s]+$/.test(t)) { try { return +Function(`return (${t})`)(); } catch { return NaN; } }
  return parseFloat(t);
}

function angleOf(v) {
  const m = /^(-?[\d.]+)(deg|turn|rad|grad)?$/.exec(String(v || "").trim());
  if (!m) return 0;
  const n = parseFloat(m[1]);
  return m[2] === "turn" ? n * 360 : m[2] === "rad" ? (n * 180) / Math.PI : m[2] === "grad" ? n * 0.9 : n;
}

// transform plus the translate, scale and rotate properties → { tx, ty, sc, rot }.
function transformOf(cs, fs) {
  const out = { tx: 0, ty: 0, sc: 1, rot: 0 };
  const len = (v) => { const l = length(v, fs, false); return typeof l === "number" ? l : 0; };
  const t = cs.transform;
  if (t && t !== "none") {
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
