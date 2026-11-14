// Run by test/runtime/watchdog_e2e_test.dart in its own `flutter test`
// process, under the custom binding in flutter_test_config.dart. The first
// test is meant to fail through the watchdog.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('stalls on a fake delay', (tester) async {
    await Future<void>.delayed(const Duration(minutes: 1));
  });

  testWidgets('runs after the stall', (tester) async {
    expect(WidgetsBinding.instance.runtimeType.toString(), '_AppBinding');
    await tester.pump(const Duration(seconds: 1));
  });
}
