package com.shca.shca

import java.security.MessageDigest

object WatchIdentityScope {
    fun aliasFor(userId: String): String {
        val legacy = "shca_watch_emergency_rsa_v1"
        if (userId.isBlank()) return legacy
        val digest = MessageDigest.getInstance("SHA-256").digest(userId.toByteArray(Charsets.UTF_8))
        return legacy + "_" + digest.joinToString("") { "%02x".format(it) }.take(32)
    }
}
