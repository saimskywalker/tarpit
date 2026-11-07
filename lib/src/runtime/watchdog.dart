import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart';

/// Settings for [tarpitWidgets], usually set once in
/// `test/flutter_test_config.dart`.
abstract final class Tarpit {
  /// How long a widget test may go without progress before it is failed.
  ///
  /// Progress means the fake clock moved or a frame was pumped. A test that
  /// keeps pumping is never stopped, however long it runs. Set to
  /// [Duration.zero] to turn the watchdog off.
  static Duration stallAfter = defaultStallAfter;

  /// The value [stallAfter] starts with.
  static const defaultStallAfter = Duration(seconds: 30);
}

/// Thrown into a widget test that made no progress for
/// [Tarpit.stallAfter].
class TarpitStall implements Exception {
  /// Creates the report. Public for tests and custom reporters.
  const TarpitStall({
    required this.description,
    required this.stallAfter,
    required this.realElapsed,
    required this.fakeElapsed,
    required this.frames,
    required this.transientCallbacks,
    required this.frameScheduled,
    this.bodyReturned = false,
  });

  /// The test's description.
  final String description;

  /// The limit that was reached.
  final Duration stallAfter;

  /// Real time since the test body started.
  final Duration realElapsed;

  /// How far the test's fake clock moved.
  final Duration fakeElapsed;

  /// Frames pumped by the test.
  final int frames;

  /// Running tickers and animations (`transientCallbackCount`).
  final int transientCallbacks;

  /// Whether a frame was requested but not pumped.
  final bool frameScheduled;

  /// Whether the test body had already returned: the test was stuck in
  /// flutter_test's own code after it, not in the body.
  final bool bodyReturned;

  @override
  String toString() {
    String seconds(Duration d) =>
        '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
    final out = StringBuffer()
      ..writeln(
        'tarpit: "$description" made no progress for ${seconds(stallAfter)} '
        'and was stopped.',
      )
      ..writeln()
      ..writeln('  real time in the test body: ${seconds(realElapsed)}')
      ..writeln(
        '  fake clock moved:           ${seconds(fakeElapsed)} '
        '(it moves only when the test pumps)',
      )
      ..writeln('  frames pumped:              $frames')
      ..writeln('  running tickers:            $transientCallbacks')
      ..writeln(
        '  frame requested, not pumped: ${frameScheduled ? 'yes' : 'no'}',
      )
      ..writeln();
    if (bodyReturned) {
      out
        ..writeln(
          'The test body returned, but the test never finished: its last '
          'await completed outside the FakeAsync zone of testWidgets, so '
          'nothing ran the code flutter_test has after the body. Usual '
          'cause: engine image work (toByteData, toImage, getNextFrame) '
          'awaited outside tester.runAsync(...).',
        )
        ..writeln();
    } else {
      out
        ..writeln(
          'The test body is awaiting a Future that nothing in the FakeAsync '
          'zone of testWidgets will complete. Usual causes:',
        )
        ..writeln(
          '  - Future.delayed, Future(...) or pumpEventQueue() awaited instead '
          'of tester.pump(duration)',
        )
        ..writeln(
          '  - file, socket or process I/O, compute() or Isolate.run() awaited '
          'outside tester.runAsync(...)',
        )
        ..writeln(
          '  - engine image work (toByteData, toImage, getNextFrame) '
          'awaited outside tester.runAsync(...)',
        )
        ..writeln(
          '  - a Completer or stream that waits for a platform channel, '
          'plugin or service the test does not fake',
        );
      if (transientCallbacks > 0) {
        out.writeln(
          '  - $transientCallbacks ticker(s) still running, such as a '
          'spinner: pumpAndSettle would not settle here either',
        );
      }
      out.writeln();
    }
    out.writeln(
      'Run `dart run tarpit` on the test file to find likely lines. If the '
      'test was inside tester.runAsync, flutter_test still waits for that '
      'real work before it moves on. If the test is just slow without '
      'pumping, raise the limit with stallAfter: or Tarpit.stallAfter.',
    );
    return out.toString().trimRight();
  }
}

