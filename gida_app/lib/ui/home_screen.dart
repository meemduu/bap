import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/accessibility_service.dart';
import '../services/content_sender.dart';
import 'log_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _isServiceEnabled = false;
  bool _isServerHealthy = false;
  bool _isEnrolling = false;
  bool _isFlushing = false;
  int _blockedCount = 0;

  StreamSubscription? _subscription;
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _pairingCodeController = TextEditingController();
  final TextEditingController _deviceNameController =
      TextEditingController(text: 'memduh-chrome-web');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeState();
  }

  Future<void> _initializeState() async {
    final service = context.read<AccessibilityService>();
    final sender = context.read<ContentSender>();

    sender.onStateChanged = () {
      if (mounted) {
        setState(() {});
      }
    };

    sender.onUnauthorized = () async {
      await service.clearAuthInfo();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text(
              'Sunucu oturumu geçersiz (401). Lütfen yeni kodla tekrar eşleştirin.',
            ),
          ),
        );
        setState(() {});
      }
    };

    sender.onBlockCommand = (url, reason) async {
      final blocked = await service.blockSite(url: url, reason: reason);
      if (blocked && mounted) {
        setState(() {
          _blockedCount++;
        });
      }
    };

    final authInfo = await service.getAuthInfo();
    sender.setAuth(
      token: authInfo['token'],
      deviceId: authInfo['device_id'],
      deviceName: authInfo['device_name'],
      savedServerUrl: authInfo['server_url'],
    );

    if (authInfo['device_name'] != null &&
        authInfo['device_name']!.isNotEmpty) {
      _deviceNameController.text = authInfo['device_name']!;
    }
    _urlController.text = sender.serverUrl;

    await _checkServiceStatus();
    await _checkServerHealth();
    _startListening();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    _urlController.dispose();
    _pairingCodeController.dispose();
    _deviceNameController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkServiceStatus();
      _checkServerHealth();
    }
  }

  Future<void> _checkServiceStatus() async {
    final service = context.read<AccessibilityService>();
    final isEnabled = await service.isServiceEnabled();
    if (mounted) {
      setState(() {
        _isServiceEnabled = isEnabled;
      });
    }
  }

  Future<void> _checkServerHealth() async {
    final sender = context.read<ContentSender>();
    final healthy = await sender.checkHealth();
    if (mounted) {
      setState(() {
        _isServerHealthy = healthy;
      });
    }
  }

  void _startListening() {
    final service = context.read<AccessibilityService>();
    final sender = context.read<ContentSender>();

    _subscription = service.contentStream.listen((content) async {
      await sender.enqueueContent(content);
    });
  }

  Future<void> _handleEnroll() async {
    final code = _pairingCodeController.text.trim();
    final deviceName = _deviceNameController.text.trim();

    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Lütfen 6 haneli eşleştirme kodunu girin.')),
      );
      return;
    }

    setState(() {
      _isEnrolling = true;
    });

    final sender = context.read<ContentSender>();
    final service = context.read<AccessibilityService>();
    final result = await sender.enroll(
      code: code,
      deviceName: deviceName.isNotEmpty ? deviceName : 'android-telefon',
    );

    if (!mounted) return;
    setState(() {
      _isEnrolling = false;
    });

    if (result.success && result.token != null) {
      await service.saveAuthInfo(
        token: result.token,
        deviceId: result.deviceId,
        deviceName: deviceName,
        serverUrl: sender.serverUrl,
      );
      _pairingCodeController.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.green,
            content: Text('Cihaz başarıyla eşleştirildi!'),
          ),
        );
      }
      // Kuyrukta bekleyen olay varsa hemen gönder
      if (sender.pendingCount > 0) {
        await sender.flushBatch();
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text(result.errorMessage ?? 'Eşleştirme başarısız oldu.'),
        ),
      );
    }
  }

  Future<void> _handleManualFlush() async {
    final sender = context.read<ContentSender>();
    if (!sender.isEnrolled || sender.pendingCount == 0) return;

    setState(() {
      _isFlushing = true;
    });
    final res = await sender.flushBatch();
    if (!mounted) return;
    setState(() {
      _isFlushing = false;
    });

    if (res.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Batch gönderildi: ${res.accepted} kabul edildi, ${res.skipped} atlandı.',
          ),
        ),
      );
    } else if (res.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.orange,
          content: Text(res.errorMessage!),
        ),
      );
    }
  }

  Future<void> _handleUnenroll() async {
    final sender = context.read<ContentSender>();
    final service = context.read<AccessibilityService>();
    sender.clearAuth();
    await service.clearAuthInfo();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cihaz eşleştirmesi kaldırıldı.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final sender = context.watch<ContentSender>();
    final recentCaptures = sender.history.take(8).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('GiDA Agent'),
        actions: [
          IconButton(
            tooltip: 'Sunucu Sağlık Kontrolü (/health)',
            icon: Icon(
              Icons.cloud_done,
              color: _isServerHealthy ? Colors.green : Colors.grey,
            ),
            onPressed: _checkServerHealth,
          ),
          IconButton(
            tooltip: 'Yerel Kara Listeyi Temizle',
            icon: const Icon(Icons.cleaning_services_outlined),
            onPressed: () async {
              await context.read<AccessibilityService>().clearLocalBlacklist();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Yerel kara liste temizlendi')),
                );
              }
            },
          ),
          IconButton(
            tooltip: 'Kayıt Geçmişi',
            icon: const Icon(Icons.list_alt),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const LogScreen()),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // 1. Accessibility Service Durum Kartı
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14.0),
              child: Row(
                children: [
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isServiceEnabled ? Colors.green : Colors.red,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _isServiceEnabled
                          ? 'Erişilebilirlik Servisi Aktif'
                          : 'Erişilebilirlik Servisi Kapalı',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      context
                          .read<AccessibilityService>()
                          .openAccessibilitySettings();
                    },
                    child: const Text('Ayarlar'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 2. Sunucu Adresi
          TextField(
            controller: _urlController,
            decoration: InputDecoration(
              labelText: 'GiDA API Adresi',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Bağlantıyı Test Et',
                onPressed: () async {
                  sender.updateServerUrl(_urlController.text);
                  await context.read<AccessibilityService>().saveAuthInfo(
                        serverUrl: sender.serverUrl,
                      );
                  await _checkServerHealth();
                },
              ),
            ),
            onChanged: (val) => sender.updateServerUrl(val),
          ),
          const SizedBox(height: 12),

          // 3. Cihaz Eşleştirme (Enroll) veya Aktif Oturum Kartı
          if (!sender.isEnrolled)
            Card(
              color: Colors.amber.withValues(alpha: 0.1),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.vpn_key, color: Colors.amber),
                        const SizedBox(width: 8),
                        Text(
                          'Adım 1: Cihaz Eşleştirme (/v1/enroll)',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Davut\'tan aldığınız 6 haneli tek kullanımlık eşleştirme kodunu girerek cihazı kaydedin.',
                      style: TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: _pairingCodeController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '6 Haneli Kod',
                              hintText: '417578',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 3,
                          child: TextField(
                            controller: _deviceNameController,
                            decoration: const InputDecoration(
                              labelText: 'Cihaz Adı',
                              hintText: 'memduh-telefon',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _isEnrolling ? null : _handleEnroll,
                      icon: _isEnrolling
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.link),
                      label: Text(
                        _isEnrolling ? 'Eşleştiriliyor...' : 'Cihazı Eşleştir',
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            Card(
              color: Colors.teal.withValues(alpha: 0.08),
              child: Padding(
                padding: const EdgeInsets.all(14.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.verified_user, color: Colors.teal),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Cihaz Eşleştirildi (${sender.deviceName ?? "Aktif"})',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        TextButton(
                          onPressed: _handleUnenroll,
                          child: const Text(
                            'Sıfırla',
                            style: TextStyle(color: Colors.redAccent),
                          ),
                        ),
                      ],
                    ),
                    if (sender.deviceId != null)
                      Text(
                        'Device ID: ${sender.deviceId}',
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      'Batch Ayarı: Her ${sender.batchSize} olayda veya ${sender.flushSeconds} sn\'de bir gönderilir',
                      style: const TextStyle(fontSize: 12, color: Colors.teal),
                    ),
                    if (sender.reviewCount > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: Text(
                          'İnceleme Arşivi: ${sender.reviewCount} paket (kısmi kabul)',
                          style: const TextStyle(fontSize: 12, color: Colors.orange),
                        ),
                      ),
                    if (sender.blockedReason != null)
                      Container(
                        margin: const EdgeInsets.only(top: 6.0),
                        padding: const EdgeInsets.all(8.0),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6.0),
                          border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.warning_amber, size: 16, color: Colors.redAccent),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Durum: ${sender.blockedReason}',
                                style: const TextStyle(fontSize: 12, color: Colors.redAccent),
                              ),
                            ),
                            TextButton(
                              onPressed: () => sender.resume(),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                              ),
                              child: const Text('Devam Et'),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed:
                            (_isFlushing || sender.pendingCount == 0)
                                ? null
                                : _handleManualFlush,
                        icon: const Icon(Icons.send, size: 16),
                        label: Text(
                          _isFlushing
                              ? 'Gönderiliyor...'
                              : 'Bekleyenleri Şimdi Gönder (${sender.pendingCount})',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 12),

          // 4. İstatistik Sayaçları
          Row(
            children: [
              Expanded(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 12.0,
                      horizontal: 8.0,
                    ),
                    child: Column(
                      children: [
                        const Text('Kuyruk', style: TextStyle(fontSize: 12)),
                        const SizedBox(height: 4),
                        Text(
                          '${sender.pendingCount}',
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(color: Colors.orange),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 12.0,
                      horizontal: 8.0,
                    ),
                    child: Column(
                      children: [
                        const Text(
                          'Kabul Edilen',
                          style: TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${sender.totalAccepted}',
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 12.0,
                      horizontal: 8.0,
                    ),
                    child: Column(
                      children: [
                        const Text('Engellenen', style: TextStyle(fontSize: 12)),
                        const SizedBox(height: 4),
                        Text(
                          '$_blockedCount',
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(color: Colors.redAccent),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),
          Text(
            'Son Yakalanan Olaylar',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (recentCaptures.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32.0),
              child: Center(child: Text('Henüz yakalanan olay yok')),
            )
          else
            ...recentCaptures.map((item) {
              return Card(
                color:
                    item.isBlocked ? Colors.red.withValues(alpha: 0.08) : null,
                child: ListTile(
                  leading: Icon(
                    item.isBlocked
                        ? Icons.block
                        : (item.synced ? Icons.cloud_done : Icons.schedule),
                    color: item.isBlocked
                        ? Colors.red
                        : (item.synced ? Colors.green : Colors.orange),
                  ),
                  title: Text(
                    item.url.isNotEmpty
                        ? item.url
                        : (item.pageTitle.isNotEmpty
                            ? item.pageTitle
                            : item.appName),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${item.eventType} • ${item.screenText.length} metin • ${item.nodes.length} düğüm',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      if (item.isBlocked && item.blockReason.isNotEmpty)
                        Text(
                          'Engellendi: ${item.blockReason}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                  trailing: item.imagePaths.isNotEmpty
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.image,
                              size: 18,
                              color: Colors.teal,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${item.imagePaths.length}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        )
                      : null,
                ),
              );
            }),
        ],
      ),
    );
  }
}
