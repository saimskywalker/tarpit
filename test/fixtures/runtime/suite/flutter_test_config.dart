// flutter_test runs this around every file in this directory. The binding
// puts every testWidgets under the watchdog, so the test files can keep the
// plain flutter_test import.
import 'dart:async';

import 'package:tarpit/tarpit.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TarpitBinding.ensureInitialized(
    stallAfter: const Duration(milliseconds: 500),
  );
  await testMain();
}
