// Visual evidence for the «Guardado en memoria» marker. Renders the real
// activity header at 412×915, Spanish, dark and light; writes PNGs only when
// MP1215_SHOTS_DIR is set (otherwise a layout smoke test). Fixtures are
// synthetic.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/core/widgets/message_avatar_header.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/design_shots.dart' show loadDesignFonts;

const _shotKey = ValueKey('mp1215-shot');
const _ok = {'success': true, 'done': true, 'entry_count': 5};

ChatTraceEvent _tool(String id, String label, Map<String, Object?> args) =>
    ChatTraceEvent(
      id: id,
      label: label,
      status: 'completed',
      detail: activityToolDetail(label, args),
      duration: const Duration(milliseconds: 900),
      memory: MemoryWrite.fromArgs(label, args) == null
          ? null
          : MemoryWrite.settle(MemoryWrite.fromArgs(label, args), _ok),
    );

Widget _block(List<ChatTraceEvent> events, String answer) => Builder(
  builder: (context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ThinkingTraceCard(
        events: events,
        active: false,
        liveInPill: true,
        duration: const Duration(seconds: 14),
        headerBuilder: (context, summary, details) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MessageAvatarHeader(
              name: 'Hermes',
              subtitle: summary,
              actions: [
                for (final icon in [Icons.copy_rounded, Icons.refresh_rounded])
                  SizedBox.square(dimension: 48, child: Icon(icon, size: 16)),
              ],
            ),
            details,
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(left: 50, top: 6),
        child: Text(
          answer,
          style: TextStyle(
            fontSize: 15,
            height: 1.4,
            color: Theme.of(context).hermes.textPrimary,
          ),
        ),
      ),
    ],
  ),
);

Widget _user(BuildContext context, String text) {
  final colors = Theme.of(context).hermes;
  return Align(
    alignment: Alignment.centerRight,
    child: Container(
      margin: const EdgeInsets.only(left: 60, bottom: 18),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(text, style: TextStyle(color: colors.textPrimary)),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  ThemeData theme,
  List<Widget> Function(BuildContext) transcript,
) async {
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
        theme: theme,
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: Scaffold(
              body: SafeArea(
                child: Column(
                  children: [
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(12, 16, 16, 16),
                        children: transcript(context),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
                      child: HermesComposerSurface(
                        child: SizedBox(
                          height: 52,
                          child: Row(
                            children: [
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  'Escribe un mensaje…',
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).hermes.textSecondary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _save(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull);
  final dir = Platform.environment['MP1215_SHOTS_DIR'];
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

void main() {
  for (final (themeName, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    testWidgets('$themeName: memory writes in the chat', (tester) async {
      await _pump(
        tester,
        theme,
        (context) => [
          _user(
            context,
            'Recuerda que vivo en Lisboa y prefiero respuestas '
            'cortas.',
          ),
          _block([
            _tool('1', 'memory', {
              'action': 'add',
              'target': 'user',
              'content':
                  'Vive en Lisboa (hora WEST). Prefiere respuestas '
                  'cortas y directas, sin relleno; si algo no está claro, '
                  'que se lo diga sin rodeos.',
            }),
          ], 'Hecho, lo tendré en cuenta.'),
          const SizedBox(height: 22),
          _user(context, 'Ya no uso Flutter 3.35, quita esa nota.'),
          _block([
            _tool('2', 'read_file', {'path': 'pubspec.yaml'}),
            _tool('3', 'memory', {
              'action': 'replace',
              'old_text': 'Flutter 3.35',
              'content': 'El proyecto usa Flutter 3.38.',
            }),
            _tool('4', 'memory', {
              'action': 'remove',
              'old_text': 'Usa el canal beta de Flutter.',
            }),
          ], 'Actualizado.'),
          const SizedBox(height: 22),
          _block([
            _tool('5', 'terminal', {'command': 'git status'}),
            _tool('6', 'memory', {
              'action': 'add',
              'content': 'Las capturas de prueba van a scratch/memorypill.',
            }),
          ], 'Listo.'),
        ],
      );
      expect(find.byKey(const ValueKey('memory-saved-marker')), findsWidgets);
      await _save(tester, 'memory-markers-$themeName');
      // Expanded preview of the first write.
      await tester.tap(find.byKey(const ValueKey('memory-saved-marker')).first);
      await tester.pump(const Duration(milliseconds: 300));
      await _save(tester, 'memory-markers-expanded-$themeName');
    });
  }
}
