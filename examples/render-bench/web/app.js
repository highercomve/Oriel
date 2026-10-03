// Render bench: the same page in Oriel's WebView and native renderers.
// Times are milliseconds on performance.now(): DOM work plus the layout a
// forced read (offsetHeight) triggers. Painting isn't included, in either.
const $ = (id) => document.getElementById(id);
const invoke = (cmd, args) => window.oriel.invoke(cmd, args);
const frame = () => new Promise((r) => requestAnimationFrame(r));
const median = (xs) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];
const RUNS = 3;
// The native renderer says so in its user agent (any WebView: WebKitGTK,
// WebView2, WKWebView, Android's, doesn't).
const NATIVE = /^Oriel native/.test(navigator.userAgent);
// ORIEL_NUI_TRACE: a log line right before each timed row change (the native
// renderer logs each draw after it: logcat's timestamps give the on-screen time).
let trace = false;
const mark = (name, r) => { if (trace) console.info(`bench mark: ${name} #${r}`); };

const results = {};
function show(name, runs, unit = "ms") {
  results[name] = { median: +median(runs).toFixed(2), runs: runs.map((x) => +x.toFixed(2)), unit };
  const tr = document.createElement("tr");
  tr.innerHTML = `<td>${name}</td><td>${results[name].median} ${unit}</td><td class="muted">${results[name].runs.join(" · ")}</td>`;
  $("rows").append(tr);
}

function buildRows(stage, n) {
  const list = document.createElement("div");
  for (let i = 0; i < n; i++) {
    const row = document.createElement("div");
    row.className = "row";
    row.innerHTML = `<span class="n">${i}</span><span class="dot"></span><span>Row ${i}: the quick brown fox</span>`;
    list.append(row);
  }
  stage.append(list);
  return list;
}

async function timeBuild(n) {
  const runs = [];
  for (let r = 0; r < RUNS; r++) {
    const stage = $("stage");
    stage.textContent = "";
    await frame();
    mark(`build ${n} rows`, r);
    const t0 = performance.now();
    const list = buildRows(stage, n);
    void list.offsetHeight; // style + layout now
    runs.push(performance.now() - t0);
  }
  show(`build ${n} rows`, runs);
}

async function timeUpdate(n) {
  const stage = $("stage");
  stage.textContent = "";
  const list = buildRows(stage, n);
  await frame();
  const runs = [];
  for (let r = 0; r < RUNS; r++) {
    mark(`update ${n} rows`, r);
    const t0 = performance.now();
    let i = 0;
    for (const row of list.children) row.lastElementChild.textContent = `Row ${i++}: updated ${r}`;
    void list.offsetHeight;
    runs.push(performance.now() - t0);
    await frame();
  }
  show(`update ${n} rows`, runs);
}

// How long the last animation loop ran, in s (its fps: frames / this).
let loopSecs = 1;

async function timeAnimation(count, ms) {
  const runs = [];
  for (let r = 0; r < RUNS; r++) runs.push((await animateBoxes(count, ms)) / loopSecs);
  show(`animate ${count} boxes`, runs, "fps");
}

// `count` boxes moved by requestAnimationFrame for `ms`: the frames drawn.
async function animateBoxes(count, ms) {
  const stage = $("stage");
  {
    stage.textContent = "";
    const boxes = [];
    for (let i = 0; i < count; i++) {
      const b = document.createElement("div");
      b.className = "box";
      stage.append(b);
      boxes.push(b);
    }
    const w = stage.clientWidth || 600, h = stage.clientHeight || 300;
    let frames = 0;
    const t0 = performance.now();
    await new Promise((done) => {
      const tick = (now) => {
        const t = (now - t0) / 1000;
        for (let i = 0; i < count; i++) {
          const x = (Math.sin(t * 2 + i * 0.3) * 0.45 + 0.5) * (w - 14);
          const y = (Math.cos(t * 1.3 + i * 0.17) * 0.45 + 0.5) * (h - 14);
          boxes[i].style.transform = `translate(${x.toFixed(1)}px, ${y.toFixed(1)}px)`;
        }
        frames++;
        if (now - t0 < ms) requestAnimationFrame(tick); else done();
      };
      requestAnimationFrame(tick);
    });
    loopSecs = (performance.now() - t0) / 1000;
    return frames;
  }
}

// A canvas game loop: physics on `count` balls, then a full redraw each
// frame (background fill + circles + text), the way a small game draws.
async function timeCanvasBalls(count, ms) {
  const runs = [];
  for (let r = 0; r < RUNS; r++) runs.push((await canvasBalls(count, ms)) / loopSecs);
  show(`canvas ${count} balls`, runs, "fps");
  await timeZigBalls(count, ms);
}

