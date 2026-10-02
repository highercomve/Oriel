// The runtime's DOM as the native one (-Dnative_dom, docs/native-dom.md):
// the engine installs the store and its bindings (__nuiDom, the Node…
// interfaces) and hands over the document as __host.document. Same exports
// as ./linkedom.js.
import { installNativeDom } from "./native.js";

export const NATIVE = true;
const nd = globalThis.__nuiDom;

export function openDocument(html) {
  const document = globalThis.__host.document;
  const out = installNativeDom(globalThis, document);
  document.__writePage(html);
  return out;
}

export const classStyle = (el, allowStyle) => nd.classStyle(el, allowStyle);

// Compiled once in the store, kept for the engine's life (a style sheet's
// rules), matched natively.
export function compileMatch(_el, sel) {
  const id = nd.keepSelector(sel);
  return (el) => nd.matchKept(el, id);
}

// Frees the detached trees nothing holds; called where no DOM operation is
// under way (the engine's render).
export const collect = () => nd.collect();

// Style writes are attribute writes: the store reports them.
export const STYLE_RECORDS = true;
