// The shared confirmation (showHermesConfirmDialog, ~119 call sites)
// overflowed already at the default text size in es/de/fr/pt/it on narrow
// phones and on the Fold cover (text size sweep, run green3), and with
// Android's own text scale on most phones. Fix kept from the text size work
// (review: «mantener arreglo diálogo con pruebas»): the content scrolls,
// the buttons stack only when they do not fit side by side, and the pills
// keep their own width when stacked.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/inter_font.dart';

const _cancel = ValueKey('hermes-confirm-dialog-cancel');
const _confirm = ValueKey('hermes-confirm-dialog-confirm');

Future<List<String>> _open(
  WidgetTester tester, {
  required Size size,
  double textScale = 1.1,
  String title = '¿Cancelar la espera de la sala?',
  String message = 'Los miembros que ya respondieron conservan su respuesta.',
  // The real labels of room_screen.dart:1205 in Spanish.
  String cancelLabel = 'Seguir esperando',
  String confirmLabel = 'Cancelar espera',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('open'),
              onPressed: () => showHermesConfirmDialog(
                context: context,
                title: title,
                message: message,
                confirmLabel: confirmLabel,
                cancelLabel: cancelLabel,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
  // A layout overflow is reported to the test binding; collect it here so
  // the test states it (null when the dialog laid out cleanly).
  final error = tester.takeException();
  return [if (error != null) '$error'];
}

bool _overflowed(List<String> errors) =>
    errors.any((e) => e.contains('overflowed'));

Rect _rect(WidgetTester tester, Key key) => tester.getRect(find.byKey(key));

void main() {
  setUpAll(loadInterFont);

  testWidgets('[RED] Fold cover (344 dp), Spanish, default size: no '
      'overflow, both buttons inside the dialog and tappable', (tester) async {
    final errors = await _open(tester, size: const Size(344, 882));
    expect(_overflowed(errors), isFalse, reason: '$errors');
    final dialog = tester.getRect(
      find.byKey(const ValueKey('hermes-confirm-dialog')),
    );
    for (final key in [_cancel, _confirm]) {
      final r = _rect(tester, key);
      expect(dialog.contains(r.topLeft) && dialog.contains(r.bottomRight - const Offset(0.1, 0.1)), isTrue,
          reason: '$key $r outside $dialog');
    }
    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hermes-confirm-dialog')), findsNothing);
  });

  testWidgets('[RED] buttons that do not fit side by side stack, confirm '
      'last, each pill as wide as its label', (tester) async {
    final errors = await _open(
      tester,
      size: const Size(360, 640),
      textScale: 1.65,
    );
    expect(_overflowed(errors), isFalse, reason: '$errors');
    final cancel = _rect(tester, _cancel);
    final confirm = _rect(tester, _confirm);
    expect(confirm.top, greaterThan(cancel.top), reason: 'stacked');
    final dialog = tester.getRect(
      find.byKey(const ValueKey('hermes-confirm-dialog')),
    );
    expect(confirm.width, lessThan(dialog.width - 40), reason: 'not stretched');
    expect(confirm.right, closeTo(cancel.right, 0.5), reason: 'end-aligned');
  });

  testWidgets('[CONTROL] when they fit, the buttons stay on one row as '
      'before', (tester) async {
    final errors = await _open(
      tester,
      size: const Size(800, 1280),
      cancelLabel: 'No',
      confirmLabel: 'Sí',
    );
    expect(_overflowed(errors), isFalse, reason: '$errors');
    final cancel = _rect(tester, _cancel);
    final confirm = _rect(tester, _confirm);
    expect(confirm.top, closeTo(cancel.top, 0.5), reason: 'one row');
    expect(confirm.left, greaterThan(cancel.right - 0.5), reason: 'cancel first');
  });

  testWidgets('[RED] a message taller than the dialog scrolls instead of '
      'overflowing; the buttons stay reachable', (tester) async {
    final errors = await _open(
      tester,
      size: const Size(360, 640),
      textScale: 2.0,
      message: List.filled(30, 'Una línea larga del aviso.').join(' '),
    );
    expect(_overflowed(errors), isFalse, reason: '$errors');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('hermes-confirm-dialog')),
        matching: find.byType(Scrollable),
      ),
      findsWidgets,
    );
    await tester.ensureVisible(find.byKey(_confirm));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hermes-confirm-dialog')), findsNothing);
  });
}
