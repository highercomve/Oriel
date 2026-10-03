// <canvas> in the native renderer: no pixels, a small program.
//
// getContext("2d") returns a recorder: every drawing call appends a compact
// op to the element's program, which the flattener sends as the canvas
// node's `cv` prop and each backend replays into its own draw pass (Cairo
// on GTK; other backends don't draw canvases yet). Not a bitmap: no
// getImageData / putImageData / drawImage, and measureText is an estimate.
//
// The program re-runs whole on every paint, so it must stand for the whole
// bitmap. A clearRect that covers it all, with no clip, no transform and
// full alpha, makes everything before it invisible (it would in a browser
// too), so the recorder drops it there: the game-loop pattern (clear all,
// redraw) keeps one frame's ops, and drawing without such a clear
// accumulates, as in a browser. After the drop the current state goes out
// again (the bitmap would have kept it; the program restarts from the
// defaults). State ops go out only when the value differs from the one in
// effect, so a loop that sets the same colors every frame still compares
// clean against the last frame.
//
// Ops (JSON arrays in props.cv):
//   ["sv"] ["rs"]                      save, restore
//   ["tl",x,y] ["ts",x,y] ["tr",a]     translate, scale, rotate
//   ["bp"] ["cp"] ["fl",even] ["st"] ["cl",even]
//                                      beginPath, closePath, fill, stroke, clip
//   ["mv",x,y] ["ln",x,y] ["rc",x,y,w,h] ["ar",x,y,r,a0,a1,ccw]
//   ["qc",cx,cy,x,y] ["bz",c1x,c1y,c2x,c2y,x,y]
//                                      moveTo, lineTo, rect, arc,
//                                      quadraticCurveTo, bezierCurveTo
//   ["fr",x,y,w,h] ["sr",…] ["cr",…]   fillRect, strokeRect, clearRect
//   ["tx",text,x,y] ["sx",text,x,y]    fillText, strokeText
//   ["sf",paint] ["ss",paint]          fillStyle, strokeStyle
//   ["lw",w] ["lc",cap] ["lj",join] ["ga",a]
//   ["fo",italic,weight,size,family]
//   ["ta",align] ["tb",baseline]
//   ["gl",id,x0,y0,x1,y1] ["gr",id,x0,y0,r0,x1,y1,r1] ["gs",id,off,r,g,b,a]
//   paint: [r,g,b,a] (r g b 0-255, a 0-1) or ["g", id]

import { color } from "./css.js";

let notify = () => {};

// The renderer listens: a recorded op means the page changed, so it renders
// (main.js passes the hook).
export function onRecord(fn) {
  notify = fn;
}

// The program for a canvas element, for the flattener ([] before any draw).
export function commandsOf(el) {
  return recorders.get(el)?.ops || [];
}

// Its version: changes with every recorded op or restart (the renderer sends
// a program to the tree when it changed: host.canvas). 0 before any draw.
export function versionOf(el) {
  return recorders.get(el)?.version || 0;
}

// A program as numbers for the tree (host.canvas, tree.decodeCanvas): each
// op its code and a fixed number of arguments (CANVAS_ARGS); strings (text,
// font families) by index into `strs`; paints as [kind, a, b, c, d] (0: a
// color r, g, b, a; 1: gradient id). Codes and words match tree.zig.
const CANVAS_CODES = { sv: 1, rs: 2, bp: 3, cp: 4, st: 5, fl: 6, cl: 7, tl: 8, ts: 9, tr: 10, mv: 11, ln: 12, rc: 13, ar: 14, bz: 15,
  fr: 16, sr: 17, cr: 18, tx: 19, sx: 20, sf: 21, ss: 22, lw: 23, ga: 24, lc: 25, lj: 26, ta: 27, tb: 28, fo: 29, gl: 30, gr: 31, gs: 32 };
