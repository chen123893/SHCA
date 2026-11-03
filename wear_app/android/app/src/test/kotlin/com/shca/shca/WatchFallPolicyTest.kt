package com.shca.shca

import org.junit.Assert.*
import org.junit.Test

class WatchFallPolicyTest {
    private val fall = WatchPendingFall("fall-1", "elderly", 1_000, 16_000, .95)
    @Test fun detectionDoesNotSendBeforeTheCountdownDeadline() {
        assertFalse(fall.shouldConfirm("elderly", 1_000))
        assertFalse(fall.shouldConfirm("elderly", 15_999))
        assertTrue(fall.shouldConfirm("elderly", 16_000))
        assertEquals(15, fall.secondsLeft(1_000))
        assertEquals(1, fall.secondsLeft(15_999))
        assertEquals(0, fall.secondsLeft(17_000))
    }
    @Test fun safeCancellationPreventsEveryLaterDeadlineCallback() {
        assertTrue(fall.canCancel("elderly"))
        val cancelled = fall.copy(status = "cancelled")
        assertFalse(cancelled.shouldConfirm("elderly", 100_000))
        assertFalse(cancelled.shouldConfirm("elderly", 100_000, true))
        assertFalse(cancelled.canRetry("elderly", 100_000))
    }
    @Test fun sendNowClaimsTheSameEventOnlyOnce() {
        assertTrue(fall.shouldConfirm("elderly", 2_000, true))
        val confirmed = fall.copy(status = "confirmed")
        assertFalse(confirmed.shouldConfirm("elderly", 2_001, true))
        assertFalse(confirmed.shouldConfirm("elderly", 16_000))
        assertFalse(confirmed.canCancel("elderly"))
        assertTrue(confirmed.canRetry("elderly", 16_000))
    }
    @Test fun restoredCountdownUsesOriginalDeadlineAndNeverAnotherAccount() {
        assertEquals(5, fall.secondsLeft(11_000))
        assertTrue(fall.shouldConfirm("elderly", 17_000))
        assertFalse(fall.shouldConfirm("another-user", 17_000))
        assertFalse(fall.shouldConfirm("", 17_000))
        assertFalse(fall.canCancel("another-user"))
        assertFalse(fall.copy(status = "confirmed").canRetry("elderly", 902_000))
    }
    @Test fun repeatedDetectionDoesNotExtendAnActiveOrRecentConfirmation() {
        assertTrue(fall.isRecent(20_000))
        assertTrue(fall.copy(status = "cancelled").isRecent(30_000))
        assertFalse(fall.isRecent(62_000))
    }
    @Test fun previewCanExerciseTimeoutWithoutDispatchingRealAlerts() {
        val preview = fall.copy(preview = true)
        assertTrue(preview.shouldConfirm("elderly", 16_000))
        val confirmed = preview.copy(status = "confirmed")
        assertFalse(confirmed.canDeliver("elderly", 16_000))
        assertTrue(fall.copy(status = "confirmed").canDeliver("elderly", 16_000))
    }

    @Test fun delayedFirstFrameStillGivesFifteenVisibleSeconds() {
        val notShown = fall.copy(firstShownAt = null)
        assertEquals(15, notShown.secondsLeft(4_000))
        val visible = notShown.startVisibleCountdown(4_000)
        assertEquals(4_000L, visible.firstShownAt)
        assertEquals(19_000L, visible.deadline)
        for (second in 0..14) assertEquals(15 - second, visible.secondsLeft(4_000L + second * 1_000))
        assertFalse(visible.shouldConfirm("elderly", 18_999))
        assertTrue(visible.shouldConfirm("elderly", 19_000))
    }
    @Test fun secondWindowAndRestoreCannotRestartTheVisibleTimer() {
        val visible = fall.copy(firstShownAt = null).startVisibleCountdown(4_000)
        assertSame(visible, visible.startVisibleCountdown(9_000))
        assertEquals(10, visible.secondsLeft(9_000))
    }
    @Test fun legacySavedCountdownRetainsItsExistingDeadline() {
        assertSame(fall, fall.startVisibleCountdown(4_000))
        assertEquals(16_000L, fall.deadline)
    }
    @Test fun alarmThatNeverBecomesVisibleStillHasABoundedFallback() {
        val notShown = fall.copy(firstShownAt = null)
        assertTrue(notShown.shouldConfirm("elderly", 16_000))
        assertSame(notShown, notShown.startVisibleCountdown(16_000))
    }
    @Test fun resolvedAlarmCannotRestartWhenAFrameArrivesLate() {
        val cancelled = fall.copy(status = "cancelled", firstShownAt = null)
        assertSame(cancelled, cancelled.startVisibleCountdown(4_000))
        val confirmed = fall.copy(status = "confirmed", firstShownAt = null)
        assertSame(confirmed, confirmed.startVisibleCountdown(4_000))
    }

}
