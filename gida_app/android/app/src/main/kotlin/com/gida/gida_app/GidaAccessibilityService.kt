package com.gida.gida_app

import android.accessibilityservice.AccessibilityService
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.TypedValue
import android.view.Display
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.plugin.common.EventChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

class GidaAccessibilityService : AccessibilityService() {
    companion object {
        private const val TAG = "GidaAccessibility"
        var eventSink: EventChannel.EventSink? = null
        var instance: GidaAccessibilityService? = null
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

    private val ignoredSystemPackages = setOf(
        "com.android.systemui",
        "android"
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private val debounceHandler = Handler(Looper.getMainLooper())
    private var pendingRunnable: Runnable? = null
    private val debounceDelay = 1200L
    private val ioExecutor = Executors.newSingleThreadExecutor()

    // Yerel kara liste (normalize edilmiş URL/host -> engellenme sebebi)
    private val blockedSites = ConcurrentHashMap<String, String>()

    // Yarış durumu (Race Condition) koruması için canlı durum değişkenleri
    @Volatile
    private var currentForegroundPackage: String = ""

    @Volatile
    private var currentBrowserUrl: String = ""

    @Volatile
    private var isOverlayShowing: Boolean = false
    private var overlayView: View? = null
    private var overlayBlockedUrl: String = ""

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.d(TAG, "Service Connected successfully")
    }

    override fun onDestroy() {
        removeBlockOverlay()
        if (instance === this) {
            instance = null
        }
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return

        val packageName = event.packageName?.toString() ?: return

        // Kendi uygulamamızdan veya sistem UI'dan gelen eventleri yoksay
        if (packageName == this.packageName || ignoredSystemPackages.contains(packageName)) {
            return
        }

        // Kullanıcı tarayıcı dışındaki bir uygulamaya (örn. Ana Ekran, WhatsApp) geçtiyse
        if (!browserPackages.contains(packageName)) {
            if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
                currentForegroundPackage = packageName
                currentBrowserUrl = ""
                pendingRunnable?.let { debounceHandler.removeCallbacks(it) }
                if (isOverlayShowing) {
                    Log.d(TAG, "User left browser to $packageName, removing block overlay")
                    removeBlockOverlay()
                }
            }
            return
        }

        currentForegroundPackage = packageName

        val eventType = event.eventType
        if (eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            eventType != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED
        ) return

        // Anlık URL kontrolü: Eğer yerel kara listedeyse debounce beklemeden (0ms) anında engelle
        val rootNode = rootInActiveWindow
        if (rootNode != null) {
            val liveUrl = extractUrl(rootNode)
            if (liveUrl.isNotEmpty()) {
                currentBrowserUrl = liveUrl

                // Eğer kullanıcı engelli siteden başka güvenli bir siteye geçtiyse perdeyi kaldır
                if (isOverlayShowing && overlayBlockedUrl.isNotEmpty() && !urlsMatch(liveUrl, overlayBlockedUrl)) {
                    Log.d(TAG, "User navigated away from blocked site to $liveUrl, removing overlay")
                    removeBlockOverlay()
                }

                // Yerel kara listede var mı?
                val cachedReason = findBlockReasonInLocalCache(liveUrl)
                if (cachedReason != null) {
                    pendingRunnable?.let { debounceHandler.removeCallbacks(it) }
                    Log.d(TAG, "Instant local blacklist hit for $liveUrl")
                    showBlockOverlay(liveUrl, cachedReason)
                    return
                }
            }
        }

        val eventTypeStr = when (eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> "TYPE_WINDOW_STATE_CHANGED"
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED -> "TYPE_WINDOW_CONTENT_CHANGED"
            else -> AccessibilityEvent.eventTypeToString(eventType)
        }

        // Proper debounce: cancel pending task and wait until DOM/media settles
        pendingRunnable?.let { debounceHandler.removeCallbacks(it) }
        val task = Runnable {
            processActiveWindow(packageName, eventTypeStr)
        }
        pendingRunnable = task
        debounceHandler.postDelayed(task, debounceDelay)
    }

