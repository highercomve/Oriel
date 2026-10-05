package dev.oriel

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor

/**
 * DNS-SD registration and browsing for `oriel.network.mdns`
 * (src/modules/network/android.zig) on the platform's [NsdManager]. The
 * system's mDNS responder does the multicast, so no MulticastLock and no
 * permission beyond INTERNET are needed (NEARBY_WIFI_DEVICES gates Wi-Fi
 * Direct/Aware, not NSD).
 *
 * Threads: Zig calls [register], [unregister], [browse] and [stopBrowse]
 * on the UI thread or on [thread]; they only call NsdManager (thread-safe)
 * and never wait. Register and browse answers go to
 * [NativeLib.onMdnsResult] straight from NsdManager's callback thread (a
 * Zig thread may be blocked waiting for them, even [thread] itself).
 * Browse state (found services, the resolve queue) lives on [thread],
 * where [NativeLib.onMdnsEvent] delivers events in mdns.zig's wire format.
 */
internal object OrielMdns {
    private const val TAG = "OrielMdns"
    private const val MAX_RESOLVE_ATTEMPTS = 6

    private val thread = HandlerThread("oriel-mdns").apply { start() }
    private val handler = Handler(thread.looper)
    private val executor = Executor { handler.post(it) }
    private val nsd: NsdManager by lazy { OrielRuntime.app.getSystemService(Context.NSD_SERVICE) as NsdManager }

    private val registrations = ConcurrentHashMap<Int, NsdManager.RegistrationListener>()
    private val browsers = ConcurrentHashMap<Int, Browser>()

    // -----------------------------------------------------------------
    // Registration
    // -----------------------------------------------------------------

    fun register(id: Int, name: ByteArray, type: ByteArray, port: Int, txt: ByteArray): Boolean {
        val info = NsdServiceInfo().apply {
            serviceName = name.utf8()
            serviceType = type.utf8()
            this.port = port
        }
        try {
            DataInputStream(ByteArrayInputStream(txt)).use { input ->
                repeat(input.readUnsignedShort()) {
                    val key = input.readBytes16().utf8()
                    if (!setAttribute(info, key, input.readBytes16())) {
                        NativeLib.onMdnsResult(0, id, false, -1, null)
                        return true
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "register: bad service info", e)
            NativeLib.onMdnsResult(0, id, false, -1, null)
            return true
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(si: NsdServiceInfo) {
                NativeLib.onMdnsResult(0, id, true, 0, (si.serviceName ?: info.serviceName).bytes())
            }

            override fun onRegistrationFailed(si: NsdServiceInfo, code: Int) {
                registrations.remove(id)
                NativeLib.onMdnsResult(0, id, false, code, null)
            }

            override fun onServiceUnregistered(si: NsdServiceInfo) {}
            override fun onUnregistrationFailed(si: NsdServiceInfo, code: Int) {
                Log.w(TAG, "unregister ${info.serviceName}: failed ($code)")
            }
        }
        registrations[id] = listener
        return try {
            nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
            true
        } catch (e: Exception) {
            Log.w(TAG, "registerService", e)
            registrations.remove(id)
            false
        }
    }

    fun unregister(id: Int) {
        val listener = registrations.remove(id) ?: return
        try {
            nsd.unregisterService(listener)
        } catch (e: IllegalArgumentException) {
            // Never registered (it failed) or already gone.
        }
    }

    /** TXT values are bytes; the public API takes a String (UTF-8 encoded
     *  again inside). A value that isn't UTF-8 goes through the hidden
     *  byte[] overload, if this Android lets us reach it. */
    private fun setAttribute(info: NsdServiceInfo, key: String, value: ByteArray): Boolean {
        val text = try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(value)).toString()
        } catch (e: CharacterCodingException) {
            null
        }
        if (text != null) {
            info.setAttribute(key, text)
            return true
        }
        return try {
            NsdServiceInfo::class.java
                .getDeclaredMethod("setAttribute", String::class.java, ByteArray::class.java)
                .invoke(info, key, value)
            true
        } catch (e: Exception) {
            Log.w(TAG, "TXT \"$key\": a value that isn't UTF-8 isn't supported on this Android", e)
            false
        }
    }

