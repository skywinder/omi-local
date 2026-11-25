package org.omilocal.next

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/** A single CV1 connection, with one pending Android GATT operation at a time. */
@SuppressLint("MissingPermission")
internal class NextCV1(private val context: Context, messenger: BinaryMessenger) : EventChannel.StreamHandler {
    private val handler = Handler(Looper.getMainLooper())
    private val commands = MethodChannel(messenger, "org.omilocal.next/cv1")
    private val events = EventChannel(messenger, "org.omilocal.next/cv1.events")
    private val adapter: BluetoothAdapter? get() = context.getSystemService(BluetoothManager::class.java)?.adapter
    private val cccd = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    private var sink: EventChannel.EventSink? = null
    private var scan: ScanCallback? = null
    private var gatt: BluetoothGatt? = null
    private val devices = mutableMapOf<String, String>()
    private val stats = mutableMapOf<String, Any>()
    private val selection = context.getSharedPreferences("next.cv1", Context.MODE_PRIVATE)
    private var target: String? = null
    private var readyOnce = false
    private var phase = "idle"
    private var generation = 0
    private var codec: Int? = null
    private var discovering = false
    private var features: Int? = null
    private var timer: Runnable? = null
    private var retryDelay = 1000L
    private var desiredAudio: Int? = null
    private var confirmedAudio: Int? = null
    private var lastAudio = 0
    private var rssiPending = false
    private val operations = ArrayDeque<Job>()
    private var active: Job? = null

    private data class Job(
        val uuid: UUID?,
        val kind: String,
        val start: (BluetoothGatt) -> Boolean,
        val complete: (ByteArray?) -> Unit,
    )

