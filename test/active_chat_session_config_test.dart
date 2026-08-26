import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_session_config.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/session_config_reducer.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _ConfiguredCreateGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopConfiguredSessionLifecycleGateway,
        HermesDesktopSessionConfigGateway,
        HermesDesktopRewindGateway,
        HermesDesktopSessionActivityGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

  int legacyResumeCalls = 0;
  int resumeExistingCalls = 0;
  int legacyCreateCalls = 0;
  int configuredCreateCalls = 0;
  DesktopSessionCreateConfig? observedConfig;
  String? observedProfile;
  final List<String> observedResumeProfiles = [];
  List<Map<String, dynamic>>? observedSeed;
  String? submittedRuntime;
  final List<({DesktopModelSelection model, bool confirmed})> modelChanges = [];
  Object? configError;
  Object? configuredCreateError;
  Object? activationError;
  bool resumeExistingSucceeds = false;
  bool connected = true;
  int activationCalls = 0;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect() async {
    connected = true;
  }

  void disconnectForTest() => connected = false;

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    resumeExistingCalls += 1;
    observedResumeProfiles.add(profile);
    if (resumeExistingSucceeds) {
      return DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-configured',
        storedSessionId: resumeExistingCalls > 1
            ? 'stored-reentered'
            : 'stored-configured',
        created: false,
        info: const DesktopSessionRuntimeInfo(
          model: 'openai/gpt-5.5-codex',
          provider: 'openai-codex',
          fast: false,
        ),
      );
    }
    throw const TuiGatewayRpcError('session.resume', 'not found', code: 4007);
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    legacyCreateCalls += 1;
    throw StateError('legacy create must not receive configured submission');
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmitConfigured({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    required DesktopSessionCreateConfig config,
  }) async {
    configuredCreateCalls += 1;
    final error = configuredCreateError;
    if (error != null) throw error;
    observedConfig = config;
    observedProfile = profile;
    observedSeed = seedMessages;
    return const DesktopSessionSnapshot(
      runtimeSessionId: 'runtime-configured',
      storedSessionId: 'stored-configured',
      created: true,
      info: DesktopSessionRuntimeInfo(
        model: 'openai/gpt-5.5-codex',
        provider: 'openai-codex',
        reasoningEffort: 'high',
        fast: false,
      ),
    );
  }

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => activationError == null
      ? DesktopGatewayCapabilityState.supported
      : DesktopGatewayCapabilityState.unknown;

  @override
  Future<DesktopSessionSnapshot> activateSession(
    String runtimeSessionId, {
    required String storedSessionId,
  }) async {
    activationCalls += 1;
    final error = activationError;
    if (error != null) throw error;
    return DesktopSessionSnapshot(
      runtimeSessionId: runtimeSessionId,
      storedSessionId: storedSessionId,
      created: false,
      info: const DesktopSessionRuntimeInfo(
        model: 'openai/gpt-5.5-codex',
        provider: 'openai-codex',
        fast: false,
      ),
    );
  }

  @override
  Future<DesktopActiveSessionList> listActiveSessions({
    String currentRuntimeSessionId = '',
  }) async => const DesktopActiveSessionList();

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    legacyResumeCalls += 1;
    observedResumeProfiles.add(profile);
    return const DesktopSessionBinding(
      runtimeSessionId: 'runtime-configured',
      storedSessionId: 'stored-configured',
      created: false,
      info: DesktopSessionRuntimeInfo(
        model: 'openai/gpt-5.5-codex',
        provider: 'openai-codex',
        reasoningEffort: 'high',
        fast: false,
      ),
    );
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submittedRuntime = runtimeSessionId;
  }

  @override
  Future<void> submitRewindPrompt(
    String runtimeSessionId,
    String text,
    int truncateBeforeUserOrdinal,
  ) async {
    submittedRuntime = runtimeSessionId;
  }

  @override
  Future<DesktopConfigSetResult> setSessionModel(
    String runtimeSessionId,
    DesktopModelSelection selection, {
    bool confirmExpensiveModel = false,
  }) async {
    final error = configError;
    if (error != null) throw error;
    modelChanges.add((model: selection, confirmed: confirmExpensiveModel));
    if (!confirmExpensiveModel) {
      return const DesktopConfigSetResult(
        key: DesktopSessionConfigKey.model,
        value: 'openai/gpt-5.5-codex',
        confirmRequired: true,
        confirmMessage: 'This model may be expensive',
      );
    }
    return DesktopConfigSetResult(
      key: DesktopSessionConfigKey.model,
      value: selection.modelId,
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
  ) async {
    final error = configError;
    if (error != null) throw error;
    return DesktopConfigSetResult(
      key: DesktopSessionConfigKey.fast,
      value: mode.wire,
    );
  }

  void emitSessionInfo(Map<String, dynamic> info) {
    _events.add(
      TuiGatewayEvent(
        type: 'session.info',
        sessionId: 'runtime-configured',
        payload: {'info': info},
      ),
    );
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
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

ActiveChat _chat(
  _ConfiguredCreateGateway gateway, {
  String? sessionProfile,
  http.Client? httpClient,
}) => ActiveChat(
  connection: SavedConnection(
    id: 'conn-configured-create',
    label: 'Configured create',
    host: '127.0.0.1',
    port: 8642,
    apiKey: 'test-key',
    kind: InstanceKind.vps,
  ),
  sessionId: 'draft-mobile',
  sessionTitle: 'Draft',
  notifications: null,
  onTerminal: () {},
  api: ApiClient(
    baseUrl: 'http://127.0.0.1:8642',
    apiKey: 'test-key',
    httpClient:
        httpClient ??
        MockClient((_) async => http.Response('unexpected REST', 500)),
  ),
  desktopGateway: gateway,
  sessionProfile: sessionProfile,
);

void main() {
  test('ensure runtime reanuda pero un 4007 nunca crea', () async {
    final draftGateway = _ConfiguredCreateGateway();
    final draft = _chat(draftGateway);
    addTearDown(draft.dispose);

    expect(await draft.ensureDesktopRuntime(), isFalse);
    expect(draftGateway.resumeExistingCalls, 1);
    expect(draftGateway.configuredCreateCalls, 0);
    expect(draftGateway.legacyCreateCalls, 0);

    final existingGateway = _ConfiguredCreateGateway()
      ..resumeExistingSucceeds = true;
    final existing = _chat(existingGateway);
    addTearDown(existing.dispose);

    expect(await existing.ensureDesktopRuntime(), isTrue);
    expect(existingGateway.resumeExistingCalls, 1);
    expect(existingGateway.configuredCreateCalls, 0);
    expect(existingGateway.legacyCreateCalls, 0);
    expect(existing.hasDesktopRuntime, isTrue);
  });

  test('draft persistido reentra aislado del scope anterior', () async {
    final gateway = _ConfiguredCreateGateway()..resumeExistingSucceeds = true;
    final chat = _chat(gateway);
    addTearDown(chat.dispose);

    expect(await chat.ensureDesktopRuntime(), isTrue);
    const key = DesktopSessionConfigKey.model;
    await chat.setSessionModel(
      DesktopModelSelection(
        modelId: 'openai/gpt-5.6-codex',
        providerSlug: 'openai-codex',
      ),
      confirmExpensiveModel: true,
    );
    expect(chat.pendingSessionConfigChange(key), isNotNull);
    gateway.disconnectForTest();
    expect(await chat.ensureDesktopRuntime(), isTrue);
    expect(gateway.activationCalls, 1);
    expect(gateway.resumeExistingCalls, 1);

    gateway
      ..disconnectForTest()
      ..activationError = const TuiGatewayRpcError(
        'session.activate',
        'runtime closed',
        code: 4007,
      );
    expect(await chat.ensureDesktopRuntime(), isTrue);
    expect(gateway.activationCalls, 2);
    expect(gateway.resumeExistingCalls, 2);
    expect(gateway.configuredCreateCalls, 0);
    expect(gateway.legacyCreateCalls, 0);
    expect(chat.serverSessionId, 'stored-reentered');
    expect(chat.pendingSessionConfigChange(key), isNull);
    expect(chat.effectiveSessionConfig.model, 'openai/gpt-5.5-codex');
  });

  test('session.info reaplica config en el stored id de reentrada', () async {
    final gateway = _ConfiguredCreateGateway()..resumeExistingSucceeds = true;
    final chat = _chat(gateway);
    addTearDown(chat.dispose);

    expect(await chat.ensureDesktopRuntime(), isTrue);
    const key = DesktopSessionConfigKey.fast;
    await chat.setSessionFastMode(DesktopFastMode.fast);
    expect(chat.pendingSessionConfigChange(key), isNotNull);

    gateway.emitSessionInfo(const {
      'stored_session_id': 'stored-from-info',
      'model': 'openai/gpt-5.7-codex',
      'provider': 'openai-codex',
      'fast': false,
    });
    await Future<void>.delayed(Duration.zero);

    expect(chat.serverSessionId, 'stored-from-info');
    expect(chat.storedSessionId, 'stored-from-info');
    expect(chat.pendingSessionConfigChange(key), isNull);
    expect(chat.effectiveSessionConfig.model, 'openai/gpt-5.7-codex');
    expect(chat.effectiveSessionConfig.provider, 'openai-codex');
    expect(chat.effectiveSessionConfig.fast, isFalse);
  });

  test(
    'un pin oficial ausente falla cerrado y nunca crea ni cae a REST',
    () async {
      final gateway = _ConfiguredCreateGateway();
      final chat = _chat(gateway);
      addTearDown(chat.dispose);

      final accepted = await chat.send(
        fullText: 'no dupliques el bot chat',
        model: 'hermes-agent',
        history: const [],
        sessionConfig: const DesktopSessionCreateConfig(
          createIfMissing: false,
          allowTransportFallback: false,
        ),
      );

      expect(accepted, isFalse);
      expect(gateway.resumeExistingCalls, 1);
      expect(gateway.configuredCreateCalls, 0);
      expect(gateway.legacyCreateCalls, 0);
      expect(gateway.submittedRuntime, isNull);
    },
  );

  test('Room create failure before prompt never degrades to REST', () async {
    final gateway = _ConfiguredCreateGateway()
      ..configuredCreateError = StateError('TUI create failed');
    var restCalls = 0;
    final chat = _chat(
      gateway,
      httpClient: MockClient((_) async {
        restCalls++;
        return http.Response('must not use REST', 500);
      }),
    );
    addTearDown(chat.dispose);

    final accepted = await chat.send(
      fullText: 'turno manager durable',
      model: 'hermes-agent',
      history: const [],
      sessionConfig: const DesktopSessionCreateConfig(
        title: '#homelab',
        createIfMissing: true,
        allowTransportFallback: false,
      ),
    );

    expect(accepted, isFalse);
    expect(gateway.configuredCreateCalls, 1);
    expect(gateway.submittedRuntime, isNull);
    expect(restCalls, 0);
  });

  test(
    'primer submit crea una vez con config capturada antes de awaits',
    () async {
      final gateway = _ConfiguredCreateGateway();
      final chat = _chat(gateway);
      addTearDown(chat.dispose);
      final config = DesktopSessionCreateConfig(
        model: DesktopModelSelection(
          modelId: 'openai/gpt-5.5-codex',
          providerSlug: 'openai-codex',
        ),
        reasoningEffort: DesktopReasoningEffort.high,
        fastMode: DesktopFastMode.normal,
      );

      final accepted = await chat.send(
        fullText: 'hola',
        model: 'openai/gpt-5.5-codex',
        history: const [
          {'role': 'assistant', 'content': 'seed'},
        ],
        profile: 'coding',
        sessionConfig: config,
      );

      expect(accepted, isTrue);
      expect(gateway.resumeExistingCalls, 1);
      expect(gateway.configuredCreateCalls, 1);
      expect(gateway.legacyResumeCalls, 0);
      expect(gateway.legacyCreateCalls, 0);
      expect(gateway.observedConfig, config);
      expect(gateway.observedProfile, 'coding');
      expect(gateway.observedSeed, const [
        {'role': 'assistant', 'content': 'seed'},
      ]);
      expect(gateway.submittedRuntime, 'runtime-configured');
      expect(chat.storedSessionId, 'stored-configured');
      expect(chat.desktopRuntimeInfo.model, 'openai/gpt-5.5-codex');
      expect(chat.desktopRuntimeInfo.fast, isFalse);
    },
  );

  test(
    'rebind conserva el perfil propietario aunque el caller cambie a otro',
    () async {
      final gateway = _ConfiguredCreateGateway()..resumeExistingSucceeds = true;
      final chat = _chat(gateway);
      addTearDown(chat.dispose);

      await chat.loadMessages(expectedMessageCount: 0, profile: 'profile-a');
      gateway.observedResumeProfiles.clear();

      final accepted = await chat.send(
        fullText: 'turno de voz',
        model: 'hermes-agent',
        history: const [],
        profile: 'profile-b',
        serverSessionId: 'voice-runtime-rotated',
      );

      expect(accepted, isTrue);
      expect(chat.sessionProfile, 'profile-a');
      expect(gateway.observedResumeProfiles, ['profile-a']);
    },
  );

  test('rewrite conserva el perfil propietario del binding', () async {
    final gateway = _ConfiguredCreateGateway();
    final chat = _chat(gateway, sessionProfile: 'profile-a');
    addTearDown(chat.dispose);
    chat.messages = [
      {'role': 'assistant', 'content': 'respuesta anterior'},
      {'role': 'user', 'content': 'pregunta original'},
    ];

    await chat.rewrite(
      userOrdinal: 0,
      text: 'pregunta editada',
      model: 'hermes-agent',
      profile: 'profile-b',
    );

    expect(chat.sessionProfile, 'profile-a');
    expect(gateway.observedResumeProfiles, ['profile-a']);
  });

  test('confirmación cara espera session.info antes de ser efectiva', () async {
    final gateway = _ConfiguredCreateGateway();
    final chat = _chat(gateway);
    addTearDown(chat.dispose);
    await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []);
    final selection = DesktopModelSelection(
      modelId: 'anthropic/claude-opus-4-8',
      providerSlug: 'anthropic',
    );

    final confirmation = await chat.setSessionModel(selection);

    expect(confirmation.status, SessionConfigChangeStatus.confirmRequired);
    expect(confirmation.confirmMessage, 'This model may be expensive');
    expect(chat.effectiveSessionConfig.model, 'openai/gpt-5.5-codex');
    expect(gateway.modelChanges.single.confirmed, isFalse);

    final accepted = await chat.confirmSessionModel(confirmation);
    expect(accepted.status, SessionConfigChangeStatus.accepted);
    expect(gateway.modelChanges.last.confirmed, isTrue);
    expect(chat.effectiveSessionConfig.model, 'openai/gpt-5.5-codex');

    gateway.emitSessionInfo({
      'model': selection.modelId,
      'provider': selection.providerSlug,
      'reasoning_effort': 'high',
      'fast': false,
    });
    await Future<void>.delayed(Duration.zero);

    expect(
      chat.pendingSessionConfigChange(DesktopSessionConfigKey.model)?.status,
      SessionConfigChangeStatus.confirmed,
    );
    expect(chat.effectiveSessionConfig.model, selection.modelId);
    expect(chat.effectiveSessionConfig.provider, selection.providerSlug);
  });

  test('4009 revierte fast y conserva la sesión utilizable', () async {
    final gateway = _ConfiguredCreateGateway();
    final chat = _chat(gateway);
    addTearDown(chat.dispose);
    await chat.send(fullText: 'hola', model: 'hermes-agent', history: const []);
    gateway.configError = const TuiGatewayRpcError(
      'config.set',
      'busy',
      code: 4009,
    );

    final result = await chat.setSessionFastMode(DesktopFastMode.fast);

    expect(result.status, SessionConfigChangeStatus.rejected);
    expect(result.failureKind, SessionConfigFailureKind.busy);
    expect((result.displayValue as SessionFastConfigValue).enabled, isFalse);
    expect(chat.effectiveSessionConfig.fast, isFalse);
    expect(chat.hasDesktopRuntime, isTrue);
  });
}
