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

## Layout

- `web/physics.js`: the rules (`createWorld`, `step(world, dt, input)`,
  `launch`, `resize`), in board pixels, no DOM and no drawing.
- `web/draw.js`: `draw(ctx, world, dpr, hint)`, with only the 2d calls the
  native canvas records. Each frame starts with an opaque `fillRect` over the
  bitmap, so the native recorder keeps one frame's program.
- `web/game.js`: the page around them (HUD, overlays, settings, stats),
  input and the `requestAnimationFrame` loop. Steps use the time since the
  last frame, so 60, 120, 144 and 180 Hz displays play the same.
