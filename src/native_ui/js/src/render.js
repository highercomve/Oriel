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

// The user-agent stylesheet: what browsers do without CSS.
export const UA_CSS = `
html, body, div, section, main, header, footer, nav, article, aside, form, fieldset, p, ul, ol, li, dl, dt, dd,
h1, h2, h3, h4, h5, h6, pre, blockquote, figure, figcaption, details, summary, address, hr { display: block; }
head, script, style, template, title, meta, link, noscript, datalist, option, [hidden] { display: none; }
li { display: list-item; }
button, input, textarea, select, img, svg, progress, meter { display: inline-block; }
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
button { padding: 1px 6px; border: 2px outset #ccc; background: #efefef; font-size: 13.33px; text-align: center; align-items: center; justify-content: center; }
input, textarea, select { padding: 1px 2px; border: 2px inset #ccc; font-size: 13.33px; background: white; }
textarea { white-space: pre-wrap; }
hr { border-top: 1px solid #888; margin: .5em 0; }
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
    if (!this.dirty) return;
    this.dirty = false;
    const nodes = new Map(); // id → { kind, props, kids }
    this.specs = new Map();
    this.animSpecs = new Map();
    this.owner.clear();
    const body = this.doc.body;
    const rootCS = this.style(this.doc.documentElement, null);
    const bodyNode = this.element(body, rootCS, nodes, { blockify: true, textAlign: "left" });
    const fixed = nodes.get("fixed") || [];
    nodes.delete("fixed");
    if (!bodyNode) return;
    // The page keeps its height in the window's scroll view (see above).
    const bn = nodes.get(bodyNode);
    if (bn && !this.cs.get(body)?.["flex-shrink"]) bn.props.fs = 0;
    // The window: the page scrolls, fixed elements stay over it.
    nodes.set(-1, { kind: "view", props: { scroll: true, fg: 1, fs: 1, ai: "stretch" }, kids: [bodyNode] });
    nodes.set(0, { kind: "view", props: { root: true, fd: "column", ai: "stretch", bg: bgOf(rootCS) }, kids: [-1, ...fixed] });
    this.emit(nodes);
  }

  style(el, parentCS) {
    const m = this.engine.matching(el);
    const spec = StyleEngine.cascade(m.normal, el.hasAttribute("style") ? parseInline(el.getAttribute("style")) : null);
    const cs = computeStyle(spec, parentCS);
    cs.__rules = m;
    this.cs.set(el, cs);
    return cs;
  }

  // An element → a node id (or null when not rendered).
  element(el, parentCS, nodes, ctx) {
    const tag = el.localName;
    if (SKIP.has(tag)) return null;
    const cs = this.style(el, parentCS);
    let display = cs.display || "inline";
    if (display === "none") return null;
    if (ctx.blockify) display = blockify(display);
    const fontSize = fontSizeOf(cs, parentCS);
    cs.__fs = fontSize;
    const id = this.idOf(el, "el");
    this.owner.set(id, el);
    const props = boxProps(cs, display, fontSize, el);
    const transitions = transitionsOf(cs);
    if (transitions) this.specs.set(id, transitions);
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
      const icon = iconFor(el, cs, this.doc);
      if (!icon) return null;
      props.icon = icon;
      return this.put(nodes, id, "icon", props, [], fixedNode);
    }
    if (tag === "input" || tag === "textarea" || tag === "select") {
      const type = (el.getAttribute("type") || "text").toLowerCase();
      if (tag === "input" && (type === "checkbox" || type === "radio")) {
        // Drawn by the page's CSS (or nothing); the click goes to the label.
        props.click = true;
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
      return this.put(nodes, id, tag === "textarea" ? "textarea" : "input", props, [], fixedNode);
    }

    // Children: blocks, and inline content collected into text runs.
    const childCtx = { blockify: display === "flex" || display === "grid", parentText: cs["text-align"] };
    const kids = [];
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
      if (child.nodeType === 3) {
        const t = child.data;
        if (t) runs.push(runFor(t, cs, fontSize));
        continue;
      }
      if (child.nodeType !== 1) continue;
      if (!childCtx.blockify && this.isInline(child, cs)) {
        this.inlineRuns(child, cs, fontSize, runs);
        continue;
      }
      flushRuns();
      flow.push({ el: child });
    }
    flushRuns();

    // An element holding only text becomes one text view.
    if (flow.length === 1 && flow[0].text && !before && !cs.__rules.after.length) {
      Object.assign(props, textProps(cs, fontSize));
      props.runs = flow[0].text;
      this.putClick(props, el);
      return this.put(nodes, id, "text", props, [], fixedNode);
    }

    for (const item of flow) {
      if (item.text) {
        const tid = this.idOf(el, "t" + kids.length);
        this.owner.set(tid, el);
        const tp = { ...textProps(cs, fontSize), runs: item.text };
        if (transitions) this.specs.set(tid, transitions);
        tp.fs = childCtx.blockify && !props.scroll ? 1 : 0;
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
      else if (props.scroll && !this.cs.get(item.el)?.["flex-shrink"]) { const n = nodes.get(cid); if (n) n.props.fs = 0; }
      // An inline box (button, chip) in a block: as wide as its content, placed by text-align.
      if (!childCtx.blockify) {
        const n = nodes.get(cid);
        const d = this.cs.get(item.el)?.display || "inline";
        if (n && (ATOMIC_INLINE.has(d) || INLINE_DISPLAY.has(d)) && !n.props.as && n.props.pos !== "absolute") {
          n.props.as = alignFor(cs["text-align"]);
        }
      }
      kids.push(cid);
    }
    const after = this.pseudo(el, cs, "after", nodes);
    if (after) kids.push(after);

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
    nodes.set(id, { kind, props, kids });
    if (fixedNode) {
      let list = nodes.get("fixed");
      if (!list) nodes.set("fixed", (list = []));
      list.push(id);
      return null; // not in its parent's flow
    }
    return id;
  }

  isInline(el, parentCS) {
    if (SKIP.has(el.localName)) return true;
    if (el.localName === "svg" || el.localName === "input" || el.localName === "textarea" || el.localName === "select" ||
        el.localName === "button" || el.localName === "img") return false;
    const cs = this.style(el, parentCS);
    const d = cs.display || "inline";
    if (d !== "inline") return false;
    // Inline only if everything inside is inline too.
    for (const c of el.children) if (!this.isInline(c, cs)) return false;
    return true;
  }

  inlineRuns(el, parentCS, parentFs, runs) {
    if (SKIP.has(el.localName)) return;
    const cs = this.cs.get(el) || this.style(el, parentCS);
    if ((cs.display || "inline") === "none") return;
    const fs = fontSizeOf(cs, parentCS);
    cs.__fs = fs;
    if (el.localName === "br") { runs.push({ t: "\n", ...runStyle(cs, fs) }); return; }
    for (const child of el.childNodes) {
      if (child.nodeType === 3) runs.push(runFor(child.data, cs, fs, el));
      else if (child.nodeType === 1) this.inlineRuns(child, cs, fs, runs);
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
    if (transitions) this.specs.set(id, transitions);
    this.noteAnimations(id, pcs, fs);
    this.owner.set(id, el);
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

  emit(nodes) {
    const ops = [];
    const seen = new Set();
    const now = Date.now();
    // Nodes made again (a new kind): their parents must attach them again.
    const remade = new Set();
    for (const [id, n] of nodes) {
      const old = this.prev.get(id);
      if (old && old.kind !== n.kind) remade.add(id);
    }
    for (const [id, n] of nodes) {
      seen.add(id);
      const old = this.prev.get(id);
      if (!old || old.kind !== n.kind) this.tx.forget(id);
      // The props to show now: the page's, or on the way to them (transitions).
      const shown = this.anim.apply(id, this.tx.apply(id, n.props, this.specs.get(id) || null, now), this.animSpecs.get(id) || null, now);
      const p = JSON.stringify(shown);
      const k = JSON.stringify(n.kids);
      if (!old || old.kind !== n.kind) {
        if (old) ops.push(["d", id]);
        ops.push(["c", id, n.kind]);
        ops.push(["p", id, shown]);
        ops.push(["k", id, n.kids]);
      } else {
        if (old.p !== p) ops.push(["p", id, shown]);
        if (old.k !== k || n.kids.some((c) => remade.has(c))) ops.push(["k", id, n.kids]);
      }
      this.prev.set(id, { kind: n.kind, p, k });
      if (n.props.val !== undefined) this.native.set(id, n.props.val);
    }
    for (const id of [...this.prev.keys()]) {
      if (!seen.has(id)) { ops.push(["d", id]); this.prev.delete(id); this.native.delete(id); this.tx.forget(id); this.anim.forget(id); }
    }
    if (!this.rootSent) { ops.push(["r", 0]); this.rootSent = true; }
    if (ops.length) this.host.ops(JSON.stringify(ops));
    this.schedule();
  }

  // An element's @keyframes animations: their frames as node props
  // (resolved with the element's style: var(), currentColor, em).
  noteAnimations(id, cs, fs) {
    const list = animationsOf(cs, this.engine.keyframes);
    if (!list) return;
    const frames = list.map((a) => this.engine.keyframes[a.name].map((f) => ({ offset: f.offset, props: animProps(f.decls, cs, fs) })));
    this.animSpecs.set(id, { key: cs.animation || list.map((a) => `${a.name} ${a.dur}`).join(","), list, frames });
  }

  // While transitions or animations run: a frame every ~16 ms that sends
  // the animated nodes' props alone (no styles, no flattening).
  schedule() {
    if (this.ticking || (!this.tx.active && !this.anim.active)) return;
    this.ticking = true;
    setTimeout(() => { this.ticking = false; this.tick(); }, 16);
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

function listens(el) {
  return !!el.__listens;
}

function blockify(d) {
  if (d === "inline" || d === "inline-block" || d === "list-item" || d === "table" || d === "table-cell") return "block";
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

// Layout and drawing properties of a box.
function boxProps(cs, display, fs, el) {
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
  if (cs.position === "absolute" || cs.position === "fixed") {
    p.pos = "absolute";
    const ins = sides.map((s) => { const l = num(cs[s], fs); return l === undefined || l === "auto" ? null : typeof l === "object" ? `${l.pct}%` : l; });
    p.ins = ins;
  } else if (cs.position === "relative") {
    const ins = sides.map((s) => { const l = num(cs[s], fs); return typeof l === "number" ? l : null; });
    if (ins.some((x) => x !== null)) p.rel = ins;
  }
  const ov = cs["overflow-y"] || cs.overflow;
  if (ov === "auto" || ov === "scroll") p.scroll = true;
  if (cs["overflow-x"] === "hidden" || cs["overflow-y"] === "hidden" || cs.overflow === "hidden") p.clip = true;
  if (cs["aspect-ratio"]) p.ar = parseFloat(cs["aspect-ratio"]);
  // Transforms: translate moves the box; scale and rotate are drawn around its center.
  const tr = transformOf(cs, fs);
  if (tr.tx) p.tx = tr.tx;
  if (tr.ty) p.ty = tr.ty;
  if (tr.sc !== 1) p.sc = tr.sc;
  if (tr.rot) p.rot = tr.rot;
  // Drawing
  const cur = color(cs.color);
  const bg = background(cs.background, cur);
  // backdrop-filter: blur() isn't drawn: a see-through bar over the page
  // (a 92% background) would show the text behind it sharp. Opaque
  // instead, which is what the blur looks like.
  if (bg?.color && bg.color[3] < 1 && /blur\(/.test(cs["backdrop-filter"] || cs["-webkit-backdrop-filter"] || "")) {
    bg.color = [...bg.color.slice(0, 3), 1];
  }
  if (bg) p.bg = bg;
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

function textProps(cs, fs) {
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

function runStyle(cs, fs) {
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
      nodes.set(filler, { kind: "view", props: { fg: 1, fb: 0 }, kids: [] });
      rowKids.push(filler);
    }
    nodes.set(rowId, { kind: "view", props: { fd: "row", ai: props.ai === "center" ? "center" : "stretch", cg: props.cg, ...(props.cg ? {} : {}) }, kids: rowKids });
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
