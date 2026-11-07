# Rules

tarpit looks only inside the body of `testWidgets` (and `tarpitWidgets`)
calls whose body is a function literal. Code inside a closure passed to
`tester.runAsync(...)` is skipped: real async work is allowed there.

Severities:

- **error**: stalls the test every time it runs.
- **warning**: stalls or fails the test in the common case.
- **info**: can stall, depending on something tarpit cannot see. The same
  patterns as an error or warning are reported as info when they sit inside
  a nested closure (a callback, a local function) that the test may or may
  not await, or when the file's imports do not resolve and the match is by
  name only.

By default the command exits 1 on warnings and errors; `--fail-on info`
makes info count too, `--fail-on error` ignores warnings.

Each rule is precise on purpose: when tarpit cannot tell, it says nothing or
reports info. A false negative is better than a lint people learn to ignore.

## Why widget tests hang

`testWidgets` runs the test body inside a `FakeAsync` zone. Timers in that
zone are fake: they fire only when the test calls `tester.pump(duration)`
(or `pumpAndSettle`). Microtasks queued in the zone run only when the test
pumps or the binding flushes them. Real asynchronous work (file and socket
I/O, other isolates, the engine's image pipeline) finishes on the real
event loop, but its continuation lands in the fake zone and waits there.

So a test body that `await`s such work, without pumping and outside
`tester.runAsync`, waits for something that will not arrive. The test then
sits until the test timeout (ten minutes by default for `testWidgets`) or
the CI job's timeout, often with no hint about the line. See for example
flutter/flutter#5728 and flutter/flutter#139870.

## Suppressing a finding

```dart
await File('golden.txt').exists(); // tarpit:allow real-io runs only with the live binding
```

- `// tarpit:allow <rule-id> <reason>` on the line of the finding, or alone
  on the line above it.
- Several rules: `// tarpit:allow real-io,fake-delay <reason>`.
- The whole file: `// tarpit:allow-file <rule-id> <reason>` anywhere in it.
- The reason is required. A comment without one, or with an unknown rule
  id, is ignored and reported as [`bad-suppression`](#bad-suppression).

## fake-delay

**error.** Awaits `Future.delayed(...)`, `Future(...)` or `pumpEventQueue()`
in the test body.

```dart
// Stalls: the 100 ms timer is fake and nothing pumps while the test waits.
await Future<void>.delayed(const Duration(milliseconds: 100));

// Works: advances fake time and fires the timer at once.
await tester.pump(const Duration(milliseconds: 100));
```

Also caught through `.timeout(...)`, `.then(...)`, `.catchError(...)`,
`.whenComplete(...)`, inside `Future.wait([...])` and `Future.any([...])`,
and as the returned value of the body. Not reported: a delay that is
started but not awaited (flutter_test already fails a test that leaves a
timer pending), `Future.value` and `Future.microtask`.

## real-io

**error.** Awaits a `Future` returned by a `dart:io` API: `File`,
`Directory`, `Link`, `RandomAccessFile`, `Process`, `Socket`,
`ServerSocket`, `HttpServer`, `InternetAddress` and so on.

```dart
// Stalls.
final json = await File('test/fixtures/user.json').readAsString();

// Works.
final json = await tester.runAsync(
  () => File('test/fixtures/user.json').readAsString(),
);
// Also works: synchronous I/O, or reading the file in setUpAll.
final json = File('test/fixtures/user.json').readAsStringSync();
```

Needs type information (`flutter pub get`). `HttpClient`, its request and
response, and `WebSocket` are not reported: flutter_test replaces
`HttpClient` with a fake that answers 400 at once, so those calls fail
rather than stall.

## isolate-hop

**error.** Awaits work on another isolate: `compute(...)` from Flutter,
`Isolate.run`, `Isolate.spawn`, `Isolate.spawnUri`, or a read such as
`.first` on a `ReceivePort`.

```dart
// Stalls.
final parsed = await compute(parseUsers, json);

// Works.
final parsed = await tester.runAsync(() => compute(parseUsers, json));
// Or call the function directly in the test.
final parsed = parseUsers(json);
```

## engine-async

**error.** Awaits the engine's image pipeline: `Image.toByteData`,
`Picture.toImage`, `Scene.toImage`, `Codec.getNextFrame` and
`decodeImageFromList` from `dart:ui`, and `precacheImage`,
`RenderRepaintBoundary.toImage`, `OffsetLayer.toImage` and
`decodeImageFromList` from Flutter.

```dart
// Stalls: the bytes arrive outside the fake zone.
final bytes = await image.toByteData(format: ui.ImageByteFormat.png);

// Works.
final bytes = await tester.runAsync(
  () => image.toByteData(format: ui.ImageByteFormat.png),
);
```

These calls do not block the test isolate
([flutter/flutter#50783](https://github.com/flutter/flutter/issues/50783)).
The engine finishes the work and the result arrives, but on the real event
loop, outside the FakeAsync zone. The test then stops at its next await, or,
when the call was its last await, the body returns and the test never
finishes. The [watchdog](../README.md#the-watchdog) fails both after
`Tarpit.stallAfter`; this rule finds them before the test runs. Checked by
`test/runtime/watchdog_e2e_test.dart` on Flutter 3.47.7 (macOS 27.2) and in
CI on Flutter 3.44.0 and 3.47.7 (Ubuntu 24.04).
`ui.instantiateImageCodec` itself completes and is not reported.

## blocking-sleep

**warning.** Calls `sleep(...)` from `dart:io` in the test body.

```dart
// Does not do what it looks like: the fake clock does not move, so timers,
// debouncers and animations have still not fired afterwards.
sleep(const Duration(milliseconds: 300));

// Works.
await tester.pump(const Duration(milliseconds: 300));
```

`sleep` blocks the isolate for real time. It cannot move the fake clock, and
real async work cannot make progress during it either. A local function
that happens to be called `sleep` is not reported.

## endless-settle

**warning.** Calls `tester.pumpAndSettle()` right after a `pumpWidget` whose
widget tree contains an indeterminate `CircularProgressIndicator`,
`LinearProgressIndicator`, `RefreshProgressIndicator` or
`CupertinoActivityIndicator`.

```dart
await tester.pumpWidget(const MaterialApp(home: CircularProgressIndicator()));
// Fails with "pumpAndSettle timed out": the spinner always has another frame.
await tester.pumpAndSettle();

// Works.
await tester.pump(const Duration(seconds: 1));
```

Indicators with a `value`, a `CupertinoActivityIndicator(animating: false)`
and indicators produced by builders or conditionals (for example the
loading branch of a `FutureBuilder`) are not reported, because whether they
are still on screen depends on state. When other statements run between the
`pumpWidget` and the `pumpAndSettle`, the finding is info.

## asset-string

**info.** Awaits `AssetBundle.loadString` (for example
`rootBundle.loadString`).

```dart
// Works today, stalls once terms.txt grows past 50 KB.
final terms = await rootBundle.loadString('assets/terms.txt');

// Works at any size.
final terms = await tester.runAsync(
  () => rootBundle.loadString('assets/terms.txt'),
);
```

Flutter decodes string assets of 50 KB or more with `compute`, which runs
on another isolate (see [`isolate-hop`](#isolate-hop)). The rule is info
because tarpit does not know the asset's size.

## bad-suppression

**warning.** A `// tarpit:allow` comment that names no rule, names an
unknown rule, or gives no reason. The comment is ignored, so the finding it
was meant to silence is reported as well.

```dart
await Future<void>.delayed(Duration.zero); // tarpit:allow fake-delay
// bad-suppression: no reason, and fake-delay is still reported.
```

`bad-suppression` itself cannot be suppressed.