export const CANVAS_ARGS = [0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 1, 2, 2, 4, 6, 6, 4, 4, 4, 3, 3, 5, 5, 1, 1, 1, 1, 1, 1, 4, 5, 7, 6];
const WORDS = {
  lc: { butt: 0, round: 1, square: 2 },
  lj: { miter: 0, round: 1, bevel: 2 },
  ta: { left: 0, center: 1, right: 2, start: 0, end: 2 },
  tb: { alphabetic: 0, top: 1, hanging: 2, middle: 3, bottom: 4, ideographic: 4 },
};
export function encodeProgram(ops) {
  let size = 0;
  for (const op of ops) size += 1 + (CANVAS_ARGS[CANVAS_CODES[op[0]]] ?? 0);
  const nums = new Float64Array(size), strs = [];
  let i = 0;
  for (const op of ops) {
    const code = CANVAS_CODES[op[0]];
    if (!code) continue;
    nums[i++] = code;
    switch (op[0]) {
      case "tx": case "sx": nums[i++] = strs.push(String(op[1])) - 1; nums[i++] = op[2]; nums[i++] = op[3]; break;
      case "fo": nums[i++] = op[1]; nums[i++] = op[2]; nums[i++] = op[3]; nums[i++] = strs.push(op[4] || "") - 1; break;
      case "sf": case "ss": {
        const p = op[1];
        if (p?.[0] === "g") { nums[i++] = 1; nums[i++] = p[1]; nums[i++] = 0; nums[i++] = 0; nums[i++] = 0; }
        else { nums[i++] = 0; nums[i++] = p[0]; nums[i++] = p[1]; nums[i++] = p[2]; nums[i++] = p[3]; }
        break;
      }
      case "lc": case "lj": case "ta": case "tb": nums[i++] = WORDS[op[0]][op[1]] ?? 0; break;
      default: for (let k = 1; k <= CANVAS_ARGS[code]; k++) nums[i++] = op[k] === true ? 1 : op[k] === false ? 0 : op[k] ?? 0;
    }
  }
  return [i === size ? nums : nums.subarray(0, i), strs];
}

const recorders = new WeakMap();
const CANVAS_DEFAULT_W = 300;
const CANVAS_DEFAULT_H = 150;
const TWO_PI = 2 * Math.PI;

// Patch linkedom's HTMLCanvasElement: getContext records, width/height are
// the attributes (300 / 150 when absent, as in a browser).
export function install(dom, markDirty) {
  const P = dom.HTMLCanvasElement?.prototype;
  if (!P) return;
  notify = markDirty;
  P.getContext = function (type) {
    if (String(type) !== "2d") return null;
    let r = recorders.get(this);
    if (!r) recorders.set(this, (r = new Recorder(this)));
    return r;
  };
  for (const [name, def] of [["width", CANVAS_DEFAULT_W], ["height", CANVAS_DEFAULT_H]]) {
    Object.defineProperty(P, name, {
      get() {
        const v = parseFloat(this.getAttribute(name));
        return Number.isFinite(v) && v > 0 ? v : def;
      },
      set(v) { this.setAttribute(name, v); },
      configurable: true,
    });
  }
}

const CAPS = { butt: 0, round: 1, square: 2 };
const JOINS = { miter: 0, round: 1, bevel: 2 };
const ALIGNS = { left: 0, start: 0, center: 1, right: 2, end: 2 };
const BASELINES = { alphabetic: 0, top: 1, hanging: 2, middle: 3, bottom: 4, ideographic: 4 };

// The context state, JS side: the truth the setters compare against (the
// native side starts from the same defaults and follows the state ops).
// fillStyle / strokeStyle hold paints ([r,g,b,a] or ["g", id]).
class State {
  constructor() {
    this.fillStyle = [0, 0, 0, 1];
    this.strokeStyle = [0, 0, 0, 1];
    this.lineWidth = 1;
    this.lineCap = "butt";
    this.lineJoin = "miter";
    this.globalAlpha = 1;
    this.font = "10px sans-serif";
    this.textAlign = "start";
    this.textBaseline = "alphabetic";
  }
}

class Recorder {
  constructor(el) {
    this.canvas = el;
    this.ops = [];
    this.version = 0; // bumped with every change to `ops` (versionOf)
    this.nGrad = 0;
    // Each live gradient's definition (its creation op and color stops),
    // replayed when the program restarts at a full clear: the page may
    // still paint with it. Gone with the gradient object (gradientGone).
    this.grads = new Map();
    this.s = new State();
    this.stack = [];
    this.penX = 0;
    this.penY = 0;
    // Where the transform stands, for the full-clear reset.
    this.tx = 0; this.ty = 0; this.scx = 1; this.scy = 1; this.rot = 0;
    this.clipped = false;
  }

  push(op) { this.ops.push(op); this.version++; notify(); }

  // ------------------------------------------------------------- state
  set fillStyle(v) { this.putStyle("sf", "fillStyle", v); }
  get fillStyle() { return this.s.fillStyle; }
  set strokeStyle(v) { this.putStyle("ss", "strokeStyle", v); }
  get strokeStyle() { return this.s.strokeStyle; }

