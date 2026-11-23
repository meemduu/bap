import 'package:flutter_test/flutter_test.dart';
import 'package:gida_app/models/captured_content.dart';

void main() {
  group('CapturedContent GiDA Contract Tests', () {
    test('toCaptureEventJson formats nodes with sanitized URL first and visibleToUser', () {
      final content = CapturedContent(
        url: 'https://example.org/news?article=123#comments',
        pageTitle: 'Example News',
        visibleText: 'First visible sentence. Second visible sentence.',
        browserPackage: 'com.android.chrome',
        eventType: 'WEB_PAGE_VISIBLE',
        timestamp: DateTime.parse('2026-10-23T09:00:00.000Z'),
        screenText: ['First visible sentence.', 'Second visible sentence.'],
      );

      final json = content.toCaptureEventJson();

      expect(json['packageName'], 'com.android.chrome');
      expect(json['appName'], 'Chrome (Web)');
      expect(json['eventType'], 'WEB_PAGE_VISIBLE');
      expect(json['sourceType'], 'web');
      expect(json['capturedAtDevice'], isNotEmpty);

      final nodes = json['nodes'] as List<Map<String, dynamic>>;
      expect(nodes.isNotEmpty, true);

      // Node 0 must be sanitized URL without query or fragment
      expect(nodes[0]['text'], 'https://example.org/news');
      expect(nodes[0]['visibleToUser'], true);

      // Subsequent nodes
      expect(nodes[1]['text'], 'First visible sentence.');
      expect(nodes[1]['visibleToUser'], true);
      expect(nodes[2]['text'], 'Second visible sentence.');
      expect(nodes[2]['visibleToUser'], true);
    });

    test('toCaptureEventJson defaults to com.android.chrome and Chrome (Web)', () {
      final content = CapturedContent(
        url: 'https://test.local',
        pageTitle: 'Test',
        visibleText: 'Visible text only',
        browserPackage: '',
        eventType: '',
        timestamp: DateTime.now(),
      );

      final json = content.toCaptureEventJson();
      expect(json['packageName'], 'com.android.chrome');
      expect(json['appName'], 'Chrome (Web)');
      expect(json['eventType'], 'WEB_PAGE_VISIBLE');
      expect(json['sourceType'], 'web');

      final nodes = json['nodes'] as List<Map<String, dynamic>>;
      expect(nodes.first['text'], 'https://test.local/');
      expect(nodes.first['visibleToUser'], true);
    });
  });
}
