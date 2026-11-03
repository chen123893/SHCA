package com.shca.shca

import org.junit.Assert.*
import org.junit.Test

class WatchIdentityScopeTest {
    @Test fun eachAccountGetsADifferentStableHardwareKeyAlias() {
        assertEquals(WatchIdentityScope.aliasFor("elderly-a"), WatchIdentityScope.aliasFor("elderly-a"))
        assertNotEquals(WatchIdentityScope.aliasFor("elderly-a"), WatchIdentityScope.aliasFor("elderly-b"))
        assertFalse(WatchIdentityScope.aliasFor("elderly-a").contains("elderly-a"))
    }
    @Test fun legacyPhoneOnlyModeKeepsItsOriginalAlias() {
        assertEquals("shca_watch_emergency_rsa_v1", WatchIdentityScope.aliasFor(""))
        assertNotEquals(WatchIdentityScope.aliasFor(""), WatchIdentityScope.aliasFor("elderly-a"))
    }
}
