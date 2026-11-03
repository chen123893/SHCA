package com.shca.shca

import android.app.*
import android.content.*
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.net.Uri
import android.os.*
import android.provider.Settings
import android.view.*
import android.widget.*
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import org.json.JSONObject
import java.util.UUID

/** Owns background/foreground automatic fall confirmation independently of Flutter. */
object WatchFallConfirmation {
    private const val PREFS = "shca_watch_fall_confirmation_v1"
    private const val CHANNEL = "shca_watch_fall_confirmation_v1"
    private const val NOTIFICATION = 9420
    private val handler = Handler(Looper.getMainLooper())
    private var deadlineTask: Runnable? = null
    private var overlay: View? = null
    private var overlayManager: WindowManager? = null
    private var screenLock: PowerManager.WakeLock? = null
    private val listeners = mutableSetOf<() -> Unit>()
    private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun current(c: Context): WatchPendingFall? = try {
        val j = JSONObject(prefs(c).getString("state", "") ?: "")
        WatchPendingFall(j.getString("eventId"), j.getString("userId"), j.getLong("createdAt"),
            j.getLong("deadline"), j.getDouble("probability"), j.getString("status"), j.optBoolean("preview"),
            if (!j.has("firstShownAt")) j.getLong("createdAt")
            else if (j.isNull("firstShownAt")) null else j.getLong("firstShownAt"))
    } catch (_: Exception) { null }

    private fun save(c: Context, value: WatchPendingFall) {
        check(prefs(c).edit().putString("state", JSONObject(mapOf(
            "eventId" to value.eventId, "userId" to value.userId, "createdAt" to value.createdAt,
            "deadline" to value.deadline, "probability" to value.probability,
            "status" to value.status, "preview" to value.preview,
            "firstShownAt" to (value.firstShownAt ?: JSONObject.NULL))).toString()).commit())
    }

    @Synchronized
    fun begin(context: Context, probability: Double = .95, preview: Boolean = false): Boolean {
        val c = context.applicationContext
        if (!WatchSession.isSignedIn(c) || (!preview && !WatchMonitoringService.isEnabled(c))) return false
        if (preview && c.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE == 0) return false
        val now = System.currentTimeMillis()
        val previous = current(c)
        if (previous?.belongsTo(WatchSession.userId(c)) == true &&
            (previous.status == "pending" || (!preview && !previous.preview && previous.isRecent(now)))) return false
        val state = WatchPendingFall(
            (if (preview) "preview-" else "watch-") + now + "-" + UUID.randomUUID().toString().take(8),
            WatchSession.userId(c), now, now + 15_000, probability.coerceIn(0.0, 1.0),
            preview = preview, firstShownAt = null)
        save(c, state)
        schedule(c, state)
        present(c, state)
        WatchEventBus.emit(mapOf("type" to "fall_confirmation_started"))
        return true
    }

    /** Starts once, after the alarm's first frame; restoring a window never resets it. */
    @Synchronized
    fun markVisible(context: Context, eventId: String) {
        val c = context.applicationContext
        val state = current(c) ?: return
        if (state.eventId != eventId || !state.belongsTo(WatchSession.userId(c))) return
        val visible = state.startVisibleCountdown(System.currentTimeMillis())
        if (visible === state) return
        save(c, visible)
        schedule(c, visible)
        // Keep the wake lock through the full visible response period.
        try { screenLock?.takeIf { it.isHeld }?.let { it.release(); it.acquire(16_000) } } catch (_: Exception) { }
    }

    @Synchronized
    fun restore(context: Context) {
        val c = context.applicationContext
        val state = current(c) ?: return
        if (!state.belongsTo(WatchSession.userId(c)) ||
            (state.preview && c.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE == 0)) {
            cancelAll(c); return
        }
        if (state.status == "pending") {
            if (state.deadline <= System.currentTimeMillis()) confirm(c, state.eventId)
            else { schedule(c, state); present(c, state) }
        } else if (state.canRetry(WatchSession.userId(c), System.currentTimeMillis())) {
            deliver(c, state)
        }
    }

    @Synchronized
    fun confirm(context: Context, id: String, sendNow: Boolean = false) {
        val c = context.applicationContext
        val state = current(c) ?: return
        if (state.eventId != id || !state.shouldConfirm(WatchSession.userId(c), System.currentTimeMillis(), sendNow)) return
        val confirmed = state.copy(status = "confirmed")
        save(c, confirmed)
        finishScreen(c)
        deliver(c, confirmed)
        Toast.makeText(c, if (confirmed.preview) "Preview finished" else "Requesting caregiver help…", Toast.LENGTH_SHORT).show()
        WatchEventBus.emit(mapOf("type" to "fall_confirmation_resolved", "cancelled" to false))
    }

    @Synchronized
    fun cancel(context: Context, id: String) {
        val c = context.applicationContext
        val state = current(c) ?: return
        if (state.eventId != id || !state.canCancel(WatchSession.userId(c))) return
        save(c, state.copy(status = "cancelled"))
        finishScreen(c)
        Toast.makeText(c, "Fall alert cancelled", Toast.LENGTH_SHORT).show()
        WatchEventBus.emit(mapOf("type" to "fall_confirmation_resolved", "cancelled" to true))
    }

