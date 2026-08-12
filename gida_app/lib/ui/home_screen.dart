import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/captured_content.dart';
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
  int _capturedCount = 0;
  final List<CapturedContent> _recentCaptures = [];
  StreamSubscription? _subscription;
  final TextEditingController _urlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkServiceStatus();
    _urlController.text = context.read<ContentSender>().serverUrl;
    _startListening();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    _urlController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkServiceStatus();
    }
  }

  Future<void> _checkServiceStatus() async {
    final service = context.read<AccessibilityService>();
    final isEnabled = await service.isServiceEnabled();
    setState(() {
      _isServiceEnabled = isEnabled;
    });
  }

  void _startListening() {
    final service = context.read<AccessibilityService>();
    final sender = context.read<ContentSender>();

    _subscription = service.contentStream.listen((content) async {
      final contentId = await sender.sendContent(content);
      
      final syncedContent = CapturedContent(
        url: content.url,
        pageTitle: content.pageTitle,
        visibleText: content.visibleText,
        browserPackage: content.browserPackage,
        eventType: content.eventType,
        timestamp: content.timestamp,
        contentId: contentId,
        synced: contentId != null,
      );

      setState(() {
        _capturedCount++;
        _recentCaptures.insert(0, syncedContent);
        if (_recentCaptures.length > 5) {
          _recentCaptures.removeLast();
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final sender = context.watch<ContentSender>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('GiDA Home'),
        actions: [
          IconButton(
            icon: const Icon(Icons.list_alt),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const LogScreen()),
              );
            },
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isServiceEnabled ? Colors.green : Colors.red,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        _isServiceEnabled ? 'Service Running' : 'Service Stopped',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () {
                        context.read<AccessibilityService>().openAccessibilitySettings();
                      },
                      child: const Text('Settings'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                border: OutlineInputBorder(),
              ),
              onChanged: (val) => sender.updateServerUrl(val),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Text(
                      'Captured Items',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '$_capturedCount',
                      style: Theme.of(context).textTheme.displayMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Recent Captures',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _recentCaptures.isEmpty
                  ? const Center(child: Text('No recent captures'))
                  : ListView.builder(
                      itemCount: _recentCaptures.length,
                      itemBuilder: (context, index) {
                        final item = _recentCaptures[index];
                        return Card(
                          child: ListTile(
                            leading: Icon(
                              Icons.public,
                              color: item.synced ? Colors.green : Colors.grey,
                            ),
                            title: Text(item.pageTitle.isNotEmpty ? item.pageTitle : 'No Title', maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(item.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
