import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import '../models/captured_content.dart';

class EnrollResult {
  final bool success;
  final String? deviceId;
  final String? token;
  final String? errorMessage;

  const EnrollResult({
    required this.success,
    this.deviceId,
    this.token,
    this.errorMessage,
  });
}

class FlushResult {
  final bool success;
  final int accepted;
  final int skipped;
  final bool unauthorized;
  final List<dynamic> commands;
  final String? errorMessage;

  const FlushResult({
    required this.success,
    this.accepted = 0,
    this.skipped = 0,
    this.unauthorized = false,
    this.commands = const [],
    this.errorMessage,
  });
}

class ContentSender {
  String serverUrl;
  final Dio _dio;

  String? token;
  String? deviceId;
  String? deviceName;

  int batchSize = 30;
  int flushSeconds = 20;

  int totalAccepted = 0;
  int totalSkipped = 0;

  final List<CapturedContent> _pendingQueue = [];
  final List<CapturedContent> _history = [];
  final List<Map<String, dynamic>> _reviewQueue = [];
  int _attempts = 0;
  DateTime? _nextAttempt;
  String? _blocked;
  Timer? _flushTimer;
  bool _isFlushing = false;

  void Function()? onStateChanged;
  void Function()? onUnauthorized;
  Future<void> Function(String url, String reason)? onBlockCommand;

  ContentSender({this.serverUrl = 'https://api.152-70-40-87.nip.io'})
      : _dio = Dio() {
    _dio.options.connectTimeout = const Duration(seconds: 12);
    _dio.options.receiveTimeout = const Duration(seconds: 15);
  }

  bool get isEnrolled => token != null && token!.isNotEmpty;
  int get pendingCount => _pendingQueue.length;
  int get reviewCount => _reviewQueue.length;
  String? get blockedReason => _blocked;
  List<CapturedContent> get history => List.unmodifiable(_history);

  void resume() {
    _blocked = null;
    _attempts = 0;
    _nextAttempt = null;
    onStateChanged?.call();
  }

  void updateServerUrl(String newUrl) {
    final cleaned = newUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (cleaned.isNotEmpty) {
      serverUrl = cleaned;
    }
  }

  void setAuth({
    String? token,
    String? deviceId,
    String? deviceName,
    String? savedServerUrl,
  }) {
    this.token = (token != null && token.isNotEmpty) ? token : null;
    this.deviceId = (deviceId != null && deviceId.isNotEmpty) ? deviceId : null;
    this.deviceName =
        (deviceName != null && deviceName.isNotEmpty) ? deviceName : null;
    if (savedServerUrl != null && savedServerUrl.trim().isNotEmpty) {
      updateServerUrl(savedServerUrl);
    }
    if (isEnrolled) {
      _restartFlushTimer();
    } else {
      _flushTimer?.cancel();
      _flushTimer = null;
    }
    onStateChanged?.call();
  }

  void clearAuth() {
    token = null;
    deviceId = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    onStateChanged?.call();
  }

