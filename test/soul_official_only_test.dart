import 'support/official_http_audit.dart';

// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/main.dart';
import 'package:hermes_android/core/screens/soul_screen.dart';
import 'package:hermes_android/core/screens/lock_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/app_lock_sensitive_read_fence.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';
import 'support/header_actions.dart';

// This boundary records every access; it cannot contact or provision a server.

final _connection = SavedConnection(
  id: 'soul-fixture',
  label: 'Fixture',
  host: 'example.invalid',
  port: 443,
  apiKey: 'synthetic-fixture-key',
  useHttps: true,
);

class _Fixture {
  late ConnectionManager manager;
  late ActiveProfileScope scope;
  late OfficialHttpAudit bridge;
  late AppLockService lock;
  final requests = <String>[];
  final bodies = <String>[];
  final server = <String, String>{
    'default': 'Default persona',
    'alpha': 'Alpha persona',
    'beta': 'Beta persona',
  };
  Future<http.Response> Function(http.Request)? handler;
  late DashboardClient client;

  Future<void> open(
    WidgetTester tester, {
    String profile = '',
    String? fixedProfile,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    manager = await ConnectionManager.create(prefs);
    // Initialize before seeding profile: manager prunes orphaned persisted data.
    scope = ActiveProfileScope.of(manager, _connection.id);
    await scope.switchTo(profile);
    final secure = SecureStorage();
    bridge = OfficialHttpAudit();
    client = DashboardClient(
      host: 'example.invalid',
      useHttps: true,
      manualToken: 'synthetic-fixture-token',
      httpClientOverride: bridge.client((request) async {
        requests.add('${request.method} ${request.url.path}');
        if (request.method == 'PUT') bodies.add(request.body);
        if (handler != null) return handler!(request);
        final owner = request.url.path.split('/')[3];
        if (request.method == 'PUT') {
          server[owner] =
              (jsonDecode(request.body) as Map)['content'] as String;
          return http.Response('{"ok":true}', 200);
        }
        return http.Response(
          jsonEncode({'content': server[owner] ?? '', 'exists': true}),
          200,
        );
      }),
    );
    final chats = ActiveChatService(
      compressionRestoreStore: testCompressionRestoreStore(),
    );
    addTearDown(chats.dispose);
    final ssh = SshManager(secure, manager);
    await tester.pumpWidget(
      HermesApp(
        connManager: manager,
        appLock: lock = AppLockService(prefs),
        approvalPolicy: ApprovalPolicyService(prefs),
        fontSize: FontSizeService(prefs),

        sshManager: ssh,
        sftpTransfers: SftpTransferService(ssh, NotificationService(prefs)),
        sshSessions: SshSessionService(ssh),
        notifications: NotificationService(prefs),
        activeChats: chats,
      ),
    );
    await tick(tester);
    bridge.requests.clear();
    final context = tester.element(find.byType(Navigator).first);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SoulScreen(
          connection: _connection,
          profileScope: scope,
          profileOverride: fixedProfile,
          dashboardClientForTesting: client,
        ),
      ),
    );
    await tick(tester);
  }
}

Future<void> tick(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String editor(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).first).controller!.text;

