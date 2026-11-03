package com.shca.shca

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import java.security.KeyStore
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Persisted Firebase session owned by the watch, encrypted by Android Keystore. */
object WatchSession {
    private const val PREFS = "shca_watch_standalone_session_v1"
    private const val KEY_ALIAS = "shca_watch_session_aes_v1"
    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isSignedIn(context: Context): Boolean =
        userId(context).isNotBlank() && prefs(context).getString("refreshToken", "").orEmpty().isNotBlank()

    fun userId(context: Context): String = prefs(context).getString("userId", "") ?: ""
    fun name(context: Context): String = prefs(context).getString("name", "") ?: ""
    fun lastCloudSync(context: Context): Long = prefs(context).getLong("lastCloudSync", 0)

    fun state(context: Context): Map<String, Any?> = mapOf(
        "signedIn" to isSignedIn(context),
        "accountName" to name(context),
        "cloudReady" to (lastCloudSync(context) > 0),
    )

    @Synchronized
    fun saveAuthentication(
        context: Context,
        userId: String,
        idToken: String,
        refreshToken: String,
        expiresInSeconds: Long,
    ) {
        prefs(context).edit()
            .putString("userId", userId)
            .putString("idToken", encrypt(idToken))
            .putString("refreshToken", encrypt(refreshToken))
            .putLong("expiresAt", System.currentTimeMillis() + expiresInSeconds * 1000)
            .apply()
    }

    fun saveName(context: Context, value: String) {
        prefs(context).edit().putString("name", value).apply()
    }

    fun markCloudSync(context: Context) {
        prefs(context).edit().putLong("lastCloudSync", System.currentTimeMillis()).apply()
    }

    fun clear(context: Context) {
        prefs(context).edit().clear().apply()
        MedicationStore.receive(context, "", "[]")
    }

    @Synchronized
    fun token(context: Context): String? {
        if (!isSignedIn(context)) return null
        val p = prefs(context)
        if (p.getLong("expiresAt", 0) > System.currentTimeMillis() + 60_000) {
            return decrypt(p.getString("idToken", "") ?: "")
        }
        val refreshToken = decrypt(p.getString("refreshToken", "") ?: "") ?: return null
        val body = "grant_type=refresh_token&refresh_token=" +
            URLEncoder.encode(refreshToken, Charsets.UTF_8.name())
        val result = WatchCloud.request(
            "https://securetoken.googleapis.com/v1/token?key=${WatchCloud.FIREBASE_API_KEY}",
            body,
            "application/x-www-form-urlencoded",
        )
        if (result.code !in 200..299) return null
        val idToken = result.json.optString("id_token")
        val nextRefresh = result.json.optString("refresh_token", refreshToken)
        val uid = result.json.optString("user_id", userId(context))
        if (idToken.isBlank() || uid.isBlank()) return null
        saveAuthentication(
            context,
            uid,
            idToken,
            nextRefresh,
            result.json.optLong("expires_in", 3600),
        )
        return idToken
    }

    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return generator.generateKey()
    }

    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val joined = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(joined, Base64.NO_WRAP)
    }

    private fun decrypt(value: String): String? = try {
        val joined = Base64.decode(value, Base64.NO_WRAP)
        if (joined.size <= 12) return null
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, joined.copyOfRange(0, 12)))
        String(cipher.doFinal(joined.copyOfRange(12, joined.size)), Charsets.UTF_8)
    } catch (_: Exception) {
        null
    }
}

data class WatchCloudResponse(val code: Int, val json: JSONObject)

/** Direct watch-to-cloud sync. The phone data layer remains a fallback only. */
object WatchCloud {
    const val FIREBASE_API_KEY = "AIzaSyDRpjBro5Dm8KPcSUCaksqiB7Btw0-pdn0"
    private const val BASE = "https://shca-medication-images.shca-medication-images.workers.dev"
    private const val PREFS = "shca_watch_cloud_queue_v1"
    private val refreshing = AtomicBoolean(false)
    private val main = Handler(Looper.getMainLooper())

