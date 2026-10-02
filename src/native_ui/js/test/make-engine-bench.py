#!/usr/bin/env python3
"""Package bench-qjs.js for engine CLIs without a common filesystem API.

Inlining the unchanged runtime also lets an AOT compiler compile its hot loops.
Parsing, boot, native layout and paint remain outside the reported timings.
"""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--trace", action="store_true", help="Untimed operation verification")
args = parser.parse_args()
root = Path(__file__).resolve().parents[4]
web = root / "examples/render-bench/web"
assets = {"web/" + p.relative_to(web).as_posix(): p.read_text()
          for p in sorted(web.rglob("*")) if p.is_file()}
source = (root / "src/native_ui/js/test/bench-qjs.js").read_text()
source = source.replace('import * as std from "qjs:std";',
                        "const assets = " + json.dumps(assets) + ";\n"
                        "const std = { loadFile(p) { return assets[p] ?? null; } };\n"
                        'const scriptArgs = ["bench", "inline", "web"];')
source = source.replace("const now = () => performance.now();",
                        "const clock = globalThis.performance?.now?.bind(globalThis.performance)"
                        " ?? Date.now.bind(Date);\nconst now = () => clock();")
source = source.replace("(0, eval)(std.loadFile(runtimePath));",
                        (root / "src/native_ui/runtime.js").read_text())
if args.trace:
    source = source.replace("let opsBytes = 0, opsCalls = 0;",
                            "let opsBytes = 0, opsCalls = 0; const trace = [];")
    for signature, record in [
        ("ops: (json) => {", '["ops", json]'),
        ("text: (id, text) => {", '["text", id, text]'),
        ("leafStyle: (id, json) => {", '["style", id, json]'),
        ("leaf: (id, style, text, isText) => {", '["leaf", id, style, text, isText]'),
    ]:
        source = source.replace(signature, signature + f" trace.push({record});")
    source = source.replace("async function t(label, fn) {",
                            "async function t(label, fn) { trace.length = 0;")
    start = source.index("  print(`${label.padEnd(22)}")
    end = source.index("\n}", start)
    source = source[:end] + '\n  print("TRACE " + JSON.stringify([label, trace]));' + source[end:]
prefix = """const output = typeof print === "function" ? print : console.log.bind(console);
globalThis.print = output;
for (const key of ["navigator", "Event", "CustomEvent", "EventTarget", "queueMicrotask"]) delete globalThis[key];
async function benchmark() {
"""
suffix = """
}
benchmark().then(() => print("BENCH_DONE"), e => {
  print("BENCH_FAILED", String(e), e.stack || "");
});
"""
args.output.write_text(prefix + source + suffix)
