package com.shca.shca

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.Signature

/**
 * Hardware-backed watch identity. The private key never leaves Android Keystore;
 * only the public key is shared with the signed-in elderly phone for enrolment.
 */
data class WatchIdentity(val keyId: String, val publicKey: String)

object WatchDeviceIdentity {

    fun getOrCreate(context: Context): WatchIdentity {
        val alias = WatchIdentityScope.aliasFor(WatchSession.userId(context))
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!store.containsAlias(alias)) {
            val generator = KeyPairGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_RSA,
                "AndroidKeyStore",
            )
            generator.initialize(
                KeyGenParameterSpec.Builder(
                    alias,
                    KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
                )
                    .setKeySize(2048)
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1)
                    .build(),
            )
            generator.generateKeyPair()
        }
        val encoded = store.getCertificate(alias).publicKey.encoded
        val digest = MessageDigest.getInstance("SHA-256").digest(encoded)
        val keyId = digest.joinToString("") { "%02x".format(it) }.take(40)
        return WatchIdentity(
            keyId = keyId,
            publicKey = Base64.encodeToString(encoded, Base64.NO_WRAP),
        )
    }

    fun sign(context: Context, message: String): String {
        val alias = WatchIdentityScope.aliasFor(WatchSession.userId(context))
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val privateKey = store.getKey(alias, null)
            ?: throw IllegalStateException("Watch identity is unavailable")
        val signer = Signature.getInstance("SHA256withRSA")
        signer.initSign(privateKey as java.security.PrivateKey)
        signer.update(message.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(signer.sign(), Base64.NO_WRAP)
    }
}

/** Sends SOS/fall alerts over the watch's own Wi-Fi or LTE connection. */
object DirectEmergencySender {
    private const val ENDPOINT =
        "https://shca-medication-images.shca-medication-images.workers.dev/v1/watch-emergency"
    private const val PREFS = "shca_watch_direct_emergency_v1"

    fun clearPending(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
    }

    fun send(context: Context, payload: JSONObject) {
        val appContext = context.applicationContext
        val eventId = payload.optString("eventId")
        if (eventId.isBlank()) return
        synchronized(this) {
            val preferences = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val pending = try {
                JSONObject(preferences.getString("pending", "{}"))
            } catch (_: Exception) {
                JSONObject()
            }
            pending.put(eventId, payload)
            preferences.edit().putString("pending", pending.toString()).apply()
        }
        sendPending(appContext, eventId, payload)
    }

    fun retryPending(context: Context) {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val pending = try {
            JSONObject(preferences.getString("pending", "{}"))
        } catch (_: Exception) {
            JSONObject()
        }
        val now = System.currentTimeMillis()
        pending.keys().asSequence().toList().forEach { eventId ->
            val payload = pending.optJSONObject(eventId) ?: return@forEach
            if (now - payload.optLong("createdAt") > 15 * 60_000) {
                removePending(context, eventId)
            } else {
                sendPending(context.applicationContext, eventId, payload)
            }
        }
    }

    private fun sendPending(appContext: Context, eventId: String, payload: JSONObject) {
        Thread {
            try {
                val identity = WatchDeviceIdentity.getOrCreate(appContext)
                val createdAt = payload.optLong("createdAt")
                val source = payload.optString("source", "wearable_sos")
                val probability = payload.optDouble("fallProbability", 0.0)
                    .coerceIn(0.0, 1.0)
                val probabilityPpm = kotlin.math.round(probability * 1_000_000).toLong()
                val canonical = listOf(
                    identity.keyId,
                    eventId,
                    createdAt.toString(),
                    source,
                    probabilityPpm.toString(),
                ).joinToString("\n")
                val body = JSONObject(
                    mapOf(
                        "credentialId" to identity.keyId,
                        "eventId" to eventId,
                        "createdAt" to createdAt,
                        "source" to source,
                        "fallProbabilityPpm" to probabilityPpm,
                        "signature" to WatchDeviceIdentity.sign(appContext, canonical),
                    ),
                )
                val connection = URL(ENDPOINT).openConnection() as HttpURLConnection
                connection.requestMethod = "POST"
                connection.connectTimeout = 12_000
                connection.readTimeout = 18_000
                connection.setRequestProperty("Content-Type", "application/json")
                connection.doOutput = true
                connection.outputStream.use { it.write(body.toString().toByteArray()) }
                val code = connection.responseCode
                val responseText = (if (code in 200..299) {
                    connection.inputStream
                } else {
                    connection.errorStream
                })?.bufferedReader()?.use { it.readText() } ?: "{}"
                connection.disconnect()
                val response = try {
                    JSONObject(responseText)
                } catch (_: Exception) {
                    JSONObject()
                }
                if (code in 200..299) {
                    removePending(appContext, eventId)
                    val accepted = response.optInt("accepted")
                    val status = if (accepted > 0) "completed" else "recorded"
                    val message = if (accepted > 0) {
                        "Caregiver push accepted directly from your watch."
                    } else {
                        response.optString(
                            "error",
                            "SOS saved, but no caregiver device accepted the push.",
                        )
                    }
                    acknowledge(appContext, eventId, status, message)
                } else {
                    acknowledge(
                        appContext,
                        eventId,
                        "queued",
                        "Direct delivery is unavailable. The paired-phone fallback is still trying…",
                    )
                }
            } catch (_: Exception) {
                acknowledge(
                    appContext,
                    eventId,
                    "queued",
                    "Direct delivery is unavailable. The paired-phone fallback is still trying…",
                )
            }
        }.start()
    }

    private fun removePending(context: Context, eventId: String) {
        synchronized(this) {
            val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val pending = try {
                JSONObject(preferences.getString("pending", "{}"))
            } catch (_: Exception) {
                JSONObject()
            }
            pending.remove(eventId)
            preferences.edit().putString("pending", pending.toString()).apply()
        }
    }

    private fun acknowledge(
        context: Context,
        eventId: String,
        status: String,
        message: String,
    ) {
        val json = JSONObject(
            mapOf("eventId" to eventId, "status" to status, "message" to message),
        )
        WatchDataStore.acceptAck(context, json.toString(), false)
    }
}
