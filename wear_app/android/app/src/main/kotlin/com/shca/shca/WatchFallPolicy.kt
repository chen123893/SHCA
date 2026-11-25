package com.shca.shca

data class WatchPendingFall(
    val eventId: String, val userId: String, val createdAt: Long,
    val deadline: Long, val probability: Double, val status: String = "pending",
    val preview: Boolean = false,
    val firstShownAt: Long? = createdAt,
) {
    // Calculate the visible countdown from the saved deadline.
    fun secondsLeft(now: Long): Int = if (firstShownAt == null && now < deadline) 15
        else ((deadline - now).coerceAtLeast(0) + 999).div(1000).toInt()
    // Start the 15-second response window when the pending warning first becomes visible.
    fun startVisibleCountdown(now: Long): WatchPendingFall =
        if (status == "pending" && firstShownAt == null && now < deadline)
            copy(firstShownAt = now, deadline = now + 15_000)
        else this
    // Check that the fall warning belongs to the current watch account.
    fun belongsTo(userId: String) = userId.isNotBlank() && this.userId == userId
    // Require a pending warning and either a help response or an expired deadline.
    fun shouldConfirm(userId: String, now: Long, sendNow: Boolean = false) =
        belongsTo(userId) && status == "pending" && (sendNow || now >= deadline)
    // Allow a safe response only for this account's pending warning.
    fun canCancel(userId: String) = belongsTo(userId) && status == "pending"
    // Check whether the warning was created within the last minute.
    fun isRecent(now: Long) = now - createdAt in 0..60_000
    // Allow a real confirmed emergency to use the current retry policy.
    fun canDeliver(userId: String, now: Long) = !preview && canRetry(userId, now)
    // Retry only this account's confirmed event within its 15-minute delivery window.
    fun canRetry(userId: String, now: Long) = belongsTo(userId) &&
        status == "confirmed" && now - createdAt in 0..900_000
}
