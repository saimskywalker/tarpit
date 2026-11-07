# Contributing

Thanks for helping widget tests fail fast instead of hanging. The most
valuable contributions are **new rules backed by a widget test that really
hangs**, **false positives** (tarpit flagged code that does not stall) and
**watchdog reports** from real suites.

## Development

tarpit depends on flutter_test, so use the Flutter SDK (3.44 or newer).

```bash
flutter pub get
(cd example && flutter pub get)
dart format .
dart analyze --fatal-infos
flutter test
flutter pub publish --dry-run
dart run tarpit                       # the repository's own tests: no findings
(cd example && dart run tarpit)       # the example: 3 findings, exit 1
```

CI runs these on the minimum supported Flutter (3.44.0) and a pinned current
stable, with `dart format --output=none --set-exit-if-changed .` (on the
pinned stable only) in place of `dart format .`.

## Adding a rule

1. **Start from a reproduction.** Open an issue with the smallest
   `testWidgets` that hangs or fails because of the pattern, the Flutter
   version, and what `tester.runAsync` or `tester.pump` changes. Links to
   Flutter issues or docs that explain the behaviour help.
2. **Write the rule.** Describe it in `lib/src/checker/rules.dart`:
   - `id`: kebab-case, stable forever (users write it in suppressions).
   - `title`: one line.
   - `why`: what happens inside FakeAsync, in terms someone who has never
     seen it can follow.
   - `fix`: what to write instead.
   Then detect it in `lib/src/checker/scan.dart`. Match on resolved
   elements (library and class), not on text; name-only matches are allowed
   only for unresolved files, and only as info. Prefer false negatives over
   false positives: a lint people ignore protects nobody. Anything that
   depends on state tarpit cannot see is info.
3. **Register it** in `allRules`.
4. **Test it** with a fixture in `test/fixtures/rules/` named after the rule:
   failing lines marked `// expect: <rule-id> <severity>` and a
   `testWidgets('safe uses', ...)` with the correct alternatives (see
   `test/fixtures/README.md`). Fixtures must be invented code.
5. **Document it**: a section in `doc/rules.md`, a row in the README rule
   table and a line in `CHANGELOG.md` (a test checks all three).

## Changing the watchdog

`lib/src/runtime/watchdog.dart` relies on how flutter_test's binding
completes a failed test. Keep `test/runtime/watchdog_e2e_test.dart` passing
on both CI Flutter versions; it runs stalling tests in a real
`flutter test` process.

## Pull requests

Small, focused commits with clear messages. Run the commands above before
pushing.

## AI-assisted contributions

Using AI tools is fine; please just be open about it.

- Say in the PR description which AI tools you used, if any: none, some or
  most, plus the tool or agent and the model (for example "Claude Code,
  Opus 5.5" or "Copilot, GPT-5").
- Please write the PR description in your own words; short and plain is fine.
  It shows us what you understood about the change. Please don't paste
  generated text.
- Read, run and test every line you submit, and be ready to explain it in
  review.
- If the disclosure is missing, a check adds a reminder to the PR. It does
  not fail the PR, but a maintainer will ask about it before merging.

## Stay in touch

Don't forget to follow [@saimskywalker](https://github.com/saimskywalker) on
GitHub to see new releases and other open-source projects as they come out.