/// [testWidgets] with a watchdog: a test that makes no progress (no pump,
/// no frame) for [stallAfter] (default [Tarpit.stallAfter]) fails with a
/// [TarpitStall] that says what state it was stuck in, instead of hanging
/// until the test or CI timeout.
///
/// The other arguments are passed to [testWidgets] unchanged.
@isTest
void tarpitWidgets(
  String description,
  WidgetTesterCallback callback, {
  bool? skip,
  Timeout? timeout,
  bool semanticsEnabled = true,
  TestVariant<Object?> variant = const DefaultTestVariant(),
  dynamic tags,
  int? retry,
  Duration? stallAfter,
}) {
  testWidgets(
    description,
    (tester) =>
        watchTester(tester, description, callback, stallAfter: stallAfter),
    skip: skip,
    timeout: timeout,
    semanticsEnabled: semanticsEnabled,
    variant: variant,
    tags: tags,
    retry: retry,
  );
}

/// Runs [callback] with the watchdog. Call it from inside a `testWidgets`
/// body when you cannot use [tarpitWidgets], for example in a custom test
/// wrapper.
Future<void> watchTester(
  WidgetTester tester,
  String description,
  WidgetTesterCallback callback, {
  Duration? stallAfter,
}) async {
  final limit = stallAfter ?? Tarpit.stallAfter;
  if (limit <= Duration.zero) return callback(tester);

  final binding = tester.binding;
  final frames = _FrameCounter.of(binding);
  // Errors reported in this zone reach the binding's test error handler,
  // which fails the test and completes it.
  final testZone = Zone.current;
  final fakeStart = binding.clock.now();
  final framesAtStart = frames.count;
  final real = Stopwatch()..start();

  var lastFake = fakeStart;
  var lastFrames = framesAtStart;
  var lastProgress = Duration.zero;
  var bodyReturned = false;

  // A real timer: timers created in the test zone are fake and would never
  // fire while the test is stuck.
  late final Timer watchdog;
  watchdog = Zone.root.createPeriodicTimer(_tick(limit), (_) {
    final DateTime fakeNow;
    try {
      fakeNow = binding.clock.now();
    } on Object {
      watchdog.cancel(); // The test already ended.
      return;
    }
    if (fakeNow != lastFake || frames.count != lastFrames) {
      lastFake = fakeNow;
      lastFrames = frames.count;
      lastProgress = real.elapsed;
      return;
    }
    if (real.elapsed - lastProgress < limit) return;

    watchdog.cancel();
    final stall = TarpitStall(
      description: description,
      stallAfter: limit,
      realElapsed: real.elapsed,
      fakeElapsed: fakeNow.difference(fakeStart),
      frames: frames.count - framesAtStart,
      transientCallbacks: binding.transientCallbackCount,
      frameScheduled: binding.hasScheduledFrame,
      bodyReturned: bodyReturned,
    );
    testZone.handleUncaughtError(stall, StackTrace.empty);
    // The binding completes the test from inside the FakeAsync zone; drain
    // its microtasks so that completion is delivered.
    try {
      binding.asyncBarrier();
    } on Object {
      // A guarded tester call is still open; the test has already failed.
    }
  });

  // Watch until the test's tear-down, not just until the body returns: when
  // the body's last await completes outside the FakeAsync zone (engine image
  // work does), flutter_test's code after the body waits on a microtask that
  // nothing flushes, and the test hangs after the body has returned.
  addTearDown(watchdog.cancel);
  try {
    await callback(tester);
  } finally {
    bodyReturned = true;
  }
}

Duration _tick(Duration limit) {
  final tenth = limit ~/ 10;
  if (tenth < const Duration(milliseconds: 20)) {
    return const Duration(milliseconds: 20);
  }
  if (tenth > const Duration(seconds: 1)) return const Duration(seconds: 1);
  return tenth;
}

/// Counts frames with one persistent frame callback per binding.
class _FrameCounter {
  _FrameCounter._(SchedulerBinding binding) {
    binding.addPersistentFrameCallback((_) => count++);
  }

  static final _counters = Expando<_FrameCounter>();

  static _FrameCounter of(SchedulerBinding binding) =>
      _counters[binding] ??= _FrameCounter._(binding);

  int count = 0;
}
