import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import 'rules.dart';

/// A finding before it has a line and column.
class Hit {
  /// Creates a hit.
  const Hit(this.rule, this.severity, this.offset, this.message);

  /// The rule that matched.
  final Rule rule;

  /// Severity of this occurrence.
  final Severity severity;

  /// Offset of the matched node in the file.
  final int offset;

  /// What was found.
  final String message;
}

/// Finds the risky patterns in every widget test body in [unit].
///
/// [resolved] says whether the unit carries type information. Without it,
/// only patterns that can be recognised by name are reported, as info.
///
/// [testFunctions] names extra functions treated like `testWidgets`. The
/// body is still the second positional argument and must be a function
/// literal.
List<Hit> scanUnit(
  CompilationUnit unit, {
  required bool resolved,
  Iterable<String> testFunctions = const [],
}) {
  final finder = _WidgetTestFinder(resolved, {
    ..._widgetTestFunctions,
    ...testFunctions,
  });
  unit.accept(finder);
  return finder.hits;
}

/// Functions whose second positional argument is a widget test body.
const _widgetTestFunctions = {'testWidgets', 'tarpitWidgets'};

/// Future methods that still wait for their receiver.
const _passThrough = {'timeout', 'then', 'catchError', 'whenComplete'};

const _httpClasses = {
  'HttpClient',
  'HttpClientRequest',
  'HttpClientResponse',
  'WebSocket',
};

const _engineUi = {
  'toByteData',
  'toImage',
  'getNextFrame',
  'decodeImageFromList',
};
const _engineFlutter = {'precacheImage', 'toImage', 'decodeImageFromList'};

const _indicators = {
  'CircularProgressIndicator',
  'LinearProgressIndicator',
  'RefreshProgressIndicator',
  'CupertinoActivityIndicator',
};

class _WidgetTestFinder extends RecursiveAstVisitor<void> {
  _WidgetTestFinder(this.resolved, this._testFunctions);

  final bool resolved;
  final Set<String> _testFunctions;
  final hits = <Hit>[];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final body = _widgetTestBody(node);
    if (body == null) {
      super.visitMethodInvocation(node);
      return;
    }
    _BodyScan(this, body).run();
  }

  /// The body passed to `name(description, body)`, if it is a literal.
  FunctionExpression? _widgetTestBody(MethodInvocation node) {
    if (!_testFunctions.contains(node.methodName.name)) return null;
    // Allow an import prefix (`ft.testWidgets`), not a method on an object.
    final target = node.target;
    if (target != null) {
      if (target is! SimpleIdentifier) return null;
      final element = target.element;
      if (element != null && element is! PrefixElement) return null;
    }
    final positional = node.argumentList.arguments
        .whereType<Expression>()
        .toList();
    if (positional.length < 2) return null;
    final body = positional[1];
    return body is FunctionExpression ? body : null;
  }
}

class _BodyScan extends RecursiveAstVisitor<void> {
  _BodyScan(this.owner, this.callback)
    : testerName = callback.parameters?.parameters.firstOrNull?.name?.lexeme;

  final _WidgetTestFinder owner;
  final FunctionExpression callback;
  final String? testerName;

  /// How many closures deep the visitor is; 0 is the test body itself.
  int _depth = 0;

  /// The last `pumpWidget` that put an indeterminate indicator on screen.
  _PumpedIndicator? _indicator;

  bool get _resolved => owner.resolved;

  void run() {
    final body = callback.body;
    if (body is ExpressionFunctionBody) {
      // `(tester) => future`: the framework awaits the returned future.
      _awaited(body.expression);
    }
    body.accept(this);
  }

  void _hit(Rule rule, AstNode node, String message, {bool sure = true}) {
    var severity = rule.severity;
    var text = message;
    if (_depth > 0 && rule.severity != Severity.info) {
      severity = Severity.info;
      text =
          '$text This is inside a closure, so it stalls the test only if '
          'the test body awaits that closure.';
    }
    if (!sure && severity != Severity.info) {
      severity = Severity.info;
      text =
          '$text (Types were not resolved, so this is a guess by name; run '
          '`flutter pub get` for an exact result.)';
    }
    owner.hits.add(Hit(rule, severity, node.offset, text));
  }

  // --- structure -----------------------------------------------------------

  @override
  void visitFunctionExpression(FunctionExpression node) {
    if (_isRunAsyncArgument(node)) return; // Real async is allowed here.
    _depth++;
    super.visitFunctionExpression(node);
    _depth--;
  }

