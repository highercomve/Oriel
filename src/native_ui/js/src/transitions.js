// CSS transitions for the native renderer: when a node's target properties
// change and its element has a `transition` for them, the values shown
// move from where they are to the new ones over the duration, with the
// timing function. The renderer ticks the animated nodes alone (no new
// styles or flattening) until they arrive.

import { splitTop, splitSpaces } from "./css.js";

// CSS property → the node properties it animates (render.js `boxProps`, `textProps`).
const KEYS = {
  opacity: ["op"],
  background: ["bg"],
  "background-color": ["bg"],
  "background-image": ["bg"],
  color: ["col", "runs"],
  transform: ["tx", "ty", "sc", "rot"],
  translate: ["tx", "ty"],
  scale: ["sc"],
  rotate: ["rot"],
  width: ["w"],
  height: ["h"],
  "max-height": ["maxh"],
  "max-width": ["maxw"],
  border: ["bc"],
  "border-color": ["bc"],
  "box-shadow": ["sh"],
};
const ALL = [...new Set(Object.values(KEYS).flat())];

export const keysFor = (prop) => (prop === "all" ? ALL : KEYS[prop] || []);

// --- Parsing ---------------------------------------------------------------

export function seconds(t) {
  const m = /^(-?[\d.]+)(m?s)$/.exec(t);
  if (!m) return null;
  return parseFloat(m[1]) * (m[2] === "ms" ? 1 : 1000);
}

export const EASES = {
  linear: (t) => t,
  ease: bezier(0.25, 0.1, 0.25, 1),
  "ease-in": bezier(0.42, 0, 1, 1),
  "ease-out": bezier(0, 0, 0.58, 1),
  "ease-in-out": bezier(0.42, 0, 0.58, 1),
};

export function easing(tok) {
  if (EASES[tok]) return EASES[tok];
  const m = /^cubic-bezier\(([^)]*)\)$/.exec(tok);
  if (m) {
    const [a, b, c, d] = m[1].split(",").map((x) => parseFloat(x));
    if ([a, b, c, d].every(Number.isFinite)) return bezier(a, b, c, d);
  }
  const s = /^steps\((\d+)/.exec(tok);
  if (s) { const n = +s[1] || 1; return (t) => Math.min(1, Math.floor(t * n) / n); }
  return null;
}

// A cubic Bézier timing function (x1, y1, x2, y2), solved for x by Newton's method.
function bezier(x1, y1, x2, y2) {
  const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
  const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  const x = (t) => ((ax * t + bx) * t + cx) * t;
  const dx = (t) => (3 * ax * t + 2 * bx) * t + cx;
  const y = (t) => ((ay * t + by) * t + cy) * t;
  return (p) => {
    if (p <= 0) return 0;
    if (p >= 1) return 1;
    let t = p;
    for (let i = 0; i < 8; i++) {
      const e = x(t) - p;
      if (Math.abs(e) < 1e-4) break;
      const d = dx(t);
      if (Math.abs(d) < 1e-6) break;
      t -= e / d;
    }
    return y(Math.min(1, Math.max(0, t)));
  };
}

// A computed style's transitions: [{ keys, dur, delay, ease }], or null.
export function transitionsOf(cs) {
  const short = cs.transition;
  const list = [];
  if (short && short !== "none") {
    for (const part of splitTop(short, ",")) {
      let prop = "all", dur = null, delay = 0, ease = EASES.ease;
      for (const tok of splitSpaces(part.trim())) {
        const s = seconds(tok);
        if (s !== null) { if (dur === null) dur = s; else delay = s; continue; }
        const e = easing(tok);
        if (e) { ease = e; continue; }
        prop = tok;
      }
      if (dur > 0) list.push({ keys: keysFor(prop), dur, delay, ease });
    }
  } else if (cs["transition-duration"]) {
    const props = splitTop(cs["transition-property"] || "all", ",").map((s) => s.trim());
    const durs = splitTop(cs["transition-duration"], ",").map((s) => seconds(s.trim()) || 0);
    const delays = splitTop(cs["transition-delay"] || "0s", ",").map((s) => seconds(s.trim()) || 0);
    const eases = splitTop(cs["transition-timing-function"] || "ease", ",").map((s) => easing(s.trim()) || EASES.ease);
    props.forEach((p, i) => {
      const dur = durs[i % durs.length];
      if (dur > 0) list.push({ keys: keysFor(p), dur, delay: delays[i % delays.length], ease: eases[i % eases.length] });
    });
  }
  return list.length ? list : null;
}

// --- Interpolation ---------------------------------------------------------

const DEFAULTS = { op: 1, tx: 0, ty: 0, sc: 1, rot: 0 };
const num = (a, b, e) => a + (b - a) * e;
const isColor = (c) => Array.isArray(c) && c.length === 4 && c.every((x) => typeof x === "number");
const clear = (c) => [c[0], c[1], c[2], 0];