    init {
        commands.setMethodCallHandler(::command)
        events.setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        val saved = selection.getString("selected", null)
        if (phase == "idle" && saved != null && BluetoothAdapter.checkBluetoothAddress(saved)) {
            // Restoring a saved pendant bypasses scan and the manual connect command.
            // Allocate a live generation before publishing any measurements or audio.
            clearLink()
            target = saved
            readyOnce = true
            connect()
        } else {
            publish(phase)
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        disconnect()
    }

    fun dispose() {
        commands.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
        disconnect()
    }

    private fun command(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "usesLegacyScanPermission" -> result.success(Build.VERSION.SDK_INT < 31)
                "scan" -> {
                    if (phase == "ready" || phase == "connecting") return result.error("busy", null, null)
                    disconnect()
                    devices.clear()
                    startScan()
                    result.success(null)
                }
                "connect" -> {
                    val address = call.argument<String>("id")
                    if (address == null || !devices.containsKey(address)) return result.error("unknown_device", null, null)
                    disconnect()
                    target = address
                    connect()
                    result.success(null)
                }
                "disconnect", "close" -> {
                    if (call.method == "disconnect") selection.edit().remove("selected").apply()
                    disconnect(if (call.method == "disconnect") "manual" else null)
                    result.success(null)
                }
                "setAudio" -> setAudio(call, result)
                "sampleDiagnostics" -> {
                    if (phase == "ready" && desiredAudio == null && confirmedAudio == null && active == null && operations.isEmpty()) sample()
                    result.success(null)
                }
                "sampleSignal" -> {
                    sampleSignal()
                    result.success(null)
                }
                "writeSetting" -> writeSetting(call, result)
                else -> result.notImplemented()
            }
        } catch (_: SecurityException) {
            clearLink()
            publish("unavailable", "permission")
            result.error("bluetooth_permission", null, null)
        }
    }

    private fun publish(value: String, reason: String? = null, code: Int? = null) {
        phase = value
        val state = mutableMapOf<String, Any>("type" to "state", "phase" to phase, "generation" to generation)
        codec?.takeIf { phase == "ready" }?.let { state["codec"] = it }
        target?.takeIf { phase == "ready" || phase == "reconnecting" }?.let { state["deviceId"] = it }
        reason?.let { state["reason"] = it }
        code?.let { state["code"] = it }
        sink?.success(state)
    }

    private fun telemetry(measurement: String? = null) {
        if (phase == "ready") {
            val event = mutableMapOf<String, Any>("type" to "diagnostics", "generation" to generation, "values" to stats.toMap())
            measurement?.let { event["measurement"] = it }
            sink?.success(event)
        }
    }

    private fun cancelTimer() {
        timer?.let(handler::removeCallbacks)
        timer = null
    }

    private fun after(delay: Long, action: () -> Unit) {
        cancelTimer()
        val epoch = generation
        timer = Runnable { if (epoch == generation) action() }.also { handler.postDelayed(it, delay) }
    }

    private fun stopScan() {
        val callback = scan ?: return
        scan = null
        runCatching { adapter?.bluetoothLeScanner?.stopScan(callback) }
    }

    private fun clearLink() {
        cancelTimer()
        stopScan()
        generation++
        val old = gatt
        gatt = null
        runCatching { old?.disconnect() }
        runCatching { old?.close() }
        val pending = listOfNotNull(active) + operations
        active = null
        operations.clear()
        stats.clear()
        codec = null
        discovering = false
        features = null
        desiredAudio = null
        confirmedAudio = null
        lastAudio = 0
        rssiPending = false
        pending.forEach { it.complete(null) }
    }

    private fun disconnect(reason: String? = null) {
        target = null
        readyOnce = false
        retryDelay = 1000
        clearLink()
        publish("idle", reason)
    }

    private fun lost(retry: Boolean, reason: String = "dropped", code: Int? = null) {
        clearLink()
        if (!retry || !readyOnce || target == null) {
            publish("failed", reason, code)
            return
        }
        publish("reconnecting", reason, code)
        val delay = retryDelay
        retryDelay = minOf(retryDelay * 2, 30000)
        after(delay) { connect() }
    }

    private fun startScan() {
        val scanner = adapter?.bluetoothLeScanner
        if (scanner == null) {
            publish("unavailable", "radio")
            return
        }
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                handler.post {
                    if (scan !== this) return@post
                    val address = result.device.address
                    val name = result.scanRecord?.deviceName ?: "Omi CV1"
                    if (devices.put(address, name) == null) {
                        sink?.success(mapOf("type" to "device", "id" to address, "name" to name))
                    }
                }
            }

            override fun onScanFailed(errorCode: Int) {
                handler.post {
                    if (scan === this) {
                        stopScan()
                        cancelTimer()
                        publish("failed", "connect", errorCode)
                    }
                }
            }
        }
        scan = callback
        publish("scanning")
        val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(Cv1Uuid.audioService)).build())
        scanner.startScan(filters, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), callback)
        after(12000) {
            stopScan()
            publish("idle")
        }
    }

    private fun connect() {
        val address = target ?: return
        publish(if (readyOnce) "reconnecting" else "connecting")
        try {
            gatt = adapter?.getRemoteDevice(address)?.connectGatt(context, false, callbacks, android.bluetooth.BluetoothDevice.TRANSPORT_LE)
        } catch (_: SecurityException) {
            publish("unavailable", "permission")
            return
        }
        if (gatt == null) return lost(false, "connect")
        after(15000) { lost(true, "timeout") }
    }

    private fun characteristic(service: UUID, uuid: UUID): BluetoothGattCharacteristic? =
        gatt?.getService(service)?.getCharacteristic(uuid)

    private fun enqueue(job: Job) {
        operations.addLast(job)
        advance()
    }

    private fun advance() {
        val connection = gatt ?: return
        if (active != null) return
        val next = operations.removeFirstOrNull() ?: return
        active = next
        if (runCatching { next.start(connection) }.getOrDefault(false)) {
            val optional = phase == "ready" && (next.kind == "read" || next.uuid == Cv1Uuid.battery)
            after(if (optional) 2000 else 5000) {
                if (optional) finish(connection, next.kind, next.uuid, null)
                else lost(true, "timeout")
            }
        } else {
            finish(connection, next.kind, next.uuid, null)
        }
    }

    private fun finish(connection: BluetoothGatt, kind: String, uuid: UUID?, data: ByteArray?) {
        val job = active ?: return
        if (gatt !== connection || job.kind != kind || job.uuid != uuid) return
        active = null
        cancelTimer()
        job.complete(data)
        advance()
    }

    private fun read(char: BluetoothGattCharacteristic, complete: (ByteArray?) -> Unit) =
        enqueue(Job(char.uuid, "read", { it.readCharacteristic(char) }, complete))

    private fun notify(char: BluetoothGattCharacteristic, enabled: Boolean, complete: (ByteArray?) -> Unit) {
        enqueue(Job(char.uuid, "descriptor", { connection ->
            val descriptor = char.getDescriptor(cccd)
            if (descriptor == null || !connection.setCharacteristicNotification(char, enabled)) false
            else {
                val value = if (enabled) BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    else BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
                if (Build.VERSION.SDK_INT >= 33) {
                    connection.writeDescriptor(descriptor, value) == BluetoothStatusCodes.SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    descriptor.value = value
                    @Suppress("DEPRECATION")
                    connection.writeDescriptor(descriptor)
                }
            }
        }, complete))
    }

    private fun discover(connection: BluetoothGatt) {
        if (discovering) return
        discovering = true
        cancelTimer()
        if (!connection.discoverServices()) return lost(true)
        after(10000) { lost(true, "timeout") }
    }

    private fun configured(connection: BluetoothGatt) {
        cancelTimer()
        val format = characteristic(Cv1Uuid.audioService, Cv1Uuid.codec) ?: return lost(false, "incompatible")
        val audio = characteristic(Cv1Uuid.audioService, Cv1Uuid.audio) ?: return lost(false, "incompatible")
        val button = characteristic(Cv1Uuid.buttonService, Cv1Uuid.button) ?: return lost(false, "incompatible")
        if (audio.getDescriptor(cccd) == null) return lost(false, "incompatible")
        read(format) { bytes ->
            if (gatt !== connection) return@read
            val id = bytes?.firstOrNull()?.toInt()
            if (id != 20 && id != 21) return@read lost(false, "incompatible")
            codec = id
            notify(button, true) {
                if (gatt === connection) {
                    if (it == null) lost(true)
                    else {
                        target?.let { selection.edit().putString("selected", it).apply() }
                        readyOnce = true
                        retryDelay = 1000
                        target?.let(devices::get)?.let { name -> stats["name"] = name }
                        publish("ready")
                        telemetry()
                        val battery = characteristic(Cv1Uuid.batteryService, Cv1Uuid.battery)
                        if (battery != null && battery.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0 &&
                            battery.getDescriptor(cccd) != null) {
                            notify(battery, true) {}
                        }
                        if (battery != null && battery.properties and BluetoothGattCharacteristic.PROPERTY_READ != 0) {
                            read(battery) batteryRead@{ bytes ->
                                if (gatt !== connection) return@batteryRead
                                val level = bytes?.firstOrNull()?.toInt()?.and(255)?.takeIf { it <= 100 } ?: return@batteryRead
                                stats["battery"] = level
                                telemetry("battery")
                            }
                        }
                    }
                }
            }
        }
    }

    private fun setAudio(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<Int>("subscription")
        val enabled = call.argument<Boolean>("enabled")
        if (token == null || enabled == null || token <= 0 || call.argument<Int>("generation") != generation) {
            return result.error("stale", null, null)
        }
        val char = characteristic(Cv1Uuid.audioService, Cv1Uuid.audio)
        if (phase != "ready" || char == null) return result.error("not_ready", null, null)
        if ((enabled && (token <= lastAudio || desiredAudio != null)) || (!enabled && token != lastAudio)) {
            return result.error("stale", null, null)
        }
        desiredAudio = if (enabled) token else null
        if (enabled) lastAudio = token
        notify(char, enabled) {
            if (it == null) result.error("audio_subscription", null, null)
            else {
                confirmedAudio = if (enabled) token else null
                result.success(null)
            }
        }
    }

    private fun settingSupported(name: String): Boolean = when (name) {
        "led" -> (features ?: 0) and Cv1Uuid.ledMask != 0
        "gain" -> (features ?: 0) and Cv1Uuid.gainMask != 0
        else -> false
    }

    private fun sample() {
        if (features == null) {
            val characteristic = characteristic(Cv1Uuid.featuresService, Cv1Uuid.features)
            if (characteristic == null) features = 0
            else {
                val epoch = generation
                read(characteristic) { bytes ->
                    if (epoch == generation) {
                        features = if (bytes != null && bytes.size >= 4)
                            (bytes[0].toInt() and 255) or ((bytes[1].toInt() and 255) shl 8) else 0
                        if (desiredAudio == null && confirmedAudio == null) sample()
                    }
                }
                return
            }
        }
        val fields = listOf(
            Triple(Cv1Uuid.batteryService, Cv1Uuid.battery, "battery"),
            Triple(Cv1Uuid.deviceInfo, Cv1Uuid.firmware, "firmware"),
            Triple(Cv1Uuid.deviceInfo, Cv1Uuid.hardware, "hardware"),
            Triple(Cv1Uuid.deviceInfo, Cv1Uuid.model, "model"),
            Triple(Cv1Uuid.deviceInfo, Cv1Uuid.manufacturer, "manufacturer"),
            Triple(Cv1Uuid.settings, Cv1Uuid.led, "led"),
            Triple(Cv1Uuid.settings, Cv1Uuid.gain, "gain"),
            Triple(Cv1Uuid.settings, Cv1Uuid.charging, "charging"),
        )
        val epoch = generation
        for ((service, id, name) in fields) {
            if (name in setOf("led", "gain") && !settingSupported(name)) continue
            if (name == "charging" && (features ?: 0) == 0) continue
            if (name in stats && name in setOf("firmware", "hardware", "model", "manufacturer")) continue
            val char = characteristic(service, id) ?: continue
            if (char.properties and BluetoothGattCharacteristic.PROPERTY_READ == 0) continue
            enqueue(Job(char.uuid, "read", { connection ->
                desiredAudio == null && confirmedAudio == null && connection.readCharacteristic(char)
            }) { bytes ->
                if (generation != epoch) return@Job
                val value = when (name) {
                    "battery", "led", "gain" -> bytes?.firstOrNull()?.toInt()?.and(0xff)?.takeIf { it in 0..100 }
                    "charging" -> bytes?.firstOrNull()?.let { it.toInt() == 1 }
                    else -> bytes?.takeIf { it.size <= 64 }?.toString(Charsets.UTF_8)?.trim('\u0000', ' ')?.takeIf { it.isNotEmpty() }
                }
                if (value != null) stats[name] = value
                else if (name == "battery") return@Job
                else stats.remove(name)
                if (char.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0 && name in setOf("led", "gain")) {
                    stats["${name}Writable"] = true
                }
                telemetry(if (name == "battery") name else null)
            })
        }
    }

    // The controller RSSI read is separate from the ATT characteristic queue.
    // A failed or unanswered observation never restarts the audio connection.
    private fun sampleSignal() {
        if (phase != "ready" || rssiPending || active != null || operations.isNotEmpty()) return
        rssiPending = runCatching { gatt?.readRemoteRssi() == true }.getOrDefault(false)
    }

    private fun writeSetting(call: MethodCall, result: MethodChannel.Result) {
        val field = call.argument<String>("field")
        val value = call.argument<Int>("value")
        val id = when (field) {
            "led" -> Cv1Uuid.led
            "gain" -> Cv1Uuid.gain
            else -> return result.error("unsupported_setting", null, null)
        }
        val char = characteristic(Cv1Uuid.settings, id)
        if (value == null || value !in 0..(if (field == "gain") 8 else 100) ||
            !settingSupported(field) || call.argument<Int>("generation") != generation ||
            phase != "ready" || desiredAudio != null || confirmedAudio != null ||
            char == null || char.properties and BluetoothGattCharacteristic.PROPERTY_WRITE == 0) {
            return result.error("setting_unavailable", null, null)
        }
        val payload = byteArrayOf(value.toByte())
        enqueue(Job(char.uuid, "write", { connection ->
            if (desiredAudio != null || confirmedAudio != null) false
            else if (Build.VERSION.SDK_INT >= 33) {
                connection.writeCharacteristic(char, payload, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) ==
                    BluetoothStatusCodes.SUCCESS
            } else {
                char.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                @Suppress("DEPRECATION")
                char.value = payload
                @Suppress("DEPRECATION")
                connection.writeCharacteristic(char)
            }
        }) {
            if (it == null) result.error("setting_write", null, null)
            else {
                stats[field] = value
                telemetry()
                result.success(null)
            }
        })
    }

    private val callbacks = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(connection: BluetoothGatt, status: Int, newState: Int) {
            handler.post {
                if (gatt !== connection) return@post
                if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
                    if (!connection.requestMtu(247)) discover(connection)
                    else after(5000) { discover(connection) }
                } else if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                    val reason = when {
                        adapter?.isEnabled == false -> "radio"
                        status == 8 -> "timeout"
                        status == 19 && phase == "ready" -> "remote"
                        phase == "ready" -> "dropped"
                        else -> "connect"
                    }
                    lost(true, reason, status)
                }
            }
        }

        override fun onMtuChanged(connection: BluetoothGatt, mtu: Int, status: Int) {
            handler.post {
                if (gatt === connection && codec == null && active == null) discover(connection)
            }
        }

        override fun onServicesDiscovered(connection: BluetoothGatt, status: Int) {
            handler.post {
                if (gatt === connection) {
                    if (status == BluetoothGatt.GATT_SUCCESS) configured(connection) else lost(true, "connect", status)
                }
            }
        }

        override fun onDescriptorWrite(connection: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            handler.post { finish(connection, "descriptor", descriptor.characteristic.uuid, success(status)) }
        }

        override fun onCharacteristicWrite(connection: BluetoothGatt, char: BluetoothGattCharacteristic, status: Int) {
            handler.post { finish(connection, "write", char.uuid, success(status)) }
        }

        override fun onReadRemoteRssi(connection: BluetoothGatt, rssi: Int, status: Int) {
            handler.post {
                if (gatt !== connection || !rssiPending) return@post
                rssiPending = false
                if (status == BluetoothGatt.GATT_SUCCESS && rssi in -127..-1) stats["rssi"] = rssi
                else stats.remove("rssi")
                telemetry("rssi")
            }
        }

        override fun onCharacteristicRead(connection: BluetoothGatt, char: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            handler.post { finish(connection, "read", char.uuid, value.takeIf { status == 0 }) }
        }

        @Deprecated("Android 12 and earlier")
        override fun onCharacteristicRead(connection: BluetoothGatt, char: BluetoothGattCharacteristic, status: Int) {
            @Suppress("DEPRECATION")
            onCharacteristicRead(connection, char, char.value?.copyOf() ?: byteArrayOf(), status)
        }

        override fun onCharacteristicChanged(connection: BluetoothGatt, char: BluetoothGattCharacteristic, value: ByteArray) {
            handler.post {
                if (gatt !== connection || phase != "ready") return@post
                if (char.uuid == Cv1Uuid.battery) {
                    val level = value.firstOrNull()?.toInt()?.and(0xff)?.takeIf { it in 0..100 } ?: return@post
                    stats["battery"] = level
                    telemetry("battery")
                } else if (char.uuid == Cv1Uuid.button && value.size >= 4) {
                    val code = (0..3).fold(0) { a, i -> a or ((value[i].toInt() and 0xff) shl (8*i)) }
                    if (code >= 0) sink?.success(mapOf("type" to "button", "generation" to generation, "code" to code))
                } else if (char.uuid == Cv1Uuid.audio && value.isNotEmpty()) {
                    val token = desiredAudio?.takeIf { it == confirmedAudio } ?: return@post
                    sink?.success(mapOf("type" to "audio", "generation" to generation, "subscription" to token, "bytes" to value))
                }
            }
        }

        @Deprecated("Android 12 and earlier")
        override fun onCharacteristicChanged(connection: BluetoothGatt, char: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION")
            onCharacteristicChanged(connection, char, char.value?.copyOf() ?: byteArrayOf())
        }
    }

    private fun success(status: Int): ByteArray? = if (status == BluetoothGatt.GATT_SUCCESS) byteArrayOf() else null
}
