// Breakout: the page around the game (HUD, overlays, settings, stats),
// input, and the loop. The rules are physics.js, the drawing draw.js.

import { createWorld, step, launch, resize, buildLevel } from "./physics.js";
import { draw } from "./draw.js";

const $ = (id) => document.getElementById(id);
const oriel = window.oriel;
const native = !!oriel?.native;
const os = oriel?.platform?.os || navigator.platform || "";
const coarse = window.matchMedia?.("(pointer: coarse)")?.matches || navigator.maxTouchPoints > 0;

const board = $("board"), canvas = $("cv"), ctx = canvas.getContext("2d");
const settings = { balls: 1, rows: 6, particles: true, stats: true, autoplay: false };
let W = 0, H = 0, dpr = 1, boardLeft = 0;
let world = null;
let paused = false, pausedBySettings = false;
let demo = 0; // BREAKOUT_DEMO: autoplay with this many balls, fps to the log

const show = (el, on) => (on ? el.removeAttribute("hidden") : el.setAttribute("hidden", ""));

// ---------------------------------------------------------------------------
// The board's size: the canvas fills it (window resizes, phone rotation).

function measure() {
  const r = board.getBoundingClientRect();
  const w = Math.max(120, Math.floor(r.width)), h = Math.max(120, Math.floor(r.height));
  const d = window.devicePixelRatio || 1;
  boardLeft = r.left;
  if (w === W && h === H && d === dpr) return;
  W = w; H = h; dpr = d;
  canvas.style.width = `${w}px`;
  canvas.style.height = `${h}px`;
  canvas.width = Math.round(w * d);
  canvas.height = Math.round(h * d);
  if (world) resize(world, w, h);
  else world = createWorld(w, h, { rows: settings.rows });
  redraw = true;
}
let measureSoon = true;
window.addEventListener("resize", () => { measureSoon = true; });
if (typeof ResizeObserver === "function") new ResizeObserver(() => { measureSoon = true; }).observe(board);

// ---------------------------------------------------------------------------
// Input: a pointer (the mouse over the board, or a finger dragging on it)
// moves the paddle to it; the keys move it while held.

const input = { target: null, dir: 0 };
let pointerActive = false;

board.addEventListener("pointermove", (e) => {
  if (e.pointerType === "mouse" || e.buttons) {
    input.target = e.clientX - boardLeft;
    pointerActive = true;
  }
});
// A tap or click on the board (a press that hardly moved) launches; not on
// the overlays and panel over it. (A pointerup, not click: iOS's WebView
// sends no click for a tap on a canvas.)
let press = null;
board.addEventListener("pointerdown", (e) => {
  if (!world || !onBoard(e.target)) return;
  input.target = e.clientX - boardLeft;
  pointerActive = true;
  press = { x: e.clientX, y: e.clientY, t: performance.now() };
});
board.addEventListener("pointerup", (e) => {
  const p = press;
  press = null;
  if (p && !paused && Math.hypot(e.clientX - p.x, e.clientY - p.y) < 12 && performance.now() - p.t < 500) launchOrRestart();
});
board.addEventListener("pointercancel", () => { press = null; });
board.addEventListener("pointerleave", (e) => { if (e.pointerType === "mouse") pointerActive = false; });
// The WebView: a finger on the board doesn't scroll the page.
board.addEventListener("touchmove", (e) => e.preventDefault(), { passive: false });

function onBoard(el) {
  return el === canvas || el === board;
}

