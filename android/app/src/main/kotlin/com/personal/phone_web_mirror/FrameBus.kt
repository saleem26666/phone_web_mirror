package com.personal.phone_web_mirror

import io.flutter.plugin.common.EventChannel

/** Native → Flutter frame bridge (video JPEG / audio PCM). */
object FrameBus {
    @Volatile
    var eventSink: EventChannel.EventSink? = null

    const val TYPE_VIDEO = 1
    const val TYPE_AUDIO = 2

    fun emit(type: Int, payload: ByteArray) {
        val sink = eventSink ?: return
        val packet = ByteArray(payload.size + 1)
        packet[0] = type.toByte()
        System.arraycopy(payload, 0, packet, 1, payload.size)
        try {
            // EventChannel must be called on main thread
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                try {
                    sink.success(packet)
                } catch (_: Exception) {
                }
            }
        } catch (_: Exception) {
        }
    }
}
