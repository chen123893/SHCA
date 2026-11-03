package com.shca.shca

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.*

/** Native EditText keeps Samsung/Wear OS IME edits synchronized before returning to Flutter. */
class WatchCredentialActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val password = intent.getStringExtra("field") == "password"
        if (password) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val density = resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(28), dp(30), dp(28), dp(30))
            setBackgroundColor(0xfffff8f1.toInt())
        }
        column.addView(TextView(this).apply {
            text = if (password) "Password" else "Email address"
            textSize = 18f
            setTextColor(0xff241d19.toInt())
            gravity = android.view.Gravity.CENTER
        })
        val edit = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT or (if (password)
                InputType.TYPE_TEXT_VARIATION_PASSWORD or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
                else InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS)
            isSingleLine = true
            imeOptions = EditorInfo.IME_ACTION_DONE
            textSize = 16f
            isSaveEnabled = false
            setAutofillHints(if (password) View.AUTOFILL_HINT_PASSWORD else View.AUTOFILL_HINT_EMAIL_ADDRESS)
            setText(intent.getStringExtra("value") ?: "")
            setSelection(text.length)
            minHeight = dp(48)
        }
        fun done() {
            setResult(RESULT_OK, Intent().putExtra("value", edit.text.toString()))
            finish()
        }
        edit.setOnEditorActionListener { _, action, _ ->
            if (action == EditorInfo.IME_ACTION_DONE) { done(); true } else false
        }
        column.addView(edit, LinearLayout.LayoutParams(-1, -2))
        if (!password) column.addView(Button(this).apply {
            text = "@"
            contentDescription = "Insert at sign"
            setOnClickListener {
                val start = maxOf(0, edit.selectionStart)
                val end = maxOf(start, edit.selectionEnd)
                edit.text.replace(start, end, "@")
                edit.requestFocus()
            }
        }, LinearLayout.LayoutParams(-1, dp(44)))
        column.addView(Button(this).apply {
            text = "Done"
            setTextColor(0xffffffff.toInt())
            backgroundTintList = android.content.res.ColorStateList.valueOf(0xffff7518.toInt())
            setOnClickListener { done() }
        }, LinearLayout.LayoutParams(-1, dp(48)))
        setContentView(ScrollView(this).apply { isFillViewport = true; addView(column) })
        edit.requestFocus()
        edit.postDelayed({
            (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager)
                .showSoftInput(edit, InputMethodManager.SHOW_IMPLICIT)
        }, 180)
    }
}
