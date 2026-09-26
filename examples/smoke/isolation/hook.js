// The smoke test's isolation hook (security Phase 3): it sees every call from
// the page. It blocks one command, tags another, and passes the rest.
globalThis.__ORIEL_ISOLATION_HOOK__ = async (call) => {
  if (call.cmd === "isolation_blocked") throw new Error("blocked by the isolation hook");
  if (call.cmd === "isolation_echo") return { cmd: call.cmd, args: { ...call.args, hooked: true } };
  return call;
};
