import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/inline_message_editor.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final brightness in [Brightness.light, Brightness.dark]) {
    for (final locale in const [Locale('es'), Locale('en')]) {
      testWidgets(
        'inline editor fits 320dp at 2x in ${brightness.name} ${locale.languageCode}',
        (tester) async {
          tester.view
            ..physicalSize = const Size(320, 640)
            ..devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          String? saved;
          var cancelled = false;

          await tester.pumpWidget(
            MaterialApp(
              locale: locale,
              localizationsDelegates: Strings.localizationsDelegates,
              supportedLocales: Strings.supportedLocales,
              theme: brightness == Brightness.light
                  ? AppTheme.hermesRedLight
                  : AppTheme.hermesRedDark,
              home: MediaQuery(
                data: const MediaQueryData(
                  size: Size(320, 640),
                  textScaler: TextScaler.linear(2),
                  disableAnimations: true,
                ),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: brightness == Brightness.light
                              ? Colors.grey.shade200
                              : Colors.grey.shade900,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: InlineMessageEditor(
                            initialText: 'Texto original',
                            onCancel: () => cancelled = true,
                            onSave: (value) => saved = value,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          final field = find.byKey(
            const ValueKey('inline-message-editor-field'),
          );
          expect(field, findsOneWidget);
          final editable = tester.widget<EditableText>(
            find.descendant(of: field, matching: find.byType(EditableText)),
          );
          expect(
            editable.controller.selection.baseOffset,
            'Texto original'.length,
          );
          expect(tester.takeException(), isNull);

          final saveButton = find.byKey(
            const ValueKey('inline-message-editor-save'),
          );
          expect(tester.widget<IconButton>(saveButton).onPressed, isNull);
          expect(
            find.byTooltip(
              locale.languageCode == 'es'
                  ? 'Guardar y reenviar'
                  : 'Save and resend',
            ),
            findsOneWidget,
          );
          final expectedSaveLabel = locale.languageCode == 'es'
              ? 'Guardar y reenviar'
              : 'Save and resend';
          final expectedCancelLabel = locale.languageCode == 'es'
              ? 'Cancelar edición'
              : 'Cancel edit';
          expect(find.byTooltip(expectedCancelLabel), findsOneWidget);
          final semantics = tester.ensureSemantics();
          expect(find.bySemanticsLabel(expectedSaveLabel), findsOneWidget);
          expect(find.bySemanticsLabel(expectedCancelLabel), findsOneWidget);
          semantics.dispose();

          await tester.enterText(field, 'Texto corregido');
          await tester.pump();
          expect(tester.widget<IconButton>(saveButton).onPressed, isNotNull);
          // El campo ya es de una línea (alto = contenido): el asa de
          // selección del caret cae sobre el pie; se suelta el foco para pulsar.
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pump();
          await tester.tap(saveButton);
          expect(saved, 'Texto corregido');
          expect(cancelled, isFalse);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  Widget host({required String text, ThemeData? theme, double width = 360}) =>
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: theme ?? AppTheme.hermesRedDark,
        home: MediaQuery(
          data: MediaQueryData(size: Size(width, 800), disableAnimations: true),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: SizedBox(
                width: width - 60,
                child: DecoratedBox(
                  key: const ValueKey('bubble'),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade800,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 11,
                    ),
                    child: InlineMessageEditor(
                      initialText: text,
                      onCancel: () {},
                      onSave: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('sin relleno ni borde y con el alto del contenido', (
    tester,
  ) async {
    for (final theme in [AppTheme.hermesRedDark, AppTheme.hermesRedLight]) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(host(text: 'dos palabras', theme: theme));
      await tester.pump();
      final field = find.byKey(const ValueKey('inline-message-editor-field'));
      final decoration = tester.widget<TextField>(field).decoration!;
      expect(decoration.filled, isFalse);
      expect(decoration.contentPadding, EdgeInsets.zero);
      expect(decoration.border, InputBorder.none);
      expect(decoration.focusedBorder, InputBorder.none);
      // Arranca con espacio para varias líneas (no una caja diminuta), aunque
      // el texto original sea corto: minLines es 3, no 1.
      final threeLines = tester.getSize(field).height;
      final oneLine = threeLines / 3;
      // Más texto crece con el contenido…
      await tester.enterText(field, List.filled(6, 'línea').join('\n'));
      await tester.pump();
      final six = tester.getSize(field).height;
      expect(six, closeTo(oneLine * 6, oneLine));
      // …hasta ~10 líneas, a partir de ahí desplaza.
      await tester.enterText(field, List.filled(20, 'línea').join('\n'));
      await tester.pump();
      final capped = tester.getSize(field).height;
      expect(capped, lessThanOrEqualTo(oneLine * 10 + 2));
      expect(capped, greaterThan(oneLine * 8));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('pie compacto pegado abajo a la derecha, sin banda vacía', (
    tester,
  ) async {
    await tester.pumpWidget(host(text: 'dos palabras'));
    await tester.pump();
    final bubble = tester.getRect(find.byKey(const ValueKey('bubble')));
    final save = tester.getRect(
      find.byKey(const ValueKey('inline-message-editor-save')),
    );
    final cancel = tester.getRect(
      find.byKey(const ValueKey('inline-message-editor-cancel')),
    );
    expect(save.size.width, lessThanOrEqualTo(40));
    expect(cancel.size.height, lessThanOrEqualTo(40));
    // A la derecha del contenido y con la burbuja acabando justo debajo
    // (padding inferior de la burbuja, sin más).
    expect(bubble.right - 16, closeTo(save.right, 1));
    expect(bubble.bottom - save.bottom, lessThanOrEqualTo(12));
    expect(cancel.right, lessThan(save.left));
  });
}