  Future<bool> checkHealth() async {
    try {
      final response = await _dio.get('$serverUrl/health');
      if (response.statusCode == 200 && response.data is Map) {
        return response.data['ok'] == true;
      }
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Adım 1 — Cihazı tek kullanımlık 6 haneli kodla kaydet (/v1/enroll).
  Future<EnrollResult> enroll({
    required String code,
    required String deviceName,
  }) async {
    try {
      final response = await _dio.post(
        '$serverUrl/v1/enroll',
        data: {
          'code': code.trim(),
          'device_name': deviceName.trim(),
        },
        options: Options(
          headers: {'Content-Type': 'application/json'},
        ),
      );

      if ((response.statusCode == 200 || response.statusCode == 201) &&
          response.data is Map) {
        final data = response.data as Map;
        final newToken = data['token']?.toString();
        final newDeviceId = data['device_id']?.toString();

        if (newToken != null && newToken.isNotEmpty) {
          token = newToken;
          deviceId = newDeviceId;
          this.deviceName = deviceName.trim();
          _restartFlushTimer();
          onStateChanged?.call();

          return EnrollResult(
            success: true,
            deviceId: newDeviceId,
            token: newToken,
          );
        }
      }

      return const EnrollResult(
        success: false,
        errorMessage: 'Sunucudan geçerli bir token dönmedi.',
      );
    } on DioException catch (e) {
      String detail = e.message ?? 'Bağlantı hatası';
      if (e.response?.data is Map) {
        final map = e.response!.data as Map;
        detail = map['detail']?.toString() ?? detail;
      }
      return EnrollResult(
        success: false,
        errorMessage: 'Eşleştirme başarısız (${e.response?.statusCode ?? "Ağ"}): $detail',
      );
    } catch (e) {
      return EnrollResult(
        success: false,
        errorMessage: 'Beklenmeyen hata: $e',
      );
    }
  }

  /// Yakalanan olayı batch kuyruğuna ekler ve görselleri varsa /v1/captures/screenshot'a yükler.
  Future<void> enqueueContent(CapturedContent content) async {
    // Backpressure: pending + review >= 1000 ise yeni olay kabul etme, upstream veriyi koru
    if (_pendingQueue.length + _reviewQueue.length >= 1000) {
      return;
    }

    _pendingQueue.add(content);
    _history.insert(0, content);
    if (_history.length > 200) {
      _history.removeLast();
    }
    onStateChanged?.call();

    if (!isEnrolled) {
      // Henüz enroll edilmediyse görsellerin diski doldurmaması için temizle
      await _cleanupLocalImages(content.imagePaths);
      return;
    }

    _ensureFlushTimerRunning();

    // Kırpılmış görseller varsa arka planda /v1/captures/screenshot endpoint'ine yükle
    if (content.imagePaths.isNotEmpty) {
      unawaited(_uploadScreenshotsAndCleanup(content));
    }

    // Kuyruk batch_size sınırına ulaştıysa hemen gönder
    if (_pendingQueue.length >= batchSize) {
      await flushBatch();
    }
  }

  /// Adım 2 — Biriken olayları toplu halde (en fazla 30-50 adet) /v1/captures'a gönder.
  Future<FlushResult> flushBatch() async {
    if (_isFlushing || _pendingQueue.isEmpty || !isEnrolled || _blocked != null) {
      return const FlushResult(success: true);
    }
    if (_nextAttempt != null && DateTime.now().isBefore(_nextAttempt!)) {
      return const FlushResult(success: true);
    }

    _isFlushing = true;
    final int takeCount = _pendingQueue.length > 30 ? 30 : _pendingQueue.length;
    final List<CapturedContent> batch = _pendingQueue.sublist(0, takeCount);
    _pendingQueue.removeRange(0, takeCount);
    onStateChanged?.call();

    try {
      final eventsPayload = batch.map((e) => e.toCaptureEventJson()).toList();

      final response = await _dio.post(
        '$serverUrl/v1/captures',
        data: {'events': eventsPayload},
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
        ),
      );

      if (response.statusCode != null &&
          response.statusCode! >= 200 &&
          response.statusCode! < 300) {
        final data = response.data is Map ? response.data as Map : {};
        final int accepted = (data['accepted'] is int)
            ? data['accepted'] as int
            : int.tryParse(data['accepted']?.toString() ?? '0') ?? batch.length;
        final int skipped = (data['skipped'] is int)
            ? data['skipped'] as int
            : int.tryParse(data['skipped']?.toString() ?? '0') ?? 0;

        totalAccepted += accepted;
        totalSkipped += skipped;

        // History içindeki öğeleri synced = true olarak işaretle
        _markBatchSyncedInHistory(batch);

        // Kısmi kabul veya atlanan varsa batch'i inceleme arşivinde tut, otomatik tekrarlama
        if (accepted != batch.length || skipped != 0) {
          _reviewQueue.add({'events': batch, 'response': data});
          _blocked = 'Review partial acknowledgement';
        }

        _attempts = 0;
        _nextAttempt = null;

        // Sunucudan gelen config (batch_size, flush_seconds) ayarlarını uygula
        if (data['config'] is Map) {
          final cfg = data['config'] as Map;
          final int? newBatchSize = cfg['batch_size'] is int
              ? cfg['batch_size'] as int
              : int.tryParse(cfg['batch_size']?.toString() ?? '');
          final int? newFlushSec = cfg['flush_seconds'] is int
              ? cfg['flush_seconds'] as int
              : int.tryParse(cfg['flush_seconds']?.toString() ?? '');

          bool timerChanged = false;
          if (newBatchSize != null && newBatchSize >= 1) {
            batchSize = newBatchSize.clamp(1, 50);
          }
          if (newFlushSec != null &&
              newFlushSec >= 5 &&
              newFlushSec != flushSeconds) {
            flushSeconds = newFlushSec;
            timerChanged = true;
          }
          if (timerChanged) {
            _restartFlushTimer();
          }
        }

        // Sunucudan dönen commands listesini işle (örn. site engelleme komutları)
        final List<dynamic> commands =
            data['commands'] is List ? data['commands'] as List<dynamic> : [];
        await _processServerCommands(commands, batch);

        _isFlushing = false;
        onStateChanged?.call();

        // Kuyrukta hala olay varsa sonraki partiyi gönder
        if (_pendingQueue.isNotEmpty && _blocked == null) {
          unawaited(flushBatch());
        }

        return FlushResult(
          success: true,
          accepted: accepted,
          skipped: skipped,
          commands: commands,
        );
      }

      _isFlushing = false;
      onStateChanged?.call();
      return const FlushResult(success: false);
    } on DioException catch (e) {
      _isFlushing = false;
      final statusCode = e.response?.statusCode;

      if (statusCode == 401) {
        // 401: kuyruğu sakla, durdur, re-enroll bekle
        _pendingQueue.insertAll(0, batch);
        _blocked = 'reenroll';
        clearAuth();
        onUnauthorized?.call();
        return const FlushResult(
          success: false,
          unauthorized: true,
          errorMessage: 'Oturum geçersiz (401). Lütfen cihazı yeniden eşleştirin.',
        );
      } else if (statusCode != null &&
          statusCode >= 400 &&
          statusCode < 500 &&
          statusCode != 408 &&
          statusCode != 429) {
        // Diğer 4xx: sakla, hatayı düzeltmeden tekrarlama, inceleme için bloke et
        _pendingQueue.insertAll(0, batch);
        _blocked = 'HTTP $statusCode';
        onStateChanged?.call();
        return FlushResult(
          success: false,
          errorMessage: 'Kalıcı hata ($statusCode). Düzeltme gerekli.',
        );
      } else {
        // 5xx / 408 / 429 / Ağ Timeout: Exponential backoff + jitter ile sakla ve tekrar dene
        _pendingQueue.insertAll(0, batch);
        _attempts = (_attempts + 1).clamp(1, 16);
        final delayMs = (1000 * (1 << (_attempts - 1))).clamp(1000, 300000);
        final jitter = delayMs * (1.0 + (DateTime.now().microsecond % 250) / 1000.0);
        _nextAttempt = DateTime.now().add(Duration(milliseconds: jitter.toInt()));
        onStateChanged?.call();
        return FlushResult(
          success: false,
          errorMessage: 'Sunucu/ağ geçici hatası (${statusCode ?? "Ağ"}), backoff aktif.',
        );
      }
    } catch (e) {
      _isFlushing = false;
      _pendingQueue.insertAll(0, batch);
      _attempts = (_attempts + 1).clamp(1, 16);
      final delayMs = (1000 * (1 << (_attempts - 1))).clamp(1000, 300000);
      _nextAttempt = DateTime.now().add(Duration(milliseconds: delayMs));
      onStateChanged?.call();
      return FlushResult(
        success: false,
        errorMessage: 'Gönderim hatası: $e',
      );
    }
  }

  Future<void> _processServerCommands(
    List<dynamic> commands,
    List<CapturedContent> sentBatch,
  ) async {
    if (commands.isEmpty || onBlockCommand == null) return;

    for (final cmd in commands) {
      if (cmd is Map) {
        final type = (cmd['type'] ?? cmd['action'] ?? cmd['command'] ?? '')
            .toString()
            .toLowerCase();
        final url =
            (cmd['url'] ?? cmd['target_url'] ?? cmd['domain'] ?? '').toString();
        final reason = (cmd['reason'] ??
                cmd['block_reason'] ??
                cmd['message'] ??
                'Sunucu tarafından engellendi')
            .toString();

        if ((type.contains('block') || url.isNotEmpty) && url.isNotEmpty) {
          await onBlockCommand!(url, reason);
          _markUrlBlockedInHistory(url, reason);
        }
      } else if (cmd is String && cmd.trim().isNotEmpty) {
        await onBlockCommand!(cmd.trim(), 'Sunucu tarafından engellendi');
        _markUrlBlockedInHistory(cmd.trim(), 'Sunucu tarafından engellendi');
      }
    }
  }

  Future<void> _uploadScreenshotsAndCleanup(CapturedContent content) async {
    if (!isEnrolled) {
      await _cleanupLocalImages(content.imagePaths);
      return;
    }

    for (final path in content.imagePaths) {
      final file = File(path);
      if (await file.exists()) {
        try {
          final fileName = path.split('/').last;
          final formData = FormData.fromMap({
            'package_name': content.browserPackage.isNotEmpty
                ? content.browserPackage
                : 'com.android.chrome',
            'screenshot': await MultipartFile.fromFile(
              path,
              filename: fileName,
            ),
          });

          await _dio.post(
            '$serverUrl/v1/captures/screenshot',
            data: formData,
            options: Options(
              headers: {
                'Authorization': 'Bearer $token',
              },
            ),
          );
        } catch (_) {
          // Görsel yükleme başarısız olsa da diski temizle
        } finally {
          try {
            if (await file.exists()) {
              await file.delete();
            }
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _cleanupLocalImages(List<String> paths) async {
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }

  void _markBatchSyncedInHistory(List<CapturedContent> batch) {
    final Set<DateTime> timestamps = batch.map((e) => e.timestamp).toSet();
    for (int i = 0; i < _history.length; i++) {
      if (timestamps.contains(_history[i].timestamp)) {
        _history[i] = _history[i].copyWith(synced: true);
      }
    }
  }

  void _markUrlBlockedInHistory(String blockedUrl, String reason) {
    final norm = blockedUrl.toLowerCase();
    for (int i = 0; i < _history.length; i++) {
      if (_history[i].url.toLowerCase().contains(norm)) {
        _history[i] = _history[i].copyWith(
          isBlocked: true,
          blockReason: reason,
        );
      }
    }
  }

  void _ensureFlushTimerRunning() {
    if (_flushTimer == null || !_flushTimer!.isActive) {
      _restartFlushTimer();
    }
  }

  void _restartFlushTimer() {
    _flushTimer?.cancel();
    if (!isEnrolled) return;
    _flushTimer = Timer.periodic(Duration(seconds: flushSeconds), (_) {
      flushBatch();
    });
  }

  void dispose() {
    _flushTimer?.cancel();
  }
}
