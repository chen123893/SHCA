package com.shca.shca

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.util.Log
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.google.android.gms.tasks.Tasks
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.FirebaseFirestoreException
import com.google.firebase.firestore.Source
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/** Sends fall and SOS texts using the elderly phone's default SMS SIM. */
class FallSmsWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
    override fun doWork(): Result {
        val context = applicationContext
        val uid = inputData.getString("uid") ?: return Result.failure()
        val eventId = inputData.getString("eventId") ?: return Result.failure()
        val detectedAt = inputData.getLong("detectedAt", 0)
        val location = EmergencyLocation.fromJson(inputData.getString("locationJson"))
        val message = EmergencySmsMessage.format(inputData.getBoolean("manualSos", false), location)
        if (!canSend(context, uid, detectedAt)) return Result.success()

        val subscription = SubscriptionManager.getDefaultSmsSubscriptionId()
        if (subscription < 0) {
            Log.w(TAG, "Fall SMS needs a default SMS SIM.")
            return Result.failure()
        }

        return try {
            val db = FirebaseFirestore.getInstance()
            val links = Tasks.await(db.collection("care_links")
                .whereEqualTo("elderlyId", uid)
                .whereEqualTo("status", "active")
                .get(Source.SERVER), 20, TimeUnit.SECONDS)
            val contacts = links.documents.mapNotNull { it.getString("caregiverId") }
                .distinct()
                .map { db.collection("caregiver_sms_contacts").document(it).get(Source.SERVER) }
            Tasks.await(Tasks.whenAllComplete(contacts), 20, TimeUnit.SECONDS)

            val phones = contacts.mapNotNull { task ->
                if (task.isSuccessful) {
                    task.result.getString("phone")?.takeIf { PHONE.matches(it) }
                } else {
                    val error = task.exception
                    // A link may have been removed while the reads were in flight.
                    if (error is FirebaseFirestoreException &&
                        error.code == FirebaseFirestoreException.Code.PERMISSION_DENIED) null
                    else throw error ?: IllegalStateException("SMS contact lookup failed")
                }
            }.distinct()

            @Suppress("DEPRECATION")
            val sms = if (Build.VERSION.SDK_INT >= 31) {
                context.getSystemService(SmsManager::class.java).createForSubscriptionId(subscription)
            } else {
                SmsManager.getSmsManagerForSubscriptionId(subscription)
            }

            for (phone in phones) {
                if (!canSend(context, uid, detectedAt)) break
                val key = digest("$uid/$eventId/$phone")
                if (!claim(context, key)) continue
                try {
                    val parts = sms.divideMessage(message)
                    val callbacks = ArrayList(parts.indices.map { index ->
                        PendingIntent.getBroadcast(context, 0,
                            Intent(context, FallSmsSentReceiver::class.java)
                                .setData(Uri.parse("shca-fall-sms:$key/$index"))
                                .putExtra("partIndex", index).putExtra("partCount", parts.size),
                            PendingIntent.FLAG_IMMUTABLE)
                    })
                    if (parts.size == 1) sms.sendTextMessage(phone, null, message, callbacks[0], null)
                    else sms.sendMultipartTextMessage(phone, null, parts, callbacks, null)
                } catch (error: Exception) {
                    Log.w(TAG, "Fall SMS submission failed: ${error.javaClass.simpleName}")
                }
            }
            Result.success()
        } catch (error: Exception) {
            Log.w(TAG, "Fall SMS worker failed: ${error.javaClass.simpleName}")
            if (runAttemptCount < 3) Result.retry() else Result.failure()
        }
    }

    companion object {
        private const val TAG = "SHCAFallSms"
        private const val PREFS = "shca_fall_sms"
        private const val MAX_AGE = 15 * 60_000L
        private val PHONE = Regex("^[+][1-9][0-9]{8,14}$")

        fun hasPermission(context: Context) =
            context.checkSelfPermission(Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED

        fun isEnabled(context: Context, uid: String) = hasPermission(context) &&
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("enabled:$uid", false)

        fun setEnabled(context: Context, uid: String, enabled: Boolean) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean("enabled:$uid", enabled).apply()
        }

        private fun canSend(context: Context, uid: String, detectedAt: Long) =
            FirebaseAuth.getInstance().currentUser?.uid == uid &&
                isEnabled(context, uid) &&
                System.currentTimeMillis() - detectedAt in 0..MAX_AGE

        fun enqueue(context: Context, uid: String, eventId: String, detectedAt: Long, manualSos: Boolean = false, location: Map<String, Any>? = null): Boolean {
            if (!canSend(context, uid, detectedAt)) return false
            return try {
                val request = OneTimeWorkRequestBuilder<FallSmsWorker>()
                    .setInputData(workDataOf("uid" to uid, "eventId" to eventId, "detectedAt" to detectedAt, "manualSos" to manualSos,
                        "locationJson" to location?.let { org.json.JSONObject(it).toString() }))
                    .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                    .build()
                WorkManager.getInstance(context).enqueueUniqueWork(
                    "fall-sms-${digest("$uid/$eventId")}", ExistingWorkPolicy.KEEP, request)
                true
            } catch (error: Exception) {
                Log.w(TAG, "Could not queue emergency SMS: ${error.javaClass.simpleName}")
                false
            }
        }

        // Claim before calling the modem to prevent duplicate texts after an ambiguous
        // submission or a process restart. Store only a hash, never the phone number.
        @Synchronized
        private fun claim(context: Context, key: String): Boolean {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val entry = "sent:$key"
            if (prefs.contains(entry)) return false
            val now = System.currentTimeMillis()
            val editor = prefs.edit().putLong(entry, now)
            for ((name, value) in prefs.all) {
                if (name.startsWith("sent:") && value is Long && now - value > MAX_AGE) {
                    editor.remove(name)
                }
            }
            return editor.commit()
        }

        private fun digest(value: String) = MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
    }
}

class FallSmsSentReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val part = intent.getIntExtra("partIndex", 0) + 1
        val count = intent.getIntExtra("partCount", 1)
        if (resultCode == Activity.RESULT_OK) Log.i("SHCAFallSms", "SMS part $part/$count accepted by the phone network.")
        else Log.w("SHCAFallSms", "SMS part $part/$count failed with result $resultCode.")
    }
}
