// new Image() and <img>: the size from the file's header (PNG, JPEG, GIF,
// WebP, BMP) of a data: URL or an app asset, "load" (or "error") after src
// is set, complete and decode().
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { withEngine } from "./engine-host.mjs";
import { imageSize } from "../src/image.js";

// Headers: a 3x2 PNG, a 640x480 JPEG (APP0 before its SOF0), a 5x7 GIF, a 9x4 BMP, a 300x200 VP8X WebP.
const png = Buffer.from("89504e470d0a1a0a0000000d494844520000000300000002080600000000", "hex");
const jpeg = Buffer.from("ffd8ffe000104a46494600010100000100010000ffc00011080" + "1e00280" + "03012200021101031101", "hex");
const gif = Buffer.from("474946383961050007000000000000000000000000000000", "hex");
const bmp = Buffer.alloc(30); bmp.write("BM", 0, "latin1"); bmp.writeInt32LE(9, 18); bmp.writeInt32LE(-4, 22);
const webp = Buffer.alloc(32); webp.write("RIFF", 0, "latin1"); webp.write("WEBPVP8X", 8, "latin1"); webp.writeUIntLE(299, 24, 3); webp.writeUIntLE(199, 27, 3);
assert.deepEqual(imageSize(png), [3, 2]);
assert.deepEqual(imageSize(jpeg), [640, 480]);
assert.deepEqual(imageSize(gif), [5, 7]);
assert.deepEqual(imageSize(bmp), [9, 4]);
assert.deepEqual(imageSize(webp), [300, 200]);
assert.equal(imageSize(Buffer.from("not an image at all, really")), null);

const scheduled = [];
const host = {
  asset: (name) => name === "index.html" ? "<html><body><img id='logo' src='logo.png'></body></html>" : undefined,
  assetBytes: (name) => name === "logo.png" ? new Uint8Array(png).buffer : undefined,
  log() {}, now: () => 0, timer: (id) => scheduled.push(id), invoke() {}, frame() {}, focus() {}, scrollIntoView() {}, scrollTo() {}, ops() {},
  platform: '{"os":"android"}', label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: withEngine(host) });
vm.runInContext(fs.readFileSync(new URL("./runtime-linkedom.js", import.meta.url), "utf8"), ctx);
ctx.__oriel.boot(400, 600, false, false);
const run = (code) => vm.runInContext(code, ctx);
const flush = () => { while (scheduled.length) ctx.__oriel.timer(scheduled.shift()); };

// Penny Goblin's check: a photo's data: URL, its size on load.
run(`globalThis.log = [];
  const image = new Image();
  image.onload = () => log.push("load " + image.naturalWidth + "x" + image.naturalHeight + " " + (image instanceof HTMLImageElement));
  image.onerror = () => log.push("error");
  image.src = "data:image/jpeg;base64,${jpeg.toString("base64")}";`);
assert.deepEqual(Array.from(run("log")), [], "load is asynchronous");
flush();
assert.deepEqual(Array.from(run("log")), ["load 640x480 true"]);

// Not an image: error.
run(`log.length = 0; const bad = new Image(); bad.addEventListener("error", () => log.push("error")); bad.src = "data:text/plain,hello"`);
flush();
assert.deepEqual(Array.from(run("log")), ["error"]);

// An <img> of the app's: its asset's size; complete; decode().
assert.equal(run(`document.getElementById("logo").naturalWidth`), 3);
assert.equal(run(`document.getElementById("logo").complete`), true);
run(`log.length = 0; document.getElementById("logo").decode().then(() => log.push("decoded"))`);
flush();
await new Promise((r) => setImmediate(r));
assert.deepEqual(Array.from(run("log")), ["decoded"]);
assert.equal(run(`new Image(40, 30).getAttribute("width")`), "40");
console.log("image: header sizes, Image() load and error, <img> natural size, complete and decode pass");
