package com.shca.shca

import android.app.Activity
import android.app.ActivityOptions
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import kotlin.math.ceil
import kotlin.math.min

data class PhoneFallAlarmState(val eventId: String, val deadline: Long, val preview: Boolean = false) {
    fun secondsLeft(now: Long = System.currentTimeMillis()): Int =
        ceil((deadline - now).coerceAtLeast(0) / 1000.0).toInt()
}

/** Presents the service's existing confirmation; it never owns alert delivery. */
object PhoneFallAlarm {
    private val handler = Handler(Looper.getMainLooper())
    private val listeners = mutableSetOf<() -> Unit>()
    private var overlay: View? = null
    private var overlayManager: WindowManager? = null
    private var screenLock: PowerManager.WakeLock? = null
    private var activeId: String? = null
    private var previewState: PhoneFallAlarmState? = null
    private var previewDeadline: Runnable? = null
    private var responding = false

    fun current(context: Context): PhoneFallAlarmState? = previewState
        ?: PhoneMonitoringService.currentFallAlarm(context)

    fun isShowing(): Boolean = activeId != null

    fun activityIntent(context: Context, state: PhoneFallAlarmState): Intent =
        Intent(context, PhoneFallAlarmActivity::class.java)
            .putExtra("eventId", state.eventId)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)

    fun activityPendingIntent(context: Context, state: PhoneFallAlarmState): PendingIntent {
        val options = if (Build.VERSION.SDK_INT >= 34) ActivityOptions.makeBasic().apply {
            setPendingIntentCreatorBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED)
        }.toBundle() else null
        return PendingIntent.getActivity(context, 9455, activityIntent(context, state),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE, options)
    }

    fun present(context: Context, state: PhoneFallAlarmState) {
        val app = context.applicationContext
        if (current(app)?.eventId != state.eventId || state.secondsLeft() <= 0) return
        if (activeId == state.eventId) return
        dismiss()
        activeId = state.eventId
        responding = false
        @Suppress("DEPRECATION")
        try {
            screenLock = app.getSystemService(PowerManager::class.java).newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "${app.packageName}:phone-fall-alarm",
            ).apply { acquire((state.deadline - System.currentTimeMillis()).coerceAtLeast(1) + 1000) }
        } catch (error: Exception) {
            android.util.Log.w("PhoneFallAlarm", "Screen wake request failed", error)
        }
        if (Settings.canDrawOverlays(app)) {
            showOverlay(app, state)
            // Android 15 requires a visible overlay before a background launch.
            overlay?.post { launchActivity(app, state) } ?: launchActivity(app, state)
        } else {
            // The notification's full-screen intent remains available as well.
            launchActivity(app, state)
        }
    }

    private fun launchActivity(context: Context, state: PhoneFallAlarmState) {
        if (activeId != state.eventId || current(context)?.eventId != state.eventId) return
        try { context.startActivity(activityIntent(context, state)) }
        catch (error: Exception) { android.util.Log.w("PhoneFallAlarm", "Alarm activity could not open; overlay/notification remain", error) }
    }

    private fun showOverlay(context: Context, state: PhoneFallAlarmState) {
        val manager = context.getSystemService(WindowManager::class.java)
        val themed = android.view.ContextThemeWrapper(context, android.R.style.Theme_Material_Light_NoActionBar)
        val view = PhoneFallAlarmView(themed, state.eventId)
        @Suppress("DEPRECATION")
        val type = if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else WindowManager.LayoutParams.TYPE_PHONE
        try {
            manager.addView(view, WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT, type,
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.OPAQUE,
            ))
            overlay = view; overlayManager = manager
        } catch (error: Exception) {
            android.util.Log.w("PhoneFallAlarm", "Appear-on-top window could not open", error)
        }
    }

    fun activityVisible(eventId: String) {
        if (activeId == eventId) removeOverlay()
    }

    private fun removeOverlay() {
        overlay?.let { try { overlayManager?.removeView(it) } catch (_: Exception) { } }
        overlay = null; overlayManager = null
    }

    fun dismiss() {
        activeId = null
        responding = false
        removeOverlay()
        screenLock?.takeIf { it.isHeld }?.release(); screenLock = null
        listeners.toList().forEach { it() }
    }

    fun respond(context: Context, eventId: String, send: Boolean) {
        if (responding || current(context)?.eventId != eventId) return
        responding = true
        if (previewState?.eventId == eventId) {
            finishPreview(if (send) "send" else "safe")
            return
        }
        PhoneMonitoringService.respond(context, mapOf("eventId" to eventId, "send" to send),
            object : io.flutter.plugin.common.MethodChannel.Result {
                override fun success(result: Any?) { responding = false }
                override fun error(code: String, message: String?, details: Any?) { responding = false }
                override fun notImplemented() { responding = false }
            })
    }

    fun listen(listener: () -> Unit) { listeners.add(listener) }
    fun unlisten(listener: () -> Unit) { listeners.remove(listener) }

    /** Debug-only local preview: no service, cloud record, or caregiver message. */
    fun preview(context: Context, durationMillis: Long = 30_000) {
        if (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0 ||
            PhoneMonitoringService.state(context)["enabled"] == true || previewState != null) return
        val state = PhoneFallAlarmState("preview-${System.currentTimeMillis()}",
            System.currentTimeMillis() + durationMillis.coerceIn(3_000, 30_000), preview = true)
        previewState = state
        FallAlertFeedback.start(context, state.deadline - System.currentTimeMillis())
        previewDeadline = Runnable { finishPreview("timeout") }.also {
            handler.postDelayed(it, state.deadline - System.currentTimeMillis())
        }
        present(context, state)
    }

    private fun finishPreview(response: String) {
        previewDeadline?.let { handler.removeCallbacks(it) }; previewDeadline = null
        previewState = null
        FallAlertFeedback.stop()
        dismiss()
        android.util.Log.i("PhoneFallAlarm", "Local preview resolved: $response; no caregiver alert sent")
    }
}

