// Render bench: the same page in Oriel's WebView and native renderers.
// Times are milliseconds on performance.now(): DOM work plus the layout a
// forced read (offsetHeight) triggers. Painting isn't included, in either.
const $ = (id) => document.getElementById(id);
const invoke = (cmd, args) => window.oriel.invoke(cmd, args);
const frame = () => new Promise((r) => requestAnimationFrame(r));
const median = (xs) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];
const RUNS = 3;

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
    const t0 = performance.now();
    let i = 0;
    for (const row of list.children) row.lastElementChild.textContent = `Row ${i++}: updated ${r}`;
    void list.offsetHeight;
    runs.push(performance.now() - t0);
    await frame();
  }
  show(`update ${n} rows`, runs);
}

async function timeAnimation(count, ms) {
  const stage = $("stage");
  const runs = [];
  for (let r = 0; r < RUNS; r++) {
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
    runs.push(frames / ((performance.now() - t0) / 1000));
  }
  show(`animate ${count} boxes`, runs, "fps");
}

async function run() {
  $("rows").textContent = "";
  $("run").disabled = true;
  const steps = [
    () => timeBuild(1000), () => timeBuild(3000),
    () => timeUpdate(1000), () => timeUpdate(3000),
    () => timeAnimation(200, 2000),
  ];
  for (const [i, step] of steps.entries()) {
    $("status").textContent = `Running ${i + 1} of ${steps.length}…`;
    await step();
  }
  $("stage").textContent = "";
  await frame();
  show("memory after the tests (PSS, all processes)", [await invoke("pss_mb")], "MB");
  $("status").textContent = "Done.";
  $("run").disabled = false;
  return results;
}

(async () => {
  const startup = await invoke("since_start");
  const renderer = window.webkit || window.chrome?.webview ? "WebView" : "native";
  $("renderer").textContent = renderer;
  show("startup → page script", [startup]);
  await frame();
  show("startup → first frame", [await invoke("since_start")]);
  show("memory at start (PSS, all processes)", [await invoke("pss_mb")], "MB");
  await run();
  // A second round: memory that grows again is a leak, memory reused from the
  // first round isn't.
  if (await invoke("bench_mode_on")) {
    const first = results["memory after the tests (PSS, all processes)"];
    await run();
    results["memory after a second round (PSS, all processes)"] = results["memory after the tests (PSS, all processes)"];
    results["memory after the tests (PSS, all processes)"] = first;
  }
  $("run").addEventListener("click", run);
  if (await invoke("bench_mode_on")) await invoke("report", { json: JSON.stringify({ renderer, results }) });
})();
