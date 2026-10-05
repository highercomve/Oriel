# Application updates

[Back to Oriel](../README.md) · [Documentation](README.md)

## Updater (`oriel.updater`)

Built-in self-updater featuring Ed25519 signature verification, atomic file replacement, throttled download progress streaming, and in-place restart.

### 1. Key generation

Generate a new Ed25519 keypair using the app build step registered by `oriel.addApp` (run inside your app project):

```sh
zig build keygen -- --name myapp --out-dir ~/.config/myapp/keys
```

- Private key written to `$XDG_CONFIG_HOME/oriel/keys/<name>.key` (default) with file mode `0600` (refuses to overwrite existing files without `--force`).
- Public key written to `<name>.pub` (standard base64) and printed to stdout.

### 2. Signing release artifacts

Sign an update artifact (raw binary, AppImage, or `.gz` archive) and produce a manifest JSON using the app build step (run inside your app project):

```sh
zig build sign-update -- zig-out/bin/my-app \
  --app-id com.example.App \
  --version 1.2.0 \
  --url https://releases.example.com/my-app-1.2.0 \
  --key ~/.config/myapp/keys/myapp.key \
  --out manifest.json
```

**Signed manifest format (`oriel-update-v2`):**
```json
{
  "app_id": "com.example.App",
  "version": "1.2.0",
  "target": "x86_64-linux",
  "format": "raw",
  "size": 1048576,
  "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "url": "https://releases.example.com/my-app-1.2.0",
  "signature": "base64-encoded-ed25519-signature"
}
```

The signature is computed over domain-separated canonical bytes:
`"oriel-update-v2\n" ++ app_id ++ "\n" ++ version ++ "\n" ++ target ++ "\n" ++ format ++ "\n" ++ size ++ "\n" ++ sha256 ++ "\n" ++ url ++ "\n"` (plus optional `expires\n`).

One file for every platform (like Tauri's `latest.json`): sign each platform's artifact with its `--target`, then combine the manifests:

```sh
zig build combine-manifests -- manifest-*.json --out latest.json
```

`latest.json` has a `platforms` map (`"x86_64-linux"`, `"aarch64-macos"`, `"x86_64-windows"`, ...), each entry a complete signed manifest. Publish it at one stable URL (e.g. `https://github.com/you/app/releases/latest/download/latest.json`) and use that as `manifest_url` in every build: each app picks and verifies the entry for its own target, and an entry filed under the wrong platform is refused. A single-platform manifest still works as `manifest_url`.

### 3. Embedding public key in the app

Configure `update_public_key` in `build.zig`:

```zig
_ = oriel.addApp(b, dep, .{
    .name = "my-app",
    .root_source_file = b.path("src/main.zig"),
    .frontend = .{ .dir = "frontend" },
    .update_public_key = "base64-public-key-string",
});
```

The public key is exposed at compile time via `@import("oriel_app").update_public_key`.

### 4. JS IPC and runtime API

In `src/main.zig`, register the comptime-configured updater commands:

```zig
const app = @import("oriel_app");

const Updater = oriel.updater.Commands(.{
    .app_id = "com.example.App",
    .manifest_url = "https://releases.example.com/latest.json",
    .current_version = "1.0.0",
    .public_key_b64 = app.update_public_key orelse @panic("missing update key"),
});

pub const Commands = struct {
    pub const updater_check = Updater.updater_check;
    pub const updater_install = Updater.updater_install;
    pub const updater_restart = Updater.updater_restart;

    pub const async_commands = .{ "updater_check", "updater_install", "updater_restart" };
};
```

For typed `listen` in the generated TypeScript, declare the progress event in your `Events` struct:
`@"updater://progress": struct { downloaded: u64, total: ?u64 }`.

From frontend TypeScript / JavaScript:

```ts
import { invoke, listen } from "./oriel";

// 1. Check for update
const update = await invoke("updater_check");
if (update?.available) {
    console.log(`Update ${update.version} available!`);

    // Listen to download progress events (throttled to ~10/s)
    const unlisten = listen("updater://progress", ({ downloaded, total }) => {
        console.log(`Downloaded ${downloaded} of ${total} bytes`);
    });

    // 2. Download and atomically install update
    await invoke("updater_install");
    unlisten();

    // 3. Restart running application
    await invoke("updater_restart");
}
```

### 5. AppImage behavior

When running inside an AppImage (`$APPIMAGE` environment variable is set), `oriel.updater` automatically targets the outer AppImage executable for replacement and re-exec, keeping desktop launcher integrations seamless.

### 6. Windows behavior

On Windows, running executables cannot be directly overwritten. `oriel.updater` downloads and verifies payloads next to the executable as `<exe>.new`, renames the running binary to `<exe>.old` using `MoveFileExW` (`MOVEFILE_REPLACE_EXISTING`), and promotes `<exe>.new` to `<exe>` (with automatic rollback on failure). Stale `.old` files are cleaned up on subsequent startup (`updater.init`). Application restart is performed via `CreateProcessW` using the original command line (`GetCommandLineW`). Runtime untested on Windows.

### 7. macOS behavior

A plain executable is replaced like on Linux (`raw` / `raw.gz`). An app in a
`.app` bundle is updated as a whole with the format `app.tar.gz` (a gzip'd tar
of one `<Name>.app`; build it with `COPYFILE_DISABLE=1 tar -czf ... Name.app`):
it is unpacked next to the running bundle, swapped with it atomically
(`renameatx_np` `RENAME_SWAP`) and the old bundle is deleted; `restart`
relaunches the bundle with `open -n`. Other OSes refuse `app.tar.gz`. For
distribution, tar the signed and notarized `zig-out/package/<Name>.app` (see
[macOS bundles](packaging.md#macos-bundles-app-dmg)), not `oriel build`'s ad-hoc
`zig-out/<Name>.app`.

### 8. Security notes

- **JS cannot choose URLs, keys, or paths**: The manifest URL, public key, and target path are configured strictly in native Zig code; frontend code cannot redirect downloads or bypass signature verification.
- **Private keys**: Never commit private keys to version control or bundle them into client applications. Use `keygen` with secure out-of-repo storage (`mode 0600`).
- **Transport**: Production manifest and payload URLs should always use HTTPS.