/** The same responsive view is used by the alarm activity and overlay fallback. */
class PhoneFallAlarmView(context: Context, private val eventId: String) : ScrollView(context) {
    private val handler = Handler(Looper.getMainLooper())
    private val seconds = TextView(context)
    private val explanation = TextView(context)
    private val countdownStatus = TextView(context)
    private var lastSeconds = -1
    private val tick = object : Runnable {
        override fun run() {
            val state = PhoneFallAlarm.current(context)
            if (state?.eventId != eventId) return
            val remaining = state.secondsLeft()
            if (remaining != lastSeconds) {
                lastSeconds = remaining
                seconds.text = "$remaining"
                seconds.contentDescription = "$remaining seconds until caregiver alert"
                explanation.text = if (state.preview) "Preview only — no caregiver alert will be sent"
                    else "Emergency alert will be sent in $remaining seconds"
                countdownStatus.text = "Countdown: $remaining seconds"
            }
            handler.postDelayed(this, 200)
        }
    }

    init {
        isFillViewport = true
        setBackgroundColor(0xffffcdc7.toInt())
        isFocusableInTouchMode = true
        val outer = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER
            setPadding(dp(24), dp(28), dp(24), dp(28))
        }
        addView(outer, LayoutParams(-1, -1))
        val content = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER }
        // Keep the card comfortable on phones, landscape displays and tablets.
        outer.addView(content, LinearLayout.LayoutParams(
            min(resources.displayMetrics.widthPixels - dp(48), dp(430)), -2))
        content.addView(label("Fall Detected", 28f, 0xffef3535.toInt(), true), row(bottom = 26))
        val card = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER
            setPadding(dp(20), dp(26), dp(20), dp(24))
            background = rounded(Color.WHITE, 28f); elevation = dp(5).toFloat()
        }
        content.addView(card, row())
        val circle = object : FrameLayout(context) {
            private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            init { setWillNotDraw(false) }
            override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
                val comfortableHeight = (resources.displayMetrics.heightPixels * .26).toInt()
                    .coerceIn(dp(160), dp(260))
                val size = min(View.MeasureSpec.getSize(widthMeasureSpec), comfortableHeight)
                super.onMeasure(View.MeasureSpec.makeMeasureSpec(size, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(size, View.MeasureSpec.EXACTLY))
            }
            override fun onDraw(canvas: Canvas) {
                super.onDraw(canvas)
                val radius = min(width, height) / 2f - dp(2)
                paint.style = Paint.Style.FILL; paint.color = 0xfffff3f1.toInt()
                canvas.drawCircle(width / 2f, height / 2f, radius, paint)
                paint.style = Paint.Style.STROKE; paint.strokeWidth = dp(1).toFloat(); paint.color = 0xffffa8a1.toInt()
                canvas.drawCircle(width / 2f, height / 2f, radius, paint)
                paint.style = Paint.Style.FILL; paint.color = 0xffffe3df.toInt()
                canvas.drawCircle(width / 2f, height / 2f, radius * .65f, paint)
            }
        }
        val counter = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER }
        counter.addView(label("SOS", 36f, 0xffff3b3b.toInt(), true))
        seconds.apply { textSize = 30f; gravity = Gravity.CENTER; setTextColor(0xffef3535.toInt()); setTypeface(null, Typeface.BOLD) }
        counter.addView(seconds)
        counter.addView(label("seconds", 13f, 0xff88766e.toInt()))
        circle.addView(counter, FrameLayout.LayoutParams(-1, -2, Gravity.CENTER))
        card.addView(circle, LinearLayout.LayoutParams(-1, -2).apply { gravity = Gravity.CENTER_HORIZONTAL })
        explanation.apply { textSize = 16f; gravity = Gravity.CENTER; setTextColor(0xff302722.toInt()); setTypeface(null, Typeface.BOLD) }
        card.addView(explanation, row(top = 22, bottom = 12))
        fun button(title: String, color: Int, send: Boolean) {
            card.addView(Button(context).apply {
                text = title; isAllCaps = false; textSize = 18f; minHeight = dp(58)
                setPadding(dp(12), dp(12), dp(12), dp(12)); setTextColor(Color.WHITE)
                setTypeface(null, Typeface.BOLD); background = rounded(color, 18f)
                elevation = dp(2).toFloat()
                setOnClickListener { PhoneFallAlarm.respond(context, eventId, send) }
            }, row(top = if (send) 12 else 0))
        }
        button("I'm OK / Cancel Alert", 0xff18865b.toInt(), false)
        button("Send alert now", 0xffdf302c.toInt(), true)
        content.addView(label("Auto-triggered by fall detection", 13f, 0xfff1332b.toInt()), row(top = 20, bottom = 12))
        val statuses = LinearLayout(context).apply { gravity = Gravity.CENTER }
        val detected = label("Fall detected", 12f, 0xffed8a00.toInt()).apply {
            background = rounded(0xfffff5d7.toInt(), 24f); setPadding(dp(12), dp(7), dp(12), dp(7))
        }
        statuses.addView(detected, LinearLayout.LayoutParams(-2, -2).apply { marginEnd = dp(8) })
        countdownStatus.apply {
            textSize = 12f; gravity = Gravity.CENTER; setTextColor(0xffec332c.toInt())
            background = rounded(0xffffeeec.toInt(), 24f); setPadding(dp(12), dp(7), dp(12), dp(7))
        }
        statuses.addView(countdownStatus, LinearLayout.LayoutParams(-2, -2))
        content.addView(statuses, row())
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun row(top: Int = 0, bottom: Int = 0) = LinearLayout.LayoutParams(-1, -2).apply {
        topMargin = dp(top); bottomMargin = dp(bottom)
    }
    private fun rounded(color: Int, radius: Float) = GradientDrawable().apply {
        setColor(color); cornerRadius = radius * resources.displayMetrics.density
    }
    private fun label(value: String, size: Float, color: Int, bold: Boolean = false) = TextView(context).apply {
        text = value; textSize = size; gravity = Gravity.CENTER; setTextColor(color)
        if (bold) setTypeface(null, Typeface.BOLD)
    }
    override fun onAttachedToWindow() { super.onAttachedToWindow(); handler.post(tick) }
    override fun onDetachedFromWindow() { handler.removeCallbacks(tick); super.onDetachedFromWindow() }
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean =
        if (keyCode == KeyEvent.KEYCODE_BACK) true else super.onKeyDown(keyCode, event)
}

