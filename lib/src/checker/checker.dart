import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:path/path.dart' as p;

import 'finding.dart';
import 'rules.dart';
import 'scan.dart';
import 'suppressions.dart';

/// A path given to the checker does not exist or is not a Dart file.
class CheckerInputException implements Exception {
  /// Creates the exception.
  const CheckerInputException(this.message);

  /// What is wrong.
  final String message;

  @override
  String toString() => message;
}

/// The outcome of a run.
class CheckResult {
  /// Creates a result.
  const CheckResult({
    required this.findings,
    required this.files,
    required this.untyped,
  });

  /// All findings that were not suppressed, sorted by location.
  final List<Finding> findings;

  /// The files that were checked, as displayed in findings.
  final List<String> files;

  /// Files checked without type information (imports did not resolve).
  final List<String> untyped;

  /// Number of findings with [severity].
  int count(Severity severity) =>
      findings.where((f) => f.severity == severity).length;

  /// Whether any finding is at least as serious as [threshold].
  bool failsAt(Severity threshold) =>
      findings.any((f) => f.severity.atLeast(threshold));
}

/// Checks widget test files for code that can stall FakeAsync.
class Checker {
  /// Creates a checker; paths in results are shown relative to
  /// [workingDirectory] (default: the current directory).
  ///
  /// [sdkPath] is the Dart SDK used to resolve `dart:` libraries; by default
  /// the analyzer finds the SDK of the running `dart` executable.
  Checker({String? workingDirectory, this.sdkPath})
    : workingDirectory = p.normalize(
        p.absolute(workingDirectory ?? Directory.current.path),
      );

  /// Directory that relative input paths and displayed paths use.
  final String workingDirectory;

  /// Dart SDK to analyze with, or null for the running one.
  final String? sdkPath;

  /// Checks [paths]: Dart files, or directories searched for `*_test.dart`.
  ///
  /// [testFunctions] names extra functions treated like `testWidgets`. The
  /// body is still the second positional argument and must be a function
  /// literal.
  Future<CheckResult> check(
    List<String> paths, {
    Iterable<String> testFunctions = const [],
  }) async {
    final files = collectFiles(paths);
    final findings = <Finding>[];
    final untyped = <String>[];
    if (files.isEmpty) {
      return CheckResult(findings: findings, files: const [], untyped: untyped);
    }

    final collection = AnalysisContextCollection(
      includedPaths: files,
      resourceProvider: PhysicalResourceProvider.INSTANCE,
      sdkPath: sdkPath,
    );
    for (final file in files) {
      final shown = _display(file);
      final source = File(file).readAsStringSync();
      CompilationUnit unit;
      var resolved = false;
      try {
        final result = await collection
            .contextFor(file)
            .currentSession
            .getResolvedUnit(file);
        if (result is ResolvedUnitResult) {
          unit = result.unit;
          resolved = _importsResolve(result);
        } else {
          unit = _parse(source, file);
        }
      } on Object {
        unit = _parse(source, file);
      }
      if (!resolved) untyped.add(shown);
      findings.addAll(
        checkUnit(
          unit,
          source,
          shown,
          resolved: resolved,
          testFunctions: testFunctions,
        ),
      );
    }
    findings.sort();
    return CheckResult(
      findings: findings,
      files: [for (final f in files) _display(f)],
      untyped: untyped,
    );
  }

  /// Expands [paths] into the absolute, sorted list of files to check.
  List<String> collectFiles(List<String> paths) {
    final files = <String>{};
    for (final input in paths) {
      final path = p.normalize(p.join(workingDirectory, input));
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.file) {
        if (!path.endsWith('.dart')) {
          throw CheckerInputException('$input is not a Dart file.');
        }
        files.add(path);
      } else if (type == FileSystemEntityType.directory) {
        files.addAll(_testsUnder(path));
      } else {
        throw CheckerInputException('$input does not exist.');
      }
    }
    return files.toList()..sort();
  }

  Iterable<String> _testsUnder(String directory) sync* {
    final entries = Directory(directory).listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (entry is Directory) {
        if (name.startsWith('.') || name == 'build') continue;
        yield* _testsUnder(entry.path);
      } else if (entry is File && name.endsWith('_test.dart')) {
        yield p.normalize(entry.path);
      }
    }
  }

  String _display(String file) {
    if (p.isWithin(workingDirectory, file)) {
      return p.relative(file, from: workingDirectory);
    }
    return file;
  }
}

/// Checks one parsed [unit] whose text is [source], reporting it as [path].
///
/// [testFunctions] names extra functions treated like `testWidgets`. The
/// body is still the second positional argument and must be a function
/// literal.
List<Finding> checkUnit(
  CompilationUnit unit,
  String source,
  String path, {
  required bool resolved,
  Iterable<String> testFunctions = const [],
}) {
  final suppressions = Suppressions.of(unit, source);
  final lineInfo = unit.lineInfo;
  final findings = <Finding>[];

  Finding at(Rule rule, Severity severity, int offset, String message) {
    final location = lineInfo.getLocation(offset);
    return Finding(
      rule: rule,
      severity: severity,
      path: path,
      line: location.lineNumber,
      column: location.columnNumber,
      message: message,
    );
  }

  for (final hit in scanUnit(
    unit,
    resolved: resolved,
    testFunctions: testFunctions,
  )) {
    final finding = at(hit.rule, hit.severity, hit.offset, hit.message);
    if (!suppressions.covers(hit.rule.id, finding.line)) {
      findings.add(finding);
    }
  }
  for (final problem in suppressions.problems) {
    findings.add(
      at(
        badSuppression,
        badSuppression.severity,
        problem.offset,
        problem.message,
      ),
    );
  }
  return findings..sort();
}

CompilationUnit _parse(String source, String path) =>
    parseString(content: source, path: path, throwIfDiagnostics: false).unit;

/// Whether every import of the file was found. Without that, names from
/// the missing libraries have no elements and only name matches are left.
bool _importsResolve(ResolvedUnitResult result) => !result.diagnostics.any(
  (d) => const {
    'uri_does_not_exist',
    'uri_has_not_been_generated',
  }.contains(d.diagnosticCode.lowerCaseName),
);
