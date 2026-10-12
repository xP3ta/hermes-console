// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/main.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final port in [9119, 8643, 8860]) {
    for (final inProgress in [false, true]) {
      testWidgets(
        'real app Home explicit localhost $port progress=$inProgress has no Termux origin',
        (tester) async {
          SharedPreferences.setMockInitialValues({
            'onboarding_done': true,
            'locale': 'en',
            'local_install_in_progress': inProgress,
            'local_uninstall_in_progress': inProgress,
          });
          FlutterSecureStorage.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          final manager = await ConnectionManager.create(prefs);
          const fixtureKey = 'synthetic-explicit-connection-key';
          await manager.upsertConnection(
            SavedConnection(
              id: 'explicit-local',
              label: 'Explicit localhost',
              host: '127.0.0.1',
              port: port,
              apiKey: fixtureKey,
              kind: InstanceKind.localhost,
              onDeviceLoopback: true,
            ),
          );
          await manager.setActiveConnection('explicit-local');
          final nativeTermux = <String>[];
          final termuxOrigins = <String>[];
          final official = <Uri>[];
          const channel = MethodChannel('hermes/android_apps');
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (call) async {
              nativeTermux.add(call.method);
              return false;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null),
          );
          final client = MockClient((request) async {
            final origin = StackTrace.current.toString();
            if (origin.contains('local_termux_agent_provider.dart')) {
              termuxOrigins.add('${request.method} ${request.url}\n$origin');
            } else if (request.url.host == '127.0.0.1' &&
                request.url.port == port) {
              official.add(request.url);
            }
            if (request.url.path == '/health') {
              return http.Response('{"status":"ok"}', 200);
            }
            if (request.url.path == '/api/sessions') {
              return http.Response(
                jsonEncode({'data': [], 'has_more': false}),
                200,
              );
            }
            return http.Response('{}', 404);
          });
          final secure = SecureStorage();
          final ssh = SshManager(secure, manager);
          final notifications = NotificationService(prefs);
          final chats = ActiveChatService(attachDesktopRuntimeOnLoad: false);
          await http.runWithClient(() async {
            await tester.pumpWidget(
              HermesApp(
                connManager: manager,
                appLock: AppLockService(prefs),
                approvalPolicy: ApprovalPolicyService(prefs),
                fontSize: FontSizeService(prefs),

                sshManager: ssh,
                sftpTransfers: SftpTransferService(ssh, notifications),
                sshSessions: SshSessionService(ssh),
                notifications: notifications,
                activeChats: chats,
              ),
            );
            for (var i = 0; i < 60; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(find.byType(HomeDashboardScreen), findsOneWidget);
            final refresh = tester.widget<RefreshIndicator>(
              find.byType(RefreshIndicator).first,
            );
            var done = false;
            final future = refresh.onRefresh().whenComplete(() => done = true);
            for (var i = 0; i < 60 && !done; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            await future;
            expect(
              termuxOrigins,
              isEmpty,
              reason: 'Origin/call stack, not a localhost port blacklist',
            );
            expect(nativeTermux, isEmpty);
            expect(
              official.where((uri) => uri.path == '/health').length,
              greaterThanOrEqualTo(2),
            );
            expect(
              official.where((uri) => uri.path == '/api/sessions'),
              isNotEmpty,
            );
            expect(
              manager.getConnections().single.apiKey,
              fixtureKey,
              reason: 'Home must not replace explicit connection credentials',
            );
            expect(find.text('Start agent'), findsNothing);
            expect(find.text('Resume'), findsNothing);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(seconds: 30));
            expect(tester.takeException(), isNull);
          }, () => client);
        },
      );
    }
  }
  testWidgets(
    'fresh real app never creates or scans an implicit localhost runtime',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'onboarding_done': true,
        'local_install_in_progress': true,
        'local_uninstall_in_progress': true,
      });
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      final requests = <Uri>[];
      final native = <String>[];
      const channel = MethodChannel('hermes/android_apps');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        native.add(call.method);
        return false;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final client = MockClient((request) async {
        requests.add(request.url);
        return http.Response('{}', 404);
      });
      final secure = SecureStorage();
      final ssh = SshManager(secure, manager);
      final notifications = NotificationService(prefs);
      await http.runWithClient(() async {
        await tester.pumpWidget(
          HermesApp(
            connManager: manager,
            appLock: AppLockService(prefs),
            approvalPolicy: ApprovalPolicyService(prefs),
            fontSize: FontSizeService(prefs),

            sshManager: ssh,
            sftpTransfers: SftpTransferService(ssh, notifications),
            sshSessions: SshSessionService(ssh),
            notifications: notifications,
            activeChats: ActiveChatService(attachDesktopRuntimeOnLoad: false),
          ),
        );
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byType(HomeDashboardScreen), findsOneWidget);
        expect(manager.getConnections(), isEmpty);
        expect(requests, isEmpty);
        expect(native, isEmpty);
        expect(find.text('Resume'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 30));
        expect(tester.takeException(), isNull);
      }, () => client);
    },
  );
  testWidgets(
    'empty Home add opens existing connection chooser, not Android installer',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: HomeDashboardScreen(connManager: manager),
        ),
      );
      await tester.pumpAndSettle();
      // Empty Home has one primary action; exercise its actual navigation.
      await tester.tap(find.byIcon(Icons.add).last);
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
