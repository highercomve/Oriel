#!/usr/bin/env python3
"""On-screen times from an Android run with ORIEL_NUI_TRACE (README.md):
for each timed row change, the first native-renderer draw after the page's
mark, by logcat's timestamps. Usage: onscreen.py <adb logcat -d -v epoch file>"""
import re, statistics, sys

marks, draws = [], []
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r"\s*(\d+\.\d+)\s", line)
    if not m:
        continue
    t = float(m.group(1)) * 1000
    if "bench mark:" in line:
        marks.append((t, line.split("bench mark:")[1].strip().rsplit(" #", 1)[0]))
    elif "nui drawn" in line:
        draws.append(t)
runs = {}
for t, name in marks:
    d = next((x for x in draws if x > t), None)
    if d is not None:
        runs.setdefault(name, []).append(d - t)
for name, v in runs.items():
    print(f"{name}: on screen {statistics.median(v):.0f} ms (runs {' · '.join(f'{x:.0f}' for x in v)})")
