// Run the same fake-host workload as bench-qjs.js under Node/V8:
// node src/native_ui/js/test/bench-node.mjs src/native_ui/runtime.js examples/render-bench/web
// Add --jitless before the script to compare V8's interpreter.
import { readFileSync } from "node:fs";

globalThis.scriptArgs = process.argv.slice(1);
globalThis.print = console.log.bind(console);
// The runtime installs its DOM globals and microtask shim in QuickJS.
// Node's built-in Event is incompatible with LinkeDOM dispatch.
for (const key of ["Event", "CustomEvent", "EventTarget", "queueMicrotask"]) delete globalThis[key];

const source = readFileSync(new URL("./bench-qjs.js", import.meta.url), "utf8");
const adapted = source.replace('import * as std from "qjs:std";', `
import { readFileSync } from "node:fs";
const std = { loadFile(path) {
  try { return readFileSync(path, "utf8"); } catch { return null; }
} };
`);
await import(`data:text/javascript;base64,${Buffer.from(adapted).toString("base64")}`);
