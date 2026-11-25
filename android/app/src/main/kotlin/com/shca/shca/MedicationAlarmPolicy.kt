package com.shca.shca

/** Keeps queued alarms and old snapshots from reviving an answered occurrence. */
object MedicationAlarmPolicy {
    // Block completed doses and allow a snoozed alarm only at its saved reminder time.
    fun allows(status: String?, snoozedUntil: Long, reminderAt: Long): Boolean = when (status) {
        "taken", "missed" -> false
        "snoozed" -> snoozedUntil > 0 && snoozedUntil == reminderAt
        else -> true
    }

    // Accept a newer dose action, using status priority when action times match.
    fun acceptsUpdate(previousStatus: String?, previousAction: Long,
                      status: String, action: Long): Boolean {
        if (action != previousAction) return action > previousAction
        // Prefer taken and missed responses over snoozed or pending values.
        fun rank(value: String?) = when (value) {
            "taken" -> 4
            "missed" -> 3
            "snoozed" -> 2
            else -> 1
        }
        return rank(status) >= rank(previousStatus)
    }
}
