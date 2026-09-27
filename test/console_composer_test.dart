import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/attachment_source_sheet.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  locale: const Locale('es'),
  theme: AppTheme.hermesRedDark,
  home: Scaffold(
    body: Align(alignment: Alignment.bottomCenter, child: child),
  ),
);

void main() {
  late TextEditingController controller;
  late FocusNode focusNode;

  setUp(() {
    controller = TextEditingController();
    focusNode = FocusNode();
  });

  tearDown(() {
    controller.dispose();
    focusNode.dispose();
  });

  ConsoleComposerDictation dictation({
    bool recording = false,
    VoidCallback? onStart,
    ValueListenable<double>? level,
  }) => ConsoleComposerDictation(
    recording: recording,
    level: level,
    onStart: onStart ?? () {},
    onStop: () {},
    onCancel: () {},
    onSend: () {},
  );

  testWidgets('envía el texto y los adjuntos por onSend', (tester) async {
    String? sentText;
    List<AttachmentDraft>? sentAttachments;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => ConsoleComposer(
            controller: controller,
            focusNode: focusNode,
            onAttach: (_) {},
            dictation: dictation(),
            sendEnabled: true,
            onSend: (text, attachments) {
              sentText = text;
              sentAttachments = attachments;
            },
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('composer-add')), findsOneWidget);
    expect(find.byKey(const ValueKey('mic')), findsOneWidget);
    expect(find.byKey(const ValueKey('send')), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'hola sala');
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('send')),
        matching: find.byType(ConsoleSendButton),
      ),
    );
    await tester.pump();
    expect(sentText, 'hola sala');
    expect(sentAttachments, isEmpty);
  });

  testWidgets('el campo crece con el texto hasta cuatro líneas', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ConsoleComposer(
          controller: controller,
          focusNode: focusNode,
          onSend: (_, _) {},
        ),
      ),
    );
    final row = find.byKey(const ValueKey('composer-input-row'));
    final before = tester.getSize(row).height;
    await tester.enterText(find.byType(TextField), 'uno\ndos\ntres');
    await tester.pump();
    expect(tester.getSize(row).height, greaterThan(before));
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.minLines, 1);
    expect(field.maxLines, 4);
  });

  testWidgets('stop sustituye a enviar y llama a onStop', (tester) async {
    var stopped = 0;
    await tester.pumpWidget(
      _host(
        ConsoleComposer(
          controller: controller,
          focusNode: focusNode,
          onSend: (_, _) {},
          showStop: true,
          onStop: () => stopped++,
        ),
      ),
    );
    expect(find.byKey(const ValueKey('stop')), findsOneWidget);
    expect(find.byKey(const ValueKey('send')), findsNothing);
    await tester.tap(find.byType(ConsoleSendButton));
    await tester.pump();
    expect(stopped, 1);
  });

  testWidgets('showBotModeToggle=false oculta modo voz y pastilla de modo', (
    tester,
  ) async {
    Widget build(bool show) => _host(
      ConsoleComposer(
        controller: controller,
        focusNode: focusNode,
        onSend: (_, _) {},
        showBotModeToggle: show,
        voiceModeAction: const SizedBox(key: ValueKey('voice-mode-launch')),
        footer: const SizedBox(key: ValueKey('mode-pill')),
      ),
    );
    await tester.pumpWidget(build(true));
    expect(find.byKey(const ValueKey('voice-mode-launch')), findsOneWidget);
    expect(find.byKey(const ValueKey('mode-pill')), findsOneWidget);

    await tester.pumpWidget(build(false));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice-mode-launch')), findsNothing);
    expect(find.byKey(const ValueKey('mode-pill')), findsNothing);
    expect(find.byKey(const ValueKey('send')), findsOneWidget);
  });

  testWidgets('sin onAttach ni dictado no hay + ni micrófono', (tester) async {
    await tester.pumpWidget(
      _host(
        ConsoleComposer(
          controller: controller,
          focusNode: focusNode,
          onSend: (_, _) {},
        ),
      ),
    );
    expect(find.byType(AttachmentSourceMenuButton), findsNothing);
    expect(find.byKey(const ValueKey('mic')), findsNothing);
  });

  testWidgets('el micrófono arranca el dictado y grabando muestra la onda', (
    tester,
  ) async {
    var started = 0;
    await tester.pumpWidget(
      _host(
        ConsoleComposer(
          controller: controller,
          focusNode: focusNode,
          onSend: (_, _) {},
          dictation: dictation(onStart: () => started++),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('mic')));
    await tester.pump();
    expect(started, 1);

    final level = ValueNotifier<double>(0.4);
    addTearDown(level.dispose);
    await tester.pumpWidget(
      _host(
        ConsoleComposer(
          controller: controller,
          focusNode: focusNode,
          onSend: (_, _) {},
          onAttach: (_) {},
          dictation: dictation(recording: true, level: level),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('dictation-visualizer')), findsOneWidget);
    expect(find.byKey(const ValueKey('dictation-cancel')), findsOneWidget);
    expect(find.byKey(const ValueKey('dictation-send')), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-add')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
