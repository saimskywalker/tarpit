/// How serious a finding is.
enum Severity {
  /// The pattern stalls a widget test whenever it runs.
  error,

  /// The pattern stalls or fails a widget test in the common case.
  warning,

  /// The pattern can stall a widget test, depending on code tarpit cannot
  /// see (a closure that may not be awaited, unresolved types, data size).
  info;

  /// Parses `error`, `warning` or `info`.
  static Severity parse(String value) =>
      Severity.values.firstWhere((s) => s.name == value);

  /// Whether this severity is at least as serious as [other].
  bool atLeast(Severity other) => index <= other.index;
}

/// A check tarpit runs on `testWidgets` bodies.
class Rule {
  /// Creates a rule description.
  const Rule({
    required this.id,
    required this.severity,
    required this.title,
    required this.why,
    required this.fix,
  });

  /// Stable kebab-case id, used in suppressions and machine output.
  final String id;

  /// Severity when the pattern is awaited directly by the test body.
  final Severity severity;

  /// One line summary.
  final String title;

  /// Why the pattern hangs or fails a widget test.
  final String why;

  /// What to do instead.
  final String fix;
}

/// Awaiting a fake timer the test never advances.
const fakeDelay = Rule(
  id: 'fake-delay',
  severity: Severity.error,
  title: 'Awaits a timer that only fake time can fire',
  why:
      'testWidgets runs the body in a FakeAsync zone. Future.delayed, '
      'Future(...) and pumpEventQueue() schedule fake timers, which fire only '
      'when the test pumps. While the body is awaiting one, nothing pumps, so '
      'the await never returns.',
  fix:
      'Advance fake time with `await tester.pump(duration)` instead. If you '
      'really need wall-clock time, wrap it in `tester.runAsync(...)`.',
);

/// Awaiting dart:io work outside runAsync.
const realIo = Rule(
  id: 'real-io',
  severity: Severity.error,
  title: 'Awaits real file, process or socket I/O outside runAsync',
  why:
      'dart:io completes on the real event loop, but the continuation is '
      'queued in the FakeAsync zone, which only drains when the test pumps. '
      'The test waits for I/O that has finished but is never delivered.',
  fix:
      'Wrap the call in `await tester.runAsync(() => ...)`, or do the I/O in '
      'setUp/setUpAll, or use an in-memory fake (for example package:file).',
);

/// Awaiting another isolate outside runAsync.
const isolateHop = Rule(
  id: 'isolate-hop',
  severity: Severity.error,
  title: 'Awaits another isolate outside runAsync',
  why:
      'compute(), Isolate.run(), Isolate.spawn() and ReceivePort reads finish '
      'on a real port. The reply is delivered into the FakeAsync zone and '
      'never processed while the test is waiting for it.',
  fix:
      'Wrap the call in `await tester.runAsync(() => ...)`, or call the '
      'function directly in the test instead of on an isolate.',
);

/// Awaiting the engine's image pipeline outside runAsync.
const engineAsync = Rule(
  id: 'engine-async',
  severity: Severity.error,
  title:
      'Awaits engine image work (toImage, toByteData, decoding) outside '
      'runAsync',
  why:
      'Image.toByteData, Picture.toImage, RenderRepaintBoundary.toImage, '
      'Codec.getNextFrame, decodeImageFromList and precacheImage wait for '
      'the engine. The result arrives on the real event loop, outside '
      'FakeAsync, so the test stops at its next await, or never finishes '
      'after the body returns.',
  fix:
      'Wrap the call in `await tester.runAsync(() => ...)`. For goldens, '
      'prefer matchesGoldenFile, which handles this for you.',
);

/// Blocking the isolate with sleep().
const blockingSleep = Rule(
  id: 'blocking-sleep',
  severity: Severity.warning,
  title: 'Calls sleep() inside a widget test',
  why:
      'sleep() blocks the isolate for real time and does not move the fake '
      'clock, so timers, animations and debounces still have not fired '
      'afterwards. Real async work cannot make progress while the isolate '
      'sleeps either.',
  fix:
      'Use `await tester.pump(duration)` to let fake time pass, or '
      '`await tester.runAsync(() => Future<void>.delayed(duration))` to wait '
      'for real work.',
);

/// pumpAndSettle while an indeterminate progress indicator is on screen.
const endlessSettle = Rule(
  id: 'endless-settle',
  severity: Severity.warning,
  title: 'pumpAndSettle with an indeterminate progress indicator on screen',
  why:
      'An indeterminate CircularProgressIndicator, LinearProgressIndicator, '
      'RefreshProgressIndicator or CupertinoActivityIndicator animates '
      'forever, so pumpAndSettle keeps pumping frames until its own timeout '
      'and then fails with "pumpAndSettle timed out".',
  fix:
      'Use `await tester.pump(duration)` while the indicator is visible, give '
      'the indicator a `value` in the test, or wait for the content with a '
      'bounded loop of pumps.',
);

/// rootBundle.loadString, which decodes large assets on an isolate.
const assetString = Rule(
  id: 'asset-string',
  severity: Severity.info,
  title:
      'Awaits AssetBundle.loadString, which uses an isolate for large '
      'assets',
  why:
      'AssetBundle.loadString decodes assets of 50 KB or more with compute(), '
      'which runs on another isolate. Small assets work, so the test hangs '
      'only once the asset grows past the limit.',
  fix:
      'Wrap the call in `await tester.runAsync(() => ...)`, or load the bytes '
      'with `load` and decode them with utf8.decode.',
);

/// A malformed `tarpit:allow` comment.
const badSuppression = Rule(
  id: 'bad-suppression',
  severity: Severity.warning,
  title: 'A tarpit:allow comment is missing a rule id or a reason',
  why:
      'Suppressions document why a pattern is safe. One without a known rule '
      'id or a reason is ignored, so the finding it was meant to silence is '
      'still reported.',
  fix:
      'Write `// tarpit:allow <rule-id> <reason>`, for example '
      '`// tarpit:allow real-io fixture is written in setUpAll`.',
);

/// Every rule, in documentation order.
const List<Rule> allRules = [
  fakeDelay,
  realIo,
  isolateHop,
  engineAsync,
  blockingSleep,
  endlessSettle,
  assetString,
  badSuppression,
];

/// Looks up a rule by id.
Rule? ruleById(String id) {
  for (final rule in allRules) {
    if (rule.id == id) return rule;
  }
  return null;
}
