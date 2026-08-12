import 'dart:convert';
import 'dart:async';
import 'package:flutter/services.dart';
import '../models/captured_content.dart';

class AccessibilityService {
  static const EventChannel _eventChannel = EventChannel('com.gida.app/accessibility_events');
  static const MethodChannel _methodChannel = MethodChannel('com.gida.app/accessibility_control');

  Stream<CapturedContent>? _contentStream;

  Future<bool> isServiceEnabled() async {
    try {
      final bool? isEnabled = await _methodChannel.invokeMethod('isServiceEnabled');
      return isEnabled ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> openAccessibilitySettings() async {
    try {
      await _methodChannel.invokeMethod('openAccessibilitySettings');
    } on PlatformException catch (e) {
      print("Failed to open accessibility settings: '${e.message}'.");
    }
  }

  Stream<CapturedContent> get contentStream {
    _contentStream ??= _eventChannel.receiveBroadcastStream().map((dynamic event) {
      Map<String, dynamic> map;
      if (event is String) {
        map = jsonDecode(event) as Map<String, dynamic>;
      } else if (event is Map) {
        map = Map<String, dynamic>.from(event);
      } else {
        throw FormatException('Unexpected event type: ${event.runtimeType}');
      }
      return CapturedContent.fromMap(map);
    }).handleError((error) {
      print('Error receiving from event channel: $error');
    });
    return _contentStream!;
  }
}