function colorLerp(a, b, e) {
  if (!isColor(a) && isColor(b)) a = clear(b);
  if (isColor(a) && !isColor(b)) b = clear(a);
  if (!isColor(a)) return undefined;
  return [num(a[0], b[0], e), num(a[1], b[1], e), num(a[2], b[2], e), num(a[3], b[3], e)];
}

const pct = (v) => (typeof v === "string" && /%$/.test(v) ? parseFloat(v) : null);

// The value of `key` between a and b at eased progress e; undefined when
// the two can't be interpolated (the new value is shown at once).
export function lerp(key, a, b, e) {
  if (a === undefined) a = DEFAULTS[key];
  if (b === undefined) b = DEFAULTS[key];
  switch (key) {
    case "op": case "tx": case "ty": case "sc": case "rot":
      return typeof a === "number" && typeof b === "number" ? num(a, b, e) : undefined;
    case "w": case "h": case "maxw": case "maxh": {
      if (typeof a === "number" && typeof b === "number") return num(a, b, e);
      const pa = a === 0 ? 0 : pct(a), pb = b === 0 ? 0 : pct(b);
      if (pa !== null && pb !== null && (pct(a) !== null || pct(b) !== null)) return `${num(pa, pb, e)}%`;
      return undefined;
    }
    case "col":
      return colorLerp(a, b, e);
    case "bc": {
      if (!Array.isArray(a) && Array.isArray(b)) a = b.map(clear);
      if (Array.isArray(a) && !Array.isArray(b)) b = a.map(clear);
      if (!Array.isArray(a) || a.length !== b.length) return undefined;
      return a.map((c, i) => colorLerp(c, b[i], e));
    }
    case "runs": {
      if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return undefined;
      if (a.some((r, i) => r.t !== b[i].t)) return undefined;
      return b.map((r, i) => ({ ...r, c: colorLerp(a[i].c, r.c, e) ?? r.c }));
    }
    case "bg": {
      const ca = a?.color, cb = b?.color;
      const ga = a?.gradient, gb = b?.gradient;
      const out = {};
      if (ca || cb) { const c = colorLerp(ca, cb, e); if (!c) return undefined; out.color = c; }
      if (ga || gb) {
        if (!ga || !gb || !!ga.radial !== !!gb.radial || ga.stops.length !== gb.stops.length) return undefined;
        out.gradient = { ...gb, angle: num(ga.angle ?? 180, gb.angle ?? 180, e), stops: gb.stops.map((s, i) => [...colorLerp(ga.stops[i].slice(0, 4), s.slice(0, 4), e), num(ga.stops[i][4], s[4], e)]) };
      }
      return out;
    }
    case "sh": {
      if (!a && !b) return undefined;
      if (!a) a = { ...b, color: clear(b.color) };
      if (!b) b = { ...a, color: clear(a.color) };
      return { x: num(a.x, b.x, e), y: num(a.y, b.y, e), blur: num(a.blur, b.blur, e), spread: num(a.spread, b.spread, e), color: colorLerp(a.color, b.color, e) };
    }
  }
  return undefined;
}

const same = (a, b) => a === b || JSON.stringify(a) === JSON.stringify(b);

// --- The running transitions ---------------------------------------------

export class Transitions {
  constructor() {
    this.targets = new Map(); // id → the props the page asks for
    this.shown = new Map();   // id → the props last sent
    this.anims = new Map();   // id → { key: { from, to, start, dur, ease } }
  }

  get active() { return this.anims.size > 0; }

  // The props to send for node `id` now: `target`, with the keys in
  // transition at their current values. `spec`: transitionsOf(), or null.
  apply(id, target, spec, now) {
    const before = this.targets.get(id);
    this.targets.set(id, target);
    let running = this.anims.get(id);
    if (spec && before && before !== target) {
      for (const s of spec) {
        for (const key of s.keys) {
          if (same(before[key], target[key])) continue;
          const cur = running?.[key];
          const from = cur ? this.valueOf(key, cur, now) : (this.shown.get(id)?.[key] ?? before[key]);
          if (lerp(key, from, target[key], 0) === undefined) { if (running) delete running[key]; continue; }
          (running ||= {})[key] = { from, to: target[key], start: now + s.delay, dur: s.dur, ease: s.ease };
        }
      }
      if (running) this.anims.set(id, running);
    }
    let out = target;
    if (running) {
      out = { ...target };
      for (const key of Object.keys(running)) {
        const a = running[key];
        if (!same(a.to, target[key]) || now >= a.start + a.dur) { delete running[key]; continue; }
        const v = this.valueOf(key, a, now);
        if (v === undefined) delete out[key]; else out[key] = v;
      }
      if (!Object.keys(running).length) this.anims.delete(id);
    }
    this.shown.set(id, out);
    return out;
  }

  valueOf(key, a, now) {
    const t = Math.min(1, Math.max(0, (now - a.start) / a.dur));
    return lerp(key, a.from, a.to, a.ease(t));
  }

  forget(id) {
    this.targets.delete(id);
    this.shown.delete(id);
    this.anims.delete(id);
  }
}
