# AGENTS.md

Guidance for AI coding agents working in this repository. People should read
[CONTRIBUTING.md](CONTRIBUTING.md); everything here applies to them too.

## What tarpit is

A Dart CLI and library that finds Flutter widget-test patterns which hang or
stall inside FakeAsync (`lib/src/checker/`), plus a runtime watchdog that turns
a stalled test into a failure (`lib/src/runtime/watchdog.dart`).

- Rules: `lib/src/checker/rules.dart` (description), `scan.dart` (detection),
  registered in `allRules`.
- Rule fixtures: `test/fixtures/rules/<rule>.dart`, with `// expect:` lines
  (see `test/fixtures/README.md`).
- Docs that a test keeps in sync: `doc/rules.md`, the README rule table and
  `CHANGELOG.md` (`test/docs_test.dart`).

## Commands

Use the Flutter SDK, 3.44 or newer. Run all of these before you open or update
a pull request. CI runs the same ones, and every one must pass:

```bash
flutter pub get && (cd example && flutter pub get)
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
flutter test
flutter pub publish --dry-run
dart run tarpit --fail-on info          # the repository's own tests: no findings
(cd example && dart run tarpit)         # the example: 3 findings, exit 1
```

## Tests are required

- Every change to `lib/` or `bin/` comes with a test change under `test/` (or
  `example/test/`). The `tests required` check fails the pull request
  otherwise. Only a maintainer can waive it, with the `no-tests-needed` label.
- A bug fix has a test that fails without the fix. Check that it does.
- A new or changed rule has a fixture with `// expect: <rule-id> <severity>`
  lines and a `testWidgets('safe uses', ...)`.

## Never

- Never delete, skip, loosen or rewrite an existing test, expectation or
  fixture to make CI pass. If a test looks wrong, say so in the issue.
- Never change an existing rule `id`. Users write them in suppressions.
- Never copy code from other projects into fixtures. Fixtures are invented.
- Never bump the version in `pubspec.yaml`, edit a released `CHANGELOG.md`
  section, publish, tag or release. Add your entry at the top of `CHANGELOG.md`
  under `## Unreleased` (create the heading if it is missing).
- Never add a dependency or change CI workflows unless the issue asks for it.
- Never add unrelated "improvements": no drive-by refactors, renames,
  reformatting of untouched code, extra comments or dead code.

## Pull requests

- One issue per pull request, as small as possible. Link it with `Closes #N`.
- Fill in the pull request template, including `### AI use` with the tool and
  model.
- The person submitting must have read, run and understood every line, and
  write the description in their own words. Pull requests that are raw,
  unreviewed agent output will be closed.