// Held keys: a key counts until its keyup. (A renderer without keyup:
// until its key repeats stop.)
const held = new Map(); // key → until (ms; Infinity with keyup)
let sawKeyUp = false;
const LEFT = new Set(["ArrowLeft", "a", "A"]), RIGHT = new Set(["ArrowRight", "d", "D"]);
window.addEventListener("keydown", (e) => {
  const k = e.key;
  if (!world || e.target?.localName === "input") return; // a slider's own arrows
  if (LEFT.has(k) || RIGHT.has(k)) {
    held.set(k, sawKeyUp ? Infinity : performance.now() + (e.repeat || held.has(k) ? 120 : 550));
    pointerActive = false;
    e.preventDefault();
  } else if (k === " " || k === "Spacebar") {
    e.preventDefault();
    if (!paused) launchOrRestart();
  } else if (k === "p" || k === "P" || k === "Escape") {
    e.preventDefault();
    if (!$("settings").hasAttribute("hidden")) closeSettings();
    else if (!world.over) { pausedBySettings = false; setPaused(!paused); }
  }
});
window.addEventListener("keyup", (e) => {
  sawKeyUp = true;
  // Either case: a with Shift pressed in between comes up as A.
  for (const k of [e.key, e.key.toLowerCase(), e.key.toUpperCase()]) held.delete(k);
});
// Keys released while the window wasn't listening don't stay held.
window.addEventListener("blur", () => held.clear());

function keyDir(now) {
  let dir = 0;
  for (const [k, until] of held) {
    if (until < now) { held.delete(k); continue; }
    dir += LEFT.has(k) ? -1 : 1;
  }
  return Math.sign(dir);
}

// Autoplay: under the lowest ball coming down.
function autoTarget() {
  let best = null;
  for (const b of world.balls) if (!b.stuck && b.vy > 0 && (!best || b.y > best.y)) best = b;
  best ||= world.balls[0];
  return best ? best.x + Math.sin(performance.now() / 700) * world.paddle.w * 0.3 : null;
}

// ---------------------------------------------------------------------------
// Game state and the HTML around it

function launchOrRestart() {
  if (world.over) return restart();
  if (launch(world, settings.balls)) redraw = true;
}

function restart() {
  world = createWorld(W, H, { rows: settings.rows });
  show($("over"), false);
  setPaused(false);
  hud();
}

function setPaused(on) {
  paused = on;
  show($("pause"), on && $("settings").hasAttribute("hidden"));
  $("pause-btn").textContent = on ? "Resume" : "Pause";
  redraw = true;
}

const shown = { score: -1, lives: -1, level: -1 };
function hud() {
  for (const k of ["score", "lives", "level"]) {
    if (shown[k] !== world[k]) { shown[k] = world[k]; $(k).textContent = String(world[k]); }
  }
}

function gameOver() {
  $("final").textContent = String(world.score);
  $("final-level").textContent = String(world.level);
  show($("over"), true);
}

$("pause-btn").addEventListener("click", () => {
  if (!$("settings").hasAttribute("hidden")) return closeSettings();
  if (!world.over) { pausedBySettings = false; setPaused(!paused); }
});
$("resume").addEventListener("click", () => setPaused(false));
$("restart").addEventListener("click", restart);
$("again").addEventListener("click", restart);

function openSettings() {
  show($("settings"), true);
  if (!paused) { pausedBySettings = true; setPaused(true); }
  show($("pause"), false);
}
function closeSettings() {
  show($("settings"), false);
  if (pausedBySettings) { pausedBySettings = false; setPaused(false); }
  else show($("pause"), paused);
}
$("settings-btn").addEventListener("click", () => ($("settings").hasAttribute("hidden") ? openSettings() : closeSettings()));
$("close-settings").addEventListener("click", closeSettings);

$("balls").addEventListener("input", (e) => {
  settings.balls = +e.target.value || 1;
  $("balls-val").textContent = String(settings.balls);
});
$("rows").addEventListener("input", (e) => {
  settings.rows = +e.target.value || 6;
  $("rows-val").textContent = String(settings.rows);
  world.rows = settings.rows;
  buildLevel(world);
  redraw = true;
});
$("particles").addEventListener("change", (e) => {
  settings.particles = e.target.checked;
  if (!settings.particles) world.particles.length = 0;
});
$("show-stats").addEventListener("change", (e) => {
  settings.stats = e.target.checked;
  $("stats").classList.toggle("off", !settings.stats);
});
$("autoplay").addEventListener("change", (e) => { settings.autoplay = e.target.checked; });