    /**
     * Flutter üzerinden sunucudan "engelle" kararı geldiğinde çağrılır.
     * Önce yerel kara listeye ekler, ardından kullanıcının hala o sitede olup olmadığını canlı kontrol eder.
     */
    fun handleBlockCommand(targetUrl: String, reason: String): Boolean {
        val normTarget = normalizeUrl(targetUrl)
        if (normTarget.isEmpty()) return false

        // 1. Yerel kara listeye kaydet (kullanıcı çıkmış olsa bile tekrar girdiğinde anında engellenecek)
        val hostKey = extractHost(targetUrl).ifEmpty { normTarget }
        blockedSites[hostKey] = reason
        blockedSites[normTarget] = reason
        Log.d(TAG, "Added to local blacklist: host='$hostKey', url='$normTarget', reason='$reason'")

        // 2. CANLI KONTROL (Race Condition Koruması): Kullanıcı hala tarayıcıda ve bu sitede mi?
        val rootNode = rootInActiveWindow
        val activePkg = rootNode?.packageName?.toString() ?: currentForegroundPackage

        if (!browserPackages.contains(activePkg) && activePkg != this.packageName) {
            Log.d(
                TAG,
                "Race condition prevented: User is no longer in browser (activePkg=$activePkg). Target '$targetUrl' only added to blacklist."
            )
            return false
        }

        val liveExtractedUrl = if (rootNode != null && browserPackages.contains(activePkg)) {
            extractUrl(rootNode)
        } else {
            ""
        }

        if (liveExtractedUrl.isNotEmpty()) {
            currentBrowserUrl = liveExtractedUrl
        }

        val effectiveCurrentUrl = if (liveExtractedUrl.isNotEmpty()) liveExtractedUrl else currentBrowserUrl

        if (effectiveCurrentUrl.isEmpty() || !urlsMatch(effectiveCurrentUrl, targetUrl)) {
            Log.d(
                TAG,
                "Race condition prevented: User already moved to '$effectiveCurrentUrl' (target was '$targetUrl'). Only added to blacklist."
            )
            return false
        }

        // 3. Kullanıcı hala aynı sıkıntılı sitede -> Engel ekranını hemen indir!
        Log.d(TAG, "Live check passed! User is still on '$effectiveCurrentUrl'. Showing block overlay.")
        showBlockOverlay(effectiveCurrentUrl, reason)
        return true
    }

    fun clearLocalBlacklist() {
        blockedSites.clear()
        removeBlockOverlay()
    }

    private fun normalizeUrl(rawUrl: String): String {
        return rawUrl.trim()
            .lowercase()
            .removePrefix("https://")
            .removePrefix("http://")
            .removePrefix("www.")
            .trimEnd('/')
    }

    private fun extractHost(rawUrl: String): String {
        val norm = normalizeUrl(rawUrl)
        val host = norm.substringBefore('/').substringBefore('?')
        // Geçerli bir domain olup olmadığını kontrol et (örn. "Google" gibi başlıkları domain sanma)
        return if (host.contains('.')) host else ""
    }

    private fun urlsMatch(urlA: String, urlB: String): Boolean {
        val normA = normalizeUrl(urlA)
        val normB = normalizeUrl(urlB)
        if (normA.isEmpty() || normB.isEmpty()) return false
        if (normA == normB) return true
        if (normA.startsWith(normB) || normB.startsWith(normA)) return true

        val hostA = extractHost(urlA)
        val hostB = extractHost(urlB)
        if (hostA.isNotEmpty() && hostB.isNotEmpty() && hostA == hostB) {
            return true
        }
        return false
    }

    private fun findBlockReasonInLocalCache(url: String): String? {
        val norm = normalizeUrl(url)
        if (norm.isEmpty()) return null

        blockedSites[norm]?.let { return it }
        val host = extractHost(url)
        if (host.isNotEmpty()) {
            blockedSites[host]?.let { return it }
        }

        for ((blockedKey, reason) in blockedSites.entries) {
            if (urlsMatch(url, blockedKey)) {
                return reason
            }
        }
        return null
    }

