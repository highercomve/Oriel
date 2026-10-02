// The runtime's DOM as linkedom (the default build). The native DOM
// (./native-backend.js, -Dnative_dom) has the same exports; build.mjs
// resolves "#dom" to one or the other.
import { parseHTML } from "../../vendor/linkedom/esm/index.js";
import { NEXT } from "../../vendor/linkedom/esm/shared/symbols.js";
import { prepareMatch } from "../../vendor/linkedom/esm/shared/matches.js";
import { ignoreCase } from "../../vendor/linkedom/esm/shared/utils.js";
import { parseSimple } from "../html.js";

export const NATIVE = false;

// { window, document } for the page's markup.
export function openDocument(html) {
  const { window, document } = parseHTML(html);
  patchInnerHTML(document);
  return { window, document };
}

// For style sharing (render.js): null when the element has an attribute
// other than class (and style, when allowStyle), else [class, style] (each
// undefined when absent). The array is reused: read it before the next call.
const pair = [undefined, undefined];
export function classStyle(el, allowStyle) {
  pair[0] = pair[1] = undefined;
  // linkedom's attributes getter allocates an array and a Proxy on every
  // read. Its attributes precede the children in the node list.
  for (let a = el[NEXT]; a?.nodeType === 2; a = a[NEXT]) {
    if (a.name === "class") pair[0] = a.value;
    else if (a.name === "style" && allowStyle) pair[1] = a.value;
    else return null;
  }
  return pair;
}

// A selector as a function of an element (throws on a bad selector).
export const compileMatch = (el, sel) => prepareMatch(el, sel);

// Element style writes don't make mutation records in linkedom: main.js
// wraps `style` to tell the renderer.
export const STYLE_RECORDS = false;

// innerHTML: plain markup is built directly (html.js), the rest by
// linkedom's parser.
function patchInnerHTML(document) {
  let proto = Object.getPrototypeOf(document.createElement("div"));
  let desc = null;
  while (proto && !(desc = Object.getOwnPropertyDescriptor(proto, "innerHTML"))) proto = Object.getPrototypeOf(proto);
  if (!desc?.set) return;
  Object.defineProperty(proto, "innerHTML", {
    configurable: true,
    get: desc.get,
    set(html) {
      // This fixed ancestry check does not need compiling a CSS selector
      // for every small innerHTML assignment (thousands when building rows).
      let simple = this.localName !== "template";
      const fold = ignoreCase(this);
      if (simple) for (let el = this; el?.nodeType === 1; el = el.parentNode) {
        const tag = fold ? el.localName.toLowerCase() : el.localName;
        if (tag === "svg" || tag === "math") { simple = false; break; }
      }
      const frag = simple ? parseSimple(this.ownerDocument, String(html ?? "")) : null;
      if (frag) this.replaceChildren(frag);
      else desc.set.call(this, html);
    },
  });
}

// Nothing to collect: linkedom's nodes are JS objects.
export const collect = () => {};

// Node ids come from the renderer's own counter (native-backend.js: from
// the store).
export const nodeIndex = null;
export const nodeAt = null;
export const markListens = () => {};
