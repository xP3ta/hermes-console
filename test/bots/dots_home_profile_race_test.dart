import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_bot_chat_title_lookup.dart';

final _connection = SavedConnection(
  id: 'dots-race',
  label: 'Race',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'k',
);

/// Every `load()` waits on its own completer, released by the test.
final class _HeldSource implements MissionControlDataSource {
  final loads = <Completer<MissionBackendSnapshot>>[];

  @override
  Future<MissionBackendSnapshot> load() {
    final answer = Completer<MissionBackendSnapshot>();
    loads.add(answer);
    return answer.future;
  }

  @override
  Stream<KanbanEvent>? watchKanban({required int since}) => null;

  @override
  void close() {}
}

MissionBackendSnapshot _roster(List<String> names) => MissionBackendSnapshot(
  profiles: [
    for (final name in names)
      AgentProfile(name: name, isDefault: name == 'default'),
  ],
  profilesCapability: MissionCapabilityState.available,
  sessionsCapability: MissionCapabilityState.available,
  kanbanCapability: MissionCapabilityState.available,
  board: const KanbanBoard(columns: <KanbanColumn>[]),
  loadedAt: DateTime(2026),
);

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
  });

  testWidgets('a roster read started before an active-profile switch never '
      'paints when it lands late; the read for the new profile does', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    final source = _HeldSource();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: MissionControlScreen(
          connection: _connection,
          connManager: manager,
          dataSource: source,
          botChatTitleLookup: FakeBotChatTitleLookup(),
        ),
      ),
    );
    expect(source.loads, hasLength(1), reason: 'the first read is held');

    // The user switches the active profile (Home chip) while it is slow.
    await manager.setActiveProfile(_connection.id, 'astra');
    await tester.pump();
    expect(
      source.loads,
      hasLength(2),
      reason: 'the switch re-reads under the new active profile',
    );

    // The previous profile's read lands late: it must not paint.
    source.loads[0].complete(_roster(['default', 'late-bot']));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('dots-tile-late-bot')), findsNothing);
    expect(find.byKey(const ValueKey('dots-main')), findsNothing);

    source.loads[1].complete(_roster(['default', 'fresh-bot']));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('dots-tile-fresh-bot')), findsOneWidget);
    expect(find.byKey(const ValueKey('dots-tile-late-bot')), findsNothing);
    expect(find.byKey(const ValueKey('dots-main')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
