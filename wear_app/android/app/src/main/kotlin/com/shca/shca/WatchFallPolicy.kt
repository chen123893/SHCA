package com.shca.shca

data class WatchPendingFall(
    val eventId: String, val userId: String, val createdAt: Long,
    val deadline: Long, val probability: Double, val status: String = "pending",
    val preview: Boolean = false,
    val firstShownAt: Long? = createdAt,
) {
    fun secondsLeft(now: Long): Int = if (firstShownAt == null && now < deadline) 15
        else ((deadline - now).coerceAtLeast(0) + 999).div(1000).toInt()
    fun startVisibleCountdown(now: Long): WatchPendingFall =
        if (status == "pending" && firstShownAt == null && now < deadline)
            copy(firstShownAt = now, deadline = now + 15_000)
        else this
    fun belongsTo(userId: String) = userId.isNotBlank() && this.userId == userId
    fun shouldConfirm(userId: String, now: Long, sendNow: Boolean = false) =
        belongsTo(userId) && status == "pending" && (sendNow || now >= deadline)
    fun canCancel(userId: String) = belongsTo(userId) && status == "pending"
    fun isRecent(now: Long) = now - createdAt in 0..60_000
    fun canDeliver(userId: String, now: Long) = !preview && canRetry(userId, now)
    fun canRetry(userId: String, now: Long) = belongsTo(userId) &&
        status == "confirmed" && now - createdAt in 0..900_000
}
