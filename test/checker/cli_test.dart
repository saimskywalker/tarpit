import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tarpit/checker.dart';

import '../support/sdk.dart';

class _Run {
  _Run(this.code, this.out, this.err);
  final int code;
  final String out;
  final String err;
}

void main() {
  late Directory project;

  setUp(() {
    project = Directory.systemTemp.createTempSync('tarpit_cli_');
    Directory(
      p.join(project.path, 'test', 'widgets'),
    ).createSync(recursive: true);
    File(
      p.join(project.path, 'test', 'widgets', 'stalls_test.dart'),
    ).writeAsStringSync('''
void main() {
  testWidgets('stalls', (tester) async {
    await Future<void>.delayed(const Duration(seconds: 1));
  });
}
''');
    File(p.join(project.path, 'test', 'clean_test.dart')).writeAsStringSync('''
void main() {
  testWidgets('clean', (tester) async {
    await tester.pump(const Duration(seconds: 1));
  });
}
''');
    File(p.join(project.path, 'test', 'helper.dart')).writeAsStringSync('''
void main() {
  testWidgets('not a test file name', (tester) async {
    await Future<void>.delayed(Duration.zero);
  });
}
''');
  });

  tearDown(() => project.deleteSync(recursive: true));

  Future<_Run> run(List<String> args) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runCli(
      args,
      out: out,
      err: err,
      workingDirectory: project.path,
      sdkPath: dartSdk(),
    );
    return _Run(code, out.toString(), err.toString());
  }

  test('scans test/ for *_test.dart by default and exits 1', () async {
    final r = await run([]);
    expect(r.code, exitFindings);
    expect(
      r.out,
      contains(
        '${p.join('test', 'widgets', 'stalls_test.dart')}:3:11  error  '
        'fake-delay',
      ),
    );
    expect(r.out, isNot(contains('helper.dart')));
    expect(
      r.out,
      contains('1 finding (1 error, 0 warnings, 0 info) in 2 files.'),
    );
    expect(r.out, contains('Why:\n  fake-delay: '));
  });

  test('exits 0 when nothing reaches --fail-on', () async {
    final r = await run(['test/clean_test.dart']);
    expect(r.code, exitClean);
    expect(r.out.trim(), 'No findings in 1 file.');
  });

  test('--fail-on info fails on an info finding', () async {
    File(p.join(project.path, 'test', 'clean_test.dart')).writeAsStringSync('''
import 'dart:io';

void main() {
  testWidgets('x', (tester) async {
    void later() => sleep(Duration.zero);
  });
}
''');
    expect((await run(['test/clean_test.dart'])).code, exitClean);
    expect(
      (await run(['--fail-on', 'info', 'test/clean_test.dart'])).code,
      exitFindings,
    );
  });

  test('--test-function checks custom wrapper bodies', () async {
    File(p.join(project.path, 'test', 'clean_test.dart')).writeAsStringSync('''
void main() {
  testScreen('stalls', (tester) async {
    await Future<void>.delayed(const Duration(seconds: 1));
  });
  testGoldens('stalls too', (tester) async {
    await Future<void>.delayed(const Duration(seconds: 1));
  });
  other('ignored', (tester) async {
    await Future<void>.delayed(const Duration(seconds: 1));
  });
}
''');
    expect((await run(['test/clean_test.dart'])).code, exitClean);
    expect((await run(['--help'])).out, contains('--test-function'));
    final r = await run([
      '--test-function',
      'testScreen',
      '--test-function',
      'testGoldens',
      'test/clean_test.dart',
    ]);
    expect(r.code, exitFindings);
    expect(r.out, contains('fake-delay'));
    expect(
      r.out,
      contains('2 findings (2 errors, 0 warnings, 0 info) in 1 file.'),
    );
  });

  test('explicit files need not end in _test.dart', () async {
    final r = await run(['test/helper.dart']);
    expect(r.code, exitFindings);
  });

  test('json output', () async {
    final r = await run(['--format', 'json']);
    final data = jsonDecode(r.out) as Map<String, Object?>;
    expect(data['format'], 'tarpit-json');
    expect(data['formatVersion'], 1);
    expect(data['summary'], {'error': 1, 'warning': 0, 'info': 0});
    final finding = (data['findings']! as List).single as Map<String, Object?>;
    expect(finding['rule'], 'fake-delay');
    expect(finding['line'], 3);
    expect(finding['column'], 11);
    expect(finding['fix'], fakeDelay.fix);
  });

  test('sarif output', () async {
    final r = await run(['-f', 'sarif']);
    final data = jsonDecode(r.out) as Map<String, Object?>;
    expect(data['version'], '2.1.0');
    final run0 = (data['runs']! as List).single as Map<String, Object?>;
    final driver =
        (run0['tool']! as Map<String, Object?>)['driver']!
            as Map<String, Object?>;
    expect((driver['rules']! as List).length, allRules.length);
    final result = (run0['results']! as List).single as Map<String, Object?>;
    expect(result['ruleId'], 'fake-delay');
    expect(result['level'], 'error');
    final location =
        ((result['locations']! as List).single
                as Map<String, Object?>)['physicalLocation']!
            as Map<String, Object?>;
    expect(
      (location['artifactLocation']! as Map<String, Object?>)['uri'],
      'test/widgets/stalls_test.dart',
    );
  });

  test('--output writes the report to a file', () async {
    final r = await run(['-o', 'report.json', '-f', 'json']);
    expect(r.out, isEmpty);
    expect(
      File(p.join(project.path, 'report.json')).readAsStringSync(),
      contains('"fake-delay"'),
    );
  });

  test('a missing path is a usage error', () async {
    final r = await run(['nope']);
    expect(r.code, exitUsage);
    expect(r.err, contains('nope does not exist'));
  });

  test('an unknown format is a usage error', () async {
    final r = await run(['--format', 'xml']);
    expect(r.code, exitUsage);
    expect(r.err, contains('Usage: tarpit'));
  });

  test('--rules lists every rule', () async {
    final r = await run(['--rules']);
    expect(r.code, exitClean);
    for (final rule in allRules) {
      expect(r.out, contains('${rule.id}  (${rule.severity.name})'));
    }
  });

  test('--version matches pubspec.yaml', () async {
    final r = await run(['--version']);
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version: (\S+)$',
      multiLine: true,
    ).firstMatch(pubspec)![1];
    expect(r.out.trim(), 'tarpit $version');
  });
}
