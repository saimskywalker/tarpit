// flutter_test runs this around every file in this directory. It installs a
// binding that puts every testWidgets under the watchdog, so the test files
// keep the plain flutter_test import.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tarpit/src/runtime/watchdog.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  _WatchedBinding();
  Tarpit.stallAfter = const Duration(milliseconds: 500);
  await testMain();
}

class _WatchedBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  Future<void> runTest(
    Future<void> Function() testBody,
    VoidCallback invariantTester, {
    String description = '',
  }) => super.runTest(
    () => watchBody(this, description, testBody),
    invariantTester,
    description: description,
  );
}
