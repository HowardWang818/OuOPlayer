package com.ouo.ouoplayer

import android.annotation.SuppressLint
import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Output-device info, Bluetooth discovery/pairing and A2DP connect for the Devices page,
 * plus connection events used for auto-play.
 */
@SuppressLint("MissingPermission")
class BluetoothPlugin(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val method = MethodChannel(messenger, "ouo/bluetooth")
    private val events = EventChannel(messenger, "ouo/bluetooth/events")
    private val main = Handler(Looper.getMainLooper())
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val adapter: BluetoothAdapter? = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
    private var a2dp: BluetoothA2dp? = null
    private var sink: EventChannel.EventSink? = null
    private var receiverRegistered = false

    init {
        method.setMethodCallHandler(this)
        events.setStreamHandler(this)
        try {
            adapter?.getProfileProxy(context, object : BluetoothProfile.ServiceListener {
                override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                    if (profile == BluetoothProfile.A2DP) a2dp = proxy as BluetoothA2dp
                }

                override fun onServiceDisconnected(profile: Int) {
                    if (profile == BluetoothProfile.A2DP) a2dp = null
                }
            }, BluetoothProfile.A2DP)
        } catch (_: SecurityException) {
        }
    }

    // ---------- output device ----------
    private fun currentOutput(): Map<String, Any?> {
        val devices = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        fun pick(vararg types: Int) = devices.firstOrNull { it.type in types }
        val bt = pick(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER)
        if (bt != null) return mapOf("name" to bt.productName.toString(), "kind" to "bluetooth")
        val wired = pick(AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET)
        if (wired != null) return mapOf("name" to "有線耳機", "kind" to "wired")
        val usb = pick(AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_DEVICE)
        if (usb != null) return mapOf("name" to usb.productName.toString().ifBlank { "USB 音訊" }, "kind" to "usb")
        return mapOf("name" to "這台裝置", "kind" to "speaker")
    }

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
            emitOutput()
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
            emitOutput()
        }
    }

    private fun emitOutput() {
        emit(mapOf("type" to "output") + currentOutput())
    }

    // ---------- bluetooth helpers ----------
    private fun isAudio(d: BluetoothDevice): Boolean = try {
        d.bluetoothClass?.majorDeviceClass == BluetoothClass.Device.Major.AUDIO_VIDEO
    } catch (_: Exception) {
        true
    }

    private fun deviceMap(d: BluetoothDevice): Map<String, Any?> = try {
        mapOf(
            "name" to (d.name ?: ""),
            "address" to d.address,
            "bonded" to (d.bondState == BluetoothDevice.BOND_BONDED),
            "connected" to (a2dp?.connectedDevices?.any { it.address == d.address } == true),
            "audio" to isAudio(d),
        )
    } catch (_: SecurityException) {
        mapOf("name" to "", "address" to d.address)
    }

    private fun device(address: String): BluetoothDevice? = adapter?.getRemoteDevice(address)

    private fun callHidden(name: String, d: BluetoothDevice): Boolean {
        val proxy = a2dp ?: return false
        return try {
            BluetoothA2dp::class.java.getMethod(name, BluetoothDevice::class.java).invoke(proxy, d) as? Boolean ?: false
        } catch (_: Throwable) {
            false
        }
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            val dev: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            } else {
                @Suppress("DEPRECATION") intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
            }
            when (intent.action) {
                BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED -> {
                    val state = intent.getIntExtra(BluetoothProfile.EXTRA_STATE, -1)
                    if (dev != null && (state == BluetoothProfile.STATE_CONNECTED || state == BluetoothProfile.STATE_DISCONNECTED)) {
                        emit(mapOf("type" to "a2dp") + deviceMap(dev) + mapOf("connected" to (state == BluetoothProfile.STATE_CONNECTED)))
                    }
                    main.postDelayed({ emitOutput() }, 800)
                }
                BluetoothDevice.ACTION_FOUND -> if (dev != null) emit(mapOf("type" to "found") + deviceMap(dev))
                BluetoothDevice.ACTION_BOND_STATE_CHANGED -> if (dev != null) {
                    emit(mapOf("type" to "bond") + deviceMap(dev))
                    // Newly paired audio device: try to connect it straight away.
                    if (dev.bondState == BluetoothDevice.BOND_BONDED && isAudio(dev)) callHidden("connect", dev)
                }
                BluetoothAdapter.ACTION_DISCOVERY_STARTED -> emit(mapOf("type" to "scan", "running" to true))
                BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> emit(mapOf("type" to "scan", "running" to false))
            }
        }
    }

    private fun emit(data: Map<String, Any?>) = main.post { sink?.success(data) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "currentOutput" -> result.success(currentOutput())
                "isEnabled" -> result.success(adapter?.isEnabled == true)
                "requestEnable" -> {
                    context.startActivity(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "bondedDevices" -> result.success(adapter?.bondedDevices?.map { deviceMap(it) } ?: emptyList<Any>())
                "startScan" -> {
                    if (adapter?.isDiscovering == true) adapter.cancelDiscovery()
                    result.success(adapter?.startDiscovery() == true)
                }
                "stopScan" -> result.success(adapter?.cancelDiscovery() == true)
                "pair" -> {
                    adapter?.cancelDiscovery()
                    result.success(device(call.argument("address")!!)?.createBond() == true)
                }
                "connect" -> {
                    adapter?.cancelDiscovery()
                    val d = device(call.argument("address")!!)
                    result.success(d != null && callHidden("connect", d))
                }
                "disconnect" -> {
                    val d = device(call.argument("address")!!)
                    result.success(d != null && callHidden("disconnect", d))
                }
                "openSettings" -> {
                    context.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: SecurityException) {
            result.error("permission", e.message, null)
        } catch (e: Exception) {
            result.error("bluetooth", e.message, null)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        audio.registerAudioDeviceCallback(deviceCallback, main)
        if (!receiverRegistered) {
            val filter = IntentFilter().apply {
                addAction(BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED)
                addAction(BluetoothDevice.ACTION_FOUND)
                addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
                addAction(BluetoothAdapter.ACTION_DISCOVERY_STARTED)
                addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
            }
            if (Build.VERSION.SDK_INT >= 33) {
                context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                context.registerReceiver(receiver, filter)
            }
            receiverRegistered = true
        }
        emitOutput()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        dispose()
    }

    fun dispose() {
        audio.unregisterAudioDeviceCallback(deviceCallback)
        if (receiverRegistered) {
            try {
                context.unregisterReceiver(receiver)
            } catch (_: Exception) {
            }
            receiverRegistered = false
        }
    }
}
