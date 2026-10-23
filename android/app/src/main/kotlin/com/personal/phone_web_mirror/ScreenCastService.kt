package com.personal.phone_web_mirror

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.ImageReader
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.DisplayMetrics
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/** Captures screen + audio and pushes frames to [FrameBus] for the browser server. */
class ScreenCastService : Service() {
    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var handlerThread: HandlerThread? = null
    private var handler: Handler? = null
    private var audioRecord: AudioRecord? = null
    private val running = AtomicBoolean(false)
    private var lastSentMs = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopCast()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                val code = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
                val data = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(EXTRA_DATA, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(EXTRA_DATA)
                }
                if (data == null) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                startForegroundNotification()
                startCast(code, data)
            }
        }
        return START_STICKY
    }

    private fun startForegroundNotification() {
        val channelId = "phone_web_mirror"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(
                NotificationChannel(channelId, "Web Mirror", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val notification: Notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle("Phone Web Mirror")
            .setContentText("Streaming to browser on your WiFi…")
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(52, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(52, notification)
        }
    }

    private fun startCast(resultCode: Int, data: Intent) {
        stopCastInternal()
        running.set(true)
        isRunning = true
        try {
            val mpm = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            projection = mpm.getMediaProjection(resultCode, data)
            projection?.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    stopCast()
                    stopSelf()
                }
            }, null)

            val wm = getSystemService(WINDOW_SERVICE) as WindowManager
            val metrics = DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealMetrics(metrics)
            var width = metrics.widthPixels
            var height = metrics.heightPixels
            val density = metrics.densityDpi
            val maxW = 960
            if (width > maxW) {
                val scale = maxW.toFloat() / width
                width = maxW
                height = (height * scale).toInt().coerceAtLeast(1)
            }

            handlerThread = HandlerThread("web-mirror-frames").also { it.start() }
            handler = Handler(handlerThread!!.looper)

            imageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
            imageReader?.setOnImageAvailableListener({ reader ->
                if (!running.get()) return@setOnImageAvailableListener
                val now = System.currentTimeMillis()
                if (now - lastSentMs < 80) {
                    reader.acquireLatestImage()?.close()
                    return@setOnImageAvailableListener
                }
                lastSentMs = now
                val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
                try {
                    val plane = image.planes[0]
                    val buffer = plane.buffer
                    val pixelStride = plane.pixelStride
                    val rowStride = plane.rowStride
                    val rowPadding = rowStride - pixelStride * width
                    val bitmap = Bitmap.createBitmap(
                        width + rowPadding / pixelStride,
                        height,
                        Bitmap.Config.ARGB_8888
                    )
                    bitmap.copyPixelsFromBuffer(buffer)
                    val cropped = Bitmap.createBitmap(bitmap, 0, 0, width, height)
                    if (cropped !== bitmap) bitmap.recycle()
                    val baos = ByteArrayOutputStream()
                    cropped.compress(Bitmap.CompressFormat.JPEG, 60, baos)
                    cropped.recycle()
                    FrameBus.emit(FrameBus.TYPE_VIDEO, baos.toByteArray())
                } catch (_: Exception) {
                } finally {
                    image.close()
                }
            }, handler)

            virtualDisplay = projection?.createVirtualDisplay(
                "PhoneWebMirror",
                width,
                height,
                density,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                imageReader?.surface,
                null,
                handler
            )
            startAudioCapture(projection!!)
        } catch (_: Exception) {
            stopCast()
            stopSelf()
        }
    }

    private fun startAudioCapture(projection: MediaProjection) {
        val sampleRate = 44100
        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minBuf = AudioRecord.getMinBufferSize(sampleRate, channelConfig, encoding)
        if (minBuf <= 0) return
        val bufferSize = minBuf * 2

        val recorder: AudioRecord? = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val playbackConfig = AudioPlaybackCaptureConfiguration.Builder(projection)
                    .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                    .addMatchingUsage(AudioAttributes.USAGE_GAME)
                    .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                    .build()
                AudioRecord.Builder()
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(encoding)
                            .setSampleRate(sampleRate)
                            .setChannelMask(channelConfig)
                            .build()
                    )
                    .setBufferSizeInBytes(bufferSize)
                    .setAudioPlaybackCaptureConfig(playbackConfig)
                    .build()
            } else {
                @Suppress("DEPRECATION")
                AudioRecord(MediaRecorder.AudioSource.MIC, sampleRate, channelConfig, encoding, bufferSize)
            }
        } catch (_: Exception) {
            try {
                @Suppress("DEPRECATION")
                AudioRecord(MediaRecorder.AudioSource.MIC, sampleRate, channelConfig, encoding, bufferSize)
            } catch (_: Exception) {
                null
            }
        }

        if (recorder == null || recorder.state != AudioRecord.STATE_INITIALIZED) {
            try {
                recorder?.release()
            } catch (_: Exception) {
            }
            return
        }
        audioRecord = recorder
        recorder.startRecording()
        thread(name = "web-mirror-audio", isDaemon = true) {
            val buf = ByteArray(bufferSize)
            while (running.get()) {
                val n = try {
                    recorder.read(buf, 0, buf.size)
                } catch (_: Exception) {
                    break
                }
                if (n > 0) {
                    FrameBus.emit(FrameBus.TYPE_AUDIO, buf.copyOf(n))
                } else if (n < 0) {
                    break
                }
            }
        }
    }

    private fun stopCast() {
        running.set(false)
        isRunning = false
        stopCastInternal()
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    private fun stopCastInternal() {
        try {
            audioRecord?.stop()
        } catch (_: Exception) {
        }
        try {
            audioRecord?.release()
        } catch (_: Exception) {
        }
        audioRecord = null
        try {
            virtualDisplay?.release()
        } catch (_: Exception) {
        }
        virtualDisplay = null
        try {
            imageReader?.close()
        } catch (_: Exception) {
        }
        imageReader = null
        try {
            projection?.stop()
        } catch (_: Exception) {
        }
        projection = null
        try {
            handlerThread?.quitSafely()
        } catch (_: Exception) {
        }
        handlerThread = null
        handler = null
    }

    override fun onDestroy() {
        stopCast()
        super.onDestroy()
    }

    companion object {
        const val ACTION_START = "com.personal.phone_web_mirror.START"
        const val ACTION_STOP = "com.personal.phone_web_mirror.STOP"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_DATA = "data"

        @Volatile
        var isRunning: Boolean = false
    }
}
