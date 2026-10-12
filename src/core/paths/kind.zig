//! Which of the app's directories (internal to oriel.paths and its backends).
pub const Kind = enum {
    /// Kept until the app is removed: `appData`.
    data,
    /// The system may clear it: `appCache`.
    cache,
    /// Settings: `appConfig`.
    config,
    /// Large files the user can reach: `appExternal`.
    external,
};
