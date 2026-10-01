// CSS @keyframes animations for the native renderer. An element's
// `animation` names keyframes; while it plays, the node's animated props
// are computed from the frames at the current time (each segment eased
// with the animation's timing function), over the props the page set.
// An animation starts when the node gets it and restarts only when its
// `animation` changes, as in a browser.

import { splitTop, splitSpaces } from "./css.js";
import { lerp, easing, seconds, EASES } from "./transitions.js";

const DIRECTIONS = new Set(["normal", "reverse", "alternate", "alternate-reverse"]);
const FILLS = new Set(["none", "forwards", "backwards", "both"]);

// An element's animations: [{ name, dur, delay, ease, iter, dir, fill }],
// only those whose keyframes exist; null when none.
export function animationsOf(cs, keyframes) {
  const list = [];
  const add = (a) => { if (a.name && a.name !== "none" && keyframes[a.name] && a.dur > 0) list.push(a); };
  if (cs.animation && cs.animation !== "none") {
    for (const part of splitTop(cs.animation, ",")) {
      const a = { name: null, dur: 0, delay: 0, ease: EASES.ease, iter: 1, dir: "normal", fill: "none" };
      let times = 0;
      for (const tok of splitSpaces(part.trim())) {
        const s = seconds(tok);
        if (s !== null) { if (times++ === 0) a.dur = s; else a.delay = s; continue; }
        const e = easing(tok);
        if (e) { a.ease = e; continue; }
        if (tok === "infinite") { a.iter = Infinity; continue; }
        if (/^[\d.]+$/.test(tok)) { a.iter = parseFloat(tok); continue; }
        if (DIRECTIONS.has(tok) && tok !== "normal") { a.dir = tok; continue; }
        if (FILLS.has(tok) && tok !== "none") { a.fill = tok; continue; }
        if (tok === "running" || tok === "paused" || tok === "normal") continue;
        a.name = tok;
      }
      add(a);
    }
  } else if (cs["animation-name"] && cs["animation-name"] !== "none") {
    const at = (prop, i, def) => { const l = splitTop(cs[prop] || def, ",").map((x) => x.trim()); return l[i % l.length]; };
    splitTop(cs["animation-name"], ",").forEach((n, i) => {
      const it = at("animation-iteration-count", i, "1");
      add({
        name: n.trim(),
        dur: seconds(at("animation-duration", i, "0s")) || 0,
        delay: seconds(at("animation-delay", i, "0s")) || 0,
        ease: easing(at("animation-timing-function", i, "ease")) || EASES.ease,
        iter: it === "infinite" ? Infinity : parseFloat(it) || 1,
        dir: at("animation-direction", i, "normal"),
        fill: at("animation-fill-mode", i, "none"),
      });
    });
  }
  return list.length ? list : null;
}

// Where an animation is at `elapsed` ms: its progress through the
// keyframes (0…1), or null when it has no effect now; and whether it is
// still running.
function progress(a, elapsed) {
  const flip = (it) => a.dir === "reverse" || (a.dir === "alternate" && it % 2 === 1) || (a.dir === "alternate-reverse" && it % 2 === 0);
  if (elapsed < 0) {
    const fills = a.fill === "backwards" || a.fill === "both";
    return { p: fills ? (flip(0) ? 1 : 0) : null, running: true };
  }
  const total = a.dur * a.iter;
  if (elapsed >= total) {
    if (a.fill !== "forwards" && a.fill !== "both") return { p: null, running: false };
    const last = Math.max(0, Math.ceil(a.iter) - 1);
    const frac = a.iter % 1 || 1;
    const q = frac;
    return { p: flip(last) ? 1 - q : q, running: false };
  }
  const it = Math.floor(elapsed / a.dur);
  const q = (elapsed - it * a.dur) / a.dur;
  return { p: flip(it) ? 1 - q : q, running: true };
}

// A key's value at progress p: between the two frames around p, eased.
function valueAt(key, frames, p, base, ease) {
  const pts = frames.filter((f) => key in f.props).map((f) => ({ o: f.offset, v: f.props[key] }));
  if (!pts.length || pts[0].o > 0) pts.unshift({ o: 0, v: base });
  if (pts[pts.length - 1].o < 1) pts.push({ o: 1, v: base });
  let i = 0;
  while (i < pts.length - 2 && p > pts[i + 1].o) i++;
  const a = pts[i], b = pts[i + 1];
  const local = b.o > a.o ? Math.min(1, Math.max(0, (p - a.o) / (b.o - a.o))) : 1;
  const e = ease(local);
  const v = lerp(key, a.v, b.v, e);
  return v === undefined ? (e < 0.5 ? a.v : b.v) : v;
}

export class Animations {
  constructor() {
    this.state = new Map(); // id → { key, start, list, frames, running }
  }

  get active() {
    for (const st of this.state.values()) if (st.running) return true;
    return false;
  }

  // The props to show for node `id` now. `spec`: { key, list, frames }
  // from a render (null: no animation), or undefined on a tick (keep).
  apply(id, base, spec, now) {
    let st = this.state.get(id);
    if (spec !== undefined) {
      if (!spec) { if (st) this.state.delete(id); return base; }
      if (!st || st.key !== spec.key) {
        st = { key: spec.key, start: now, list: spec.list, frames: spec.frames, running: true };
        this.state.set(id, st);
      } else {
        st.frames = spec.frames; // the same animation, its values may have changed (var(), theme)
      }
    }
    if (!st) return base;
    let out = base;
    let running = false;
    st.list.forEach((a, i) => {
      const { p, running: r } = progress(a, now - st.start - a.delay);
      running ||= r;
      if (p === null) return;
      const frames = st.frames[i];
      const keys = new Set(frames.flatMap((f) => Object.keys(f.props)));
      if (out === base) out = { ...base };
      for (const key of keys) {
        const v = valueAt(key, frames, p, base[key], a.ease);
        if (v === undefined) delete out[key]; else out[key] = v;
      }
    });
    st.running = running;
    return out;
  }

  forget(id) {
    this.state.delete(id);
  }
}
