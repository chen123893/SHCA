package com.shca.shca

import android.content.Context
import android.media.AudioAttributes
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

object WatchAlertVibration {
    private val FALL_PATTERN = longArrayOf(0, 800, 250, 800, 700)
    private val BACKGROUND_FALL_PATTERN =
        longArrayOf(0, 800, 250, 800, 250, 800, 700, 800, 250, 800)

    @Suppress("DEPRECATION")
    private fun vibrator(context: Context): Vibrator =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(VibratorManager::class.java).defaultVibrator
        } else {
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }

    private fun vibrate(context: Context, pattern: LongArray, repeat: Int) {
        vibrator(context).vibrate(
            VibrationEffect.createWaveform(pattern, repeat),
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ALARM)
                .build(),
        )
    }

    fun startFallCountdown(context: Context) {
        vibrate(context, FALL_PATTERN, 0)
    }

    fun signalBackgroundFall(context: Context) {
        vibrate(context, BACKGROUND_FALL_PATTERN, -1)
    }

    fun stop(context: Context) {
        vibrator(context).cancel()
    }
}
