package com.ouo.ouoplayer

import android.content.Context
import androidx.car.app.connection.CarConnection
import androidx.lifecycle.Observer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * Whether Android Auto is showing the phone right now, so lyrics can go to
 * the car and the phone's notification separately (both read the same media
 * session).
 */
class CarConnectionPlugin(context: Context, messenger: BinaryMessenger) : EventChannel.StreamHandler {
    private val connection = CarConnection(context)
    private var observer: Observer<Int>? = null

    init {
        EventChannel(messenger, "ouo/car").setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val o = Observer<Int> { type -> events.success(type != CarConnection.CONNECTION_TYPE_NOT_CONNECTED) }
        observer = o
        connection.type.observeForever(o)
    }

    override fun onCancel(arguments: Any?) {
        observer?.let { connection.type.removeObserver(it) }
        observer = null
    }
}
