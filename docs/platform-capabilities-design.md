# Oriel platform capabilities: design

*Architect, 2026-10-04, branch release-0.9.1. Motivated by GhostShare (ghostfile, branch dark-mode-and-android-discovery).*

The guiding rule: **declare intent once in `build.zig`, call one runtime API.** The build turns the
declaration into each platform's manifest, plist, entitlements or desktop entry, and the runtime maps
calls to each OS. Capability differences are **queryable**: a field a platform can't honour is
reported by `capabilities()` and returned as an error. It is never dropped silently.

## 0. What exists, and cross-cutting decisions

Patterns this design builds on:
- `AppOptions.permissions: Permissions` (build.zig:879) = `permissions/common.zig` `Declared`, one
  `?[]const u8` reason per `Kind`. `effectivePermissions` (build.zig ~945) adds what modules need
  (audio_capture → microphone). `addPermissionOptions` passes them to the app as `permission_<kind>`.
- Android: `androidProjectVars` (build.zig:1433) fills `@@permissions@@`, `@@url_schemes@@` and
  `@@android_components@@` in `android/template/app/src/main/AndroidManifest.xml`. iOS: `ios-app
  --permission kind=reason` (tools/package/ios.zig). macOS: `usageKeys` and `generateEntitlements`
  (tools/package/macos.zig:36-75). Oriel doesn't sandbox macOS apps (sign_macos.zig:84).
- Runtime: `core/permissions.zig` (`status`, `request`, `openSettings`; the `permission-changed`
  event) plus `permissions/<os>.zig`. On Android the Kind ordinal is passed to `OrielPermissions.kt`
  (`permission(kind)` returns one string; `onResult` hard-codes `kind !in 0..6`).
- Modules: `src/modules/<m>.zig` facade + `<m>/{common,linux,windows,macos,android,ios}.zig`, with
  `apple.zig` shared where useful (audio_capture). Each module is enabled by `Features` (build.zig:30-100,
  `-D<name>`), exposed as `oriel.<m> = if (options.<m>) ... else struct {}`, and has a `check()`.
