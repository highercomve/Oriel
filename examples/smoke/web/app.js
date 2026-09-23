const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);
const autoQuit = location.search.includes("auto-quit");

$("greet").onclick = async () => {
  $("greet-out").textContent = await ziguri.invoke("greet", { name: $("name").value });
};

async function main() {
  const results = [];
  try {
    const status = await ziguri.invoke("status");
    results.push(...status.checks);

    if (status.media_url) {
      try {
        const res = await fetch(status.media_url);
        const body = await res.json();
        $("fetch-out").textContent = ` fetch(${status.media_url}) → ${JSON.stringify(body)}`;
        results.push({ module: "webview→media", ok: body.pong === true, detail: `fetch from app:// page: ${JSON.stringify(body)}` });
      } catch (e) {
        $("fetch-out").textContent = ` failed: ${e}`;
        results.push({ module: "webview→media", ok: false, detail: String(e) });
      }
    }

    const greeting = await ziguri.invoke("greet", { name: "IPC" });
    results.push({ module: "ipc", ok: greeting.startsWith("Hello, IPC!"), detail: `invoke("greet") → ${greeting}` });

    results.push(...(await securityChecks()));

    try {
      await ziguri.invoke("no_such_command");
      results.push({ module: "ipc errors", ok: false, detail: "unknown command resolved" });
    } catch (e) {
      results.push({ module: "ipc errors", ok: String(e).includes("UnknownCommand"), detail: `unknown command rejected: ${e}` });
    }
  } catch (e) {
    results.push({ module: "ipc", ok: false, detail: String(e) });
  }

  $("checks").innerHTML = results.map((c) =>
    `<tr><td class="state ${c.ok ? "ok" : "fail"}">${c.ok ? "OK" : "FAIL"}</td>` +
    `<td><code>${esc(c.module)}</code></td><td>${esc(c.detail)}</td></tr>`).join("");

  if (autoQuit) {
    const report = results.map((c) => `[${c.ok ? "ok" : "FAIL"}] ${c.module.padEnd(16)} ${c.detail}`).join("\n");
    await ziguri.invoke("done", { failed: results.filter((c) => !c.ok).length, report });
  }
}
main();

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Checks of the webview security policy, run inside the real webview.
async function securityChecks() {
  const out = [];
  const check = (module, ok, detail) => out.push({ module, ok, detail });

  // CSP: script-src 'self' forbids eval and inline scripts.
  let evalBlocked = false;
  try { eval("1"); } catch (e) { evalBlocked = true; }
  check("csp eval", evalBlocked, evalBlocked ? "eval() refused by the Content-Security-Policy" : "eval() ran");

  const inline = document.createElement("script");
  inline.textContent = "window.__inlineRan = true";
  document.body.append(inline);
  await sleep(50);
  check("csp inline", !window.__inlineRan, window.__inlineRan ? "inline script ran" : "injected inline <script> did not run");

  // Remote iframe: navigation policy keeps it on about:blank.
  const frame = document.createElement("iframe");
  frame.src = "https://example.com/";
  frame.style.display = "none";
  document.body.append(frame);
  await sleep(1500);
  let frameUrl = "(cross-origin: loaded!)";
  try { frameUrl = frame.contentDocument?.URL ?? frameUrl; } catch (e) {}
  check("nav iframe", frameUrl === "about:blank", `iframe to https://example.com stayed at ${frameUrl}`);

  // Popups: scripts can't open windows.
  const popup = window.open("https://example.com/");
  check("nav popup", popup === null, popup === null ? "window.open() returned null" : "popup opened");

  // Top-level navigation away from the app is blocked; this page keeps running.
  const before = location.href;
  location.href = "https://example.com/";
  await sleep(1500);
  check("nav top-level", location.href === before, `location.href = https://example.com blocked; still on ${location.pathname}`);

  // Zig -> JS events.
  const got = await new Promise((resolve) => {
    const off = ziguri.listen("ping", (p) => { off(); resolve(p); });
    ziguri.invoke("emit_ping", { n: 42 });
    setTimeout(() => resolve(null), 1000);
  });
  check("events", got?.n === 42, got ? `listen("ping") received ${JSON.stringify(got)}` : "no event received");
  return out;
}
