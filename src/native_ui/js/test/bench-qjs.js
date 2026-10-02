// The native runtime in plain qjs with a fake host: times the render-bench
// steps (DOM work, render = style+flatten+emit) without GTK.
// From the repository root:
// qjs src/native_ui/js/test/bench-qjs.js src/native_ui/runtime.js examples/render-bench/web
import * as std from "qjs:std";
const [runtimePath, dir] = scriptArgs.slice(1);
const now = () => performance.now();
let opsBytes = 0, opsCalls = 0;
const timers = new Map();
globalThis.__host = {
  log: (l, m) => print(["dbg", "info", "WARN", "ERR"][l], m),
  asset: (p) => std.loadFile(dir + "/" + p) ?? undefined,
  invoke: (id, cmd) => { pendingInvokes.push([id, cmd]); },
  timer: (id, ms) => timers.set(id, ms),
  ops: (json) => { opsBytes += json.length; opsCalls++; if (globalThis.PARSE) JSON.parse(json); },
  // The direct native text bridge transfers the string alone. Count its
  // payload here; ids are passed as numbers, not encoded as JSON.
  text: (id, text) => { opsBytes += text.length; return true; },
  leafStyle: (id, json) => { opsBytes += json.length; return true; },
  leaf: (id, style, text, isText) => { opsBytes += text.length; return true; },
  frame: () => [0, 0, 600, 400, 400],
  focus() {}, scrollIntoView() {}, scrollTo() {},
  now,
  platform: JSON.stringify({ os: "linux" }), label: "main", url: "index.html", prof: false,
};
const pendingInvokes = [];
// Don't run the page's app.js: replace its asset with nothing.
const realAsset = __host.asset;
__host.asset = (p) => p === "app.js" ? "" : realAsset(p);
(0, eval)(std.loadFile(runtimePath));
__oriel.boot(900, 700, true, false);
__oriel.render();
const $ = (id) => document.getElementById(id);
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
async function t(label, fn) {
  const a = now(); fn(); const b = now();
  await null; await null;
  opsBytes = 0;
  const c = now(); __oriel.render(); const d = now();
  const T = globalThis.__T; let extra = "";
  if (T) { extra = " " + Object.entries(T).map(([k, v]) => `${k} ${v.toFixed(1)}`).join(" "); for (const k in T) delete T[k]; }
  print(`${label.padEnd(22)} dom ${(b - a).toFixed(1).padStart(7)}  render ${(d - c).toFixed(1).padStart(7)}  ops ${(opsBytes / 1024).toFixed(0)}KB${extra}`);
}
const stage = $("stage");
for (const n of [1000, 3000]) {
  for (let r = 0; r < 2; r++) await t(`build ${n}`, () => { stage.textContent = ""; buildRows(stage, n); });
  let list;
  await t(`setup ${n}`, () => { stage.textContent = ""; list = buildRows(stage, n); });
  for (let r = 0; r < 2; r++) await t(`update ${n}`, () => { let i = 0; for (const row of list.children) row.lastElementChild.textContent = `Row ${i++}: updated ${r}`; });
  await t(`no change ${n}`, () => { $("status").setAttribute("data-x", String(n)); });
}
let boxes;
await t("setup boxes", () => {
  stage.textContent = "";
  boxes = [];
  for (let i = 0; i < 200; i++) { const b = document.createElement("div"); b.className = "box"; stage.append(b); boxes.push(b); }
});
for (let f = 0; f < 3; f++) await t("animate frame", () => {
  for (let i = 0; i < 200; i++) boxes[i].style.transform = `translate(${(i * 3 + f).toFixed(1)}px, ${(i * 2 + f).toFixed(1)}px)`;
});
let ctx;
for (const count of [200, 1000]) {
  await t("setup canvas", () => { stage.textContent = ""; const el = document.createElement("canvas"); el.width = 600; el.height = 400; stage.append(el); ctx = el.getContext("2d"); });
  for (let f = 0; f < 3; f++) await t(`canvas ${count}`, () => {
    ctx.fillStyle = "#10141b"; ctx.fillRect(0, 0, 600, 400);
    const colors = ["#6d8bff", "#e8555a", "#3ad07a", "#e8c55a", "#e8eaee"];
    for (let i = 0; i < count; i++) { ctx.beginPath(); ctx.arc((i * 37 + f) % 600, (i * 23 + f) % 400, 6, 0, 2 * Math.PI); ctx.fillStyle = colors[i % 5]; ctx.fill(); }
    ctx.fillStyle = "#e8eaee"; ctx.font = "12px sans-serif"; ctx.textBaseline = "top"; ctx.fillText(`${count} balls`, 8, 8);
  });
}
