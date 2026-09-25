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
  document.querySelectorAll(".prose pre").forEach(function (pre) {
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
