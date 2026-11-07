import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tarpit/tarpit.dart';

const _short = Duration(milliseconds: 300);

void main() {
  // flutter_test reports a failed widget test through reportTestException.
  // Capturing it here lets the stalls below be checked without failing.
  final reported = <String, Object>{};
  late TestExceptionReporter original;

  group('a stalled test', () {
    setUpAll(() {
      original = reportTestException;
      reportTestException = (details, description) {
        reported[description] = details.exception;
      };
    });
    tearDownAll(() => reportTestException = original);

    tarpitWidgets('awaits a fake delay', (tester) async {
      await tester.pumpWidget(const SizedBox());
      // tarpit:allow fake-delay the watchdog must catch this stall
      await Future<void>.delayed(const Duration(minutes: 1));
    }, stallAfter: _short);

    tarpitWidgets('awaits real I/O', (tester) async {
      // tarpit:allow real-io the watchdog must catch this stall
      await File('pubspec.yaml').readAsString();
    }, stallAfter: _short);

    tarpitWidgets('awaits a completer nobody completes', (tester) async {
      await Completer<void>().future;
    }, stallAfter: _short);

    // flutter/flutter#50783: the bytes arrive, but outside the FakeAsync
    // zone, so the test hangs after its body returns.
    tarpitWidgets('awaits engine work as its last step', (tester) async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 1, 1), Paint());
      final image = recorder.endRecording().toImageSync(1, 1);
      // tarpit:allow engine-async the watchdog must catch this stall
      await image.toByteData();
    }, stallAfter: _short);
  });

  test('each stall failed its test with a TarpitStall', () {
    expect(reported.keys, [
      'awaits a fake delay',
      'awaits real I/O',
      'awaits a completer nobody completes',
      'awaits engine work as its last step',
    ]);
    for (final error in reported.values) {
      expect(error, isA<TarpitStall>());
    }
    final delay = reported['awaits a fake delay']! as TarpitStall;
    expect(delay.stallAfter, _short);
    expect(delay.realElapsed, greaterThanOrEqualTo(_short));
    expect(delay.fakeElapsed, Duration.zero);
    expect(delay.frames, greaterThanOrEqualTo(1));
    expect(delay.bodyReturned, isFalse);
    final engine = reported['awaits engine work as its last step']!;
    expect((engine as TarpitStall).bodyReturned, isTrue);
  });

  tarpitWidgets('the next test runs normally', (tester) async {
    await tester.pumpWidget(
      const Text('after', textDirection: TextDirection.ltr),
    );
    expect(find.text('after'), findsOneWidget);
  });

  tarpitWidgets('a slow test that keeps pumping is not stopped', (
    tester,
  ) async {
    final real = Stopwatch()..start();
    while (real.elapsed < _short * 3) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 1));
    }
  }, stallAfter: _short);

  group('Tarpit.stallAfter', () {
    tearDown(() => Tarpit.stallAfter = Tarpit.defaultStallAfter);

    test('defaults to 30 seconds', () {
      expect(Tarpit.stallAfter, const Duration(seconds: 30));
    });
  });

  test('TarpitStall explains what it saw', () {
    const stall = TarpitStall(
      description: 'loads the profile',
      stallAfter: Duration(seconds: 30),
      realElapsed: Duration(milliseconds: 30400),
      fakeElapsed: Duration(milliseconds: 1500),
      frames: 3,
      transientCallbacks: 2,
      frameScheduled: true,
    );
    final text = stall.toString();
    expect(
      text,
      startsWith(
        'tarpit: "loads the profile" made no progress '
        'for 30.0s and was stopped.',
      ),
    );
    expect(text, contains('fake clock moved:           1.5s'));
    expect(text, contains('frames pumped:              3'));
    expect(text, contains('2 ticker(s) still running'));
    expect(text, contains('frame requested, not pumped: yes'));
    expect(text, contains('dart run tarpit'));
    expect(text, isNot(contains('The test body returned')));
  });

  test('TarpitStall says when the body had already returned', () {
    const stall = TarpitStall(
      description: 'saves a screenshot',
      stallAfter: Duration(seconds: 30),
      realElapsed: Duration(seconds: 30),
      fakeElapsed: Duration.zero,
      frames: 1,
      transientCallbacks: 0,
      frameScheduled: false,
      bodyReturned: true,
    );
    final text = stall.toString();
    expect(text, contains('The test body returned, but the test never'));
    expect(text, contains('toByteData'));
    expect(text, isNot(contains('Usual causes:')));
  });
}
