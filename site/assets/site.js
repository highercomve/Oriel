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
  // renders as an empty div.block.mermaid followed by the pre; Mermaid draws
  // that pre's text (loaded only on pages that have one).
  var diagrams = document.querySelectorAll(".prose .block.mermaid");
  if (diagrams.length) {
    diagrams.forEach(function (block) {
      var src = block.querySelector("pre") || block.nextElementSibling;
      if (!src || src.tagName !== "PRE") return;
      var pre = document.createElement("pre");
      pre.className = "mermaid";
      pre.textContent = src.textContent;
      block.replaceChildren(pre);
      if (src.parentNode !== block) src.remove();
    });
    import("https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs").then(function (m) {
      var light = window.matchMedia("(prefers-color-scheme: light)").matches;
      m.default.initialize({ startOnLoad: false, theme: light ? "neutral" : "dark", fontFamily: "Inter, sans-serif", securityLevel: "strict" });
      m.default.run({ querySelector: ".prose pre.mermaid" });
    });
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
