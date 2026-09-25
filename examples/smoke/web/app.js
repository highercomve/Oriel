const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);
const autoQuit = location.search.includes("auto-quit");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

if (location.search.includes("child=1")) {
  document.body.innerHTML = "<h1>Oriel Child Window</h1>";
  oriel.listen("ping_to_child", (payload) => {
    oriel.window.emitTo("main", "pong_from_child", { received: payload });
  });
  oriel.listen("close_child", async () => {
    const cur = oriel.window.current();
    await cur.close();
  });
} else {
  $("greet").onclick = async () => {
    $("greet-out").textContent = await oriel.invoke("greet", { name: $("name").value });
  };

  async function main() {
    const results = [];
    try {
      const status = await oriel.invoke("status");
      results.push(...status.checks);

      if (status.ping_url) {
        try {
          const res = await fetch(status.ping_url);
          const body = await res.json();
          $("fetch-out").textContent = ` fetch(${status.ping_url}) → ${JSON.stringify(body)}`;
          results.push({ module: "webview→media", ok: body.pong === true, detail: `fetch from app:// page: ${JSON.stringify(body)}` });
        } catch (e) {
          $("fetch-out").textContent = ` failed: ${e}`;
          results.push({ module: "webview→media", ok: false, detail: String(e) });
        }
      }

      if (status.media_url && status.expected_sample_hex) {
        try {
          const res = await fetch(status.media_url, {
            headers: { Range: "bytes=100-199" }
          });
          const cr = res.headers.get("content-range");
          const buf = await res.arrayBuffer();
          const hex = Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
          const expectedCr = `bytes 100-199/${status.total_file_size}`;
          const ok = res.status === 206 && cr === expectedCr && hex === status.expected_sample_hex;
          results.push({
            module: "media range tcp",
            ok: ok,
            detail: `status ${res.status}, Content-Range: ${cr}, 100 B ${ok ? "matched" : "mismatched"}`
          });
        } catch (e) {
          results.push({ module: "media range tcp", ok: false, detail: String(e) });
        }
      }

      if (status.media_app_url && status.expected_sample_hex) {
        try {
          const res = await fetch(status.media_app_url, {
            headers: { Range: "bytes=100-199" }
          });
          const cr = res.headers.get("content-range");
          const buf = await res.arrayBuffer();
          const hex = Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
          const expectedCr = `bytes 100-199/${status.total_file_size}`;
          const ok = res.status === 206 && cr === expectedCr && hex === status.expected_sample_hex;
          results.push({
            module: "media range app://",
            ok: ok,
            detail: `status ${res.status}, Content-Range: ${cr}, 100 B ${ok ? "matched" : "mismatched"}`
          });
        } catch (e) {
          results.push({ module: "media range app://", ok: false, detail: String(e) });
        }

        // The whole file (1 MiB): streamed in chunks by the scheme handler.
        try {
          const res = await fetch(status.media_app_url);
          const buf = await res.arrayBuffer();
          const ok = res.status === 200 && buf.byteLength === status.total_file_size;
          results.push({
            module: "media full app://",
            ok: ok,
            detail: `status ${res.status}, ${buf.byteLength} of ${status.total_file_size} B`
          });
        } catch (e) {
          results.push({ module: "media full app://", ok: false, detail: String(e) });
        }
      }

      if (status.media_url) {
        // Load the WAV from the TCP media server into <audio> and seek: the
        // GStreamer player issues its own Range requests. (WebKitGTK's player
        // refuses custom schemes, so <audio src="app://..."> cannot work.)
        const seek = await new Promise((resolve) => {
          const audio = document.createElement("audio");
          audio.preload = "auto";
          const tid = setTimeout(() => resolve({ ok: false, detail: `no seeked event within 5 s (readyState ${audio.readyState})` }), 5000);
          audio.addEventListener("loadedmetadata", () => { audio.currentTime = 5; });
          audio.addEventListener("seeked", () => {
            clearTimeout(tid);
            resolve({ ok: Math.abs(audio.currentTime - 5) < 0.1 && Math.abs(audio.duration - status.total_file_size / 88200) < 0.1,
                      detail: `duration ${audio.duration.toFixed(2)} s, seeked to ${audio.currentTime.toFixed(2)} s` });
          });
          audio.addEventListener("error", () => {
            clearTimeout(tid);
            resolve({ ok: false, detail: `media error ${audio.error && audio.error.code}: ${audio.error && audio.error.message}` });
          });
          audio.src = status.media_url;
        });
        results.push({ module: "media audio seek", ...seek });
      }

      const greeting = await oriel.invoke("greet", { name: "IPC" });
      results.push({ module: "ipc", ok: greeting.startsWith("Hello, IPC!"), detail: `invoke("greet") → ${greeting}` });

      // Async IPC: sleep 500ms while sync_ping answers immediately in parallel
      const asyncStart = performance.now();
      const sleepPromise = oriel.invoke("async_sleep", { ms: 500 });
      const syncRes = await oriel.invoke("sync_ping");
      const syncElapsed = performance.now() - asyncStart;
      const sleepRes = await sleepPromise;
      const totalElapsed = performance.now() - asyncStart;
      const asyncOk = syncRes === "pong" && syncElapsed < 250 && sleepRes === "slept" && totalElapsed >= 400;
      results.push({
        module: "async ipc",
        ok: asyncOk,
        detail: `sync returned in ${Math.round(syncElapsed)}ms; total ${Math.round(totalElapsed)}ms`
      });

      try {
        const winCheck = await oriel.invoke("test_windows_and_menu");
        results.push({ module: "windows+menu", ok: winCheck.ok, detail: winCheck.detail });
      } catch (e) {
        results.push({ module: "windows+menu", ok: false, detail: String(e) });
      }

      try {
        const clip = await oriel.invoke("clipboard_roundtrip");
        results.push({ module: "clipboard r/w", ok: clip.ok, detail: clip.detail });
      } catch (e) {
        results.push({ module: "clipboard r/w", ok: false, detail: String(e) });
      }

      try {
        const curDl = await oriel.deepLink.current();
        results.push({
          module: "deep_link js",
          ok: curDl === null || typeof curDl === "string",
          detail: `current() returned ${JSON.stringify(curDl)}`,
        });
      } catch (e) {
        results.push({ module: "deep_link js", ok: false, detail: String(e) });
      }

      results.push(...(await permissionChecks()));
      results.push(...(await windowChecks()));
      results.push(...(await securityChecks()));

      try {
        await oriel.invoke("no_such_command");
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
      await oriel.invoke("done", { failed: results.filter((c) => !c.ok).length, report });
    }
  }
  main();
}

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
    const off = oriel.listen("ping", (p) => { off(); resolve(p); });
    oriel.invoke("emit_ping", { n: 42 });
    setTimeout(() => resolve(null), 1000);
  });
  check("events", got?.n === 42, got ? `listen("ping") received ${JSON.stringify(got)}` : "no event received");

  // openExternal: rejects dangerous schemes (file:, javascript:), allows http(s):
  let fileRejected = false;
  try {
    await oriel.openExternal("file:///etc/passwd");
  } catch (e) {
    fileRejected = true;
  }
  check("openExt file:", fileRejected, fileRejected ? "file: URL rejected" : "file: URL was not rejected");

  let jsRejected = false;
  try {
    await oriel.openExternal("javascript:alert(1)");
  } catch (e) {
    jsRejected = true;
  }
  check("openExt js:", jsRejected, jsRejected ? "javascript: URL rejected" : "javascript: URL was not rejected");

  let httpsAllowed = false;
  try {
    await oriel.openExternal("https://example.com");
    httpsAllowed = true;
  } catch (e) {
    httpsAllowed = false;
  }
  check("openExt https:", httpsAllowed, httpsAllowed ? "https: URL allowed and dispatched to hook" : "https: URL was rejected");

  return out;
}

