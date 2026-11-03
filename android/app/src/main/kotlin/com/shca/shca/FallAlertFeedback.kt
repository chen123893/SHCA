package com.shca.shca

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log

/** Local warning for bystanders during the possible-fall confirmation countdown. */
object FallAlertFeedback {
    private const val TAG = "FallAlertFeedback"
    private val handler = Handler(Looper.getMainLooper())
    private var active = false
    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private var audio: AudioManager? = null
    private var focus: AudioFocusRequest? = null
    private var previousAlarmVolume: Int? = null
    private var raisedAlarmVolume: Int? = null
    private var deadline: Runnable? = null
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ALARM)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    @Suppress("DEPRECATION")
    fun start(context: Context, durationMillis: Long) {
        if (active) return
        active = true
        val app = context.applicationContext
        val manager = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audio = manager
        val timeout = durationMillis.coerceIn(1000L, 300000L) + 1000L
        deadline = Runnable { stop() }.also { handler.postDelayed(it, timeout) }

        // Vibration remains available even when Android cannot start audio.
        try {
            val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                app.getSystemService(VibratorManager::class.java).defaultVibrator
            } else {
                app.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }
            vibrator = device
            val pattern = longArrayOf(0, 700, 250, 700, 850)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                device.vibrate(VibrationEffect.createWaveform(pattern, 0), attributes)
            } else {
                device.vibrate(pattern, 0, attributes)
            }
        } catch (error: Exception) {
            Log.w(TAG, "Fall vibration could not start", error)
        }

        try {
            if (!manager.isVolumeFixed) {
                val original = manager.getStreamVolume(AudioManager.STREAM_ALARM)
                val maximum = manager.getStreamMaxVolume(AudioManager.STREAM_ALARM)
                if (original < maximum) {
                    previousAlarmVolume = original
                    manager.setStreamVolume(AudioManager.STREAM_ALARM, maximum, 0)
                    raisedAlarmVolume = manager.getStreamVolume(AudioManager.STREAM_ALARM)
                }
            }
        } catch (error: Exception) {
            // DND and other system audio policies must not break the countdown.
            Log.w(TAG, "Keeping the system alarm volume", error)
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                    .setAudioAttributes(attributes)
                    .setOnAudioFocusChangeListener { change ->
                        when (change) {
                            AudioManager.AUDIOFOCUS_LOSS -> stop()
                            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> player?.pause()
                            AudioManager.AUDIOFOCUS_GAIN -> if (active) player?.start()
                        }
                    }
                    .build()
                focus = request
                manager.requestAudioFocus(request)
            }
            val warning = MediaPlayer.create(app, R.raw.fall_alert_siren, attributes, 0)
                ?: throw IllegalStateException("The fall warning sound could not be loaded.")
            player = warning
            manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                ?.let { warning.setPreferredDevice(it) }
            warning.isLooping = true
            warning.setVolume(1f, 1f)
            warning.start()
            Log.i(TAG, "Fall siren started with repeating vibration")
        } catch (error: Exception) {
            Log.e(TAG, "Fall siren could not start; countdown and vibration continue", error)
            player?.release()
            player = null
        }
    }

    fun stop() {
        if (!active) return
        active = false
        deadline?.let(handler::removeCallbacks)
        deadline = null
        player?.release()
        player = null
        vibrator?.cancel()
        vibrator = null
        val manager = audio
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focus?.let { manager?.abandonAudioFocusRequest(it) }
        }
        focus = null
        val previous = previousAlarmVolume
        val raised = raisedAlarmVolume
        try {
            // Keep a volume change the user made while the warning was sounding.
            if (manager != null && previous != null && raised != null &&
                manager.getStreamVolume(AudioManager.STREAM_ALARM) == raised
            ) {
                manager.setStreamVolume(AudioManager.STREAM_ALARM, previous, 0)
            }
        } catch (error: Exception) {
            Log.w(TAG, "Could not restore the prior alarm volume", error)
        }
        previousAlarmVolume = null
        raisedAlarmVolume = null
        audio = null
        Log.i(TAG, "Fall siren and vibration stopped")
    }
}
