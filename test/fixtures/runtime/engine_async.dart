// Run by test/runtime/watchdog_e2e_test.dart in its own `flutter test`
// process. The first two tests await engine image work outside
// tester.runAsync, the shape of flutter/flutter#50783, and are meant to fail
// through the watchdog.
//
// The engine call does not block the isolate: the bytes arrive and the
// body goes on. But they arrive on the real event loop, outside the
// FakeAsync zone, so the next microtask the test schedules in that zone is
// never run. If the body awaits again (here: a pump), the body stops there.
// If the engine call was its last await, the body returns and flutter_test's
// own code after it never runs, so the test never finishes.
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:tarpit/flutter_test.dart';

void main() {
  Tarpit.stallAfter = const Duration(milliseconds: 500);

  testWidgets('awaits toByteData as its last step', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: const ColoredBox(color: Color(0xFF00FF00)),
      ),
    );
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    print('engine bytes: ${bytes!.lengthInBytes}');
  });

  testWidgets('awaits toByteData, then pumps', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 1, 1), Paint());
    final image = recorder.endRecording().toImageSync(1, 1);
    final bytes = await image.toByteData();
    print('engine bytes: ${bytes!.lengthInBytes}');
    await tester.pump();
  });

  testWidgets('runs after the stalls', (tester) async {
    await tester.pump(const Duration(seconds: 1));
  });
}
