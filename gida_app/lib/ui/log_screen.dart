import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../services/content_sender.dart';

class LogScreen extends StatelessWidget {
  const LogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sender = context.watch<ContentSender>();
    final logs = sender.history;

    return Scaffold(
      appBar: AppBar(
        title: Text('Olay Geçmişi (${logs.length})'),
      ),
      body: logs.isEmpty
          ? const Center(
              child: Text('Bu oturumda henüz yakalanan olay bulunmuyor.'),
            )
          : ListView.builder(
              itemCount: logs.length,
              itemBuilder: (context, index) {
                final log = logs[index];
                return Card(
                  color:
                      log.isBlocked ? Colors.red.withValues(alpha: 0.08) : null,
                  margin:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: ListTile(
                    leading: Icon(
                      log.isBlocked
                          ? Icons.block
                          : (log.synced ? Icons.cloud_done : Icons.schedule),
                      color: log.isBlocked
                          ? Colors.red
                          : (log.synced ? Colors.green : Colors.orange),
                    ),
                    title: Text(
                      log.url.isNotEmpty
                          ? log.url
                          : (log.pageTitle.isNotEmpty
                              ? log.pageTitle
                              : log.appName),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${log.browserPackage} (${log.eventType})',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Metin: ${log.screenText.length} adet | Düğüm: ${log.nodes.length} adet',
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          DateFormat.yMd().add_Hms().format(log.timestamp),
                          style: const TextStyle(fontSize: 11),
                        ),
                        if (log.isBlocked && log.blockReason.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Engellendi: ${log.blockReason}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.redAccent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                        if (log.imagePaths.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(
                                Icons.photo_library,
                                size: 14,
                                color: Colors.teal,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${log.imagePaths.length} ekran görüntüsü',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.teal,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                    trailing: Text(
                      log.synced ? 'Gönderildi' : 'Kuyrukta',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: log.synced ? Colors.green : Colors.orange,
                      ),
                    ),
                    isThreeLine: true,
                  ),
                );
              },
            ),
    );
  }
}
