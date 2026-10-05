// The page's accessibility tree for the platform's (docs/native-controls-
// a11y-design.md, section 2): each element worth an entry (a control, a
// link, a heading, an image, a list, a landmark, anything focusable or
// clickable, anything with ARIA) gets ["a", id, ax] ops: its role, name,
// description, states, level and value. Off until the backend says an
// assistive technology is there (the "a11y" event): then the whole tree at
// once, from inside that event, and after each render only what changed;
// off again, ["a", -2] clears it. Text nodes get no entry (the backend
// reads their runs), nor do elements the renderer didn't place.

import { accessibleName } from "./render.js";

const ROLES = new Set(("button link checkbox radio switch textbox searchbox combobox listbox option slider " +
  "progressbar heading img list listitem separator dialog alertdialog alert status navigation main banner " +
  "contentinfo region form table row cell columnheader tab tablist tabpanel menu menuitem menubar toolbar " +
  "tooltip tree treeitem group generic text").split(" "));
// Roles whose name is their content's text (accname 1.2, step 2F).
const FROM_CONTENT = new Set(["button", "link", "heading", "checkbox", "radio", "option", "tab", "menuitem", "cell", "listitem", "tooltip", "treeitem", "switch"]);
const LANDMARKS = { nav: "navigation", main: "main", form: "form", dialog: "dialog" };
const TEXT_INPUTS = new Set(["", "text", "email", "url", "tel", "password", "number", "date", "time", "datetime-local", "month", "week"]);
const FOCUSABLE = new Set(["button", "input", "select", "textarea", "summary"]);
// State bits (ax.s).
const S = { disabled: 1, checked: 2, mixed: 4, expanded: 8, collapsed: 16, selected: 32, pressed: 64, required: 128, invalid: 256, readonly: 512, focusable: 1024, multiline: 2048 };

const clean = (t) => (t || "").replace(/\s+/g, " ").trim();

// An element's role: its role attribute's first known one, else its own.
export function roleOf(el) {
  const explicit = (el.getAttribute("role") || "").trim().split(/\s+/).find((r) => ROLES.has(r) || r === "presentation" || r === "none");
  if (explicit) return explicit === "none" ? "presentation" : explicit;
  const tag = el.localName;
  const type = (el.getAttribute("type") || "").toLowerCase();
  switch (tag) {
    case "a": return el.hasAttribute("href") ? "link" : null;
    case "button": return "button";
    case "input":
      if (type === "button" || type === "submit" || type === "reset" || type === "image") return "button";
      if (type === "checkbox") return "checkbox";
      if (type === "radio") return "radio";
      if (type === "range") return "slider";
      if (type === "search") return "searchbox";
      if (type === "hidden") return null;
      return TEXT_INPUTS.has(type) ? "textbox" : "textbox";
    case "textarea": return "textbox";
    case "select": return el.hasAttribute("multiple") || +el.getAttribute("size") > 1 ? "listbox" : "combobox";
    case "option": return "option";
    case "h1": case "h2": case "h3": case "h4": case "h5": case "h6": return "heading";
    case "img": return "img";
    case "svg": return el.getAttribute("aria-label") || el.querySelector?.("title") ? "img" : null;
    case "ul": case "ol": return "list";
    case "li": return "listitem";
    case "hr": return "separator";
    case "progress": case "meter": return "progressbar";
    case "details": return "group";
    case "summary": return "button";
    case "header": return el.closest?.("article, section, aside, main, nav") ? null : "banner";
    case "footer": return el.closest?.("article, section, aside, main, nav") ? null : "contentinfo";
    case "section": return el.hasAttribute("aria-label") || el.hasAttribute("aria-labelledby") ? "region" : null;
    case "aside": return "region";
    default: return LANDMARKS[tag] || null;
  }
}

function focusable(el) {
  const t = el.getAttribute("tabindex");
  if (t !== null && !Number.isNaN(parseInt(t, 10))) return parseInt(t, 10) >= 0;
  if (el.localName === "a") return el.hasAttribute("href");
  return FOCUSABLE.has(el.localName) && !el.hasAttribute("disabled") || el.isContentEditable === true;
}

// Text of the elements an aria-labelledby/describedby names.
function idrefText(el, attr) {
  const ids = el.getAttribute(attr);
  if (!ids) return "";
  const doc = el.ownerDocument;
  return clean(ids.split(/\s+/).map((id) => doc?.getElementById(id)?.textContent || "").join(" "));
}

// accname 1.2's common steps: aria-labelledby, aria-label, the native
// label (render.js accessibleName for form controls: the same name their
// `al` prop carries; alt; an input button's value), content for the
// roles named by it, then title (which becomes the description when a
// name came before it). [name, from title]
export function accName(el, role) {
  const tag = el.localName;
  if (tag === "input" || tag === "textarea" || tag === "select") {
    const type = (el.getAttribute("type") || "").toLowerCase();
    if (tag === "input" && (type === "button" || type === "submit" || type === "reset")) {
      const v = clean(el.getAttribute("value")) || (type === "submit" ? "Submit" : type === "reset" ? "Reset" : "");
      return [clean(el.getAttribute("aria-label")) || idrefText(el, "aria-labelledby") || v, false];
    }
    const n = accessibleName(el);
    return [n, !!n && n === clean(el.getAttribute("title")) && !el.getAttribute("aria-label")];
  }
  const by = idrefText(el, "aria-labelledby");
  if (by) return [by, false];
  const aria = clean(el.getAttribute("aria-label"));
  if (aria) return [aria, false];
  if (tag === "img") { const alt = el.getAttribute("alt"); if (alt !== null) return [clean(alt), false]; }
  if (tag === "svg") { const t = clean(el.querySelector?.("title")?.textContent); if (t) return [t, false]; }
  if (FROM_CONTENT.has(role)) { const t = clean(el.textContent); if (t) return [t.slice(0, 256), false]; }
  const title = clean(el.getAttribute("title"));
  return [title, !!title];
}

