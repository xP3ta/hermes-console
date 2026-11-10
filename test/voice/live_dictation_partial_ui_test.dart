import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_dictation.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// The live text of a Hermes dictation, drawn where Desktop's dictation
/// pill shows it (`voice-activity.tsx:195-196`: the partial, else the
/// status). The wave stays underneath, dimmed, so the level still shows.
Widget _host(Widget child, ThemeData theme) => MaterialApp(
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  locale: const Locale('es'),
  theme: theme,
  home: Scaffold(
    body: Align(alignment: Alignment.bottomCenter, child: child),
  ),
);

class _Room extends RoomDictation {
  @override
  bool get recording => false;
  @override
  bool get transcribing => false;
  @override
  ValueListenable<double>? get level => null;
  @override
  Future<void> start({
    required String currentText,
    required ValueChanged<String> onText,
    required ValueChanged<RoomDictationFailure> onFailure,
  }) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> cancel() async {}
}

void main() {
  late TextEditingController controller;
  late FocusNode focusNode;
  late ValueNotifier<double> level;

  setUp(() {
    controller = TextEditingController();
    focusNode = FocusNode();
    level = ValueNotifier<double>(0.4);
  });

  tearDown(() {
    controller.dispose();
    focusNode.dispose();
    level.dispose();
  });

  Widget composer({
    String partial = '',
    bool transcribing = false,
    ThemeData? theme,
  }) => _host(
    ConsoleComposer(
      controller: controller,
      focusNode: focusNode,
      onSend: (_, _) {},
      onAttach: (_) {},
      dictation: ConsoleComposerDictation(
        recording: true,
        transcribing: transcribing,
        level: level,
        partial: partial,
        onStart: () {},
        onStop: () {},
        onCancel: () {},
        onSend: () {},
      ),
    ),
    theme ?? AppTheme.hermesRedDark,
  );

  const partialKey = ValueKey('dictation-partial');

  testWidgets('no partial: only the wave, as before', (tester) async {
    await tester.pumpWidget(composer());
    expect(find.byKey(partialKey), findsNothing);
    expect(find.byKey(const ValueKey('dictation-visualizer')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (name, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    testWidgets('the partial shows over a dimmed wave ($name theme)', (
      tester,
    ) async {
      await tester.pumpWidget(composer(partial: 'hola qué tal', theme: theme));
      expect(find.byKey(partialKey), findsOneWidget);
      expect(find.text('hola qué tal'), findsOneWidget);
      final colors = theme.hermes;
      final text = tester.widget<Text>(find.text('hola qué tal'));
      expect(text.style?.color, colors.textPrimary);
      expect(text.maxLines, 1);

      final wave = tester.widget<ConsoleDictationVisualizer>(
        find.byKey(const ValueKey('dictation-visualizer')),
      );
      expect(wave.color, isNot(colors.textSecondary));
      expect(wave.color.a, lessThan(colors.textSecondary.a));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('the partial stays while the final is on its way', (
    tester,
  ) async {
    await tester.pumpWidget(composer(partial: 'hola', transcribing: true));
    expect(find.text('hola'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a long partial at 2x text on a 320dp phone shows its end '
      'without overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    const long =
        'esto es un dictado muy largo que no cabe en la fila del composer '
        'y sigue y sigue hasta la última palabra';
    await tester.pumpWidget(composer(partial: long));
    expect(tester.takeException(), isNull);

    final area = tester.getRect(
      find.byKey(const ValueKey('dictation-recording-area')),
    );
    final text = tester.getRect(find.text(long));
    // The newest words are the visible ones: the text ends at the area's end.
    expect(text.right, moreOrLessEquals(area.right, epsilon: 1));
    expect(text.left, lessThan(area.left));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the partial is readable by a screen reader', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(composer(partial: 'hola'));
    expect(find.bySemanticsLabel('hola'), findsOneWidget);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('a room dictation has no live text unless it says so', () {
    final room = _Room();
    addTearDown(room.dispose);
    expect(room.partial, '');
  });
}
