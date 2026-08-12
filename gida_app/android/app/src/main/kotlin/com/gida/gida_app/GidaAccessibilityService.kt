package com.gida.gida_app

import android.accessibilityservice.AccessibilityService
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import io.flutter.plugin.common.EventChannel
import org.json.JSONObject

class GidaAccessibilityService : AccessibilityService() {
    companion object {
        private const val TAG = "GidaAccessibility"
        var eventSink: EventChannel.EventSink? = null
    }

    private val browserPackages = setOf(
        "com.android.chrome",
        "com.chrome.canary",
        "com.chrome.beta",
        "com.chrome.dev",
        "org.mozilla.firefox",
        "com.sec.android.app.sbrowser",
        "com.opera.browser",
        "com.microsoft.emmx",
        "com.brave.browser"
    )

    private var lastEventTime = 0L
    private val debounceDelay = 300L

    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.d(TAG, "Service Connected successfully")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        
        val packageName = event.packageName?.toString() ?: return
        if (!browserPackages.contains(packageName)) return

        val eventType = event.eventType
        if (eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED && eventType != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED) return

        val currentTime = System.currentTimeMillis()
        if (currentTime - lastEventTime < debounceDelay) return
        lastEventTime = currentTime

        val rootNode = rootInActiveWindow ?: return
        
        val url = extractUrl(rootNode)
        val title = extractTitle(event, rootNode)
        val visibleText = extractVisibleText(rootNode)

        Log.d(TAG, "Captured event from $packageName -> URL: $url | Title: $title")

        if (url.isEmpty() && visibleText.isEmpty()) {
            return
        }

        val json = JSONObject().apply {
            put("url", url)
            put("page_title", title)
            put("visible_text", visibleText)
            put("browser_package", packageName)
            put("timestamp", currentTime.toString())
            put("event_type", "PAGE_VISIT")
        }
        
        Handler(Looper.getMainLooper()).post {
            eventSink?.let { sink ->
                sink.success(json.toString())
                Log.d(TAG, "Sent data to Flutter EventSink")
            } ?: Log.w(TAG, "EventSink is null, Flutter app not listening")
        }
    }

    private fun extractTitle(event: AccessibilityEvent, rootNode: AccessibilityNodeInfo): String {
        val eventTitle = event.text.joinToString(" ").trim()
        if (eventTitle.isNotEmpty()) return eventTitle
        val description = event.contentDescription?.toString()?.trim()
        if (!description.isNullOrEmpty()) return description
        return rootNode.text?.toString() ?: ""
    }

    private fun extractUrl(node: AccessibilityNodeInfo): String {
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(node)
        while (queue.isNotEmpty()) {
            val current = queue.removeFirst()
            val className = current.className?.toString() ?: ""
            val viewId = current.viewIdResourceName?.toString() ?: ""

            if (className.contains("EditText", ignoreCase = true) || 
                className.contains("AutoCompleteTextView", ignoreCase = true) ||
                viewId.contains("url_bar", ignoreCase = true) ||
                viewId.contains("search_box", ignoreCase = true) ||
                viewId.contains("location_bar", ignoreCase = true)) {
                val text = current.text?.toString()
                if (!text.isNullOrEmpty()) {
                    return text
                }
            }

            for (i in 0 until current.childCount) {
                current.getChild(i)?.let { queue.add(it) }
            }
        }
        return ""
    }

    private fun extractVisibleText(node: AccessibilityNodeInfo): String {
        val stringBuilder = java.lang.StringBuilder()
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(node)
        var count = 0
        while (queue.isNotEmpty() && count < 200) {
            val current = queue.removeFirst()
            count++
            
            if (current.isVisibleToUser) {
                val text = current.text?.toString()
                val desc = current.contentDescription?.toString()
                if (!text.isNullOrEmpty() && text.length > 2) {
                    stringBuilder.append(text).append(" ")
                } else if (!desc.isNullOrEmpty() && desc.length > 2) {
                    stringBuilder.append(desc).append(" ")
                }
            }
            
            for (i in 0 until current.childCount) {
                current.getChild(i)?.let { queue.add(it) }
            }
        }
        return stringBuilder.toString().trim()
    }

    override fun onInterrupt() {
        Log.d(TAG, "Service Interrupted")
    }
}