// The canvas game loop for `ms`: the frames drawn.
async function canvasBalls(count, ms) {
  const stage = $("stage");
  {
    stage.textContent = "";
    const el = document.createElement("canvas");
    const w = stage.clientWidth || 600, h = stage.clientHeight || 300;
    el.width = w; el.height = h;
    el.style.width = "100%"; el.style.height = "100%";
    stage.append(el);
    const ctx = el.getContext("2d");
    const colors = ["#6d8bff", "#e8555a", "#3ad07a", "#e8c55a", "#e8eaee"];
    const balls = [];
    for (let i = 0; i < count; i++) balls.push({
      x: 10 + (i * 37.13) % (w - 20), y: 10 + (i * 23.71) % (h - 20),
      dx: 40 + (i % 7) * 17, dy: 30 + (i % 5) * 23, c: colors[i % colors.length],
    });
    let frames = 0;
    const t0 = performance.now();
    let last = t0;
    await new Promise((done) => {
      const tick = (now) => {
        const dt = Math.min(0.05, (now - last) / 1000);
        last = now;
        ctx.fillStyle = "#10141b";
        ctx.fillRect(0, 0, w, h);
        for (const b of balls) {
          b.x += b.dx * dt; b.y += b.dy * dt;
          if (b.x < 6 || b.x > w - 6) b.dx = -b.dx;
          if (b.y < 6 || b.y > h - 6) b.dy = -b.dy;
          ctx.beginPath();
          ctx.arc(b.x, b.y, 6, 0, 2 * Math.PI);
          ctx.fillStyle = b.c;
          ctx.fill();
        }
        ctx.fillStyle = "#e8eaee";
        ctx.font = "12px sans-serif";
        ctx.textBaseline = "top";
        ctx.fillText(`${count} balls`, 8, 8);
        frames++;
        if (now - t0 < ms) requestAnimationFrame(tick); else done();
      };
      requestAnimationFrame(tick);
    });
    loopSecs = (performance.now() - t0) / 1000;
    return frames;
  }
}

// The same balls drawn by the app's Zig code (zig_balls.zig, oriel.canvas):
// no JavaScript per frame. Native renderer only.
async function timeZigBalls(count, ms) {
  if (!NATIVE) return;
  const stage = $("stage");
  const runs = [], costs = [];
  for (let r = 0; r < RUNS; r++) {
    stage.textContent = "";
    const el = document.createElement("canvas");
    el.id = "zigballs";
    el.width = stage.clientWidth || 600; el.height = stage.clientHeight || 300;
    el.style.width = "100%"; el.style.height = "100%";
    stage.append(el);
    await frame();
    if (!(await invoke("zig_balls", { count, ms }))) return;
    let res;
    do {
      await new Promise((done) => setTimeout(done, 100));
      res = await invoke("zig_balls_result");
    } while (!res.done);
    runs.push(res.fps);
    costs.push(res.frame_us);
  }
  show(`canvas ${count} balls (Zig)`, runs, "fps");
  show(`canvas ${count} balls (Zig), Zig work per frame`, costs, "µs");
}

// --- Power (RENDER_BENCH_POWER=<seconds>, or the Power button) -------------
// The device's draw while each scenario runs, from power_now: a battery's
// current and voltage (Android, Linux laptops; on battery only: a charger
// makes the numbers meaningless) or the CPU package's energy counter (Linux
// RAPL, if readable). Whole-device numbers: compare the two renderers under
// the same scenario, brightness and conditions. Emulators have no real
// battery.

const power = () => invoke("power_now").catch(() => ({ ok: false, source: "no power_now" }));

// Run `work` (an async function returning the frames it drew) while sampling
// the power every 250 ms: average mW, joules, mJ per frame.
async function measurePower(name, work) {
  const first = await power();
  if (!first.ok) return { name, error: first.source || "no battery or energy counter here" };
  const samples = [];
  let plugged = first.plugged;
  let energyMj = 0, last = { t: performance.now(), p: first };
  const timer = setInterval(async () => {
    const p = await power();
    const t = performance.now();
    if (p.ok && p.energy_uj < 0) energyMj += ((last.p.mw + p.mw) / 2) * ((t - last.t) / 1000); // trapezoid: mW × s = mJ
    plugged = plugged || p.plugged;
    samples.push(p.mw);
    last = { t, p };
  }, 250);
  const t0 = performance.now();
  const frames = await work();
  clearInterval(timer);
  const end = await power();
  const secs = (performance.now() - t0) / 1000;
  if (end.energy_uj >= 0 && first.energy_uj >= 0) energyMj = (end.energy_uj - first.energy_uj) / 1000;
  else energyMj += ((last.p.mw + end.mw) / 2) * ((performance.now() - last.t) / 1000);
  const mw = energyMj / secs;
  const out = { name, source: first.source, seconds: +secs.toFixed(1), mw: +mw.toFixed(0), joules: +(energyMj / 1000).toFixed(2), samples: samples.length, plugged };
  if (frames) { out.fps = +(frames / secs).toFixed(1); out.mj_per_frame = +(energyMj / frames).toFixed(2); }
  if (first.charge_uah > 0 && end.charge_uah > 0) out.charge_uah = Math.round(first.charge_uah - end.charge_uah);
  return out;
}

