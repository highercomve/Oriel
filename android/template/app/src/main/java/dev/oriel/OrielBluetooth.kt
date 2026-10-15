package dev.oriel

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import android.util.Log
import java.util.UUID

/**
 * Bluetooth LE advertising for `oriel.bluetooth`
 * (src/modules/bluetooth/android.zig) on [android.bluetooth.le.BluetoothLeAdvertiser]:
 * legacy advertising (31 bytes), no timeout, until [stop].
 *
 * Threads: Zig calls everything here on the UI thread, where
 * AdvertiseCallback and the adapter's state broadcast also arrive. A start
 * (or its failure, which Android reports after startAdvertising returned)
 * and a stop the system made (the adapter turned off) go to Zig as the
 * "ble-advertise" system event: "handle\tstate\tcode", state "started",
 * "failed" (code: AdvertiseCallback's error) or "stopped".
 */
internal object OrielBluetooth {
    private const val TAG = "OrielBluetooth"
    private const val LEGACY_MAX = 31

    // bluetooth/common.zig's results: a handle (> 0) or one of these.
    private const val UNSUPPORTED = -1
    private const val PERMISSION_DENIED = -2
    private const val ADAPTER_OFF = -3
    private const val FAILED = -4

    private var next = 1
    private val active = HashMap<Int, AdvertiseCallback>()
    private var watching = false

    private val adapter: BluetoothAdapter?
        get() = (OrielRuntime.app.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private fun hasLe(): Boolean = OrielRuntime.app.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)

    /** Android 12+ asks for BLUETOOTH_ADVERTISE (the "Nearby devices" group); older ones only need BLUETOOTH_ADMIN, granted at install. */
    private fun permitted(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            OrielRuntime.app.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED

    /**
     * Bits for android.zig's capabilities(): 1 the device can advertise (an
     * LE adapter with an advertiser, or one that is off, so advertise
     * answers AdapterOff), 2 the adapter is on, 4 extended advertising;
     * bits 16+ the bytes Oriel sends (legacy: 31).
     *
     * Not isMultipleAdvertisementSupported: that's more than one at a time,
     * and ChromeOS's ARC says false while advertising one works.
     */
    @SuppressLint("MissingPermission")
    fun capabilities(): Int {
        val a = adapter ?: return 0
        if (!hasLe()) return 0
        val on = a.isEnabled
        // Off, the adapter has no advertiser to tell its support.
        val can = if (on) a.bluetoothLeAdvertiser != null else true
        if (!can) return 0
        var bits = 1 or (if (on) 2 else 0)
        if (on && a.isLeExtendedAdvertisingSupported) bits = bits or 4
        return bits or (LEGACY_MAX shl 16)
    }

    /**
     * Start advertising: [uuids], 16-bit service UUIDs little-endian; service
     * data [sdData] under [sdUuid] (-1: none); [flags] bit 0 the device name,
     * bit 1 connectable, bits 2-3 the mode (low_latency, balanced,
     * low_power), bits 4-5 the power (high, medium, low, ultra_low).
     */
    @SuppressLint("MissingPermission")
    fun advertise(uuids: ByteArray, sdUuid: Int, sdData: ByteArray?, flags: Int): Int {
        val a = adapter ?: return UNSUPPORTED
        if (!hasLe()) return UNSUPPORTED
        if (!permitted()) return PERMISSION_DENIED
        if (!a.isEnabled) return ADAPTER_OFF
        val advertiser = a.bluetoothLeAdvertiser ?: return UNSUPPORTED
        // One at a time without multiple-advertisement support (ChromeOS's
        // ARC): a second would fail later as DATA_TOO_LARGE, which misleads.
        if (active.isNotEmpty() && !a.isMultipleAdvertisementSupported) {
            Log.w(TAG, "one advertisement at a time on this adapter")
            return FAILED
        }
        val mode = when ((flags shr 2) and 3) {
            0 -> AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY
            2 -> AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
            else -> AdvertiseSettings.ADVERTISE_MODE_BALANCED
        }
        val power = when ((flags shr 4) and 3) {
            0 -> AdvertiseSettings.ADVERTISE_TX_POWER_HIGH
            2 -> AdvertiseSettings.ADVERTISE_TX_POWER_LOW
            3 -> AdvertiseSettings.ADVERTISE_TX_POWER_ULTRA_LOW
            else -> AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM
        }
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(mode)
            .setTxPowerLevel(power)
            .setConnectable(flags and 2 != 0)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder().setIncludeDeviceName(flags and 1 != 0).setIncludeTxPowerLevel(false)
        var i = 0
        while (i + 1 < uuids.size) {
            data.addServiceUuid(uuid16((uuids[i].toInt() and 0xff) or ((uuids[i + 1].toInt() and 0xff) shl 8)))
            i += 2
        }
        if (sdUuid >= 0) data.addServiceData(uuid16(sdUuid), sdData ?: ByteArray(0))
        val handle = next++
        val callback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
                if (active.containsKey(handle)) report(handle, "started", 0)
            }

            override fun onStartFailure(errorCode: Int) {
                Log.w(TAG, "advertisement $handle failed: $errorCode")
                if (active.remove(handle) != null) report(handle, "failed", errorCode)
            }
        }
        active[handle] = callback
        watchAdapter()
        try {
            advertiser.startAdvertising(settings, data.build(), callback)
        } catch (e: SecurityException) {
            active.remove(handle)
            return PERMISSION_DENIED
        } catch (e: RuntimeException) {
            Log.w(TAG, "startAdvertising", e)
            active.remove(handle)
            return FAILED
        }
        return handle
    }

    @SuppressLint("MissingPermission")
    fun stop(handle: Int) {
        val callback = active.remove(handle) ?: return
        try {
            adapter?.bluetoothLeAdvertiser?.stopAdvertising(callback)
        } catch (e: RuntimeException) {
            Log.w(TAG, "stopAdvertising", e)
        }
    }

    private fun uuid16(u: Int): ParcelUuid =
        ParcelUuid(UUID(((u.toLong() and 0xffff) shl 32) or 0x1000L, -0x7fffff7fa064cb05L)) // 0000xxxx-0000-1000-8000-00805f9b34fb

    private fun report(handle: Int, state: String, code: Int) =
        NativeLib.onSystemEvent("ble-advertise".bytes(), "$handle\t$state\t$code".bytes())

    /** The adapter turning off ends every advertisement: each is "stopped". */
    private fun watchAdapter() {
        if (watching) return
        watching = true
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
                if (state != BluetoothAdapter.STATE_TURNING_OFF && state != BluetoothAdapter.STATE_OFF) return
                val ended = active.keys.toList()
                active.clear()
                for (h in ended) report(h, "stopped", 0)
            }
        }
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        // A system broadcast: exported, as Android 14 asks it be said.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            OrielRuntime.app.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            OrielRuntime.app.registerReceiver(receiver, filter)
        }
    }
}