  putStyle(tag, name, v) {
    const paint = paintOf(v);
    if (paint === undefined) return; // an invalid color: ignored, as in a browser
    if (samePaint(this.s[name], paint)) return;
    this.s[name] = paint;
    this.push([tag, paint]);
  }

  set lineWidth(v) { this.putNum("lineWidth", "lw", v); }
  get lineWidth() { return this.s.lineWidth; }
  set globalAlpha(v) {
    const n = Number(v);
    if (!Number.isFinite(n) || n < 0 || n > 1) return;
    this.putNum("globalAlpha", "ga", n);
  }
  get globalAlpha() { return this.s.globalAlpha; }
  set lineCap(v) { if (v in CAPS) this.putWord("lineCap", "lc", v); }
  get lineCap() { return this.s.lineCap; }
  set lineJoin(v) { if (v in JOINS) this.putWord("lineJoin", "lj", v); }
  get lineJoin() { return this.s.lineJoin; }
  set textAlign(v) { if (v in ALIGNS) this.putWord("textAlign", "ta", v); }
  get textAlign() { return this.s.textAlign; }
  set textBaseline(v) { if (v in BASELINES) this.putWord("textBaseline", "tb", v); }
  get textBaseline() { return this.s.textBaseline; }

  putNum(name, tag, v) {
    const n = +v;
    if (!Number.isFinite(n) || n === this.s[name] || (n < 0 && name === "lineWidth")) return;
    this.s[name] = n;
    this.push([tag, n]);
  }

  putWord(name, tag, v) {
    if (v === this.s[name]) return;
    this.s[name] = v;
    this.push([tag, v]);
  }

  set font(v) {
    const f = fontOf(v);
    if (!f) return;
    const cur = fontOf(this.s.font) || {};
    if (f.italic === cur.italic && f.weight === cur.weight && f.size === cur.size && f.family === cur.family) return;
    this.s.font = String(v);
    this.push(["fo", f.italic ? 1 : 0, f.weight, f.size, f.family || ""]);
  }
  get font() { return this.s.font; }

  // The state ops as they stand now (after a full-clear drop: the bitmap
  // kept this state, the program restarts from the defaults).
  // The program starts over (a full clear or cover): the live gradients'
  // definitions, then the state.
  restart() {
    this.ops.length = 0;
    this.version++;
    if (this.grads.size) {
      const used = new Set();
      for (const st of [this.s, ...this.stack.map((x) => x.s)]) {
        for (const p of [st.fillStyle, st.strokeStyle]) if (!isColor(p) && p?.[0] === "g") used.add(p[1]);
      }
      for (const [id, def] of this.grads) {
        if (def.dead && !used.has(id)) { this.grads.delete(id); continue; }
        for (const op of def) this.ops.push(op);
      }
    }
    this.emitState();
  }

  emitState() {
    this.version++;
    const s = this.s;
    this.ops.push(
      ["sf", s.fillStyle], ["ss", s.strokeStyle],
      ["lw", s.lineWidth], ["lc", s.lineCap], ["lj", s.lineJoin], ["ga", s.globalAlpha],
    );
    const f = fontOf(s.font);
    if (f) this.ops.push(["fo", f.italic ? 1 : 0, f.weight, f.size, f.family || ""]);
    this.ops.push(["ta", s.textAlign], ["tb", s.textBaseline]);
    notify();
  }

  // ------------------------------------------------------------- transforms

  save() {
    this.stack.push({ s: { ...this.s }, tx: this.tx, ty: this.ty, scx: this.scx, scy: this.scy, rot: this.rot, clipped: this.clipped });
    this.push(["sv"]);
  }

  restore() {
    const st = this.stack.pop();
    if (!st) return;
    this.s = st.s;
    this.tx = st.tx; this.ty = st.ty; this.scx = st.scx; this.scy = st.scy;
    this.rot = st.rot; this.clipped = st.clipped;
    this.push(["rs"]);
  }

  // A browser ignores a transform call with an argument that isn't a finite
  // number; 0 is a real value (scale(0) makes everything after it invisible).
  translate(x, y) {
    x = +x; y = +y;
    if (!Number.isFinite(x) || !Number.isFinite(y)) return;
    this.tx += x; this.ty += y;
    this.push(["tl", x, y]);
  }

  scale(x, y) {
    x = +x; y = y === undefined ? x : +y;
    if (!Number.isFinite(x) || !Number.isFinite(y)) return;
    this.scx *= x; this.scy *= y;
    this.push(["ts", x, y]);
  }

  rotate(a) {
    a = +a;
    if (!Number.isFinite(a)) return;
    this.rot += a;
    this.push(["tr", a]);
  }

