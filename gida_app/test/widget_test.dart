import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gida_app/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.gida.app/accessibility_control'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'isServiceEnabled') {
          return true;
        }
        if (methodCall.method == 'getAuthInfo') {
          return <String, String?>{};
        }
        return null;
      },
    );
  });

  testWidgets('GiDA app loads correctly', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('GiDA Agent'), findsOneWidget);
  });
}
