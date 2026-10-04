import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/screens/profiles_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final a11yConnection = SavedConnection(
  id: 'a11y-main-screens',
  label: 'Accessibility fixture',
  host: 'hermes.example.test',
  port: 443,
  apiKey: 'fixture-token',
  useHttps: true,
);

Session a11ySession() => Session(
  id: 'a11y-session',
  title: 'Accessible conversation',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 4,
  isActive: true,
  preview: 'Review the release',
  startedAt: 1,
);

List<Map<String, dynamic>> a11yTranscript() => const [
  {
    'id': 'user-row',
    'message_id': 'user-row',
    'role': 'user',
    'content': 'Review the release',
  },
  {
    'id': 'tool-call-row',
    'message_id': 'tool-call-row',
    'role': 'assistant',
    'content': '',
    'tool_calls': [
      {
        'id': 'tool-call',
        'type': 'function',
        'function': {'name': 'terminal', 'arguments': '{}'},
      },
    ],
  },
  {
    'id': 'tool-result-row',
    'message_id': 'tool-result-row',
    'role': 'tool',
    'tool_call_id': 'tool-call',
    'content': 'Checks completed',
  },
  {
    'id': 'assistant-row',
    'message_id': 'assistant-row',
    'role': 'assistant',
    'content': 'The release is ready.',
  },
];

void installA11yPlatformMocks() {
  final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => call.method == 'readAll' ? <String, String>{} : null,
  );
  for (final name in const [
    'dexterous.com/flutter/local_notifications',
    'flutter_foreground_task/methods',
    'flutter_foreground_task/background',
  ]) {
    messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }
}

void clearA11yPlatformMocks() {
  final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
  for (final name in const [
    'plugins.it_nomads.com/flutter_secure_storage',
    'dexterous.com/flutter/local_notifications',
    'flutter_foreground_task/methods',
    'flutter_foreground_task/background',
  ]) {
    messenger.setMockMethodCallHandler(MethodChannel(name), null);
  }
}

Future<ConnectionManager> createA11yManager({bool onboarded = true}) async {
  SharedPreferences.setMockInitialValues({
    if (onboarded) 'onboarding_done': true,
    'dock_use_dock': false,
  });
  return ConnectionManager.create(await SharedPreferences.getInstance());
}

Widget a11yHost(Widget child, {double textScale = 2}) => MaterialApp(
  locale: const Locale('en'),
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: child,
);

const a11yPhoneSize = Size(360, 690);

void useA11yPhoneView(WidgetTester tester) {
  tester.view.physicalSize = a11yPhoneSize;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Proves that the named [targets] stay usable on the compact phone view at
/// [textScale]: every match is rendered at least at the requested text scale,
/// scrolled fully inside the viewport, hit-testable (nothing overlays or clips
/// it) and does not overlap any other target that is on screen at the same
/// time.
///
/// Matching one control is not enough: a layout that clamps or overlays the
/// rest of the screen would still leave that control visible. AppBar titles
/// are exempt from the scale check because Flutter clamps them at 1.34x.
Future<void> expectA11yLayoutUsable(
  WidgetTester tester,
  Map<String, Finder> targets, {
  double textScale = 2,
}) async {
  expect(tester.takeException(), isNull);
  final viewport =
      Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio);

  final resolved = <String, Finder>{};
  for (final entry in targets.entries) {
    final elements = entry.value.evaluate().toList();
    expect(elements, isNotEmpty, reason: '${entry.key} is not on screen');
    for (var index = 0; index < elements.length; index++) {
      final element = elements[index];
      resolved['${entry.key}[$index]'] = find.byElementPredicate(
        (candidate) => identical(candidate, element),
        description: entry.key,
      );
    }
  }

  Rect? rectOf(Finder finder) =>
      finder.evaluate().isEmpty ? null : tester.getRect(finder);

  // The part of the screen in which [finder] can currently be seen: the
  // viewport narrowed by its nearest scroll view.
  Rect clipOf(Finder finder) {
    final scrollables = find.ancestor(
      of: finder,
      matching: find.byType(Scrollable),
    );
    if (scrollables.evaluate().isEmpty) return viewport;
    return viewport.intersect(tester.getRect(scrollables.first));
  }

  bool within(Rect rect, Rect bounds) =>
      rect.left >= bounds.left - 0.5 &&
      rect.top >= bounds.top - 0.5 &&
      rect.right <= bounds.right + 0.5 &&
      rect.bottom <= bounds.bottom + 0.5;

  for (final entry in resolved.entries) {
    final name = entry.key;
    final target = entry.value;
    await tester.ensureVisible(target);
    await tester.pump();
    expect(tester.takeException(), isNull, reason: name);

    final inAppBar = find
        .ancestor(of: target, matching: find.byType(AppBar))
        .evaluate()
        .isNotEmpty;
    if (!inAppBar) {
      expect(
        MediaQuery.textScalerOf(tester.element(target)).scale(10),
        greaterThanOrEqualTo(10 * textScale - 0.01),
        reason: '$name is not laid out at ${textScale}x text',
      );
    }

    final rect = rectOf(target)!;
    expect(rect.width, greaterThan(0), reason: '$name has no width');
    expect(rect.height, greaterThan(0), reason: '$name has no height');
    final clip = clipOf(target);
    expect(
      within(rect, clip),
      isTrue,
      reason: '$name $rect is not fully inside the visible area $clip',
    );
    expect(
      target.hitTestable(),
      findsOneWidget,
      reason: '$name is covered or clipped',
    );

    for (final other in resolved.entries) {
      if (other.key == name) continue;
      final otherRect = rectOf(other.value);
      // A target scrolled partly out of view is checked on its own turn.
      if (otherRect == null || !within(otherRect, clipOf(other.value))) {
        continue;
      }
      final overlap = rect.intersect(otherRect);
      expect(
        overlap.width <= 1 || overlap.height <= 1,
        isTrue,
        reason: '$name $rect overlaps ${other.key} $otherRect',
      );
    }
  }
}

