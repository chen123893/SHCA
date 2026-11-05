package com.shca.shca

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.telecom.TelecomManager
import android.util.Log

internal object EmergencyContactCall {
    private const val EVENT_WINDOW_MS = 15 * 60_000L

    fun normalize(phone: String?): String? =
        phone?.trim()?.replace(Regex("[ ()-]"), "")?.takeIf { it.matches(Regex("[+]?[0-9]{7,15}")) }

    @Synchronized
    fun request(context: Context, phone: String?, eventId: String? = null, occurredAt: Long = 0): Boolean {
        val number = normalize(phone) ?: return false
        if (context.checkSelfPermission(Manifest.permission.CALL_PHONE) != PackageManager.PERMISSION_GRANTED) {
            return false
        }
        val telecom = context.getSystemService(TelecomManager::class.java) ?: return false
        val now = System.currentTimeMillis()
        val receipts = context.getSharedPreferences("shca_emergency_call_receipts", Context.MODE_PRIVATE)
        if (eventId != null) {
            if (kotlin.math.abs(now - occurredAt) > EVENT_WINDOW_MS) return false
            if (receipts.contains(eventId)) return true
            // Persist the claim before asking Telecom so a delivery retry cannot redial.
            val update = receipts.edit()
            for ((id, time) in receipts.all) {
                if (time is Long && now - time > EVENT_WINDOW_MS) update.remove(id)
            }
            if (!update.putLong(eventId, now).commit()) return false
        }
        return try {
            telecom.placeCall(Uri.fromParts("tel", number, null), Bundle())
            true
        } catch (error: RuntimeException) {
            if (eventId != null) receipts.edit().remove(eventId).commit()
            Log.w("EmergencyContactCall", "Telecom rejected the call request")
            false
        }
    }
}
