# Changelog

## 0.1.1

- Watchdog: a test whose body returns while the rest of the test waits on
  a microtask nothing flushes now fails with a `TarpitStall` instead of
  hanging. Engine image work (`toByteData`, `toImage`, `getNextFrame`)
  awaited outside `tester.runAsync` as the body's last await did this
  ([flutter/flutter#50783](https://github.com/flutter/flutter/issues/50783)).
  The watchdog now runs until the test's tear-down, and the report says
  when the body had already returned (`TarpitStall.bodyReturned`).
- Docs: engine image calls do not block the test isolate, and the watchdog
  catches them; the README, doc/rules.md and the `engine-async` text said
  otherwise.

## 0.1.0

First release.

- `tarpit` command: checks `testWidgets` bodies with the Dart analyzer
  (resolved AST, not text matching) for code that stalls the FakeAsync zone.
  Code inside `tester.runAsync` is skipped; the same patterns inside nested
  closures, or in files whose imports do not resolve, are reported as info.
- Rules: `fake-delay`, `real-io`, `isolate-hop`, `engine-async` (errors),
  `blocking-sleep`, `endless-settle` (warnings), `asset-string` (info), and
  `bad-suppression` for malformed suppression comments.
- Suppressions with a required reason: `// tarpit:allow <rule-id> <reason>`
  for one line, `// tarpit:allow-file <rule-id> <reason>` for a file.
- Text, JSON (`tarpit-json`, `formatVersion: 1`) and SARIF 2.1.0 output;
  `--fail-on`, `--output`, `--rules`; exit codes 0 / 1 / 2.
- Watchdog (`package:tarpit/tarpit.dart`): `tarpitWidgets`, `watchTester`
  and `Tarpit.stallAfter` fail a widget test that makes no progress (no
  pump, no frame) for 30 seconds with a `TarpitStall` describing the state
  it was stuck in, then let the next test run. `package:tarpit/flutter_test.dart`
  is flutter_test with that `testWidgets`, for a one-line opt-in.
