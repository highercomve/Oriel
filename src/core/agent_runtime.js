// The page half of the dev agent (src/core/agent.zig): what `oriel agent`
// and its MCP server do inside a window. Development builds only: agent.zig
// is compiled out of production builds, and with it this file.
//
// The Zig side evaluates this script (once per page: it checks
// `window.__oriel_agent`), then `window.__oriel_agent.run(id, method,
// params)`. Every call answers through `oriel:agent:reply`.
(() => {
  if (window.__oriel_agent) return;

  const MAX_TEXT = 200;
  const MAX_SNAPSHOT = 60000;
  const MAX_LOGS = 1000;

  // Page console and errors, from the first agent call in this page.
  const logs = [];
  let logSeq = 0;
  const pushLog = (level, args) => {
    let text;
    try {
      text = args.map((a) => (typeof a === "string" ? a : a instanceof Error ? `${a.name}: ${a.message}\n${a.stack ?? ""}` : safeJson(a))).join(" ");
    } catch (_) {
      text = String(args);
    }
    logs.push({ seq: ++logSeq, level, text, time: Date.now() });
    if (logs.length > MAX_LOGS) logs.shift();
  };
  for (const level of ["log", "info", "warn", "error", "debug"]) {
    const orig = console[level];
    console[level] = function (...args) {
      pushLog(level, args);
      return orig.apply(this, args);
    };
  }
  window.addEventListener("error", (e) => pushLog("error", [`uncaught: ${e.message} (${e.filename}:${e.lineno})`]));
  window.addEventListener("unhandledrejection", (e) => pushLog("error", ["unhandled rejection:", e.reason]));

  function safeJson(v) {
    if (v === undefined) return "undefined";
    if (v instanceof Element) return describe(v);
    try {
      return JSON.stringify(v);
    } catch (_) {
      return String(v);
    }
  }

  // Refs from the last snapshot: "e12" → element.
  let refs = new Map();
  let nextRef = 1;
  const refOf = new WeakMap();

  function refFor(el) {
    let r = refOf.get(el);
    if (!r) {
      r = `e${nextRef++}`;
      refOf.set(el, r);
    }
    refs.set(r, new WeakRef(el));
    return r;
  }

  const implicitRoles = {
    A: (el) => (el.hasAttribute("href") ? "link" : null),
    BUTTON: () => "button",
    SELECT: (el) => (el.multiple ? "listbox" : "combobox"),
    TEXTAREA: () => "textbox",
    IMG: () => "img",
    H1: () => "heading", H2: () => "heading", H3: () => "heading",
    H4: () => "heading", H5: () => "heading", H6: () => "heading",
    UL: () => "list", OL: () => "list", LI: () => "listitem",
    NAV: () => "navigation", MAIN: () => "main", HEADER: () => "banner",
    FOOTER: () => "contentinfo", ASIDE: () => "complementary",
    DIALOG: () => "dialog", FORM: () => "form", TABLE: () => "table",
    TR: () => "row", TD: () => "cell", TH: () => "columnheader",
    LABEL: () => "label", OPTION: () => "option", PROGRESS: () => "progressbar",
    SUMMARY: () => "button", DETAILS: () => "group", FIELDSET: () => "group",
    INPUT: (el) => {
      const t = (el.getAttribute("type") || "text").toLowerCase();
      if (t === "hidden") return null;
      if (t === "checkbox") return "checkbox";
      if (t === "radio") return "radio";
      if (t === "range") return "slider";
      if (t === "number") return "spinbutton";
      if (t === "search") return "searchbox";
      if (["button", "submit", "reset", "image"].includes(t)) return "button";
      if (t === "file") return "button";
      return "textbox";
    },
  };

  function roleOf(el) {
    const explicit = el.getAttribute("role");
    if (explicit) return explicit.split(/\s+/)[0];
    const f = implicitRoles[el.tagName];
    if (f) return f(el);
    if (el.isContentEditable && el.getAttribute("contenteditable") !== null) return "textbox";
    return null;
  }

  const interactiveRoles = new Set(["button", "link", "textbox", "searchbox", "checkbox", "radio", "combobox", "listbox", "slider", "spinbutton", "switch", "tab", "menuitem", "option", "treeitem"]);

  function isInteractive(el, role) {
    if (role && interactiveRoles.has(role)) return true;
    if (el.hasAttribute("onclick") || el.tabIndex >= 0 && el.hasAttribute("tabindex")) return true;
    return false;
  }

  function clip(s) {
    s = (s || "").replace(/\s+/g, " ").trim();
    return s.length > MAX_TEXT ? s.slice(0, MAX_TEXT) + "…" : s;
  }

  function nameOf(el, role) {
    const aria = el.getAttribute("aria-label");
    if (aria) return clip(aria);
    const by = el.getAttribute("aria-labelledby");
    if (by) {
      const t = by.split(/\s+/).map((id) => document.getElementById(id)?.innerText || "").join(" ");
      if (t.trim()) return clip(t);
    }
    if (el.tagName === "IMG") return clip(el.getAttribute("alt") || el.getAttribute("title") || "");
    if (el.labels && el.labels.length) return clip([...el.labels].map((l) => l.innerText).join(" "));
    if (el.tagName === "INPUT" || el.tagName === "TEXTAREA") {
      const t = (el.getAttribute("type") || "").toLowerCase();
      if (["button", "submit", "reset"].includes(t)) return clip(el.value);
      return clip(el.getAttribute("placeholder") || el.getAttribute("title") || "");
    }
    if (el.tagName === "SELECT") return clip(el.getAttribute("title") || "");
    if (role && (interactiveRoles.has(role) || role === "heading" || role === "option" || role === "listitem" || role === "label" || role === "cell" || role === "columnheader")) {
      return clip(el.innerText || el.textContent || el.getAttribute("title") || "");
    }
    return clip(el.getAttribute("title") || "");
  }

  function visible(el) {
    if (el.getAttribute("aria-hidden") === "true") return false;
    if (el.hidden) return false;
    const s = getComputedStyle(el);
    if (s.display === "none" || s.visibility === "hidden" || s.visibility === "collapse") return false;
    if (s.display === "contents") return true;
    const r = el.getBoundingClientRect();
    if (r.width === 0 && r.height === 0 && s.overflow !== "visible") return false;
    return true;
  }

  function stateOf(el, role) {
    const parts = [];
    if (el.disabled || el.getAttribute("aria-disabled") === "true") parts.push("disabled");
    if (role === "checkbox" || role === "radio" || role === "switch") {
      const c = el.checked ?? el.getAttribute("aria-checked") === "true";
      parts.push(c ? "checked" : "unchecked");
    }
    const exp = el.getAttribute("aria-expanded");
    if (exp) parts.push(exp === "true" ? "expanded" : "collapsed");
    if (el.getAttribute("aria-selected") === "true" || (el.tagName === "OPTION" && el.selected)) parts.push("selected");
    if (el.getAttribute("aria-current") && el.getAttribute("aria-current") !== "false") parts.push("current");
    if (document.activeElement === el && el !== document.body) parts.push("focused");
    if (role === "heading") {
      const lvl = el.getAttribute("aria-level") || (/^H([1-6])$/.exec(el.tagName) || [])[1];
      if (lvl) parts.push(`level=${lvl}`);
    }
    return parts;
  }

  function valueOf(el, role) {
    if (role === "textbox" || role === "searchbox" || role === "spinbutton" || role === "slider" || role === "combobox") {
      if ("value" in el && el.tagName !== "BUTTON") return clip(String(el.value ?? ""));
      if (el.isContentEditable) return clip(el.innerText);
    }
    return null;
  }

  // An indented outline of what a user sees: roles, names, states, values,
  // and a ref (`e12`) for every element an action can target.
  function snapshot(params) {
    refs = new Map();
    const root = params.selector ? document.querySelector(params.selector) : document.body;
    if (!root) throw new Error(`no element matches ${params.selector}`);
    const interactiveOnly = !!params.interactive;
    const lines = [];
    let size = 0;
    let truncated = false;
    const emit = (depth, line) => {
      if (truncated) return;
      const l = "  ".repeat(depth) + "- " + line;
      size += l.length + 1;
      if (size > MAX_SNAPSHOT) {
        truncated = true;
        return;
      }
      lines.push(l);
    };
    const walk = (node, depth) => {
      if (truncated) return;
      for (const child of node.childNodes) {
        if (child.nodeType === Node.TEXT_NODE) {
          if (interactiveOnly) continue;
          const parentRole = child.parentElement && roleOf(child.parentElement);
          if (parentRole && nameOf(child.parentElement, parentRole)) continue; // already the name
          const t = clip(child.textContent);
          if (t) emit(depth, `text: ${JSON.stringify(t)}`);
          continue;
        }
        if (child.nodeType !== Node.ELEMENT_NODE) continue;
        const el = child;
        if (["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "META", "LINK"].includes(el.tagName)) continue;
        if (!visible(el)) continue;
        const role = roleOf(el);
        const interactive = isInteractive(el, role);
        const show = interactiveOnly ? interactive : role || interactive;
        if (show) {
          const name = nameOf(el, role);
          let line = role || el.tagName.toLowerCase();
          if (name) line += ` ${JSON.stringify(name)}`;
          const st = stateOf(el, role);
          if (st.length) line += ` [${st.join(", ")}]`;
          line += ` [ref=${refFor(el)}]`;
          const v = valueOf(el, role);
          if (v !== null) line += ` value=${JSON.stringify(v)}`;
          if (role === "link" && el.getAttribute("href")) line += ` href=${JSON.stringify(el.getAttribute("href"))}`;
          emit(depth, line);
          // Leaves: their text is the name.
          if (role === "button" || role === "link" || role === "textbox" || role === "searchbox" || role === "option" || role === "heading" || role === "img") {
            if (!el.querySelector("button, a[href], input, select, textarea, [role]")) continue;
          }
          walk(el, depth + 1);
        } else {
          walk(el, depth);
        }
        if (el.shadowRoot) walk(el.shadowRoot, show ? depth + 1 : depth);
      }
    };
    walk(root, 0);
    return {
      url: location.href,
      title: document.title,
      snapshot: lines.join("\n") + (truncated ? "\n- … (truncated: pass a selector to narrow it)" : ""),
    };
  }

  function describe(el) {
    const role = roleOf(el);
    const name = nameOf(el, role);
    return `${role || el.tagName.toLowerCase()}${name ? ` ${JSON.stringify(name)}` : ""}`;
  }

  // A target: "e12" (a snapshot ref), "text=Save" (the smallest visible
  // element with that text), "role=button[name=Save]", or a CSS selector.
  function resolve(target) {
    if (target == null || target === "") throw new Error("missing target");
    if (/^e\d+$/.test(target)) {
      const el = refs.get(target)?.deref();
      if (!el || !el.isConnected) throw new Error(`ref ${target} is stale: take a new snapshot`);
      return el;
    }
    if (target.startsWith("text=")) {
      const want = target.slice(5).trim().toLowerCase();
      let best = null;
      for (const el of document.body.querySelectorAll("*")) {
        if (!visible(el)) continue;
        const t = (el.innerText || "").replace(/\s+/g, " ").trim().toLowerCase();
        if (t === want || (want.length > 0 && t.includes(want))) {
          if (!best || best.contains(el)) best = el;
        }
      }
      if (!best) throw new Error(`no visible element has text ${JSON.stringify(target.slice(5))}`);
      return best;
    }
    const m = /^role=([a-z]+)(?:\[name=(.*)\])?$/i.exec(target);
    if (m) {
      const want = m[2] ? m[2].replace(/^["']|["']$/g, "").toLowerCase() : null;
      for (const el of document.body.querySelectorAll("*")) {
        const role = roleOf(el);
        if (role !== m[1] || !visible(el)) continue;
        if (want === null || nameOf(el, role).toLowerCase().includes(want)) return el;
      }
      throw new Error(`no visible element matches ${target}`);
    }
    const el = document.querySelector(target);
    if (!el) throw new Error(`no element matches ${JSON.stringify(target)}`);
    return el;
  }

  function center(el) {
    el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
    const r = el.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  }

  function mouse(el, type, p, extra = {}) {
    const init = { bubbles: true, cancelable: true, composed: true, view: window, clientX: p.x, clientY: p.y, button: 0, buttons: type.endsWith("down") ? 1 : 0, ...extra };
    const E = type.startsWith("pointer") && typeof PointerEvent === "function" ? PointerEvent : MouseEvent;
    if (E === PointerEvent) Object.assign(init, { pointerId: 1, pointerType: "mouse", isPrimary: true });
    return el.dispatchEvent(new E(type, init));
  }

  function click(params) {
    const el = resolve(params.target);
    if (el.disabled) throw new Error(`${describe(el)} is disabled`);
    const p = center(el);
    // What a real click would hit (an overlay may cover the target).
    const hit = document.elementFromPoint(p.x, p.y);
    const target = hit && (el === hit || el.contains(hit)) ? hit : el;
    const count = params.double ? 2 : 1;
    mouse(target, "pointerover", p);
    mouse(target, "mouseover", p);
    for (let i = 1; i <= count; i++) {
      mouse(target, "pointerdown", p, { detail: i });
      mouse(target, "mousedown", p, { detail: i });
      if (i === 1 && typeof el.focus === "function") el.focus({ preventScroll: true });
      mouse(target, "pointerup", p, { detail: i });
      mouse(target, "mouseup", p, { detail: i });
      mouse(target, "click", p, { detail: i });
    }
    if (params.double) mouse(target, "dblclick", p, { detail: 2 });
    return { clicked: describe(el), covered: hit && !(el === hit || el.contains(hit)) ? describe(hit) : null };
  }

  function hover(params) {
    const el = resolve(params.target);
    const p = center(el);
    for (const t of ["pointerover", "pointerenter", "mouseover", "mouseenter", "pointermove", "mousemove"]) mouse(el, t, p);
    return { hovered: describe(el) };
  }

  function setNativeValue(el, value) {
    const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : el.tagName === "SELECT" ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
    if (setter) setter.call(el, value);
    else el.value = value;
  }

  // Replace a field's value the way typing would: frameworks (React's
  // value tracker included) see input and change events.
  function fill(params) {
    const el = resolve(params.target);
    const value = String(params.value ?? "");
    el.focus?.({ preventScroll: true });
    if (el.tagName === "SELECT") {
      const opt = [...el.options].find((o) => o.value === value || o.text.trim() === value);
      if (!opt) throw new Error(`${describe(el)} has no option ${JSON.stringify(value)}`);
      setNativeValue(el, opt.value);
    } else if (el.tagName === "INPUT" && ["checkbox", "radio"].includes(el.type)) {
      const want = !["false", "0", "off", ""].includes(value.toLowerCase());
      if (el.checked !== want) el.click();
      return { filled: describe(el), checked: el.checked };
    } else if (el.tagName === "INPUT" || el.tagName === "TEXTAREA") {
      setNativeValue(el, value);
    } else if (el.isContentEditable) {
      el.textContent = value;
    } else {
      throw new Error(`${describe(el)} is not a field`);
    }
    el.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: value }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return { filled: describe(el), value: "value" in el ? el.value : el.innerText };
  }

  // Insert text at the caret (after what's there), as the keyboard would.
  function type(params) {
    const el = params.target ? resolve(params.target) : document.activeElement;
    if (!el || el === document.body) throw new Error("nothing is focused: pass a target");
    el.focus?.({ preventScroll: true });
    const text = String(params.text ?? "");
    for (const ch of text) {
      const k = { key: ch, bubbles: true, cancelable: true, composed: true };
      if (!el.dispatchEvent(new KeyboardEvent("keydown", k))) continue;
      el.dispatchEvent(new KeyboardEvent("keypress", k));
      if (!document.execCommand("insertText", false, ch)) {
        if ("value" in el) {
          const start = el.selectionStart ?? el.value.length;
          const end = el.selectionEnd ?? el.value.length;
          setNativeValue(el, el.value.slice(0, start) + ch + el.value.slice(end));
          el.selectionStart = el.selectionEnd = start + 1;
          el.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: ch }));
        }
      }
      el.dispatchEvent(new KeyboardEvent("keyup", k));
    }
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return { typed: describe(el), value: "value" in el ? el.value : el.innerText };
  }

  const keyCodes = { Enter: "Enter", Tab: "Tab", Escape: "Escape", Backspace: "Backspace", Delete: "Delete", ArrowUp: "ArrowUp", ArrowDown: "ArrowDown", ArrowLeft: "ArrowLeft", ArrowRight: "ArrowRight", Home: "Home", End: "End", PageUp: "PageUp", PageDown: "PageDown", " ": "Space" };

  // "Enter", "Control+a", "Shift+Tab", "Meta+k".
  function press(params) {
    const el = params.target ? resolve(params.target) : document.activeElement || document.body;
    if (params.target) el.focus?.({ preventScroll: true });
    const parts = String(params.key || "").split("+");
    const key = parts.pop();
    if (!key) throw new Error("missing key");
    const mods = new Set(parts.map((p) => p.toLowerCase()));
    const init = {
      key, code: keyCodes[key] || (key.length === 1 ? (/[a-z]/i.test(key) ? `Key${key.toUpperCase()}` : /\d/.test(key) ? `Digit${key}` : key) : key),
      bubbles: true, cancelable: true, composed: true,
      ctrlKey: mods.has("control") || mods.has("ctrl"), shiftKey: mods.has("shift"),
      altKey: mods.has("alt"), metaKey: mods.has("meta") || mods.has("cmd"),
    };
    const go = el.dispatchEvent(new KeyboardEvent("keydown", init));
    if (go) {
      // What the browser does by default for the keys agents press most.
      if (key === "Enter" && el.form && el.tagName === "INPUT") el.form.requestSubmit?.();
      else if (key === "Enter" && (el.tagName === "BUTTON" || el.tagName === "A")) el.click();
      else if (key === " " && el.tagName === "BUTTON") el.click();
      else if (key === "Tab") focusNext(el, init.shiftKey);
      else if (key === "Backspace" && !init.ctrlKey && !init.metaKey) document.execCommand("delete");
      else if (key === "a" && (init.ctrlKey || init.metaKey) && "select" in el) el.select();
      else if (key.length === 1 && !init.ctrlKey && !init.metaKey && !init.altKey) document.execCommand("insertText", false, key);
    }
    el.dispatchEvent(new KeyboardEvent("keyup", init));
    return { pressed: params.key, on: describe(el), defaultPrevented: !go };
  }

  function focusNext(from, back) {
    const all = [...document.querySelectorAll("a[href], button, input, select, textarea, [tabindex]")].filter((e) => e.tabIndex >= 0 && !e.disabled && visible(e));
    const i = all.indexOf(from);
    const next = all[(i + (back ? -1 : 1) + all.length) % all.length];
    next?.focus();
  }

  function scroll(params) {
    if (params.target) {
      const el = resolve(params.target);
      if (params.dy || params.dx) el.scrollBy(params.dx || 0, params.dy || 0);
      else el.scrollIntoView({ block: "center", behavior: "instant" });
    } else {
      window.scrollBy(params.dx || 0, params.dy || 0);
    }
    return { scrollX: window.scrollX, scrollY: window.scrollY };
  }

  function text(params) {
    const el = params.target ? resolve(params.target) : document.body;
    const t = el.innerText ?? el.textContent ?? "";
    return { text: t.length > MAX_SNAPSHOT ? t.slice(0, MAX_SNAPSHOT) + "…" : t };
  }

  function present(params) {
    try {
      const el = resolve(params.target);
      return visible(el);
    } catch (_) {
      return false;
    }
  }

  // Until the target is visible (or, `state: "hidden"`, gone), or
  // `timeout_ms` passes.
  async function waitFor(params) {
    const timeout = Math.min(params.timeout_ms ?? 5000, 60000);
    const hidden = params.state === "hidden";
    const start = performance.now();
    for (;;) {
      const there = present(params);
      if (there !== hidden) return { waited_ms: Math.round(performance.now() - start) };
      if (performance.now() - start > timeout) throw new Error(`timed out after ${timeout} ms waiting for ${params.target} to be ${hidden ? "hidden" : "visible"}`);
      await new Promise((r) => setTimeout(r, 50));
    }
  }

  function getLogs(params) {
    const since = params.since ?? 0;
    return { entries: logs.filter((l) => l.seq > since), last: logSeq };
  }

  async function evaluate(params) {
    // Indirect eval: global scope. Dev builds send no CSP.
    let v = (0, eval)(String(params.expression));
    if (v && typeof v.then === "function") v = await v;
    return toJson(v);
  }

  function toJson(v) {
    if (v === undefined) return null;
    if (v instanceof Element) return describe(v);
    if (v instanceof NodeList || v instanceof HTMLCollection) return [...v].map(describe);
    try {
      return JSON.parse(JSON.stringify(v));
    } catch (_) {
      return String(v);
    }
  }

  function invoke(params) {
    return window.oriel.invoke(params.cmd, params.args ?? null);
  }

  function reload() {
    setTimeout(() => location.reload(), 0);
    return { reloading: location.href };
  }

  function info() {
    return {
      url: location.href, title: document.title, readyState: document.readyState,
      size: { width: innerWidth, height: innerHeight, dpr: devicePixelRatio },
      focused: document.activeElement && document.activeElement !== document.body ? describe(document.activeElement) : null,
    };
  }

  const methods = { snapshot, click, hover, fill, type, press, scroll, text, wait_for: waitFor, logs: getLogs, eval: evaluate, invoke, reload, info };

  window.__oriel_agent = {
    async run(id, method, params) {
      let ok = true;
      let value;
      try {
        const f = methods[method];
        if (!f) throw new Error(`unknown method ${method}`);
        value = toJson(await f(params || {}));
      } catch (e) {
        ok = false;
        value = e instanceof Error ? e.message : String(e);
      }
      try {
        await window.oriel.invoke("oriel:agent:reply", { id, ok, value: value ?? null });
      } catch (e) {
        // The reply didn't fit (or the bridge is gone): say why instead.
        await window.oriel.invoke("oriel:agent:reply", { id, ok: false, value: `reply failed: ${e && e.message}` }).catch(() => {});
      }
    },
  };
})();
