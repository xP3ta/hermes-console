import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// The select of a form or of a row: it shows the value and opens the shared
/// options surface, like every other choice in the app.
void main() {
  const surface = ValueKey('hermes-option-surface');
  const field = ValueKey('field');

  Widget app({
    required String? value,
    required ValueChanged<String>? onChanged,
    bool inline = false,
    String? hint,
  }) => MaterialApp(
    theme: AppTheme.fromId('classic-dark'),
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Align(
          alignment: Alignment.topLeft,
          child: HermesSelectField<String>(
            key: field,
            value: value,
            inline: inline,
            hint: hint,
            decoration: inline
                ? null
                : const InputDecoration(labelText: 'Entrega'),
            title: 'Entrega',
            options: const [
              HermesOption(value: 'log', label: 'Solo registro'),
              HermesOption(value: 'chat', label: 'Al chat'),
              HermesOption(value: 'mail', label: 'Por correo'),
            ],
            onChanged: onChanged,
          ),
        ),
      ),
    ),
  );

  for (final inline in const [false, true]) {
    testWidgets('${inline ? 'inline' : 'field'}: shows the value, opens the '
        'shared options surface and reports the choice', (tester) async {
      final chosen = <String>[];
      await tester.pumpWidget(
        app(value: 'chat', onChanged: chosen.add, inline: inline),
      );
      expect(find.text('Al chat'), findsOneWidget);
      expect(find.byKey(surface), findsNothing);
      expect(
        tester.getSize(find.byKey(field)).height,
        greaterThanOrEqualTo(48),
      );

      await tester.tap(find.byKey(field));
      await tester.pumpAndSettle();
      expect(find.byKey(surface), findsOneWidget);
      // The sheet's scrim, the floating tone: the shared surface.
      final barriers = tester.widgetList<ModalBarrier>(
        find.byType(ModalBarrier),
      );
      expect(
        barriers.map((b) => b.color?.a).whereType<double>(),
        contains(closeTo(HermesChrome.scrimSheet, 0.005)),
      );
      // Every option is offered; the one in force is there too.
      for (final label in const ['Solo registro', 'Al chat', 'Por correo']) {
        expect(
          find.descendant(of: find.byKey(surface), matching: find.text(label)),
          findsOneWidget,
        );
      }

      await tester.tap(find.text('Por correo'));
      await tester.pumpAndSettle();
      expect(chosen, ['mail']);
      expect(find.byKey(surface), findsNothing);
    });
  }

  testWidgets('closed without choosing, nothing is reported', (tester) async {
    final chosen = <String>[];
    await tester.pumpWidget(app(value: 'chat', onChanged: chosen.add));
    await tester.tap(find.byKey(field));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byKey(surface), findsNothing);
    expect(chosen, isEmpty);
  });

  testWidgets('with no onChanged it is disabled and does not open', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(app(value: 'chat', onChanged: null));
    await tester.tap(find.byKey(field), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byKey(surface), findsNothing);
    final node = tester.getSemantics(find.byKey(field));
    expect(node.label, 'Entrega');
    expect(node.value, 'Al chat');
    expect(node.flagsCollection.isButton, isTrue);
    handle.dispose();
  });

  testWidgets('a screen reader gets the name, the value and a tap', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final chosen = <String>[];
    await tester.pumpWidget(app(value: null, onChanged: chosen.add, hint: '—'));
    final node = tester.getSemantics(find.byKey(field));
    expect(node.label, 'Entrega');
    expect(node.value, '—');
    tester.semantics.tap(find.semantics.byLabel('Entrega'));
    await tester.pumpAndSettle();
    expect(find.byKey(surface), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the keyboard reaches it and opens it', (tester) async {
    await tester.pumpWidget(app(value: 'chat', onChanged: (_) {}));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(surface), findsOneWidget);
  });
}
