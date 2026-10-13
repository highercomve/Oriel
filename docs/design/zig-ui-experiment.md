# Zig UI renderer experiment

The render-bench example has three explicit build modes: `webview`, `native`
and `oriel` (named `zig` in the 2026-10-12 measurements). The last compiles
`.oriel` views and runs state/events in Zig. It shares Oriel's native tree,
Yoga and platform backends, but does not link the QuickJS or DOM
implementations. Yoga is C++; Android still uses the existing
Kotlin host. “Pure Zig” describes the application and view runtime.

## Views and identity

```zig
const ui = oriel.ui;
const Row = ui.View(@embedFile("views/row.oriel"));
try Row.prepare(&engine.tree, 2000);
_ = try Row.mount(&engine.tree, row_id, 2000, &.{
    .{ .name = "index", .value = index_text },
    .{ .name = "label", .value = label_text },
});
```

The markup parser runs at compile time. Supported tags are `column`, `row`,
`view`, `text`, `button` and `canvas`; style attributes form a deliberately
small schema of native properties. Unknown tags/attributes, duplicate names
and malformed nesting fail compilation. Text supports literals or whole
`{binding}` values. `View.id("name", base)` resolves a named node at compile
time. There is no JavaScript, DOM, stylesheet matching or runtime markup parsing.

Prepare registers shared immutable styles outside workload timing. Mount
creates an owned subtree or updates its existing text using explicit stable
IDs. Text is copied into the tree. Reordering keyed rows retains their node
identity and scroll state; deleting a view frees its owned descendants.
Changing a retained node's kind or style identity returns an error. Dynamic
lists use the tree's existing child-stamping operation, and animation updates
native paint properties directly.

`ui.configure` registers a driver before application startup. Its typed boot,
event, timer and frame callbacks connect to the existing platform lifecycle.
Callbacks added inside a display frame begin on the following frame. The
example state is single-window; this is an experiment, not a general component,
effect, routing or automatic reconciliation framework. JavaScript page APIs
and hot reload are outside this mode's current scope.

## Benchmark equivalence

The experiment implements the same full row counts and styling, text changes,
synchronous native layout endpoint, three trials and two benchmark rounds.
It does not virtualize rows. It also retains the box animation, both canvas
sizes/variants, memory, power and buttons. The primary canvas loop is translated
to Zig using f64 physics; the existing direct Zig canvas is reused unchanged.
Both use the same native canvas backend. The UI shell uses native rows rather
than HTML table layout. View source files live under
[render-bench/views](../../examples/render-bench/views/).

Desktop measurements use ReleaseFast, serial processes, rotated renderer
order, Xvfb at 1024×768 and Cairo drawing. Row timings include synchronous
layout and exclude painting. Whole-process perf counters include startup and
both rounds. The full suite reaches the approximately 60 Hz display ceiling;
power is unavailable on this desktop without readable energy counters.
These measurements do not establish Pixel 8 timings or battery savings.

[Build/run instructions](../../examples/render-bench/README.md) ·
[Raw three-renderer samples and counters](../../examples/render-bench/results/2026-10-12-three-renderers-desktop.json)

## Validation

Root Zig tests cover compiled markup, owned text, keyed reordering, subtree
destruction and next-frame callback scheduling. Both native engines and the
WebView build successfully on Linux; the Zig renderer also builds for Android
arm64 with the existing host. The pure binary has no QuickJS/DOM symbols or
WebKit/JavaScript shared-library dependencies. Full-suite and GUI checks are
separate from performance runs. Private-display clicks verified repeated power
requests replace their previous results and Run again resets the measurement
state; the layout was also inspected at a 410 px window width. Physical Pixel 8 results remain to be collected.

[Readiness review for an official Oriel renderer](../internal/oriel-renderer-readiness.md)
identifies missing primitives and runtime blockers beyond the benchmark.


## System monitor integration

[System monitor](../../examples/system-monitor/README.md) now supports
`-Drenderer=oriel`, retaining its other two modes. This exercises native input
and push-button controls, scroll containers, dynamic retained properties,
asynchronous sampling and virtual process rows beyond the benchmark.

`<input value="" placeholder="Search" label="Search processes" />` creates an
editable native control. `<control value="Pause" />` creates a native push
button with platform keyboard behavior; the earlier `<button>` remains a drawn
clickable container. Other additions include scroll, wrap/justify, flex basis,
min/max width, insets, font weight, disabled/visible state, and RGBA hex colors.
The schema is still experimental, not a complete native control language.

`Tree.updateUiProps(id, props)` owns dynamic slices and mirrors changes through
existing host callbacks while retaining template identity.
`Tree.acceptUiValue(id, value)` records an edit the native control already made,
without echoing it or resetting its cursor. `ui.invoke(engine, request_id,
command, args)` uses the existing command dispatcher; `Driver.resolved` receives
request ID, success/error status and JSON valid for the callback. Apps parse or
copy replies before returning. `Driver.scrolled` permits bounded virtual lists.
Callbacks may cancel frame hooks during dispatch; cancellation is deferred until
the callback returns. Retained detached nodes have empty frame/clip rectangles
so platform controls cannot remain at stale on-screen positions.

System monitor histories and pending process actions own their data. Its state
is still single-window and raw node/style ranges are still caller-managed.
These improvements do not settle the remaining component, lifecycle,
accessibility and platform-conformance requirements in the readiness review.