async function runPower(seconds) {
  const ms = seconds * 1000;
  const native = NATIVE;
  const scenarios = [
    ["idle (nothing moving)", async () => { $("stage").textContent = ""; await new Promise((r) => setTimeout(r, ms)); return 0; }],
    ["animate 200 boxes", () => animateBoxes(200, ms)],
    ["canvas 1000 balls", () => canvasBalls(1000, ms)],
  ];
  if (native) scenarios.push(["canvas 1000 balls (Zig)", async () => {
    const stage = $("stage");
    stage.textContent = "";
    const el = document.createElement("canvas");
    el.id = "zigballs"; el.width = stage.clientWidth || 600; el.height = stage.clientHeight || 300;
    el.style.width = "100%"; el.style.height = "100%";
    stage.append(el);
    await frame();
    if (!(await invoke("zig_balls", { count: 1000, ms }))) return 0;
    let res;
    do { await new Promise((d) => setTimeout(d, 250)); res = await invoke("zig_balls_result"); } while (!res.done);
    return res.frames;
  }]);
  const out = [];
  for (const [i, [name, work]] of scenarios.entries()) {
    $("status").textContent = `Power ${i + 1} of ${scenarios.length}: ${name} (${seconds} s)…`;
    const r = await measurePower(name, work);
    out.push(r);
    const tr = document.createElement("tr");
    tr.innerHTML = r.error
      ? `<td>power: ${name}</td><td colspan="2" class="muted">${r.error}</td>`
      : `<td>power: ${name}</td><td>${r.mw} mW</td><td class="muted">${r.joules} J in ${r.seconds} s${r.fps !== undefined ? ` · ${r.fps} fps · ${r.mj_per_frame} mJ/frame` : ""}${r.charge_uah !== undefined ? ` · ${r.charge_uah} µAh` : ""} · ${r.source}${r.plugged ? " · ON A CHARGER: not meaningful" : ""}</td>`;
    $("rows").append(tr);
  }
  $("stage").textContent = "";
  $("status").textContent = "Power done.";
  results.power = out;
  return out;
}

async function run() {
  $("rows").textContent = "";
  $("run").disabled = true;
  const steps = [
    () => timeBuild(1000), () => timeBuild(3000),
    () => timeUpdate(1000), () => timeUpdate(3000),
    () => timeAnimation(200, 2000),
    () => timeCanvasBalls(200, 2000), () => timeCanvasBalls(1000, 2000),
  ];
  for (const [i, step] of steps.entries()) {
    $("status").textContent = `Running ${i + 1} of ${steps.length}…`;
    await step();
  }
  $("stage").textContent = "";
  await frame();
  // As a window that has been idle a moment: the native renderer gives a
  // removed list's memory back a while after (Tree.trimPools).
  await new Promise((r) => setTimeout(r, 2500));
  show("memory after the tests (PSS, all processes)", [await invoke("pss_mb")], "MB");
  show("private memory after the tests (all processes)", [await invoke("private_mb")], "MB");
  $("status").textContent = "Done.";
  $("run").disabled = false;
  return results;
}

(async () => {
  const startup = await invoke("since_start");
  trace = await invoke("trace_on").catch(() => false);
  const renderer = NATIVE ? "native" : "WebView";
  $("renderer").textContent = renderer;
  show("startup → page script", [startup]);
  await frame();
  show("startup → first frame", [await invoke("since_start")]);
  show("memory at start (PSS, all processes)", [await invoke("pss_mb")], "MB");
  show("private memory at start (all processes)", [await invoke("private_mb")], "MB");
  await run();
  // A second round: memory that grows again is a leak, memory reused from the
  // first round isn't.
  if (await invoke("bench_mode_on")) {
    const first = results["memory after the tests (PSS, all processes)"];
    const firstPrivate = results["private memory after the tests (all processes)"];
    await run();
    results["memory after a second round (PSS, all processes)"] = results["memory after the tests (PSS, all processes)"];
    results["private memory after a second round (all processes)"] = results["private memory after the tests (all processes)"];
    results["memory after the tests (PSS, all processes)"] = first;
    results["private memory after the tests (all processes)"] = firstPrivate;
  }
  $("run").addEventListener("click", run);
  $("power").addEventListener("click", async () => { $("power").disabled = true; await runPower(60); $("power").disabled = false; });
  const powerSecs = await invoke("power_seconds_set").catch(() => 0);
  if (powerSecs > 0) await runPower(powerSecs);
  if (await invoke("bench_mode_on")) await invoke("report", { json: JSON.stringify({ renderer, results }) });
})();
