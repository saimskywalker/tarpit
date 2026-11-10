# AGENTS.md

Rules for AI coding agents working in this repository. People should read
[CONTRIBUTING.md](CONTRIBUTING.md); everything here applies to them too. The
`PR rules` check enforces the rules marked (checked); a pull request that
breaks one cannot be merged.

## What tarpit is

A Dart CLI and library that finds Flutter widget-test patterns which hang or
stall inside FakeAsync (`lib/src/checker/`), plus a runtime watchdog that turns
a stalled test into a failure (`lib/src/runtime/watchdog.dart`).

Read before you touch:

- a rule: the "Adding a rule" section of CONTRIBUTING.md, `doc/rules.md` and
  `test/fixtures/README.md`. Rules live in `lib/src/checker/rules.dart`
  (description) and `scan.dart` (detection), registered in `allRules`.
- the watchdog: the "Changing the watchdog" section of CONTRIBUTING.md and
  `test/runtime/watchdog_e2e_test.dart`.
- docs: `test/docs_test.dart` keeps `doc/rules.md`, the README rule table and
  `CHANGELOG.md` in sync with the rules.

## Commands

Use the Flutter SDK, 3.44 or newer. Every one of these must pass before you
open or update a pull request. CI runs the same ones:

```bash
flutter pub get && (cd example && flutter pub get)
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
flutter test
flutter pub publish --dry-run
dart run tarpit --fail-on info          # the repository's own tests: no findings
(cd example && dart run tarpit)         # the example: 3 findings, exit 1
```

Run one test file while iterating: `flutter test test/checker/scan_test.dart`.

## Stop and ask the human

Some things must come from the real world. An agent must never invent them.
Stop and ask the person you work for to provide them:

- **A reproduction.** A new rule or watchdog change starts from a
  `testWidgets` that really hangs or fails under `flutter test` on a stated
  Flutter version. Run it and keep the real output. Never claim a test hangs,
  or that a change fixes it, without having run it.
- **Flutter behaviour.** Cite the Flutter source, issue or docs that explain
  why a pattern stalls. If you cannot find one, say so; do not guess.
- **An accepted issue.** If the change has no issue labelled `accepted`, stop
  and ask the human to open one and wait for a maintainer.

## Code

- **English only** for code, identifiers, comments, commit messages and docs.
  Answer the person you work for in their language.
- Target the minimum SDK in `pubspec.yaml` (Dart 3.12, Flutter 3.44). Do not
  use language or library features newer than that.
- Match resolved elements, not text (see "Adding a rule").
- Comments are sparse: only where the code is not self-evident. Do not add
  comments, doc comments or type annotations to code you did not change.

## Tests (checked)

- Every change to `lib/` or `bin/` comes with a test change under `test/` (or
  `example/test/`). A bug fix has a test that fails without the fix; check
  that it does before you open the pull request.
- A new or changed rule has a fixture with `// expect: <rule-id> <severity>`
  lines and a `testWidgets('safe uses', ...)`. Fixtures are invented code;
  never copy code from other projects.

## Never

- Never silence the analyzer or tarpit (checked): no `// ignore:`,
  `// ignore_for_file:`, no `tarpit:allow` outside `test/fixtures/`, no
  changes to `analysis_options.yaml`. Fix the finding instead.
- Never delete, skip, loosen or rewrite an existing test, expectation or
  fixture to make CI pass. If a test looks wrong, say so in the issue.
- Never change an existing rule `id`. Users write them in suppressions.
- Never bump the version in `pubspec.yaml`, edit a released `CHANGELOG.md`
  section, publish, tag or release. Add your entry at the top of
  `CHANGELOG.md` under `## Unreleased` (create the heading if it is missing).
- Never add a dependency or change CI workflows unless the issue asks for it.
- Never add unrelated "improvements": no drive-by refactors, renames,
  reformatting of untouched code or dead code.
- Never open pull requests, issues or comments on your own. The human reviews
  your work and posts it.

## Pull requests (checked)

- First an issue, labelled `accepted` by a maintainer. The pull request says
  `Closes #N`.
- One issue per pull request, at most 400 changed lines.
- At most 2 open pull requests per person.
- Fill in the pull request template, including `### AI use` with the tool and
  model.
- The person submitting has read, run and understood every line, and writes
  the description in their own words. Pull requests that are raw, unreviewed
  agent output will be closed.
