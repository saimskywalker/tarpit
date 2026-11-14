// Run by test/runtime/watchdog_e2e_test.dart in its own `flutter test`
// process. The tarpit import watches each test too, under the binding in
// flutter_test_config.dart; each stall must be reported once.
import 'package:tarpit/flutter_test.dart';

void main() {
  testWidgets('stalls under both watches', (tester) async {
    await Future<void>.delayed(const Duration(minutes: 1));
  });

  testWidgets('stalls with its own limit', (tester) async {
    await Future<void>.delayed(const Duration(minutes: 1));
  }, stallAfter: const Duration(seconds: 1));

  testWidgets('runs after the stalls', (tester) async {
    await tester.pump(const Duration(seconds: 1));
  });
}