    // -----------------------------------------------------------------
    // Browsing
    // -----------------------------------------------------------------

    /** A service seen by a browser; [thread] only. */
    private class Entry(val info: NsdServiceInfo) {
        var reported = false
        var callback: NsdManager.ServiceInfoCallback? = null
        var attempts = 0
    }

    private class Browser(val id: Int, val type: String) {
        @Volatile var stopped = false
        /** By service name; [thread] only. */
        val entries = HashMap<String, Entry>()
        lateinit var listener: NsdManager.DiscoveryListener
    }

    fun browse(id: Int, type: ByteArray): Boolean {
        val b = Browser(id, type.utf8())
        b.listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                NativeLib.onMdnsResult(1, id, true, 0, null)
            }

            override fun onStartDiscoveryFailed(serviceType: String, code: Int) {
                browsers.remove(id)
                b.stopped = true
                NativeLib.onMdnsResult(1, id, false, code, null)
            }

            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStopDiscoveryFailed(serviceType: String, code: Int) {
                Log.w(TAG, "stop discovery ${b.type}: failed ($code)")
            }

            override fun onServiceFound(info: NsdServiceInfo) {
                handler.post { found(b, info) }
            }

            override fun onServiceLost(info: NsdServiceInfo) {
                handler.post { lost(b, info.serviceName ?: return@post) }
            }
        }
        browsers[id] = b
        return try {
            nsd.discoverServices(b.type, NsdManager.PROTOCOL_DNS_SD, b.listener)
            true
        } catch (e: Exception) {
            Log.w(TAG, "discoverServices", e)
            browsers.remove(id)
            false
        }
    }

    fun stopBrowse(id: Int) {
        val b = browsers.remove(id) ?: return
        b.stopped = true
        try {
            nsd.stopServiceDiscovery(b.listener)
        } catch (e: IllegalArgumentException) {
            // Discovery failed to start, or already stopped.
        }
        handler.post {
            for (e in b.entries.values) forget(e)
            b.entries.clear()
            queue.removeAll { it.first === b }
        }
    }

    /** [thread] */
    private fun found(b: Browser, info: NsdServiceInfo) {
        if (b.stopped) return
        val name = info.serviceName ?: return
        // API 34+ reports a service once per network it is on; one is enough.
        if (b.entries.containsKey(name)) return
        val e = Entry(info)
        b.entries[name] = e
        if (Build.VERSION.SDK_INT >= 34) watch(b, e) else enqueue(b, e)
    }

    /** [thread] */
    private fun lost(b: Browser, name: String) {
        val e = b.entries.remove(name) ?: return
        forget(e)
        queue.removeAll { it.second === e }
        if (e.reported && !b.stopped) send(b, encodeLost(name))
    }

    /** API 34+: addresses and TXT now and whenever they change. */
    private fun watch(b: Browser, e: Entry) {
        if (Build.VERSION.SDK_INT < 34) return
        val cb = object : NsdManager.ServiceInfoCallback {
            override fun onServiceInfoCallbackRegistrationFailed(code: Int) {
                Log.w(TAG, "service info callback for ${e.info.serviceName}: failed ($code), resolving instead")
                e.callback = null
                if (!b.stopped && b.entries[e.info.serviceName] === e) enqueue(b, e)
            }

            override fun onServiceUpdated(si: NsdServiceInfo) {
                if (!b.stopped && b.entries[e.info.serviceName] === e) deliver(b, e, si)
            }

            // The discovery listener reports it too.
            override fun onServiceLost() {}
            override fun onServiceInfoCallbackUnregistered() {}
        }
        e.callback = cb
        try {
            nsd.registerServiceInfoCallback(e.info, executor, cb)
        } catch (ex: Exception) {
            Log.w(TAG, "registerServiceInfoCallback", ex)
            e.callback = null
            enqueue(b, e)
        }
    }

    private fun forget(e: Entry) {
        val cb = e.callback ?: return
        e.callback = null
        if (Build.VERSION.SDK_INT < 34) return
        try {
            nsd.unregisterServiceInfoCallback(cb)
        } catch (ex: IllegalArgumentException) {
            // Its registration failed.
        }
    }

    // Before API 34, resolveService: one at a time across the app (older
    // Androids answer a second concurrent one with FAILURE_ALREADY_ACTIVE).

    /** [thread] */
    private val queue = ArrayDeque<Pair<Browser, Entry>>()
    private var resolving = false

    private fun enqueue(b: Browser, e: Entry) {
        queue.addLast(b to e)
        pump()
    }

    @Suppress("DEPRECATION")
    private fun pump() {
        if (resolving) return
        val (b, e) = queue.pollFirst() ?: return
        if (b.stopped || b.entries[e.info.serviceName] !== e) return pump()
        resolving = true
        val listener = object : NsdManager.ResolveListener {
            override fun onServiceResolved(si: NsdServiceInfo) {
                handler.post {
                    resolving = false
                    if (!b.stopped && b.entries[e.info.serviceName] === e) deliver(b, e, si)
                    pump()
                }
            }

            override fun onResolveFailed(si: NsdServiceInfo, code: Int) {
                handler.post {
                    resolving = false
                    val busy = code == NsdManager.FAILURE_ALREADY_ACTIVE || code == NsdManager.FAILURE_MAX_LIMIT
                    if (busy && ++e.attempts < MAX_RESOLVE_ATTEMPTS) {
                        queue.addFirst(b to e)
                        handler.postDelayed({ pump() }, 200L * e.attempts)
                    } else {
                        Log.w(TAG, "resolve ${e.info.serviceName}: failed ($code)")
                        pump()
                    }
                }
            }
        }
        try {
            nsd.resolveService(e.info, listener)
        } catch (ex: Exception) {
            Log.w(TAG, "resolveService", ex)
            resolving = false
            pump()
        }
    }

    // -----------------------------------------------------------------
    // Events (the wire format of src/modules/network/mdns.zig)
    // -----------------------------------------------------------------

    @Suppress("DEPRECATION")
    private fun addresses(si: NsdServiceInfo): List<InetAddress> =
        if (Build.VERSION.SDK_INT >= 34) si.hostAddresses else listOfNotNull(si.host)

    /** [thread] */
    private fun deliver(b: Browser, e: Entry, si: NsdServiceInfo) {
        e.reported = true
        send(b, encodeFound(e.info.serviceName, si))
    }

    private fun send(b: Browser, event: ByteArray) {
        if (!b.stopped) NativeLib.onMdnsEvent(b.id, event)
    }

    private fun encodeFound(name: String, si: NsdServiceInfo): ByteArray {
        val bytes = ByteArrayOutputStream()
        DataOutputStream(bytes).use { out ->
            out.writeByte(0)
            out.writeBytes16(name.bytes())
            out.writeBytes16(ByteArray(0)) // host: NsdServiceInfo has no host name
            out.writeShort(si.port)
            val addrs = addresses(si).mapNotNull { it.hostAddress }.take(255)
            out.writeByte(addrs.size)
            for (a in addrs) out.writeBytes16(a.bytes())
            val attrs = (si.attributes ?: emptyMap()).entries.take(255)
            out.writeByte(attrs.size)
            for ((k, v) in attrs) {
                out.writeBytes16(k.bytes())
                out.writeBytes16(v ?: ByteArray(0))
            }
        }
        return bytes.toByteArray()
    }

    private fun encodeLost(name: String): ByteArray {
        val bytes = ByteArrayOutputStream()
        DataOutputStream(bytes).use { out ->
            out.writeByte(1)
            out.writeBytes16(name.bytes())
        }
        return bytes.toByteArray()
    }

    private fun DataOutputStream.writeBytes16(b: ByteArray) {
        val n = minOf(b.size, 0xFFFF)
        writeShort(n)
        write(b, 0, n)
    }

    private fun DataInputStream.readBytes16(): ByteArray {
        val b = ByteArray(readUnsignedShort())
        readFully(b)
        return b
    }
}
