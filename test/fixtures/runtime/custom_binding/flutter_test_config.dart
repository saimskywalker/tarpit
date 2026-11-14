// A suite with its own binding adds the watchdog with the mixin.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tarpit/tarpit.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  _AppBinding();
  Tarpit.stallAfter = const Duration(milliseconds: 500);
  await testMain();
}

class _AppBinding extends AutomatedTestWidgetsFlutterBinding
    with TarpitWatchdogBinding {}