  // ------------------------------------------------------------- paths

  beginPath() { this.push(["bp"]); }
  closePath() { this.push(["cp"]); }

  moveTo(x, y) {
    this.penX = +x || 0; this.penY = +y || 0;
    this.push(["mv", this.penX, this.penY]);
  }

  lineTo(x, y) {
    this.penX = +x || 0; this.penY = +y || 0;
    this.push(["ln", this.penX, this.penY]);
  }

  rect(x, y, w, h) {
    this.penX = +x || 0; this.penY = +y || 0;
    this.push(["rc", this.penX, this.penY, +w || 0, +h || 0]);
  }

  arc(x, y, r, a0, a1, ccw) {
    if (!(r >= 0)) return;
    const start = +a0 || 0;
    let end = a1 === undefined ? TWO_PI : +a1;
    if (!Number.isFinite(end)) end = start;
    // Where the pen lands: the sweep the backends normalize to.
    if (!ccw) { if (end < start) end += TWO_PI; }
    else { if (end > start) end -= TWO_PI; }
    this.penX = x + r * Math.cos(end);
    this.penY = y + r * Math.sin(end);
    this.push(["ar", +x || 0, +y || 0, r, start, a1 === undefined ? TWO_PI : +a1, ccw ? 1 : 0]);
  }

  // A canvas ellipse, as the recorder sees one: a scaled circle.
  ellipse(x, y, rx, ry, rot = 0, a0 = 0, a1 = TWO_PI, ccw = false) {
    if (!(rx >= 0 && ry >= 0)) return;
    this.ops.push(
      ["sv"], ["tl", +x || 0, +y || 0], ["tr", +rot || 0], ["ts", rx, ry],
      ["ar", 0, 0, 1, +a0 || 0, a1, ccw ? 1 : 0], ["rs"],
    );
    this.penX = x + rx * Math.cos(+a1 || 0);
    this.penY = y + ry * Math.sin(+a1 || 0);
    this.version++;
    notify();
  }

  // Quadratic curves become cubics (cairo has no quadratic: the control
  // points sit 2/3 of the way to it, from each end).
  quadraticCurveTo(cx, cy, x, y) {
    const x0 = this.penX, y0 = this.penY, qx = +cx || 0, qy = +cy || 0, ex = +x || 0, ey = +y || 0;
    this.penX = ex; this.penY = ey;
    this.push(["bz", x0 + 2 / 3 * (qx - x0), y0 + 2 / 3 * (qy - y0), ex + 2 / 3 * (qx - ex), ey + 2 / 3 * (qy - ey), ex, ey]);
  }

  bezierCurveTo(c1x, c1y, c2x, c2y, x, y) {
    this.penX = +x || 0; this.penY = +y || 0;
    this.push(["bz", +c1x || 0, +c1y || 0, +c2x || 0, +c2y || 0, this.penX, this.penY]);
  }

  // ------------------------------------------------------------- drawing

  fill(rule) { this.push(["fl", rule === "evenodd" ? 1 : 0]); }
  stroke() { this.push(["st"]); }
  clip(rule) { this.clipped = true; this.push(["cl", rule === "evenodd" ? 1 : 0]); }

  fillRect(x, y, w, h) {
    x = +x; y = +y; w = +w; h = +h;
    if (![x, y, w, h].every(Number.isFinite)) return; // ignored, as in a browser
    this.penX = x; this.penY = y;
    // An opaque fill of the whole bitmap (no clip, no transform): like a
    // full clearRect, it covers everything before it — the common way a
    // game loop "clears". The program restarts here.
    const p = this.s.fillStyle;
    if (x <= 0 && y <= 0 && w >= this.canvas.width && h >= this.canvas.height && !this.clipped && isColor(p) && p[3] >= 1 &&
        Math.abs(this.tx) < 1e-9 && Math.abs(this.ty) < 1e-9 && Math.abs(this.scx - 1) < 1e-9 &&
        Math.abs(this.scy - 1) < 1e-9 && Math.abs(this.rot) < 1e-9) {
      this.restart();
    }
    this.push(["fr", x, y, w, h]);
  }

  strokeRect(x, y, w, h) {
    this.penX = +x || 0; this.penY = +y || 0;
    this.push(["sr", this.penX, this.penY, +w || 0, +h || 0]);
  }

