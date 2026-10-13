// Run against the real QuickJS/native DOM, which can suppress detached
// mutation hooks. Node/LinkeDOM alone cannot detect this regression.
// zig build dom-bench -Doptimize=ReleaseFast
// node src/native_ui/js/test/theme-color-native.test.mjs [dom_bench] [runtime]
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import assert from "node:assert/strict";

const root = fileURLToPath(new URL("../../../../", import.meta.url));
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "oriel-theme-color-"));
const script = path.join(dir, "test.js");
const prefix = `
const themeCalls = [];
let mutationHooks = 0;
const nativeObserve = __nuiDom.observe;
__nuiDom.observe = (hook, connectedOnly) => nativeObserve(
  hook ? (...args) => { mutationHooks++; return hook(...args); } : null,
  connectedOnly
);
globalThis.__host = {
  document,
  asset: p => p === "index.html" ? '<html><head><meta name="theme-color" content="#336699"></head><body><p>hi</p></body></html>' : undefined,
  log: (level, message) => { if (level >= 3) throw new Error(message); },
  invoke: (id, cmd, args) => { if (cmd === "oriel:window:setThemeColor") themeCalls.push(JSON.parse(args)); },
  timer() {}, frame() {}, focus() {}, scrollIntoView() {}, scrollTo() {}, ops() {},
  platform: JSON.stringify({ os: "android", arch: "aarch64" }), label: "main", url: "index.html"
};
`;
const suffix = `
function check(ok, message) { if (!ok) throw new Error(message); }
__oriel.boot(400, 600, false, false);
__oriel.render();
check(JSON.stringify(themeCalls[0].color) === "[51,102,153,255]", "initial theme color");
const start = mutationHooks;
const list = document.createElement("div");
for (let i = 0; i < 100; i++) {
  const row = document.createElement("div");
  row.className = "row";
  row.innerHTML = '<span class="n">' + i + '</span><span>Row ' + i + '</span>';
  list.append(row);
}
check(mutationHooks === start, "internal theme watcher must not report detached construction");
document.body.append(list);
check(mutationHooks > start, "connected insertion still reaches the renderer");
document.querySelector("meta").setAttribute("content", "#ff0000");
// Native mutation observers deliver callbacks through QuickJS promise jobs.
Promise.resolve().then(() => {
  check(JSON.stringify(themeCalls.at(-1).color) === "[255,0,0,255]", "changed theme color");
  const mo = new MutationObserver(() => {});
  mo.observe(list, { subtree: true, childList: true });
  list.remove();
  mo.takeRecords();
  const child = document.createElement("p");
  list.append(child);
  check(mo.takeRecords().some(r => r.target === list && r.addedNodes[0] === child), "page observers still see detached changes");
  mo.disconnect();
  const before = mutationHooks;
  list.append(document.createElement("p"));
  check(mutationHooks === before, "disconnect restores connected-only hooks");
  print("native theme color: ok");
});
`;
try {
  fs.writeFileSync(script, prefix + fs.readFileSync(process.argv[3] || path.join(root, "src/native_ui/runtime.js"), "utf8") + suffix);
  const output = execFileSync(process.argv[2] || path.join(root, "zig-out/bin/dom_bench"), [script], { encoding: "utf8" });
  assert.equal(output.trim(), "native theme color: ok", "native assertions must finish, including promise jobs");
  process.stdout.write(output);
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}
