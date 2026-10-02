// Visual evidence that the backdrop-blur policy keeps the look at rest.
// Renders the room summary pill above a transcript and the glass dock over a
// list at 412×915, Spanish, dark; writes PNGs only when BLUR_SHOTS_DIR is set
// (otherwise a layout smoke test). Fixtures are synthetic.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/room_summary.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/dock.dart';
import 'package:hermes_android/core/widgets/room_summary_pill.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'room_member_status_test.dart' show statusEvent, statusRoom, statusNow;
import 'support/design_shots.dart' show loadDesignFonts;

const _shotKey = ValueKey('blur-shot');

Future<void> _pump(WidgetTester tester, Widget body) async {
  await loadDesignFonts();
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: Scaffold(body: SafeArea(child: body)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester, String name) async {
  final dir = Platform.environment['BLUR_SHOTS_DIR'];
  if (dir == null || dir.isEmpty) return;
  final boundary =
      tester.renderObject(find.byKey(_shotKey)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Widget _rows(int count) => ListView(
  padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
  children: [
    for (var i = 0; i < count; i++)
      Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: i.isEven ? const Color(0xFF2A1A1A) : const Color(0xFF1E2430),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          'Mensaje $i: revisa el despliegue y confirma los registros',
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
      ),
  ],
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('room summary pill at rest above the transcript', (tester) async {
    final summary = deriveRoomSummary(
      events: [
        statusEvent(1, 'message.user', text: '@forja revisa la release'),
        for (var i = 2; i < 6; i++)
          statusEvent(
            i,
            'turn.settled',
            payload: {'task_id': 'task-$i', 'passed': true},
          ),
      ],
      members: statusRoom.members,
      localGatewayId: 'gateway',
      now: statusNow,
    );
    await _pump(
      tester,
      Column(
        children: [
          RoomSummaryPill(summary: summary, localGatewayId: 'gateway'),
          Expanded(child: _rows(20)),
        ],
      ),
    );
    expect(find.byKey(const ValueKey('room-summary-pill')), findsOneWidget);
    await _save(tester, 'room_pill_rest');
  });

  testWidgets('glass dock at rest over a list', (tester) async {
    final controller = DockPreferencesController.instance;
    final before = controller.value.general;
    await controller.updateGeneral(
      (p) => p.copyWith(style: p.style.copyWith(transparency: 0.6)),
      persist: false,
    );
    addTearDown(() => controller.updateGeneral((_) => before, persist: false));
    await _pump(
      tester,
      Stack(
        fit: StackFit.expand,
        children: [
          _rows(20),
          Dock(
            profileId: DockProfileId.general,
            bottomInset: 12,
            actions: {
              DockItemId.home: const DockItemAction(selected: true),
              DockItemId.create: DockItemAction(onTap: () {}),
              DockItemId.bots: DockItemAction(onTap: () {}),
              DockItemId.settings: DockItemAction(onTap: () {}),
            },
          ),
        ],
      ),
    );
    expect(
      find.byKey(const ValueKey('general-mode-floating-dock')),
      findsOneWidget,
    );
    await _save(tester, 'dock_glass_rest');
  });
}