// In-webview checks for oriel.window API
async function windowChecks() {
  const out = [];
  const check = (module, ok, detail) => out.push({ module, ok, detail });

  // 1. Current window check
  try {
    const cur = oriel.window.current();
    check("window current", cur && cur.label === "main", cur ? `current window label is "${cur.label}"` : "current() returned null/undefined");
  } catch (e) {
    check("window current", false, String(e));
  }

  // 2. Invalid label rejected
  let invalidRejected = false;
  let invalidErr = "";
  try {
    await oriel.window.open({ label: "invalid label with spaces" });
  } catch (e) {
    invalidRejected = true;
    invalidErr = String(e);
  }
  check(
    "window invalid label",
    invalidRejected && invalidErr.includes("InvalidLabel"),
    invalidRejected ? `rejected invalid label: ${invalidErr}` : "invalid label was accepted"
  );

  // 3. Open child window & window:created event
  let createdReceived = null;
  const offCreated = oriel.listen("window:created", (p) => {
    if (p && p.label === "smoke-child") createdReceived = p;
  });

  let closedReceived = null;
  const offClosed = oriel.listen("window:closed", (p) => {
    if (p && p.label === "smoke-child") closedReceived = p;
  });

  let childHandle = null;
  try {
    childHandle = await oriel.window.open({
      label: "smoke-child",
      url: "index.html?child=1",
      title: "Smoke Child Window",
      width: 350,
      height: 250,
    });
  } catch (e) {
    check("window open", false, `open() failed: ${e}`);
  }

  if (childHandle) {
    check("window open", childHandle.label === "smoke-child", `opened child window "${childHandle.label}"`);

    // Wait for window:created
    for (let i = 0; i < 30 && !createdReceived; i++) {
      await sleep(100);
    }
    offCreated();
    const createdOk = createdReceived && createdReceived.label === "smoke-child";
    check(
      "window created event",
      createdOk,
      createdOk ? `received window:created for "${createdReceived.label}"` : `not received or mismatched: ${JSON.stringify(createdReceived)}`
    );

    // 4. emitTo round-trip
    let pongReceived = null;
    const offPong = oriel.listen("pong_from_child", (p) => {
      pongReceived = p;
    });

    for (let i = 0; i < 40 && !pongReceived; i++) {
      try {
        await oriel.window.emitTo("smoke-child", "ping_to_child", { testNum: 42 });
      } catch (e) {
        // Child might still be loading
      }
      await sleep(100);
    }
    offPong();

    const pongOk = pongReceived && pongReceived.received && pongReceived.received.testNum === 42;
    check(
      "window emit round-trip",
      pongOk,
      pongOk ? `received pong from child with payload ${JSON.stringify(pongReceived.received)}` : `round-trip failed: ${JSON.stringify(pongReceived)}`
    );

    // 5. Child closes itself from its own JS
    for (let i = 0; i < 30 && !closedReceived; i++) {
      try {
        await oriel.window.emitTo("smoke-child", "close_child", {});
      } catch (e) {}
      await sleep(100);
    }
    offClosed();

    const closedOk = closedReceived && closedReceived.label === "smoke-child";
    check(
      "window closed event",
      closedOk,
      closedOk ? `received window:closed for "${closedReceived.label}"` : `not received: ${JSON.stringify(closedReceived)}`
    );

    // Give it a moment to ensure unregistration is finished
    await sleep(200);

    // 6. Window query after close
    const childAfterClose = await oriel.window.get("smoke-child");
    check("window get after close", childAfterClose === null, childAfterClose === null ? "get('smoke-child') returned null" : "window still found");

    // 7. emitTo on closed window rejects with WindowNotFound
    let emitClosedRejected = false;
    let emitClosedErr = "";
    try {
      await oriel.window.emitTo("smoke-child", "ping_to_child", {});
    } catch (e) {
      emitClosedRejected = true;
      emitClosedErr = String(e);
    }
    check(
      "window closed emitTo",
      emitClosedRejected && emitClosedErr.includes("WindowNotFound"),
      emitClosedRejected ? `rejected emitTo closed window: ${emitClosedErr}` : "emitTo on closed window did not reject"
    );
  }

  return out;
}


