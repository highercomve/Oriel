// Copy buttons, the mobile menu and the active nav link.
(function () {
  function copyText(btn, text) {
    navigator.clipboard.writeText(text).then(function () {
      btn.textContent = "Copied";
      btn.classList.add("copied");
      setTimeout(function () { btn.textContent = "Copy"; btn.classList.remove("copied"); }, 1500);
    });
  }
  document.querySelectorAll("[data-copy]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      copyText(btn, document.getElementById(btn.dataset.copy).textContent.trim());
    });
  });
  // Diagrams: `>[]($block.attrs("mermaid"))` right above a fenced block
  // renders as an empty div.block.mermaid followed by the pre (the Mermaid
  // text). Each is shown as its image, rendered ahead of time
  // (tools/docs/diagrams.mjs: assets/diagrams/<page>-<n>.svg, -dark.svg),
  // fitted to the column; a tap opens it full size.
  var diagrams = document.querySelectorAll(".prose .block.mermaid");
  var script = document.querySelector('script[src*="site.js"]');
  var base = script ? script.src.replace(/site\.js(\?.*)?$/, "diagrams/") : null;
  var page = location.pathname.replace(/index\.html$/, "").split("/").filter(Boolean).pop() || "";
  if (diagrams.length && base) diagrams.forEach(function (block, i) {
    var src = block.querySelector("pre") || block.nextElementSibling;
    var name = base + page + "-" + (i + 1);
    var fig = document.createElement("figure");
    fig.className = "diagram";
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "diagram-open";
    btn.setAttribute("aria-label", "Enlarge the diagram");
    var pic = document.createElement("picture");
    var dark = document.createElement("source");
    dark.srcset = name + "-dark.svg";
    dark.media = "(prefers-color-scheme: dark)";
    var img = document.createElement("img");
    img.src = name + ".svg";
    img.alt = "Diagram";
    img.loading = "lazy";
    img.decoding = "async";
    pic.append(dark, img);
    btn.appendChild(pic);
    var hint = document.createElement("figcaption");
    hint.textContent = "Tap to enlarge";
    fig.append(btn, hint);
    btn.addEventListener("click", function () { openDiagram(img.currentSrc || img.src); });
    block.replaceWith(fig);
    if (src && src.tagName === "PRE" && src.parentNode) src.remove();
  });
  // The full-size view: the image at its own size (or the screen's width,
  // whichever is larger), scrolled and zoomed; Escape, the close button or a
  // tap outside it closes.
  function openDiagram(url) {
    var view = document.createElement("div");
    view.className = "diagram-viewer";
    view.setAttribute("role", "dialog");
    view.setAttribute("aria-modal", "true");
    view.setAttribute("aria-label", "Diagram");
    var bar = document.createElement("div");
    bar.className = "diagram-bar";
    var scale = 1;
    var img = document.createElement("img");
    img.src = url;
    img.alt = "Diagram";
    function zoom(by) {
      scale = Math.min(4, Math.max(0.5, scale * by));
      img.style.width = Math.round(img.naturalWidth * scale) + "px";
    }
    img.addEventListener("load", function () {
      // Start filling the screen's width, but no smaller than 75% (its
      // 17px labels at 13px): a wide diagram scrolls sideways.
      scale = Math.max(0.75, Math.min(1.5, (window.innerWidth - 32) / img.naturalWidth));
      zoom(1);
    });
    [["−", "Zoom out", function () { zoom(1 / 1.25); }], ["+", "Zoom in", function () { zoom(1.25); }], ["×", "Close", close]].forEach(function (b) {
      var x = document.createElement("button");
      x.type = "button";
      x.textContent = b[0];
      x.setAttribute("aria-label", b[1]);
      x.addEventListener("click", b[2]);
      bar.appendChild(x);
    });
    var stage = document.createElement("div");
    stage.className = "diagram-stage";
    stage.appendChild(img);
    stage.addEventListener("click", function (e) { if (e.target === stage) close(); });
    view.append(bar, stage);
    function key(e) { if (e.key === "Escape") close(); }
    function close() {
      document.removeEventListener("keydown", key);
      document.body.classList.remove("viewing-diagram");
      view.remove();
    }
    document.addEventListener("keydown", key);
    document.body.classList.add("viewing-diagram");
    document.body.appendChild(view);
    bar.lastChild.focus();
  }
  document.querySelectorAll(".prose pre:not(.mermaid)").forEach(function (pre) {
    var btn = document.createElement("button");
    btn.className = "copy-btn";
    btn.type = "button";
    btn.textContent = "Copy";
    btn.addEventListener("click", function () { copyText(btn, pre.querySelector("code").innerText.trim()); });
    pre.appendChild(btn);
  });
  // Install command tabs: one panel per OS, preselect the visitor's OS.
  var tabs = document.querySelectorAll(".install-tab");
  function selectOs(os) {
    tabs.forEach(function (t) { t.setAttribute("aria-selected", t.dataset.os === os ? "true" : "false"); });
    document.querySelectorAll("[data-os-panel]").forEach(function (p) { p.hidden = p.dataset.osPanel !== os; });
  }
  tabs.forEach(function (t) { t.addEventListener("click", function () { selectOs(t.dataset.os); }); });
  if (tabs.length) {
    var ua = [navigator.userAgent, navigator.platform, navigator.userAgentData && navigator.userAgentData.platform].join(" ");
    selectOs(/win/i.test(ua) ? "windows" : /mac|iphone|ipad/i.test(ua) ? "macos" : "linux");
  }

  var toggle = document.querySelector(".menu-toggle");
  var nav = document.querySelector(".topnav");
  if (toggle && nav) {
    toggle.addEventListener("click", function () {
      var open = nav.classList.toggle("open");
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
    });
  }
  var here = location.pathname.replace(/index\.html$/, "");
  document.querySelectorAll(".sidebar a, .topnav a").forEach(function (a) {
    var p = new URL(a.href, location.href).pathname.replace(/index\.html$/, "");
    if (p === here) a.classList.add("active");
  });
})();
