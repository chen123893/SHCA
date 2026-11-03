package com.shca.shca

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.net.URL

class WatchHttpTransportTest {
    private class Connection(
        val status: Int = 200,
        val response: String = "{\"saved\":true}",
        val failUpload: Boolean = false,
        val failDownload: Boolean = false,
    ) : HttpURLConnection(URL("https://watch.invalid")) {
        var disconnected = false
        val uploaded = ByteArrayOutputStream()
        override fun connect() = Unit
        override fun usingProxy() = false
        override fun disconnect() { disconnected = true }
        override fun getOutputStream(): OutputStream {
            if (failUpload) throw SocketTimeoutException("connect timed out")
            return uploaded
        }
        override fun getResponseCode() = status
        override fun getInputStream(): InputStream = if (failDownload) {
            object : InputStream() {
                override fun read(): Int = throw SocketTimeoutException("read timed out")
            }
        } else ByteArrayInputStream(response.toByteArray())
        override fun getErrorStream() = ByteArrayInputStream(response.toByteArray())
    }

    @Test fun unreachableNetworkIsRetryableWithoutThrowing() {
        val result = WatchHttpTransport.post("https://watch.invalid", "{}",
            openConnection = { throw UnknownHostException("offline") })
        assertEquals(503, result.code)
        assertTrue(result.json.has("error"))
    }

    @Test fun uploadTimeoutDoesNotEscapeAndDisconnects() {
        val connection = Connection(failUpload = true)
        val result = WatchHttpTransport.post("https://watch.invalid", "{}", openConnection = { connection })
        assertEquals(503, result.code)
        assertTrue(connection.disconnected)
    }

    @Test fun readTimeoutDoesNotEscapeAndDisconnects() {
        val connection = Connection(failDownload = true)
        val result = WatchHttpTransport.post("https://watch.invalid", "{}", openConnection = { connection })
        assertEquals(503, result.code)
        assertTrue(connection.disconnected)
    }

    @Test fun successfulRequestPreservesPayloadAndAuthentication() {
        val connection = Connection()
        val result = WatchHttpTransport.post("https://watch.invalid", "{\"value\":1}",
            authorization = "test-token", openConnection = { connection })
        assertEquals(200, result.code)
        assertTrue(result.json.getBoolean("saved"))
        assertEquals("{\"value\":1}", connection.uploaded.toString("UTF-8"))
        assertEquals("Bearer test-token", connection.getRequestProperty("Authorization"))
        assertTrue(connection.disconnected)
    }

    @Test fun serverAuthenticationFailureRetainsItsStatusAndError() {
        val connection = Connection(status = 401, response = "{\"error\":\"expired\"}")
        val result = WatchHttpTransport.post("https://watch.invalid", "{}", openConnection = { connection })
        assertEquals(401, result.code)
        assertEquals("expired", result.json.getString("error"))
        assertTrue(connection.disconnected)
    }
}
