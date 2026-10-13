# Oriel renderer readiness review

Reviewed 2026-10-13. Scope: `.oriel` compiler, `ui.View`, Zig engine, shared native
node/backend contract and render-bench integration. This is a readiness audit;
the original audit below records the benchmark-only state. The system monitor
implementation subsequently addressed several findings (see progress below).

**Decision: suitable as an experimental third renderer; not ready for official
application support.** The benchmark proves a useful direct-to-native path,
but it covers a small static grammar, pointer clicks, text updates and canvas.
Keep the existing native web renderer as the web-technology entry point. The
Oriel renderer should be its Zig application entry point, sharing the same
native tree, controls, text, layout, drawing and platform services.

## Implementation progress: system monitor

The monitor now has an experimental `-Drenderer=oriel` frontend using compiled
`.oriel` views and the same sampler/commands as its web frontends. Added native
input and push-button controls, typed property updates, consumed native edit
values (preserving cursor position), scrolling, layout attributes, RGBA colors,
request ID/status completion callbacks and virtual-list scroll notifications.
The monitor preserves its telemetry, histories, settings, process actions and
confirmation, with 32 mounted process rows and no continuous frame hook.

The reproduced frame-hook self-cancellation crash is fixed using deferred
cancellation during dispatch. Regression coverage includes self/later hook
cancellation, next-frame registration, reply status/ID preservation, typed value
ownership, retained identity, and clearing detached control geometry. Linux
checks exercised editable search, pause/refresh, filtering/sorting/scrolling,
settings persistence, clipboard and keyboard cancellation/confirmation against
a disposable process. All three monitor modes build on Linux.

This is progress toward application support, not official renderer readiness.
Drawn `<button>` containers still lack complete focus/accessibility semantics;
`<control>` uses the platform push-button widget. Multi-window models, component
ownership, async task cancellation, a complete schema and cross-platform
conformance remain open. Historical findings below describe the pre-port audit;
items marked addressed should not be read as current unfixed bugs.

## Must fix before official support

### P1: cancellation during a frame can crash — addressed

