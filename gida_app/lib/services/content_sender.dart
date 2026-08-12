import 'package:dio/dio.dart';
import '../models/captured_content.dart';

class ContentSender {
  String serverUrl;
  final Dio _dio;

  ContentSender({this.serverUrl = 'http://10.120.237.37:8000'}) : _dio = Dio() {
    _dio.options.connectTimeout = const Duration(seconds: 5);
    _dio.options.receiveTimeout = const Duration(seconds: 5);
  }

  void updateServerUrl(String newUrl) {
    serverUrl = newUrl;
  }

  Future<String?> sendContent(CapturedContent content) async {
    try {
      final response = await _dio.post(
        '$serverUrl/api/v1/content',
        data: content.toJson(),
      );
      if (response.statusCode == 200 || response.statusCode == 201) {
        return response.data['id']?.toString() ?? response.data['content_id']?.toString();
      }
      return null;
    } catch (e) {
      print('Error sending content: $e');
      return null;
    }
  }

  Future<List<CapturedContent>> fetchLogs({String? deviceId, int limit = 50}) async {
    try {
      final response = await _dio.get(
        '$serverUrl/api/v1/logs',
        queryParameters: {
          if (deviceId != null) 'device_id': deviceId,
          'limit': limit,
        },
      );
      if (response.statusCode == 200) {
        final List<dynamic> data = response.data is List ? response.data : (response.data['items'] ?? []);
        return data.map((item) => CapturedContent.fromJson(item)).toList();
      }
      return [];
    } catch (e) {
      print('Error fetching logs: $e');
      return [];
    }
  }
}
