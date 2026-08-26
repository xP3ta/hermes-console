import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/command_descriptor.dart';
import 'package:hermes_android/core/models/desktop_context_breakdown.dart';
import 'package:hermes_android/core/models/desktop_model_catalog.dart';
import 'package:hermes_android/core/models/desktop_session_config.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/screens/skills_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/utils/slash_commands.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SlashGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopCommandGateway,
        HermesDesktopContextUsageGateway,
        HermesDesktopSessionConfigGateway,
        HermesDesktopModelCatalogGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  final List<String> submissions = [];
  final List<String> slashCalls = [];
  Completer<SlashCompletionBatch>? slashCompletion;
  Completer<DesktopCommandRpcResult>? slashGate;
  int slashCompletionCalls = 0;
  Object? slashError;
  Object? dispatchError;
  Object? resumeExistingError;
  Object? modelError;
  Object? submitError;
  final List<DesktopModelSelection> modelSelections = [];
  DesktopCommandRpcResult slashResult = _acceptedResult;

  final DesktopModelCatalog modelCatalog = DesktopModelCatalog.fromJson(const {
    'model': 'old-model',
    'provider': 'provider-a',
    'providers': [
      {
        'slug': 'provider-a',
        'name': 'Provider A',
        'is_current': true,
        'authenticated': true,
        'models': ['old-model', 'bad-model'],
      },
    ],
  });

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
    runtimeSessionId: 'runtime-slash-test',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    if (resumeExistingError case final error?) throw error;
    return DesktopSessionSnapshot(
      runtimeSessionId: 'runtime-slash-test',
      storedSessionId: storedSessionId,
      created: false,
    );
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-slash-test',
    storedSessionId: 'session-slash-test',
    created: true,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submissions.add(text);
    if (submitError case final error?) throw error;
  }

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
  }) async {}

  @override
  Future<DesktopCommandCatalog> commandsCatalog() async =>
      DesktopCommandCatalog.fromJson(const {
        'pairs': [
          ['/goal', 'Run a goal'],
        ],
      });

  @override
  Future<SlashCompletionBatch> completeSlash(String text) async {
    slashCompletionCalls++;
    return slashCompletion?.future ??
        SlashCompletionBatch.fromJson(const {'items': <Object>[]}, input: text);
  }

  @override
  Future<DesktopCommandRpcResult> slashExec(
    String runtimeSessionId,
    String command,
  ) async {
    slashCalls.add(command);
    if (slashError case final error?) throw error;
    return slashGate?.future ?? slashResult;
  }

  @override
  Future<DesktopCommandRpcResult> commandDispatch(
    String runtimeSessionId, {
    required String name,
    String arg = '',
  }) async {
    if (dispatchError case final error?) throw error;
    return _acceptedResult;
  }

  @override
  Future<DesktopModelCatalog> modelOptions(
    String runtimeSessionId, {
    bool refresh = false,
  }) async => modelCatalog;

  @override
  Future<DesktopConfigSetResult> setSessionModel(
    String runtimeSessionId,
    DesktopModelSelection selection, {
    bool confirmExpensiveModel = false,
  }) async {
    modelSelections.add(selection);
    if (modelError case final error?) throw error;
    return DesktopConfigSetResult(
      key: DesktopSessionConfigKey.model,
      value: selection.sessionWireValue,
    );
  }

  @override
  Future<DesktopConfigSetResult> setSessionReasoning(
    String runtimeSessionId,
    DesktopReasoningEffort effort,
  ) async => DesktopConfigSetResult(
    key: DesktopSessionConfigKey.reasoning,
    value: effort.wire,
  );

  @override
  Future<DesktopConfigSetResult> setSessionFastMode(
    String runtimeSessionId,
    DesktopFastMode mode,
  ) async => DesktopConfigSetResult(
    key: DesktopSessionConfigKey.fast,
    value: mode.wire,
  );

  @override
  Future<DesktopContextBreakdown> contextBreakdown(
    String runtimeSessionId,
  ) async => const DesktopContextBreakdown();

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

class _OpenSttEngine implements SttEngine {
  final StreamController<SttResult> _results =
      StreamController<SttResult>.broadcast();
  int stopCalls = 0;

  @override
  Future<bool> available() async => true;

  @override
  bool get supportsPartials => true;