[engine_zig.zig:121](../../src/native_ui/engine_zig.zig#L121) removes the current
array index after invoking user code. That code can call `removeFrameHooks`,
which mutates the same array. A callback that removes its own context and
returns false leaves an empty array; dispatch then calls `orderedRemove(0)`.
A temporary regression probe reproduced an index-out-of-bounds panic/ABRT in
ReleaseSafe. Returning true can instead skip the next callback after a removal.

Use stable callback tokens and deferred cancellation while dispatching, with
new registrations eligible on the next frame. Test self-cancellation, cancelling
an earlier/later hook, adding a hook, cancellation followed by registration,
window closure during dispatch and no callbacks after owner destruction.

### P1: asynchronous command replies cannot be correlated — addressed

[engine_zig.zig:212](../../src/native_ui/engine_zig.zig#L212) discards `call_id`
and `ok`, forwarding only a JSON payload as an event on node zero. Two pending
commands cannot identify their replies, and success cannot be distinguished
from failure. The shared backend already includes request IDs.

Add a completion callback carrying request ID and success/error, owned pending
requests and cancellation on window closure. Decode at the host boundary into
typed events. Test out-of-order replies, error responses and late replies after
shutdown. Do not silently accept unsupported page APIs as success.

### P1: buttons lack default keyboard and accessibility behavior

[oriel_markup.zig:38](../../src/native_ui/oriel_markup.zig#L38) maps `button` to
`view` plus `click=true`. There is no semantic role, accessible name/state,
disabled property, focus order or default Enter/Space activation. The original
renderer implements much of its focus/default-key behavior in JavaScript;
removing QuickJS also removes that implementation.

[engine_zig.zig:200](../../src/native_ui/engine_zig.zig#L200) does not populate
`Tree.ax`. Merely notifying the backend is insufficient. Add a native focus
manager, visible focus state and typed accessibility entries/updates. Drawn
buttons can remain custom styled, but must carry button semantics. Reuse actual
native controls where appropriate. Test keyboard-only operation and assistive
technology on each supported platform, including dynamic names and deletion.

### P1: application primitives and dynamic properties are missing — partly addressed

The grammar exposes only row, column, view, text, button and canvas.
The shared [node kinds and properties](../../src/native_ui/tree.zig#L19)
already support inputs, textarea, select, check, image and icon, but the template
compiler cannot produce them. `createLeaf` accepts only view/text. Bindings are
string lookups for whole text values; mount only updates text on retained nodes.

Expose a documented v1 set of native controls and asset primitives; typed
bindings for values, checked/disabled/visible state, style and events; keyboard,
IME, selection and validation behavior. Ensure updates mirror into the platform
backend, rather than directly mutating only Zig props. This is required for
ordinary forms and asynchronously loaded content, not merely advanced widgets.

## Important design and correctness gaps

- **P2 — Identity/style registration:** callers allocate raw node and style
  ranges. `defineStaticStyle` silently keeps an existing style with the same ID,
  even if another template supplied different props. Mount checks kind/style ID,
  not template ownership, so compatible collisions can update or move another
  view. Introduce instance-owned identities, template-specific style handles and
  explicit keyed children. Detect collisions instead of relying on magic ranges.
- **P2 — Model/lifecycle ownership:** the driver is globally configured and has
  no explicit per-window model/context factory. Boot errors are only logged,
  while shutdown is called even if boot never succeeded. Mount can leave partial
  changes after allocation failure. Define create/boot/failure/destroy states,
  per-window models, cleanup of partially initialized state, owned timers/tasks
  and explicit recovery or rollback. Test two windows and repeated open/close.
- **P2 — Event batching:** event/timer callbacks immediately call `paintNow`,
  unlike the JS engine's coalesced `request_frame` path. Bursts can repeat layout
  and backend publication before one display refresh. Schedule dirty work once
  per frame, preserving an explicit synchronous layout API for geometry reads.
- **P2 — Components and dynamic structure:** there are no component imports,
  typed component props, slots, conditional branches or supported keyed-list
  abstraction. Manual tree mutation can assemble these, but is not a complete
  template/application API. Define ownership and removal before adding syntax.
- **P2 — Compiler validation:** attribute names and finite numbers are checked,
  but `align`/`position` accept arbitrary strings and duplicate attributes replace
  previous values. Source locations, literal brace escaping, entities and comments
  are absent. The compiler uses fixed limits of 128 nodes and depth 32. Specify
  the language, validate enums/ranges and produce file/line diagnostics.
- **P2 — Layout/themes/localization:** no template scroll container, wrap/justify,
  general min/max sizes, margins/insets, theme tokens, font family/weight,
  direction or responsive conditions. Text defaults are set independently on
  every node rather than inherited. Static immutable styles need a supported
  dynamic-state/theme path with cache invalidation. Test scaling, narrow windows,
  safe areas, keyboard insets, wrapping, RTL and Unicode text/IME.
- **P2 — Services and capability reporting:** canvas and asset lookup exist,
  but drag/drop returns no accepted action and drop-path commands are unsupported.
  JavaScript evaluation is a silent no-op. Expose typed native service APIs and
  explicit capability errors; keep web-only operations outside this renderer.

## Current support matrix

“Shared foundation” means existing native implementation, not verified `.oriel`
access or an official platform guarantee.

| Requirement | Today | Required for v1 |
|---|---|---|
| Compiled views; no QuickJS/DOM | Working | Preserve build/dependency checks |
| Basic row/column layout and styles | Working subset | Scroll, sizing, wrapping, responsive constraints |
| Text and stable retained nodes | Working; explicit IDs | Typed bindings, ownership, localization/fonts |
| Canvas and display callbacks | Working | Safe cancellation/lifecycle; retained canvas tests |
| Pointer-click buttons | Working | Keyboard, focus, disabled and accessibility semantics |
| Text inputs, IME, checkbox, select | Shared foundation | Template/API mappings and interaction tests |
| Images, icons and asset sources | Shared foundation | Template/API mappings and ownership tests |
| Accessibility roles/names/states | Shared foundation, absent in views | Semantic tree and host conformance |
| Conditional views, components, keyed lists | Manual tree operations | Supported composition/reconciliation API |
| Theme and runtime property changes | Text updates/paint operations only | Typed dynamic props and theme invalidation |
| Async services/results | Incomplete reply bridge | Request correlation, errors, cancellation |
| Multi-window and model ownership | Global configuration; no model factory | Window-owned state and lifecycle |
| Linux / Android arm64 | Builds and benchmark checks | Real application/platform interaction tests |
| Windows / macOS / iOS | Shared backends; not verified for this mode | Dedicated compile and runtime checks |
| Memory, frame latency, power | Benchmark plumbing; preliminary evidence | Controlled physical-device comparisons |
| Public naming/build/tooling | Examples use `-Drenderer=webview\|native\|oriel` (no aliases); root `-Dzig_ui` flag; not on the docs site | One canonical Oriel name (no alias), docs page, CI |

## Recommended implementation order

1. Harden callback dispatch, asynchronous replies, instance ownership and failure
   cleanup. Add regression tests for the reproduced crash before changing it.
2. Define the v1 native schema and implement inputs, semantic buttons, check/select,
   images/icons, scroll containers, focus/accessibility and dynamic properties.
   Use one schema for compiler validation, typed operations and documentation.
3. Add component composition, keyed/conditional children and a window-owned
   model/update/view API. Keep `.oriel` declarative; execute logic as compiled Zig.
   Notifications must update only affected state and batch publication per frame.
4. Build one real application with a form, a scrolling keyed list, conditional
   loading/error states, async requests, theme changes, images and navigation.
   Validate keyboard, screen reader, rotation/resizing and repeated mount/unmount.
   Preserve the current full-row benchmark; add explicit virtualization separately.
5. Establish platform gates and naming: WebView, native web, Oriel. Keep the web
   renderer's frontend compatibility and verify it after shared-backend changes.
   Add grammar negative tests, allocator-failure tests, lifecycle tests and
   renderer conformance checks. Hot reload/inspector support can follow v1.

## Evidence and release gates

The earlier suite passed 579 tests with three skips, but did not cover the
cancellation case. This review's temporary probe added one test and produced
579 passes, three skips and one crash in ReleaseSafe. The probe was removed;
no failing test or experimental runtime edit is left in the workspace. The
reproducer and observed diagnostic are retained in the
[review evidence](../../examples/render-bench/results/2026-10-13-oriel-renderer-review.json).
Other findings above are source inspection, not new physical-device measurements.

The user's lower-memory observation is consistent with removing the JS heap,
DOM store and related caches. No Oriel-mode phone numbers were supplied in this
review. A feeling of smoothness is useful feedback; FPS at the refresh ceiling
cannot establish input latency or dropped-frame differences. Measure p50/p95/p99
frame times and input-to-present latency under identical workloads.

For power, compare all three modes on the Pixel 8 at the same refresh rate,
brightness, thermal state and network/background conditions, unplugged. Run idle,
boxes and both canvas workloads for at least 60 seconds, repeat in rotated order
and retain source/samples/charger status. Do not infer battery savings from lower
memory or user instructions. Native/Oriel memory readings should be captured at
the same lifecycle endpoint; WebView totals must include its isolated renderer.

[Experiment design](../design/zig-ui-experiment.md) ·
[Three-renderer desktop measurements](../../examples/render-bench/results/2026-10-12-three-renderers-desktop.json)

## Subsequent Poco X3 test preparation

Device testing identified a typed-style wire-format issue: default serialization
of `Dim`/`Corner` did not match the native property parser. Explicit serialization
now preserves pixel/percentage/calc dimensions and corner radii, with a round-trip
regression test. It also identified power-test geometry changing as result rows
were appended. Power sampling now uses a visible fixed 320 × 240 viewport and
holds result publication until completion. These fixes do not resolve the other
readiness blockers above.