  @override
  void visitFunctionDeclarationStatement(FunctionDeclarationStatement node) {
    _depth++;
    super.visitFunctionDeclarationStatement(node);
    _depth--;
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    _awaited(node.expression);
    super.visitAwaitExpression(node);
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    // `return future;` in the async body waits for the future too.
    final expression = node.expression;
    if (_depth == 0 && expression != null && callback.body.isAsynchronous) {
      _awaited(expression);
    }
    super.visitReturnStatement(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _checkSleep(node);
    if (_depth == 0) _trackSettle(node);
    super.visitMethodInvocation(node);
  }

  // --- awaited expressions -------------------------------------------------

  void _awaited(Expression expression) {
    final e = _strip(expression);
    if (e is MethodInvocation) {
      final name = e.methodName.name;
      final target = e.realTarget;
      if (target != null &&
          _passThrough.contains(name) &&
          _maybeFuture(target)) {
        _awaited(target);
        return;
      }
      if ((name == 'wait' || name == 'any') && _isFutureClass(target)) {
        for (final argument in e.argumentList.arguments) {
          if (argument is ListLiteral) {
            for (final element in argument.elements) {
              if (element is Expression) _awaited(element);
            }
          }
        }
        return;
      }
    }
    _classify(e);
  }

  void _classify(Expression e) {
    if (_checkFakeDelay(e)) return;

    final element = _element(e);
    final name = _name(e);
    if (name == null) return;

    if (element == null) {
      if (!_resolved) _classifyByName(e, name);
      return;
    }

    final library = element.library?.uri.toString() ?? '';
    final owner = element.enclosingElement;
    final ownerName = owner is InterfaceElement ? owner.name : null;
    final receivePort = _receivePortName(e);
    final call = element is PropertyAccessorElement ? name : '$name()';
    final label = receivePort != null
        ? '$receivePort.$call'
        : ownerName == null
        ? call
        : '$ownerName.$call';

    if (library == 'dart:io' &&
        _returnsFuture(e) &&
        !_httpClasses.contains(ownerName)) {
      _hit(
        realIo,
        e,
        'Awaits $label from dart:io outside tester.runAsync; the result '
        'arrives on the real event loop and the test never resumes.',
      );
      return;
    }

    final flutter = library.startsWith('package:flutter/');
    if ((library == 'dart:isolate' && _returnsFuture(e)) ||
        (flutter && name == 'compute') ||
        _readsReceivePort(e)) {
      _hit(
        isolateHop,
        e,
        'Awaits $label, which waits for another isolate, outside '
        'tester.runAsync; the reply is never delivered.',
      );
      return;
    }

    if ((library == 'dart:ui' && _engineUi.contains(name)) ||
        (flutter && _engineFlutter.contains(name))) {
      _hit(
        engineAsync,
        e,
        'Awaits $label outside tester.runAsync; the engine never answers '
        'and the test isolate blocks.',
      );
      return;
    }

    if (flutter && name == 'loadString') {
      _hit(
        assetString,
        e,
        'Awaits $label; assets of 50 KB or more are decoded with compute() '
        'and stall outside tester.runAsync.',
      );
    }
  }

  /// `Future.delayed`, `Future(...)` and `pumpEventQueue()`.
  bool _checkFakeDelay(Expression e) {
    if (e is InstanceCreationExpression) {
      final constructor = e.constructorName;
      if (constructor.type.name.lexeme != 'Future') return false;
      final element = constructor.element;
      if (element != null && element.library.uri.toString() != 'dart:async') {
        return false;
      }
      final named = constructor.name?.name;
      if (named == 'delayed') {
        _hit(
          fakeDelay,
          e,
          'Awaits Future.delayed(...); its fake timer fires only when the '
          'test pumps, and the test is waiting instead of pumping.',
        );
        return true;
      }
      if (named == null) {
        _hit(
          fakeDelay,
          e,
          'Awaits Future(...), which runs its callback on a zero-length fake '
          'timer that fires only when the test pumps.',
        );
        return true;
      }
      return false;
    }
    if (e is MethodInvocation) {
      final name = e.methodName.name;
      final element = e.methodName.element;
      // Unresolved `Future.delayed(...)` parses as a method invocation.
      if (name == 'delayed' && element == null && _isFutureClass(e.target)) {
        _hit(
          fakeDelay,
          e,
          'Awaits Future.delayed(...); its fake timer fires only when the '
          'test pumps, and the test is waiting instead of pumping.',
        );
        return true;
      }
      if (name == 'pumpEventQueue' && e.target == null) {
        final library = element?.library?.uri.toString();
        if (library != null &&
            !library.startsWith('package:test_api/') &&
            !library.startsWith('package:test_core/') &&
            !library.startsWith('package:flutter_test/')) {
          return false;
        }
        _hit(
          fakeDelay,
          e,
          'Awaits pumpEventQueue(), which waits on zero-length fake timers '
          'that fire only when the test pumps.',
        );
        return true;
      }
    }
    return false;
  }

  /// Name-only guesses for a file analysed without types.
  void _classifyByName(Expression e, String name) {
    if (name == 'compute' || (name == 'run' && _isNamed(e, 'Isolate'))) {
      _hit(
        isolateHop,
        e,
        'Awaits $name(...), which looks like work on another isolate, '
        'outside tester.runAsync.',
        sure: false,
      );
    } else if (_engineUi.contains(name) || _engineFlutter.contains(name)) {
      _hit(
        engineAsync,
        e,
        'Awaits $name(...), which looks like engine image work, outside '
        'tester.runAsync.',
        sure: false,
      );
    }
  }

  // --- sleep ---------------------------------------------------------------

  void _checkSleep(MethodInvocation node) {
    if (node.methodName.name != 'sleep' || node.target != null) return;
    final element = node.methodName.element;
    if (element != null && element.library?.uri.toString() != 'dart:io') {
      return;
    }
    if (element == null && _resolved) return;
    _hit(
      blockingSleep,
      node,
      'Calls sleep(), which blocks the isolate without moving the fake '
      'clock.',
      sure: element != null,
    );
  }

  // --- pumpAndSettle with an indeterminate indicator -----------------------

  void _trackSettle(MethodInvocation node) {
    if (!_isTesterCall(node)) return;
    final name = node.methodName.name;
    if (name == 'pumpWidget') {
      final arguments = node.argumentList.arguments;
      final widget = arguments.isEmpty ? null : arguments.first;
      final finder = _IndicatorFinder();
      widget?.accept(finder);
      final found = finder.found;
      _indicator = found == null
          ? null
          : _PumpedIndicator(found, finder.offset, _statementOf(node));
      return;
    }
    if (name != 'pumpAndSettle') return;
    final pumped = _indicator;
    if (pumped == null) return;
    _indicator = null;
    final unit = node.root as CompilationUnit;
    final line = unit.lineInfo.getLocation(pumped.offset).lineNumber;
    final kind = pumped.name;
    final statement = _statementOf(node);
    final direct =
        pumped.statement != null &&
        statement != null &&
        _nextStatement(pumped.statement!) == statement;
    if (direct) {
      _hit(
        endlessSettle,
        node,
        'pumpAndSettle() right after pumping an indeterminate $kind (line '
        '$line); the indicator animates forever, so this never settles.',
      );
    } else {
      owner.hits.add(
        Hit(
          endlessSettle,
          Severity.info,
          node.offset,
          'pumpAndSettle() while the indeterminate $kind pumped on line $line '
          'may still be on screen; if it is, this never settles.',
        ),
      );
    }
  }

  bool _isTesterCall(MethodInvocation node) {
    final target = node.realTarget;
    if (target == null) return false;
    final type = target.staticType;
    if (type != null && type.element?.name == 'WidgetTester') return true;
    return target is SimpleIdentifier && target.name == testerName;
  }
}

class _PumpedIndicator {
  const _PumpedIndicator(this.name, this.offset, this.statement);

