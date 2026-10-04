import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_screen.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/command_descriptor.dart';
import 'package:hermes_android/core/models/composer_reference.dart';
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
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/compression_restore_store.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/utils/slash_commands.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
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

  void emit(String type, [Map<String, dynamic>? payload]) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: 'runtime-slash-test',
        payload: payload ?? const {},
      ),
    );
  }

  final List<String> submissions = [];
  final List<String> slashCalls = [];
  Completer<SlashCompletionBatch>? slashCompletion;
  SlashCompletionBatch Function(String text)? slashResponder;
  // Per-query gates: answers can be released in any order (stale replies).
  final Map<String, Completer<SlashCompletionBatch>> slashGates = {};
  final List<Map<String, String>> dispatchCalls = [];
  // Like Hermes: command.dispatch refuses anything that is not a quick,
  // plugin, bundle or skill command.
  DesktopCommandRpcResult? dispatchResult;
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
      messagesProvided: true,
      messageCount: 0,
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
    String? requestId,
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
    if (slashGates[text] case final gate?) return gate.future;
    if (slashResponder case final respond?) return respond(text);
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
    dispatchCalls.add({'name': name, 'arg': arg});
    if (dispatchError case final error?) throw error;
    if (dispatchResult case final result?) return result;
    throw TuiGatewayRpcError(
      'command.dispatch',
      'not a quick/plugin/bundle/skill command: $name',
      code: 4018,
    );
  }

  @override
  Future<DesktopModelCatalog> modelOptions(
    String runtimeSessionId, {
    bool refresh = false,
    bool connectedOnly = false,
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

class _ReferenceGateway extends _SlashGateway
    implements HermesDesktopComposerCompletionGateway {
  final List<Map<String, String>> pathCalls = [];
  final Map<String, Completer<PathCompletionBatch>> pathGates = {};
  // Scope each complete.slash carried: runtime or new-chat profile.
  final List<Map<String, String?>> slashScopes = [];

  @override
  Future<SlashCompletionBatch> completeSlashInSession(
    String text, {
    String? runtimeSessionId,
    String? profile,
  }) {
    slashScopes.add({
      'text': text,
      'session_id': runtimeSessionId,
      'profile': profile,
    });
    return completeSlash(text);
  }

  @override
  Future<PathCompletionBatch> completePath(
    String word, {
    required String runtimeSessionId,
  }) async {
    pathCalls.add({'word': word, 'session_id': runtimeSessionId});
    if (pathGates[word] case final gate?) return gate.future;
    if (word == '@') {
      return PathCompletionBatch.fromJson({
        'items': [
          {'text': '@diff', 'meta': 'git diff'},
          {'text': '@file:', 'meta': 'attach file'},
          {'text': '@folder:', 'meta': 'attach folder'},
          {'text': '@url:', 'meta': 'fetch url'},
          {'text': '@alice', 'meta': 'agent profile'},
        ],
      });
    }
    return PathCompletionBatch.fromJson({
      'items': [
        {'text': '@folder:lib/core/', 'display': 'core/', 'meta': 'dir'},
        {'text': '@file:lib/main.dart', 'display': 'main.dart', 'meta': 'lib'},
      ],
    });
  }
}

class _GatedCompressionStorage implements CompressionRestoreStorage {
  String? value;
  Completer<void>? readEntered;
  Completer<void>? releaseRead;

  void gateNextRead() {
    readEntered = Completer<void>();
    releaseRead = Completer<void>();
  }

  @override
  Future<String?> read() async {
    final entered = readEntered;
    final release = releaseRead;
    if (entered != null && release != null) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
      if (identical(releaseRead, release)) {
        readEntered = null;
        releaseRead = null;
      }
    }
    return value;
  }

  @override
  Future<void> write(String next) async {
    value = next;
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
  bool bindInitialStoredSession = true,
  CompressionRestoreStore? compressionRestoreStore,
  String? sessionProfile,
  bool? attachDesktopRuntimeOnLoad,
}) async {
  final session = sessionProfile == null
      ? _session
      : _session.copyWith(profile: sessionProfile);
  tester.platformDispatcher.localesTestValue = [const Locale('es')];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  final secure = SecureStorage();
  final activeChats = ActiveChatService(
    compressionRestoreStore: compressionRestoreStore,
  );
  final connection = _connection().copyWith(readOnly: readOnly);
  final chat = activeChats.attach(
    connection: connection,
    sessionId: _session.id,
    sessionTitle: _session.title,
    sessionProfile: sessionProfile,
    initialStoredSessionId: bindInitialStoredSession ? _session.id : null,
    api: _safeApi(),
    desktopGateway: gateway,
    attachDesktopRuntimeOnLoad: attachDesktopRuntimeOnLoad,
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
      builder: (_) => ChatScreen(connection: connection, session: session),
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
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
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

    test(
      '/ compress is invalid while /compress is routed before busy files',
      () {
        expect(parseSlashCommand('/ compress'), isNull);
        expect(
          shouldRouteSlashBeforeBusyAttachmentQueue(
            '/compress keep this draft',
          ),
          isTrue,
        );
        expect(
          shouldRouteSlashBeforeBusyAttachmentQueue(
            '/ compress keep this draft',
          ),
          isTrue,
        );
      },
    );
  });

  group('Chat @ references', () {
    testWidgets('@ lists Desktop starters and inserts the Desktop wire form', (
      tester,
    ) async {
      final gateway = _ReferenceGateway();
      final chat = await _pumpSlashChat(tester, gateway);
      expect(chat.desktopRuntimeSessionId, isNotNull);
      final composer = find.byType(TextField).last;
      await tester.tap(composer);
      await tester.pump(const Duration(milliseconds: 250));

      await tester.enterText(composer, 'mira @');
      await tester.pump(const Duration(milliseconds: 300));
      expect(gateway.pathCalls.single, {
        'word': '@',
        'session_id': chat.desktopRuntimeSessionId!,
      });
      expect(
        find.byKey(const ValueKey('chat-reference-palette')),
        findsOneWidget,
      );
      // Profiles belong to the mention palette; @diff is not offered.
      expect(find.byKey(const ValueKey('chat-reference-@diff:')), findsNothing);
      expect(find.text('@alice'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('chat-reference-@file:')));
      await tester.pump();
      final field = tester.widget<TextField>(composer);
      expect(field.controller!.text, 'mira @file:');
      await tester.pump(const Duration(milliseconds: 300));
      expect(gateway.pathCalls.last['word'], '@file:');

      await tester.tap(
        find.byKey(const ValueKey('chat-reference-@file:lib/main.dart')),
      );
      await tester.pump();
      expect(field.controller!.text, 'mira @file:`lib/main.dart` ');
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('chat-reference-palette')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a folder opens in place and a fast burst sends one lookup', (
      tester,
    ) async {
      final gateway = _ReferenceGateway();
      await _pumpSlashChat(tester, gateway);
      final composer = find.byType(TextField).last;
      await tester.tap(composer);
      await tester.pump(const Duration(milliseconds: 250));

      const typed = '@lib/mainx';
      for (var index = 1; index <= typed.length; index++) {
        await tester.enterText(composer, typed.substring(0, index));
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.pump(const Duration(milliseconds: 300));
      expect(gateway.pathCalls, hasLength(1));
      expect(gateway.pathCalls.single['word'], typed);

      await tester.tap(
        find.byKey(const ValueKey('chat-reference-open-@folder:lib/core/')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<TextField>(composer).controller!.text, '@lib/core/');
      expect(gateway.pathCalls.last['word'], '@lib/core/');

      // Closing the palette (blur) cancels the pending lookup.
      final calls = gateway.pathCalls.length;
      await tester.enterText(composer, '@lib/core/x');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 400));
      expect(gateway.pathCalls, hasLength(calls));
      expect(
        find.byKey(const ValueKey('chat-reference-palette')),
        findsNothing,
      );
    });

    testWidgets('a late @ answer never overwrites a newer query', (
      tester,
    ) async {
      final gateway = _ReferenceGateway();
      final older = gateway.pathGates['@lib/a'] =
          Completer<PathCompletionBatch>();
      final newer = gateway.pathGates['@lib/ab'] =
          Completer<PathCompletionBatch>();
      await _pumpSlashChat(tester, gateway);
      final composer = find.byType(TextField).last;
      await tester.tap(composer);
      await tester.pump(const Duration(milliseconds: 250));

      await tester.enterText(composer, '@lib/a');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(composer, '@lib/ab');
      await tester.pump(const Duration(milliseconds: 300));
      expect(gateway.pathCalls.map((call) => call['word']), [
        '@lib/a',
        '@lib/ab',
      ]);

      newer.complete(
        PathCompletionBatch.fromJson(const {
          'items': [
            {'text': '@file:lib/ab.dart', 'display': 'ab.dart'},
          ],
        }),
      );
      await tester.pump();
      older.complete(
        PathCompletionBatch.fromJson(const {
          'items': [
            {'text': '@file:lib/a_stale.dart', 'display': 'a_stale.dart'},
          ],
        }),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.byKey(const ValueKey('chat-reference-@file:lib/ab.dart')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('chat-reference-@file:lib/a_stale.dart')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a gateway without complete.path shows no @ palette', (
      tester,
    ) async {
      final gateway = _SlashGateway();
      await _pumpSlashChat(tester, gateway);
      final composer = find.byType(TextField).last;
      await tester.tap(composer);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(composer, '@lib/');
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('chat-reference-palette')),
        findsNothing,
      );
    });
  });

  group('Chat slash palette', () {
    testWidgets(
      '/compress floats above the composer and selection preserves draft focus',
      (tester) async {
        final gateway = _SlashGateway();
        await _pumpSlashChat(tester, gateway);
        final composer = find.byType(TextField).last;
        final host = find.byKey(const ValueKey('chat-composer-host'));

        await tester.tap(composer);
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.widget<TextField>(composer).focusNode?.hasFocus, isTrue);
        final heightBeforePalette = tester.getSize(host).height;
        await tester.enterText(composer, '/comp');
        await tester.pump(const Duration(milliseconds: 250));

        final palette = find.byKey(const ValueKey('chat-slash-palette'));
        final command = find.byKey(
          const ValueKey('chat-slash-command-compress'),
        );
        expect(palette, findsOneWidget);
        expect(command, findsOneWidget);
        expect(tester.getSize(host).height, closeTo(heightBeforePalette, 1));
        expect(tester.widget<TextField>(composer).focusNode?.hasFocus, isTrue);
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

    testWidgets('server skills appear grouped with their descriptions', (
      tester,
    ) async {
      final gateway = _SlashGateway()
        ..slashResponder = (text) => SlashCompletionBatch.fromJson({
          'replace_from': 1,
          'items': [
            {'text': '/goal', 'meta': 'Run a goal', 'kind': 'command'},
            {'text': '/review-pr', 'meta': 'Review a PR', 'kind': 'skill'},
          ],
        }, input: text);
      await _pumpSlashChat(tester, gateway);
      final composer = find.byType(TextField).last;

      await tester.tap(composer);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(composer, '/');
      await tester.pump(const Duration(milliseconds: 250));

      expect(gateway.slashCompletionCalls, 1);
      final skill = find.byKey(const ValueKey('chat-slash-command-review-pr'));
      await tester.scrollUntilVisible(
        skill,
        80,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('chat-slash-palette')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(skill, findsOneWidget);
      expect(find.text('Review a PR'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('chat-slash-skills-header')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('chat-slash-command-goal')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a fast keystroke burst sends one completion; blur cancels', (
      tester,
    ) async {
      final gateway = _SlashGateway();
      await _pumpSlashChat(tester, gateway);
      final composer = find.byType(TextField).last;
      await tester.tap(composer);
      await tester.pump(const Duration(milliseconds: 250));
      final before = gateway.slashCompletionCalls;

      const typed = '/abcdefghi';
      for (var index = 1; index <= typed.length; index++) {
        await tester.enterText(composer, typed.substring(0, index));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(gateway.slashCompletionCalls - before, 1);

      final afterBurst = gateway.slashCompletionCalls;
      await tester.enterText(composer, '/zz');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 400));
      expect(gateway.slashCompletionCalls, afterBurst);
      expect(find.byKey(const ValueKey('chat-slash-palette')), findsNothing);
    });

    testWidgets('a new chat scopes / to its profile, not the default one', (
      tester,
    ) async {
      final gateway = _ReferenceGateway();
      final chat = await _pumpSlashChat(
        tester,
        gateway,
        bindInitialStoredSession: false,
        attachDesktopRuntimeOnLoad: false,
        sessionProfile: 'work',
      );
      expect(chat.desktopRuntimeSessionId, isNull);
      final composer = find.byType(TextField).last;
      await tester.tap(composer);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(composer, '/rev');
      await tester.pump(const Duration(milliseconds: 300));

      expect(gateway.slashScopes, [
        {'text': '/rev', 'session_id': null, 'profile': 'work'},
      ]);
    });

    testWidgets('a cached slash answer never crosses a runtime rotation', (
      tester,
    ) async {
      final gateway = _ReferenceGateway()
        ..slashResponder = (text) => SlashCompletionBatch.fromJson({
          'replace_from': 1,
          'items': [
            {'text': '/review-a', 'meta': 'Runtime A only', 'kind': 'skill'},
          ],
        }, input: text);
      final chat = await _pumpSlashChat(tester, gateway);
      final runtimeA = chat.desktopRuntimeSessionId!;
      final composer = find.byType(TextField).last;
      await tester.tap(composer);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(composer, '/rev');
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('chat-slash-command-review-a')),
        findsOneWidget,
      );

      // The runtime rotates while the same query is typed again: B is asked
      // and A's memoised answer is never repainted.
      final runtimeB = '$runtimeA-rotated';
      gateway.slashResponder = (text) => SlashCompletionBatch.fromJson({
        'replace_from': 1,
        'items': [
          {'text': '/review-b', 'meta': 'Runtime B', 'kind': 'skill'},
        ],
      }, input: text);
      chat.adoptDesktopRuntimeForTesting(runtimeB);
      await tester.enterText(composer, '/re');
      await tester.pump();
      await tester.enterText(composer, '/rev');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('chat-slash-command-review-a')),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(gateway.slashScopes.last, {
        'text': '/rev',
        'session_id': runtimeB,
        'profile': null,
      });
      expect(
        find.byKey(const ValueKey('chat-slash-command-review-b')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('chat-slash-command-review-a')),
        findsNothing,
      );
    });

    testWidgets('an in-flight slash answer from a retired runtime is dropped', (
      tester,
    ) async {
      final gateway = _ReferenceGateway();
      final late = gateway.slashGates['/rev'] =
          Completer<SlashCompletionBatch>();
      final chat = await _pumpSlashChat(tester, gateway);
      final composer = find.byType(TextField).last;
      await tester.tap(composer);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(composer, '/rev');
      await tester.pump(const Duration(milliseconds: 300));
      expect(gateway.slashScopes, hasLength(1));

      chat.adoptDesktopRuntimeForTesting(
        '${chat.desktopRuntimeSessionId}-rotated',
      );
      late.complete(
        SlashCompletionBatch.fromJson(const {
          'replace_from': 1,
          'items': [
            {'text': '/stale-a', 'meta': 'Runtime A', 'kind': 'skill'},
          ],
        }, input: '/rev'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byKey(const ValueKey('chat-slash-command-stale-a')),
        findsNothing,
      );
    });

    testWidgets('a late slash answer never overwrites a newer query', (
      tester,
    ) async {
      final gateway = _SlashGateway();
      final older = gateway.slashGates['/re'] =
          Completer<SlashCompletionBatch>();
      final newer = gateway.slashGates['/rev'] =
          Completer<SlashCompletionBatch>();
      await _pumpSlashChat(tester, gateway);
      final composer = find.byType(TextField).last;
      await tester.tap(composer);
      await tester.pump(const Duration(milliseconds: 250));

      await tester.enterText(composer, '/re');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(composer, '/rev');
      await tester.pump(const Duration(milliseconds: 300));
      expect(gateway.slashCompletionCalls, 2);

      newer.complete(
        SlashCompletionBatch.fromJson(const {
          'replace_from': 1,
          'items': [
            {'text': '/review-pr', 'meta': 'Review a PR', 'kind': 'skill'},
          ],
        }, input: '/rev'),
      );
      await tester.pump();
      older.complete(
        SlashCompletionBatch.fromJson(const {
          'replace_from': 1,
          'items': [
            {'text': '/reset-stale', 'meta': 'stale', 'kind': 'command'},
          ],
        }, input: '/re'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.byKey(const ValueKey('chat-slash-command-review-pr')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('chat-slash-command-reset-stale')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a skill falls back to command.dispatch and sends its body', (
      tester,
    ) async {
      final gateway = _SlashGateway()
        ..slashResponder = ((text) => SlashCompletionBatch.fromJson(const {
          'replace_from': 1,
          'items': [
            {'text': '/review-pr', 'meta': 'Review a PR', 'kind': 'skill'},
          ],
        }, input: text))
        ..slashError = const TuiGatewayRpcError(
          'slash.exec',
          'skill command: use command.dispatch for /review-pr',
          code: 4018,
        )
        ..dispatchResult = DesktopCommandRpcResult.fromJson(const {
          'type': 'skill',
          'name': 'review-pr',
          'message': 'Skill body for PR 12',
        });
      await _pumpSlashChat(tester, gateway);
      final composer = find.byType(TextField).last;
      await tester.tap(composer);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(composer, '/rev');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(composer, '/review-pr 12');
      await tester.pump(const Duration(milliseconds: 300));
      await _submitSlash(tester);

      // Desktop slash.ts: slash.exec first, command.dispatch {name, arg}
      // on its error, then the skill body goes out as the next turn.
      expect(gateway.slashCalls, ['review-pr 12']);
      expect(gateway.dispatchCalls, [
        {'name': 'review-pr', 'arg': '12'},
      ]);
      expect(gateway.submissions, ['Skill body for PR 12']);
      expect(tester.widget<TextField>(composer).controller?.text, isEmpty);
      gateway.emit('message.complete', {'text': 'ok'});
      await tester.pump(const Duration(milliseconds: 350));
    });

    testWidgets('a failed slash.exec keeps its own error over the fallback', (
      tester,
    ) async {
      final gateway = _SlashGateway()
        ..slashError = const TuiGatewayRpcError(
          'slash.exec',
          'worker timeout',
          code: 5030,
        );
      await _pumpSlashChat(tester, gateway);
      final composer = find.byType(TextField).last;
      await tester.tap(composer);
      await tester.enterText(composer, '/goal algo');
      await tester.pump(const Duration(milliseconds: 250));
      await _submitSlash(tester);

      expect(gateway.dispatchCalls, [
        {'name': 'goal', 'arg': 'algo'},
      ]);
      expect(gateway.submissions, isEmpty);
      expect(tester.widget<TextField>(composer).controller?.text, '/goal algo');
    });

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

    testWidgets('navigation slash opens route once', (tester) async {
      final gateway = _SlashGateway();
      await _pumpSlashChat(tester, gateway);
      final composer = find.byType(TextField).last;
      final controller = tester.widget<TextField>(composer).controller!;
      await tester.enterText(composer, '/ski');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const ValueKey('chat-slash-command-skills')));
      await tester.pumpAndSettle();
      expect(find.byType(CapabilitiesHub), findsOneWidget);
      expect(find.byType(SkillsScreen), findsNothing);
      expect(controller.text, isEmpty);
      expect(gateway.submissions, isEmpty);
      expect(gateway.slashCalls, isEmpty);
    });

    testWidgets('typed /skills opens the capabilities hub without sending', (
      tester,
    ) async {
      final gateway = _SlashGateway();
      await _pumpSlashChat(tester, gateway);
      final composer = find.byType(TextField).last;
      final controller = tester.widget<TextField>(composer).controller!;
      await tester.enterText(composer, '/Skills  ');
      await tester.pump(const Duration(milliseconds: 250));
      await _submitSlash(tester);
      await tester.pumpAndSettle();

      expect(find.byType(CapabilitiesHub), findsOneWidget);
      final hub = tester.widget<CapabilitiesHub>(find.byType(CapabilitiesHub));
      expect(hub.connection.id, _connection().id);
      expect(hub.advancedBuilder, isNotNull);
      expect(hub.classicSkillsBuilder, isNotNull);
      expect(find.byType(SkillsScreen), findsNothing);
      expect(controller.text, isEmpty);
      expect(gateway.submissions, isEmpty);
      expect(gateway.slashCalls, isEmpty);

      // Exactly one route was pushed: closing the hub returns to the chat.
      Navigator.of(tester.element(find.byType(CapabilitiesHub))).pop();
      await tester.pumpAndSettle();
      final chatRoute = ModalRoute.of(tester.element(find.byType(ChatScreen)));
      expect(chatRoute?.isCurrent, isTrue);
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

    testWidgets('busy ejecuta slash remoto sin encolar ni redirigir', (
      tester,
    ) async {
      final gateway = _SlashGateway();
      final chat = await _pumpSlashChat(tester, gateway);

      expect(
        await chat.send(
          fullText: 'turno vivo',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      final composer = find.byType(TextField).last;
      await tester.tap(composer);
      await tester.enterText(composer, '/goal corregir ahora');
      await tester.pump(const Duration(milliseconds: 250));
      await _submitSlash(tester);

      expect(gateway.slashCalls, ['goal corregir ahora']);
      expect(gateway.submissions, ['turno vivo']);
      expect(chat.queuedMessages, isEmpty);
      expect(tester.widget<TextField>(composer).controller?.text, isEmpty);
      expect(tester.takeException(), isNull);

      gateway.emit('message.complete', {'text': 'listo'});
      await tester.pump(const Duration(milliseconds: 350));
    });

    testWidgets(
      'busy /compress with attachment preserves exact editable batch and does zero RPC',
      (tester) async {
        final gateway = _SlashGateway();
        final temp = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('compress-file-draft-'),
        ))!;
        addTearDown(() async {
          if (await temp.exists()) await temp.delete(recursive: true);
        });
        final file = (await tester.runAsync(() async {
          final value = File('${temp.path}/evidence.txt');
          await value.writeAsString('safe');
          return value;
        }))!;
        final attachment = AttachmentDraft(
          localId: 'compress-file',
          type: AttachmentType.document,
          name: 'evidence.txt',
          mimeType: 'text/plain',
          sizeBytes: file.lengthSync(),
          localPath: file.path,
        );
        String scope(String value) =>
            base64Url.encode(utf8.encode(value)).replaceAll('=', '');
        secureStore['chat_draft_v3.${scope('slash-widget')}.${scope('default')}.${scope(_session.id)}'] =
            jsonEncode({
              'savedAt': DateTime.now().millisecondsSinceEpoch,
              'text': '/compress keep exact',
              'attachments': [attachment.toJson()],
            });

        final chat = await _pumpSlashChat(tester, gateway);
        expect(
          await chat.send(
            fullText: 'turno vivo',
            model: 'hermes-agent',
            history: const [],
          ),
          isTrue,
        );
        await tester.pump(const Duration(milliseconds: 400));
        final composer = find.byType(TextField).last;
        final field = tester.widget<TextField>(composer);
        expect(field.controller?.text, '/compress keep exact');

        await _submitSlash(tester);

        expect(field.controller?.text, '/compress keep exact');
        expect(find.textContaining('evidence.txt'), findsWidgets);
        expect(chat.queuedMessages, isEmpty);
        expect(gateway.slashCalls, isEmpty);
        expect(gateway.submissions, ['turno vivo']);
        expect(tester.takeException(), isNull);
        gateway.emit('message.complete', {'text': 'listo'});
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );

    testWidgets('/model with an argument gives feedback without a runtime', (
      tester,
    ) async {
      final gateway = _SlashGateway()..resumeExistingError = _syntheticRpcError;
      final chat = await _pumpSlashChat(tester, gateway);
      // The stored session is gone, so no runtime can be acquired:
      // ensureDesktopRuntime answers false instead of throwing.
      chat.markStoredSessionGone();
      expect(
        await chat.ensureDesktopRuntime(acquireForExplicitAction: true),
        isFalse,
      );
      final composer = find.byType(TextField).last;

      await tester.tap(composer);
      await tester.enterText(composer, '/model bad-model');
      await tester.pump(const Duration(milliseconds: 250));
      final field = tester.widget<TextField>(composer);

      await _submitSlash(tester);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 240));

      final sheetOpened = find
          .byKey(const ValueKey('chat-model-dialog'))
          .evaluate()
          .isNotEmpty;
      final noticeShown = find.byType(SnackBar).evaluate().isNotEmpty;
      expect(
        sheetOpened || noticeShown,
        isTrue,
        reason: 'the command must not be silently dropped',
      );
      expect(gateway.submissions, isEmpty);
      expect(field.controller?.text, isNot('/model bad-model'));
    });

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

    testWidgets(
      'REGRESSION_COMP2A /compress invalidation is not dispatched or replayed',
      (tester) async {
        final gateway = _SlashGateway();
        final storage = _GatedCompressionStorage();
        final chat = await _pumpSlashChat(
          tester,
          gateway,
          compressionRestoreStore: CompressionRestoreStore(
            storage: storage,
            mutationNamespaceForTesting: 'comp2a-authority-widget',
          ),
        );
        final composer = find.byType(TextField).last;
        await tester.tap(composer);
        await tester.enterText(composer, '/compress authority target');
        await tester.pump(const Duration(milliseconds: 250));
        final field = tester.widget<TextField>(composer);

        storage.gateNextRead();
        _sendAction(tester).onPressed!();
        await tester.pump();
        await storage.readEntered!.future;
        chat.invalidatePassiveRead();
        storage.releaseRead!.complete();
        await tester.pump(const Duration(milliseconds: 500));

        expect(gateway.slashCalls, isEmpty);
        expect(gateway.submissions, isEmpty);
        expect(field.controller?.text, '/compress authority target');

        // Only a second explicit gesture creates fresh authority.
        await tester.tap(composer);
        await tester.pump();
        await _submitSlash(tester);
        expect(gateway.slashCalls, ['compress authority target']);
        expect(gateway.submissions, isEmpty);
        expect(field.controller?.text, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('/compress preserves rejected invocation', (tester) async {
      final gateway = _SlashGateway()
        ..slashResult = DesktopCommandRpcResult.fromJson({
          'type': 'error',
          'accepted': false,
          'status': 'rejected',
        });
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
      gateway._events.add(
        const TuiGatewayEvent(
          type: 'status.update',
          sessionId: 'runtime-slash-test',
          payload: {
            'kind': 'compacted',
            'info': {
              '_lineage_root_id': 'session-slash-test',
              'stored_session_id': 'session-slash-test-compressed',
            },
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      gateway
        ..slashError = _syntheticRpcError
        ..dispatchError = _syntheticRpcError;
      await tester.enterText(composer, '/compress retry me');
      await tester.pump(const Duration(milliseconds: 250));
      await _submitSlash(tester);
      // A legacy transport failure that still lets a durable fence arm
      // (`desktopCompressionAwaitingReconciliation` is true here, same as
      // the structured "pending" case in REGRESSION_COMP_FIX3) is genuinely
      // uncertain, not a rejection — the composer clears like the rest of a
      // sent command and the floating dock/late `compacted` event below is
      // the signal, not stale text sitting in the field.
      expect(field.controller?.text, isEmpty);
      gateway._events.add(
        const TuiGatewayEvent(
          type: 'status.update',
          sessionId: 'runtime-slash-test',
          payload: {
            'kind': 'compacted',
            'info': {
              '_lineage_root_id': 'session-slash-test',
              'stored_session_id': 'session-slash-test-compressed-again',
            },
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      gateway.resumeExistingError = _syntheticRpcError;
      await tester.enterText(composer, '/compress no runtime');
      await tester.pump(const Duration(milliseconds: 250));
      await _submitSlash(tester);
      // The still-set slashError/dispatchError from the previous attempt
      // (never reset) means this also resolves ambiguous rather than a
      // clean rejection — same as the case just above, the composer stays
      // cleared rather than restoring stale text.
      expect(field.controller?.text, isEmpty);
    });
    testWidgets('/compress preserves a late draft', (tester) async {
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
    });
    testWidgets('read-only has no slash submission surface', (tester) async {
      await _pumpSlashChat(tester, _SlashGateway(), readOnly: true);
      expect(find.byType(TextField), findsNothing);
    });
    testWidgets('remote slash preserves late composer state', (tester) async {
      final gateway = _SlashGateway()..slashResult = _rejectedResult;
      final stt = _OpenSttEngine();
      final chat = await _pumpSlashChat(tester, gateway, stt: stt);
      final composer = find.byType(TextField).last;
      final field = tester.widget<TextField>(composer);
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
      final sendAction = _sendAction(tester);
      sendAction.onPressed!();
      sendAction.onPressed!();
      await tester.pump();
      await tester.enterText(composer, 'directed turn');
      await tester.pump(const Duration(milliseconds: 400));
      tester
          .widget<HermesTactileAction>(find.byKey(const ValueKey('mic')))
          .onPressed!();
      await tester.pump();
      stt._results.add(const SttResult('dictado tardío', false));
      await tester.pump(const Duration(milliseconds: 400));
      idleGate.complete(_directedResult);
      await tester.pump(const Duration(milliseconds: 800));
      expect(gateway.slashCalls, hasLength(3));
      expect(find.byKey(const ValueKey('recording')), findsOneWidget);
      expect(stt.stopCalls, 0);
      expect(field.controller?.text, 'directed turn');
      HermesNotice.of(
        tester.element(find.byType(ChatScreen).last),
      ).clearSnackBars();
      await _pumpSlashChat(tester, gateway, stt: stt);
      final restored = tester.widget<TextField>(find.byType(TextField).last);
      expect(restored.controller?.text, 'directed turn');
      await tester.pump(const Duration(milliseconds: 300));
      expect(gateway.submissions, ['directed turn']);
      final recovered = jsonDecode(secureStore['chat_turn_outbox_v1']!) as Map;
      final recoveredId = (recovered.values.single as Map)['client_turn_id'];

      // Un turno dirigido recuperado conserva la propiedad de su outbox hasta
      // que el usuario lo descarte explícitamente; enviar otro lote no puede
      // reemplazarlo ni crear una segunda entrega potencialmente duplicada.
      gateway.submitError = null;

      await tester.enterText(
        find.byType(TextField).last,
        '/goal second directed turn',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await _submitSlash(tester);
      expect(gateway.submissions, ['directed turn']);
      final afterBlockedSlash =
          jsonDecode(secureStore['chat_turn_outbox_v1']!) as Map;
      expect(afterBlockedSlash, hasLength(1));
      expect(
        (afterBlockedSlash.values.single as Map)['client_turn_id'],
        recoveredId,
      );

      await tester.enterText(find.byType(TextField).last, 'directed turn');
      await tester.pump(const Duration(milliseconds: 250));
      _sendAction(tester).onPressed!();
      await tester.pump(const Duration(milliseconds: 800));
      expect(gateway.submissions, ['directed turn']);
      final stillRecovered =
          jsonDecode(secureStore['chat_turn_outbox_v1']!) as Map;
      expect(stillRecovered, hasLength(1));
      expect(
        (stillRecovered.values.single as Map)['client_turn_id'],
        recoveredId,
      );

      // b7e95b6: the recovered-turn notice is now an in-chat banner above the
      // composer (it used to be a snackbar that covered the app bar).
      final discard = find.byKey(
        const ValueKey('recovered-turn-discard'),
        skipOffstage: false,
      );
      await tester.tap(discard.last);
      await tester.pump(const Duration(milliseconds: 400));
      expect(restored.controller?.text, 'directed turn');
      expect(secureStore.containsKey('chat_turn_outbox_v1'), isFalse);
      await _pumpSlashChat(tester, gateway, stt: stt);
      final resubmitted = tester.widget<TextField>(find.byType(TextField).last);
      expect(resubmitted.controller?.text, 'directed turn');
      gateway.submitError = null;
      _sendAction(tester).onPressed!();
      await tester.pump(const Duration(milliseconds: 800));
      expect(gateway.submissions, ['directed turn', 'directed turn']);
      final submitted = jsonDecode(secureStore['chat_turn_outbox_v1']!) as Map;
      final submittedId = (submitted.values.single as Map)['client_turn_id'];
      expect(submittedId, isNot(recoveredId));
      gateway._events.add(
        const TuiGatewayEvent(
          type: 'message.complete',
          sessionId: 'runtime-slash-test',
          payload: {'text': 'done'},
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
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
