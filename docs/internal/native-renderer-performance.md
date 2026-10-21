# Native renderer performance

[Documentation](../README.md) · [Native renderer](../native-renderer.md) · [Experiment history](../design/native-renderer-performance-history.md)

Updated 2026-10-12 from the published site and tracked benchmark reports.
This page separates the site's 2026-10-03 hardware results from the later
2026-10-04 software-rendered diagnostics. Dates, displays, renderers, and
measurement methods matter: a newer run is not automatically a replacement
for a run on different hardware.

## Theme-color observer regression, 2026-10-12

A Pixel 8 report shows native builds at 51.93 / 217.21 ms and updates at
41.28 / 74.73 ms for 1,000 / 3,000 rows, against WebView's 23.10 / 73.10 ms
builds and 9.80 / 27.10 ms updates. Both renderers reach approximately
120 fps in the reported animation/canvas workloads. The user confirmed the
earlier native APK was the build immediately before this fix; its optimization
was not separately recorded. These phone screenshots remain separate from
the docs' measurements on different hardware.

After receiving the fixed arm64 ReleaseFast APK with profiling disabled,
the user supplied a new Pixel 8 screenshot:

| Phone workload | Earlier native | Fixed APK | WebView reference |
|---|---:|---:|---:|
| Build 1,000 rows | 51.93 ms | **14.37 ms** | 23.10 ms |
| Build 3,000 rows | 217.21 ms | **97.54 ms** | 73.10 ms |
| Update 1,000 rows | 41.28 ms | **14.19 ms** | 9.80 ms |
| Update 3,000 rows | 74.73 ms | **38.42 ms** | 27.10 ms |

Observed row time falls 49–72%. Construction of 1,000 rows now leads the
WebView reference; construction of 3,000 rows and both update workloads
still trail it. This is one screenshot per variant with uncontrolled
thermal/background state. The user identified the earlier APK as immediately
pre-fix; its build mode was not separately recorded. In
particular, the much larger phone update improvement cannot be attributed
entirely to the observer fix from the Linux comparison below.

