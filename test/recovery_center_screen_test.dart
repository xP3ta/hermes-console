import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/screens/recovery_center_screen.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'support/quiet_feedback.dart';

class _RecoveryGateway implements HermesDesktopControlGateway {
  RecoveryTimeline timeline = const RecoveryTimeline(
    enabled: true,
    checkpoints: [],
  );
  RecoveryDiff recoveryDiff = const RecoveryDiff(stat: '', diff: '');
  Object? listFailure;
  Object? diffFailure;
  Object? restoreFailure;
  int listCalls = 0;
  int diffCalls = 0;
  int restoreCalls = 0;
  String? restoredHash;

  @override
  Future<RecoveryTimeline> listRecovery(String runtimeSessionId) async {
    listCalls++;
    if (listFailure case final failure?) throw failure;
    return timeline;
  }

  @override
  Future<RecoveryDiff> diffRecovery(
    String runtimeSessionId,
    String checkpointHash,
  ) async {
    diffCalls++;
    if (diffFailure case final failure?) throw failure;
    return recoveryDiff;
  }

  @override
  Future<RecoveryRestoreResult> restoreRecovery(
    String runtimeSessionId,
    String checkpointHash,
  ) async {
    restoreCalls++;
    restoredHash = checkpointHash;
    if (restoreFailure case final failure?) throw failure;
    return const RecoveryRestoreResult(success: true, historyRemoved: 2);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(Widget home, {Locale locale = const Locale('es')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: home,
);

const _hash = 'abcdef1234567890abcdef1234567890abcdef12';

RecoveryTimeline _timeline() => const RecoveryTimeline(
  enabled: true,
  checkpoints: [
    RecoveryCheckpoint(
      hash: _hash,
      timestamp: '2026-07-22T10:30:00Z',
      message: 'Antes del cambio en /private/host/project',
    ),
  ],
);

void main() {
  testWidgets('renders checkpoint and readable diff without host paths or JSON', (
    tester,
  ) async {
    final gateway = _RecoveryGateway()
      ..timeline = _timeline()
      ..recoveryDiff = const RecoveryDiff(
        stat: '2 archivos modificados en /home/alice/project',
        diff:
            '--- /private/host/project/secret.dart\n+++ lib/safe.dart\n@@ -1 +1 @@\n-old\n+new',
      );

    await tester.pumpWidget(
      _app(
        RecoveryCenterScreen(gateway: gateway, runtimeSessionId: 'runtime-a'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Recuperación'), findsOneWidget);
    expect(find.textContaining('abcdef12'), findsOneWidget);
    expect(find.textContaining('/private/host'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('recovery-checkpoint-$_hash')));
    await tester.pumpAndSettle();

    expect(gateway.diffCalls, 1);
    expect(find.textContaining('2 archivos modificados'), findsOneWidget);
    expect(find.textContaining('+new'), findsOneWidget);
    expect(find.textContaining('/private/host'), findsNothing);
    expect(find.textContaining('/home/alice'), findsNothing);
    expect(find.textContaining('{"'), findsNothing);
  });

  testWidgets('restore requires the exact checkpoint hash and refreshes', (
    tester,
  ) async {
    final gateway = _RecoveryGateway()
      ..timeline = _timeline()
      ..recoveryDiff = const RecoveryDiff(
        stat: '1 archivo modificado',
        diff: '@@ -1 +1 @@\n-a\n+b',
      );

    await tester.pumpWidget(
      _app(
        RecoveryCenterScreen(gateway: gateway, runtimeSessionId: 'runtime-a'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recovery-checkpoint-$_hash')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restaurar checkpoint'));
    await tester.pumpAndSettle();

    var restoreButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Restaurar ahora'),
    );
    expect(restoreButton.onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'abcdef12');
    await tester.pump();
    restoreButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Restaurar ahora'),
    );
    expect(restoreButton.onPressed, isNull);
    expect(gateway.restoreCalls, 0);

    await tester.enterText(find.byType(TextField), _hash);
    await tester.pump();
    await tester.tap(find.text('Restaurar ahora'));
    await tester.pumpAndSettle();

    expect(gateway.restoreCalls, 1);
    expect(gateway.restoredHash, _hash);
    expect(gateway.listCalls, 2);
    expectRoutineFeedback(tester, 'Checkpoint restaurado.');
  });

  testWidgets('read-only keeps restore disabled and sends no mutation', (
    tester,
  ) async {
    final gateway = _RecoveryGateway()
      ..timeline = _timeline()
      ..recoveryDiff = const RecoveryDiff(stat: 'Sin cambios', diff: '');

    await tester.pumpWidget(
      _app(
        RecoveryCenterScreen(
          gateway: gateway,
          runtimeSessionId: 'runtime-a',
          readOnly: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('solo lectura'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('recovery-checkpoint-$_hash')));
    await tester.pumpAndSettle();

    final restoreButton = tester.widget<HermesSecondaryButton>(
      find.widgetWithText(HermesSecondaryButton, 'Restaurar checkpoint'),
    );
    expect(restoreButton.onTap, isNull);
    expect(gateway.restoreCalls, 0);
  });

  testWidgets('unsupported recovery is explicit, never a fake empty timeline', (
    tester,
  ) async {
    final gateway = _RecoveryGateway()
      ..listFailure = const DesktopControlFailure(
        DesktopControlFailureKind.unsupported,
        code: -32601,
      );

    await tester.pumpWidget(
      _app(
        RecoveryCenterScreen(gateway: gateway, runtimeSessionId: 'runtime-a'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Esta versión de Hermes no ofrece recuperación.'),
      findsOneWidget,
    );
    expect(find.text('No hay checkpoints'), findsNothing);
    expect(find.text('Reintentar'), findsOneWidget);
  });

  testWidgets('missing runtime does not issue rollback RPCs', (tester) async {
    final gateway = _RecoveryGateway()..timeline = _timeline();

    await tester.pumpWidget(
      _app(RecoveryCenterScreen(gateway: gateway, runtimeSessionId: '')),
    );
    await tester.pumpAndSettle();

    expect(gateway.listCalls, 0);
    expect(
      find.text('Abre una conversación para consultar sus checkpoints.'),
      findsOneWidget,
    );
  });

  testWidgets('renders recovery copy in English', (tester) async {
    final gateway = _RecoveryGateway();

    await tester.pumpWidget(
      _app(
        RecoveryCenterScreen(gateway: gateway, runtimeSessionId: ''),
        locale: const Locale('en'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Recovery'), findsOneWidget);
    expect(
      find.text('Open a conversation to view its checkpoints.'),
      findsOneWidget,
    );
    expect(gateway.listCalls, 0);
  });
}