    fun signIn(
        context: Context,
        email: String,
        password: String,
        callback: (Map<String, Any?>) -> Unit,
    ) {
        Thread {
            val result = try {
                val auth = request(
                    "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=$FIREBASE_API_KEY",
                    JSONObject(mapOf(
                        "email" to email.trim(),
                        "password" to password,
                        "returnSecureToken" to true,
                    )).toString(),
                )
                if (auth.code !in 200..299) {
                    val provider = auth.json.optJSONObject("error")?.optString("message").orEmpty()
                    mapOf("error" to when {
                        provider.contains("INVALID_LOGIN_CREDENTIALS") || provider.contains("INVALID_PASSWORD") ->
                            "Email or password is incorrect."
                        provider.contains("EMAIL_NOT_FOUND") -> "No SHCA account uses this email."
                        provider.contains("TOO_MANY_ATTEMPTS") -> "Too many attempts. Wait briefly and try again."
                        else -> "The watch could not sign in. Check its internet connection."
                    })
                } else {
                    completeSignIn(context, auth)
                }
            } catch (_: Exception) {
                mapOf("error" to "The watch could not sign in. Check its internet connection.")
            }
            main.post { callback(result) }
        }.start()
    }

    private fun completeSignIn(context: Context, auth: WatchCloudResponse): Map<String, Any?> {
        val idToken = auth.json.optString("idToken")
        val refreshToken = auth.json.optString("refreshToken")
        val uid = WatchAuthResponse.userId(auth.json)
        return if (idToken.isBlank() || refreshToken.isBlank() || uid.isBlank()) {
            mapOf("error" to "The watch received an incomplete sign-in response.")
        } else {
            WatchSession.saveAuthentication(
                context,
                uid,
                idToken,
                refreshToken,
                auth.json.optLong("expiresIn", 3600),
            )
            val identity = WatchDeviceIdentity.getOrCreate(context)
            val session = authorizedPost(context, "/v1/watch/session", JSONObject(mapOf(
                "credentialId" to identity.keyId,
                "publicKey" to identity.publicKey,
            )))
            if (session.code !in 200..299) {
                WatchSession.clear(context)
                mapOf("error" to session.json.optString("error", "Use an elderly SHCA account."))
            } else {
                WatchSession.saveName(context, session.json.optString("name", "Elderly user"))
                refreshIfNeeded(context, force = true)
                WatchMonitoringService.start(context)
                mapOf("success" to true)
            }
        }
    }

    fun signInWithCustomToken(
        context: Context, customToken: String, stillApproved: () -> Boolean,
        callback: (Map<String, Any?>) -> Unit,
    ) {
        Thread {
            val result = try {
                val auth = request(
                    "https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=$FIREBASE_API_KEY",
                    JSONObject(mapOf("token" to customToken, "returnSecureToken" to true)).toString(),
                )
                if (!stillApproved()) mapOf("error" to "This code expired or was cancelled. Generate a new code.")
                else if (auth.code !in 200..299) mapOf("error" to "Phone approval expired. Generate a new code and try again.")
                else completeSignIn(context, auth)
            } catch (_: Exception) {
                mapOf("error" to "The watch could not finish sign-in. Check its internet connection and retry.")
            }
            main.post { callback(result) }
        }.start()
    }

    fun signOut(context: Context) {
        WatchPhoneSignIn.cancel(context)
        WatchFallConfirmation.cancelAll(context)
        DirectEmergencySender.clearPending(context)
        WatchSession.clear(context)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
        context.stopService(android.content.Intent(context, WatchMonitoringService::class.java))
        WatchEventBus.emit(mapOf("type" to "session_updated"))
    }

    fun refreshIfNeeded(context: Context, force: Boolean = false) {
        if (!WatchSession.isSignedIn(context) || !refreshing.compareAndSet(false, true)) return
        Thread {
            try {
                val last = WatchSession.lastCloudSync(context)
                if (force || System.currentTimeMillis() - last >= 60_000) refreshNow(context, force)
                retryMedicationActions(context)
                DirectEmergencySender.retryPending(context)
            } finally {
                refreshing.set(false)
            }
        }.start()
    }

