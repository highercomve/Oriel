//! The page's side of oriel.system_ai: the TypeScript types of
//! `oriel.systemAi` (src/core/ipc.zig's generated bindings) and which
//! commands are its. The page API itself is in src/core/bridge_api.js,
//! which every bridge carries; without -Dsystem_ai the commands fail and
//! `oriel.features.systemAi` is false.

const std = @import("std");

/// The bindings' types, before `declare global`.
pub const typescript =
    \\/** oriel.systemAi.status(): `reason` says why it's unavailable, or what to do next. */
    \\export interface SystemAiStatus {
    \\  state: "available" | "downloadable" | "downloading" | "unavailable";
    \\  reason: string;
    \\}
    \\
    \\export interface SystemAiCapabilities {
    \\  images: boolean;
    \\  maxImages: number;
    \\  streaming: boolean;
    \\  /** False so far: a schema goes to the model as instructions. */
    \\  structuredOutput: boolean;
    \\  /** The context window in tokens; 0 when unknown. */
    \\  maxInputTokens: number;
    \\}
    \\
    \\export interface SystemAiImage {
    \\  /** Base64, a Blob/File, an ArrayBuffer or a typed array; at most 8 MiB. */
    \\  data: string | Blob | ArrayBuffer | ArrayBufferView;
    \\  mime?: string;
    \\}
    \\
    \\export interface SystemAiRequest {
    \\  prompt: string;
    \\  system?: string;
    \\  /** Up to capabilities().maxImages (4 at most). */
    \\  images?: SystemAiImage[];
    \\  temperature?: number;
    \\  maxTokens?: number;
    \\  /** A JSON schema the reply should follow (sent as instructions). */
    \\  schema?: string | object;
    \\}
    \\
    \\/** The "system_ai:download" event. */
    \\export interface SystemAiDownloadEvent {
    \\  state: "started" | "progress" | "completed" | "failed";
    \\  downloaded: number;
    \\  /** 0 when the platform doesn't say. */
    \\  total: number;
    \\}
    \\
    \\export interface SystemAiApi {
    \\  status(): Promise<SystemAiStatus>;
    \\  capabilities(): Promise<SystemAiCapabilities>;
    \\  /** Where the platform downloads on demand (Android); resolves with the new status. */
    \\  download(onProgress?: (event: SystemAiDownloadEvent) => void): Promise<SystemAiStatus>;
    \\  /** The whole reply; `onToken` sees it piece by piece. */
    \\  generate(request: SystemAiRequest, onToken?: (text: string) => void): Promise<string>;
    \\  /** Stops the running generate or download: it rejects with "Cancelled". */
    \\  cancel(): Promise<void>;
    \\}
    \\
    \\
;

/// Commands of the page's `oriel.systemAi`.
pub fn isCommand(cmd: []const u8) bool {
    return std.mem.startsWith(u8, cmd, "system_ai:");
}

/// They block on the platform, so they run on an IPC worker; `cancel`
/// only sets a flag, so it runs at once (and never waits behind a busy
/// worker).
pub fn isAsyncCommand(cmd: []const u8) bool {
    return isCommand(cmd) and !std.mem.eql(u8, cmd, "system_ai:cancel");
}

test isAsyncCommand {
    try std.testing.expect(isAsyncCommand("system_ai:generate"));
    try std.testing.expect(!isAsyncCommand("system_ai:cancel"));
    try std.testing.expect(isCommand("system_ai:cancel"));
    try std.testing.expect(!isCommand("extensions:call"));
}