PSS rises from 72.71 to 92.67 MB, and private memory from 53.06 to 78.05 MB.
These snapshots do not establish a leak. Despite the screenshots' "all
processes" label, render-bench reads the app's accessible `/proc` process
tree. Android's isolated WebView renderer is spawned under `webview_zygote`,
outside that tree, and is not included. Thus the WebView's 96.79 MB PSS and
52.99 MB private reading are not combined app-plus-renderer totals and
cannot establish the native/WebView total-memory difference. New Android
benchmark labels say "app process tree" and explicitly note the exclusion.
Use external `adb shell dumpsys meminfo` readings of the app and its
identified isolated renderer at the same benchmark endpoint for a fair total.
[Android WebView memory/process accounting](https://developer.android.com/develop/ui/views/layout/webapps/manage-webview-memory).

Animation is 115.41 fps, while
canvas medians remain near 120 fps; the 1,000-ball Zig canvas includes a
52.84 fps trial that needs a repeated run to assess stability. The screenshot
shows power measurement starting but supplies no power results.
[Transcribed phone trials and APK identity](../../examples/render-bench/results/2026-10-12-pixel8-screenshots.json).

The local investigation nevertheless reproduces a construction regression
in the shared runtime. `41faf78` (2026-10-04) added an internal theme-color
MutationObserver without the runtime's `__nuiConnectedOnly` marker. The
native DOM consequently enables hooks for every detached mutation across
the document, including row parsing and list construction, although this
observer only watches the head. The fix marks the watcher as internal,
retaining normal page observers' detached notifications.

Three serial processes per variant, rotated order, ReleaseFast, private
Xvfb at 1024×768, 900×700 windows, software Cairo rendering. Nine pooled
second-round samples per row workload, including synchronous layout:

| Metric | Before (`69a47ec`) | Fixed | Historical (`c0615af`) |
|---|---:|---:|---:|
| Build 1,000 rows | 18.62 ms | **7.71 ms** | 6.91 ms |
| Build 3,000 rows | 54.85 ms | **21.43 ms** | 19.70 ms |
| Update 1,000 rows | 4.22 ms | 4.20 ms | 3.23 ms |
| Update 3,000 rows | 13.86 ms | 12.45 ms | 9.50 ms |
| Whole-process user instructions, median | 15.51 billion | 9.75 billion | 7.82 billion |

Construction improves 59–61%, close to the historical baseline on this
same setup. Updates remain slower than that baseline; do not claim they
are fixed. Before/after larger-update trial ranges overlap. Counter runs
include startup, both rounds and idle painting, not just timed rows.
Row-only memory is not comparable to full-suite memory. These Linux
results establish neither Pixel 8 timings nor energy savings.

Tools used: `perf record` with DWARF stacks, `perf stat` for user cycles
and instructions, the native DOM-only benchmark, and `-Dnative_ui_prof`
stage logging. In the sampled row-only pair, `JS_CallInternal` drops from
21.29% to 8.81% of self samples; absolute instruction counts provide the
separate work-reduction evidence. Stage logging confirms that construction
still uses list stamping and text updates still use row stamping. The
previous text log reported zero leaves/direct calls and charged stamped
native work to preparation; it now reports stamped rows and includes
their calls in apply time.

The final instrumented full suite also completes both rounds; animation
and JavaScript/Zig canvas stay at the private display's approximately
60 Hz limit. The corrected first-round text logs split 3,000 stamped rows
into 2.25–2.66 ms of preparation and 2.76–3.30 ms in native stamping.
Treat these stage samples as diagnostics, separately from the serial
comparison above. JavaScript, Zig, DOM and typed-dispatch checks pass.

Next priorities supported by this review:

1. **Profile text updates on the Pixel 8.** Separate mutation hooks, row
   stamping, batched Android text measurement, Yoga and frame publication.
   Desktop diagnostics show about 12 ms in the first 3,000-row update's
   synchronous layout and about 5 ms in later stamped-update preparation
   plus native work; these are instrumented observations, not phone timings.
2. **Measure cold layout separately from repeated text edits.** New
   3,000-row lists invoke Yoga's measure callback about 12,000 times in the
   desktop stage trace, mostly hitting cached text sizes. Optimize repeated
   layout work without changing synchronous geometry or font baselines.
3. **Keep internal observers from enabling page-wide detached hooks.**
   The new `test-native-runtime` check runs the production bundle on
   QuickJS/the native DOM, fails on the old bundle, checks live theme-color
   changes, and verifies detached records for page observers and restored
   suppression after disconnect. LinkeDOM tests alone cannot detect this.

[Raw samples, counters, profiled pairs and conditions](../../examples/render-bench/results/2026-10-12-theme-observer-rows.json).
Reproduction commands are in the [render-bench README](../../examples/render-bench/README.md).

## Third renderer: compiled Zig views, 2026-10-12

The benchmark now offers `-Drenderer=oriel` (called `zig` in the 2026-10-12
runs below) alongside `webview` and `native`.
It compiles `.oriel` templates into the existing native tree and runs events,
state and canvas loops in Zig, without QuickJS, DOM or CSS processing. The
full benchmark workloads and controls remain available; this is an experimental
view API with explicit stable identities, not a complete component framework.
[Architecture and scope](../design/zig-ui-experiment.md).

Three serial processes per renderer, rotated order, ReleaseFast, private Xvfb
at 1024×768, 900×700 windows and Cairo. Nine pooled second-round samples:

| Workload | WebView | Native JS (observer fixed) | Zig UI |
|---|---:|---:|---:|
| Build 1,000 rows | 18 ms | 7.79 ms | 7.09 ms |
| Build 3,000 rows | 51 ms | 21.55 ms | 19.57 ms |
| Update 1,000 rows | 8 ms | 4.28 ms | 0.70 ms |
| Update 3,000 rows | 25 ms | 12.84 ms | 1.74 ms |

Construction improves about 9%; updates improve 84–86% relative to the fixed
JavaScript native mode in this desktop diagnostic. Layout stays inside timing,
painting outside. Rows are fully instantiated. Zig uses native templates and
text updates, with no DOM/CSS synchronization; its shell uses native rows
rather than an HTML table. Native font measurement, Yoga and platform drawing
remain. These results do not establish Android timings or energy savings.

The full two-round Zig suite completes all box/canvas workloads near the
private display's 60 Hz ceiling. Its primary canvas uses f64 Zig physics in
place of JavaScript; the direct `(Zig)` variant reuses the existing f32 code.
The four power scenarios correctly report an unavailable desktop energy source.
Android arm64 ReleaseFast builds with the existing host; Pixel 8 measurements
remain to be collected. Tests cover ownership, keyed identity and frame pacing.
[Raw samples, perf counters, conditions and full-suite diagnostic](../../examples/render-bench/results/2026-10-12-three-renderers-desktop.json).

## Poco X3 device measurements, 2026-10-13

The compiled-view Oriel mode, fixed native JS mode and WebView were tested on
the connected M2007J20CG, Android 12, arm64 ReleaseFast, unplugged over Wi-Fi
ADB. Original brightness and the 60 Hz peak refresh limit were retained.
Power uses a fixed visible 320 × 240 viewport with result publication deferred;
this avoids the original table shrinking or clipping the drawing area.

| Measurement | Oriel | Native JS | WebView |
|---|---:|---:|---:|
| External combined PSS snapshots | 89–111 MiB | 103–122 MiB | 196–202 MiB |
| Idle whole-device draw | 1.17 W | 1.11 W | 0.98 W |
| 200 boxes whole-device draw | 1.39 W | 2.64 W | 2.15 W |
| 1,000 balls whole-device draw | 1.68 W | 3.25 W* | 2.09 W |
| 1,000 balls scenario-average FPS | 59.8 | 33.6* | 58.9 |
| Direct Zig balls draw | 1.88 W | 2.05 W | — |

The box scenario's average draw falls about 48% versus native JS and 36%
versus WebView, at approximately 60 fps. Idle does not improve. Memory was
sampled separately through dumpsys meminfo, including the isolated WebView
renderer associated by ActivityManager packageList. Native/Oriel ranges overlap
and post-suite snapshot times differ; avoid a precise improvement percentage.
In-app /proc PSS omits graphics accounting, and Pss_Anon (“private”) is absent
on this device and shown as zero. These in-app fields were excluded from totals.

*The standard native-JS canvas scenario lasted 80.2 seconds for a requested
60. Its average watts/FPS include the whole scenario; the cause is uninvestigated.
Do not compare total joules as equal-duration work or treat the reported FPS
as isolated steady-state drawing throughput. The other scenarios lasted about
60 seconds. One pass in fixed order, different thermal/background state and
whole-device current/voltage sampling supply no confidence interval or general
battery-life conclusion. Charge-counter steps were too coarse for attribution.

The device test also caught typed dimension/corner serialization mismatching
the native parser; explicit wire serialization and round-trip tests now preserve
sizes and radii. Both native test suites pass. The original APK, screen timeout
and debug property were restored after testing.
[Complete raw reports, APK hashes and limitations](../../examples/render-bench/results/2026-10-13-poco-x3-memory-power.json).

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
[experiment history](../design/native-renderer-performance-history.md). For this run,
native row construction is about 3.1–3.7 times faster than WebView, and row
updates about 3.2–4.7 times faster. These are workload-specific observations,
not a guarantee for every page.

Source: [published native-renderer page](https://oriel.foreachdeveloper.com/docs/native-renderer/#speed)
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

Source: [published platform comparison](https://oriel.foreachdeveloper.com/docs/native-renderer/#on-every-platform).

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

Source: [published Android comparison](https://oriel.foreachdeveloper.com/docs/native-renderer/#on-android-against-react-native-and-plain-views).

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
parsing also changed the path. See the [native DOM implementation notes](../design/native-dom.md)
and the site's [implementation discussion](https://oriel.foreachdeveloper.com/docs/native-renderer/).

The old 122.37 ms build, 10.85 ms update, and statements that native row
construction trails WebView belong to those historical configurations. They
are preserved with their original evidence in the
[experiment history](../design/native-renderer-performance-history.md), rather than
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
