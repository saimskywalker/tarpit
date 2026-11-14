# tarpit

Find the widget-test code that hangs your CI, before it runs, and make a
stalled `testWidgets` fail in seconds with a reason instead of sitting until
the timeout.

[![CI](https://github.com/saimskywalker/tarpit/actions/workflows/ci.yml/badge.svg)](https://github.com/saimskywalker/tarpit/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/saimskywalker/tarpit/blob/main/LICENSE)

## Why

`testWidgets` runs the test body in a `FakeAsync` zone. Timers there fire
only when the test pumps, and the results of real async work (files,
sockets, isolates, the engine's image pipeline) wait in the fake zone for a
pump that never comes. So one innocent line:

```dart
await File('test/fixtures/user.json').readAsString();
```

turns into a test that never finishes. Locally it looks like a frozen
runner; in CI the job sits until the ten-minute test timeout or the job
timeout, and the log does not say which line
([flutter/flutter#5728](https://github.com/flutter/flutter/issues/5728),
[flutter/flutter#139870](https://github.com/flutter/flutter/issues/139870)).

tarpit has two parts:

1. **A checker** (`dart run tarpit`) that reads your tests with the Dart
   analyzer and points at the lines that will stall, with why and how to fix
   each one.
2. **A watchdog** (`package:tarpit/flutter_test.dart`) that fails a widget
   test which makes no progress for 30 seconds, says what state it was stuck
   in, and lets the rest of the file run.

## Rules

| Rule | Severity | Reports |
|---|---|---|
| `fake-delay` | error | `await Future.delayed(...)`, `Future(...)` or `pumpEventQueue()` |
| `real-io` | error | an awaited `dart:io` call: files, directories, processes, sockets |
| `isolate-hop` | error | an awaited `compute`, `Isolate.run`/`spawn`, `ReceivePort` read |
| `engine-async` | error | an awaited `toByteData`, `toImage`, `getNextFrame`, `precacheImage` |
| `blocking-sleep` | warning | `sleep(...)` from `dart:io` |
| `endless-settle` | warning | `pumpAndSettle()` right after pumping an indeterminate progress indicator |
| `asset-string` | info | an awaited `AssetBundle.loadString` (uses an isolate at 50 KB and up) |
| `bad-suppression` | warning | a `tarpit:allow` comment without a known rule id or a reason |

Only `testWidgets` and `tarpitWidgets` bodies are checked by default.
`--test-function` adds other wrappers whose body is the second positional
argument and a function literal. Anything inside `tester.runAsync(...)` is
allowed. The same pattern inside a nested
closure the test may not await, or in a file whose imports do not resolve,
is reported as info rather than an error. [doc/rules.md](doc/rules.md) has
the details, examples and what each rule deliberately leaves alone.

## Install

```sh
flutter pub add --dev tarpit
```

Or install the command once for all projects (with the `dart` that comes
with Flutter):

```sh
dart pub global activate tarpit
```

## Run the checker

```sh
dart run tarpit                 # checks test/ (every *_test.dart)
dart run tarpit test/widgets    # or given directories and files
tarpit                          # when activated globally
```

Run `flutter pub get` first: tarpit uses your project's resolved types, so
`file.readAsString()` is known to be `dart:io` and not your own repository
class. Output from the [example](example/) project:

```text
$ cd example && dart run tarpit
test/stalls_test.dart:22:11  error  fake-delay
  Awaits Future.delayed(...); its fake timer fires only when the test pumps, and the test is waiting instead of pumping.
  fix: Advance fake time with `await tester.pump(duration)` instead. If you really need wall-clock time, wrap it in `tester.runAsync(...)`.

test/stalls_test.dart:28:24  error  real-io
  Awaits File.readAsString() from dart:io outside tester.runAsync; the result arrives on the real event loop and the test never resumes.
  fix: Wrap the call in `await tester.runAsync(() => ...)`, or do the I/O in setUp/setUpAll, or use an in-memory fake (for example package:file).

test/stalls_test.dart:40:11  warning  endless-settle
  pumpAndSettle() right after pumping an indeterminate CircularProgressIndicator (line 38); the indicator animates forever, so this never settles.
  fix: Use `await tester.pump(duration)` while the indicator is visible, give the indicator a `value` in the test, or wait for the content with a bounded loop of pumps.

Why:
  fake-delay: testWidgets runs the body in a FakeAsync zone. Future.delayed, Future(...) and pumpEventQueue() schedule fake timers, which fire only when the test pumps. While the body is awaiting one, nothing pumps, so the await never returns.
  real-io: dart:io completes on the real event loop, but the continuation is queued in the FakeAsync zone, which only drains when the test pumps. The test waits for I/O that has finished but is never delivered.
  endless-settle: An indeterminate CircularProgressIndicator, LinearProgressIndicator, RefreshProgressIndicator or CupertinoActivityIndicator animates forever, so pumpAndSettle keeps pumping frames until its own timeout and then fails with "pumpAndSettle timed out".

3 findings (2 errors, 1 warning, 0 info) in 2 files.
$ echo $?
1
```

### Options and exit codes

| Option | Meaning |
|---|---|
| `-f`, `--format text\|json\|sarif` | Output format (default `text`). |
| `--fail-on error\|warning\|info` | Lowest severity that makes the exit code 1 (default `warning`). |
| `-o`, `--output <file>` | Write the report to a file instead of stdout. |
| `--test-function <name>` | Also check this function like `testWidgets` (repeatable). The body is the second positional argument and must be a function literal. |
| `--rules` | List the rules. |
| `--version`, `-h`, `--help` | |

Exit code `0`: nothing at or above `--fail-on`. `1`: findings. `2`: bad
arguments, a path that does not exist, or a report that cannot be written.

`--format json` prints `{"format": "tarpit-json", "formatVersion": 1, ...}`
with one object per finding (`rule`, `severity`, `path`, `line`, `column`,
`message`, `why`, `fix`). `--format sarif` prints SARIF 2.1.0 for GitHub
code scanning:

```yaml
- run: dart run tarpit --format sarif --output tarpit.sarif || test $? -eq 1
- uses: github/codeql-action/upload-sarif@v4
  with:
    sarif_file: tarpit.sarif
- run: dart run tarpit
```

### Suppressing a finding

When a pattern is fine in one place, say why next to it:

```dart
await File('golden.txt').exists(); // tarpit:allow real-io runs only with the live binding

// tarpit:allow fake-delay,real-io this helper pumps from a fake timer
await waitForSync();
```

The comment works on its own line or on the line above. `// tarpit:allow-file
<rule-id> <reason>` covers a whole file. The reason is required; without
one, or with an unknown rule id, the comment is ignored and reported as
`bad-suppression`.

## The watchdog

Change one import in a test file:

```dart
import 'package:tarpit/flutter_test.dart'; // instead of package:flutter_test
```

Every `testWidgets` in that file now runs under a watchdog. Or use
`tarpitWidgets(...)` from `package:tarpit/tarpit.dart` for single tests,
and `watchTester(tester, description, body)` inside a custom wrapper.

A test that stops making progress (the fake clock does not move and no
frame is pumped) for `Tarpit.stallAfter` (30 seconds) fails with a
`TarpitStall`, and the next test runs normally. A test that keeps pumping is
never stopped, however long it takes. From `flutter test` in the example:

```text
══╡ EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK ╞════════════════════════════════════════════════════
The following TarpitStall was thrown running a test:
tarpit: "reads the name from a file" made no progress for 3.0s and was stopped.

  real time in the test body: 3.0s
  fake clock moved:           0.0s (it moves only when the test pumps)
  frames pumped:              0
  running tickers:            0
  frame requested, not pumped: no

The test body is awaiting a Future that nothing in the FakeAsync zone of testWidgets will complete.
Usual causes:
  - Future.delayed, Future(...) or pumpEventQueue() awaited instead of tester.pump(duration)
  - file, socket or process I/O, compute() or Isolate.run() awaited outside tester.runAsync(...)
  - engine image work (toByteData, toImage, getNextFrame) awaited outside tester.runAsync(...)
  - a Completer or stream that waits for a platform channel, plugin or service the test does not
fake

Run `dart run tarpit` on the test file to find likely lines. If the test was inside tester.runAsync,
flutter_test still waits for that real work before it moves on. If the test is just slow without
pumping, raise the limit with stallAfter: or Tarpit.stallAfter.
```

Set the limit for a whole suite in `test/flutter_test_config.dart`:

```dart
import 'dart:async';

import 'package:tarpit/tarpit.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  Tarpit.stallAfter = const Duration(seconds: 20); // Duration.zero turns it off
  await testMain();
}
```

or per test with `stallAfter:`.

### Watch the whole suite

To watch every `testWidgets` without changing any imports, install the
tarpit binding in `test/flutter_test_config.dart`:

```dart
import 'dart:async';

import 'package:tarpit/tarpit.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TarpitBinding.ensureInitialized(stallAfter: const Duration(seconds: 20));
  await testMain();
}
```

This covers wrappers that call `testWidgets`, such as `testGoldens`, too.
An isolate has only one binding, so if your suite already creates its own,
add the watchdog to it with the mixin instead:

```dart
class AppTestBinding extends AutomatedTestWidgetsFlutterBinding
    with TarpitWatchdogBinding {}
```

A file that also imports `package:tarpit/flutter_test.dart` is still
watched once per test, and its `stallAfter:` arguments still apply. The
binding does not know when the test body returns, so the "The test body
returned" hint needs the per-file import. Only the automated binding is
covered, not the live one (`flutter run` on a test file).

Engine image work awaited outside `tester.runAsync` (`toByteData`,
`toImage`, `getNextFrame`;
[flutter/flutter#50783](https://github.com/flutter/flutter/issues/50783))
does not block the test isolate. The engine finishes and the bytes arrive,
but on the real event loop, outside the fake zone, so the test stops at its
next await, or never finishes after the body returns when that call was the
last one. The watchdog fails both; the second says "The test body returned,
but the test never finished". `test/runtime/watchdog_e2e_test.dart` checks
this on Flutter 3.47.7 (macOS 27.2) and in CI on Flutter 3.44.0 and 3.47.7
(Ubuntu 24.04).

What the watchdog cannot do:

- **Inside `tester.runAsync`**, the failure is reported on time, but
  flutter_test waits for the real work before it starts the next test.
- `experimentalLeakTesting` is not passed through; use flutter_test's
  `testWidgets` for those tests.

## How it works

The checker builds an `AnalysisContextCollection` over the files, gets each
file's resolved AST from package:analyzer, finds `testWidgets`,
`tarpitWidgets` and any `--test-function` calls whose body is a function
literal, and walks the body: awaited expressions are
classified by the library and class of the element they call (`dart:io`,
`dart:isolate`, `dart:ui`, `package:flutter`), not by text. Without
resolved types it only reports what it can recognise by name, as info.

The watchdog runs a real timer in the root zone next to the test's fake
one. When the fake clock and the frame count stay still for the limit, it
reports a `TarpitStall` into the test's zone, which flutter_test's binding
handles like any other test failure, and drains the binding's pending
microtasks so the test completes. It keeps watching until the test's
tear-down, not just until the body returns.

## Contributing

Issues and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).
New rules need a reproduction that hangs or fails a real widget test.
tarpit is the successor to `imaji_test_hang`.

## License

MIT, see [LICENSE](LICENSE).
