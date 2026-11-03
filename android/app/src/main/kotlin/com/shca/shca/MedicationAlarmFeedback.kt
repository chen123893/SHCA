package com.shca.shca

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log

/** Owns playback while the medicine alert is ringing, independent of notifications. */
object MedicationAlarmFeedback {
    private const val TAG = "MedicationAlarmFeedback"
    private val handler = Handler(Looper.getMainLooper())
    private var activeKey: String? = null
    private var player: MediaPlayer? = null
    private var alarmVibrator: Vibrator? = null
    private var audioManager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null
    private var timeout: Runnable? = null
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ALARM)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    @Suppress("DEPRECATION")
    fun start(context: Context, key: String) {
        if (activeKey == key) return
        stop()
        activeKey = key
        val app = context.applicationContext
        val audio = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager = audio
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attributes)
                .setOnAudioFocusChangeListener { change ->
                    if (change == AudioManager.AUDIOFOCUS_LOSS) stop(key)
                }
                .build()
            focusRequest = request
            audio.requestAudioFocus(request)
        }

        val uri = RingtoneManager.getActualDefaultRingtoneUri(app, RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
        var alarmPlayer: MediaPlayer? = null
        try {
            alarmPlayer = MediaPlayer.create(app, uri, null, attributes, 0)
        } catch (error: Exception) {
            Log.w(TAG, "Could not open selected alarm tone; using bundled tone", error)
        }
        if (alarmPlayer == null) {
            alarmPlayer = MediaPlayer.create(app, R.raw.medication_alarm_fallback, attributes, 0)
        }
        player = alarmPlayer
        alarmPlayer?.apply {
            isLooping = true
            setVolume(1f, 1f)
            start()
        }
        Log.i(TAG, "Alarm sound started=${alarmPlayer?.isPlaying == true}")

        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            app.getSystemService(VibratorManager::class.java).defaultVibrator
        } else {
            app.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        alarmVibrator = vibrator
        val pattern = longArrayOf(0, 600, 350, 600, 350, 600, 1000)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createWaveform(pattern, 0), attributes)
        } else {
            vibrator.vibrate(pattern, 0, attributes)
        }
        Log.i(TAG, "Alarm vibration started=${vibrator.hasVibrator()}")
        // Bound unattended ringing without keeping a stale Activity alive.
        timeout = Runnable { stop(key) }.also { handler.postDelayed(it, 5 * 60 * 1000L) }
    }

    fun stop(key: String? = null) {
        // Disposing an older alert must not silence a newer medicine alarm.
        if (key != null && key != activeKey) return
        if (activeKey == null) return
        activeKey = null
        timeout?.let(handler::removeCallbacks)
        timeout = null
        player?.release()
        player = null
        alarmVibrator?.cancel()
        alarmVibrator = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audioManager?.abandonAudioFocusRequest(it) }
        }
        focusRequest = null
        audioManager = null
        Log.i(TAG, "Alarm sound and vibration stopped")
    }
}
