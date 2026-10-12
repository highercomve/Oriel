//! The page's side of oriel.system_ai: `oriel.systemAi` in every bridge
//! (one source, spliced into each platform's bridge script), its
//! TypeScript types (src/core/ipc.zig's generated bindings), and which
//! commands are its. Pure: no build options, so the bridges always carry
//! it; without -Dsystem_ai the commands fail and `oriel.features.systemAi`
//! is false.

const std = @import("std");

/// A property of the bridges' `window.oriel` object literal (after
/// `extensions`), indented like its siblings.
pub const js =
    \\    // The device's own model (oriel.system_ai): Gemini Nano on Android,
    \\    // Foundation Models on iOS 26+. Tokens stream as "system_ai:token"
    \\    // ({ text }), download progress as "system_ai:download".
    \\    systemAi: Object.freeze({
    \\      status() {
    \\        return invoke("system_ai:status", {});
    \\      },
    \\      capabilities() {
    \\        return invoke("system_ai:capabilities", {});
    \\      },
    \\      download(onProgress) {
    \\        const off = onProgress ? window.oriel.listen("system_ai:download", onProgress) : null;
    \\        return Promise.resolve(invoke("system_ai:download", {})).finally(() => off && off());
    \\      },
    \\      async generate(request, onToken) {
    \\        const b64 = async (data) => {
    \\          if (typeof data === "string") return data;
    \\          const bytes = data instanceof Blob ? new Uint8Array(await data.arrayBuffer()) : data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    \\          let bin = "";
    \\          for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    \\          return btoa(bin);
    \\        };
    \\        const images = [];
    \\        for (const img of request.images || []) images.push({ data: await b64(img.data), mime: img.mime || (img.data && img.data.type) || "image/jpeg" });
    \\        const schema = request.schema == null || typeof request.schema === "string" ? request.schema : JSON.stringify(request.schema);
    \\        const off = onToken ? window.oriel.listen("system_ai:token", (e) => onToken(e.text)) : null;
    \\        try {
    \\          return await invoke("system_ai:generate", { system: request.system || "", prompt: request.prompt, images, temperature: request.temperature, maxTokens: request.maxTokens, schema });
    \\        } finally {
    \\          if (off) off();
    \\        }
    \\      },
    \\      cancel() {
    \\        return invoke("system_ai:cancel", {});
    \\      },
    \\    }),
    \\
;

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
    \\  /** Stops the running generate or download: it rejects with "cancelled". */
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