final _announcements = <String>[];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final secure = <String, String>{};
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    _announcements.clear();
    messenger.setMockDecodedMessageHandler(SystemChannels.accessibility, (
      message,
    ) async {
      if (message is Map && message['data'] is Map) {
        final text = (message['data'] as Map)['message'];
        if (text is String) _announcements.add(text);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?) ?? {};
        switch (call.method) {
          case 'read':
            return secure[args['key']];
          case 'write':
            secure[args['key'] as String] = args['value'] as String;
            return null;
          case 'delete':
            secure.remove(args['key']);
            return null;
          case 'readAll':
            return Map<String, String>.from(secure);
          case 'containsKey':
            return secure.containsKey(args['key']);
        }
        return null;
      },
    );
    for (final name in [
      'dexterous.com/flutter/local_notifications',
      'flutter_foreground_task/background',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_foreground_task/methods'),
      (call) async => call.method == 'isRunningService' ? false : null,
    );
  });

  testWidgets(
    'real app navigation loads default SOUL without any Bridge access',
    (tester) async {
      final f = _Fixture();
      await f.open(tester);
      expect(editor(tester), 'Default persona');
      expect(f.requests, contains('GET /api/profiles/default/soul'));
      expect(f.bridge.calls, isEmpty);
      expect(find.byTooltip('Configure bridge'), findsNothing);
      Navigator.of(tester.element(find.byType(SoulScreen))).pop();
      await tick(tester);
      expect(f.bridge.calls, isEmpty);
    },
  );

  for (final status in [401, 404, 500]) {
    testWidgets(
      'official $status is unavailable without provisioning or losing the draft',
      (tester) async {
        final f = _Fixture();
        f.handler = (_) async =>
            http.Response('{"detail":"Fixture unavailable"}', status);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'soul_draft_${_connection.id}',
          'Local persona draft',
        );
        await f.open(tester);
        expect(editor(tester), 'Local persona draft');
        await tester.tap(find.text('reload'));
        await tick(tester);
        await tester.tap(find.text('Reload').last);
        await tick(tester);
        expect(editor(tester), 'Local persona draft');
        expect(find.textContaining("Couldn't load:"), findsWidgets);
        expect(f.bridge.calls, isEmpty);
      },
    );
  }

  testWidgets('invalid official content is not an empty successful reload', (
    tester,
  ) async {
    final f = _Fixture();
    await f.open(tester);
    await tester.enterText(find.byType(TextField).first, 'Unsaved persona');
    f.handler = (_) async =>
        http.Response('{"content":false,"exists":true}', 200);
    await tester.tap(find.text('reload'));
    await tick(tester);
    await tester.tap(find.text('Reload').last);
    await tick(tester);
    expect(editor(tester), 'Unsaved persona');
    expect(find.textContaining("Couldn't load:"), findsWidgets);
    expect(f.bridge.calls, isEmpty);
  });

  testWidgets(
    'official save reviews a fresh same-owner diff and verifies the write',
    (tester) async {
      final f = _Fixture();
      await f.open(tester);
      await tester.enterText(find.byType(TextField).first, 'Edited persona');
      await tester.tap(find.text('Apply'));
      await tick(tester);
      expect(find.byKey(const ValueKey('soul-diff-page')), findsOneWidget);
      expect(find.textContaining('-Default persona'), findsOneWidget);
      expect(find.textContaining('+Edited persona'), findsOneWidget);
      expect(f.requests.where((r) => r.startsWith('PUT')), isEmpty);
      await tester.tap(find.byKey(const ValueKey('hermes-review-confirm')));
      await tick(tester);
      expect(f.server['default'], 'Edited persona');
      expect(
        f.requests.where((r) => r == 'GET /api/profiles/default/soul').length,
        greaterThanOrEqualTo(4),
      );
      expect(_announcements, contains('SOUL for profile «default» applied'));
      expect(find.textContaining("Couldn't apply:"), findsNothing);
      expect(f.bridge.calls, isEmpty);
    },
  );

  testWidgets(
    'profile switches preserve each owners draft instead of overwriting it',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'soul_draft_${_connection.id}@alpha',
        'Alpha local draft',
      );
      await prefs.setString(
        'soul_draft_${_connection.id}@beta',
        'Beta local draft',
      );
      final f = _Fixture();
      await f.open(tester, profile: 'alpha');
      expect(editor(tester), 'Alpha local draft');
      await tester.enterText(
        find.byType(TextField).first,
        'Alpha pending draft',
      );
      await f.scope.switchTo('beta');
      await tick(tester);
      expect(editor(tester), 'Beta local draft');
      await f.scope.switchTo('alpha');
      await tick(tester);
      expect(editor(tester), 'Alpha pending draft');
      expect(
        prefs.getString('soul_draft_${_connection.id}@beta'),
        'Beta local draft',
      );
      expect(f.bridge.calls, isEmpty);
    },
  );

  for (final status in [401, 404, 500, 408]) {
    testWidgets(
      'cold official $status visibly reports unavailable and never provisions',
      (tester) async {
        final f = _Fixture();
        f.handler = (_) async {
          if (status == 408) throw TimeoutException('Fixture timeout');
          return http.Response('{"detail":"Fixture unavailable"}', status);
        };
        await f.open(tester);
        expect(editor(tester), isEmpty);
        expect(find.textContaining("Couldn't load:"), findsWidgets);
        expect(f.requests, contains('GET /api/profiles/default/soul'));
        expect(f.bridge.calls, isEmpty);
      },
    );
  }

  testWidgets(
    'a revoked private read cannot publish after a successor unlock',
    (tester) async {
      final held = Completer<http.Response>();
      final f = _Fixture();
      f.handler = (_) => held.future;
      await f.open(tester);
      AppLockSensitiveReadFence.foreground(f.lock, false);
      AppLockSensitiveReadFence.foreground(f.lock, true);
      held.complete(
        http.Response('{"content":"Retired persona","exists":true}', 200),
      );
      await tick(tester);
      expect(editor(tester), isEmpty);
      expect(f.requests.length, 1, reason: 'Unlock does not renew an old read');
      expect(f.bridge.calls, isEmpty);
    },
  );

  testWidgets('a stale reload cannot release the current owners busy read', (
    tester,
  ) async {
    final f = _Fixture();
    await f.open(tester, profile: 'alpha');
    final old = Completer<http.Response>();
    final fresh = Completer<http.Response>();
    f.handler = (request) =>
        request.url.path.contains('/alpha/') ? old.future : fresh.future;
    await tester.tap(find.text('reload'));
    await tick(tester);
    await f.scope.switchTo('beta');
    await tick(tester);
    old.complete(http.Response('{"content":"Old alpha","exists":true}', 200));
    await tick(tester);
    expect(find.text('applying…'), findsOneWidget);
    expect(editor(tester), isNot('Old alpha'));
    fresh.complete(
      http.Response('{"content":"Fresh beta","exists":true}', 200),
    );
    await tick(tester);
    expect(editor(tester), 'Fresh beta');
    expect(find.text('Apply'), findsOneWidget);
    expect(f.bridge.calls, isEmpty);
  });

  testWidgets(
    'reload requires an explicit decision before replacing a dirty draft',
    (tester) async {
      final f = _Fixture();
      await f.open(tester);
      await tester.enterText(find.byType(TextField).first, 'Keep this draft');
      final before = f.requests.length;
      await tester.tap(find.text('reload'));
      await tick(tester);
      expect(find.text('Reload from server'), findsOneWidget);
      await tester.tap(find.text('Cancel').last);
      await tick(tester);
      expect(editor(tester), 'Keep this draft');
      expect(f.requests.length, before);
      expect(f.bridge.calls, isEmpty);
    },
  );

  for (final reply in ['{"ok":false}', '{}', '{"ok":"true"}', '{"ok":true}']) {
    testWidgets('PUT $reply cannot report success without verified content', (
      tester,
    ) async {
      final f = _Fixture();
      await f.open(tester);
      await tester.enterText(
        find.byType(TextField).first,
        'Keep edited persona',
      );
      f.handler = (request) async => request.method == 'PUT'
          ? http.Response(reply, 200)
          : http.Response('{"content":"Default persona","exists":true}', 200);
      await tester.tap(find.text('Apply'));
      await tick(tester);
      await tester.tap(find.byKey(const ValueKey('hermes-review-confirm')));
      await tick(tester);
      expect(find.textContaining("Couldn't apply:"), findsWidgets);
      expect(_announcements.where((s) => s.endsWith(' applied')), isEmpty);
      expect(editor(tester), 'Keep edited persona');
      expect(f.bridge.calls, isEmpty);
    });
  }

  testWidgets(
    'server changes during review refuse overwrite and retain the draft',
    (tester) async {
      final f = _Fixture();
      await f.open(tester);
      await tester.enterText(find.byType(TextField).first, 'Reviewed persona');
      await tester.tap(find.text('Apply'));
      await tick(tester);
      f.server['default'] = 'Concurrent server persona';
      await tester.tap(find.byKey(const ValueKey('hermes-review-confirm')));
      await tick(tester);
      expect(f.bodies, isEmpty);
      expect(editor(tester), 'Reviewed persona');
      expect(find.textContaining("Couldn't apply:"), findsWidgets);
      expect(f.bridge.calls, isEmpty);
    },
  );

  for (final failure in [false, true]) {
    testWidgets(
      'late PUT ${failure ? 'failure' : 'success'} cannot publish across profile ABA',
      (tester) async {
        final f = _Fixture();
        await f.open(tester, profile: 'alpha');
        await tester.enterText(find.byType(TextField).first, 'Alpha write');
        final held = Completer<http.Response>();
        f.handler = (request) async {
          if (request.method == 'PUT') return held.future;
          final owner = request.url.path.split('/')[3];
          return http.Response(
            jsonEncode({'content': f.server[owner], 'exists': true}),
            200,
          );
        };
        await tester.tap(find.text('Apply'));
        await tick(tester);
        await tester.tap(find.byKey(const ValueKey('hermes-review-confirm')));
        await tick(tester);
        expect(f.bodies, hasLength(1));
        await f.scope.switchTo('beta');
        await tick(tester);
        await f.scope.switchTo('alpha');
        await tick(tester);
        held.complete(
          http.Response(
            failure ? '{"detail":"Late fixture failure"}' : '{"ok":true}',
            failure ? 500 : 200,
          ),
        );
        await tick(tester);
        expect(editor(tester), 'Alpha write');
        expect(find.textContaining("Couldn't apply:"), findsNothing);
        expect(_announcements.where((s) => s.endsWith(' applied')), isEmpty);
        expect(f.bodies, hasLength(1));
        expect(f.bridge.calls, isEmpty);
      },
    );
  }

  testWidgets(
    'fixed-profile SOUL remains pinned when active profile switches',
    (tester) async {
      final f = _Fixture();
      await f.open(tester, profile: 'beta', fixedProfile: 'alpha');
      expect(editor(tester), 'Alpha persona');
      await f.scope.switchTo('default');
      await tick(tester);
      expect(editor(tester), 'Alpha persona');
      expect(f.requests.toSet(), {'GET /api/profiles/alpha/soul'});
      expect(f.bridge.calls, isEmpty);
    },
  );

  testWidgets('read-only approval blocks all SOUL write traffic', (
    tester,
  ) async {
    final f = _Fixture();
    await f.open(tester);
    await tester
        .widget<HermesApp>(find.byType(HermesApp))
        .approvalPolicy
        .setGlobalMode(ApprovalMode.readOnly);
    final before = f.requests.length;
    await tester.tap(find.text('Apply'));
    await tick(tester);
    expect(f.requests.length, before);
    expect(f.bodies, isEmpty);
    expect(f.bridge.calls, isEmpty);
  });

  testWidgets(
    'a template confirmation cannot replace a successor profiles draft',
    (tester) async {
      final f = _Fixture();
      await f.open(tester, profile: 'alpha');
      await tester.enterText(
        find.byType(TextField).first,
        'Alpha template draft',
      );
      await tester.tap(find.byIcon(Icons.auto_fix_high_outlined));
      await tick(tester);
      await tester.tap(find.text('Minimalist agent'));
      await tick(tester);
      await f.scope.switchTo('beta');
      await tick(tester);
      await tester.tap(find.text('Replace').last);
      await tick(tester);
      expect(editor(tester), 'Beta persona');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('soul_backup_${_connection.id}@beta'), isNull);
      expect(
        prefs.getString('soul_draft_${_connection.id}@alpha'),
        'Alpha template draft',
      );
      expect(f.bridge.calls, isEmpty);
    },
  );

  testWidgets('revoking review authority prevents PUT even after unlocking', (
    tester,
  ) async {
    final f = _Fixture();
    await f.open(tester);
    await tester.enterText(find.byType(TextField).first, 'Private local draft');
    await tester.tap(find.text('Apply'));
    await tick(tester);
    AppLockSensitiveReadFence.foreground(f.lock, false);
    AppLockSensitiveReadFence.foreground(f.lock, true);
    await tester.tap(find.byKey(const ValueKey('hermes-review-confirm')));
    await tick(tester);
    expect(f.bodies, isEmpty);
    expect(editor(tester), 'Private local draft');
    expect(_announcements.where((s) => s.endsWith(' applied')), isEmpty);
    expect(f.bridge.calls, isEmpty);
  });

  testWidgets('a local backup restore cannot land on a successor profile', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'soul_backup_${_connection.id}@alpha',
      'Alpha backup',
    );
    final f = _Fixture();
    await f.open(tester, profile: 'alpha');
    await tapHeaderAction(
      tester,
      inBar: find.byTooltip('__never__'),
      inMenu: find.byIcon(Icons.restore),
    );
    await tick(tester);
    await f.scope.switchTo('beta');
    await tick(tester);
    await tester.tap(find.text('Restore').last);
    await tick(tester);
    expect(editor(tester), 'Beta persona');
    expect(f.bridge.calls, isEmpty);
  });

  testWidgets(
    'a template menu opened for one owner cannot be adopted by another',
    (tester) async {
      final f = _Fixture();
      await f.open(tester, profile: 'alpha');
      await tester.tap(find.byIcon(Icons.auto_fix_high_outlined));
      await tick(tester);
      await f.scope.switchTo('beta');
      await tick(tester);
      await tester.tap(find.text('Empty'));
      await tick(tester);
      // No successor-owned confirmation is offered for an old menu callback.
      expect(find.text('Replace'), findsNothing);
      expect(editor(tester), 'Beta persona');
      expect(f.bridge.calls, isEmpty);
    },
  );

  testWidgets('leaving SOUL flushes the owners pending local draft', (
    tester,
  ) async {
    final f = _Fixture();
    await f.open(tester, profile: 'alpha');
    await tester.enterText(
      find.byType(TextField).first,
      'Last local keystroke',
    );
    Navigator.of(tester.element(find.byType(SoulScreen))).pop();
    await tick(tester);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('soul_draft_${_connection.id}@alpha'),
      'Last local keystroke',
    );
    expect(f.bridge.calls, isEmpty);
  });

  testWidgets(
    'App Lock verification route cancels write without losing the draft',
    (tester) async {
      final f = _Fixture();
      await f.open(tester);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('app_lock_enabled', true);
      await tester.enterText(find.byType(TextField).first, 'Gated local draft');
      await tester.tap(find.text('Apply'));
      await tick(tester);
      await tester.tap(find.byKey(const ValueKey('hermes-review-confirm')));
      await tick(tester);
      expect(find.byType(LockScreen), findsOneWidget);
      expect(f.bodies, isEmpty);
      Navigator.of(tester.element(find.byType(LockScreen))).pop(false);
      await tick(tester);
      expect(editor(tester), 'Gated local draft');
      expect(f.bodies, isEmpty);
      expect(f.bridge.calls, isEmpty);
    },
  );

  testWidgets(
    'templates retain a local backup and restore it without remote writes',
    (tester) async {
      final f = _Fixture();
      await f.open(tester);
      await tester.enterText(
        find.byType(TextField).first,
        'Original local persona',
      );
      await tester.tap(find.byIcon(Icons.auto_fix_high_outlined));
      await tick(tester);
      await tester.tap(find.text('Empty'));
      await tick(tester);
      await tester.tap(find.text('Replace').last);
      await tick(tester);
      expect(editor(tester), isEmpty);
      await tapHeaderAction(
        tester,
        inBar: find.byTooltip('__never__'),
        inMenu: find.byIcon(Icons.restore),
      );
      await tick(tester);
      await tester.tap(find.text('Restore').last);
      await tick(tester);
      expect(editor(tester), 'Original local persona');
      expect(f.bodies, isEmpty);
      expect(f.bridge.calls, isEmpty);
    },
  );

  for (final status in [401, 404, 500, 408]) {
    testWidgets('official PUT $status is unavailable without provisioning', (
      tester,
    ) async {
      final f = _Fixture();
      await f.open(tester);
      await tester.enterText(
        find.byType(TextField).first,
        'Retained write draft',
      );
      f.handler = (request) async {
        if (request.method == 'PUT') {
          if (status == 408) throw TimeoutException('Fixture timeout');
          return http.Response('{"detail":"Fixture rejected"}', status);
        }
        return http.Response(
          '{"content":"Default persona","exists":true}',
          200,
        );
      };
      await tester.tap(find.text('Apply'));
      await tick(tester);
      await tester.tap(find.byKey(const ValueKey('hermes-review-confirm')));
      await tick(tester);
      expect(find.textContaining("Couldn't apply:"), findsWidgets);
      expect(editor(tester), 'Retained write draft');
      expect(_announcements.where((s) => s.endsWith(' applied')), isEmpty);
      expect(f.bridge.calls, isEmpty);
    });
  }

  testWidgets('switching owner during diff review cancels the old write', (
    tester,
  ) async {
    final f = _Fixture();
    await f.open(tester, profile: 'alpha');
    await tester.enterText(
      find.byType(TextField).first,
      'Alpha reviewed draft',
    );
    await tester.tap(find.text('Apply'));
    await tick(tester);
    await f.scope.switchTo('beta');
    await tick(tester);
    await tester.tap(find.byKey(const ValueKey('hermes-review-confirm')));
    await tick(tester);
    expect(editor(tester), 'Beta persona');
    expect(f.bodies, isEmpty);
    expect(f.bridge.calls, isEmpty);
  });

  testWidgets(
    'pending initial official load cannot overwrite newly typed text',
    (tester) async {
      final held = Completer<http.Response>();
      final f = _Fixture();
      f.handler = (_) => held.future;
      await f.open(tester);
      await tester.enterText(
        find.byType(TextField).first,
        'New text on pending read',
      );
      held.complete(
        http.Response('{"content":"Old server persona","exists":true}', 200),
      );
      await tick(tester);
      expect(editor(tester), 'New text on pending read');
      expect(f.bridge.calls, isEmpty);
    },
  );

  testWidgets(
    'an intentionally empty saved draft stays empty on reopen and can be applied',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('soul_draft_${_connection.id}', '');
      final f = _Fixture();
      await f.open(tester);
      expect(editor(tester), isEmpty);
      await tester.tap(find.text('Apply'));
      await tick(tester);
      await tester.tap(find.byKey(const ValueKey('hermes-review-confirm')));
      await tick(tester);
      expect(f.server['default'], isEmpty);
      expect(_announcements, contains('SOUL for profile «default» applied'));
      expect(f.bridge.calls, isEmpty);
    },
  );
}
