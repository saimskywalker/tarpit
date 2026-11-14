/// `package:flutter_test/flutter_test.dart` with a `testWidgets` that runs
/// under the tarpit watchdog.
///
/// Change the import line of a test file to opt it in:
///
/// ```dart
/// import 'package:tarpit/flutter_test.dart';
/// ```
library;

import 'package:flutter_test/flutter_test.dart' as flutter_test;
import 'package:meta/meta.dart';

import 'src/runtime/watchdog.dart';

export 'package:flutter_test/flutter_test.dart' hide testWidgets;
export 'src/runtime/binding.dart' show TarpitBinding, TarpitWatchdogBinding;
export 'src/runtime/watchdog.dart'
    show Tarpit, TarpitStall, tarpitWidgets, watchTester;

/// Same as `testWidgets` from flutter_test, under the tarpit watchdog; see
/// [tarpitWidgets]. `experimentalLeakTesting` is not supported here: use
/// flutter_test's `testWidgets` for those tests.
@isTest
void testWidgets(
  String description,
  flutter_test.WidgetTesterCallback callback, {
  bool? skip,
  flutter_test.Timeout? timeout,
  bool semanticsEnabled = true,
  flutter_test.TestVariant<Object?> variant =
      const flutter_test.DefaultTestVariant(),
  dynamic tags,
  int? retry,
  Duration? stallAfter,
}) => tarpitWidgets(
  description,
  callback,
  skip: skip,
  timeout: timeout,
  semanticsEnabled: semanticsEnabled,
  variant: variant,
  tags: tags,
  retry: retry,
  stallAfter: stallAfter,
);
