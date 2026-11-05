package com.shca.shca

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

internal class EmergencyLocationChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val owner: () -> String,
) {
    private var pending: Pair<String, MethodChannel.Result>? = null

    init {
        MethodChannel(messenger, "com.shca.shca/emergency_location").setMethodCallHandler { call, result ->
            val uid = owner()
            when (call.method) {
                "status" -> result.success(EmergencyLocation.status(activity, uid))
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    when {
                        uid.isBlank() -> result.success(EmergencyLocation.status(activity, uid))
                        !enabled || EmergencyLocation.hasPermission(activity) -> {
                            EmergencyLocation.setEnabled(activity, uid, enabled)
                            result.success(EmergencyLocation.status(activity, uid))
                        }
                        pending != null -> result.error("permission-pending", "Location permission is already open.", null)
                        else -> {
                            pending = uid to result
                            activity.requestPermissions(arrayOf(
                                Manifest.permission.ACCESS_FINE_LOCATION,
                                Manifest.permission.ACCESS_COARSE_LOCATION,
                            ), REQUEST_CODE)
                        }
                    }
                }
                "openSettings" -> {
                    activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:${activity.packageName}")))
                    result.success(null)
                }
                "capture" -> Thread {
                    val location = EmergencyLocation.capture(activity.applicationContext, uid, "phone")
                    activity.runOnUiThread { result.success(if (owner() == uid) location else null) }
                }.start()
                else -> result.notImplemented()
            }
        }
    }

    fun permissionResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val request = pending ?: return true
        pending = null
        if (owner() == request.first && EmergencyLocation.hasPermission(activity)) {
            EmergencyLocation.setEnabled(activity, request.first, true)
        }
        request.second.success(EmergencyLocation.status(activity, owner()))
        return true
    }

    companion object {
        private const val REQUEST_CODE = 9462
    }
}
