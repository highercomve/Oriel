// Session history: pushState/replaceState entries with their state, back,
// forward and go firing popstate (and hashchange across fragments), fragment
// navigations as entries, and the platform's back walking them.
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { withEngine } from "./engine-host.mjs";

const scheduled = [];
const host = {
  asset: (name) => name === "index.html" ? "<html><body></body></html>" : undefined,
  log() {}, now: () => 0, timer: (id) => scheduled.push(id), invoke() {}, frame() {}, focus() {}, scrollIntoView() {}, scrollTo() {}, ops() {},
  platform: '{"os":"android"}', label: "main", url: "index.html?x=1#start",
};
const ctx = vm.createContext({ __host: withEngine(host) });
vm.runInContext(fs.readFileSync(new URL("./runtime-linkedom.js", import.meta.url), "utf8"), ctx);
ctx.__oriel.boot(400, 600, false, false);
const run = (code) => vm.runInContext(code, ctx);
const flush = () => { while (scheduled.length) ctx.__oriel.timer(scheduled.shift()); };

run(`globalThis.log = [];
  addEventListener("popstate", (e) => log.push("pop:" + JSON.stringify(e.state) + ":" + location.hash));
  addEventListener("hashchange", (e) => log.push("hash:" + e.oldURL.split("#")[1] + ">" + e.newURL.split("#")[1]));`);
flush();
assert.equal(run("location.href"), "app://localhost/index.html?x=1#start");
assert.equal(run("history.length"), 1);
assert.equal(run("history.state"), null);

// pushState: a new entry, no events; the state is a copy.
run(`const s = { penny: "view", view: "reports" }; history.pushState(s, ""); s.view = "changed";`);
assert.equal(run("history.length"), 2);
assert.equal(run("history.state.view"), "reports");
run(`history.pushState({ penny: "dialog" }, "", "settings?tab=2#top")`);
assert.equal(run("location.pathname + location.search + location.hash"), "/settings?tab=2#top");
assert.equal(run("history.length"), 3);
flush();
assert.deepEqual(Array.from(run("log")), []);

// back is asynchronous: popstate with the entry's state, hashchange across fragments.
run("history.back()");
assert.equal(run("history.state.penny"), "dialog", "back hasn't happened yet");
flush();
assert.equal(run("history.state.penny"), "view");
assert.deepEqual(Array.from(run("log")), ['pop:{"penny":"view","view":"reports"}:#start', "hash:top>start"]);
run("log.length = 0; history.forward()"); flush();
assert.equal(run("location.pathname"), "/settings");
run("log.length = 0; history.go(-2)"); flush();
assert.deepEqual(Array.from(run("log")), ["pop:null:#start", "hash:top>start"]);
assert.equal(run("history.length"), 3, "traversal keeps the forward entries");

// A push from the middle drops the forward entries; replaceState swaps the current one.
run(`history.pushState({ n: 1 }, ""); history.replaceState({ n: 2 }, "")`);
assert.equal(run("history.length"), 2);
assert.equal(run("history.state.n"), 2);

// A fragment navigation: a new entry, popstate (null state) then hashchange.
run("log.length = 0; location.hash = 'chat'"); flush();
assert.equal(run("history.length"), 3);
assert.deepEqual(Array.from(run("log")), ["pop:null:#chat", "hash:start>chat"]);
run("log.length = 0; location.hash = '#chat'"); flush();
assert.deepEqual(Array.from(run("log")), [], "the same fragment is no navigation");

// Other origins are refused.
assert.throws(() => run(`history.pushState(null, "", "https://example.com/")`), /SecurityError|Can't change/);

// The platform's back walks the entries, then lets the app go.
run("log.length = 0");
assert.equal(ctx.__oriel.event(0, "back", null), true); flush();
assert.equal(run("history.state.n"), 2);
assert.equal(ctx.__oriel.event(0, "back", null), true); flush();
assert.equal(ctx.__oriel.event(0, "back", null), false, "the first entry: the platform closes the app");
console.log("history: entries, state, traversal events, fragments, origin check and the platform back pass");
