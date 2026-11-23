package com.gida.gida_app

import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.accessibilityservice.AccessibilityServiceInfo
import android.view.accessibility.AccessibilityManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val EVENT_CHANNEL = "com.gida.app/accessibility_events"
    private val METHOD_CHANNEL = "com.gida.app/accessibility_control"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    GidaAccessibilityService.eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    GidaAccessibilityService.eventSink = null
                }
            }
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isServiceEnabled" -> {
                    result.success(isAccessibilityServiceEnabled())
                }
                "openAccessibilitySettings" -> {
                    val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    startActivity(intent)
                    result.success(true)
                }
                "blockSite" -> {
                    val url = call.argument<String>("url") ?: ""
                    val reason = call.argument<String>("reason") ?: "Zararlı içerik tespit edildi"
                    val blockedImmediately = GidaAccessibilityService.instance?.handleBlockCommand(url, reason) ?: false
                    result.success(blockedImmediately)
                }
                "clearBlacklist" -> {
                    GidaAccessibilityService.instance?.clearLocalBlacklist()
                    result.success(true)
                }
                "getAuthInfo" -> {
                    val prefs = getSharedPreferences("gida_cloud_prefs", Context.MODE_PRIVATE)
                    val map = mapOf(
                        "token" to prefs.getString("token", null),
                        "device_id" to prefs.getString("device_id", null),
                        "device_name" to prefs.getString("device_name", null),
                        "server_url" to prefs.getString("server_url", null)
                    )
                    result.success(map)
                }
                "saveAuthInfo" -> {
                    val prefs = getSharedPreferences("gida_cloud_prefs", Context.MODE_PRIVATE)
                    prefs.edit().apply {
                        call.argument<String>("token")?.let { putString("token", it) }
                        call.argument<String>("device_id")?.let { putString("device_id", it) }
                        call.argument<String>("device_name")?.let { putString("device_name", it) }
                        call.argument<String>("server_url")?.let { putString("server_url", it) }
                        apply()
                    }
                    result.success(true)
                }
                "clearAuthInfo" -> {
                    val prefs = getSharedPreferences("gida_cloud_prefs", Context.MODE_PRIVATE)
                    prefs.edit().apply {
                        remove("token")
                        remove("device_id")
                        apply()
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        val am = getSystemService(Context.ACCESSIBILITY_SERVICE) as AccessibilityManager
        val enabledServices = am.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
        for (service in enabledServices) {
            if (service.resolveInfo.serviceInfo.packageName == packageName &&
                service.resolveInfo.serviceInfo.name == GidaAccessibilityService::class.java.name) {
                return true
            }
        }
        return false
    }
}
