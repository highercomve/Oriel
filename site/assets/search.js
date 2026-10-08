// Pagefind is generated after Zine builds. Load its index only when needed.
(function () {
  const dialog = document.getElementById("docs-search");
  const trigger = document.querySelector(".search-trigger");
  if (!dialog || !trigger || typeof dialog.showModal !== "function") return;
  const input = document.getElementById("search-input");
  const status = document.getElementById("search-status");
  const results = document.getElementById("search-results");
  const root = new URL(dialog.dataset.searchRoot, location.href);
  let engine;
  let revision = 0;
  let timer;
  let previousFocus;

  function loadEngine() {
    if (!engine) {
      engine = import(new URL("pagefind/pagefind.js", root).href).then(async function (pagefind) {
        await pagefind.options({ baseUrl: root.pathname });
        return pagefind;
      }).catch(function (error) { engine = null; throw error; });
    }
    return engine;
  }

  async function search(query, request) {
    try {
      const pagefind = await loadEngine();
      const found = await pagefind.search(query);
      const pages = await Promise.all(found.results.slice(0, 12).map(function (result) { return result.data(); }));
      if (request !== revision || !dialog.open) return;
      results.replaceChildren();
      status.textContent = found.results.length
        ? found.results.length + " matching page" + (found.results.length === 1 ? "" : "s") + (found.results.length > 12 ? " · showing the first 12" : "")
        : "No results. Try a different word or API name.";
      pages.forEach(function (page) {
        const item = document.createElement("li");
        const link = document.createElement("a");
        link.href = page.url;
        const title = document.createElement("strong");
        title.textContent = page.meta.title || "Documentation";
        const excerpt = document.createElement("p");
        // Pagefind escapes excerpt text and adds only its own <mark> tags.
        excerpt.innerHTML = page.excerpt;
        link.append(title, excerpt);
        item.append(link);
        results.append(item);
      });
    } catch (error) {
      if (request !== revision || !dialog.open) return;
      results.replaceChildren();
      status.textContent = "Search could not load. Check your connection and try again.";
    }
  }

  function scheduleSearch() {
    clearTimeout(timer);
    const request = ++revision;
    const query = input.value.trim();
    results.replaceChildren();
    status.textContent = query ? "Searching…" : "Type to search the documentation.";
    if (query) timer = setTimeout(function () { search(query, request); }, 150);
  }

  function openSearch() {
    if (dialog.open) return;
    previousFocus = document.activeElement;
    dialog.showModal();
    input.focus();
    input.select();
    scheduleSearch();
  }

  trigger.hidden = false;
  trigger.querySelector("kbd").textContent = /Mac|iPhone|iPad/.test(navigator.platform) ? "⌘ K" : "Ctrl K";
  trigger.addEventListener("click", openSearch);
  input.addEventListener("input", scheduleSearch);
  dialog.querySelector(".search-close").addEventListener("click", function () { dialog.close(); });
  dialog.addEventListener("close", function () {
    // The native close event is queued; a shortcut may already have reopened it.
    if (dialog.open) return;
    ++revision;
    clearTimeout(timer);
    if (previousFocus && previousFocus.isConnected) previousFocus.focus();
  });
  dialog.addEventListener("click", function (event) {
    const bounds = dialog.getBoundingClientRect();
    if (event.target === dialog && (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom)) dialog.close();
  });
  dialog.addEventListener("keydown", function (event) {
    if (event.key === "Escape") { event.preventDefault(); dialog.close(); return; }
    const links = Array.from(results.querySelectorAll("a"));
    const index = links.indexOf(document.activeElement);
    if (event.key === "ArrowDown" && links.length) {
      event.preventDefault();
      links[Math.min(index + 1, links.length - 1)].focus();
    } else if (event.key === "ArrowUp" && links.length) {
      event.preventDefault();
      (index <= 0 ? input : links[index - 1]).focus();
    } else if (event.key === "Enter" && document.activeElement === input && links.length) {
      event.preventDefault();
      links[0].click();
    }
  });
  document.addEventListener("keydown", function (event) {
    const editing = event.target.closest("input, textarea, select, [contenteditable]");
    const command = (event.ctrlKey || event.metaKey) && !event.altKey && event.key.toLowerCase() === "k";
    const slash = event.key === "/" && !editing && !event.ctrlKey && !event.metaKey && !event.altKey;
    if (command || slash) { event.preventDefault(); openSearch(); }
  });
})();
