package com.superconnect.receiver

import android.content.Context
import android.text.InputType as AndroidInputType
import android.view.KeyEvent
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.widget.EditText

/**
 * Hidden soft-keyboard capture surface — analogue of harmony `ui/ImeCatcher.ets`. A 0-opacity EditText
 * that owns the SOFT keyboard so committed text (incl. CJK) reaches the Mac without a visible field:
 *   • commitText(…)          → onText  (CONTROL `{type:text}`)
 *   • deleteSurroundingText  → onBackspace (Mac Backspace keystroke)
 *   • sendKeyEvent           → onKey (route hardware-style keys through the keyboard handler)
 * Composing (pinyin → 汉字) is kept in the invisible editable so 3rd-party IMEs compose normally; the
 * final text arrives via commitText and the buffer is cleared, so the field never retains anything.
 * Physical keys are captured at the Activity level (dispatchKeyEvent), independent of this view's focus.
 */
class ImeCatcher(
    context: Context,
    private val onText: (CharSequence) -> Unit,
    private val onBackspace: (Int) -> Unit,
    private val onKey: (KeyEvent) -> Boolean,
) : EditText(context) {
    init {
        isFocusable = true
        isFocusableInTouchMode = true
        alpha = 0f
        setBackgroundColor(0)
    }

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = AndroidInputType.TYPE_CLASS_TEXT or AndroidInputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_FLAG_NO_EXTRACT_UI
        return object : BaseInputConnection(this, true) {
            override fun commitText(text: CharSequence, newCursorPosition: Int): Boolean {
                if (text.isNotEmpty()) onText(text)
                editable?.clear()                       // never retain — pure capture surface
                return true
            }

            override fun setComposingText(text: CharSequence, newCursorPosition: Int): Boolean =
                super.setComposingText(text, newCursorPosition)   // compose invisibly; commit sends it

            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                if (beforeLength > 0) onBackspace(beforeLength)
                return true
            }

            override fun sendKeyEvent(event: KeyEvent): Boolean {
                if (onKey(event)) return true
                return super.sendKeyEvent(event)
            }
        }
    }
}
