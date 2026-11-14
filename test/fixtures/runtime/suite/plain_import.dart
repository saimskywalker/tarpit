// Run by test/runtime/watchdog_e2e_test.dart in its own `flutter test`
// process. A plain flutter_test import: the watchdog comes from the binding
// in flutter_test_config.dart. The first two tests are meant to fail
// through it.
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('stalls on a fake delay', (tester) async {
    await Future<void>.delayed(const Duration(minutes: 1));
  });

  _wrapper('stalls inside a wrapper', (tester) async {
    await Future.any(<Future<void>>[]);
  });

  testWidgets('runs after the stalls', (tester) async {
    await tester.pump(const Duration(seconds: 1));
  });
}

// Like testGoldens or patrolWidgetTest: calls flutter_test's testWidgets.
void _wrapper(String description, WidgetTesterCallback body) =>
    testWidgets(description, body);
