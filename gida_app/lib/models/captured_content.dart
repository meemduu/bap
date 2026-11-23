class CapturedContent {
  final String url;
  final String pageTitle;
  final String visibleText;
  final String browserPackage;
  final String appName;
  final String eventType;
  final String capturedAtDevice;
  final List<String> screenText;
  final List<Map<String, dynamic>> nodes;
  final bool isTargetApp;
  final bool isSupportedEventType;
  final DateTime timestamp;
  final String deviceId;
  final List<String> imagePaths;
  final String? contentId;
  final bool synced;
  final bool isBlocked;
  final String blockReason;

  CapturedContent({
    required this.url,
    required this.pageTitle,
    required this.visibleText,
    required this.browserPackage,
    required this.eventType,
    required this.timestamp,
    this.appName = '',
    this.capturedAtDevice = '',
    this.screenText = const [],
    this.nodes = const [],
    this.isTargetApp = true,
    this.isSupportedEventType = true,
    this.deviceId = '',
    this.imagePaths = const [],
    this.contentId,
    this.synced = false,
    this.isBlocked = false,
    this.blockReason = '',
  });

  CapturedContent copyWith({
    bool? synced,
    bool? isBlocked,
    String? blockReason,
    String? contentId,
  }) {
    return CapturedContent(
      url: url,
      pageTitle: pageTitle,
      visibleText: visibleText,
      browserPackage: browserPackage,
      appName: appName,
      eventType: eventType,
      capturedAtDevice: capturedAtDevice,
      screenText: screenText,
      nodes: nodes,
      isTargetApp: isTargetApp,
      isSupportedEventType: isSupportedEventType,
      timestamp: timestamp,
      deviceId: deviceId,
      imagePaths: imagePaths,
      contentId: contentId ?? this.contentId,
      synced: synced ?? this.synced,
      isBlocked: isBlocked ?? this.isBlocked,
      blockReason: blockReason ?? this.blockReason,
    );
  }

  factory CapturedContent.fromMap(Map<String, dynamic> map) {
    DateTime parsedTime;
    final ts = map['timestamp'];
    if (ts is int) {
      parsedTime = DateTime.fromMillisecondsSinceEpoch(ts);
    } else if (ts is String) {
      final intVal = int.tryParse(ts);
      if (intVal != null) {
        parsedTime = DateTime.fromMillisecondsSinceEpoch(intVal);
      } else {
        parsedTime = DateTime.tryParse(ts) ?? DateTime.now();
      }
    } else {
      parsedTime = DateTime.now();
    }

    final rawImages = map['image_paths'];
    final List<String> parsedImages = [];
    if (rawImages is List) {
      for (final item in rawImages) {
        if (item != null) {
          parsedImages.add(item.toString());
        }
      }
    }

    final rawScreenText = map['screenText'];
    final List<String> parsedScreenText = [];
    if (rawScreenText is List) {
      for (final item in rawScreenText) {
        if (item != null && item.toString().trim().isNotEmpty) {
          parsedScreenText.add(item.toString().trim());
        }
      }
    }

    final rawNodes = map['nodes'];
    final List<Map<String, dynamic>> parsedNodes = [];
    if (rawNodes is List) {
      for (final item in rawNodes) {
        if (item is Map) {
          parsedNodes.add(Map<String, dynamic>.from(item));
        }
      }
    }

    final visibleTextStr = (map['visible_text'] ?? map['visibleText'] ?? '').toString();
    if (parsedScreenText.isEmpty && visibleTextStr.isNotEmpty) {
      parsedScreenText.add(visibleTextStr);
    }

    final pkg = (map['packageName'] ?? map['browser_package'] ?? map['browserPackage'] ?? '').toString();

    return CapturedContent(
      url: (map['url'] ?? '').toString(),
      pageTitle: (map['page_title'] ?? map['pageTitle'] ?? '').toString(),
      visibleText: visibleTextStr,
      browserPackage: pkg,
      appName: (map['appName'] ?? pkg).toString(),
      eventType: (map['eventType'] ?? map['event_type'] ?? 'TYPE_WINDOW_CONTENT_CHANGED').toString(),
      capturedAtDevice: (map['capturedAtDevice'] ?? parsedTime.toUtc().toIso8601String()).toString(),
      screenText: parsedScreenText,
      nodes: parsedNodes,
      isTargetApp: map['isTargetApp'] != false,
      isSupportedEventType: map['isSupportedEventType'] != false,
      timestamp: parsedTime,
      deviceId: (map['device_id'] ?? '').toString(),
      imagePaths: parsedImages,
      isBlocked: map['is_blocked'] == true,
      blockReason: map['block_reason']?.toString() ?? '',
    );
  }

  static String sanitizeUrl(String raw) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      trimmed = 'https://$trimmed';
    }
    try {
      final uri = Uri.parse(trimmed);
      final clean = Uri(
        scheme: uri.scheme.isNotEmpty ? uri.scheme : 'https',
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: uri.path.isNotEmpty ? uri.path : '/',
      );
      return clean.toString();
    } catch (_) {
      return trimmed.split('?').first.split('#').first;
    }
  }

  /// GiDA POST /v1/captures kontratına tam uyumlu event şeması.
  Map<String, dynamic> toCaptureEventJson() {
    final cleanUrl = sanitizeUrl(url);
    final verifiedNodes = <Map<String, dynamic>>[];

    // İlk düğüm mutlaka temizlenmiş URL/hostname olmalıdır (browser analyzer seçimi için)
    if (cleanUrl.isNotEmpty) {
      verifiedNodes.add({
        'text': cleanUrl,
        'visibleToUser': true,
      });
    }

    if (nodes.isNotEmpty) {
      for (final n in nodes) {
        final text = (n['text'] ?? n['contentDescription'])?.toString().trim();
        if (text != null && text.isNotEmpty && text != cleanUrl) {
          verifiedNodes.add({
            'text': text,
            'visibleToUser': true,
          });
        }
      }
    } else {
      final texts = screenText.isNotEmpty
          ? screenText
          : (visibleText.isNotEmpty ? [visibleText] : <String>[]);
      for (final t in texts) {
        final trimmed = t.trim();
        if (trimmed.isNotEmpty && trimmed != cleanUrl) {
          verifiedNodes.add({
            'text': trimmed,
            'visibleToUser': true,
          });
        }
      }
    }

    final pkg = browserPackage.isNotEmpty ? browserPackage : 'com.android.chrome';
    final app = (pkg == 'com.android.chrome' || appName.isEmpty) ? 'Chrome (Web)' : appName;
    final evt = (eventType.isEmpty || eventType == 'TYPE_WINDOW_CONTENT_CHANGED') ? 'WEB_PAGE_VISIBLE' : eventType;

    return {
      'packageName': pkg,
      'appName': app,
      'eventType': evt,
      'capturedAtDevice': capturedAtDevice.isNotEmpty
          ? capturedAtDevice
          : timestamp.toUtc().toIso8601String(),
      'sourceType': 'web',
      'nodes': verifiedNodes,
      'isTargetApp': isTargetApp,
      'isSupportedEventType': isSupportedEventType,
    };
  }
}
