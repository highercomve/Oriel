# Breakout

A Breakout (Arkanoid) game for comparing Oriel's two renderers: the same
page in the WebView and in the native renderer (`-Dnative_ui`). The board
is a `<canvas>` drawn with the 2d context at the display's pixel ratio; the
score, overlays, settings and stats around it are HTML and CSS, so the
native widgets get exercised too.

```sh
zig build                                   # WebView
zig build -Dnative_ui -p zig-out-native     # native renderer
./zig-out/bin/oriel-breakout
./zig-out-native/bin/oriel-breakout
```

For iOS add `-Dtarget=aarch64-ios-simulator -Dapple_sdk=$(xcrun --sdk
iphonesimulator --show-sdk-path)` (or `aarch64-ios` and the iPhoneOS SDK).

## Screenshots

<p>
  <img src="../../assets/screenshots/breakout-desktop.png" alt="Breakout with the native renderer on Linux" width="62%">
  <img src="../../assets/screenshots/breakout-phone.png" alt="Breakout with the native renderer on Android" width="24%">
</p>

## Playing

- Desktop: the mouse moves the paddle (or ← → / A D); click or Space
  launches; P or Esc pauses.
- Phone: drag anywhere on the board to move the paddle; tap to launch.
- Settings: balls per launch (1–500: chaos), brick rows, particles, the stats
  overlay, and autoplay (the paddle follows the balls).

The stats overlay shows the frame rate, the frame time, the JavaScript time
per frame (physics and drawing) and which renderer runs the page.

## Measuring

`BREAKOUT_DEMO=<balls>` starts in autoplay with that many balls a launch, no
lives lost, and logs a line every 2 s (`breakout: fps …`). On the simulator:
`SIMCTL_CHILD_BREAKOUT_DEMO=500 xcrun simctl launch --console-pty <device>
dev.oriel.Breakout`. `-Dnative_ui_prof` adds the native renderer's stage
timings.

Speed increases with levels up to three times the base speed, keeping
collision substeps bounded during extended autoplay. Both modes use the
current balls setting after slider edits; the demo sets its initial value.
Check the physics rules with `node test/physics.test.mjs` and
`zig build test-game -Dnative_ui`.

`BREAKOUT_MODE=zig` (native renderer) runs the demo in the Zig mode; its
lines end in `mode zig` (the page's, `mode js`).

## Zig mode (native renderer)

Settings → Renderer mode: **JS** (the page steps `physics.js` and draws
with `draw.js` each frame) or **Zig** (`game.zig`: the same rules and
drawing in Zig, through `oriel.canvas`, with no JavaScript per frame). The
page keeps the HTML and the input: it sends the paddle's target and the keys'
direction when they change, and launch, pause, settings and the board's
size (`zig_*` commands in `main.zig`); Zig sends the score, lives and level
(`breakout:state`) and its stats (`breakout:stats`) back. Switching starts a
new game. The WebView has no Zig mode (the toggle isn't shown there).

GTK, 180 Hz desktop (`BREAKOUT_DEMO=n BREAKOUT_MODE=js|zig`): 100 balls hold
180 fps in both modes (0.3–0.9 ms of JS a frame vs 0.004–0.1 ms of Zig);
500 balls: 88–108 fps in JS (2.9–4.4 ms of JS a frame) vs 180 in Zig
(0.03–0.22 ms). Zig draws each ball as a path of its own (the GTK backend
fills a lone circle from a cached mask), the page 16 to a path.

## Layout

- `web/physics.js`: the rules (`createWorld`, `step(world, dt, input)`,
  `launch`, `resize`), in board pixels, no DOM and no drawing.
- `web/draw.js`: `draw(ctx, world, dpr, hint)`, with only the 2d calls the
  native canvas records. Each frame starts with an opaque `fillRect` over the
  bitmap, so the native recorder keeps one frame's program.
- `game.zig`: the Zig mode (the rules and drawing of the two above).
- `web/game.js`: the page around them (HUD, overlays, settings, stats),
  input and the `requestAnimationFrame` loop. Steps use the time since the
  last frame, so 60, 120, 144 and 180 Hz displays play the same.
