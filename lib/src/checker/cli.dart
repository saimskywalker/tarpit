import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'checker.dart';
import 'report.dart';
import 'rules.dart';
import 'version.dart';

/// Exit code: nothing at or above the `--fail-on` severity.
const exitClean = 0;

/// Exit code: at least one finding at or above the `--fail-on` severity.
const exitFindings = 1;

/// Exit code: bad arguments, a missing path, or an internal error.
const exitUsage = 2;

ArgParser _parser() => ArgParser()
  ..addOption(
    'format',
    abbr: 'f',
    allowed: ['text', 'json', 'sarif'],
    defaultsTo: 'text',
    help: 'Output format.',
  )
  ..addOption(
    'fail-on',
    allowed: ['error', 'warning', 'info'],
    defaultsTo: 'warning',
    help: 'Lowest severity that makes the exit code 1.',
  )
  ..addOption(
    'output',
    abbr: 'o',
    valueHelp: 'file',
    help: 'Write the report to a file instead of stdout.',
  )
  ..addMultiOption(
    'test-function',
    valueHelp: 'name',
    splitCommas: false,
    help:
        'Also check bodies of this function, like testWidgets (repeatable). '
        'The body is the second positional argument and must be a function '
        'literal.',
  )
  ..addFlag('rules', negatable: false, help: 'List the rules and exit.')
  ..addFlag('version', negatable: false, help: 'Print the version and exit.')
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');

/// Runs the command line; returns the exit code.
///
/// Reports go to [out] (or `--output`), errors and help to [err].
Future<int> runCli(
  List<String> arguments, {
  StringSink? out,
  StringSink? err,
  String? workingDirectory,
  String? sdkPath,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  final parser = _parser();

  ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderrSink
      ..writeln('tarpit: ${e.message}')
      ..writeln()
      ..writeln(_usage(parser));
    return exitUsage;
  }

  if (args.flag('help')) {
    stdoutSink.writeln(_usage(parser));
    return exitClean;
  }
  if (args.flag('version')) {
    stdoutSink.writeln('tarpit $packageVersion');
    return exitClean;
  }
  if (args.flag('rules')) {
    stdoutSink.write(rulesReport());
    return exitClean;
  }

  final checker = Checker(workingDirectory: workingDirectory, sdkPath: sdkPath);
  var paths = args.rest;
  if (paths.isEmpty) {
    final defaultDir = Directory(p.join(checker.workingDirectory, 'test'));
    paths = [if (defaultDir.existsSync()) 'test' else '.'];
  }

  CheckResult result;
  try {
    result = await checker.check(
      paths,
      testFunctions: args.multiOption('test-function'),
    );
  } on CheckerInputException catch (e) {
    stderrSink.writeln('tarpit: $e');
    return exitUsage;
  }

  final report = switch (args.option('format')) {
    'json' => jsonReport(result),
    'sarif' => sarifReport(result),
    _ => textReport(result),
  };
  final output = args.option('output');
  if (output == null) {
    stdoutSink.write(report);
  } else {
    try {
      File(p.join(checker.workingDirectory, output)).writeAsStringSync(report);
    } on FileSystemException catch (e) {
      stderrSink.writeln('tarpit: cannot write $output: ${e.message}');
      return exitUsage;
    }
  }

  final threshold = Severity.parse(args.option('fail-on')!);
  return result.failsAt(threshold) ? exitFindings : exitClean;
}

String _usage(ArgParser parser) =>
    '''
Find code in testWidgets bodies that can stall FakeAsync.

Usage: tarpit [options] [paths...]

Paths are Dart files or directories (searched for *_test.dart).
Default: test/ if it exists, else the current directory.

${parser.usage}

Exit codes: 0 no findings at or above --fail-on, 1 findings, 2 usage error.
Silence a finding with: // tarpit:allow <rule-id> <reason>''';
