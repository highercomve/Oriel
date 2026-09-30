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
(async () => {
  const name = await invoke("ui_test");
  if (!name) return;
  const log = (line) => invoke("ui_log", { line: String(line) });
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const shot = async (n) => { await log(`screenshot ${n}`); await sleep(3000); };
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
      await until(() => chatState.status.models.find((x) => x.name === model).present, 30 * 60000, "the download");
      if (typeof off === "function") off();
    }
    await log(`model present; ${$("chat-backend").textContent.trim()}; ${$("chat-proc-note").textContent}`);

    // A long answer, to see it stream and stop it.
    let tokens = 0;
    const offTok = listen("chat:token", () => { tokens += 1; });
    $("chat-input").value = "Write a long story about a lighthouse keeper and a storm.";
    $("chat-form").requestSubmit();
    const t0 = Date.now();
    await until(() => tokens >= 1, 5 * 60000, "the first token");
    await log(`first token after ${Date.now() - t0} ms`);
    await until(() => tokens >= 20, 5 * 60000, "20 tokens");
    const bubbleText = () => { const b = $("chat-log").querySelectorAll(".bubble"); return b[b.length - 1].querySelector("p").textContent; };
    const len1 = bubbleText().length;
    await sleep(1500);
    const len2 = bubbleText().length;
    await log(`streaming: ${tokens} tokens so far; the bubble grew from ${len1} to ${len2} characters`);
    check(len2 > len1, "the reply didn't grow while streaming");
    await shot("chat-streaming");
    $("chat-send").click(); // Stop while busy
    await until(() => !chatState.busy, 60000, "Stop");
    const meta = () => { const s = $("chat-log").querySelectorAll(".bubble small"); return s.length ? s[s.length - 1].textContent : ""; };
    await log(`stopped: ${meta()}`);
    check(/stopped/.test(meta()), "the stopped reply doesn't say it was stopped");

    // A follow-up: the conversation so far is in the KV cache.
    $("chat-input").value = "Now tell the same story in one sentence.";
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
    await until(() => dict.recording || /Error|allowed/.test($("dict-state").textContent), 90000, "listening");
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

  try {
    await log(`start ${name}`);
    if (name === "chat") await chat();
    else if (name.startsWith("dictate-")) await dictate(name.slice("dictate-".length));
    else throw new Error(`unknown test ${name}`);
    await log("done ok");
  } catch (e) {
    await log(`FAIL ${e.message || e}`);
    await shot("fail");
  }
})();
