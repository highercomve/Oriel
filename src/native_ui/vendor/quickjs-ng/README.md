# QuickJS-ng, vendored

The JavaScript engine of the native renderer (`-Dnative_ui`), copied from
[quickjs-ng v0.17.0](https://github.com/quickjs-ng/quickjs/releases/tag/v0.17.0)
(only the files the build compiles: the engine, its regexp, unicode and dtoa
libraries and their headers) so it can be tuned for the renderer.
MIT License (LICENSE).

## Changes from upstream

Each is marked `Oriel:` in the source.

- **Hashing of Map/WeakMap keys and object lists** (`js_mix64`). Upstream
  hashed an object pointer as `ptr * 3163` and a number as the XOR of its
  double's halves times 3163, and the tables take the low bits. Pointers are
  aligned and small integers' doubles have a zero low word, so those bits
  hardly vary: most buckets stayed empty and lookups walked long chains. The
  renderer keys Maps by node id and WeakMaps by element, so a third of its
  instructions went to those walks (callgrind, building 1000 rows). A 64-bit
  finalizer (MurmurHash3's fmix64) spreads them: 34% fewer instructions,
  the render of 1000 rows 109 → 44 ms in the QuickJS harness.
