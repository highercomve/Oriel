// The isolation hook (off until `.isolation` is uncommented in build.zig).
//
// With isolation on, every call from the frontend to Zig (window.oriel.invoke,
// the window API, openExternal, ...) comes here first. This runs in a
// sandboxed frame the page can't reach, with no network access: an XSS or a
// compromised dependency in the frontend can't skip it. Return the call to
// let it through (or a modified one), or throw to reject it. It may be async.
globalThis.__ORIEL_ISOLATION_HOOK__ = (call) => {
  // e.g. if (call.cmd === "delete_everything") throw new Error("not from the UI");
  return call;
};