  final String name;
  final int offset;
  final Statement? statement;
}

/// Finds an indeterminate progress indicator that is always part of a
/// pumped widget tree.
///
/// Builders, conditionals and collection `if`s are skipped: what they produce
/// depends on state the checker cannot see.
class _IndicatorFinder extends RecursiveAstVisitor<void> {
  String? found;
  int offset = 0;

  @override
  void visitFunctionExpression(FunctionExpression node) {}

  @override
  void visitConditionalExpression(ConditionalExpression node) {}

  @override
  void visitIfElement(IfElement node) {}

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final constructor = node.constructorName;
    final element = constructor.element;
    final fromFlutter =
        element == null ||
        element.library.uri.toString().startsWith('package:flutter/');
    _consider(
      node,
      constructor.type.name.lexeme,
      constructor.name?.name,
      node.argumentList,
      fromFlutter,
    );
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    // Without types, `CircularProgressIndicator()` parses as a call.
    if (node.methodName.element == null) {
      final target = node.target;
      if (target == null) {
        _consider(node, node.methodName.name, null, node.argumentList, true);
      } else if (target is SimpleIdentifier) {
        _consider(
          node,
          target.name,
          node.methodName.name,
          node.argumentList,
          true,
        );
      }
    }
    super.visitMethodInvocation(node);
  }

