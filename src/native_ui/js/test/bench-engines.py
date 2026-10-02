#!/usr/bin/env python3
"""Verify and measure packaged bench-qjs.js across engine CLIs.

Build engines and package scripts first. A JSON config maps engine names to
{command: [...], trace_command: [...], ...metadata}. Commands must point to
the generated regular and --trace scripts (or their compiled equivalents).
Run on an idle machine; trace checks are separate from timing observations.
"""
import argparse
import hashlib
import json
import re
import statistics
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("config", type=Path)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--rounds", type=int, default=3)
args = parser.parse_args()
if args.rounds < 1:
    parser.error("--rounds must be positive")
config = json.loads(args.config.read_text())
result = {"method": "Same inlined runtime/fixture, fake host; excludes boot, native apply/layout/paint",
          "config": config, "engines": {}}
row = re.compile(r"^(.+?)\s+dom\s+([\d.]+)\s+render\s+([\d.]+)\s+ops\s+(\d+)KB$")


def execute(command, allow_partial=False):
    process = subprocess.run(command, capture_output=True, text=True, timeout=180)
    output = process.stdout + process.stderr
    if process.returncode or (not allow_partial and ("BENCH_DONE" not in output or re.search(r"BENCH_FAILED|^ERR ", output, re.M))):
        raise RuntimeError(f"exit={process.returncode}\n{output[-4000:]}")
    return output


baseline = None
for name, engine in config["engines"].items():
    record = result["engines"][name] = {"samples": [], "verification": {}}
    try:
        output = execute(engine["trace_command"], allow_partial=True)
        traces = [json.loads(line[6:]) for line in output.splitlines() if line.startswith("TRACE ")]
        if len(traces) < 12:
            raise RuntimeError(f"Expected at least 12 row steps, got {len(traces)}\n{output[-1000:]}")
        if baseline is None:
            if len(traces) != 24 or "BENCH_DONE" not in output or "BENCH_FAILED" in output:
                raise RuntimeError("Reference must complete all 24 steps")
            baseline = traces
        if traces[:12] != baseline[:12]:
            raise RuntimeError("Row host transcript differs")
        differences = [i for i, (a, b) in enumerate(zip(traces, baseline)) if a != b]
        digest = hashlib.sha256(json.dumps(traces, separators=(",", ":")).encode()).hexdigest()
        record["verification"] = {"equal": traces == baseline, "rows_equal": True,
                                  "steps": len(traces), "differing_steps": differences, "sha256": digest,
                                  "completion": "BENCH_DONE" in output, "failure": output.split("BENCH_FAILED", 1)[-1][-1000:] if "BENCH_FAILED" in output else None}
        print(f"{name}: rows match; full transcript equal={traces == baseline}; completed={len(traces)}", flush=True)
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        if baseline is None:
            raise RuntimeError("Baseline verification must succeed") from error
        record["verification"] = {"equal": False, "rows_equal": False, "error": str(error)}
        print(f"{name}: verification failed: {error}", flush=True)

for iteration in range(args.rounds):
    # Rotate engine order between rounds to reduce systematic ordering bias.
    names = list(config["engines"])
    names = names[iteration % len(names):] + names[:iteration % len(names)]
    for name in names:
        record = result["engines"][name]
        if not record["verification"]["rows_equal"]:
            continue
        output = execute(config["engines"][name]["command"], allow_partial=True)
        samples = []
        for line in output.splitlines():
            match = row.match(line)
            if match:
                label, dom, render, payload = match.groups()
                samples.append({"step": label, "dom_ms": float(dom), "render_ms": float(render),
                                "payload_kb_rounded": int(payload), "round": iteration + 1})
        if len(samples) < 12:
            raise RuntimeError(f"{name}: expected at least 12 row observations, got {len(samples)}")
        record.setdefault("timing_completions", []).append({"round": iteration + 1,
            "steps": len(samples), "completed": "BENCH_DONE" in output,
            "failure": output.split("BENCH_FAILED", 1)[-1][-1000:] if "BENCH_FAILED" in output else None})
        record["samples"].extend(samples)
        print(f"{name}: round {iteration + 1} complete", flush=True)

for name, record in result["engines"].items():
    record["medians"] = {}
    for label in dict.fromkeys(sample["step"] for sample in record["samples"]):
        samples = [sample for sample in record["samples"] if sample["step"] == label]
        record["medians"][label] = {"observations": len(samples), **{
            key: statistics.median(sample[key] for sample in samples)
            for key in ["dom_ms", "render_ms"]}}
    if record["samples"]:
        print(name, json.dumps({key: record["medians"][key] for key in ["build 1000", "build 3000"]}))
args.output.write_text(json.dumps(result, indent=2) + "\n")
