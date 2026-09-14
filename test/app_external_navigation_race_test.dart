import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/new_session_launch_coordinator.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';

import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DraftProbe extends StatefulWidget {
  const _DraftProbe({
    required this.marker,
    required this.emissions,
    required this.releaseFirstSubmit,
  });

  final String marker;
  final List<String> emissions;
  final Future<void> releaseFirstSubmit;

  @override
  State<_DraftProbe> createState() => _DraftProbeState();
}

class _DraftProbeState extends State<_DraftProbe> {
  Future<void> _submit() async {
    widget.emissions.add('session.create');
    await widget.releaseFirstSubmit;
    if (!mounted) return;
    widget.emissions.add('prompt.submit');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Text(widget.marker),
    floatingActionButton: FloatingActionButton(
      key: const ValueKey('new-draft-first-submit'),
      onPressed: _submit,
      child: const Icon(Icons.arrow_upward),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a delayed old external open cannot replace a newer draft first submit',
    (tester) async {
      const marker = 'STALE_NAVIGATION_RACE_MARKER';
      final lookupStarted = Completer<void>();
      final releaseLookup = Completer<void>();
      final releaseFirstSubmit = Completer<void>();
      final emissions = <String>[];

      final connectionFixture = SavedConnection(
        id: 'race-connection',
        label: 'Race fixture',
        host: '192.168.255.254',
        port: 8642,
        apiKey: 'test-key',
        kind: InstanceKind.vps,
        onDeviceLoopback: true,
      );
      SharedPreferences.setMockInitialValues({'onboarding_done': true});
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      await prefs.setStringList('saved_connections', [
        jsonEncode(connectionFixture.toMap()),
      ]);
      manager.activeConnectionId.value = connectionFixture.id;
      final connection = connectionFixture;

      final notifications = NotificationService(prefs);
      final activeChats = ActiveChatService(
        notifications: notifications,
        policy: ApprovalPolicyService(prefs),
        prefs: prefs,
      );
      addTearDown(activeChats.dispose);

      final secure = SecureStorage();
      await tester.pumpWidget(
        HermesApp(
          connManager: manager,
          appLock: AppLockService(prefs),
          approvalPolicy: ApprovalPolicyService(prefs),
          fontSize: FontSizeService(prefs),
          bridgeManager: BridgeManager(secure, manager),
          sshManager: SshManager(secure, manager),
          sftpTransfers: SftpTransferService(
            SshManager(secure, manager),
            notifications,
          ),
          sshSessions: SshSessionService(SshManager(secure, manager)),
          notifications: notifications,
          activeChats: activeChats,
          externalSessionLookupForTesting: (_, sessionId, _) async {
            expect(sessionId, 'old-session');
            if (!lookupStarted.isCompleted) lookupStarted.complete();
            await releaseLookup.future;
            return const Session(
              id: 'old-session',
              title: 'Old destination',
              model: '',
              source: 'desktop',
              messageCount: 1,
              isActive: true,
              preview: 'old',
              startedAt: 1,
            );
          },
        ),
      );
      await tester.pump();

      final state = tester.state<HermesAppState>(find.byType(HermesApp));
      final staleOpen = state.debugOpenWidgetSession(connection, 'old-session');
      for (
        var attempt = 0;
        attempt < 50 && !lookupStarted.isCompleted;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(lookupStarted.isCompleted, isTrue);

      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      navigator.push<void>(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'new-draft:mob-new-draft'),
          builder: (_) => _DraftProbe(
            marker: marker,
            emissions: emissions,
            releaseFirstSubmit: releaseFirstSubmit.future,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('new-draft-first-submit')));
      await tester.pump();
      expect(emissions, ['session.create']);

      releaseLookup.complete();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text(marker), findsOneWidget);
      expect(find.text('Old destination'), findsNothing);
      expect(await staleOpen, NavigationDeliveryOutcome.deferred);

      releaseFirstSubmit.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        emissions.where((method) => method == 'session.create'),
        hasLength(1),
      );
      expect(
        emissions.where((method) => method == 'prompt.submit'),
        hasLength(1),
      );
      expect(find.text(marker), findsOneWidget);
    },
  );
}