function statesOf(el, role) {
  let s = 0;
  const aria = (a) => el.getAttribute(a);
  if (el.hasAttribute("disabled") || aria("aria-disabled") === "true") s |= S.disabled;
  if (role === "checkbox" || role === "radio" || role === "switch") {
    if (el.indeterminate || aria("aria-checked") === "mixed") s |= S.mixed;
    else if (el.checked === true || aria("aria-checked") === "true") s |= S.checked;
  }
  const exp = aria("aria-expanded");
  if (exp === "true") s |= S.expanded;
  else if (exp === "false") s |= S.collapsed;
  else if (el.localName === "summary" && el.parentNode?.localName === "details") s |= el.parentNode.hasAttribute("open") ? S.expanded : S.collapsed;
  if (aria("aria-selected") === "true" || (el.localName === "option" && el.selected)) s |= S.selected;
  if (aria("aria-pressed") === "true") s |= S.pressed;
  if (el.hasAttribute("required") || aria("aria-required") === "true") s |= S.required;
  if (aria("aria-invalid") === "true") s |= S.invalid;
  if (el.hasAttribute("readonly") || aria("aria-readonly") === "true") s |= S.readonly;
  if (focusable(el)) s |= S.focusable;
  if (el.localName === "textarea") s |= S.multiline;
  return s;
}

// Whether an element gets an entry (section 2.2).
function wanted(el, role) {
  if (role) return true;
  for (const a of ["aria-label", "aria-labelledby", "aria-describedby", "aria-live", "aria-hidden"]) if (el.hasAttribute(a)) return true;
  return focusable(el);
}

// An element's entry, or null for none.
export function axOf(el, clickable) {
  const role0 = roleOf(el);
  if (role0 === "presentation" && !focusable(el)) return null;
  const role = role0 === "presentation" ? null : role0;
  if (el.getAttribute("aria-hidden") === "true") return { r: role || "generic", h: 1 };
  if (!wanted(el, role) && !clickable) return null;
  if (el.localName === "img" && el.getAttribute("alt") === "") return { r: "img", h: 1 };
  const r = role || "generic";
  const ax = { r };
  const [n, fromTitle] = accName(el, r);
  if (n) ax.n = n.slice(0, 256);
  const d = idrefText(el, "aria-describedby") || (!fromTitle ? clean(el.getAttribute("title")) : "");
  if (d && d !== ax.n) ax.d = d.slice(0, 256);
  const s = statesOf(el, r);
  if (s) ax.s = s;
  if (r === "heading") ax.l = +(el.getAttribute("aria-level") || el.localName.slice(1)) || 2;
  if (r === "textbox" || r === "searchbox") { const v = el.value; if (typeof v === "string" && el.getAttribute("type") !== "password") ax.v = v.slice(0, 1024); }
  if (r === "combobox") { const o = el.options?.[el.selectedIndex]; if (o) ax.v = clean(o.textContent); }
  if (r === "slider" || r === "progressbar") {
    const num = (a, d) => { const x = parseFloat(el.getAttribute(a)); return Number.isFinite(x) ? x : d; };
    const now = r === "slider" ? parseFloat(el.value) : num("value", NaN);
    ax.rv = [num("min", 0), num("max", 100), Number.isFinite(now) ? now : num("aria-valuenow", 0)];
    const vt = el.getAttribute("aria-valuetext");
    if (vt) ax.v = vt;
  }
  const live = el.getAttribute("aria-live");
  if (live === "polite") ax.live = 1;
  else if (live === "assertive") ax.live = 2;
  return ax;
}

export class A11y {
  constructor(renderer, host, doc) {
    this.renderer = renderer;
    this.host = host;
    this.doc = doc;
    this.on = false;
    this.sent = new Map(); // id → its entry's JSON, as last sent
  }

  // The backend's "a11y" event: on sends the whole tree now (the
  // platform's first query waits on it), off clears it.
  set(on) {
    if (on === this.on) return;
    this.on = on;
    this.sent.clear();
    if (on) { this.renderer.render(); this.update(); } else this.host.ops('[["a",-2]]');
  }

  // After a render: the entries that changed, and those gone.
  update() {
    if (!this.on) return;
    const r = this.renderer;
    const ops = [];
    const seen = new Set();
    const walk = (el) => {
      for (let c = el.firstElementChild; c; c = c.nextElementSibling) {
        if (!r.sc.get(c)) continue; // not rendered (display: none, never laid out)
        const id = r.idOf(c, "el");
        // Placed by its own node, or (a link amid text) by its runs' k.
        const placed = r.prev.has(id) || (r.spans.has(c) && c.localName === "a" && c.hasAttribute("href"));
        const ax = placed ? axOf(c, false) : null;
        if (ax) {
          seen.add(id);
          const json = JSON.stringify(ax);
          if (this.sent.get(id) !== json) { this.sent.set(id, json); ops.push(`["a",${id},${json}]`); }
          if (ax.h) continue; // aria-hidden: nothing under it
        }
        walk(c);
      }
    };
    if (this.doc.body) walk(this.doc.body);
    for (const id of [...this.sent.keys()]) if (!seen.has(id)) { this.sent.delete(id); ops.push(`["a",${id},null]`); }
    if (ops.length) this.host.ops(`[${ops.join(",")}]`);
  }
}