    @Synchronized
    fun cancelAll(c: Context) {
        current(c)?.takeIf { it.status == "pending" }?.let { save(c, it.copy(status = "cancelled")) }
        finishScreen(c)
    }

    private fun deliver(c: Context, state: WatchPendingFall) {
        // Preview is local only: never queue cloud or phone emergency delivery.
        if (state.preview) {
            prefs(c).edit().putString("previewResult", "confirmed").apply()
            return
        }
        if (!state.canDeliver(WatchSession.userId(c), System.currentTimeMillis())) return
        val payload = JSONObject(mapOf("eventId" to state.eventId, "elderlyId" to state.userId,
            "createdAt" to state.createdAt, "source" to "wearable_fall", "fallProbability" to state.probability))
        DirectEmergencySender.send(c, payload)
        val request = PutDataMapRequest.create("${Paths.EMERGENCY}/${state.eventId}").apply {
            dataMap.putString("eventId", state.eventId)
            dataMap.putString("elderlyId", state.userId)
            dataMap.putLong("createdAt", state.createdAt)
            dataMap.putString("source", "wearable_fall")
            dataMap.putFloat("fallProbability", state.probability.toFloat())
            dataMap.putLong("retryAt", System.currentTimeMillis())
        }.asPutDataRequest().setUrgent()
        Wearable.getDataClient(c).putDataItem(request)
    }

    private fun alarm(c: Context, id: String): PendingIntent = PendingIntent.getBroadcast(c, 9420,
        Intent(c, WatchFallReceiver::class.java).setAction("deadline").putExtra("eventId", id),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun schedule(c: Context, state: WatchPendingFall) {
        deadlineTask?.let { handler.removeCallbacks(it) }
        val delay = (state.deadline - System.currentTimeMillis()).coerceAtLeast(0)
        deadlineTask = Runnable { confirm(c, state.eventId) }.also { handler.postDelayed(it, delay) }
        val manager = c.getSystemService(AlarmManager::class.java)
        try {
            if (Build.VERSION.SDK_INT < 31 || manager.canScheduleExactAlarms()) {
                manager.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    SystemClock.elapsedRealtime() + delay, alarm(c, state.eventId))
            }
        } catch (_: SecurityException) { /* The foreground service's wake lock also keeps the timer running. */ }
    }

    private fun action(c: Context, state: WatchPendingFall, action: String, requestCode: Int): PendingIntent =
        PendingIntent.getBroadcast(c, requestCode, Intent(c, WatchFallReceiver::class.java)
            .setAction(action).putExtra("eventId", state.eventId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun present(c: Context, state: WatchPendingFall) {
        WatchAlertVibration.startFallCountdown(c)
        @Suppress("DEPRECATION")
        try {
            screenLock?.takeIf { it.isHeld }?.release()
            screenLock = c.getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                    "${c.packageName}:fall-confirmation").apply { acquire((state.deadline - System.currentTimeMillis()).coerceAtLeast(1) + 1000) }
        } catch (_: Exception) { /* Full-screen activity also requests screen-on. */ }
        val open = Intent(c, WatchFallConfirmationActivity::class.java)
            .putExtra("eventId", state.eventId).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val options = if (Build.VERSION.SDK_INT >= 35) ActivityOptions.makeBasic().apply {
            setPendingIntentCreatorBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED)
        }.toBundle() else null
        val pending = PendingIntent.getActivity(c, NOTIFICATION, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE, options)
        val manager = c.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Possible fall confirmation", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Lets you cancel a possible fall before caregivers are notified"
            setSound(null, null); enableVibration(false)
        })
        try {
            manager.notify(NOTIFICATION, Notification.Builder(c, CHANNEL).setSmallIcon(c.applicationInfo.icon)
                .setContentTitle(if (state.preview) "Preview: possible fall" else "Possible fall — are you safe?")
                .setContentText("Tap I'm safe to cancel. Alerts caregiver after 15 seconds.")
                .setCategory(Notification.CATEGORY_ALARM).setOngoing(true).setOnlyAlertOnce(true)
                .setContentIntent(pending).setFullScreenIntent(pending, true)
                .addAction(Notification.Action.Builder(null, "I'm safe", action(c, state, "safe", 9421)).build())
                .addAction(Notification.Action.Builder(null, "Send alert", action(c, state, "send", 9422)).build()).build())
        } catch (_: SecurityException) { }
        if (Settings.canDrawOverlays(c)) {
            showOverlay(c, state)
            // A visible overlay permits the alarm activity to wake/show over the lock screen.
            handler.post {
                if (current(c)?.eventId == state.eventId && current(c)?.status == "pending") {
                    try { c.startActivity(open) } catch (_: Exception) { }
                }
            }
        } else {
            try { c.startActivity(open) } catch (_: Exception) { /* Notification actions remain available. */ }
        }
    }

    private fun showOverlay(c: Context, state: WatchPendingFall) {
        if (overlay != null) return
        val manager = c.getSystemService(WindowManager::class.java)
        val themed = ContextThemeWrapper(c, android.R.style.Theme_Material_Light_NoActionBar)
        val view = WatchFallView(themed, state.eventId)
        try {
            manager.addView(view, WindowManager.LayoutParams(WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT))
            overlay = view; overlayManager = manager
        } catch (_: Exception) { }
    }

    private fun finishScreen(c: Context) {
        deadlineTask?.let { handler.removeCallbacks(it) }; deadlineTask = null
        current(c)?.let { c.getSystemService(AlarmManager::class.java).cancel(alarm(c, it.eventId)) }
        WatchAlertVibration.stop(c)
        c.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION)
        overlay?.let { try { overlayManager?.removeView(it) } catch (_: Exception) { } }
        overlay = null; overlayManager = null
        screenLock?.takeIf { it.isHeld }?.release(); screenLock = null
        listeners.toList().forEach { it() }
    }

    fun listen(listener: () -> Unit) { listeners.add(listener) }
    fun unlisten(listener: () -> Unit) { listeners.remove(listener) }
}

class WatchFallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("eventId") ?: return
        when (intent.action) {
            "safe" -> WatchFallConfirmation.cancel(context, id)
            "send" -> WatchFallConfirmation.confirm(context, id, true)
            "deadline" -> WatchFallConfirmation.confirm(context, id)
        }
    }
}

/** Compact layout keeps both responses visible within a round watch screen. */
class WatchFallView(context: Context, private val eventId: String) : LinearLayout(context) {
    private val handler = Handler(Looper.getMainLooper())
    private val counter = TextView(context)
    private var firstFramePosted = false
    private val tick = object : Runnable {
        override fun run() {
            val state = WatchFallConfirmation.current(context)
            if (state?.eventId == eventId && state.status == "pending") {
                counter.text = "${state.secondsLeft(System.currentTimeMillis())}s"
                handler.postDelayed(this, 200)
            }
        }
    }
    init {
        orientation = VERTICAL; gravity = Gravity.CENTER
        setBackgroundColor(0xfffff2ed.toInt())
        val density = resources.displayMetrics.density
        fun dp(n: Int) = (n * density).toInt()
        setPadding(dp(30), dp(16), dp(30), dp(16))
        fun label(text: String, size: Float) = TextView(context).apply {
            this.text = text; textSize = size; gravity = Gravity.CENTER
            setTextColor(0xff241d19.toInt())
        }
        val state = WatchFallConfirmation.current(context)
        addView(label(if (state?.preview == true) "Preview: possible fall" else "Possible fall", 16f))
        addView(label("Are you safe?", 14f))
        counter.textSize = 28f; counter.gravity = Gravity.CENTER
        counter.setTextColor(0xffd32f2f.toInt()); counter.setTypeface(null, Typeface.BOLD)
        addView(counter, LayoutParams(-1, dp(38)))
        addView(label("Caregiver alerted when timer ends", 10f))
        fun button(text: String, color: Int, action: () -> Unit) {
            addView(Button(context).apply {
                this.text = text; isAllCaps = false; textSize = 13f; minHeight = 0
                setPadding(0, 0, 0, 0); setTextColor(Color.WHITE)
                backgroundTintList = android.content.res.ColorStateList.valueOf(color)
                setOnClickListener { action() }
            }, LayoutParams(-1, dp(44)))
        }
        button("I'm safe", 0xff21895e.toInt()) { WatchFallConfirmation.cancel(context, eventId) }
        button("Send alert", 0xffe63832.toInt()) { WatchFallConfirmation.confirm(context, eventId, true) }
        isFocusableInTouchMode = true; requestFocus()
    }
    override fun dispatchDraw(canvas: android.graphics.Canvas) {
        if (!firstFramePosted) {
            firstFramePosted = true
            // Run after this first frame so notification setup and window launch
            // do not consume the user's 15-second response time.
            post { WatchFallConfirmation.markVisible(context, eventId) }
        }
        super.dispatchDraw(canvas)
    }
    override fun onAttachedToWindow() { super.onAttachedToWindow(); handler.post(tick) }
    override fun onDetachedFromWindow() { handler.removeCallbacks(tick); super.onDetachedFromWindow() }
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean = if (keyCode == KeyEvent.KEYCODE_BACK) true else super.onKeyDown(keyCode, event)
}

class WatchFallConfirmationActivity : Activity() {
    private val changed: () -> Unit = {
        if (WatchFallConfirmation.current(this)?.status != "pending") finish()
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val id = intent.getStringExtra("eventId")
        val state = WatchFallConfirmation.current(this)
        if (id == null || state?.eventId != id || state.status != "pending") { finish(); return }
        setShowWhenLocked(true); setTurnScreenOn(true)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(WatchFallView(this, id))
        WatchFallConfirmation.listen(changed)
    }
    @Deprecated("The pending fall can only be cancelled with the explicit safe response")
    override fun onBackPressed() { }
    override fun onDestroy() { WatchFallConfirmation.unlisten(changed); super.onDestroy() }
}
