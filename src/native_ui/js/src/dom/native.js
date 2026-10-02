// The native DOM's JavaScript side (docs/native-dom.md).
//
// The nodes live in Zig (src/native_ui/dom): the tree, attributes, text,
// innerHTML, selectors, cloning and serializing are native, reached through
// the C bindings' prototypes (Node, CharacterData, Text, Comment, Element,
// HTMLElement, DocumentFragment, Document). This module adds what is plain
// JavaScript on top of them, with the semantics linkedom gave the runtime and
// pages (events, style, classList, dataset, attributes, form elements,
// MutationObserver, DOMParser…), and returns a `window`-like object with the
// constructors, as linkedom's parseHTML did.

const ELEMENT_NODE = 1, ATTRIBUTE_NODE = 2, TEXT_NODE = 3, COMMENT_NODE = 8, DOCUMENT_NODE = 9, DOCUMENT_FRAGMENT_NODE = 11;
const SVG_NS = "http://www.w3.org/2000/svg", HTML_NS = "http://www.w3.org/1999/xhtml", MATH_NS = "http://www.w3.org/1998/Math/MathML";

const hyphen = (name) => name.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase());

export function installNativeDom(g, document) {
  const nd = g.__nuiDom;
  const { Node, CharacterData, Text, Comment, Element, HTMLElement, DocumentFragment, Document } = g;
  const def = (proto, props) => {
    for (const [k, v] of Object.entries(props)) {
      Object.defineProperty(proto, k, typeof v === "function" ? { value: v, writable: true, configurable: true } : { ...v, configurable: true });
    }
  };
  const reflect = (name) => ({ get() { return this.getAttribute(name) || ""; }, set(v) { this.setAttribute(name, v); } });
  const boolAttr = (name) => ({ get() { return this.hasAttribute(name); }, set(v) { if (v) this.setAttribute(name, ""); else this.removeAttribute(name); } });

  // ---------------------------------------------------------------- constants
  const constants = { ELEMENT_NODE, ATTRIBUTE_NODE, TEXT_NODE, COMMENT_NODE, DOCUMENT_NODE, DOCUMENT_FRAGMENT_NODE,
    DOCUMENT_POSITION_DISCONNECTED: 1, DOCUMENT_POSITION_PRECEDING: 2, DOCUMENT_POSITION_FOLLOWING: 4,
    DOCUMENT_POSITION_CONTAINS: 8, DOCUMENT_POSITION_CONTAINED_BY: 16, DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC: 32 };
  for (const [k, v] of Object.entries(constants)) {
    Object.defineProperty(Node, k, { value: v });
    Object.defineProperty(Node.prototype, k, { value: v });
  }

  // ---------------------------------------------------------------- events
  // linkedom's semantics, which React and the runtime rely on: the path is
  // the target and its ancestors (parentNode), listeners run in insertion
  // order with no separate capture phase, target/currentTarget are only set
  // during the call.
  const BUBBLING_PHASE = 3, AT_TARGET = 2, CAPTURING_PHASE = 1, NONE = 0;
  class Event {
    static get BUBBLING_PHASE() { return BUBBLING_PHASE; }
    static get AT_TARGET() { return AT_TARGET; }
    static get CAPTURING_PHASE() { return CAPTURING_PHASE; }
    static get NONE() { return NONE; }
    constructor(type, init = {}) {
      this.type = type;
      this.bubbles = !!init.bubbles;
      this.cancelBubble = false;
      this._stopImmediatePropagationFlag = false;
      this.cancelable = !!init.cancelable;
      this.composed = !!init.composed;
      this.eventPhase = NONE;
      this.timeStamp = Date.now();
      this.defaultPrevented = false;
      this.originalTarget = null;
      this.returnValue = null;
      this.srcElement = null;
      this.target = null;
      this.isTrusted = false;
      this._path = [];
    }
    get BUBBLING_PHASE() { return BUBBLING_PHASE; }
    get AT_TARGET() { return AT_TARGET; }
    get CAPTURING_PHASE() { return CAPTURING_PHASE; }
    get NONE() { return NONE; }
    preventDefault() { this.defaultPrevented = true; }
    composedPath() { return this._path.map((p) => p.currentTarget); }
    stopPropagation() { this.cancelBubble = true; }
    stopImmediatePropagation() { this.stopPropagation(); this._stopImmediatePropagationFlag = true; }
    initEvent(type, bubbles, cancelable) { this.type = type; this.bubbles = !!bubbles; this.cancelable = !!cancelable; }
  }
  class CustomEvent extends Event {
    constructor(type, init = {}) { super(type, init); this.detail = init.detail; }
  }
  const listeners = new WeakMap();
  function invoke(event, step) {
    const map = listeners.get(step.currentTarget);
    if (!map || !map.has(event.type)) return false;
    const list = map.get(event.type);
    event.eventPhase = step.currentTarget === step.target ? AT_TARGET : BUBBLING_PHASE;
    event.currentTarget = step.currentTarget;
    event.target = step.target;
    for (const [fn, opts] of list) {
      if (opts && opts.once) list.delete(fn);
      if (typeof fn === "function") fn.call(step.target, event); else fn.handleEvent(event);
      if (event._stopImmediatePropagationFlag) break;
    }
    delete event.currentTarget;
    delete event.target;
    return event.cancelBubble;
  }
  const eventTarget = {
    addEventListener(type, fn, opts) {
      if (!fn) return;
      let map = listeners.get(this);
      if (!map) listeners.set(this, (map = new Map()));
      let list = map.get(type);
      if (!list) map.set(type, (list = new Map()));
      list.set(fn, opts);
    },
    removeEventListener(type, fn) {
      const map = listeners.get(this);
      const list = map?.get(type);
      if (list && list.delete(fn) && !list.size) map.delete(type);
    },
    dispatchEvent(event) {
      event.eventPhase = CAPTURING_PHASE;
      for (let n = this; n; n = event.bubbles ? n._getParent() : null) event._path.push({ currentTarget: n, target: this });
      event._path.some((step) => invoke(event, step));
      event._path = [];
      event.eventPhase = NONE;
      return !event.defaultPrevented;
    },
    _getParent() { return null; },
  };
  class EventTarget {}
  def(EventTarget.prototype, eventTarget);
  // Nodes are event targets (their parent: parentNode).
  def(Node.prototype, { ...eventTarget, _getParent() { return this.parentNode; } });

  // ---------------------------------------------------------------- Node
  const rootOf = (n) => { while (n.parentNode) n = n.parentNode; return n; };
  def(Node.prototype, {
    ownerDocument: { get() { if (this.nodeType === DOCUMENT_NODE) return null; const r = rootOf(this); return r.nodeType === DOCUMENT_NODE ? r : document; } },
    nodeValue: { get() { return null; }, set(_v) {} },
    getRootNode() { return rootOf(this); },
    isSameNode(o) { return this === o; },
    isEqualNode(o) {
      if (!o || o.nodeType !== this.nodeType) return false;
      if (this.nodeType === ELEMENT_NODE) return this.outerHTML === o.outerHTML;
      if (this.nodeType === TEXT_NODE || this.nodeType === COMMENT_NODE) return this.data === o.data;
      return this.innerHTML === o.innerHTML;
    },
    compareDocumentPosition(other) {
      if (this === other) return 0;
      if (rootOf(this) !== rootOf(other)) return 1 | 32 | 2;
      if (this.contains(other)) return 16 | 4;
      if (other.contains(this)) return 8 | 2;
      // Document order: compare the ancestor chains below the common one.
      const chain = (n) => { const out = []; for (; n; n = n.parentNode) out.unshift(n); return out; };
      const a = chain(this), b = chain(other);
      let i = 0;
      while (a[i] === b[i]) i++;
      for (let s = a[i]; s; s = s.nextSibling) if (s === b[i]) return 4;
      return 2;
    },
    normalize() {
      for (let c = this.firstChild; c;) {
        const next = c.nextSibling;
        if (c.nodeType === TEXT_NODE) {
          if (!c.data) c.remove();
          else if (next?.nodeType === TEXT_NODE) { next.data = c.data + next.data; c.remove(); }
        } else if (c.nodeType === ELEMENT_NODE) c.normalize();
        c = next;
      }
    },
  });
  // Methods that take nodes or strings (ChildNode, ParentNode).
  const nodesFrom = (doc, args) => args.map((a) => (a instanceof Node ? a : doc.createTextNode(String(a))));
  const childNode = {
    before(...args) { const p = this.parentNode; if (!p) return; for (const n of nodesFrom(document, args)) p.insertBefore(n, this); },
    after(...args) { const p = this.parentNode; if (!p) return; const ref = this.nextSibling; for (const n of nodesFrom(document, args)) p.insertBefore(n, ref); },
    replaceWith(...args) { const p = this.parentNode; if (!p) return; const ref = this.nextSibling; this.remove(); for (const n of nodesFrom(document, args)) p.insertBefore(n, ref); },
  };
  const parentNode = {
    replaceChildren(...args) { this.textContent = ""; this.append(...args); },
    getElementsByTagName(name) { return this.querySelectorAll(name === "*" ? "*" : name); },
    getElementsByClassName(names) { const sel = String(names).trim().split(/\s+/).filter(Boolean).map((c) => "." + CSS_escape(c)).join(""); return sel ? this.querySelectorAll(sel) : []; },
    childElementCount: { get() { let n = 0; for (let c = this.firstElementChild; c; c = c.nextElementSibling) n++; return n; } },
  };
  def(Element.prototype, { ...childNode, ...parentNode });
  def(CharacterData.prototype, childNode);
  def(DocumentFragment.prototype, parentNode);
  def(Document.prototype, parentNode);

  def(CharacterData.prototype, {
    length: { get() { return this.data.length; } },
    appendData(s) { this.data += s; },
    substringData(o, n) { return this.data.substr(o, n); },
    textContent: { get() { return this.data; }, set(v) { this.data = v == null ? "" : v; } },
  });
  def(Text.prototype, {
    nodeName: { get() { return "#text"; } },
    wholeText: { get() { return this.data; } },
    splitText(offset) { const rest = this.data.slice(offset); this.data = this.data.slice(0, offset); const t = document.createTextNode(rest); this.after(t); return t; },
  });
  def(Comment.prototype, { nodeName: { get() { return "#comment"; } } });
  def(DocumentFragment.prototype, { nodeName: { get() { return "#document-fragment"; } } });

  // ---------------------------------------------------------------- Element
  // classList: a live view of the class attribute.
  class DOMTokenList {
    constructor(el) { this._el = el; }
    _get() { return (this._el.getAttribute("class") || "").split(/\s+/).filter(Boolean); }
    _set(list) { this._el.setAttribute("class", [...new Set(list)].join(" ")); }
    get length() { return this._get().length; }
    get value() { return this._el.getAttribute("class") || ""; }
    set value(v) { this._el.setAttribute("class", v); }
    item(i) { return this._get()[i] ?? null; }
    contains(t) { return this._get().includes(t); }
    add(...ts) { const l = this._get(); let changed = false; for (const t of ts) if (t && !l.includes(t)) { l.push(t); changed = true; } if (changed || !this._el.hasAttribute("class")) this._set(l); }
    remove(...ts) { const l = this._get(); const out = l.filter((t) => !ts.includes(t)); if (out.length !== l.length) this._set(out); }
    toggle(t, force) {
      const has = this.contains(t);
      if (has && force !== true) { this.remove(t); return false; }
      if (!has && force !== false) { this.add(t); return true; }
      return has;
    }
    replace(a, b) { const l = this._get(); const i = l.indexOf(a); if (i < 0) return false; l[i] = b; this._set(l); return true; }
    supports() { return true; }
    forEach(fn, self) { this._get().forEach((t, i) => fn.call(self, t, i, this)); }
    toString() { return this.value; }
    [Symbol.iterator]() { return this._get()[Symbol.iterator](); }
    keys() { return this._get().keys(); }
    values() { return this._get().values(); }
    entries() { return this._get().entries(); }
  }
  const tokenLists = new WeakMap();
  // style: linkedom's CSSStyleDeclaration (a view of the style attribute).
  const styleOf = new WeakMap();
  function parseStyle(text) {
    const m = new Map();
    for (const rule of (text || "").split(/\s*;\s*/)) {
      const i = rule.indexOf(":");
      if (i < 0) continue;
      const key = rule.slice(0, i).trim(), value = rule.slice(i + 1).trim();
      if (key && value) m.set(key, value);
    }
    return m;
  }
  const writeStyle = (el, m) => {
    const parts = [];
    for (const [k, v] of m) parts.push(`${k}:${v}`);
    if (parts.length || el.hasAttribute("style")) el.setAttribute("style", parts.join(";"));
  };
  const styleProto = {
    get cssText() { return this.toString(); },
    set cssText(v) { this._el.setAttribute("style", v); },
    getPropertyValue(name) { return parseStyle(this._el.getAttribute("style")).get(name) ?? ""; },
    setProperty(name, value) { const m = parseStyle(this._el.getAttribute("style")); if (value == null || value === "") m.delete(name); else m.set(name, String(value)); writeStyle(this._el, m); },
    removeProperty(name) { const m = parseStyle(this._el.getAttribute("style")); const old = m.get(name) ?? ""; if (m.delete(name)) writeStyle(this._el, m); return old; },
    item(i) { return [...parseStyle(this._el.getAttribute("style")).keys()][i] ?? ""; },
    toString() { const parts = []; for (const [k, v] of parseStyle(this._el.getAttribute("style"))) parts.push(`${k}:${v}`); return parts.join(";"); },
    [Symbol.iterator]() { return parseStyle(this._el.getAttribute("style")).keys(); },
  };
  const styleHandler = {
    get(t, name) {
      if (typeof name === "symbol" || name in styleProto || name === "_el") return name === "_el" ? t._el : (typeof styleProto[name] === "function" ? styleProto[name].bind(t) : Reflect.get(styleProto, name, t));
      const m = parseStyle(t._el.getAttribute("style"));
      if (name === "length") return m.size;
      if (/^\d+$/.test(name)) return [...m.keys()][name];
      if (name === "cssFloat") name = "float";
      return m.get(name.startsWith("--") ? name : hyphen(name)) ?? "";
    },
    set(t, name, value) {
      if (name === "cssText") { t._el.setAttribute("style", value); return true; }
      if (name === "cssFloat") name = "float";
      const key = name.startsWith("--") ? name : hyphen(name);
      const m = parseStyle(t._el.getAttribute("style"));
      if (value == null || value === "") m.delete(key); else m.set(key, String(value));
      writeStyle(t._el, m);
      return true;
    },
    has(t, name) { return name in styleProto || typeof name === "string"; },
  };
  // dataset: data-* attributes by camelCase name.
  const datasetHandler = {
    get(t, name) { if (typeof name !== "string") return undefined; const v = t._el.getAttribute("data-" + hyphen(name)); return v ?? undefined; },
    set(t, name, value) { t._el.setAttribute("data-" + hyphen(name), String(value)); return true; },
    deleteProperty(t, name) { t._el.removeAttribute("data-" + hyphen(name)); return true; },
    has(t, name) { return typeof name === "string" && t._el.hasAttribute("data-" + hyphen(name)); },
    ownKeys(t) { const out = []; const a = nd.attrs(t._el); for (let i = 0; i < a.length; i += 2) if (a[i].startsWith("data-")) out.push(a[i].slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())); return out; },
    getOwnPropertyDescriptor(t, name) { const v = this.get(t, name); return v === undefined ? undefined : { value: v, enumerable: true, configurable: true, writable: true }; },
  };
  const datasets = new WeakMap();
  // attributes: Attr-like objects, in order (a snapshot, as linkedom's
  // reads were; their value setter writes through).
  class Attr {
    constructor(el, name, value) { this.ownerElement = el; this.name = name; this._value = value; }
    get localName() { return this.name; }
    get nodeName() { return this.name; }
    get nodeType() { return ATTRIBUTE_NODE; }
    get specified() { return true; }
    get namespaceURI() { return null; }
    get value() { return this.ownerElement ? this.ownerElement.getAttribute(this.name) ?? this._value : this._value; }
    set value(v) { this._value = v; this.ownerElement?.setAttribute(this.name, v); }
    get nodeValue() { return this.value; }
    get textContent() { return this.value; }
  }
  const attributesOf = (el) => {
    const a = nd.attrs(el), out = [];
    for (let i = 0; i < a.length; i += 2) out.push(new Attr(el, a[i], a[i + 1]));
    out.getNamedItem = (n) => out.find((x) => x.name === n) ?? null;
    out.item = (i) => out[i] ?? null;
    return out;
  };
  const xlinkName = (ns, name) => (ns === "http://www.w3.org/1999/xlink" && !name.startsWith("xlink:") ? "xlink:" + name : name);
  def(Element.prototype, {
    classList: { get() { let l = tokenLists.get(this); if (!l) tokenLists.set(this, (l = new DOMTokenList(this))); return l; }, set(v) { this.setAttribute("class", v); } },
    style: { get() { let s = styleOf.get(this); if (!s) styleOf.set(this, (s = new Proxy({ _el: this }, styleHandler))); return s; }, set(v) { this.setAttribute("style", String(v)); } },
    dataset: { get() { let d = datasets.get(this); if (!d) datasets.set(this, (d = new Proxy({ _el: this }, datasetHandler))); return d; } },
    attributes: { get() { return attributesOf(this); } },
    getAttributeNames() { const a = nd.attrs(this), out = []; for (let i = 0; i < a.length; i += 2) out.push(a[i]); return out; },
    hasAttributes() { return nd.attrs(this).length > 0; },
    getAttributeNode(name) { const v = this.getAttribute(name); return v === null ? null : new Attr(this, name, v); },
    setAttributeNode(attr) { this.setAttribute(attr.name, attr._value ?? attr.value); attr.ownerElement = this; return null; },
    toggleAttribute(name, force) {
      const has = this.hasAttribute(name);
      if (has && force !== true) { this.removeAttribute(name); return false; }
      if (!has && force !== false) { this.setAttribute(name, ""); return true; }
      return has;
    },
    getAttributeNS(ns, name) { return this.getAttribute(xlinkName(ns, name)); },
    setAttributeNS(ns, name, value) { this.setAttribute(xlinkName(ns, name), value); },
    removeAttributeNS(ns, name) { this.removeAttribute(xlinkName(ns, name)); },
    hasAttributeNS(ns, name) { return this.hasAttribute(xlinkName(ns, name)); },
    namespaceURI: { get() { return nd.isForeign(this) ? (this.localName === "math" ? MATH_NS : SVG_NS) : HTML_NS; } },
    prefix: { get() { return null; } },
    shadowRoot: { get() { return null; } },
    hidden: boolAttr("hidden"),
    title: reflect("title"),
    lang: reflect("lang"),
    dir: reflect("dir"),
    slot: reflect("slot"),
    tabIndex: { get() { const v = parseInt(this.getAttribute("tabindex"), 10); return Number.isFinite(v) ? v : -1; }, set(v) { this.setAttribute("tabindex", String(v)); } },
    contentEditable: { get() { return this.getAttribute("contenteditable") ?? "inherit"; }, set(v) { this.setAttribute("contenteditable", v); } },
    isContentEditable: { get() { return false; } },
    innerText: { get() { return this.textContent; }, set(v) { this.textContent = v; } },
    outerText: { get() { return this.textContent; } },
    nodeValue: { get() { return null; }, set(_v) {} },
    attachShadow() { throw new Error("NotSupportedError: shadow roots aren't supported by the native renderer"); },
    getClientRects() { return [this.getBoundingClientRect()]; },
  });

  // ---------------------------------------------------------------- element classes
  // A prototype (and an illegal constructor, for instanceof) per interface,
  // chosen by tag when a node gets its wrapper (__nuiDom.setProto).
  const classes = { HTMLElement };
  const makeClass = (name, parent, props) => {
    const ctor = function () { throw new TypeError("Illegal constructor"); };
    Object.defineProperty(ctor, "name", { value: name });
    ctor.prototype = Object.create(parent.prototype, { constructor: { value: ctor, writable: true, configurable: true } });
    Object.setPrototypeOf(ctor, parent);
    if (props) def(ctor.prototype, props);
    classes[name] = ctor;
    return ctor;
  };
  const form = { get() { return this.closest("form"); } };
  const TAGS = {
    HTMLAnchorElement: [["a"], { href: reflect("href"), target: reflect("target"), rel: reflect("rel"), download: reflect("download"), text: { get() { return this.textContent; } } }],
    HTMLAreaElement: [["area"]], HTMLAudioElement: [["audio"], { play() { return Promise.resolve(); }, pause() {} }],
    HTMLBRElement: [["br"]], HTMLBaseElement: [["base"]], HTMLBodyElement: [["body"]],
    HTMLButtonElement: [["button"], { type: { get() { const t = (this.getAttribute("type") || "").toLowerCase(); return t === "button" || t === "reset" ? t : "submit"; }, set(v) { this.setAttribute("type", v); } }, name: reflect("name"), value: reflect("value"), form }],
    HTMLCanvasElement: [["canvas"]], HTMLDataElement: [["data"]], HTMLDataListElement: [["datalist"]],
    HTMLDetailsElement: [["details"], { open: boolAttr("open") }], HTMLDialogElement: [["dialog"], { open: boolAttr("open"), show() { this.setAttribute("open", ""); }, showModal() { this.setAttribute("open", ""); }, close() { this.removeAttribute("open"); } }],
    HTMLDivElement: [["div"]], HTMLDListElement: [["dl"]], HTMLEmbedElement: [["embed"]], HTMLFieldSetElement: [["fieldset"], { disabled: boolAttr("disabled") }],
    HTMLFormElement: [["form"], { action: reflect("action"), method: reflect("method"), name: reflect("name"), elements: { get() { return this.querySelectorAll("input, select, textarea, button"); } } }],
    HTMLHeadingElement: [["h1", "h2", "h3", "h4", "h5", "h6"]], HTMLHeadElement: [["head"]], HTMLHRElement: [["hr"]], HTMLHtmlElement: [["html"]],
    HTMLIFrameElement: [["iframe"]], HTMLImageElement: [["img"], { src: reflect("src"), alt: reflect("alt"), width: { get() { return parseFloat(this.getAttribute("width") || 0); }, set(v) { this.setAttribute("width", v); } }, height: { get() { return parseFloat(this.getAttribute("height") || 0); }, set(v) { this.setAttribute("height", v); } }, naturalWidth: { get() { return 0; } }, naturalHeight: { get() { return 0; } }, complete: { get() { return true; } } }],
    HTMLInputElement: [["input"], {
      value: { get() { return this.getAttribute("value") || ""; }, set(v) { this.setAttribute("value", v); } },
      defaultValue: reflect("value"), name: reflect("name"), placeholder: reflect("placeholder"),
      type: { get() { return this.getAttribute("type"); }, set(v) { this.setAttribute("type", v); } },
      checked: boolAttr("checked"), defaultChecked: boolAttr("checked"), disabled: boolAttr("disabled"), readOnly: boolAttr("readonly"), required: boolAttr("required"),
      autofocus: boolAttr("autofocus"), min: reflect("min"), max: reflect("max"), step: reflect("step"), form,
      selectionStart: { get() { return this.value.length; }, set(_v) {} }, selectionEnd: { get() { return this.value.length; }, set(_v) {} },
      select() {}, setSelectionRange() {},
    }],
    HTMLLabelElement: [["label"], { htmlFor: { get() { return this.getAttribute("for") || ""; }, set(v) { this.setAttribute("for", v); } }, control: { get() { const id = this.getAttribute("for"); return id ? document.getElementById(id) : this.querySelector("input, select, textarea, button"); } } }],
    HTMLLegendElement: [["legend"]], HTMLLIElement: [["li"]], HTMLLinkElement: [["link"], { href: reflect("href"), rel: reflect("rel"), sheet: { get() { return null; } } }],
    HTMLMapElement: [["map"]], HTMLMetaElement: [["meta"], { content: reflect("content"), name: reflect("name") }], HTMLMeterElement: [["meter"]],
    HTMLOListElement: [["ol"]], HTMLOptGroupElement: [["optgroup"], { label: reflect("label"), disabled: boolAttr("disabled") }],
    HTMLOptionElement: [["option"], {
      value: { get() { return this.hasAttribute("value") ? this.getAttribute("value") : this.textContent; }, set(v) { this.setAttribute("value", v); } },
      text: { get() { return this.textContent; }, set(v) { this.textContent = v; } }, label: { get() { return this.getAttribute("label") ?? this.textContent; } },
      selected: { get() { return this.hasAttribute("selected"); }, set(v) {
        const other = this.closest("select")?.querySelector("option[selected]");
        if (v && other && other !== this) other.removeAttribute("selected");
        if (v) this.setAttribute("selected", ""); else this.removeAttribute("selected");
      } },
      defaultSelected: boolAttr("selected"), disabled: boolAttr("disabled"),
      index: { get() { const s = this.closest("select"); return s ? [...s.options].indexOf(this) : 0; } },
    }],
    HTMLOutputElement: [["output"]], HTMLParagraphElement: [["p"]], HTMLPictureElement: [["picture"]], HTMLPreElement: [["pre"]], HTMLProgressElement: [["progress"]],
    HTMLQuoteElement: [["q", "blockquote"]], HTMLScriptElement: [["script"], { src: reflect("src"), type: reflect("type"), text: { get() { return this.textContent; }, set(v) { this.textContent = v; } } }],
    HTMLSelectElement: [["select"], {
      options: { get() {
        const out = [];
        for (let c = this.firstElementChild; c; c = c.nextElementSibling) {
          if (c.localName === "optgroup") { for (let o = c.firstElementChild; o; o = o.nextElementSibling) if (o.localName === "option") out.push(o); } else if (c.localName === "option") out.push(c);
        }
        return out;
      } },
      length: { get() { return this.options.length; } }, name: reflect("name"), disabled: boolAttr("disabled"), multiple: boolAttr("multiple"), form,
      value: { get() { return this.querySelector("option[selected]")?.value; } },
      selectedIndex: { get() { return this.options.findIndex((o) => o.hasAttribute("selected")); }, set(i) { const o = this.options[i]; if (o) o.selected = true; } },
      type: { get() { return this.multiple ? "select-multiple" : "select-one"; } },
    }],
    HTMLSlotElement: [["slot"]], HTMLSourceElement: [["source"]], HTMLSpanElement: [["span"]], HTMLStyleElement: [["style"], { sheet: { get() { return null; } } }],
    HTMLTableElement: [["table"]], HTMLTableSectionElement: [["thead", "tbody", "tfoot"]], HTMLTableRowElement: [["tr"]], HTMLTableCellElement: [["td", "th"]], HTMLTableCaptionElement: [["caption"]], HTMLTableColElement: [["col", "colgroup"]],
    HTMLTemplateElement: [["template"]], HTMLTextAreaElement: [["textarea"], {
      value: { get() { return this.textContent; }, set(v) { this.textContent = v; } }, defaultValue: { get() { return this.textContent; }, set(v) { this.textContent = v; } },
      name: reflect("name"), placeholder: reflect("placeholder"), disabled: boolAttr("disabled"), readOnly: boolAttr("readonly"), type: { get() { return "textarea"; } }, form,
      selectionStart: { get() { return this.value.length; }, set(_v) {} }, selectionEnd: { get() { return this.value.length; }, set(_v) {} }, select() {}, setSelectionRange() {},
    }],
    HTMLTimeElement: [["time"]], HTMLTitleElement: [["title"]], HTMLTrackElement: [["track"]], HTMLUListElement: [["ul"]],
    HTMLVideoElement: [["video"], { play() { return Promise.resolve(); }, pause() {} }],
  };
  for (const [name, [tags, props]] of Object.entries(TAGS)) {
    const ctor = makeClass(name, HTMLElement, props);
    for (const t of tags) nd.setProto(t, ctor.prototype);
  }
  makeClass("HTMLUnknownElement", HTMLElement);
  const SVGElement = makeClass("SVGElement", Element, { ownerSVGElement: { get() { return this.parentNode?.closest?.("svg") ?? null; } } });
  nd.setProto("#foreign", SVGElement.prototype);
  // <template>: its content, a fragment holding copies of its children.
  const contents = new WeakMap();
  def(classes.HTMLTemplateElement.prototype, {
    content: { get() {
      let f = contents.get(this);
      if (!f) contents.set(this, (f = document.createDocumentFragment()));
      if (this.hasChildNodes() && !f.hasChildNodes()) for (let c = this.firstChild; c; c = c.nextSibling) f.appendChild(c.cloneNode(true));
      return f;
    } },
  });

  // ---------------------------------------------------------------- Document
  def(Document.prototype, {
    nodeName: { get() { return "#document"; } },
    defaultView: { get() { return this === document ? g : null; } },
    ownerDocument: { get() { return null; } },
    createElementNS(ns, name) { return nd.createElement(name, ns === SVG_NS || ns === MATH_NS); },
    createEvent(_type) { return new Event(""); },
    createAttribute(name) { return new Attr(null, String(name).toLowerCase(), ""); },
    createRange() {
      return { setStart() {}, setEnd() {}, setStartBefore() {}, setEndAfter() {}, selectNodeContents() {}, collapse() {}, detach() {},
        getBoundingClientRect() { return { x: 0, y: 0, left: 0, top: 0, width: 0, height: 0, right: 0, bottom: 0 }; }, getClientRects() { return []; },
        cloneContents() { return document.createDocumentFragment(); }, toString() { return ""; } };
    },
    createTreeWalker(root, whatToShow = 0xffffffff, filter = null) { return new TreeWalker(root, whatToShow, filter); },
    title: {
      get() { return this.querySelector("title")?.textContent ?? ""; },
      set(v) { let t = this.querySelector("title"); if (!t) { t = this.createElement("title"); this.head?.append(t); } t.textContent = v; },
    },
    readyState: { get() { return "complete"; } },
    characterSet: { get() { return "UTF-8"; } },
    compatMode: { get() { return "CSS1Compat"; } },
    contentType: { get() { return "text/html"; } },
    cookie: { get() { return ""; }, set(_v) {} },
    URL: { get() { return g.location?.href ?? "app://localhost/index.html"; } },
    documentURI: { get() { return g.location?.href ?? "app://localhost/index.html"; } },
    location: { get() { return this === document ? g.location : null; } },
    hasFocus() { return true; },
    getElementsByName(name) { return this.querySelectorAll(`[name="${String(name).replace(/"/g, '\\"')}"]`); },
    implementation: { get() { return { createHTMLDocument(title = "") { const d = nd.createDocument(); d.__writePage(`<html><head><title>${title}</title></head><body></body></html>`); return d; }, hasFeature() { return true; } }; } },
    forms: { get() { return this.querySelectorAll("form"); } },
    images: { get() { return this.querySelectorAll("img"); } },
    links: { get() { return this.querySelectorAll("a[href], area[href]"); } },
    scripts: { get() { return this.querySelectorAll("script"); } },
  });

  // ---------------------------------------------------------------- TreeWalker
  const NodeFilter = { FILTER_ACCEPT: 1, FILTER_REJECT: 2, FILTER_SKIP: 3, SHOW_ALL: 0xffffffff, SHOW_ELEMENT: 1, SHOW_ATTRIBUTE: 2, SHOW_TEXT: 4, SHOW_COMMENT: 0x80, SHOW_DOCUMENT: 0x100, SHOW_DOCUMENT_FRAGMENT: 0x400 };
  class TreeWalker {
    constructor(root, whatToShow, filter) { this.root = root; this.whatToShow = whatToShow; this.filter = filter; this.currentNode = root; }
    _ok(n) {
      if (!(this.whatToShow & (1 << (n.nodeType - 1)))) return NodeFilter.FILTER_SKIP;
      const f = this.filter;
      return f ? (typeof f === "function" ? f(n) : f.acceptNode(n)) : NodeFilter.FILTER_ACCEPT;
    }
    nextNode() {
      let n = this.currentNode;
      for (;;) {
        if (n.firstChild) n = n.firstChild;
        else { while (n !== this.root && !n.nextSibling) n = n.parentNode; if (n === this.root) return null; n = n.nextSibling; }
        if (this._ok(n) === NodeFilter.FILTER_ACCEPT) return (this.currentNode = n);
      }
    }
    previousNode() {
      let n = this.currentNode;
      while (n !== this.root) {
        if (n.previousSibling) { n = n.previousSibling; while (n.lastChild) n = n.lastChild; } else n = n.parentNode;
        if (this._ok(n) === NodeFilter.FILTER_ACCEPT) return (this.currentNode = n);
      }
      return null;
    }
    parentNode() { for (let n = this.currentNode; n !== this.root && (n = n.parentNode);) if (this._ok(n) === NodeFilter.FILTER_ACCEPT) return (this.currentNode = n); return null; }
    firstChild() { for (let n = this.currentNode.firstChild; n; n = n.nextSibling) if (this._ok(n) === NodeFilter.FILTER_ACCEPT) return (this.currentNode = n); return null; }
    lastChild() { for (let n = this.currentNode.lastChild; n; n = n.previousSibling) if (this._ok(n) === NodeFilter.FILTER_ACCEPT) return (this.currentNode = n); return null; }
    nextSibling() { for (let n = this.currentNode.nextSibling; n; n = n.nextSibling) if (this._ok(n) === NodeFilter.FILTER_ACCEPT) return (this.currentNode = n); return null; }
    previousSibling() { for (let n = this.currentNode.previousSibling; n; n = n.previousSibling) if (this._ok(n) === NodeFilter.FILTER_ACCEPT) return (this.currentNode = n); return null; }
  }

  // ---------------------------------------------------------------- MutationObserver
  // Fed by the store's mutations (__nuiDom.observe). Page observers get
  // records by microtask, as in browsers; an observer with the runtime's
  // private hooks (__nuiChild / __nuiAttribute, the renderer's) is called
  // directly, for connected nodes only, as with linkedom's hooks.
  const observers = new Set();
  let pageObservers = 0;
  const ADDED = 1, REMOVED = 2, ATTRIBUTE = 3, DATA = 4;
  function covers(reg, node) {
    if (reg.target === node) return true;
    return !!reg.options.subtree && reg.target.contains(node);
  }
  function hook(kind, target, node, name) {
    for (const mo of observers) {
      if (mo.__nuiChild || mo.__nuiAttribute) {
        // The renderer's: connected nodes only (target is the parent for
        // child changes, the element for attributes, the text for data).
        if (!target.isConnected && kind !== REMOVED) continue;
        if (kind === ATTRIBUTE) mo.__nuiAttribute?.(target, name);
        else if (kind === ADDED) mo.__nuiChild?.(node, null);
        else if (kind === REMOVED) mo.__nuiChild?.(node, target);
        else if (kind === DATA && node) mo.__nuiChild?.(target, node); // linkedom reported a text change as its removal from the parent
        continue;
      }
      for (const reg of mo._regs) {
        const o = reg.options;
        if (kind === ATTRIBUTE) {
          if (!o.attributes || !covers(reg, target)) continue;
          if (o.attributeFilter && !o.attributeFilter.includes(name)) continue;
          mo._queue({ type: "attributes", target, attributeName: name, attributeNamespace: null, oldValue: null, addedNodes: [], removedNodes: [], previousSibling: null, nextSibling: null });
        } else if (kind === DATA) {
          if (!o.characterData || !covers(reg, target)) continue;
          mo._queue({ type: "characterData", target, attributeName: null, oldValue: null, addedNodes: [], removedNodes: [], previousSibling: null, nextSibling: null });
        } else {
          if (!o.childList || !covers(reg, target)) continue;
          mo._queue({ type: "childList", target, attributeName: null, oldValue: null,
            addedNodes: kind === ADDED ? [node] : [], removedNodes: kind === REMOVED ? [node] : [],
            previousSibling: kind === ADDED ? node.previousSibling : null, nextSibling: kind === ADDED ? node.nextSibling : null });
        }
        break; // one record per observer per mutation
      }
    }
  }
  const syncObserving = () => nd.observe(observers.size ? hook : null, pageObservers === 0);
  class MutationObserver {
    constructor(callback) { this._callback = callback; this._regs = []; this._records = []; this._scheduled = false; }
    observe(target, options = {}) {
      if (options.attributeOldValue !== undefined || options.attributeFilter !== undefined) options = { ...options, attributes: true };
      if (options.characterDataOldValue !== undefined) options = { ...options, characterData: true };
      const reg = this._regs.find((r) => r.target === target);
      if (reg) reg.options = options; else this._regs.push({ target, options });
      if (!observers.has(this)) {
        observers.add(this);
        if (!this.__nuiChild && !this.__nuiAttribute && !this.__nuiConnectedOnly) pageObservers++;
      }
      syncObserving();
    }
    disconnect() {
      if (observers.delete(this) && !this.__nuiChild && !this.__nuiAttribute && !this.__nuiConnectedOnly) pageObservers--;
      this._regs = [];
      this._records = [];
      syncObserving();
    }
    takeRecords() { return this._records.splice(0); }
    _queue(record) {
      this._records.push(record);
      if (this._scheduled) return;
      this._scheduled = true;
      Promise.resolve().then(() => {
        this._scheduled = false;
        const records = this._records.splice(0);
        if (records.length) this._callback(records, this);
      });
    }
  }

  // ---------------------------------------------------------------- DOMParser
  class DOMParser {
    parseFromString(markup, _type) {
      const d = nd.createDocument();
      let html = String(markup);
      if (!/<html[\s>]/i.test(html)) html = /<body[\s>]/i.test(html) ? `<html>${html}</html>` : `<html><head></head><body>${html}</body></html>`;
      d.__writePage(html);
      return d;
    }
  }

  // ---------------------------------------------------------------- custom elements
  // Not upgraded (the native renderer doesn't run custom element classes):
  // a registry so pages that check or define don't fail.
  const registry = new Map();
  const customElements = {
    define(name, ctor) { registry.set(name, ctor); },
    get(name) { return registry.get(name); },
    whenDefined(name) { return Promise.resolve(registry.get(name)); },
    upgrade() {},
  };

  const CSS_escape = (s) => String(s).replace(/([^\w-])/g, "\\$1");

  const window = {
    Node, CharacterData, Text, Comment, Element, HTMLElement, DocumentFragment, Document, HTMLDocument: Document,
    Event, CustomEvent, EventTarget, MutationObserver, DOMParser, TreeWalker, NodeFilter, Attr, DOMTokenList, customElements,
    InputEvent: Event, DocumentType: function DocumentType() { throw new TypeError("Illegal constructor"); },
    ...classes,
    document,
  };
  return { window, document };
}
