package com.shca.shca

import android.content.Context
import androidx.work.*
import com.google.android.gms.tasks.Tasks
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.Source
import com.google.firebase.Timestamp
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Date
import java.util.concurrent.TimeUnit

/** Durable background processing; never depends on a Flutter screen being open. */
class WatchActionWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val payload = JSONObject(inputData.getString("payload") ?: return Result.failure())
        val id = payload.optString("eventId")
        val node = inputData.getString("node") ?: ""
        val medicine = inputData.getBoolean("medicine", false)
        fun ack(status: String, message: String) = WatchBridge.acknowledge(applicationContext, node, id, status, message, medicine)
        try {
            FirebaseApp.initializeApp(applicationContext)
            val user = FirebaseAuth.getInstance().currentUser
            val target = payload.optString("elderlyId")
            if (user == null || target.isEmpty() || target != user.uid) {
                ack("failed", "Sign in to the linked elderly account on the phone, then retry.")
                return Result.success()
            }
            val db = FirebaseFirestore.getInstance()
            val profile = Tasks.await(db.collection("users").document(user.uid).get(Source.SERVER), 20, TimeUnit.SECONDS)
            if (profile.getString("role") != "elderly") {
                ack("failed", "The paired phone must use the elderly account.")
                return Result.success()
            }
            // Old queued requests must not silently notify hours after the event.
            if (kotlin.math.abs(System.currentTimeMillis() - payload.optLong("createdAt")) > 15 * 60_000) {
                ack("failed", "Request expired. Send a new request if help is still needed.")
                return Result.success()
            }
            if (medicine) {
                val medicationId = payload.optString("medicationId")
                val occurrenceId = payload.optString("occurrenceId")
                val scheduledAt = payload.optLong("scheduledAt")
                if (!occurrenceId.matches(Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}_[A-Za-z0-9_-]+")) ||
                    !occurrenceId.endsWith("_$medicationId") || scheduledAt <= 0) {
                    ack("failed", "This medicine reminder is no longer valid.")
                    return Result.success()
                }
                val scheduleRef = db.collection("medications").document("${user.uid}_$medicationId")
                val recordRef = db.collection("medication_records").document("${user.uid}_$occurrenceId")
                Tasks.await(db.runTransaction { tx ->
                    val schedule = tx.get(scheduleRef)
                    val previous = tx.get(recordRef)
                    if (!schedule.exists() || schedule.getBoolean("active") == false) throw IllegalStateException("Medicine removed")
                    if (previous.getString("status") == "taken" || previous.getString("watchActionId") == id) return@runTransaction null
                    val status = when (payload.optString("action")) { "taken" -> "taken"; "snoozed" -> "snoozed"; else -> throw IllegalArgumentException("Invalid medicine action") }
                    val values = hashMapOf<String, Any?>("elderlyId" to user.uid, "medicationId" to medicationId,
                        "recordKey" to occurrenceId, "scheduledAt" to (previous.getTimestamp("scheduledAt") ?: Timestamp(Date(scheduledAt))),
                        "status" to status, "actionAt" to Timestamp(Date(payload.optLong("createdAt"))),
                        "snoozedUntil" to if (status == "snoozed") Timestamp(Date(payload.optLong("remindAt"))) else null,
                        "watchActionId" to id, "updatedAt" to FieldValue.serverTimestamp())
                    // History keeps the instructions that applied to this dose.
                    if (previous.get("scheduleSnapshot") == null) {
                        val fields = listOf("name", "dose", "quantity", "instruction", "category", "visual", "imageKey", "instructionSource", "recurrence", "startDate", "endDate", "weekdays", "intervalDays")
                        values["scheduleSnapshot"] = fields.associateWith { schedule.get(it) }
                    }
                    if (status == "taken") {
                        val remaining = schedule.getLong("stockRemaining")
                        if (remaining != null) {
                            val quantity = (schedule.getLong("quantity") ?: 1L).coerceIn(1L, 99L)
                            tx.update(scheduleRef, mapOf(
                                "stockRemaining" to (remaining - quantity).coerceAtLeast(0L),
                                "updatedAt" to FieldValue.serverTimestamp()
                            ))
                        }
                    }
                    tx.set(recordRef, values, com.google.firebase.firestore.SetOptions.merge())
                    null
                }, 25, TimeUnit.SECONDS)
                ack("completed", "Medicine response saved on the phone.")
                return Result.success()
            }
            if (payload.optString("source") == "wearable_fall") {
                FallSmsWorker.enqueue(applicationContext, user.uid, "watch_${user.uid}_$id",
                    payload.optLong("createdAt"))
            }
            val elderlyProfile = Tasks.await(db.collection("elderly_profiles").document(user.uid).get(Source.SERVER), 20, TimeUnit.SECONDS)
            val links = Tasks.await(db.collection("care_links").whereEqualTo("elderlyId", user.uid).get(Source.SERVER), 20, TimeUnit.SECONDS)
            val caregivers = links.documents.filter { it.getString("status") == "active" }.mapNotNull { it.getString("caregiverId") }.distinct()
            val phone = elderlyProfile.getString("emergencyContact.phone") ?: ""
            val alertId = "watch_${user.uid}_$id"
            val alert = db.collection("emergency_alerts").document(alertId)
            Tasks.await(db.runTransaction { tx ->
                if (!tx.get(alert).exists()) tx.set(alert, mapOf("elderlyId" to user.uid,
                    "elderlyName" to (elderlyProfile.getString("fullName") ?: profile.getString("fullName") ?: "Elderly user"),
                    "type" to payload.optString("source"), "status" to "active", "activity" to "Watch emergency",
                    "fallProbability" to payload.optDouble("fallProbability"), "sensorSource" to "watch",
                    "emergencyContactPhone" to phone, "recipientCaregiverIds" to caregivers,
                    "watchEventId" to id, "createdAt" to FieldValue.serverTimestamp()))
                null
            }, 25, TimeUnit.SECONDS)
            if (payload.optString("source") == "wearable_fall") {
                val fallRef = db.collection("fall_events").document(alertId)
                Tasks.await(db.runTransaction { tx ->
                    if (!tx.get(fallRef).exists()) tx.set(fallRef, mapOf("elderlyId" to user.uid,
                        "source" to "wearable", "status" to "alert_sent", "activity" to "Possible fall",
                        "fallProbability" to payload.optDouble("fallProbability"), "confidence" to 0,
                        "detectedAt" to Timestamp(Date(payload.optLong("createdAt"))), "resolvedAt" to FieldValue.serverTimestamp()))
                    null
                }, 25, TimeUnit.SECONDS)
            }
            WatchBridge.showEmergencyNotification(applicationContext, "Watch help request saved. Tap to open SHCA or call the emergency contact.", phone)
            ack("recorded", "Phone saved your SOS. Checking caregiver push delivery…")
            val token = Tasks.await(user.getIdToken(false), 20, TimeUnit.SECONDS).token ?: throw IllegalStateException("No token")
            val connection = URL("https://shca-medication-images.shca-medication-images.workers.dev/v1/emergency-alerts/push").openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            connection.connectTimeout = 15000
            connection.readTimeout = 20000
            connection.setRequestProperty("Authorization", "Bearer $token")
            connection.setRequestProperty("Content-Type", "application/json")
            connection.doOutput = true
            connection.outputStream.use { it.write(JSONObject(mapOf("alertId" to alertId)).toString().toByteArray()) }
            val code = connection.responseCode
            val responseText = (if (code in 200..299) connection.inputStream else connection.errorStream)?.bufferedReader()?.use { it.readText() } ?: "{}"
            connection.disconnect()
            val response = try { JSONObject(responseText) } catch (_: Exception) { JSONObject() }
            if (code in 200..299 && response.optInt("accepted") > 0) {
                ack("completed", "Caregiver push accepted. Phone SOS saved.")
                return Result.success()
            }
            val message = response.optString("error", "No caregiver device received a push request. Check the phone.")
            ack("recorded", "SOS saved on phone. $message")
            if ((code == 429 || code >= 500) && code != 503 && runAttemptCount < 3) return Result.retry()
            return Result.success()
        } catch (_: Exception) {
            ack("failed", if (runAttemptCount < 3) "Phone could not finish. Retrying when online…" else "Phone could not finish. Check internet and retry.")
            return if (runAttemptCount < 3) Result.retry() else Result.failure()
        }
    }
    companion object {
        fun enqueue(context: Context, payload: String, node: String, medicine: Boolean) {
            val id = JSONObject(payload).optString("eventId")
            val builder = OneTimeWorkRequestBuilder<WatchActionWorker>()
                .setInputData(workDataOf("payload" to payload, "node" to node, "medicine" to medicine))
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 10, TimeUnit.SECONDS)
            if (android.os.Build.VERSION.SDK_INT >= 31) builder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            val request = builder.build()
            WorkManager.getInstance(context).enqueueUniqueWork("watch-$id", ExistingWorkPolicy.KEEP, request)
        }
    }
}
