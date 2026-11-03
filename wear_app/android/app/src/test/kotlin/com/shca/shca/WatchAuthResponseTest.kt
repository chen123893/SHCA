package com.shca.shca

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Base64

class WatchAuthResponseTest {
    private fun token(uid: String): String {
        val payload = Base64.getUrlEncoder().withoutPadding()
            .encodeToString(JSONObject(mapOf("sub" to uid)).toString().toByteArray())
        return "header.$payload.signature"
    }

    @Test fun customTokenResponseWithoutLocalIdUsesFirebaseSubject() {
        val response = JSONObject(mapOf("idToken" to token("elderly"), "refreshToken" to "refresh", "expiresIn" to "3600"))
        assertEquals("elderly", WatchAuthResponse.userId(response))
    }

    @Test fun passwordResponseRetainsMatchingLocalId() {
        assertEquals("elderly", WatchAuthResponse.userId(JSONObject(mapOf("idToken" to token("elderly"), "localId" to "elderly"))))
    }

    @Test fun inconsistentOrMalformedIdentityCannotBeSaved() {
        assertEquals("", WatchAuthResponse.userId(JSONObject(mapOf("idToken" to token("elderly"), "localId" to "someone_else"))))
        assertEquals("", WatchAuthResponse.userId(JSONObject(mapOf("idToken" to "broken", "localId" to "elderly"))))
        assertEquals("", WatchAuthResponse.userId(JSONObject(mapOf("idToken" to token("")))))
    }
}
