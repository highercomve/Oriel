// Scripted UI tests, for runs nobody can tap (CI on the iOS simulator):
// `--ui-test <name>` on the command line makes the page drive its own
// controls, as a person would, and report each step to the app's log as
// "ui-test: ..." lines. "screenshot <name>" asks the runner for a
// screenshot (the test pauses a moment for it); the run ends with
// "done ok" or "FAIL <why>".
//
//   chat          the Chat tab: download Qwen2.5 0.5B, send a message, see
//                 tokens stream in, Stop, a follow-up (KV cache reuse), Compare.
//   dictate-<lang> the Dictate tab with the System engine in <lang> (en, es),
//                 on test.wav in the models directory (no microphone in CI).
//   tour          every tab (a screenshot each), IPC echo, events from a
//                 worker, a note, and a second window opened and closed:
//                 the native renderer's run (docs/native-renderer.md). The
//                 Speak tab's controls; with the voice model and a voice on
//                 the device (nothing is downloaded), a sentence read aloud.
(async () => {
  const name = await invoke("ui_test");
  if (!name) return;
  // A second window (the tour opens one): no test of its own; it closes
  // itself when asked (a window may only close itself).
  if (new URLSearchParams(location.search).has("second")) {
    listen("ui-test:close", () => window.oriel.window.current().close());
    return;
  }
  const log = (line) => invoke("ui_log", { line: String(line) });
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const shot = async (n) => { await log(`screenshot ${n}`); await sleep(8000); }; // simctl takes seconds
  async function until(ok, ms, what) {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      if (await ok()) return;
      await sleep(250);
    }
    throw new Error(`timed out waiting for ${what}`);
  }
  const check = (cond, what) => { if (!cond) throw new Error(what); };

  async function chat() {
    const model = "qwen2.5-0.5b";
    location.hash = "#chat";
    await until(() => chatState.status, 60000, "chat_status");
    $("chat-model").querySelector(`button[data-value="${model}"]`).click();
    let m = chatState.status.models.find((x) => x.name === model);
    if (!m.present) {
      await log(`downloading ${model} (${m.mb} MB)`);
      let next = 0;
      const off = listen("chat:download", (p) => {
        if (p.done_mb >= next) { log(`download ${p.done_mb} of ${p.total_mb} MB`); next = p.done_mb + 100; }
      });
      $("chat-download").click();
      const failed = () => /Download failed/.test($("chat-state").textContent);
      await until(() => chatState.status.models.find((x) => x.name === model).present || failed(), 30 * 60000, "the download");
      check(!failed(), $("chat-state").textContent);
      if (typeof off === "function") off();
    }
    await log(`model present; ${$("chat-backend").textContent.trim()}; ${$("chat-proc-note").textContent}`);

    // A long answer, to see it stream and stop it. The simulator runs on
    // the Mac's CPU, fast enough to finish a whole answer in a second or
    // two, and token events reach the page in bursts, so everything is
    // measured from the token events themselves: the bubble's length after
    // the 3rd and the 8th token, then Stop. Counting is long and never
    // refused (a 0.5B model sometimes declines a story), but it may still
    // shorten it ("1 … 200") and finish before Stop arrives: then ask again.
    let tokens = 0, len3 = 0, len8 = 0;
    const bubbleText = () => { const b = $("chat-log").querySelectorAll(".bubble"); return b[b.length - 1].querySelector("p").textContent; };
    const meta = () => { const s = $("chat-log").querySelectorAll(".bubble small"); return s.length ? s[s.length - 1].textContent : ""; };
    const offTok = listen("chat:token", () => {
      tokens += 1; // after the page's own listener, which appended the token
      if (tokens === 3) len3 = bubbleText().length;
      if (tokens === 8) { len8 = bubbleText().length; $("chat-send").click(); } // Stop while busy
    });
    for (let attempt = 1; ; attempt++) {
      // A fresh conversation each time: asked again in the same one, the
      // model copies its earlier short answers (run 49: 29, 5, then 1 token).
      if (attempt > 1) $("chat-new").click();
      tokens = 0; len3 = 0; len8 = 0;
      $("chat-input").value = "Count from 1 to 200, one number per line.";
      $("chat-form").requestSubmit();
      const t0 = Date.now();
      await until(() => tokens >= 1, 5 * 60000, "the first token");
      await log(`first token after ${Date.now() - t0} ms`);
      await until(() => !chatState.busy, 5 * 60000, "the reply to end");
      if (/stopped/.test(meta()) || attempt === 4) break;
      await log(`attempt ${attempt}: the answer ended on its own after ${tokens} tokens (${meta()}): asking again`);
    }
    await log(`streaming: the bubble had ${len3} characters after 3 tokens, ${len8} after 8; ${tokens} tokens reached the page`);
    check(len8 > len3 && len3 > 0, "the reply didn't grow while streaming");
    await log(`stopped: ${meta()}`);
    check(/stopped/.test(meta()), "the stopped reply doesn't say it was stopped");
    await shot("chat-stopped");

    // A follow-up: the conversation so far is in the KV cache.
    $("chat-input").value = "Now count from 1 to 5.";
    $("chat-form").requestSubmit();
    await until(() => chatState.busy, 10000, "the follow-up to start");
    await until(() => !chatState.busy, 10 * 60000, "the follow-up");
    await log(`follow-up: "${bubbleText().slice(0, 200)}"`);
    await log(`follow-up stats: ${meta()}`);
    check(/\d+ of \d+ prompt tokens reused/.test(meta()), "no prompt tokens reused");
    await shot("chat-followup");

    // Compare: the GPU (Metal) against the CPU.
    if ($("chat-compare").hidden) {
      await log("no GPU backend: Compare hidden");
    } else {
      const before = chatState.status.models.find((x) => x.name === model).faster;
      await log(`before Compare: auto uses ${before || "the phone default (CPU)"}`);
      $("chat-compare").click();
      await until(() => chatState.busy, 10000, "Compare to start");
      await until(() => !chatState.busy, 15 * 60000, "Compare");
      await log(`compare: ${$("chat-compare-out").textContent.replace(/\s+/g, " ").trim()}`);
      await log(`after Compare: auto uses ${chatState.status.models.find((x) => x.name === model).faster}`);
      $("chat-compare-out").scrollIntoView();
      await shot("chat-compare");
    }
    offTok && typeof offTok === "function" && offTok();
  }

  async function dictate(lang) {
    location.hash = "#dictate";
    await until(() => dict.status, 60000, "dictation_status");
    const st = dict.status;
    await log(`system: ${st.system}, on-device: ${st.system_on_device}, auto: ${st.auto_engine}`);
    check(st.system, "no system recognizer (engine field hidden)");
    $("dict-engine").querySelector('button[data-value="system"]').click();
    $("dict-lang").querySelector(`button[data-value="${lang}"]`).click();
    await sleep(500);
    let partials = 0, finals = [];
    const offP = listen("dictation:partial", (p) => { if (p.text) partials += 1; });
    const offF = listen("dictation:final", (f) => { finals.push(f.text); log(`final (${f.backend}): ${f.text}`); });
    const offE = listen("dictation:error", (e) => log(`error: ${e.message}`));
    $("dict-rec").click();
    // Listening, or a reason it can't (an error, a missing permission or language).
    await until(() => dict.recording || /Error|allowed|didn't|doesn't/.test($("dict-state").textContent), 90000, "listening");
    await log(`state: ${$("dict-state").textContent}`);
    check(dict.recording, "not listening");
    await sleep(4000);
    await shot(`dictate-${lang}-listening`);
    await sleep(8000); // test.wav is a few seconds, then silence
    $("dict-rec").click(); // stop
    await until(() => !dict.recording && !dict.busy, 30000, "stop");
    const card = $("dict-out").querySelector(".transcript p");
    const text = card ? card.textContent : "";
    await log(`transcript: ${text}`);
    await log(`partials: ${partials}, finals: ${finals.length}`);
    await shot(`dictate-${lang}-done`);
    for (const off of [offP, offF, offE]) if (typeof off === "function") off();
    check(text && text !== "Nothing heard", "nothing transcribed");
  }

  async function tour() {
    for (const tab of ["dictate", "chat", "speak", "notes", "files", "system", "app"]) {
      location.hash = "#" + tab;
      await sleep(800);
      check($(tab).classList.contains("active"), `tab ${tab} not shown`);
      await log(`tab ${tab} shown`);
      await shot(`tour-${tab}`);
    }
    await speak();
    // IPC: text to Zig and back, byte for byte.
    const text = "héllo 👋 ✓ 世界 \"q\" <b>";
    $("echo-input").value = text;
    $("echo-form").dispatchEvent(new Event("submit", { cancelable: true }));
    await until(() => /Round trip|Mismatch|Error/.test($("echo-out").textContent), 10000, "the echo");
    check($("echo-out").textContent === `✓ Round trip: ${text}`, $("echo-out").textContent);
    await log("echo ok");
    // Events from a worker thread.
    $("ticks").click();
    await until(() => /All five/.test($("tick-out").textContent), 15000, "five ticks");
    await log("ticks ok");
    await shot("tour-app-done");
    // A note in SQLite.
    location.hash = "#notes";
    await sleep(500);
    const note = `tour note ${Date.now() % 100000}`;
    $("note-input").value = note;
    $("note-form").dispatchEvent(new Event("submit", { cancelable: true }));
    await until(() => $("note-list").textContent.includes(note), 10000, "the note");
    await log("note ok");
    await shot("tour-notes-done");
    // A second window, then closed again.
    location.hash = "#app";
    await sleep(500);
    $("open").click();
    await until(() => /Opened window|Error/.test($("windows-out").textContent), 15000, "the second window");
    check(/Opened window/.test($("windows-out").textContent), $("windows-out").textContent);
    const label = `second-${$("windows-out").textContent.match(/\d+/)[0]}`;
    await log(`opened ${label}`);
    await shot("tour-second-window");
    await window.oriel.window.emitTo(label, "ui-test:close", null);
    await until(() => /Closed/.test($("windows-out").textContent), 15000, "the close");
    await log(`closed ${label}`);
  }

  // The Speak tab: its controls render; with the model and a voice present,
  // a short sentence is read and its result measured.
  async function speak() {
    location.hash = "#speak";
    await until(() => tts.status, 60000, "tts_status");
    await sleep(500);
    const st = tts.status;
    check($("tts-model").querySelectorAll("button").length === st.models.length, "the model picker is empty");
    check($("tts-voice").querySelectorAll("option").length === st.voices.length + 1, "the voice picker is incomplete");
    check($("tts-speed").querySelectorAll("button").length === 4, "no speeds");
    await log(`speak: ${$("tts-backend").textContent.trim()}; espeak data ${st.espeak_data || "missing"}; ${$("tts-state").textContent}`);
    const model = st.models.find((m) => m.present);
    const voice = st.voices.find((v) => v.present && v.lang === "en-us") || st.voices.find((v) => v.present);
    if (!model || !voice || !st.espeak_data) {
      check($("tts-speak").disabled || !st.espeak_data, "Speak enabled without a model or voice");
      await log("speak: no model or voice on the device: not speaking (the test downloads nothing)");
      return;
    }
    $("tts-model").querySelector(`button[data-value="${model.id}"]`).click();
    $("tts-voice").value = voice.id;
    $("tts-voice").dispatchEvent(new Event("change"));
    $("tts-text").value = "Oriel tour check.";
    tts.last = null;
    const phases = [];
    const off = listen("tts:state", (s) => phases.push(s.phase));
    await until(() => !$("tts-speak").disabled, 5000, "Speak to be enabled");
    $("tts-speak").click();
    await until(() => tts.busy, 5000, "speaking to start");
    await until(() => !tts.busy, 120000, "the utterance to end");
    if (typeof off === "function") off();
    const r = tts.last;
    check(r, `no result: ${$("tts-state").textContent}`);
    await log(`speak: ${r.voice} (${r.lang}) on ${r.backend}: first audio ${r.first_audio_ms} ms, load ${r.load_ms} ms, ${r.chunks} chunks, ${r.audio_s.toFixed(1)} s in ${r.synth_ms} ms, gaps ${r.gap_ms} ms; phases ${phases.join(",")}`);
    check(r.first_audio_ms > 0 && !r.stopped, "no audio");
    check(phases.includes("playing") && phases[phases.length - 1] === "idle", "tts:state didn't go through playing to idle");
    check($("tts-out").querySelector(".spoken"), "no result card");
    await shot("tour-speak-done");
  }

  try {
    await log(`start ${name}`);
    if (name === "chat") await chat();
    else if (name === "tour") await tour();
    else if (name.startsWith("dictate-")) await dictate(name.slice("dictate-".length));
    else throw new Error(`unknown test ${name}`);
    await log("done ok");
  } catch (e) {
    await log(`FAIL ${e.message || e}`);
    await shot("fail");
  }
})();
