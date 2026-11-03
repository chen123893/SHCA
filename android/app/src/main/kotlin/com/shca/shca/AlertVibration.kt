package com.shca.shca

import android.content.Context
import android.media.AudioAttributes
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

object AlertVibration {
    private val FALL_PATTERN = longArrayOf(0, 700, 250, 700, 850)

    @Suppress("DEPRECATION")
    private fun vibrator(context: Context): Vibrator =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(VibratorManager::class.java).defaultVibrator
        } else {
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }

    fun startFall(context: Context) {
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .build()
        vibrator(context).vibrate(
            VibrationEffect.createWaveform(FALL_PATTERN, 0),
            attributes,
        )
    }

    fun stop(context: Context) {
        vibrator(context).cancel()
    }
}
