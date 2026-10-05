# Native renderer performance

[Documentation](README.md) · [Native renderer](native-renderer.md) · [Experiment history](native-renderer-performance-history.md)

Updated 2026-10-05 from the published site and tracked benchmark reports.
This page separates the site's 2026-10-03 hardware results from the later
2026-10-04 software-rendered diagnostics. Dates, displays, renderers, and
measurement methods matter: a newer run is not automatically a replacement
for a run on different hardware.

## Published desktop comparison, 2026-10-03

Linux desktop, 180 Hz display, ReleaseFast; the site reports medians of three
runs. Row timings include the synchronous layout read (`offsetHeight`).

| | Native renderer | WebView (WebKitGTK) |
|---|---|---|
| Build 1000 / 3000 rows | **6.4 / 18.6 ms** | 20 / 69 ms |
| Update 1000 / 3000 rows | **2.8 / 8.5 ms** | 9 / 40 ms |
| Page script runs | **19 ms** after start | 349 ms |
| First frame | **69 ms** | 431 ms |
| Animate 200 boxes | **165 fps** | 62 fps |
| Canvas, 200 / 1000 balls | **180 / 91 fps** (the display's rate is 180) | 62 / 62 fps |
| Memory at start | **110 MB** | 491 MB |
| Memory after the tests | **174 MB**, 177 after a second round | 561 MB |

These figures supersede the old LinkeDOM headline comparisons in the
[experiment history](native-renderer-performance-history.md). For this run,
native row construction is about 3.1–3.7 times faster than WebView, and row
updates about 3.2–4.7 times faster. These are workload-specific observations,
not a guarantee for every page.

Source: [published native-renderer page](https://highercomve.github.io/Oriel/docs/native-renderer/#speed)
and its [tracked source](../site/content/docs/native-renderer.smd). The site
publishes rounded values; a matching raw JSON report for this 180 Hz run is
not tracked under `examples/render-bench/results/`.

## Published platform results

The same benchmark, native renderer, medians of three; ReleaseFast except
Windows, which uses ReleaseSafe. These are the site's hardware results,
not the Android emulator run below. The platform table does not give a
separate measurement date for each device.

| | Build 1000 rows | Update 1000 rows | Animate 200 boxes | Canvas 1000 balls |
|---|---|---|---|---|
| Linux (desktop, 180 Hz) | 6.4 ms | 2.8 ms | 165 fps | 91 fps |
| Windows 11 (a 2018 laptop, 144 Hz) | 18.9 ms | 8.2 ms | 72 fps | 64 fps |
| macOS (M1, 120 Hz display) | 24.9 ms | 15.6 ms | 120 fps | 120 fps |
| iOS (simulator, 60 Hz) | 22.3 ms | 13.8 ms | 60 fps | 60 fps |
| Android (a 120 Hz phone) | 13.8 ms | 18.9 ms | 116 fps | 91 fps |

A workload at the display's refresh rate is capped by that display. Drawing
1,000 canvas balls from Zig rather than JavaScript reaches 179 fps on Linux,
143 on Windows, and 120 on macOS and the Android phone in the site's runs.
Keep these canvas results separate from the 500-ball Breakout game, which
also includes physics and other page work.

Source: [published platform comparison](https://highercomve.github.io/Oriel/docs/native-renderer/#on-every-platform).

## Android hardware comparison

The site's separate comparison uses one arm64 Chromebook with a 60 Hz
display, release builds, and medians of three. React Native is version 0.87
with Fabric and Hermes. It is a different device from the 120 Hz Android
phone in the platform table.

| | Plain Android views | Oriel native | Oriel WebView | React Native |
|---|---|---|---|---|
| Build 1000 rows | 54 ms | **13–14 ms** (35–37 on screen) | 13 ms | 475–514 ms |
| Build 3000 rows | 183 ms | **36–40 ms** (108–188 on screen) | 51 ms | 2284–2700 ms |
| Update 1000 rows | **4.7 ms** | 31 ms (37–38 on screen) | 6.4 ms | 127–161 ms |
| Update 3000 rows | **15 ms** | 74–78 ms (89–91 on screen) | 17.5 ms | 299–302 ms |
| Animate 200 boxes | 60 fps | 59 fps | 45 fps | 59 fps |
| Canvas, 200 / 1000 balls | 60 / 60 fps | 59 / 49 fps | 51 / 48 fps | 60 / 60 fps (Skia) |
| Memory after the tests | 48 MB | 109–114 MB | about 151 MB | 145–157 MB |

Timing endpoints differ: plain views include measurement and layout; Oriel
page time ends when the layout read returns, while “on screen” also includes
Android layout and drawing; WebView measures Chromium layout; React Native
ends when Fabric mounts views on the UI thread. Memory includes all app
processes, including the WebView renderer. Oriel's row construction is faster
in this comparison, while plain views and WebView lead its text updates.

Source: [published Android comparison](https://highercomve.github.io/Oriel/docs/native-renderer/#on-android-against-react-native-and-plain-views).

## Latest recorded desktop diagnostic, 2026-10-04

The callback-tuning comparison uses ReleaseFast, Xvfb at 1280 × 900,
`GDK_BACKEND=x11`, `GSK_RENDERER=cairo`, and an approximately 60 Hz display.
It runs one process per variant and reports second-round medians of three
trials for timed workloads. Startup and memory are individual readings.
The baseline is `3e83d4e`; the updated variant adds typed QuickJS callbacks
and interval cancellation. Both columns are native; this report has no
WebView measurement.

| Metric | Before callbacks | After callbacks |
|---|---:|---:|
| Build 1,000 rows | 7.79 ms | 7.93 ms |
| Build 3,000 rows | 21.76 ms | 21.94 ms |
| Update 1,000 rows | 3.46 ms | 3.50 ms |
| Update 3,000 rows | 10.24 ms | 10.53 ms |
| Startup to page script | 82.02 ms | 55.57 ms |
| Startup to first frame | 130.35 ms | 102.02 ms |
| Animate 200 boxes | 60.15 fps | 60.14 fps |
| Canvas, 1,000 balls (JavaScript) | 60.01 fps | 60.03 fps |
| Canvas, 1,000 balls (Zig) | 59.99 fps | 60.00 fps |
| Memory after tests (PSS, all processes) | 116.87 MB | 117.25 MB |
| Memory after second round (PSS, all processes) | 121.08 MB | 119.80 MB |

The raw report establishes no end-to-end row or canvas win from callback
tuning. Its approximately 60 fps ceiling and software rendering cannot be
compared directly with the site's 165 fps animation or 91 fps canvas result
on the 180 Hz desktop. Startup improved in this pair; one pair does not
establish a repeatable improvement or confidence interval.

[Raw samples and conditions](../examples/render-bench/results/2026-10-04-native-dispatch-desktop.json).

## Latest recorded Android emulator diagnostic, 2026-10-04

Android 35 x86_64 emulator, lavapipe Vulkan / swangle GLES software graphics,
ReleaseFast, one process and two rounds. Second-round medians are
12.64 / 33.77 ms to build 1,000 / 3,000 rows and
6.57 / 19.05 ms to update them. Animation reaches 60.21 fps;
JavaScript canvas with 1,000 balls reaches 59.41 fps. PSS after the tests
is 47.08 MB, across all processes.

There is no Android before/after comparison in this report, and emulator
results do not establish physical-device energy use.

[Raw emulator report](../examples/render-bench/results/2026-10-04-native-android-emulator.json).

## Why the old numbers differ

The 2026-10-02 investigation optimized a JavaScript-owned LinkeDOM and
JavaScript flattening path. The default renderer now uses the native DOM;
common rows and lists are stamped from its Zig store. Incremental updates,
QuickJS changes, build-time bytecode, cached glyph widths, pooled nodes,
transform-only animation, display-paced frames, and build-time stylesheet
parsing also changed the path. See the [native DOM implementation notes](native-dom.md)
and the site's [implementation discussion](https://highercomve.github.io/Oriel/docs/native-renderer/).

The old 122.37 ms build, 10.85 ms update, and statements that native row
construction trails WebView belong to those historical configurations. They
are preserved with their original evidence in the
[experiment history](native-renderer-performance-history.md), rather than
presented as the current renderer's headline results.

## Current priorities after callback tuning, 2026-10-04

The typed QuickJS dispatch pass reduced isolated callback overhead but did
not establish an end-to-end win in render-bench or the 500-ball JS game.
On a diagnostic 12-second desktop Breakout run, native painting had a
2.68 ms median, the page call 1.79 ms, and layout 0.02 ms. Profiling adds
overhead, game states are unseeded, and stage medians must not be added as
one representative frame. They identify where to investigate next.

Android now retains requested display frames while hidden or detached,
removes the posted Choreographer callback, and resumes it on visibility
or reattachment. Render-bench on the Android 35 x86_64 emulator advanced
its trace counter by 480 during eight hidden seconds before the change,
and zero after it; both resumed drawing. Timers and services retain their
existing behavior. This establishes eliminated background frame work,
not a whole-device energy reduction.

Next experiments, each requiring a new before/after comparison:

1. **Canvas recording and command storage.** Profile recorder writes,
   native decoding and Android unpacking separately. The Android hardware
   path already draws directly to the GPU; adding hardware acceleration
   again would not help. It still creates a `CvOp` object per command and
   a new `Replay` with paths, matrices, paints and arrays for each replay.
   Reusable bounded command storage and replay state could reduce GC and
   per-frame allocation. A native recorder for hot 2d methods could also
   replace interpreted numeric-buffer writes, while retaining normal
   canvas semantics and the JavaScript implementation as fallback.
2. **Retained painting and batched shapes.** GTK replays each canvas
   program even when an unrelated page edit caused the repaint, and its
   circle-mask fast path covers only a lone circle. Breakout groups 16
   circles in each path. Measure retained raster/display-list caching and
   a batch fast path with correct overlap, alpha, clipping and fill rules.
   Android's existing circle batching is a useful comparison. Reuse static
   content without changing canvas persistence or transparent compositing.
3. **Explicit lazy lists.** Large feeds need a model-backed visible-row
   list with reuse (RecyclerView or equivalent), rather than allocating
   and laying out every row. Preserve the full-DOM benchmark and its
   synchronous geometry guarantees; this is an additional application API,
   not an invisible replacement for ordinary HTML lists.

[Raw callback-tuning comparison](../examples/render-bench/results/2026-10-04-native-dispatch-desktop.json),
[background scheduling checks and diagnostic stage timings](../examples/render-bench/results/2026-10-04-android-background-frames.json).
