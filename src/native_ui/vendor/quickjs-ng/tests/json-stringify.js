// JSON.stringify cases for the vendored QuickJS's fast path (README.md):
// prints one line per case; the output must match V8's (node) exactly.
//   qjs json-stringify.js > a.txt; node json-stringify.js > b.txt; diff a.txt b.txt
const print = globalThis.print ?? console.log;
const cases = [];
const add = (name, fn) => cases.push([name, fn]);

add("plain", () => JSON.stringify({ a: 1, b: "x", c: true, d: null, e: [1, 2, 3], f: { g: 1.5 } }));
add("numbers", () => JSON.stringify([0, -0, 1, -1, 0.1, 1 / 3, 1e21, 1e-7, 123456789012, 2 ** 53, NaN, Infinity, -Infinity, 13.333, 5e-324]));
add("escapes", () => JSON.stringify(["a\"b\\c", "\n\r\t\b\f", "\u0001\u001f", "\ud800", "\udc00x", "é€😀", "plain", ""]));
add("integer keys", () => JSON.stringify({ b: 1, 2: "two", a: 2, 1: "one", "10": 10, "-1": -1, "01": "zero-one" }));
add("symbol and non-enumerable", () => { const o = { a: 1, [Symbol("s")]: 2 }; Object.defineProperty(o, "h", { value: 3, enumerable: false }); return JSON.stringify(o); });
add("deleted", () => { const o = { a: 1, b: 2, c: 3 }; delete o.b; o.d = 4; return JSON.stringify(o); });
add("undefined and functions", () => JSON.stringify({ a: undefined, b() {}, c: Symbol("x"), d: 1, e: [undefined, () => 1, Symbol("y")] }));
add("toJSON object", () => JSON.stringify({ a: { toJSON(k) { return "k=" + k; } }, b: [{ toJSON(k) { return "i=" + k; } }] }));
add("toJSON primitive wrapper", () => JSON.stringify([new Number(3), new String("s"), new Boolean(false), Object(1n) === 0 ? 0 : 1]));
add("date", () => JSON.stringify({ d: new Date(0) }));
add("replacer function", () => JSON.stringify({ a: 1, b: [2, 3], c: { d: 4 } }, function (k, v) { return typeof v === "number" ? v * 10 + (this === undefined ? 0 : 0) : v; }));
add("replacer keys", () => JSON.stringify({ a: 1, b: 2, c: { a: 3, z: 4 }, 1: 5 }, ["c", "a", 1]));
add("space number", () => JSON.stringify({ a: [1, { b: 2 }], c: {} , d: [] }, null, 2));
add("space string", () => JSON.stringify({ a: [1, { b: 2 }] }, null, "--"));
add("getter", () => JSON.stringify({ get a() { return 7; }, b: 1 }));
add("getter that mutates", () => { const o = { b: 1 }; Object.defineProperty(o, "a", { enumerable: true, get() { o.c = 3; delete o.b; return 0; } }); return JSON.stringify(o); });
add("toJSON mutates parent", () => { const o = { a: { toJSON() { delete o.b; o.z = 9; return "a"; } }, b: 2, c: 3 }; return JSON.stringify(o); });
add("toJSON mutates array", () => { const arr = [1, { toJSON() { arr.length = 3; arr.push("x"); return "m"; } }, 3, 4, 5]; return JSON.stringify(arr); });
add("cycle", () => { const o = { a: {} }; o.a.b = o; try { return JSON.stringify(o); } catch (e) { return e.constructor.name; } });
add("cycle in array", () => { const a = [1]; a.push([a]); try { return JSON.stringify(a); } catch (e) { return e.constructor.name; } });
add("same object twice", () => { const s = { x: 1 }; return JSON.stringify({ a: s, b: s, c: [s, s] }); });
add("bigint", () => { try { return JSON.stringify({ a: 1n }); } catch (e) { return e.constructor.name; } });
add("holes", () => JSON.stringify([1, , 3, , ]));
add("sparse", () => { const a = []; a[5] = 1; return JSON.stringify(a); });
add("class instance", () => { class P { constructor() { this.x = 1; this.y = [2]; } get z() { return 3; } } return JSON.stringify(new P()); });
add("null prototype", () => { const o = Object.create(null); o.a = 1; o.b = "2"; return JSON.stringify(o); });
add("prototype toJSON", () => { const proto = { toJSON() { return "proto"; } }; return JSON.stringify([Object.create(proto)]); });
add("map and set", () => JSON.stringify([new Map([[1, 2]]), new Set([1])]));
add("proxy", () => JSON.stringify(new Proxy({ a: 1, b: 2 }, { ownKeys: () => ["b", "a"], getOwnPropertyDescriptor: (t, k) => ({ value: t[k], enumerable: true, configurable: true }), get: (t, k) => (k === "toJSON" ? undefined : t[k] * 100) })));
add("arguments", () => (function () { return JSON.stringify(arguments); })(1, "a"));
add("typed array", () => JSON.stringify([new Uint8Array([1, 2])]));
add("rope strings", () => { let s = ""; for (let i = 0; i < 200; i++) s += "ab\"" + i; return JSON.stringify({ s, t: s + "\n" }); });
add("many keys", () => { const o = {}; for (let i = 0; i < 40; i++) o["k" + i] = i % 3 ? i : { n: i }; return JSON.stringify(o); });
add("deep", () => { let o = { v: 0 }; for (let i = 1; i < 200; i++) o = { v: i, n: o }; return JSON.stringify(o).length; });
add("top-level", () => [JSON.stringify(1), JSON.stringify("s"), JSON.stringify(undefined), JSON.stringify(null), JSON.stringify(() => 1), JSON.stringify(-0)].join("|"));
add("unicode keys", () => JSON.stringify({ "é": 1, "a\"b": 2, "\n": 3, "": 4 }));
add("frozen and accessor-less", () => JSON.stringify(Object.freeze({ a: [Object.seal({ b: 1 })] })));
add("render props", () => JSON.stringify({ fd: "row", ai: "center", pad: [3, 8, 3, 8], bw: [0, 0, 1, 0], bc: [[48, 52, 61, 1], [48, 52, 61, 1]], bg: { color: [29, 32, 38, 1] }, runs: [{ t: "Row 1: the quick brown fox", c: [230, 232, 236, 1], sz: 14, w: 400 }], fz: 14, cg: 8, fs: 0 }));

for (const [name, fn] of cases) {
  let out;
  try { out = fn(); } catch (e) { out = "threw " + e.constructor.name; }
  print(`${name}: ${out}`);
}
