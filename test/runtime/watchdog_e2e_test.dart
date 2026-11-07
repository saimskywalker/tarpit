@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Runs the fixtures in test/fixtures/runtime in a separate `flutter test`
/// process, the way CI would, and reads its JSON reporter output.
void main() {
  test(
    'stalled tests fail fast with a diagnostic; the next test passes',
    () async {
      final run = await _flutterTest('stalls.dart');

      expect(run.exitCode, 1, reason: run.stderr);
      expect(run.outcomes['stalls on a fake delay'], isNot('success'));
      expect(run.outcomes['stalls on a never-ending future'], isNot('success'));
      expect(run.outcomes['runs after the stalls'], 'success');
      expect(
        run.output['stalls on a fake delay'],
        contains('"stalls on a fake delay" made no progress for 0.5s'),
      );
      // Two 0.5 s stalls plus tool start-up, far below any CI timeout.
      expect(run.elapsed, lessThan(const Duration(minutes: 2)));
    },
  );

  // flutter/flutter#50783: engine image work awaited outside runAsync.
  test('engine image work outside runAsync is caught too', () async {
    final run = await _flutterTest('engine_async.dart');

    expect(run.exitCode, 1, reason: run.stderr);
    const last = 'awaits toByteData as its last step';
    const pumps = 'awaits toByteData, then pumps';
    // The engine call itself completes: the isolate is not blocked.
    expect(run.output[last], contains('engine bytes: '));
    expect(run.output[pumps], contains('engine bytes: '));
    // The test hangs after it, and the watchdog fails it.
    expect(run.outcomes[last], isNot('success'));
    expect(run.output[last], contains('"$last" made no progress for 0.5s'));
    expect(run.output[last], contains('The test body returned'));
    expect(run.outcomes[pumps], isNot('success'));
    expect(run.output[pumps], contains('"$pumps" made no progress for 0.5s'));
    expect(run.outcomes['runs after the stalls'], 'success');
    expect(run.elapsed, lessThan(const Duration(minutes: 2)));
  });
}

class _Run {
  _Run(this.exitCode, this.stderr, this.elapsed);

  final int exitCode;
  final String stderr;
  final Duration elapsed;

  /// Test name to `testDone` result.
  final outcomes = <String, String>{};

  /// Test name to its printed output and errors.
  final output = <String, String>{};
}

/// Runs one fixture file and kills it if it hangs, so a watchdog that
/// misses a stall fails this test instead of hanging CI.
Future<_Run> _flutterTest(String fixture) async {
  final root = Platform.environment['FLUTTER_ROOT'];
  final flutter = root == null ? 'flutter' : p.join(root, 'bin', 'flutter');
  final real = Stopwatch()..start();
  final process = await Process.start(flutter, [
    'test',
    '--no-pub',
    '--reporter',
    'json',
    p.join('test', 'fixtures', 'runtime', fixture),
  ]);
  final stdout = process.stdout.transform(utf8.decoder).join();
  final stderr = process.stderr.transform(utf8.decoder).join();
  final exitCode = await process.exitCode.timeout(
    const Duration(minutes: 2),
    onTimeout: () {
      process.kill();
      fail('$fixture did not finish within 2 minutes: a stall was missed.');
    },
  );
  real.stop();

  final run = _Run(exitCode, await stderr, real.elapsed);
  final names = <int, String>{};
  for (final line in const LineSplitter().convert(await stdout)) {
    if (!line.startsWith('{')) continue;
    final event = jsonDecode(line) as Map<String, Object?>;
    switch (event['type']) {
      case 'testStart':
        final test = event['test']! as Map<String, Object?>;
        names[test['id']! as int] = test['name']! as String;
      case 'print':
        final name = names[event['testID']]!;
        run.output[name] = '${run.output[name] ?? ''}${event['message']}\n';
      case 'error':
        final name = names[event['testID']]!;
        run.output[name] = '${run.output[name] ?? ''}${event['error']}\n';
      case 'testDone':
        run.outcomes[names[event['testID']]!] = event['result']! as String;
    }
  }
  return run;
}