    private fun refreshNow(context: Context, force: Boolean) {
        if (!force && System.currentTimeMillis() - WatchSession.lastCloudSync(context) < 60_000) return
        val now = Date()
        val format = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        format.timeZone = TimeZone.getDefault()
        val response = authorizedPost(context, "/v1/watch/snapshot", JSONObject(mapOf(
            "date" to format.format(now),
            "offsetMinutes" to (TimeZone.getDefault().getOffset(now.time) / 60_000),
        )))
        if (response.code !in 200..299) return
        val uid = response.json.optString("elderlyId")
        val medications = response.json.optJSONArray("medications") ?: JSONArray()
        if (uid.isBlank() || uid != WatchSession.userId(context)) return
        WatchSession.saveName(context, response.json.optString("name", WatchSession.name(context)))
        MedicationStore.receive(context, uid, medications.toString())
        WatchSession.markCloudSync(context)
        WatchEventBus.emit(mapOf("type" to "session_updated"))
    }

    fun publishActivity(context: Context, values: Map<String, Any?>) {
        if (!WatchSession.isSignedIn(context)) return
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val label = values["label"] as? String ?: return
        val signature = "$label:${values["possibleFall"] == true}"
        val now = System.currentTimeMillis()
        if (p.getString("activitySignature", "") == signature && now - p.getLong("activityAt", 0) < 15_000) return
        Thread {
            val response = authorizedPost(context, "/v1/watch/activity", JSONObject(values))
            if (response.code in 200..299) {
                p.edit().putString("activitySignature", signature).putLong("activityAt", now).apply()
            }
        }.start()
    }

    fun queueMedicationAction(context: Context, payload: JSONObject) {
        val id = payload.optString("eventId")
        if (id.isBlank()) return
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        synchronized(this) {
            val pending = try { JSONObject(p.getString("medication", "{}")) } catch (_: Exception) { JSONObject() }
            pending.put(id, payload)
            p.edit().putString("medication", pending.toString()).apply()
        }
        refreshIfNeeded(context, force = true)
    }

    private fun retryMedicationActions(context: Context) {
        if (!WatchSession.isSignedIn(context)) return
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val pending = try { JSONObject(p.getString("medication", "{}")) } catch (_: Exception) { JSONObject() }
        val ids = pending.keys().asSequence().toList()
        for (id in ids) {
            val payload = pending.optJSONObject(id) ?: continue
            val response = authorizedPost(context, "/v1/watch/medication-action", payload)
            if (response.code in 200..299) {
                pending.remove(id)
                MedicationStore.confirmAction(context, payload.optString("occurrenceId"))
                WatchDataStore.acceptAck(context, JSONObject(mapOf(
                    "eventId" to id,
                    "status" to "completed",
                    "message" to "Medicine response saved directly from your watch.",
                )).toString(), true)
            }
        }
        p.edit().putString("medication", pending.toString()).apply()
    }

    private fun authorizedPost(context: Context, path: String, body: JSONObject): WatchCloudResponse {
        val token = WatchSession.token(context) ?: return WatchCloudResponse(401, JSONObject(mapOf("error" to "Sign in again.")))
        var response = request("$BASE$path", body.toString(), authorization = token)
        if (response.code == 401) {
            context.getSharedPreferences("shca_watch_standalone_session_v1", Context.MODE_PRIVATE)
                .edit().putLong("expiresAt", 0).apply()
            val refreshed = WatchSession.token(context)
            if (refreshed != null) response = request("$BASE$path", body.toString(), authorization = refreshed)
        }
        return response
    }

    fun request(
        url: String,
        body: String,
        contentType: String = "application/json",
        authorization: String? = null,
    ): WatchCloudResponse {
        return WatchHttpTransport.post(url, body, contentType, authorization)
    }
}