  clearRect(x, y, w, h) {
    x = +x; y = +y; w = +w; h = +h;
    if (![x, y, w, h].every(Number.isFinite)) return; // ignored, as in a browser
    this.penX = x; this.penY = y;
    // A full clear with no clip or transform in effect: everything drawn
    // before it is gone from the bitmap (as in a browser), so the program
    // restarts here — the state first, which the bitmap would have kept.
    if (x <= 0 && y <= 0 && w >= this.canvas.width && h >= this.canvas.height && !this.clipped &&
        Math.abs(this.tx) < 1e-9 && Math.abs(this.ty) < 1e-9 && Math.abs(this.scx - 1) < 1e-9 &&
        Math.abs(this.scy - 1) < 1e-9 && Math.abs(this.rot) < 1e-9) {
      this.restart();
    }
    this.push(["cr", x, y, w, h]);
  }

  fillText(t, x, y) {
    if (t === undefined || t === null || t === "") return;
    this.penX = +x || 0; this.penY = +y || 0;
    this.push(["tx", String(t), this.penX, this.penY]);
  }

  strokeText(t, x, y) {
    if (t === undefined || t === null || t === "") return;
    this.penX = +x || 0; this.penY = +y || 0;
    this.push(["sx", String(t), this.penX, this.penY]);
  }

  // Not a bitmap: measureText is a width estimate (Pango measures the DOM's
  // text; a canvas would need a round trip to it).
  measureText(t) {
    const size = fontOf(this.s.font)?.size || 10;
    let w = 0;
    for (const ch of String(t)) w += /[ ilj|!.,:;'\x60]/.test(ch) ? 0.3 : /[ftrI(){}[\]-]/.test(ch) ? 0.4 : /[mwMW@]/.test(ch) ? 0.9 : 0.58;
    return { width: w * size };
  }

  createLinearGradient(x0, y0, x1, y1) {
    return this.gradient(["gl", ++this.nGrad, +x0 || 0, +y0 || 0, +x1 || 0, +y1 || 0]);
  }

  createRadialGradient(x0, y0, r0, x1, y1, r1) {
    return this.gradient(["gr", ++this.nGrad, +x0 || 0, +y0 || 0, +r0 || 0, +x1 || 0, +y1 || 0, +r1 || 0]);
  }

  gradient(op) {
    const id = op[1], def = [op];
    this.grads.set(id, def);
    this.push(op);
    const g = gradientOf(this, id, def);
    gradientGone?.register(g, { grads: this.grads, id });
    return g;
  }
}

// A gradient object the page no longer holds can't be assigned again: its
// definition is marked dead, and a restart drops it unless a style (the
// current state's or a saved one) still paints with it, which keeps only
// its id. Without FinalizationRegistry definitions stay, as many as made.
const gradientGone = typeof FinalizationRegistry === "function"
  ? new FinalizationRegistry(({ grads, id }) => { const def = grads.get(id); if (def) def.dead = true; }) : null;

function gradientOf(r, id, def) {
  return {
    __grad: id,
    addColorStop(off, c) {
      const col = color(String(c));
      if (!col) return;
      const o = +off;
      if (!Number.isFinite(o)) return;
      const op = ["gs", id, Math.max(0, Math.min(1, o)), col[0], col[1], col[2], col[3]];
      def.push(op);
      r.push(op);
      notify();
    },
  };
}

// A color (not a gradient reference, not an invalid state).
function isColor(p) {
  return Array.isArray(p) && p.length === 4;
}

// A color, or a gradient reference; undefined for an invalid color (the
// assignment is ignored, as in a browser).
function paintOf(v) {
  if (typeof v === "object" && v !== null && typeof v.__grad === "number") return ["g", v.__grad];
  if (typeof v !== "string") return undefined; // patterns aren't supported
  const c = color(v);
  return c ? c : undefined;
}

function samePaint(a, b) {
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (Array.isArray(a)) return a.length === b.length && a.every((x, i) => x === b[i]);
  return a === b;
}

function fontOf(v) {
  const m = /^\s*(italic\s+)?(?:(\d+|bold|normal|lighter)\s+)?([\d.]+)(px|pt|em)\s+(.+?)\s*$/.exec(String(v || ""));
  if (!m) return null;
  let size = parseFloat(m[3]);
  if (m[4] === "pt") size *= 4 / 3;
  if (m[4] === "em") size *= 16;
  let weight = 400;
  if (m[2] === "bold") weight = 700;
  else if (m[2] === "lighter") weight = 300;
  else if (m[2] !== undefined && m[2] !== "normal") weight = parseInt(m[2], 10) || 400;
  return { italic: !!m[1], weight, size, family: m[5] ? m[5].replace(/["']/g, "") : "" };
}
