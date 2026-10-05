// node test/keyboard-props.test.mjs: a text field's keyboard props (itype,
// im, ek, cap, cor, spellcheck), as browsers hand them to the platform's
// keyboard: the input type, inputmode and enterkeyhint as written ("search"
// for a search field, "go" in a form by default), autocapitalize and
// autocorrect (Safari's defaults: off for email, url, tel, number and
// password), spellcheck (inherited; never for a password).
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body>
<input id="a">
<input id="b" type="email">
<form><input id="c" type="search"><input id="d" inputmode="decimal" enterkeyhint="done" autocapitalize="words" autocorrect="off"></form>
<div spellcheck="false"><textarea id="e"></textarea></div>
<input id="f" type="password">
<input id="g" type="tel" autocapitalize="on">
</body></html>`;
const nodes = new Map();
const host = {
  log: (lvl, msg) => { if (lvl >= 3) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined, focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => { for (const [k, id, x] of JSON.parse(json)) { if (k === "c") nodes.set(id, { kind: x, props: {} }); else if (k === "p") nodes.get(id).props = x; } },
  platform: JSON.stringify({ os: "ios" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
const f = [...nodes.values()].filter((n) => n.kind === "input" || n.kind === "textarea").map((n) => {
  const { itype, im, ek, cap, cor, spellcheck } = n.props;
  return { itype, im, ek, cap, cor, spellcheck };
});
const u = undefined;
assert.deepEqual(f, [
  { itype: u, im: u, ek: u, cap: "sentences", cor: true, spellcheck: true },
  { itype: "email", im: u, ek: u, cap: "none", cor: false, spellcheck: true },
  { itype: "search", im: u, ek: "search", cap: "sentences", cor: true, spellcheck: true },
  { itype: u, im: "decimal", ek: "done", cap: "words", cor: false, spellcheck: true },
  { itype: u, im: u, ek: u, cap: "sentences", cor: true, spellcheck: false },
  { itype: u, im: u, ek: u, cap: "none", cor: false, spellcheck: false },
  { itype: "tel", im: u, ek: u, cap: "sentences", cor: false, spellcheck: true },
]);
console.log("keyboard props: ok");
