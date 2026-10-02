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
- **JSON.stringify fast path** (`json_put_quoted`, `json_put_number`,
  `json_plain_object`, the C `stack`). A plain object's properties are read
  in shape order (what Object.keys gives when no key is an integer) instead
  of through an allocated key array and full lookups; keys, strings and
  numbers go straight into the output buffer; the circular-reference stack
  is a C array instead of a JS Array; an element's key string is made only
  when a toJSON or replacer may use it. Getters, integer keys, exotic
  objects, replacer arrays and indentation take upstream's path. The output
  is the same as V8's on `tests/json-stringify.js`
  (`qjs tests/json-stringify.js` vs `node tests/json-stringify.js`).
- **A profiler of JavaScript functions** (`ORIEL_QJS_FUNC_PROFILE`, off
  unless defined; x86-64). Each bytecode function's own time (TSC ticks,
  callees excluded, builtins it calls included) and calls, the top 60
  printed to stderr at exit. For the QuickJS harness, e.g. a `qjs` built
  from upstream's tree with this quickjs.c and
  `-DCMAKE_C_FLAGS="-O2 -DORIEL_QJS_FUNC_PROFILE"`.
