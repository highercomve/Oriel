// What React does: wrap value/checked on the element to remember the last
// value it saw, and treat an input event as a change only if it differs.
const seen = [];
function track(el, prop) {
  const proto = Object.getPrototypeOf(el);
  let d; for (let p = proto; p && !d; p = Object.getPrototypeOf(p)) d = Object.getOwnPropertyDescriptor(p, prop);
  let last = d.get.call(el);
  Object.defineProperty(el, prop, {
    configurable: true,
    get() { return d.get.call(this); },
    set(v) { last = v; d.set.call(this, v); },
  });
  const changed = () => { const now = el[prop]; if (now !== last) { last = now; seen.push(`${el.id}=${now}`); } };
  el.addEventListener("input", changed);
  el.addEventListener("click", changed);
}
track(document.getElementById("name"), "value");
track(document.getElementById("box"), "checked");
globalThis.__seen = seen;