  void _consider(
    AstNode node,
    String type,
    String? constructor,
    ArgumentList arguments,
    bool fromFlutter,
  ) {
    if (found != null || !fromFlutter || !_indicators.contains(type)) return;
    if (constructor == 'partiallyRevealed') return;
    Expression? argument(String name) {
      for (final a in arguments.arguments) {
        if (a is NamedArgument && a.name.lexeme == name) {
          return a.argumentExpression;
        }
      }
      return null;
    }

    final value = argument('value');
    if (value != null && value is! NullLiteral) return;
    final animating = argument('animating');
    if (animating is BooleanLiteral && !animating.value) return;
    found = type;
    offset = node.offset;
  }
}

// --- helpers ---------------------------------------------------------------

Expression _strip(Expression e) {
  var current = e;
  while (true) {
    if (current is ParenthesizedExpression) {
      current = current.expression;
    } else if (current is AsExpression) {
      current = current.expression;
    } else if (current is PostfixExpression && current.operator.lexeme == '!') {
      current = current.operand;
    } else {
      return current;
    }
  }
}

Element? _element(Expression e) => switch (e) {
  MethodInvocation(:final methodName) => methodName.element,
  PropertyAccess(:final propertyName) => propertyName.element,
  PrefixedIdentifier(:final identifier) => identifier.element,
  SimpleIdentifier() => e.element,
  _ => null,
};

String? _name(Expression e) => switch (e) {
  MethodInvocation(:final methodName) => methodName.name,
  PropertyAccess(:final propertyName) => propertyName.name,
  PrefixedIdentifier(:final identifier) => identifier.name,
  SimpleIdentifier(:final name) => name,
  _ => null,
};

bool _returnsFuture(Expression e) {
  final type = e.staticType;
  return type != null && (type.isDartAsyncFuture || type.isDartAsyncFutureOr);
}

bool _maybeFuture(Expression e) {
  final type = e.staticType;
  return type == null ||
      type.isDartAsyncFuture ||
      type.isDartAsyncFutureOr ||
      type is DynamicType;
}

bool _isFutureClass(Expression? target) =>
    target is SimpleIdentifier && target.name == 'Future';

bool _isNamed(Expression e, String targetName) =>
    e is MethodInvocation &&
    e.target is SimpleIdentifier &&
    (e.target! as SimpleIdentifier).name == targetName;

/// The class name when [e] reads a ReceivePort (`port.first`), else null.
String? _receivePortName(Expression e) {
  final Expression? target = switch (e) {
    PropertyAccess(:final realTarget) => realTarget,
    PrefixedIdentifier(:final prefix) => prefix,
    MethodInvocation(:final realTarget) => realTarget,
    _ => null,
  };
  final element = target?.staticType?.element;
  if (element == null || element.library?.uri.toString() != 'dart:isolate') {
    return null;
  }
  final name = element.name;
  return name == 'ReceivePort' || name == 'RawReceivePort' ? name : null;
}

/// `port.first` and similar awaited reads of a ReceivePort.
bool _readsReceivePort(Expression e) =>
    _receivePortName(e) != null && _returnsFuture(e);

bool _isRunAsyncArgument(FunctionExpression node) {
  var parent = node.parent;
  if (parent is NamedArgument) parent = parent.parent;
  if (parent is! ArgumentList) return false;
  final invocation = parent.parent;
  return invocation is MethodInvocation &&
      invocation.methodName.name == 'runAsync';
}

Statement? _statementOf(AstNode node) {
  AstNode? current = node;
  while (current != null && current is! Statement) {
    current = current.parent;
  }
  return current as Statement?;
}

Statement? _nextStatement(Statement statement) {
  final parent = statement.parent;
  if (parent is! Block) return null;
  final index = parent.statements.indexOf(statement);
  if (index < 0 || index + 1 >= parent.statements.length) return null;
  return parent.statements[index + 1];
}