final class A11yApiClient extends ApiClient {
  A11yApiClient({this.sessions = const []})
    : super(
        baseUrl: 'https://hermes.example.test',
        apiKey: 'fixture-token',
        connectionId: a11yConnection.id,
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );

  final List<Session> sessions;

  @override
  Future<bool> healthCheck() async => true;

  @override
  Future<bool> healthReachable() async => true;

  @override
  Future<List<Session>> getSessions({
    bool includeChildren = false,
    String? profile,
    int pageSize = 200,
    bool Function(List<Session> sessions)? enough,
    int? maxPages,
  }) async => List.of(sessions);

  @override
  void close() {}
}

Future<void> pumpA11yProfiles(
  WidgetTester tester, {
  ConnectionManager? manager,
  double textScale = 2,
}) async {
  final resolvedManager = manager ?? await createA11yManager();
  await tester.pumpWidget(
    a11yHost(
      ProfilesScreen(
        connection: a11yConnection,
        connManager: resolvedManager,
        clientOverride: DashboardClient(
          host: 'hermes.example.test',
          manualToken: 'fixture-token',
          httpClientOverride: MockClient((_) async => http.Response('{}', 404)),
        ),
        gatewayProfilesOverride: () async => const [
          AgentProfile(
            name: 'default',
            isDefault: true,
            description: 'Primary accessibility profile',
            skillCount: 2,
          ),
          AgentProfile(
            name: 'release',
            description: 'Release verification profile',
            skillCount: 4,
          ),
        ],
      ),
      textScale: textScale,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

final class A11yDesktopGateway
    implements HermesDesktopGateway, HermesDesktopSessionLifecycleGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-a11y',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async => DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-a11y',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-a11y',
    storedSessionId: 'a11y-session',
    created: true,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

Future<void> pumpA11yChat(WidgetTester tester, {double textScale = 2}) async {
  tester.platformDispatcher.localesTestValue = const [Locale('en')];
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final manager = await createA11yManager();
  final prefs = manager.prefs;
  final secureStorage = SecureStorage();
  final activeChats = ActiveChatService();
  addTearDown(activeChats.dispose);
  final gateway = A11yDesktopGateway();
  final chat = activeChats.attach(
    connection: a11yConnection,
    sessionId: a11ySession().id,
    sessionTitle: a11ySession().title,
    api: A11yApiClient(),
    desktopGateway: gateway,
    disableForegroundKeepAlive: true,
  );
  chat
    ..internalMessagesForTesting = a11yTranscript()
    ..messagesLoaded = true;

  await tester.pumpWidget(
    HermesApp(
      connManager: manager,
      appLock: AppLockService(prefs),
      approvalPolicy: ApprovalPolicyService(prefs),
      fontSize: FontSizeService(prefs),
      bridgeManager: BridgeManager(secureStorage, manager),
      sshManager: SshManager(secureStorage, manager),
      sftpTransfers: SftpTransferService(
        SshManager(secureStorage, manager),
        NotificationService(prefs),
      ),
      sshSessions: SshSessionService(SshManager(secureStorage, manager)),
      notifications: NotificationService(prefs),
      activeChats: activeChats,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 4));
  await tester.pump(const Duration(milliseconds: 1500));

  Navigator.of(tester.element(find.byType(Navigator).first)).push(
    MaterialPageRoute(
      builder: (_) =>
          ChatScreen(connection: a11yConnection, session: a11ySession()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}