  @override
  Stream<SttResult> listen({
    String localeId = 'es_ES',
    void Function()? onSpeechEnd,
    void Function()? onCaptureReady,
    bool continuous = false,
  }) {
    onCaptureReady?.call();
    return _results.stream;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {
    if (!_results.isClosed) await _results.close();
  }
}

SavedConnection _connection() => SavedConnection(
  id: 'slash-widget',
  label: 'Slash QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-only',
);

const _session = Session(
  id: 'session-slash-test',
  title: 'Slash test',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 0,
  isActive: true,
  preview: '',
  startedAt: 0,
);

const _acceptedResult = DesktopCommandRpcResult(
  kind: DesktopCommandDispatchKind.none,
  accepted: DesktopCommandAcceptance.accepted,
);
const _rejectedResult = DesktopCommandRpcResult(
  kind: DesktopCommandDispatchKind.none,
  accepted: DesktopCommandAcceptance.rejected,
);
const _directedResult = DesktopCommandRpcResult(
  kind: DesktopCommandDispatchKind.send,
  accepted: DesktopCommandAcceptance.accepted,
  message: 'directed turn',
);
const _syntheticRpcError = TuiGatewayRpcError(
  'slash.exec',
  'synthetic failure',
  code: 5005,
);

ApiClient _safeApi() => ApiClient(
  baseUrl: 'http://127.0.0.1:8642',
  apiKey: 'test-only',
  httpClient: MockClient((_) async => http.Response('not found', 404)),
);

Future<ActiveChat> _pumpSlashChat(
  WidgetTester tester,
  _SlashGateway gateway, {
  _OpenSttEngine? stt,
  bool readOnly = false,
}) async {
  tester.platformDispatcher.localesTestValue = [const Locale('es')];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  SharedPreferences.setMockInitialValues({'onboarding_done': true});
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  final secure = SecureStorage();
  final activeChats = ActiveChatService();
  final connection = _connection().copyWith(readOnly: readOnly);
  final chat = activeChats.attach(
    connection: connection,
    sessionId: _session.id,
    sessionTitle: _session.title,
    initialStoredSessionId: _session.id,
    api: _safeApi(),
    desktopGateway: gateway,
    disableForegroundKeepAlive: true,
  );
  chat
    ..messagesLoaded = false
    ..state = ChatPipelineState.idle;

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
        NotificationService(prefs),
      ),
      sshSessions: SshSessionService(SshManager(secure, manager)),
      notifications: NotificationService(prefs),
      activeChats: activeChats,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 4));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 500));

  if (stt != null) {
    tester
        .state<HermesAppState>(find.byType(HermesApp))
        .voice
        .debugSttFactory = () =>
        stt;
  }

  final navigatorContext = tester.element(find.byType(Navigator).first);
  Navigator.of(navigatorContext).push(
    MaterialPageRoute<void>(
      builder: (_) => ChatScreen(connection: connection, session: _session),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  return chat;
}

HermesTactileAction _sendAction(WidgetTester tester) =>
    tester.widget<HermesTactileAction>(
      find.descendant(
        of: find.byKey(const ValueKey('send')),
        matching: find.byType(HermesTactileAction),
      ),
    );

Future<void> _submitSlash(WidgetTester tester) async {
  _sendAction(tester).onPressed!();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Strings s;
  final secureStore = <String, String>{};
  var foregroundServiceRunning = false;

  setUpAll(() async {
    s = await Strings.delegate.load(const Locale('es'));
  });

  setUp(() {
    secureStore.clear();
    foregroundServiceRunning = false;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                secureStore[args['key'] as String] = args['value'] as String;
              case 'read':
                return secureStore[args['key'] as String];
              case 'delete':
                secureStore.remove(args['key'] as String);
              case 'readAll':
                return Map<String, String>.from(secureStore);
              case 'containsKey':
                return secureStore.containsKey(args['key'] as String);
            }
            return null;
          },
        );
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dexterous.com/flutter/local_notifications'),
          (_) async => null,
        );
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_foreground_task/methods'),
          (call) async {
            switch (call.method) {
              case 'isRunningService':
                return foregroundServiceRunning;
              case 'startService':
              case 'restartService':
                foregroundServiceRunning = true;
              case 'stopService':
                foregroundServiceRunning = false;
              case 'attachedActivity':
                return true;
            }
            return null;
          },
        );
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_foreground_task/background'),
          (_) async => null,
        );
  });

  tearDown(() {
    for (final channel in const [
      'plugins.it_nomads.com/flutter_secure_storage',
      'dexterous.com/flutter/local_notifications',
      'flutter_foreground_task/methods',
      'flutter_foreground_task/background',
    ]) {
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), null);
    }
  });

  group('slashSuggestionsFor', () {
    test('vacío si no empieza por /', () {
      expect(slashSuggestionsFor('hola', s), isEmpty);
    });

    test('todos los comandos con solo /', () {
      expect(slashSuggestionsFor('/', s).length, slashCommands(s).length);
    });

    test('filtra por prefijo', () {
      final r = slashSuggestionsFor('/mo', s);
      expect(r.map((c) => c.name), containsAll(['model', 'models']));
      expect(r.every((c) => c.name.startsWith('mo')), isTrue);
    });

    test('ofrece la compresión manual con tema opcional', () {
      final r = slashSuggestionsFor('/comp', s);
      expect(r.map((c) => c.name), ['compress']);
      expect(r.single.takesArg, isTrue);
      expect(r.map((c) => c.name), isNot(contains('compact')));
    });

    test('sin sugerencias cuando ya hay espacio (escribiendo args)', () {
      expect(slashSuggestionsFor('/model gpt', s), isEmpty);
    });
  });

  group('parseSlashCommand', () {
    test('comando conocido sin argumento', () {
      final p = parseSlashCommand('/new');
      expect(p, isNotNull);
      expect(p!.command.action, SlashAction.newChat);
      expect(p.arg, '');
    });

    test('comando conocido con argumento', () {
      final p = parseSlashCommand('/model gpt-5.5');
      expect(p!.command.name, 'model');
      expect(p.arg, 'gpt-5.5');
    });

    test('comando desconocido queda sin acción local', () {
      expect(parseSlashCommand('/goal terminar el release'), isNull);
      final invocation = parseSlashInvocation('/goal terminar el release');
      expect(invocation?.name, 'goal');
      expect(invocation?.arg, 'terminar el release');
    });

    test('texto normal devuelve null', () {
      expect(parseSlashCommand('hola que tal'), isNull);
    });

    test('case-insensitive en el nombre', () {
      expect(parseSlashCommand('/HELP')!.command.action, SlashAction.help);
    });

    test('/compress ejecuta adapter y /compact termina unavailable local', () {
      final compress = parseSlashCommand('/compress decisiones de release');
      final compact = parseSlashCommand('/compact decisiones de release');

      expect(compress?.command.action, SlashAction.compress);
      expect(compact?.command.action, SlashAction.unavailable);
      expect(compress?.arg, 'decisiones de release');
      expect(compact?.arg, 'decisiones de release');
      expect(isUnavailableSlashName('/compact'), isTrue);
    });
  });

  group('Chat slash palette', () {
    testWidgets(
      '/compress floats above the composer and selection preserves draft focus',
      (tester) async {
        final gateway = _SlashGateway();
        await _pumpSlashChat(tester, gateway);
        final composer = find.byType(TextField).last;

        await tester.enterText(composer, '/comp');
        await tester.pump(const Duration(milliseconds: 250));

        final palette = find.byKey(const ValueKey('chat-slash-palette'));
        final command = find.byKey(
          const ValueKey('chat-slash-command-compress'),
        );
        expect(palette, findsOneWidget);
        expect(command, findsOneWidget);
        expect(
          find.ancestor(
            of: palette,
            matching: find.byType(HermesComposerSurface),
          ),
          findsNothing,
        );
        expect(
          tester.getBottomLeft(palette).dy,
          lessThan(tester.getTopLeft(composer).dy),
        );
        final margin = tester.widget<Container>(palette).margin;
        expect(margin, isA<EdgeInsets>());
        expect((margin! as EdgeInsets).bottom, greaterThanOrEqualTo(8));

        await tester.tap(command);
        await tester.pump();

        final field = tester.widget<TextField>(composer);
        expect(field.controller?.text, '/compress ');
        expect(field.focusNode?.hasFocus, isTrue);
        expect(palette, findsNothing);
        expect(gateway.submissions, isEmpty);
        expect(gateway.slashCalls, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a no-argument slash executes immediately exactly once', (
      tester,
    ) async {
      final gateway = _SlashGateway();
      final completion = Completer<SlashCompletionBatch>();
      gateway.slashCompletion = completion;
      await _pumpSlashChat(tester, gateway);
      final composer = find.byType(TextField).last;

      await tester.enterText(composer, '/he');
      await tester.pump(const Duration(milliseconds: 250));
      expect(gateway.slashCompletionCalls, 1);
      final help = find.byKey(const ValueKey('chat-slash-command-help'));
      expect(help, findsOneWidget);

      await tester.tap(help);
      completion.complete(
        SlashCompletionBatch.fromJson(const {
          'items': <Object>[
            {'replacement': '/remote-late', 'meta': 'late'},
          ],
        }, input: '/he'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));

      expect(
        find.byKey(const ValueKey('chat-slash-help-dialog')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('chat-slash-palette')), findsNothing);
      expect(gateway.submissions, isEmpty);
      expect(gateway.slashCalls, isEmpty);

      Navigator.of(
        tester.element(find.byKey(const ValueKey('chat-slash-help-dialog'))),
      ).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));

      final field = tester.widget<TextField>(composer);
      expect(field.controller?.text, isEmpty);
      expect(field.focusNode?.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a navigation slash consumes once and opens its route', (
      tester,
    ) async {
      final gateway = _SlashGateway();
      await _pumpSlashChat(tester, gateway);
      final composer = find.byType(TextField).last;
      final controller = tester.widget<TextField>(composer).controller!;
      await tester.enterText(composer, '/ski');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const ValueKey('chat-slash-command-skills')));
      await tester.pumpAndSettle();
      expect(find.byType(SkillsScreen), findsOneWidget);
      expect(controller.text, isEmpty);
      expect(gateway.submissions, isEmpty);
      expect(gateway.slashCalls, isEmpty);
    });

    testWidgets(
      '/model clears composer and restores focus after selector closes',
      (tester) async {
        final gateway = _SlashGateway();
        await _pumpSlashChat(tester, gateway);
        final composer = find.byType(TextField).last;

        await tester.tap(composer);
        await tester.enterText(composer, '/model ');
        await tester.pump(const Duration(milliseconds: 250));
        final fieldBeforeSubmit = tester.widget<TextField>(composer);
        expect(fieldBeforeSubmit.controller?.text, '/model ');
        final sendAction = find.descendant(
          of: find.byKey(const ValueKey('send')),
          matching: find.byType(HermesTactileAction),
        );
        final onPressed = tester
            .widget<HermesTactileAction>(sendAction)
            .onPressed;
        expect(onPressed, isNotNull);
        onPressed!();
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));
        expect(fieldBeforeSubmit.controller?.text, isEmpty);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('chat-model-dialog')), findsOneWidget);
        expect(fieldBeforeSubmit.controller?.text, isEmpty);
        expect(find.byKey(const ValueKey('chat-slash-palette')), findsNothing);
        expect(gateway.submissions, isEmpty);
        expect(gateway.slashCalls, isEmpty);
        Navigator.of(
          tester.element(find.byKey(const ValueKey('chat-model-dialog'))),
        ).pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));

        expect(fieldBeforeSubmit.controller?.text, isEmpty);
        expect(fieldBeforeSubmit.focusNode?.hasFocus, isTrue);
        expect(gateway.submissions, isEmpty);
        expect(gateway.slashCalls, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '/model with an unmatched argument restores focus after lookup',
      (tester) async {
        final gateway = _SlashGateway();
        await _pumpSlashChat(tester, gateway);
        final composer = find.byType(TextField).last;

        await tester.tap(composer);
        await tester.enterText(composer, '/model definitely-not-a-model');
        await tester.pump(const Duration(milliseconds: 250));
        final field = tester.widget<TextField>(composer);
        final sendAction = find.descendant(
          of: find.byKey(const ValueKey('send')),
          matching: find.byType(HermesTactileAction),
        );
        final onPressed = tester
            .widget<HermesTactileAction>(sendAction)
            .onPressed;
        expect(onPressed, isNotNull);

        onPressed!();
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));

        expect(field.controller?.text, isEmpty);
        expect(find.byKey(const ValueKey('chat-model-dialog')), findsOneWidget);
        expect(gateway.submissions, isEmpty);
        expect(gateway.slashCalls, isEmpty);

        Navigator.of(
          tester.element(find.byKey(const ValueKey('chat-model-dialog'))),
        ).pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));

        expect(field.focusNode?.hasFocus, isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('/model preserves rejection and accepted retry clears once', (
      tester,
    ) async {
      final gateway = _SlashGateway()
        ..modelError = const TuiGatewayRpcError(
          'config.set',
          'rejected',
          code: 5001,
        );
      await _pumpSlashChat(tester, gateway);
      final composer = find.byType(TextField).last;

      await tester.tap(composer);
      await tester.enterText(composer, '/model bad-model');
      await tester.pump(const Duration(milliseconds: 250));
      final field = tester.widget<TextField>(composer);
      var composerChanges = 0;
      field.controller!.addListener(() => composerChanges++);
      final sendAction = find.descendant(
        of: find.byKey(const ValueKey('send')),
        matching: find.byType(HermesTactileAction),
      );

      tester.widget<HermesTactileAction>(sendAction).onPressed!();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));

      expect(gateway.modelSelections.single.modelId, 'bad-model');
      expect(field.controller?.text, '/model bad-model');
      expect(field.focusNode?.hasFocus, isTrue);
      expect(composerChanges, 0);
      expect(gateway.submissions, isEmpty);

      gateway.modelError = null;
      tester.widget<HermesTactileAction>(sendAction).onPressed!();
      await tester.pump(const Duration(milliseconds: 500));

      expect(gateway.modelSelections, hasLength(2));
      expect(field.controller?.text, isEmpty);
      expect(composerChanges, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'an unavailable slash preserves invocation and composer focus',
      (tester) async {
        final gateway = _SlashGateway();
        await _pumpSlashChat(tester, gateway);
        final composer = find.byType(TextField).last;

        await tester.tap(composer);
        await tester.enterText(composer, '/compact');
        await tester.pump(const Duration(milliseconds: 250));
        final field = tester.widget<TextField>(composer);
        final sendAction = find.descendant(
          of: find.byKey(const ValueKey('send')),
          matching: find.byType(HermesTactileAction),
        );
        final onPressed = tester
            .widget<HermesTactileAction>(sendAction)
            .onPressed;
        expect(onPressed, isNotNull);

        onPressed!();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));

        expect(field.controller?.text, '/compact');
        expect(field.focusNode?.hasFocus, isTrue);
        expect(gateway.submissions, isEmpty);
        expect(gateway.slashCalls, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('/compress rejection preserves invocation and composer focus', (
      tester,
    ) async {
      final gateway = _SlashGateway()..slashResult = _rejectedResult;
      await _pumpSlashChat(tester, gateway);
      final composer = find.byType(TextField).last;
      await tester.tap(composer);
      await tester.enterText(composer, '/compress release decisions');
      await tester.pump(const Duration(milliseconds: 250));
      final field = tester.widget<TextField>(composer);
      await _submitSlash(tester);
      expect(gateway.slashCalls, ['compress release decisions']);
      expect(field.controller?.text, '/compress release decisions');
      expect(field.focusNode?.hasFocus, isTrue);
      gateway.slashResult = _acceptedResult;
      await _submitSlash(tester);
      expect(gateway.slashCalls, hasLength(2));
      expect(field.controller?.text, isEmpty);
      gateway
        ..slashError = _syntheticRpcError
        ..dispatchError = _syntheticRpcError;
      await tester.enterText(composer, '/compress retry me');
      await tester.pump(const Duration(milliseconds: 250));
      await _submitSlash(tester);
      expect(field.controller?.text, '/compress retry me');
    });

    testWidgets('/compress without runtime preserves invocation', (
      tester,
    ) async {
      final gateway = _SlashGateway()
        ..resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'missing runtime',
          code: 4007,
        );
      await _pumpSlashChat(tester, gateway);
      final composer = find.byType(TextField).last;
      await tester.enterText(composer, '/compress no runtime');
      await tester.pump(const Duration(milliseconds: 250));
      await _submitSlash(tester);
      expect(
        tester.widget<TextField>(composer).controller?.text,
        '/compress no runtime',
      );
      expect(gateway.slashCalls, isEmpty);
    });

    testWidgets('/compress accepted late preserves a newer draft', (
      tester,
    ) async {
      final gate = Completer<DesktopCommandRpcResult>();
      final gateway = _SlashGateway()..slashGate = gate;
      await _pumpSlashChat(tester, gateway);
      final composer = find.byType(TextField).last;
      await tester.enterText(composer, '/compress first');
      await tester.pump(const Duration(milliseconds: 250));
      _sendAction(tester).onPressed!();
      await tester.pump();
      tester.widget<TextField>(composer).controller!.text = 'new draft';
      gate.complete(_acceptedResult);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.widget<TextField>(composer).controller?.text, 'new draft');
      expect(gateway.slashCalls, ['compress first']);
    });

    testWidgets('read-only exposes no slash submission surface or RPC', (
      tester,
    ) async {
      final gateway = _SlashGateway();
      await _pumpSlashChat(tester, gateway, readOnly: true);

      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('late directed remote slash preserves a newer draft', (
      tester,
    ) async {
      final gate = Completer<DesktopCommandRpcResult>();
      final gateway = _SlashGateway()..slashGate = gate;
      final chat = await _pumpSlashChat(tester, gateway);
      final composer = find.byType(TextField).last;

      await tester.enterText(composer, '/goal first');
      await tester.pump(const Duration(milliseconds: 250));
      final sendAction = _sendAction(tester);
      sendAction.onPressed!();
      sendAction.onPressed!();
      await tester.pump();
      expect(gateway.slashCalls, ['goal first']);

      await tester.enterText(composer, 'new draft');
      chat.state = ChatPipelineState.streaming;
      await tester.pump();
      gate.complete(_directedResult);
      await tester.pump(const Duration(milliseconds: 500));

      final field = tester.widget<TextField>(composer);
      expect(field.controller?.text, 'new draft');
      expect(field.focusNode?.hasFocus, isTrue);

      gateway
        ..slashGate = null
        ..slashResult = _rejectedResult;
      await tester.enterText(composer, '/goal rejected');
      await tester.pump(const Duration(milliseconds: 250));
      await _submitSlash(tester);
      expect(field.controller?.text, '/goal rejected');

      gateway.slashError = _syntheticRpcError;
      await tester.enterText(composer, '/goal errors');
      await tester.pump(const Duration(milliseconds: 250));
      await _submitSlash(tester);
      expect(field.controller?.text, '/goal errors');

      final idleGate = Completer<DesktopCommandRpcResult>();
      gateway
        ..slashError = null
        ..slashGate = idleGate
        ..submitError = StateError('prompt rejected before acceptance');
      chat.state = ChatPipelineState.idle;
      await tester.enterText(composer, '/goal idle');
      await tester.pump(const Duration(milliseconds: 250));
      sendAction.onPressed!();
      await tester.pump();
      await tester.enterText(composer, '@worker newer draft');
      await tester.pump(const Duration(milliseconds: 400));
      idleGate.complete(_directedResult);
      await tester.pump(const Duration(milliseconds: 800));

      final prefs = await SharedPreferences.getInstance();
      final restored = await ChatDraftStore(
        prefs,
      ).load(_connection().id, _session.id);
      expect(restored.text, '@worker newer draft');
      expect(gateway.submissions, ['directed turn', 'directed turn']);
      expect(gateway.slashCalls, hasLength(4));
    });

    testWidgets('recording and transcribing hide slash suggestions', (
      tester,
    ) async {
      final gateway = _SlashGateway();
      final stt = _OpenSttEngine();
      await _pumpSlashChat(tester, gateway, stt: stt);
      final composer = find.byType(TextField).last;

      await tester.enterText(composer, '/comp');
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const ValueKey('chat-slash-palette')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('mic')));
      await tester.pump();
      expect(find.byKey(const ValueKey('recording')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-slash-palette')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('recording')));
      await tester.pump();
      expect(stt.stopCalls, 1);
      expect(find.byKey(const ValueKey('chat-slash-palette')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('slash palette fits 320dp at text scale 2 without overflow', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(320, 760)
        ..devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final gateway = _SlashGateway();
      await _pumpSlashChat(tester, gateway);

      await tester.enterText(find.byType(TextField).last, '/');
      await tester.pump(const Duration(milliseconds: 250));

      final palette = find.byKey(const ValueKey('chat-slash-palette'));
      expect(palette, findsOneWidget);
      expect(tester.getSize(palette).width, lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
    });
  });
}