    private fun showBlockOverlay(blockedUrl: String, reason: String) {
        mainHandler.post {
            try {
                if (isOverlayShowing && overlayView != null) {
                    overlayBlockedUrl = blockedUrl
                    return@post
                }

                val wm = getSystemService(WINDOW_SERVICE) as WindowManager
                val params = WindowManager.LayoutParams(
                    WindowManager.LayoutParams.MATCH_PARENT,
                    WindowManager.LayoutParams.MATCH_PARENT,
                    WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                        WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
                    PixelFormat.TRANSLUCENT
                ).apply {
                    gravity = Gravity.CENTER
                }

                val rootLayout = LinearLayout(this).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.CENTER
                    setBackgroundColor(Color.parseColor("#F2141824"))
                    setPadding(dp(28), dp(28), dp(28), dp(28))
                }

                val cardLayout = LinearLayout(this).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.CENTER_HORIZONTAL
                    setPadding(dp(24), dp(32), dp(24), dp(28))
                    background = GradientDrawable().apply {
                        setColor(Color.parseColor("#1E2436"))
                        cornerRadius = dp(20).toFloat()
                        setStroke(dp(2), Color.parseColor("#EF4444"))
                    }
                }

                val iconText = TextView(this).apply {
                    text = "🛡️"
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 48f)
                    gravity = Gravity.CENTER
                }

                val titleText = TextView(this).apply {
                    text = "Bu Site GiDA Tarafından Engellendi"
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
                    setTextColor(Color.WHITE)
                    typeface = Typeface.DEFAULT_BOLD
                    gravity = Gravity.CENTER
                    setPadding(0, dp(16), 0, dp(8))
                }

                val urlBadge = TextView(this).apply {
                    text = blockedUrl
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                    setTextColor(Color.parseColor("#FCA5A5"))
                    gravity = Gravity.CENTER
                    setPadding(dp(12), dp(6), dp(12), dp(6))
                    background = GradientDrawable().apply {
                        setColor(Color.parseColor("#3B1D27"))
                        cornerRadius = dp(8).toFloat()
                    }
                }

                val reasonText = TextView(this).apply {
                    text = reason.ifEmpty { "Güvenli internet politikası kapsamında bu sayfaya erişim kısıtlanmıştır." }
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                    setTextColor(Color.parseColor("#D1D5DB"))
                    gravity = Gravity.CENTER
                    setPadding(0, dp(16), 0, dp(24))
                }

                val backButton = Button(this).apply {
                    text = "Güvenli Sayfaya Dön"
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                    setTextColor(Color.WHITE)
                    typeface = Typeface.DEFAULT_BOLD
                    isAllCaps = false
                    setPadding(dp(24), dp(12), dp(24), dp(12))
                    background = GradientDrawable().apply {
                        setColor(Color.parseColor("#EF4444"))
                        cornerRadius = dp(12).toFloat()
                    }
                    setOnClickListener {
                        removeBlockOverlay()
                        // Kullanıcıyı engellenen sayfadan geri çıkar
                        performGlobalAction(GLOBAL_ACTION_BACK)
                    }
                }

                cardLayout.addView(iconText)
                cardLayout.addView(titleText)
                cardLayout.addView(urlBadge)
                cardLayout.addView(reasonText)
                cardLayout.addView(backButton)
                rootLayout.addView(cardLayout)