$("help").textContent = coarse
  ? "Drag anywhere on the board to move · tap to launch"
  : "Mouse, ← → or A D to move · click or Space to launch · P or Esc to pause";
$("st-renderer").textContent = `${native ? "native renderer" : "WebView"}${os ? ` · ${os}` : ""}`;

// ---------------------------------------------------------------------------
// The loop: requestAnimationFrame at the display's rate, the step by the
// time since the last frame (60, 120, 144, 180 Hz play the same).

let last = 0, redraw = true, frame = 0;
const acc = { n: 0, dt: 0, phys: 0, draw: 0, since: 0 };

function tick(t) {
  requestAnimationFrame(tick);
  if (measureSoon || frame % 30 === 0) { measureSoon = false; measure(); }
  frame++;
  if (!last) { last = t; acc.since = t; return; }
  const real = (t - last) / 1000, dt = Math.min(real, 1 / 20);
  last = t;

  const t0 = performance.now();
  const running = !paused && !world.over;
  if (running) {
    input.dir = keyDir(t0);
    input.target = settings.autoplay || demo ? autoTarget() : pointerActive ? input.target : null;
    const ev = step(world, dt, input, { particles: settings.particles, endless: settings.autoplay || demo > 0 });
    // Autoplay relaunches by itself.
    if ((settings.autoplay || demo) && world.balls.length && world.balls.every((b) => b.stuck)) launch(world, settings.balls);
    if (ev.broken || ev.lost || ev.cleared) hud();
    if (world.over) gameOver();
  }
  const t1 = performance.now();
  if (running || redraw) {
    redraw = false;
    const stuck = !world.over && world.balls.some((b) => b.stuck);
    draw(ctx, world, dpr, stuck && !settings.autoplay && !demo ? (coarse ? "Tap to launch" : "Click or press Space to launch") : null);
  }
  const t2 = performance.now();

  acc.n++; acc.dt += real; acc.phys += t1 - t0; acc.draw += t2 - t1;
  if (t - acc.since >= 500) stats(t);
}

function stats(t) {
  const fps = (acc.n * 1000) / (t - acc.since);
  const frameMs = (acc.dt * 1000) / acc.n, phys = acc.phys / acc.n, drw = acc.draw / acc.n;
  if (settings.stats) {
    $("st-fps").textContent = fps.toFixed(0);
    $("st-frame").textContent = frameMs.toFixed(2);
    $("st-js").textContent = (phys + drw).toFixed(2);
    $("st-phys").textContent = phys.toFixed(2);
    $("st-draw").textContent = drw.toFixed(2);
    $("st-balls").textContent = String(world.balls.length);
    $("st-parts").textContent = String(world.particles.length);
  }
  if (demo && (demoLog += t - acc.since) >= 2000) {
    demoLog = 0;
    oriel?.invoke?.("log", { line: `fps ${fps.toFixed(1)} frame ${frameMs.toFixed(2)} ms js ${(phys + drw).toFixed(3)} ms (physics ${phys.toFixed(3)}, draw ${drw.toFixed(3)}) balls ${world.balls.length} particles ${world.particles.length} renderer ${native ? "native" : "webview"}` })?.catch?.(() => {});
  }
  acc.n = 0; acc.dt = 0; acc.phys = 0; acc.draw = 0; acc.since = t;
}
let demoLog = 0;

// BREAKOUT_DEMO=<balls> (or #demo=<balls>): autoplay, for measuring.
async function startDemo() {
  let n = Number((location.hash.match(/demo=(\d+)/) || [])[1]) || 0;
  if (!n) { try { n = Number(await oriel?.invoke?.("demo")) || 0; } catch { n = 0; } }
  if (!n) return;
  demo = n;
  settings.balls = n;
  $("balls").value = String(n);
  $("balls-val").textContent = String(n);
}

startDemo();
requestAnimationFrame(tick);
