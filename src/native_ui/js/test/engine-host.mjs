// The engine's input rules for a test's fake host: host.tabNext,
// clickFocuses, activates and focusRing answered by interaction.zig itself
// (compiled to WebAssembly, `zig build interaction-wasm`, built here when
// missing), as engine_js.zig answers them in the app. A host's own
// functions stay. host.keyScroll is the engine's (it scrolls the tree):
// here no scroller takes the key; key scrolling is tested in Zig
// (engine_core.zig).
import fs from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../../../../", import.meta.url));
const file = `${root}zig-out/bin/interaction.wasm`;
// Built when missing or older than its sources (`npm test` builds it first).
const sources = ["interaction.zig", "interaction_wasm.zig"].map((f) => `${root}src/native_ui/${f}`);
const stale = !fs.existsSync(file) || sources.some((s) => fs.statSync(s).mtimeMs > fs.statSync(file).mtimeMs);
if (stale) execFileSync("zig", ["build", "interaction-wasm"], { cwd: root, stdio: "inherit" });
const { exports: w } = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(file)), {});
const enc = new TextEncoder();

// `s` in the module's memory, for one call.
function withString(s, fn) {
  const bytes = enc.encode(s);
  const ptr = w.alloc(Math.max(1, bytes.length));
  new Uint8Array(w.memory.buffer, ptr, bytes.length).set(bytes);
  try { return fn(ptr, bytes.length); } finally { w.free(ptr, Math.max(1, bytes.length)); }
}

export function withEngine(host) {
  const platform = () => withString(host.platform || "{}", (p, n) => w.set_platform(p, n));
  // A host's own functions stay; ours (a copied host's too) answer for this one.
  const add = (name, fn) => { if (!host[name] || host[name].fromEngine) host[name] = Object.assign(fn, { fromEngine: true }); };
  add("tabNext", (json, active, back) => { platform(); return withString(json, (p, n) => w.tab_next(p, n, active, !!back)); });
  add("clickFocuses", (kind) => { platform(); return !!w.click_focuses(kind); });
  add("activates", (key, down, repeat, button, link, checkable) => withString(key, (p, n) => !!w.activates(p, n, !!down, !!repeat, !!button, !!link, !!checkable)));
  add("focusRing", (kind, accent) => {
    platform();
    const a = Array.isArray(accent) && accent.length === 3 ? accent : null;
    return [...new Float64Array(w.memory.buffer, w.focus_ring(kind, !!a, a?.[0] ?? 0, a?.[1] ?? 0, a?.[2] ?? 0), 8)];
  });
  add("isScrollKey", (key) => withString(key, (p, n) => !!w.is_scroll_key(p, n)));
  add("keyScroll", () => false);
  return host;
}
