package com.shca.shca

import android.content.Context
import android.media.AudioAttributes
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

object AlertVibration {
    private val FALL_PATTERN = longArrayOf(0, 700, 250, 700, 850)

    // Get the vibration service supported by this Android version.
    @Suppress("DEPRECATION")
    private fun vibrator(context: Context): Vibrator =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(VibratorManager::class.java).defaultVibrator
        } else {
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }

    // Start the phone's fall-alert vibration pattern.
    fun startFall(context: Context) {
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .build()
        vibrator(context).vibrate(
            VibrationEffect.createWaveform(FALL_PATTERN, 0),
            attributes,
        )
    }

    // Stop the current alert vibration.
    fun stop(context: Context) {
        vibrator(context).cancel()
    }
}
