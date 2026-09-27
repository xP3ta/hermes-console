// Spec 080 step 9: AlertDialogs swept to the floating dialog system.
// Screenshots at 390×844 dark ES when DESIGN_SHOTS_DIR is set.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart';

import '../support/design_shots.dart';

Widget _opener(Future<void> Function(BuildContext) open) => Builder(
  builder: (context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () => open(context),
        child: const Text('open'),
      ),
    ),
  ),
);

void main() {
  testWidgets('confirm dialog: destructive pill, floating', (tester) async {
    bool? result;
    await pumpDesignScreen(
      tester,
      _opener(
        (context) async => result = await showHermesDialog<bool>(
          context: context,
          title: '¿Eliminar instancia?',
          message:
              'Se quitará «Casa · homelab» de este dispositivo. El servidor '
              'no se modifica.',
          actions: const [
            HermesDialogAction(
              label: 'Cancelar',
              value: false,
              style: HermesDialogActionStyle.cancel,
            ),
            HermesDialogAction(
              label: 'Eliminar',
              value: true,
              style: HermesDialogActionStyle.destructive,
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hermes-dialog')), findsOneWidget);
    await saveDesignShot(tester, 'dialog_confirm');
    await tester.tap(find.text('Eliminar'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('form dialog: field + enabled rule', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    String? result;
    await pumpDesignScreen(
      tester,
      _opener(
        (context) async => result = await showHermesFormDialog<String?>(
          context: context,
          title: 'Nueva tarea en segundo plano',
          body: (context, setState) => TextField(
            controller: controller,
            autofocus: true,
            minLines: 2,
            maxLines: 5,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'Qué debe hacer el agente…',
            ),
          ),
          enabled: (v) => v == null || controller.text.trim().isNotEmpty,
          actions: const [
            HermesDialogAction(
              label: 'Cancelar',
              value: null,
              style: HermesDialogActionStyle.cancel,
            ),
            HermesDialogAction(label: 'Iniciar', value: 'go'),
          ],
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Iniciar'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hermes-form-dialog')), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Revisa los logs');
    await tester.pumpAndSettle();
    await saveDesignShot(tester, 'dialog_form');
    await tester.tap(find.text('Iniciar'));
    await tester.pumpAndSettle();
    expect(result, 'go');
  });

  testWidgets('long message + keyboard: actions stay reachable', (
    tester,
  ) async {
    await pumpDesignScreen(
      tester,
      _opener(
        (context) => showHermesDialog<bool>(
          context: context,
          title: '¿Descartar cambios?',
          message: 'Texto largo. ' * 80,
          actions: const [
            HermesDialogAction(label: 'Seguir', value: false),
          ],
        ),
      ),
      size: const Size(320, 720),
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Seguir'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hermes-dialog')), findsNothing);
  });
}
