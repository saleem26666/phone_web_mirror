package com.personal.phone_web_mirror

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val methodChannel = "phone_web_mirror/capture"
    private val eventChannel = "phone_web_mirror/frames"
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startCast" -> {
                        pendingResult = result
                        val mpm = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                        startActivityForResult(mpm.createScreenCaptureIntent(), REQ_CAPTURE)
                    }
                    "stopCast" -> {
                        val intent = Intent(this, ScreenCastService::class.java)
                        intent.action = ScreenCastService.ACTION_STOP
                        startService(intent)
                        result.success(true)
                    }
                    "isCasting" -> result.success(ScreenCastService.isRunning)
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannel)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    FrameBus.eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    FrameBus.eventSink = null
                }
            })
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_CAPTURE) return
        val result = pendingResult
        pendingResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result?.error("denied", "Screen capture permission denied", null)
            return
        }
        val intent = Intent(this, ScreenCastService::class.java).apply {
            action = ScreenCastService.ACTION_START
            putExtra(ScreenCastService.EXTRA_RESULT_CODE, resultCode)
            putExtra(ScreenCastService.EXTRA_DATA, data)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        result?.success(true)
    }

    companion object {
        private const val REQ_CAPTURE = 5501
    }
}
