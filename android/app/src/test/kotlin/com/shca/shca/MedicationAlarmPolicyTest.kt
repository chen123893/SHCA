package com.shca.shca

import org.junit.Assert.*
import org.junit.Test

class MedicationAlarmPolicyTest {
    @Test fun takenAndSkippedDosesRejectBothOriginalAndSnoozedAlarms() {
        for (status in listOf("taken", "missed")) {
            assertFalse(MedicationAlarmPolicy.allows(status, 0, 0))
            assertFalse(MedicationAlarmPolicy.allows(status, 200, 200))
        }
    }

    @Test fun snoozingOnlyAllowsTheCurrentReminder() {
        assertFalse(MedicationAlarmPolicy.allows("snoozed", 200, 0))
        assertFalse(MedicationAlarmPolicy.allows("snoozed", 200, 100))
        assertTrue(MedicationAlarmPolicy.allows("snoozed", 200, 200))
    }

    @Test fun aDelayedPendingSnapshotCannotUndoATakenResponse() {
        assertFalse(MedicationAlarmPolicy.acceptsUpdate("taken", 200, "pending", 0))
        assertFalse(MedicationAlarmPolicy.acceptsUpdate("taken", 200, "snoozed", 200))
        assertTrue(MedicationAlarmPolicy.acceptsUpdate("snoozed", 100, "taken", 200))
    }

    @Test fun unansweredDosesCanStillRing() {
        assertTrue(MedicationAlarmPolicy.allows(null, 0, 0))
        assertTrue(MedicationAlarmPolicy.allows("pending", 0, 0))
    }
}
