class CapturedContent {
  final String url;
  final String pageTitle;
  final String visibleText;
  final String browserPackage;
  final String eventType;
  final DateTime timestamp;
  final String deviceId;
  final String? contentId;
  final bool synced;

  CapturedContent({
    required this.url,
    required this.pageTitle,
    required this.visibleText,
    required this.browserPackage,
    required this.eventType,
    required this.timestamp,
    this.deviceId = 'android-realme-3710',
    this.contentId,
    this.synced = false,
  });

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

    return CapturedContent(
      url: map['url'] ?? '',
      pageTitle: map['page_title'] ?? map['pageTitle'] ?? '',
      visibleText: map['visible_text'] ?? map['visibleText'] ?? '',
      browserPackage: map['browser_package'] ?? map['browserPackage'] ?? '',
      eventType: map['event_type'] ?? map['eventType'] ?? '',
      timestamp: parsedTime,
      deviceId: map['device_id'] ?? 'android-realme-3710',
    );
  }

  factory CapturedContent.fromJson(Map<String, dynamic> json) {
    return CapturedContent(
      url: json['url'] ?? '',
      pageTitle: json['page_title'] ?? '',
      visibleText: json['visible_text'] ?? '',
      browserPackage: json['browser_package'] ?? '',
      eventType: json['event_type'] ?? '',
      timestamp: json['timestamp'] != null 
          ? DateTime.parse(json['timestamp']) 
          : DateTime.now(),
      deviceId: json['device_id'] ?? 'android-realme-3710',
      contentId: json['id'] ?? json['content_id'],
      synced: true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'device_id': deviceId,
      'url': url,
      'page_title': pageTitle,
      'visible_text': visibleText,
      'browser_package': browserPackage,
      'event_type': eventType.isNotEmpty ? eventType : 'PAGE_VISIT',
      'timestamp': timestamp.toIso8601String(),
    };
  }
}
