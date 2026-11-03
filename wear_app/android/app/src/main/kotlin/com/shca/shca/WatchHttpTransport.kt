package com.shca.shca

import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/** Network failures are retryable results, so they cannot kill local monitoring. */
internal object WatchHttpTransport {
    fun post(
        url: String,
        body: String,
        contentType: String = "application/json",
        authorization: String? = null,
        openConnection: (String) -> HttpURLConnection = { URL(it).openConnection() as HttpURLConnection },
    ): WatchCloudResponse {
        var connection: HttpURLConnection? = null
        return try {
            val active = openConnection(url)
            connection = active
            active.requestMethod = "POST"
            active.connectTimeout = 15_000
            active.readTimeout = 25_000
            active.setRequestProperty("Content-Type", contentType)
            if (authorization != null) active.setRequestProperty("Authorization", "Bearer $authorization")
            active.doOutput = true
            active.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val code = active.responseCode
            val text = (if (code in 200..299) active.inputStream else active.errorStream)
                ?.bufferedReader()?.use { it.readText() } ?: "{}"
            WatchCloudResponse(code, try { JSONObject(text) } catch (_: Exception) { JSONObject() })
        } catch (_: IOException) {
            // Callers retain queued medicine/emergency actions on non-success.
            // Do not clear authentication or stop sensors when the network drops.
            WatchCloudResponse(503, JSONObject(mapOf(
                "error" to "The watch could not reach the server. It will retry when online.",
            )))
        } finally {
            connection?.disconnect()
        }
    }
}
