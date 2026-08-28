import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/attachment_source_sheet.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/core/widgets/home_prompt_composer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  testWidgets('es un campo real y no envía contenido vacío', (tester) async {
    String? submitted;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          body: HomePromptComposer(
            hintText: 'Pregunta a Hermes…',
            attachmentTooltip: 'Adjuntar archivo',
            dictationTooltip: 'Dictar',
            voiceTooltip: 'Conversación de voz',
            sendTooltip: 'Enviar',
            onAttachmentSelected: (_) {},
            onDictationPressed: () {},
            onVoicePressed: () {},
            onSubmitted: (value) => submitted = value,
          ),
        ),
      ),
    );

    expect(find.byType(TextField), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration?.filled, isFalse);
    expect(field.decoration?.focusedBorder, InputBorder.none);
    final send = find.byKey(const ValueKey('home-prompt-send'));
    expect(tester.widget<HermesTactileAction>(send).onPressed, isNotNull);
    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(tester.widget<HermesTactileAction>(send).onPressed, isNotNull);
    expect(submitted, isNull);
  });

  testWidgets('normaliza, envía una vez y limpia el campo', (tester) async {
    final submitted = <String>[];
    var wasEmptyInsideCallback = false;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          body: HomePromptComposer(
            hintText: 'Pregunta a Hermes…',
            attachmentTooltip: 'Adjuntar archivo',
            dictationTooltip: 'Dictar',
            voiceTooltip: 'Conversación de voz',
            sendTooltip: 'Enviar',
            onAttachmentSelected: (_) {},
            onDictationPressed: () {},
            onVoicePressed: () {},
            onSubmitted: (value) {
              wasEmptyInsideCallback =
                  tester
                      .widget<TextField>(find.byType(TextField))
                      .controller
                      ?.text
                      .isEmpty ??
                  false;
              submitted.add(value);
            },
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byType(TextField),
      '  dame las noticias de hoy  ',
    );
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.textInputAction, TextInputAction.newline);
    expect(field.keyboardType, TextInputType.multiline);

    final send = find.byKey(const ValueKey('home-prompt-send'));
    expect(tester.widget<HermesTactileAction>(send).onPressed, isNotNull);
    expect(tester.getSize(send), const Size(48, 48));

    await tester.tap(send);
    await tester.pump();

    expect(submitted, ['dame las noticias de hoy']);
    expect(wasEmptyInsideCallback, isTrue);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
  });

  testWidgets('Enter inserta nueva línea y Ctrl+Enter envía', (tester) async {
    final submitted = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          body: HomePromptComposer(
            hintText: 'Pregunta a Hermes…',
            attachmentTooltip: 'Adjuntar archivo',
            dictationTooltip: 'Dictar',
            voiceTooltip: 'Conversación de voz',
            sendTooltip: 'Enviar',
            onAttachmentSelected: (_) {},
            onDictationPressed: () {},
            onVoicePressed: () {},
            onSubmitted: submitted.add,
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'línea 1');
    await tester.pump();

    // El campo es multiline con acción newline: no hay onSubmitted que envíe.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.textInputAction, TextInputAction.newline);
    expect(field.onSubmitted, isNull);

    // Un texto con newline real se conserva (no dispara envío).
    await tester.enterText(find.byType(TextField), 'línea 1\nlínea 2');
    await tester.pump();
    expect(submitted, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'línea 1\nlínea 2',
    );

    // Ctrl+Enter envía desde teclado físico.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump();

    expect(submitted, isNotEmpty);
  });

  testWidgets('la acción contextual cambia de voz a enviar', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          body: HomePromptComposer(
            hintText: 'Pregunta a Hermes…',
            attachmentTooltip: 'Adjuntar archivo',
            dictationTooltip: 'Dictar',
            voiceTooltip: 'Conversación de voz',
            sendTooltip: 'Enviar',
            onAttachmentSelected: (_) {},
            onDictationPressed: () {},
            onVoicePressed: () {},
            onSubmitted: (_) {},
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'hola');
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
    expect(find.byIcon(Icons.graphic_eq_rounded), findsNothing);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
  });

  testWidgets('el botón + expone un adjunto real con target de 48 dp', (
    tester,
  ) async {
    final selected = <AttachmentSourceChoice>[];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          body: HomePromptComposer(
            hintText: 'Pregunta a Hermes…',
            attachmentTooltip: 'Adjuntar archivo',
            dictationTooltip: 'Dictar',
            voiceTooltip: 'Conversación de voz',
            sendTooltip: 'Enviar',
            onAttachmentSelected: selected.add,
            onDictationPressed: () {},
            onVoicePressed: () {},
            onSubmitted: (_) {},
          ),
        ),
      ),
    );

    final attach = find.byKey(const ValueKey('home-prompt-attach'));
    expect(tester.getSize(attach), const Size(48, 48));
    await tester.tap(attach);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNWidgets(3));
    await tester.tap(find.text('Galería'));
    await tester.pumpAndSettle();
    expect(selected, [AttachmentSourceChoice.photos]);
  });

  testWidgets('el estado disabled impide editar y enviar', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          body: HomePromptComposer(
            hintText: 'Pregunta a Hermes…',
            attachmentTooltip: 'Adjuntar archivo',
            dictationTooltip: 'Dictar',
            voiceTooltip: 'Conversación de voz',
            sendTooltip: 'Enviar',
            enabled: false,
            onAttachmentSelected: (_) => calls++,
            onDictationPressed: () => calls++,
            onVoicePressed: () => calls++,
            onSubmitted: (_) => calls++,
          ),
        ),
      ),
    );

    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(
      tester
          .widget<HermesTactileAction>(
            find.byKey(const ValueKey('home-prompt-send')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<AttachmentSourceMenuButton>(
            find.byKey(const ValueKey('home-prompt-attach')),
          )
          .enabled,
      isFalse,
    );
    expect(calls, 0);
  });

  testWidgets('el foco ensancha la cápsula sin perder texto ni foco', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          body: HomePromptComposer(
            hintText: 'Pregunta a Hermes…',
            attachmentTooltip: 'Adjuntar archivo',
            dictationTooltip: 'Dictar',
            voiceTooltip: 'Conversación de voz',
            sendTooltip: 'Enviar',
            onAttachmentSelected: (_) {},
            onDictationPressed: () {},
            onVoicePressed: () {},
            onSubmitted: (_) {},
          ),
        ),
      ),
    );

    const surfaceKey = ValueKey('hermes-composer-visible-surface');
    final surface = find.byKey(surfaceKey);
    final resting = tester.getRect(surface);

    await tester.enterText(find.byType(TextField), 'texto conservado');
    await tester.pumpAndSettle();

    final focused = tester.getRect(surface);
    expect(focused.width, greaterThan(resting.width));
    expect(focused.width - resting.width, greaterThanOrEqualTo(20));
    expect(focused.left, lessThan(resting.left));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'texto conservado',
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
    );
  });

  testWidgets(
    'viewport estrecho, texto ampliado y Reduce Motion conservan el layout',
    (tester) async {
      tester.view.physicalSize = const Size(280, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: true,
              textScaler: const TextScaler.linear(2),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: HomePromptComposer(
              hintText: 'Pregunta a Hermes…',
              attachmentTooltip: 'Adjuntar archivo',
              dictationTooltip: 'Dictar',
              voiceTooltip: 'Conversación de voz',
              sendTooltip: 'Enviar',
              onAttachmentSelected: (_) {},
              onDictationPressed: () {},
              onVoicePressed: () {},
              onSubmitted: (_) {},
            ),
          ),
        ),
      );

      final surface = find.byKey(
        const ValueKey('hermes-composer-visible-surface'),
      );
      final resting = tester.getRect(surface);
      final animatedPadding = tester.widget<AnimatedPadding>(
        find.descendant(
          of: find.byType(HermesComposerSurface),
          matching: find.byType(AnimatedPadding),
        ),
      );
      expect(animatedPadding.duration, Duration.zero);
      expect(tester.widget<AnimatedContainer>(surface).duration, Duration.zero);

      await tester.enterText(find.byType(TextField), 'hola');
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(tester.getRect(surface).width, greaterThan(resting.width));
      expect(tester.getRect(surface).right, lessThanOrEqualTo(280));
      expect(
        tester.getSize(find.byKey(const ValueKey('home-prompt-attach'))),
        const Size(48, 48),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('home-prompt-dictation'))),
        const Size(48, 48),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('home-prompt-send'))),
        const Size(48, 48),
      );
    },
  );
}
