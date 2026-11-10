import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/delegated_work_pill.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/inter_font.dart';

SubagentActivity _child(String id, SubagentActivityPhase phase) =>
    SubagentActivity(
      key: SubagentActivityKey(
        scope: SubagentActivityScope(
          connectionId: 'c',
          parentSessionId: 'p',
          runtimeSessionId: 'r',
          turnEpoch: 1,
        ),
        identityKind: SubagentIdentityKind.subagent,
        stableId: id,
      ),
      source: SubagentActivitySource.native,
      phase: phase,
      subagentId: id,
      details: const SubagentActivityDetails(),
    );

Widget _host(SubagentActivityPhase phase) => MaterialApp(
  theme: AppTheme.fromId('dark'),
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(
    body: DelegatedWorkPill(
      name: 'xPeta',
      capsule: true,
      snapshot: ActivitySnapshot(
        subagents: [
          for (final id in ['sa-1', 'sa-2', 'sa-3']) _child(id, phase),
        ],
      ),
      onOpen: () async {},
    ),
  ),
);

void main() {
  setUpAll(loadInterFont);

  testWidgets(
    'rec-error: a latched «Detenido» retires once server truth completes '
    'the children',
    (tester) async {
      await tester.pumpWidget(_host(SubagentActivityPhase.cancelled));
      await tester.pump();
      expect(find.textContaining('Detenido'), findsOneWidget);

      await tester.pumpWidget(_host(SubagentActivityPhase.completed));
      await tester.pump();
      expect(find.textContaining('Detenido'), findsNothing);
      expect(find.textContaining('Falló'), findsNothing);
      // Nothing running, nothing failed: the capsule rests hidden.
      expect(find.byKey(const ValueKey('delegates-capsule')), findsNothing);
      await tester.pump(const Duration(seconds: 4));
    },
  );

  testWidgets('rec-error: a real failure stays until acknowledged', (
    tester,
  ) async {
    await tester.pumpWidget(_host(SubagentActivityPhase.failed));
    await tester.pump();
    final label = tester
        .widget<Text>(find.byKey(const ValueKey('delegates-capsule-text')))
        .data;
    expect(label, contains('3'));

    await tester.pumpWidget(_host(SubagentActivityPhase.failed));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('delegates-capsule-text')),
      findsOneWidget,
    );
  });
}
