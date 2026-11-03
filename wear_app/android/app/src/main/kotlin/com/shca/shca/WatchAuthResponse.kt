package com.shca.shca

import org.json.JSONObject
import java.util.Base64

object WatchAuthResponse {
    /** Parse only the ID token returned directly by Firebase over HTTPS.
     * Worker/Firestore requests still verify the token's signature and role.
     * signInWithCustomToken omits localId; signInWithPassword includes it.
     */
    fun userId(response: JSONObject): String {
        val subject = try {
            val parts = response.optString("idToken").split('.')
            if (parts.size != 3) return ""
            JSONObject(String(Base64.getUrlDecoder().decode(parts[1]), Charsets.UTF_8)).optString("sub")
        } catch (_: Exception) { return "" }
        if (!subject.matches(Regex("[A-Za-z0-9_-]{1,128}"))) return ""
        val localId = response.optString("localId")
        return if (localId.isNotBlank() && localId != subject) "" else subject
    }
}