                wm.addView(rootLayout, params)
                overlayView = rootLayout
                overlayBlockedUrl = blockedUrl
                isOverlayShowing = true
            } catch (e: Exception) {
                Log.e(TAG, "Error showing accessibility block overlay", e)
            }
        }
    }

    private fun removeBlockOverlay() {
        mainHandler.post {
            try {
                overlayView?.let { view ->
                    val wm = getSystemService(WINDOW_SERVICE) as WindowManager
                    wm.removeViewImmediate(view)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Error removing block overlay: ${e.message}")
            } finally {
                overlayView = null
                overlayBlockedUrl = ""
                isOverlayShowing = false
            }
        }
    }

    private fun dp(value: Int): Int {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            resources.displayMetrics
        ).toInt()
    }

    private fun sanitizeUrlForCapture(rawUrl: String): String {
        var trimmed = rawUrl.trim()
        if (trimmed.isEmpty()) return ""
        if (!trimmed.startsWith("http://", ignoreCase = true) && !trimmed.startsWith("https://", ignoreCase = true)) {
            trimmed = "https://$trimmed"
        }
        return try {
            val uri = java.net.URI(trimmed)
            val scheme = uri.scheme ?: "https"
            val host = uri.host ?: return trimmed.substringBefore('?').substringBefore('#')
            val portPart = if (uri.port != -1 && uri.port != 80 && uri.port != 443) ":${uri.port}" else ""
            val path = uri.path ?: "/"
            val cleanPath = if (path.isEmpty()) "/" else path
            "$scheme://$host$portPart$cleanPath"
        } catch (e: Exception) {
            trimmed.substringBefore('?').substringBefore('#')
        }
    }

    private fun processActiveWindow(packageName: String, eventTypeStr: String) {
        val rootNode = rootInActiveWindow ?: return
        
        val url = extractUrl(rootNode)
        if (url.isNotEmpty()) {
            currentBrowserUrl = url
            val cachedReason = findBlockReasonInLocalCache(url)
            if (cachedReason != null) {
                Log.d(TAG, "Blocked site detected during processActiveWindow: $url")
                showBlockOverlay(url, cachedReason)
                return
            }
        }

        val webViewNode = findWebViewNode(rootNode)
        val title = extractTitle(rootNode)
        val screenTextList = extractScreenTextList(webViewNode ?: rootNode)
        val visibleText = screenTextList.joinToString(" ")
        val rawNodes = extractNodesArray(rootNode)
        val imageBounds = extractImageBounds(rootNode)
        val appName = if (packageName == "com.android.chrome") "Chrome (Web)" else resolveAppName(packageName)
        val eventType = if (eventTypeStr.contains("STATE_CHANGED", ignoreCase = true)) "WEB_NAVIGATION" else "WEB_PAGE_VISIBLE"

        // URL'yi ilk görünür düğüm olarak ekle (GiDA browser analyzer için zorunlu)
        val cleanUrl = sanitizeUrlForCapture(url)
        val nodesArray = JSONArray()
        if (cleanUrl.isNotEmpty()) {
            nodesArray.put(JSONObject().apply {
                put("text", cleanUrl)
                put("visibleToUser", true)
            })
        }
        for (i in 0 until rawNodes.length()) {
            val n = rawNodes.getJSONObject(i)
            if (n.optString("text") != cleanUrl) {
                nodesArray.put(n)
            }
        }

        Log.d(TAG, "Processing window $packageName ($appName) -> URL: $url | Texts: ${screenTextList.size} | Nodes: ${nodesArray.length()} | Images: ${imageBounds.size}")

        if (url.isEmpty() && visibleText.isEmpty() && nodesArray.length() == 0) {
            return
        }

        val currentTime = System.currentTimeMillis()
        val isoFormatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US)
        val capturedAtIso = isoFormatter.format(Date(currentTime))

        val json = JSONObject().apply {
            // UI & local fields
            put("url", url)
            put("page_title", title)
            put("visible_text", visibleText)
            put("browser_package", packageName)
            put("timestamp", currentTime.toString())
            // GiDA /v1/captures contract
            put("packageName", packageName)
            put("appName", appName)
            put("eventType", eventType)
            put("event_type", eventType)
            put("sourceType", "web")
            put("capturedAtDevice", capturedAtIso)
            put("screenText", JSONArray(screenTextList))
            put("nodes", nodesArray)
            put("isTargetApp", true)
            put("isSupportedEventType", true)
        }

        if (imageBounds.isNotEmpty() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                takeScreenshot(
                    Display.DEFAULT_DISPLAY,
                    mainExecutor,
                    object : TakeScreenshotCallback {
                        override fun onSuccess(screenshotResult: ScreenshotResult) {
                            ioExecutor.execute {
                                val hardwareBuffer = screenshotResult.hardwareBuffer
                                val colorSpace = screenshotResult.colorSpace
                                val hwBitmap = Bitmap.wrapHardwareBuffer(hardwareBuffer, colorSpace)
                                val swBitmap = hwBitmap?.copy(Bitmap.Config.ARGB_8888, false)
                                hardwareBuffer.close()

                                val imagePaths = if (swBitmap != null) {
                                    val paths = cropAndSaveImages(swBitmap, imageBounds)
                                    swBitmap.recycle()
                                    paths
                                } else {
                                    emptyList()
                                }

                                json.put("image_paths", JSONArray(imagePaths))
                                emitEvent(json)
                            }
                        }

                        override fun onFailure(errorCode: Int) {
                            Log.w(TAG, "takeScreenshot failed with code: $errorCode")
                            json.put("image_paths", JSONArray())
                            emitEvent(json)
                        }
                    }
                )
            } catch (e: Exception) {
                Log.e(TAG, "Exception calling takeScreenshot", e)
                json.put("image_paths", JSONArray())
                emitEvent(json)
            }
        } else {
            json.put("image_paths", JSONArray())
            emitEvent(json)
        }
    }

    private fun resolveAppName(packageName: String): String {
        return try {
            val appInfo = packageManager.getApplicationInfo(packageName, 0)
            packageManager.getApplicationLabel(appInfo).toString()
        } catch (e: Exception) {
            packageName
        }
    }

    private fun emitEvent(json: JSONObject) {
        mainHandler.post {
            eventSink?.let { sink ->
                sink.success(json.toString())
                Log.d(TAG, "Sent data to Flutter EventSink (${json.optJSONArray("image_paths")?.length() ?: 0} images)")
            } ?: Log.w(TAG, "EventSink is null, Flutter app not listening")
        }
    }

    private fun findWebViewNode(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(node)
        var count = 0
        while (queue.isNotEmpty() && count < 100) {
            val current = queue.removeFirst()
            count++
            val className = current.className?.toString() ?: ""
            if (className.contains("WebView", ignoreCase = true)) {
                return current
            }
            for (i in 0 until current.childCount) {
                current.getChild(i)?.let { queue.add(it) }
            }
        }
        return null
    }

    private fun extractImageBounds(rootNode: AccessibilityNodeInfo): List<Rect> {
        val boundsList = mutableListOf<Rect>()
        // 1. MUST HAVE A WEBVIEW: If there is no WebView (e.g. typing in address bar, home screen), do NOT capture images!
        val webViewNode = findWebViewNode(rootNode) ?: return emptyList()

        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(webViewNode)
        var count = 0

        while (queue.isNotEmpty() && count < 500) {
            val current = queue.removeFirst()
            count++

            val className = current.className?.toString() ?: ""
            val viewId = current.viewIdResourceName?.toString() ?: ""

            // Exclude browser controls and buttons
            val isBrowserControl = viewId.contains("com.android.chrome:id") ||
                                   viewId.contains("toolbar") ||
                                   viewId.contains("button") ||
                                   className.contains("Button", ignoreCase = true)

            // True web images inside WebView
            val isImage = (className.contains("Image", ignoreCase = true) ||
                           className.contains("Picture", ignoreCase = true) ||
                           viewId.contains("image", ignoreCase = true) ||
                           viewId.contains("photo", ignoreCase = true) ||
                           viewId.contains("img", ignoreCase = true)) && !isBrowserControl

            if (isImage && current.isVisibleToUser) {
                val rect = Rect()
                current.getBoundsInScreen(rect)

                // Minimum size: 150x120 to ignore small arrows, icons, and bullets, and must be in web view area
                if (rect.width() >= 150 && rect.height() >= 120 && rect.top >= 250 && rect.bottom <= 2350) {
                    val isDuplicateOrSub = boundsList.any { existing ->
                        (Math.abs(existing.left - rect.left) < 30 && Math.abs(existing.top - rect.top) < 30) ||
                        existing.contains(rect)
                    }
                    if (!isDuplicateOrSub) {
                        boundsList.add(rect)
                        if (boundsList.size >= 8) break
                    }
                }
            }

            for (i in 0 until current.childCount) {
                current.getChild(i)?.let { queue.add(it) }
            }
        }
        return boundsList
    }

    private fun cropAndSaveImages(bitmap: Bitmap, imageBounds: List<Rect>): List<String> {
        val savedPaths = mutableListOf<String>()
        val captureDir = File(cacheDir, "captures")
        if (!captureDir.exists()) {
            captureDir.mkdirs()
        }

        val timestamp = System.currentTimeMillis()
        for ((index, rect) in imageBounds.withIndex()) {
            try {
                val x = rect.left.coerceIn(0, bitmap.width - 1)
                val y = rect.top.coerceIn(0, bitmap.height - 1)
                val w = rect.width().coerceAtMost(bitmap.width - x)
                val h = rect.height().coerceAtMost(bitmap.height - y)

                if (w > 50 && h > 50) {
                    val cropped = Bitmap.createBitmap(bitmap, x, y, w, h)
                    val file = File(captureDir, "img_${timestamp}_$index.jpg")
                    FileOutputStream(file).use { out ->
                        cropped.compress(Bitmap.CompressFormat.JPEG, 85, out)
                    }
                    cropped.recycle()
                    savedPaths.add(file.absolutePath)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error cropping image index $index", e)
            }
        }
        return savedPaths
    }

    private fun extractTitle(rootNode: AccessibilityNodeInfo): String {
        val webViewNode = findWebViewNode(rootNode)
        val title = webViewNode?.contentDescription?.toString()?.trim() ?: ""
        if (title.isNotEmpty()) return title
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

    private fun extractScreenTextList(node: AccessibilityNodeInfo): List<String> {
        val list = mutableListOf<String>()
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(node)
        var count = 0
        while (queue.isNotEmpty() && count < 250) {
            val current = queue.removeFirst()
            count++

            if (current.isVisibleToUser) {
                val text = current.text?.toString()?.trim()
                val desc = current.contentDescription?.toString()?.trim()
                if (!text.isNullOrEmpty() && text.length > 1) {
                    list.add(text)
                } else if (!desc.isNullOrEmpty() && desc.length > 1) {
                    list.add(desc)
                }
            }

            for (i in 0 until current.childCount) {
                current.getChild(i)?.let { queue.add(it) }
            }
        }
        return list
    }

    private fun extractNodesArray(rootNode: AccessibilityNodeInfo): JSONArray {
        val arr = JSONArray()
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(rootNode)
        var count = 0
        while (queue.isNotEmpty() && count < 150) {
            val current = queue.removeFirst()
            count++

            // Parola ve gizli alanları ASLA toplama
            if (current.isPassword) {
                continue
            }

            if (current.isVisibleToUser) {
                val text = current.text?.toString()?.trim()
                val desc = current.contentDescription?.toString()?.trim()
                val className = current.className?.toString()
                val viewId = current.viewIdResourceName?.toString()

                if (!text.isNullOrEmpty() || !desc.isNullOrEmpty()) {
                    val nodeText = if (!text.isNullOrEmpty()) text else desc
                    val nodeObj = JSONObject().apply {
                        put("text", nodeText)
                        if (!desc.isNullOrEmpty()) put("contentDescription", desc)
                        put("visibleToUser", true)
                        put("className", className ?: JSONObject.NULL)
                        put("viewIdResourceName", viewId ?: JSONObject.NULL)
                        put("isClickable", current.isClickable)
                        put("isEditable", current.isEditable)
                    }
                    arr.put(nodeObj)
                }
            }

            for (i in 0 until current.childCount) {
                current.getChild(i)?.let { queue.add(it) }
            }
        }
        return arr
    }

    override fun onInterrupt() {
        Log.d(TAG, "Service Interrupted")
    }
}