class PhoneFallAlarmActivity : Activity() {
    private var eventId = ""
    private val changed: () -> Unit = {
        if (PhoneFallAlarm.current(this)?.eventId != eventId || !PhoneFallAlarm.isShowing()) finish()
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 27) { setShowWhenLocked(true); setTurnScreenOn(true) }
        @Suppress("DEPRECATION")
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= 33) onBackInvokedDispatcher.registerOnBackInvokedCallback(0) { }
        PhoneFallAlarm.listen(changed)
        bindAlarm()
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); bindAlarm() }
    private fun bindAlarm() {
        eventId = intent.getStringExtra("eventId") ?: ""
        if (eventId.isEmpty() || PhoneFallAlarm.current(this)?.eventId != eventId) { finish(); return }
        val alarmView = PhoneFallAlarmView(this, eventId)
        setContentView(alarmView)
        if (Build.VERSION.SDK_INT >= 30) {
            // Some phones have no decor during onCreate. View.post waits for
            // attachment, and the view getter safely returns null if detached.
            alarmView.post {
                val controller = alarmView.windowInsetsController ?: return@post
                val appearance = android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                    android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
                controller.setSystemBarsAppearance(appearance, appearance)
            }
        }
    }
    override fun onResume() { super.onResume(); PhoneFallAlarm.activityVisible(eventId); changed() }
    @Deprecated("Use the explicit cancel or send response")
    override fun onBackPressed() { }
    override fun onDestroy() { PhoneFallAlarm.unlisten(changed); super.onDestroy() }
}