- Events: `App.emit`. Cold start: `notification/common.zig` `Pending` + `pageReady()` (the
  `notification:ready` builtin in `ipc.zig:293-336`, sent by the bridges' `listen()`), and `deep_link:ready`.
- The JS API is duplicated in **5 places**: linux/bridge.zig, windows/bridge_script.zig (Android reuses
  it), macos/bridge.zig, ios/bridge.zig, native_ui/js/src/main.js.
- Received-file capability: `native_ui/drop.zig` (a read-only descriptor table, u32 handles, snapshot
  checks). App-scheme handlers per platform (e.g. linux/scheme.zig `serveAsset`, already routing `/media/`).

GhostShare workarounds this design replaces: `tools/android_manifest.zig` patches
`CHANGE_WIFI_MULTICAST_STATE` into the manifest, because `android-project` never rewrites an existing
manifest. `src/android_multicast.zig` takes a MulticastLock over raw JNI through
`ActivityThread.currentApplication()`.

### ADR-0.1 One declaration form: `.permissions = .{ .<capability> = "reason" }`
(Matches the coordinator's decision for `bluetooth`.) `Kind` gets **appended** `bluetooth` and
`local_network`. They must be appended because the Kotlin ordinals must stay stable. Each is a
`?[]const u8` reason like the existing kinds, so `addPermissionOptions`, the inline loops,
`--permission` args and `defaultReason` keep working. **Declaring the kind is the whole contract.**
It expands to everything the platform needs for the module's full API, with safe defaults:
- `bluetooth`: all roles. On Android, SCAN, ADVERTISE and CONNECT share the single "Nearby devices"
  prompt; SCAN carries `neverForLocation`.
- `local_network`: multicast on Android, where it is a normal permission.

Only details that *cannot* be defaulted go in an optional refinement keyed by the same names,
`AppOptions.permission_options` (`.local_network = .{ .bonjour_services, .multicast_entitlement, .inbound }`,
`.bluetooth = .{ .scan_derives_location, .background }`). Raw platform strings stay in the
per-platform escape hatch (ADR-0.2). Modules that need a kind add it with the default reason
(`effectivePermissions`, as audio_capture does): `-Dbluetooth` implies `.bluetooth = ""`.

### ADR-0.2 Escape hatch per platform, structured and not string-spliced
Anything unmapped goes through typed per-platform lists, merged after the generated entries
(de-duplicated by name/key; an override of a generated key logs a build warning):
```zig
.android = .{ .tile = ..., .manifest = .{
    .permissions = &.{ .{ .name = "android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" },
                       .{ .name = "android.permission.BLUETOOTH", .max_sdk = 30 } },
    .remove_permissions = &.{"android.permission.BLUETOOTH_CONNECT"}, // trim a kind's defaults
    .features = &.{ .{ .name = "android.hardware.bluetooth_le", .required = false } },
    .queries_xml = "", .application_xml = "", .main_activity_xml = "",   // raw, last resort
} },
.ios   = .{ .info_plist = &.{ .{ .key = "UIFileSharingEnabled", .value = .{ .boolean = true } } },
            .entitlements = &.{ .{ .key = "com.apple.developer.networking.wifi-info", .value = .{ .boolean = true } } } },
.macos = .{ .info_plist = ..., .entitlements = ..., .sandbox = false },
.windows = .{ .registry = ... },   // reserved; MSIX capabilities only once an MSIX format exists
.linux = .{ .desktop_keys = &.{ .{ .key = "X-GNOME-UsesNotifications", .value = "true" } } },
```
`PlistValue = union(enum) { string, boolean, integer, strings: []const []const u8, raw_xml }`.
This is shared by `tools/package/{ios,macos}.zig`, passed as `--plist key=json` args.

### ADR-0.3 (blocking) The Android manifest must be regenerated on every build
Today any new declaration never reaches an existing `android/` project, which is why GhostShare
needed its patch tool. The template gets marked regions, `<!-- oriel:permissions begin/end -->`,
`<!-- oriel:main-activity begin/end -->` and `<!-- oriel:components begin/end -->`. The
`--runtime-only` sync (run on every install, build.zig:1401) rewrites **only those regions** and
leaves the user's edits elsewhere alone. A manifest without markers produces a build error naming
`-Dandroid_force`.

### ADR-0.4 One JS API source
Extract the `window.oriel` sub-APIs (`permissions`, `deepLink`, plus the new `share`, `network`,
`bluetooth`, `system`) into `src/core/bridge_api.zig` as a JS fragment, like `theme_color_js`.
The four bridges splice it in, and `native_ui/js/src/main.js` imports a generated copy. Without
this, every feature edits five files.

### ADR-0.5 Generic queued events
Generalize notification's `Pending`/`pageReady` into `src/core/pending_events.zig`, a bounded
per-event FIFO (`capacity`), delivered once a Zig handler is set and once the page listens. A
generic builtin `events:ready {event}` replaces the per-event commands; the old commands stay as
aliases. `listen()` calls it for events in a frozen set: `notification:action`, `share:received`
and `deep-link`.

### ADR-0.6 Module flags
| Module | Flag | Default | Why |
|---|---|---|---|
| `network` | `-Dnetwork` | on | Small, and it links nothing new (Network.framework is in libSystem on Apple) |
| `bluetooth` | `-Dbluetooth` | **off**, like deep_link | It links CoreBluetooth and WinRT, and its plist key is mandatory once it's used |
| `share` | `-Dshare` | on | Receiving is inert until `.share_target` is declared |
| `system` | core (`oriel.system`) | always | No permissions; a few syscalls per OS |

Enabling `bluetooth` implies `permissions.bluetooth` (`effectivePermissions`).

---

## 1. Capabilities and permissions: `local_network`, `bluetooth`

### API
```zig
// build.zig: this is all most apps write
.permissions = .{ .local_network = "Find nearby devices", .bluetooth = "Wake nearby phones" },
// optional refinements, only what can't be defaulted
.permission_options = .{
    .local_network = .{
        .bonjour_services = &.{"_FC9F5ED42C8A._tcp"}, // iOS/macOS NSBonjourServices (no default possible)
        .multicast_entitlement = false, // iOS com.apple.developer.networking.multicast: Apple-approved, so opt-in
        .inbound = true,                // listens on the LAN: Windows firewall rule, macOS sandbox server
    },
    .bluetooth = .{ .scan_derives_location = false, .background = false },
},
```
Runtime: no new functions. `oriel.permissions.status/request(.local_network | .bluetooth)` and
`window.oriel.permissions.request("bluetooth")` work as for the existing kinds. `ipc.zig` already
parses kinds by name.

### Build mapping
| | local_network | bluetooth |
|---|---|---|
| Android (`androidProjectVars` → new pure `build/android_manifest.zig`) | ACCESS_NETWORK_STATE, ACCESS_WIFI_STATE, CHANGE_WIFI_MULTICAST_STATE (all normal permissions, no prompt); INTERNET is already there. NEARBY_WIFI_DEVICES **not** by default: it's for Wi-Fi Direct/Aware, not mDNS (escape hatch). Android 17's ACCESS_LOCAL_NETWORK when targetSdk ≥ 37 (verify, see Q4) | BLUETOOTH_SCAN (`usesPermissionFlags="neverForLocation"` unless `scan_derives_location`), BLUETOOTH_ADVERTISE and BLUETOOTH_CONNECT: one group prompt; legacy BLUETOOTH + BLUETOOTH_ADMIN `maxSdkVersion="30"`; ACCESS_FINE_LOCATION `maxSdkVersion="30"` for scanning on ≤30; `<uses-feature android.hardware.bluetooth_le required="false">`. An app that wants fewer roles drops them via the escape hatch (`.android.manifest.remove_permissions`) |
| iOS (`tools/package/ios.zig`) | NSLocalNetworkUsageDescription; NSBonjourServices; entitlement `com.apple.developer.networking.multicast` only if `multicast_entitlement` (Apple-approved, see Q2) | NSBluetoothAlwaysUsageDescription; UIBackgroundModes `bluetooth-central`/`bluetooth-peripheral` if `background` |
| macOS (`tools/package/macos.zig`) | NSLocalNetworkUsageDescription (the macOS 15 local network privacy prompt); with `.macos.sandbox`: `com.apple.security.network.client`, plus `.server` if `inbound` | NSBluetoothAlwaysUsageDescription; with sandbox: `com.apple.security.device.bluetooth` |
| Windows (nsis.zig) | Unpackaged: nothing, except that `inbound` adds a firewall rule for the exe (private profile) in the per-machine install; per-user installs get the Defender dialog on first bind. MSIX `privateNetworkClientServer` later | Nothing for Win32; MSIX `<DeviceCapability Name="bluetooth"/>` later |
| Linux | Nothing | Nothing (BlueZ over D-Bus); Flatpak would need `--system-talk-name=org.bluez` (note in docs) |

### Runtime prompts and statuses
| | local_network | bluetooth |
|---|---|---|
| Android | `granted` (normal permissions), unless ACCESS_LOCAL_NETWORK exists on this API level, which is a runtime prompt | Runtime prompt on 31+ (the "Nearby devices" group, one request for all declared roles); ≤30 scan → location prompt. `OrielPermissions.permission()` becomes `permissions(kind): Array<String>` per SDK; fix `onResult`'s `0..6` |
| iOS | No query API. `unknown` until asked; `request` browses the first `bonjour_services` type with `nw_browser` (Network.framework C API) and publishes the same type with `nw_listener`: if the browser sees the app's own service → `granted`; `kDNSServiceErr_PolicyDenied` (-65570) → `denied`. The result is cached in NSUserDefaults. Without Bonjour types, `request` returns `unknown` (heuristic, Q3) | `CBManager.authorization` (class property): notDetermined → `prompt`; `request` creates a CBCentralManager (ShowPowerAlert=NO) and resolves on `centralManagerDidUpdateState:` |
| macOS | Same as iOS on 15+; `granted` before 15 | Same as iOS (TCC since macOS 11) |
| Windows | `granted` | `granted` (availability is in `bluetooth.capabilities()`, not in the permission) |
| Linux | `granted` | `granted` |

Rule: a **permission** says whether the user allows it; **availability** (adapter present, powered,
peripheral role supported) belongs to the module's `capabilities()`.

### Phases
- **1a (shared):** `Kind`/`Declared`/`defaultReason`, `permission_options` and escape-hatch structs, the merge
  in `effectivePermissions`, Android regions (ADR-0.3), and the pure generator `build/android_manifest.zig` with tests.
- **1b (in parallel):** Android statuses and request in `OrielPermissions.kt`; Apple plist and entitlement
  keys plus the CBManager status/request (`permissions/{ios,macos}.zig`); the local-network probe (Apple);
  the NSIS firewall rule (Windows).
- GhostShare deletes `tools/android_manifest.zig` after 1a.

### Tests
- `build/android_manifest.zig`: golden tests for each combination (kinds × `permission_options` × `remove_permissions` ×
  escape hatch overriding or duplicating), checking `maxSdkVersion` and the flags, plus a region-rewrite
  test (markers kept, user content outside them kept, a missing marker gives an error).
- macos.zig/ios.zig: NSBonjourServices array, usage keys, entitlements by sandbox flag, plist escape-hatch override.
- `permissions.zig`: the unknown-kind and undeclared-kind tests extended to the new kinds.

---

## 2. Network: multicast lock and LAN info

### API
```zig
// oriel.network
pub const MulticastLock = struct { id: u32, pub fn release(self: MulticastLock) void };
pub fn acquireMulticast() error{ NotDeclared, Failed }!MulticastLock; // ref-counted, any thread
pub const Transport = enum { wifi, ethernet, cellular, vpn, other, none };
pub const Info = struct { connected: bool, transport: Transport, metered: bool,
                          addresses: []const std.Io.net.IpAddress }; // LAN-scope only
pub fn info(gpa: Allocator) !Info;
pub fn onChange(handler: ?*const fn (Info) void) void; // and the "network:changed" event
```
```js
const lock = await oriel.network.multicast(); // released by lock.release(), and by the window closing or reloading
await oriel.network.info(); oriel.listen("network:changed", cb);
```
`NotDeclared` means `.permissions.local_network` is unset: the build option is checked at
runtime, so the app fails loudly instead of hitting a SecurityException inside the JVM. The JS locks
are tracked per window label (in `network/common.zig`) so a reload can't leak them.

### Mapping
| | multicast | info / changes |
|---|---|---|
| Android | New `OrielNetwork.kt`: one `WifiManager.createMulticastLock("oriel")`, `setReferenceCounted(false)`; Zig keeps the count and calls `OrielRuntime.multicast(on)` on 0↔1 through `runtime.call` (`runOnMainThread`, as permissions/android.zig does). It uses `OrielRuntime.app`, with no ActivityThread | `ConnectivityManager.getNetworkCapabilities(activeNetwork)` + `LinkProperties.linkAddresses`; `registerDefaultNetworkCallback` → `NativeLib.onSystemEvent("network")` |
| iOS / macOS (`network/apple.zig`) | No-op success; the entitlement (iOS) and the prompt are the real gates | `nw_path_monitor` (interface type, `nw_path_is_expensive`) + `getifaddrs` |
| Windows | No-op | `GetAdaptersAddresses` (IfType 71 = Wi-Fi) + `NotifyIpInterfaceChange` |
| Linux | No-op | `GNetworkMonitor` (`network-changed`, `network-metered`) + `getifaddrs`; Wi-Fi = `/sys/class/net/<if>/wireless` exists |

No SSID: that needs location permission on Android and an entitlement on iOS. It goes through the
escape hatch if anyone ever asks for it.

### Phases
1. Android multicast lock with the other platforms as no-ops. This replaces GhostShare's
   `src/android_multicast.zig`. Very small.
2. `info()` and `onChange`, one platform per session (each is ~100-200 lines).

### Tests
Ref-count unit tests in `common.zig` (acquire ×2 / release ×1 keeps the lock; window close releases)
with a fake backend; `check()` prints `info()`; a manual ChromeOS run (Q5).

---

## 3. Bluetooth LE: advertising and scanning

### API (`oriel.bluetooth`, `-Dbluetooth`): the decided API, plus additive extensions
The Android session is implementing this now; other platforms must conform to it:
```zig
pub const Advertisement = struct {
    service_uuids16: []const u16 = &.{},
    service_data: ?struct { uuid16: u16, data: []const u8 } = null,
    local_name: bool = false,          // include the system's device/adapter name
    connectable: bool = false,
    mode: enum { low_latency, balanced, low_power } = .balanced,
    tx_power: enum { high, medium, low, ultra_low } = .medium,
};
pub const Capabilities = struct { advertise: bool, service_data: bool, local_name: bool, connectable: bool };
pub fn capabilities() Capabilities;
pub fn advertise(ad: Advertisement) error{ Unsupported, PermissionDenied, AdapterOff, TooLarge, Failed }!Handle;
pub fn stop(h: Handle) void;
```
Semantics every backend must honour:
- A field the platform can't send returns **`error.Unsupported`** and is never dropped:
  `service_data != null` with `!caps.service_data`, `local_name` with `!caps.local_name`, and
  `connectable != <what the platform does>` (below).
- **`TooLarge`** comes from a shared pure function `bluetooth/common.zig`
  `encodedSize(os, ad) u8`, checked against 31 bytes (legacy). It counts the AD structures and
  whether this stack adds Flags (3 bytes). Quick Share's beacon is 0xFE2C + 24 bytes = 28 bytes, so
  it fits only without Flags. Android omits Flags when non-connectable; BlueZ adds them only for
  Type "peripheral". Backends may also map the stack's own size error to TooLarge.
- **Asynchronous start failures.** Android `onStartFailure`, BlueZ's async `RegisterAdvertisement`
  reply, Apple `peripheralManagerDidStartAdvertising:error:` and Windows `StatusChanged=Aborted`
  all arrive after `advertise` returned a Handle. Recommended additive extension: a
  `bluetooth:advertise` event (Zig: `onState(handler)`) with `{ handle, state: "started"|"failed"|"stopped", error }`.
  Otherwise a failed beacon is invisible.

**Additive `Capabilities` fields** (non-breaking, defaults false), needed for honesty on other platforms:
`non_connectable: bool` (Apple can't do it, see below), `extended: bool`, `max_bytes: u8`,
`scan: bool`, `scan_service_data: bool`, `powered: bool` (distinguishes AdapterOff up front).

**Apple restriction (explicit):** `CBPeripheralManager.startAdvertising` accepts only
`CBAdvertisementDataLocalNameKey` and `CBAdvertisementDataServiceUUIDsKey`. **Service data and
manufacturer data cannot be advertised on iOS or macOS, and non-connectable advertising can't be
requested.** In the background, iOS also drops the local name and moves UUIDs to an overflow area
that only iOS scanners see. Apple reports `{ advertise: true, service_data: false, local_name: true,
connectable: true, non_connectable: false }`. Recommended rule for `connectable = false` (the
default) on Apple: **best-effort, not Unsupported.** Apple publishes no GATT services, so a central
that connects finds nothing, and `non_connectable: false` says so. Failing instead would make every
default call fail on Apple (Q10). `connectable = true` is fine on Apple and Linux, and Unsupported on Windows.
Consequence: **Quick Share's 0xFE2C wake-up beacon (blea.rs) cannot be sent from GhostShare on
macOS or iOS**; GhostShare should check `capabilities().service_data` and hide that feature.
Scanning *does* receive `kCBAdvDataServiceData` on Apple, so detecting nearby senders works everywhere.

### Scanning (phase 3; same style as the decided API)
```zig
pub const ScanResult = struct { id: []const u8, rssi: i16, local_name: ?[]const u8,
    service_uuids16: []const u16, service_data: []const struct { uuid16: u16, data: []const u8 } };
pub fn scan(filter: struct { service_uuids16: []const u16 = &.{} },
            on_result: *const fn (*const ScanResult) void) error{ Unsupported, PermissionDenied, AdapterOff, Failed }!ScanHandle;
pub fn stopScan(h: ScanHandle) void;
```
JS: `const s = await oriel.bluetooth.scan({ services: [0xFE2C] }, cb); s.stop();` with the event
`bluetooth:scan`. common.zig throttles results to one per (id, payload) per second, and debounces
start/stop (Android fails silently after 5 starts in 30 s). `id` is opaque: a MAC on Android, Linux
and Windows; the CBPeripheral UUID on Apple. Only 16-bit UUIDs, matching the advertising API;
128-bit is a later additive field.

JS mirror for advertising: `oriel.bluetooth.capabilities()`,
`oriel.bluetooth.advertise({ serviceUuids16, serviceData: { uuid16, data: Uint8Array }, ... })`
→ `{ id }` (rejects with the error name), `oriel.bluetooth.stop(id)`.

### Mapping
| | Advertise | Capabilities | Scan |
|---|---|---|---|
| Android (in progress) | `BluetoothLeAdvertiser.startAdvertising(AdvertiseSettings, AdvertiseData{addServiceData(ParcelUuid(0000xxxx-0000-1000-8000-00805f9b34fb)), setIncludeDeviceName(local_name)})` | `isMultipleAdvertisementSupported` → advertise; service_data/local_name/connectable/non_connectable all true; `isLeExtendedAdvertisingSupported` | `BluetoothLeScanner.startScan` with ScanFilter.setServiceUuid; a filter is required for screen-off results |
| Linux: `bluetooth/linux.zig`, GIO **system** bus (tray/global_shortcut already use GIO D-Bus) | Export `/dev/oriel/adv<N>` implementing `org.bluez.LEAdvertisement1` (`g_dbus_connection_register_object` + introspection XML; Type `broadcast` if !connectable else `peripheral`; ServiceUUIDs; ServiceData `a{sv}` keyed by the full UUID string; `Includes: ["local-name"]` when local_name; method Release) → `LEAdvertisingManager1.RegisterAdvertisement(path, {})`, and Unregister on `stop`. The adapter is found via ObjectManager. Don't power it on (rquickshare's `set_powered(true)` is an app decision) | advertise = an adapter exposes LEAdvertisingManager1 and `SupportedInstances > 0`; `SupportedIncludes` has "local-name"; `SupportedCapabilities.MaxAdvLen`; all fields true; `Powered` | `Adapter1.SetDiscoveryFilter({UUIDs, Transport:"le", DuplicateData:true})` + `StartDiscovery`; `InterfacesAdded` + `PropertiesChanged` on `Device1` (ServiceData, RSSI) |
| Windows: `bluetooth/windows.zig` + new `platform/windows/winrt.zig` | `BluetoothLEAdvertisementPublisher`; service data as `BluetoothLEAdvertisementDataSection(0x16, [lo, hi, data…])`; UUIDs as section 0x03; buffers from `CryptographicBuffer.CreateFromByteArray`; `StatusChanged` → event | `BluetoothAdapter.GetDefaultAsync`: `IsPeripheralRoleSupported` → advertise, `IsExtendedAdvertisingSupported`, `MaxAdvertisementDataLength`. **local_name false** (the publisher rejects LocalName); connectable: legacy publisher adverts are non-connectable, so `connectable` is false and `non_connectable` true; verify `IsAnonymous`/`UseExtendedAdvertisement` on 2004+ in the PoC | `BluetoothLEAdvertisementWatcher` + `Received`; `IBufferByteAccess` to read sections |
| iOS / macOS: `bluetooth/apple.zig` (objc via `apple.defineSubclass`; delegates on a private dispatch queue) | `CBPeripheralManager startAdvertising:@{ServiceUUIDs: [CBUUID 16-bit], LocalName: device name}`; service_data → Unsupported | As above; `CBManager.state` for powered and AdapterOff; `CBManager.authorization` for PermissionDenied | `CBCentralManager scanForPeripheralsWithServices:options:{AllowDuplicates}`; `didDiscoverPeripheral:advertisementData:RSSI:` |

**WinRT cost.** Oriel has no WinRT today, and Zig has no projection. `winrt.zig` must provide:
HSTRING (`WindowsCreateStringReference`), `RoGetActivationFactory`/`RoActivateInstance` (combase),
the IInspectable vtable, ~10 hand-declared interfaces, Zig-implemented COM delegates
(`TypedEventHandler`, `AsyncOperationCompletedHandler`) and **parameterized IIDs**. Those are SHA-1
of a type signature: generate them with a tested function, not copied GUIDs. Estimate: ~400 lines
for winrt.zig and ~400 for the publisher, ~250 for the watcher. Share-out (§5) reuses winrt.zig.

### Phases
1. Android advertise (in progress), with `encodedSize` and the per-OS field table in common.zig
   (shared session) so every backend uses the same TooLarge/Unsupported rules.
2. In parallel: Linux BlueZ advertise; Apple advertise (UUIDs + name) with the CBManager permission path; the `bluetooth:advertise` state event.
3. Scan on Android, Linux and Apple, in parallel.
4. Windows: winrt.zig, then the publisher, then the watcher.

### Tests
`encodedSize` and the Unsupported table, golden-tested for every OS from Linux (the FE2C beacon:
Android/Linux OK at 28 bytes; Apple service_data Unsupported; Windows local_name Unsupported).
LEAdvertisement1 property marshalling against a **mock BlueZ** on a private bus (`GTestDBus` + a
tiny service implementing `RegisterAdvertisement` that reads the object's properties back). The
throttle and debounce logic with a fake clock. `check()` prints `capabilities()`. Hardware: an
Android phone advertising with a Quick Share phone nearby; a Linux laptop; a Windows 11 box; a Mac (scan).

## 4. System information: `oriel.system`

### API
```zig
pub fn deviceName(gpa: Allocator) ![]u8;
pub const FormFactor = enum { phone, tablet, laptop, desktop, tv, unknown };
pub const Info = struct { device_name: []const u8, device_name_is_generic: bool,
    manufacturer: ?[]const u8, model: ?[]const u8,       // "Google", "Pixel 8" / "MacBookPro18,3"
    os: []const u8, os_version: []const u8,              // "android","16" / "windows","10.0.26100 (24H2)"
    form_factor: FormFactor, chromeos: bool };
pub fn info(gpa: Allocator) !Info;
```
JS: `await oriel.system.info()`, a builtin allowed for the app's own origin only (it's mildly
identifying). Remote origins need a capability for `system:info`. **Model, OS version and form factor
should be exposed:** Quick Share's endpoint info carries a device type (phone/tablet/laptop), and
"`Sergio's Pixel` (phone)" is exactly what such apps show.

| | Device name | Model / OS / form factor |
|---|---|---|
| Android | `Settings.Global.getString(cr, "device_name")` (API 25+) → `BluetoothAdapter.name` only if BLUETOOTH_CONNECT is held → `Build.MANUFACTURER + " " + Build.MODEL` | `Build.*`, `VERSION.RELEASE`; tablet if `smallestScreenWidthDp ≥ 600`; ChromeOS = `hasSystemFeature("org.chromium.arc")` → laptop |
| iOS | `UIDevice.name`. Since iOS 16 it's generic ("iPhone") unless the app has `com.apple.developer.device-information.user-assigned-device-name`: an Apple-**approved** entitlement (request form, then a provisioning profile with it). Declared as `.ios = .{ .user_assigned_device_name = true }` (iOS-only, so it lives in the iOS options rather than `.permissions`, since nothing prompts) → iOS entitlement; `device_name_is_generic` reports the result | `utsname.machine` ("iPhone16,1"), `UIDevice.systemVersion`, `userInterfaceIdiom` |
| macOS | `SCDynamicStoreCopyComputerName` (links SystemConfiguration). Not `NSHost.currentHost.localizedName`, which can block on DNS | `sysctl hw.model`; laptop if the model contains "MacBook"; `NSProcessInfo.operatingSystemVersion` |
| Windows | `GetComputerNameExW(ComputerNamePhysicalDnsHostname)`, case-preserved. Windows has no separate friendly name: Settings' "Device name" *is* this. NetBIOS (`ComputerName`) is uppercased and 15 chars: don't use it | Registry `HARDWARE\DESCRIPTION\System\BIOS` SystemManufacturer/SystemProductName; `RtlGetVersion` + `DisplayVersion`; laptop if a battery is present (`GetSystemPowerStatus`) or the SMBIOS chassis type says so |
| Linux | `org.freedesktop.hostname1` `PrettyHostname` (system bus) → parse `/etc/machine-info` `PRETTY_HOSTNAME` (shell-quoted) → `uname().nodename` | hostname1 `HardwareVendor/HardwareModel/Chassis` (systemd 249+) → `/sys/class/dmi/id/{sys_vendor,product_name,chassis_type}`; `/etc/os-release` |

Location: `src/core/system.zig` + `system/<os>.zig`. Android gets `OrielRuntime.deviceInfo(): ByteArray` (JSON).
**Phases:** 1 `deviceName` (each platform session, ~30-80 lines); 2 `info()`.
**Tests:** machine-info/os-release parsers (quoting, comments, missing keys); Windows chassis mapping;
`check()` prints `info()`.
**iOS entitlement plumbing:** `ios-app` writes no `.entitlements` today, and xtool signs with its own
(see Q1). This plumbing is shared with local_network multicast and the share extension.

---

## 5. Share target (receive) and share sheet (send)

### Declaration and API
```zig
.share_target = .{
    .types = &.{ "image/*", "video/*", "text/plain", "*/*" }, // MIME; text/plain also means "text/URL shares"
    .multiple = true,
    .label = "Send with GhostShare",   // Android filter label, NSServices title, Send To shortcut name
    .windows_extensions = &.{},        // optional: also "Open with" for these extensions
},
```
```zig
// oriel.share
pub const Source = enum { share, open_with, service, send_to, extension };
pub const File = struct { handle: u32, name: []const u8, mime: []const u8, size: u64 };
pub const Received = struct { id: u32, source: Source, text: ?[]const u8, subject: ?[]const u8,
                              url: ?[]const u8, files: []const File };
pub fn onReceive(handler: ?*const fn (*const Received) void) void;  // queued until set (cold start)
pub fn open(handle: u32) !std.Io.File;        // Zig side: read-only; never a path the page sees
pub fn release(id: u32) void;                 // closes handles, deletes cache copies, revokes tokens
pub const Outgoing = struct { title: ?[]const u8 = null, text: ?[]const u8 = null, url: ?[]const u8 = null,
                              files: []const OutFile = &.{} };  // OutFile = .{ .path } | .{ .handle } | .{ .name, .bytes }
pub fn send(item: Outgoing, anchor: ?Rect, done: ?*const fn (Result) void) error{ Unsupported, Busy }!void;
pub const Result = struct { completed: bool, target: ?[]const u8 };  // target where the OS reports it
pub fn capabilities() struct { receive: ?Source, send: struct { supported: bool, files: bool, text: bool, url: bool, multiple: bool } };
```
```js
oriel.share.onReceive(async (s) => { for (const f of s.files) { const file = await oriel.share.file(f.handle); /* File */ } });
await oriel.share.send({ title, text, url, files: [fileOrBlob] });  // -> { completed, target }
```
The event is `share:received`, queued per ADR-0.5 (capacity 8). The first `onReceive` or `listen`
flushes it, so shares that launched the app aren't lost.

### File contents without paths (WebView and native renderer)
- Every received file becomes a handle in a **shared descriptor table**: move `native_ui/drop.zig`'s
  table to `src/core/file_handles.zig` (drop.zig re-exports it). It is opened read-only at
  receive time, with the same size/mtime snapshot semantics.
- Content URIs, extension inboxes and pasteboard data are first copied into
  `<cache>/oriel-share/<random>/`. Paths the OS hands a desktop app (Open with, Send To) are opened
  in place. Copies are deleted by `release()`, or swept at launch once older than 24 h.
- **Native renderer:** `host.fileRead(handle, offset, len)`, exactly as for drops.
- **WebView:** `oriel.share.file(h)` fetches `<app_origin>/__oriel/share/<token>`. The token is
  128-bit random per file and minted with the event, and it dies with `release()`. The route is
  served by the existing app-scheme handlers (linux/scheme.zig next to `/media/`, WebView2
  WebResourceRequested, macOS/iOS scheme.zig, Android `shouldInterceptRequest`) with Range support
  from `media/range.zig`, and it is same-origin with the app only. This avoids base64 over IPC. The
  bridge wraps the response in a `File` with name and type.
- Outbound page Blobs: `{name, bytes}` through IPC, capped (16 MB) and written to the cache before
  sending; bigger files should come from Zig paths or received handles.

### Receive mapping
| | Mechanism | Where |
|---|---|---|
| Android | `<intent-filter>` ACTION_SEND (+ SEND_MULTIPLE if `multiple`), one `<data android:mimeType>` per type, `android:label`, in the `main-activity` region (ADR-0.3) | `OrielRuntime.onActivityCreated/onActivityNewIntent`: new `shareIntent(intent)` reads EXTRA_STREAM (the typed `getParcelableExtra` on 33+), ClipData, EXTRA_TEXT/SUBJECT; copies URIs **off the main thread, promptly** (the read grant lives with the Activity) with the existing `copyToCache`/`displayName` (OrielRuntime.kt:662-669) → `NativeLib.onShare(json)`. On a cold start, Zig queues the share as notificationTap does |
| iOS, step 1 | `CFBundleDocumentTypes` (MIME → UTI: image/* → public.image, text/plain → public.plain-text, */* → public.data). The app then appears in the share sheet's app row for **files** ("Open in"), but text isn't covered | `scene:openURLContexts:` (ios/Shell.zig:517) and `connectionOptions.URLContexts`: route `file://` to share instead of deep_link, and copy out of `Documents/Inbox` |
| iOS, step 2 | **Share Extension.** A second bundle `<Name>.app/PlugIns/Share.appex`: a small Objective-C principal class shipped by Oriel (`ios/share_extension/OrielShareExtension.m`), compiled by `zig cc -fobjc-arc -fapplication-extension` against the SDK and linked with `-e _NSExtensionMain`. Its Info.plist has `NSExtension{NSExtensionPointIdentifier=com.apple.share-services, NSExtensionPrincipalClass, NSExtensionActivationRule}`, the rule generated from types/multiple. Bundle id `<app_id>.share`. It copies attachments (`loadFileRepresentationForTypeIdentifier:`) and text into the **App Group** container `group.<app_id>/oriel-share/<uuid>/` plus a `manifest.json`, posts the Darwin notification `<app_id>.oriel.share`, then `completeRequest`. **There is no supported way for a Share extension to open its containing app** (`extensionContext.openURL` is for Today/iMessage only; the responder-chain `openURL:` trick is unsupported and has broken across iOS releases). So the extension shows "Sent to GhostShare", and the app ingests on the Darwin notification (if running) or on `orielWillEnterForeground`/launch by scanning the inbox | `share/ios.zig`; `ios-app --appex` in tools/package/ios.zig; App Group entitlement on **both** bundles |
| macOS, step 1 | `CFBundleDocumentTypes` (Finder "Open With", drop on the Dock icon) | A kAEOpenDocuments ('odoc') handler in macos/Shell.zig beside the kAEGetURL one (Shell.zig:253-558) |
| macOS, step 2 | **NSServices** (cheap): Info.plist `NSServices[{NSMenuItem.default=label, NSMessage=orielShare, NSPortName, NSSendFileTypes=UTIs, NSSendTypes=[public.utf8-plain-text, public.url]}]` + `NSApp.setServicesProvider:` with `orielShare:userData:error:`. It shows in context menus and the Services menu, not in the Share menu | `share/macos.zig` |
| macOS, step 3 | Share extension as on iOS. The appex **must be sandboxed** and needs an App Group, so sign_macos.zig must sign `Contents/PlugIns/*.appex` first with its own entitlements. On macOS the extension *can* open the app (NSWorkspace) | Shares the .m source, with `#if TARGET_OS_OSX` |
| Windows | **The Share Target needs package identity: Oriel's NSIS installer is not enough.** Step 1: a **Send To** shortcut (`$SENDTO\<label>.lnk` → exe, files as argv; NSIS `CreateShortCut`, removed on uninstall) and optionally "Open with" (`HKCU\Software\Classes\Applications\<exe>\SupportedTypes` + per-extension `OpenWithProgids`). Later: a **sparse package** (packaging with external location: a signed identity-only MSIX registered by the installer) or a real MSIX format, which then enables `windows.shareTarget` | argv arrives through the existing single-instance WM_COPYDATA path (deep_link/windows.zig); forward file args, not just URLs. Note the 32K command-line limit for big selections |
| Linux | `.desktop` `MimeType=` (types; `*/*` → `application/octet-stream`; wildcards like `image/*` aren't reliably honoured, so expand a known list) and `Exec=… %U` (desktop.zig:58 uses `%u` for schemes; switch to `%U`) → "Open With" in Nautilus/Dolphin. **No XDG share-target portal exists** | GApplication command-line (linux/Shell.zig:156): non-scheme args go to share |

### Send mapping
| | API | Notes |
|---|---|---|
| Android | `Intent.createChooser(ACTION_SEND/SEND_MULTIPLE)`, EXTRA_STREAM = `OrielFileProvider.uriFor` (OrielFileProvider.kt:32) + ClipData + FLAG_GRANT_READ_URI_PERMISSION, EXTRA_TEXT | Target via the chooser's IntentSender (EXTRA_CHOSEN_COMPONENT); `completed` = chosen |
| iOS | `UIActivityViewController(activityItems: [NSURL…, NSString, NSURL])` from the root VC | iPad **requires** `popoverPresentationController.sourceView/sourceRect` (the `anchor`, defaulting to the window's center) or it crashes; `completionWithItemsHandler` → Result |
| macOS | `NSSharingServicePicker(items) showRelativeToRect:ofView:preferredEdge:` | Delegate `didChooseSharingService:` + `NSSharingServiceDelegate` didShare/didFail |
| Windows | `IDataTransferManagerInterop::GetForWindow(hwnd)` → `add_DataRequested` → `DataPackage` (Properties.Title is **mandatory**, SetText, SetWebLink, SetStorageItems via `StorageFile.GetFileFromPathAsync` under `DataRequest.GetDeferral()`) → `ShowShareUIForWindow(hwnd)` | Works unpackaged. Needs winrt.zig (§3). `ShareCompleted` gives the target |
| Linux | No share portal. Fallback: `org.freedesktop.portal.OpenURI.OpenFile` with `ask: true` (app chooser) for **one file**, and `OpenURI` for a URL | `capabilities().send` reports `files: true, multiple: false, text: false`; anything else returns `Unsupported` |

### Phases
1. **Android receive + send** (intent filters, copy to cache, queued event, file handles and the token route in the Android scheme), with `file_handles.zig` and `pending_events.zig` done by shared. This is GhostShare's main mobile flow.
2. Desktop receive (Linux MimeType/%U, macOS document types + odoc, Windows Send To) and send on macOS and Linux (portal), in parallel.
3. iOS: document types (receive), UIActivityViewController (send), then the Share extension (the biggest Apple item, ~1-1.5 weeks including signing). Windows send through DataTransferManager after winrt.zig.
4. macOS NSServices, then the macOS extension; a Windows sparse package (optional).

### Tests
- Generators: intent-filter XML; MIME → UTI and the CFBundleDocumentTypes plist; `NSExtensionActivationRule`
  (dictionary or SUBQUERY form); the NSServices plist; the appex Info.plist; desktop `MimeType`/`%U`; NSIS
  SendTo create/remove.
- Runtime logic: the share queue (cold start: three shares before the handler, then the page; ordering;
  capacity overflow drops the oldest with a log); token mint/revoke (a revoked token → 404, another
  origin → 403); the cache sweep; Range reads.
- Headless Linux: launch the dev exe with file args into a running instance → handler gets `open_with`.
  Android: `adb shell am start -a android.intent.action.SEND -t text/plain --es android.intent.extra.TEXT hi`
  and `--eu android.intent.extra.STREAM content://…`, scripted on an emulator/ChromeOS.

---

## Work split (four sessions)

| Session | Phase-0 / shared | Features |
|---|---|---|
| **Linux + shared** (start first, ~3 days, blocking) | ADR-0.1 kinds (`bluetooth` first: Android needs it now) + `permission_options` + escape-hatch structs; ADR-0.3 manifest regions + `build/android_manifest.zig`; ADR-0.4 `bridge_api.zig`; ADR-0.5 `pending_events.zig` + `events:ready`; `file_handles.zig` extraction; **stub modules** (`network`, `bluetooth`, `share`, `system` common.zig with the full API and backends returning `Unsupported`) so the others build against the contract; `bluetooth/common.zig` `encodedSize` + the per-OS Unsupported table (to land alongside the Android BLE work) | Linux: BlueZ advertise and scan, GNetworkMonitor, hostname1, MimeType/%U receive, portal send |
| **Android / ChromeOS** | Kotlin permission rework (`permissions(kind)` arrays, `onResult` range) | BLE advertise (in progress), multicast lock, BLE scan + the state event, network info, deviceName/info, share receive and send |
| **macOS + iOS** | `ios-app`/macOS plist escape hatch, entitlements file for iOS (Q1), the local-network probe | CBManager permissions, Apple advertise (limited) and scan, nw_path_monitor, device names, document types + odoc, NSServices, share sheets, the Share extension(s) |
| **Windows** | `winrt.zig` foundation + pinterface IID generator | NSIS firewall rule + Send To, adapters info, computer name, DataTransferManager send, BLE publisher and watcher |

The only hard ordering is: phase 0 → everything else, and winrt.zig → Windows BLE and send.
Everything else runs in parallel against the stub contracts. GhostShare can drop its two
workarounds after **phase 0 + the Android multicast lock**, about a week in.

## Risks

| Risk | L | I | Mitigation |
|---|---|---|---|
| Adding Kinds breaks Kotlin ordinals or the inline loops in build/ios-app | M | H | Append-only; a test asserting the Kotlin constants equal the Zig ordinals (parse OrielPermissions.kt in a build test) |
| Existing Android projects lack manifest markers | H | M | A clear build error + `-Dandroid_force`; one-time migration notes in CHANGELOG |
| iOS local-network status is a heuristic | H | L | `unknown` is honest; documented; the cached result is refreshed on each probe |
| WinRT-from-Zig effort and IID mistakes | M | M | Generator-tested IIDs; a PoC of publisher-only first (one week box) |
| BLE legacy 31-byte budget / Flags differences per stack | M | M | Shared `encodedSize` per platform + a hardware test with the real FE2C payload |
| ChromeOS ARC: multicast forwarding and BLE advertising support vary by device and board | M | M | `capabilities()` from the adapter; verify on the user's ChromeOS device (Q5) |
| Share-extension signing (App Groups, appex profiles) with xtool / free accounts | H | M | Document types first (no extension); extension gated on Q1 |
| Linux `image/*` in MimeType ignored by some file managers | M | L | Expand to concrete types |
| Received files are large, and the Android URI grant expires with the Activity | M | M | Copy right away on a worker; progress isn't exposed in v1 (Q7) |

## Open questions for the user
1. **iOS signing/entitlements:** does xtool accept a custom entitlements file and sign embedded
   `.appex` bundles (with App Groups) under your team? Are you on a paid team? This decides whether
   multicast, user-assigned-device-name and the Share extension are possible at all from Linux.
2. **GhostShare on iOS uses mdns-sd (raw multicast)**, which requires Apple's approved multicast
   entitlement. Request it, or should Oriel later offer DNS-SD (`DNSServiceBrowse`, which needs only
   NSBonjourServices) as `oriel.network.dnssd`?
3. Is the iOS/macOS local-network probe (browse your own service) acceptable, or should `request`
   simply return `unknown` and leave the prompt to the first real use?
4. Android 17 local network protection (`ACCESS_LOCAL_NETWORK`, enforced at targetSdk 37): confirm
   the current status and what targetSdk Oriel's template will use.
5. ChromeOS: which device or board can we test BLE advertising and multicast forwarding on?
6. Windows: is an MSIX or sparse-package format (code-signing certificate) on the roadmap? Without
   it, a Windows Share Target and the MSIX capability lines stay out of reach.
7. Share v1: expose copy progress for large inbound Android/iOS files, or deliver only after the copy finishes?
8. Should `bluetooth` stay opt-in (`-Dbluetooth`), or be default-on and inert until `.permissions.bluetooth` is declared?
9. A macOS sandbox option (`.macos.sandbox`) makes the network/bluetooth sandbox entitlements
   meaningful. Is the Mac App Store a goal, or is that row future-only?
10. Apple and `connectable = false`: best-effort (recommended, reported by `non_connectable: false`)
    or `Unsupported`? Should the decided API also get the additive `non_connectable`, `scan`,
    `powered` and `max_bytes` capability fields and the `bluetooth:advertise` state event, before
    the Android implementation freezes the shape?