// Permissions: the app declares the microphone and notifications, not the camera.
async function permissionChecks() {
  const out = [];
  const withTimeout = (p, ms) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error("no answer (an OS prompt?)")), ms))]);
  try {
    const cam = await oriel.permissions.query("camera");
    const camReq = await withTimeout(oriel.permissions.request("camera"), 5000);
    const mic = await oriel.permissions.query("microphone");
    const settings = await oriel.permissions.openSettings("location");
    out.push({
      module: "permissions js",
      ok: cam === "denied" && camReq === "denied" && ["granted", "prompt", "unknown"].includes(mic) && typeof settings === "boolean",
      detail: `camera=${cam}/${camReq} (undeclared), microphone=${mic}`,
    });
  } catch (e) {
    out.push({ module: "permissions js", ok: false, detail: String(e) });
  }
  // The webview refuses what the app doesn't declare (camera), and passes the
  // rest on (the microphone may still be missing: NotFoundError is fine).
  const media = async (constraints) => {
    if (!navigator.mediaDevices?.getUserMedia) return "no getUserMedia";
    try {
      const stream = await withTimeout(navigator.mediaDevices.getUserMedia(constraints), 5000);
      stream.getTracks().forEach((t) => t.stop());
      return "allowed";
    } catch (e) {
      return e.name || String(e);
    }
  };
  const video = await media({ video: true });
  const audio = await media({ audio: true });
  out.push({
    module: "permissions webview",
    // Without a camera device the request can fail before it's asked
    // (OverconstrainedError/NotFoundError); it must never be allowed.
    ok: ["NotAllowedError", "OverconstrainedError", "NotFoundError"].includes(video) && audio !== "NotAllowedError" && audio !== "no getUserMedia",
    detail: `camera (undeclared): ${video}; microphone (declared): ${audio}`,
  });
  return out;
}
