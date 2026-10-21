// A task launched from the Task Center is a normal chat session: the typed
// instruction becomes the first message of a new chat on the same connection
// and nothing is sent to the REST run API.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/screens/task_center_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/run_registry.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/desktop_chat_socket.dart' show HostCounter;

void main() {
  testWidgets('localhost FAB composer launch opens a chat with the prompt', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final connection = SavedConnection(
      id: 'existing',
      label: 'Existing',
      host: 'localhost',
      port: 9131,
      apiKey: 'synthetic-gateway-key',
      kind: InstanceKind.localhost,
    );
    final before = connection.toMap();
    final hosts = HostCounter();
    final opened = <ChatScreen>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.hermesRedDark,
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: TaskCenterScreen(
            connection: connection,
            profile: 'work_bot',
            chatHost: (chat) {
              opened.add(chat);
              return const SizedBox(key: ValueKey('chat-stub'));
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('runs-create')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('run-composer-surface')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byType(TextField).first,
        'Synthetic instruction',
      );
      final launch = find.text(
        Strings.of(
          tester.element(find.byType(TextField).first),
        ).runComposerLaunch,
      );
      await tester.ensureVisible(launch);
      await tester.tap(launch);
      await tester.pumpAndSettle();

      expect(opened, hasLength(1));
      expect(opened.single.initialPrompt, 'Synthetic instruction');
      expect(opened.single.connection.id, 'existing');
      expect(hosts.requests, isEmpty);
      final registry = await RunRegistry.load(
        await SharedPreferences.getInstance(),
        connection.id,
      );
      expect(registry.records, isEmpty);
      expect(connection.toMap(), before);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }, () => hosts);
  });
}
