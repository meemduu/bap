import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/accessibility_service.dart';
import 'services/content_sender.dart';
import 'ui/home_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AccessibilityService>(create: (_) => AccessibilityService()),
        Provider<ContentSender>(create: (_) => ContentSender()),
      ],
      child: MaterialApp(
        title: 'GiDA',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          useMaterial3: true,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
