// URL and URLSearchParams (src/url.js): bundlers resolve assets with
// new URL(path, import.meta.url), routers read searchParams.
import assert from "node:assert/strict";
import { URL, URLSearchParams } from "../src/url.js";

const r = (i, b) => new URL(i, b).href;
assert.equal(r("../icons.svg", "app://app/assets/index-x.js"), "app://app/icons.svg");
assert.equal(r("hero.png", "app://app/assets/index-x.js"), "app://app/assets/hero.png");
assert.equal(r("https://a.b:443/x/../y?q=1#h"), "https://a.b/y?q=1#h");
assert.equal(r("?z=2", "https://a.b/p?q=1"), "https://a.b/p?z=2");
assert.equal(r("#top", "https://a.b/p?q=1"), "https://a.b/p?q=1#top");
assert.equal(r("//c.d/e", "https://a.b/"), "https://c.d/e");
assert.equal(new URL("https://a.b/x").origin, "https://a.b");
assert.equal(new URL("https://u:p@a.b:8080/x").host, "a.b:8080");
assert.equal(new URL("https://a.b/p?x=1&y=two+words").searchParams.get("y"), "two words");
const u = new URL("https://a.b/");
u.searchParams.set("k", "v w");
u.searchParams.append("k", "2");
assert.equal(u.href, "https://a.b/?k=v+w&k=2");
assert.deepEqual(u.searchParams.getAll("k"), ["v w", "2"]);
assert.throws(() => new URL("not a url"), TypeError);
assert.equal(URL.canParse("x", "app://app/"), true);
assert.equal(new URLSearchParams({ a: 1, b: "c d" }).toString(), "a=1&b=c+d");
console.log("url: ok");
