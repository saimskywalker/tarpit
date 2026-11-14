import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'watchdog.dart';

/// Puts every widget test run by this binding under the watchdog, whatever
/// the test file imports. Mix it into your own binding when the suite
/// already has one; otherwise use [TarpitBinding].
///
/// The limit is [Tarpit.stallAfter]. A test that also uses [tarpitWidgets]
/// or [watchTester] is watched once, with that call's `stallAfter`.
mixin TarpitWatchdogBinding on AutomatedTestWidgetsFlutterBinding {
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

/// The binding `testWidgets` uses by default, with [TarpitWatchdogBinding].
class TarpitBinding extends AutomatedTestWidgetsFlutterBinding
    with TarpitWatchdogBinding {
  /// Creates the binding, once. Call it in `testExecutable` in
  /// `test/flutter_test_config.dart`, before any test runs: an isolate has
  /// only one binding, and the first one created is kept. [stallAfter], if
  /// given, sets [Tarpit.stallAfter].
  static TarpitBinding ensureInitialized({Duration? stallAfter}) {
    if (stallAfter != null) Tarpit.stallAfter = stallAfter;
    return _instance ??= TarpitBinding();
  }

  static TarpitBinding? _instance;
}
