// Tests de integración end-to-end del flujo de chat completo, ejercitando el
// camino crítico de la app: enviar mensaje → recibir la respuesta del gateway
// (SSE de /v1/runs) → refrescar/persistir → reabrir y reconstruir el transcript.
//
// Patrón de mocking idéntico al resto del proyecto (ver
// active_chat_service_test.dart y connection_manager_test.dart): un MockClient
// de package:http/testing.dart simula el gateway HTTP, y SharedPreferences /
// flutter_secure_storage se mockean por canal en memoria.
//
// Cobertura:
//   1. Flujo completo REMOTO: send → SSE (delta + run.completed) → refetch de
//      mensajes; verifica que NO se toca el transcript local (es instancia
//      remota, el gateway ya guarda el historial server-side).
//   2. Persistencia y carga LOCAL (bridge): el contrato real de /bridge/chat y
//      la ida/vuelta por LocalTranscriptStore + ActiveChat.loadMessages.
//   3. Error del servidor: 503 en startRun no deja el pipeline colgado y no
//      pierde el turno previo de la conversación.
//   4. Steering por el protocolo oficial de Desktop: prompt y complementos
//      comparten la misma sesión JSON-RPC, sin `/v1/runs/{id}/steer`.
//
// Nota sobre el escenario 2: la orquestación de _sendViaBridge no es
// directamente accionable en un test unitario porque BridgeClient.provision
// instancia su propio http.Client (sin punto de inyección desde ActiveChat) y
// el keep-alive en 2º plano va por canales de plataforma. Por eso el escenario
// ejercita las piezas reales de las que depende ese flujo: el parseo de la
// respuesta del bridge (/bridge/chat → {ok, response}) con un MockClient, y la
// persistencia/recarga del transcript local que ActiveChat usa al reabrir.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/local_transcript_store.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

const _kWatchKey = 'bg_watch_runs'; // BackgroundWatch._key (privado)

/// Instancia REMOTA (host privado → InstanceKind.homelab, no localhost): el
/// chat va por el motor /v1/runs y el historial lo guarda el gateway.
SavedConnection _remoteConn() => SavedConnection(
  id: 'conn-remote',
  label: 'Remoto',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

/// Instancia LOCAL (127.0.0.1 → InstanceKind.localhost): el chat va por el
/// Mobile Bridge y el transcript se persiste localmente cifrado.
SavedConnection _localConn() => SavedConnection(
  id: 'conn-local',
  label: 'Local',
  host: '127.0.0.1',
  port: 9119,
  apiKey: 'test-key',
  onDeviceLoopback: true,
);

String _sse(List<Map<String, dynamic>> frames) =>
    frames.map((f) => 'data: ${jsonEncode(f)}\n\n').join();

/// MockClient del gateway: POST /v1/runs, el SSE de eventos del run y el
/// refetch de mensajes. [postBodies] (si se pasa) acumula el cuerpo JSON de
/// cada POST /v1/runs para inspeccionar el contexto enviado.
MockClient _gateway({
  required String events,
  required List<Map<String, dynamic>> finalMessages,
  int runStatus = 200,
  List<Map<String, dynamic>>? postBodies,
}) {
  return MockClient((request) async {
    final path = request.url.path;
    if (request.method == 'POST' && path == '/v1/runs') {
      postBodies?.add(jsonDecode(request.body) as Map<String, dynamic>);
      if (runStatus != 200) {
        return http.Response('{"error":"unavailable"}', runStatus);
      }
      return http.Response(jsonEncode({'run_id': 'run_1'}), 200);
    }
    if (request.method == 'GET' && path == '/v1/runs/run_1/events') {
      return http.Response(
        events,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    if (request.method == 'POST' && path == '/v1/runs/run_1/approval') {
      return http.Response(jsonEncode({'ok': true}), 200);
    }
    if (request.method == 'GET' && path == '/api/sessions/sess-1/messages') {
      return http.Response(jsonEncode({'data': finalMessages}), 200);
    }
    return http.Response('not found', 404);
  });
}

/// Espera activa hasta que [cond] se cumple o salta el timeout. Evita depender
/// de delays fijos en los pasos asíncronos (SSE, refetch, etc.).
Future<void> _waitUntil(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

List<Map<String, dynamic>> _generatedImageRefs(Map<String, dynamic> message) {
  final raw = message['_generatedImages'];
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
}

class _FakeDesktopGateway
    implements HermesDesktopGateway, HermesDesktopInterruptedPromptGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  final List<({String sessionId, String text})> prompts = [];
  final List<({String sessionId, String text})> interruptedPrompts = [];
  final List<({String sessionId, String text})> steers = [];
  final List<String> interrupts = [];
  final List<String> calls = [];
  final List<({String sessionId, String choice})> approvals = [];
  bool connected = false;
  bool completeInterrupts = true;
  String? returnedStoredId;
  String? resumedStoredId;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect() async => connected = true;

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    resumedStoredId = storedSessionId;
    return DesktopSessionBinding(
      runtimeSessionId: 'runtime-1',
      storedSessionId: returnedStoredId ?? storedSessionId,
      created: false,
    );
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    calls.add('submit:$text');
    prompts.add((sessionId: runtimeSessionId, text: text));
  }

  @override
  Future<void> submitInterruptedPrompt(
    String runtimeSessionId,
    String text,
  ) async {
    calls.add('submit-interrupted:$text');
    interruptedPrompts.add((sessionId: runtimeSessionId, text: text));
  }

  @override
  Future<void> steer(String runtimeSessionId, String text) async {
    calls.add('steer:$text');
    steers.add((sessionId: runtimeSessionId, text: text));
  }

  @override
  Future<void> interrupt(String runtimeSessionId) async {
    calls.add('interrupt:$runtimeSessionId');
    interrupts.add(runtimeSessionId);
    if (completeInterrupts) {
      emit('message.complete', {'text': 'Operation interrupted.'});
    }
  }

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
  }) async {
    approvals.add((sessionId: runtimeSessionId, choice: choice));
  }

  void emit(String type, [Map<String, dynamic> payload = const {}]) {
    _events.add(
      TuiGatewayEvent(type: type, sessionId: 'runtime-1', payload: payload),
    );
  }

  @override
  Future<void> close() async {
    connected = false;
    if (!_events.isClosed) await _events.close();
  }
}

class _RedirectDesktopGateway extends _FakeDesktopGateway
    implements HermesDesktopRedirectGateway {
  final List<({String sessionId, String text})> redirects = [];
  final List<DesktopRedirectDisposition> _dispositions;

  _RedirectDesktopGateway({
    List<DesktopRedirectDisposition> dispositions = const [],
  }) : _dispositions = List<DesktopRedirectDisposition>.of(dispositions);

  @override
  Future<DesktopRedirectDisposition> redirect(
    String runtimeSessionId,
    String text,
  ) async {
    redirects.add((sessionId: runtimeSessionId, text: text));
    return _dispositions.isEmpty
        ? DesktopRedirectDisposition.redirected
        : _dispositions.removeAt(0);
  }
}

class _GatedRedirectDesktopGateway extends _RedirectDesktopGateway {
  _GatedRedirectDesktopGateway({
    this.disposition = DesktopRedirectDisposition.redirected,
  });

  final DesktopRedirectDisposition disposition;
  final Completer<void> redirectGate = Completer<void>();

  @override
  Future<DesktopRedirectDisposition> redirect(
    String runtimeSessionId,
    String text,
  ) async {
    redirects.add((sessionId: runtimeSessionId, text: text));
    await redirectGate.future;
    return disposition;
  }
}

class _RecoveringRedirectDesktopGateway extends _RedirectDesktopGateway
    implements HermesDesktopSessionLifecycleGateway {
  final int firstRedirectErrorCode;
  int resumeExistingCalls = 0;
  int createForFirstSubmitCalls = 0;
  final List<String> resumeStoredIds = [];
  final List<String> resumeProfiles = [];

  _RecoveringRedirectDesktopGateway({this.firstRedirectErrorCode = 4001});

  @override
  Future<DesktopSessionBinding> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    resumeExistingCalls++;
    resumeStoredIds.add(storedSessionId);
    resumeProfiles.add(profile);
    return DesktopSessionBinding(
      runtimeSessionId: 'runtime-${resumeExistingCalls + 1}',
      storedSessionId: storedSessionId,
      created: false,
    );
  }

  @override
  Future<DesktopSessionBinding> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    createForFirstSubmitCalls++;
    throw StateError('session.create must not repair a stale redirect');
  }

  @override
  Future<DesktopRedirectDisposition> redirect(
    String runtimeSessionId,
    String text,
  ) async {
    redirects.add((sessionId: runtimeSessionId, text: text));
    if (redirects.length == 1) {
      throw TuiGatewayRpcError(
        'session.redirect',
        firstRedirectErrorCode == 4001
            ? 'session not found'
            : 'request timed out',
        code: firstRedirectErrorCode,
      );
    }
    return DesktopRedirectDisposition.redirected;
  }
}

class _RecoveringInterruptDesktopGateway extends _FakeDesktopGateway
    implements HermesDesktopSessionLifecycleGateway {
  _RecoveringInterruptDesktopGateway({required this.firstInterruptErrorCode});

  final int firstInterruptErrorCode;
  int resumeExistingCalls = 0;
  int createForFirstSubmitCalls = 0;
  final List<String> resumeStoredIds = [];
  final List<String> resumeProfiles = [];
  final List<bool> resumeOmitMessages = [];

  @override
  Future<DesktopSessionBinding> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    resumeExistingCalls++;
    resumeStoredIds.add(storedSessionId);
    resumeProfiles.add(profile);
    resumeOmitMessages.add(omitMessages);
    return DesktopSessionBinding(
      runtimeSessionId: 'runtime-2',
      storedSessionId: storedSessionId,
      created: false,
    );
  }

  @override
  Future<DesktopSessionBinding> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    createForFirstSubmitCalls++;
    throw StateError('session.create must not repair a stale interrupt');
  }

  @override
  Future<void> interrupt(String runtimeSessionId) async {
    calls.add('interrupt:$runtimeSessionId');
    interrupts.add(runtimeSessionId);
    if (interrupts.length == 1) {
      throw TuiGatewayRpcError(
        'session.interrupt',
        firstInterruptErrorCode == 4001
            ? 'session not found'
            : 'interrupt rejected',
        code: firstInterruptErrorCode,
      );
    }
    _events.add(
      TuiGatewayEvent(
        type: 'message.complete',
        sessionId: runtimeSessionId,
        payload: const {'text': 'Operation interrupted.'},
      ),
    );
  }
}

enum _OwnerOperation { none, create, resume, submit, interrupt, redirect }

/// Gateway delimitado por owner para demostrar que un cambio de perfil en la
/// UI no puede reasignar una operación que ya pertenece a otro [ActiveChat].
/// Ambos owners devuelven a propósito los mismos ids durable/runtime: la única
/// frontera fiable del test es el owner inmutable, no una coincidencia de ids.
class _OwnerScopedDesktopGateway extends _FakeDesktopGateway
    implements
        HermesDesktopRedirectGateway,
        HermesDesktopSessionLifecycleGateway {
  _OwnerScopedDesktopGateway(this.owner, {this.gated = _OwnerOperation.none});

  final String owner;
  final _OwnerOperation gated;
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  final List<String> wire = [];

  Future<void> _pause(_OwnerOperation operation) async {
    if (gated != operation) return;
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }

  DesktopSessionBinding _binding({required bool created}) =>
      DesktopSessionBinding(
        runtimeSessionId: 'runtime-1',
        storedSessionId: 'stored-collision',
        created: created,
      );

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    wire.add('$owner:resume:$profile:$storedSessionId');
    await _pause(_OwnerOperation.resume);
    return _binding(created: false);
  }

  @override
  Future<DesktopSessionBinding> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    wire.add('$owner:resume-existing:$profile:$storedSessionId');
    await _pause(_OwnerOperation.resume);
    return _binding(created: false);
  }

  @override
  Future<DesktopSessionBinding> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    wire.add('$owner:create:$profile');
    await _pause(_OwnerOperation.create);
    return _binding(created: true);
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    wire.add('$owner:submit:$runtimeSessionId:$text');
    prompts.add((sessionId: runtimeSessionId, text: text));
    await _pause(_OwnerOperation.submit);
  }

  @override
  Future<void> interrupt(String runtimeSessionId) async {
    wire.add('$owner:interrupt:$runtimeSessionId');
    interrupts.add(runtimeSessionId);
    await _pause(_OwnerOperation.interrupt);
    emit('message.complete', {'text': 'Operation interrupted.'});
  }

  @override
  Future<DesktopRedirectDisposition> redirect(
    String runtimeSessionId,
    String text,
  ) async {
    wire.add('$owner:redirect:$runtimeSessionId:$text');
    await _pause(_OwnerOperation.redirect);
    return DesktopRedirectDisposition.redirected;
  }
}

class _LegacyOnlyRewindGateway extends _FakeDesktopGateway
    implements HermesDesktopRewindGateway {
  int legacyRewinds = 0;

  @override
  Future<void> submitRewindPrompt(
    String runtimeSessionId,
    String text,
    int truncateBeforeUserOrdinal,
  ) async {
    legacyRewinds += 1;
  }
}

class _FakeRewindGateway extends _FakeDesktopGateway
    implements
        HermesDesktopRewindResolverGateway,
        HermesDesktopDurableRewindGateway {
  final List<({String sessionId, String text, int ordinal})> rewinds = [];
  bool rejectRewind = false;
  bool loseRewindAck = false;
  int? rejectRewindOrdinal;
  int rewindErrorCode = 422;

  @override
  Future<int?> resolveDurableUserRowId(
    String runtimeSessionId, {
    required String sourceText,
    required int expectedOrdinal,
  }) async => 73;

  @override
  Future<DesktopRewindAck> submitDurableRewindPrompt(
    String runtimeSessionId,
    String text,
    int truncateBeforeUserOrdinal, {
    required int truncateBeforeRowId,
  }) async {
    rewinds.add((
      sessionId: runtimeSessionId,
      text: text,
      ordinal: truncateBeforeUserOrdinal,
    ));
    if (rejectRewind || rejectRewindOrdinal == truncateBeforeUserOrdinal) {
      throw TuiGatewayRpcError(
        'prompt.submit',
        'rewind rejected for test',
        code: rewindErrorCode,
      );
    }
    if (loseRewindAck) {
      throw const TuiGatewayRpcError(
        'prompt.submit',
        'Timeout waiting for JSON-RPC response',
      );
    }
    return const DesktopRewindAck();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('aísla chats con el mismo sessionId en conexiones distintas', () {
    final service = ActiveChatService();
    final firstConnection = _remoteConn().copyWith(id: 'conn-first');
    final secondConnection = _remoteConn().copyWith(id: 'conn-second');
    final first = service.attach(
      connection: firstConnection,
      sessionId: 'shared-session',
      sessionTitle: 'Primero',
      api: ApiClient(
        baseUrl: firstConnection.baseUrl,
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('not found', 404)),
      ),
      desktopGateway: _FakeDesktopGateway(),
    );
    final second = service.attach(
      connection: secondConnection,
      sessionId: 'shared-session',
      sessionTitle: 'Segundo',
      api: ApiClient(
        baseUrl: secondConnection.baseUrl,
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('not found', 404)),
      ),
      desktopGateway: _FakeDesktopGateway(),
    );

    expect(first, isNot(same(second)));
    expect(service.of(firstConnection.id, 'shared-session'), same(first));
    expect(service.of(secondConnection.id, 'shared-session'), same(second));
    service.dispose();
  });

  test('aísla el mismo sessionId entre perfiles de una conexión', () {
    final service = ActiveChatService();
    final connection = _remoteConn();
    final first = service.attach(
      connection: connection,
      sessionId: 'shared-profile-session',
      sessionTitle: 'Perfil A',
      sessionProfile: 'profile-a',
      api: ApiClient(
        baseUrl: connection.baseUrl,
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('not found', 404)),
      ),
      desktopGateway: _FakeDesktopGateway(),
    );
    final second = service.attach(
      connection: connection,
      sessionId: 'shared-profile-session',
      sessionTitle: 'Perfil B',
      sessionProfile: 'profile-b',
      api: ApiClient(
        baseUrl: connection.baseUrl,
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('not found', 404)),
      ),
      desktopGateway: _FakeDesktopGateway(),
    );

    expect(first, isNot(same(second)));
    expect(first.sessionProfile, 'profile-a');
    expect(second.sessionProfile, 'profile-b');
    expect(
      service.of(connection.id, 'shared-profile-session', profile: 'profile-a'),
      same(first),
    );
    expect(
      service.of(connection.id, 'shared-profile-session', profile: 'profile-b'),
      same(second),
    );
    expect(service.of(connection.id, 'shared-profile-session'), isNull);
    service.dispose();
  });

  // Almacén cifrado simulado en memoria para flutter_secure_storage, de modo
  // que LocalTranscriptStore persista de verdad entre instancias de ActiveChat.
  final secureStore = <String, String>{};

  void mockChannel(String name) {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureStore.clear();
    // flutter_secure_storage: implementación en memoria (read/write/delete/…).
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                secureStore[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secureStore[args['key'] as String];
              case 'readAll':
                return Map<String, String>.from(secureStore);
              case 'delete':
                secureStore.remove(args['key'] as String);
                return null;
              case 'deleteAll':
                secureStore.clear();
                return null;
              case 'containsKey':
                return secureStore.containsKey(args['key'] as String);
            }
            return null;
          },
        );
    // Canales de plataforma del foreground service / notificaciones. El canal
    // de métodos responde `isRunningService=true` para que BackgroundListener
    // corte temprano (ya en marcha) en vez de devolver `null` donde se espera
    // un `bool` y arrastrar un TypeError asíncrono entre tests.
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_foreground_task/methods'),
          (call) async => call.method == 'isRunningService' ? true : null,
        );
    mockChannel('flutter_foreground_task/background');
    mockChannel('dexterous.com/flutter/local_notifications');
  });

  ActiveChat attachOwner(
    ActiveChatService service,
    _OwnerScopedDesktopGateway gateway,
    String profile,
  ) {
    final connection = _remoteConn();
    return service.attach(
      connection: connection,
      sessionId: 'stored-collision',
      sessionTitle: 'Owner $profile',
      sessionProfile: profile,
      api: ApiClient(
        baseUrl: connection.baseUrl,
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('not found', 404)),
      ),
      desktopGateway: gateway,
    );
  }

  Future<void> primeOwner(ActiveChat chat, String profile) async {
    expect(
      await chat.send(
        fullText: 'turno $profile',
        model: 'hermes-agent',
        history: const [],
        profile: profile,
      ),
      isTrue,
    );
  }

  void switchVisibleOwner({
    required ActiveChatService service,
    required ActiveChat ownerA,
    required ActiveChat ownerB,
    required _OwnerScopedDesktopGateway gatewayB,
  }) {
    final reattachedB = attachOwner(service, gatewayB, 'profile-b');
    expect(reattachedB, same(ownerB));
    expect(ownerA.bindSessionProfile('profile-b'), 'profile-a');
    expect(ownerA.sessionProfile, 'profile-a');
    expect(ownerB.sessionProfile, 'profile-b');
  }

  void expectCollidingIdsRemainOwnerScoped({
    required ActiveChatService service,
    required ActiveChat ownerA,
    required ActiveChat ownerB,
  }) {
    expect(ownerA.sessionId, 'stored-collision');
    expect(ownerB.sessionId, 'stored-collision');
    expect(ownerA.storedSessionId, 'stored-collision');
    expect(ownerB.storedSessionId, 'stored-collision');
    expect(ownerA.desktopRuntimeSessionId, 'runtime-1');
    expect(ownerB.desktopRuntimeSessionId, 'runtime-1');
    expect(
      service.of(_remoteConn().id, 'stored-collision', profile: 'profile-a'),
      same(ownerA),
    );
    expect(
      service.of(_remoteConn().id, 'stored-collision', profile: 'profile-b'),
      same(ownerB),
    );
    expect(service.of(_remoteConn().id, 'stored-collision'), isNull);
  }

  group('T039A — owner de perfil inmutable con ids colisionados', () {
    test('create de A no se reasigna a B durante el await', () async {
      final service = ActiveChatService();
      addTearDown(service.dispose);
      final gatewayA = _OwnerScopedDesktopGateway(
        'A',
        gated: _OwnerOperation.create,
      );
      final gatewayB = _OwnerScopedDesktopGateway('B');
      final ownerA = attachOwner(service, gatewayA, 'profile-a');
      final ownerB = attachOwner(service, gatewayB, 'profile-b');
      await primeOwner(ownerB, 'profile-b');
      final wireBBefore = List<String>.of(gatewayB.wire);

      ownerA.markStoredSessionMissing();
      final operation = ownerA.send(
        fullText: 'create A',
        model: 'hermes-agent',
        history: const [],
        profile: 'profile-a',
      );
      await gatewayA.entered.future.timeout(const Duration(seconds: 2));
      switchVisibleOwner(
        service: service,
        ownerA: ownerA,
        ownerB: ownerB,
        gatewayB: gatewayB,
      );
      gatewayA.release.complete();

      expect(await operation, isTrue);
      expect(gatewayA.wire, [
        'A:create:profile-a',
        'A:submit:runtime-1:create A',
      ]);
      expect(gatewayB.wire, wireBBefore);
      expectCollidingIdsRemainOwnerScoped(
        service: service,
        ownerA: ownerA,
        ownerB: ownerB,
      );
    });

    test('resume de A conserva su perfil y su gateway al mostrar B', () async {
      final service = ActiveChatService();
      addTearDown(service.dispose);
      final gatewayA = _OwnerScopedDesktopGateway(
        'A',
        gated: _OwnerOperation.resume,
      );
      final gatewayB = _OwnerScopedDesktopGateway('B');
      final ownerA = attachOwner(service, gatewayA, 'profile-a');
      final ownerB = attachOwner(service, gatewayB, 'profile-b');
      await primeOwner(ownerB, 'profile-b');
      final wireBBefore = List<String>.of(gatewayB.wire);

      final operation = ownerA.send(
        fullText: 'resume A',
        model: 'hermes-agent',
        history: const [],
        profile: 'profile-a',
      );
      await gatewayA.entered.future.timeout(const Duration(seconds: 2));
      switchVisibleOwner(
        service: service,
        ownerA: ownerA,
        ownerB: ownerB,
        gatewayB: gatewayB,
      );
      gatewayA.release.complete();

      expect(await operation, isTrue);
      expect(gatewayA.wire, [
        'A:resume:profile-a:stored-collision',
        'A:submit:runtime-1:resume A',
      ]);
      expect(gatewayB.wire, wireBBefore);
      expectCollidingIdsRemainOwnerScoped(
        service: service,
        ownerA: ownerA,
        ownerB: ownerB,
      );
    });

    test('submit de A no cruza al gateway de B con runtime idéntico', () async {
      final service = ActiveChatService();
      addTearDown(service.dispose);
      final gatewayA = _OwnerScopedDesktopGateway(
        'A',
        gated: _OwnerOperation.submit,
      );
      final gatewayB = _OwnerScopedDesktopGateway('B');
      final ownerA = attachOwner(service, gatewayA, 'profile-a');
      final ownerB = attachOwner(service, gatewayB, 'profile-b');
      await primeOwner(ownerB, 'profile-b');
      final wireBBefore = List<String>.of(gatewayB.wire);

      final operation = ownerA.send(
        fullText: 'submit A',
        model: 'hermes-agent',
        history: const [],
        profile: 'profile-a',
      );
      await gatewayA.entered.future.timeout(const Duration(seconds: 2));
      switchVisibleOwner(
        service: service,
        ownerA: ownerA,
        ownerB: ownerB,
        gatewayB: gatewayB,
      );
      gatewayA.release.complete();

      expect(await operation, isTrue);
      expect(gatewayA.wire, [
        'A:resume:profile-a:stored-collision',
        'A:submit:runtime-1:submit A',
      ]);
      expect(gatewayB.wire, wireBBefore);
      expectCollidingIdsRemainOwnerScoped(
        service: service,
        ownerA: ownerA,
        ownerB: ownerB,
      );
    });

    test('interrupt de A no alcanza el runtime homónimo de B', () async {
      final service = ActiveChatService();
      addTearDown(service.dispose);
      final gatewayA = _OwnerScopedDesktopGateway(
        'A',
        gated: _OwnerOperation.interrupt,
      );
      final gatewayB = _OwnerScopedDesktopGateway('B');
      final ownerA = attachOwner(service, gatewayA, 'profile-a');
      final ownerB = attachOwner(service, gatewayB, 'profile-b');
      await primeOwner(ownerA, 'profile-a');
      await primeOwner(ownerB, 'profile-b');
      final wireBBefore = List<String>.of(gatewayB.wire);

      final operation = ownerA.interruptForVoiceBarge(
        settleTimeout: const Duration(seconds: 2),
      );
      await gatewayA.entered.future.timeout(const Duration(seconds: 2));
      switchVisibleOwner(
        service: service,
        ownerA: ownerA,
        ownerB: ownerB,
        gatewayB: gatewayB,
      );
      gatewayA.release.complete();
      await operation;

      expect(gatewayA.wire.last, 'A:interrupt:runtime-1');
      expect(gatewayB.wire, wireBBefore);
      expect(ownerB.isStreaming, isTrue);
      expectCollidingIdsRemainOwnerScoped(
        service: service,
        ownerA: ownerA,
        ownerB: ownerB,
      );
    });

    test('redirect de A no alcanza el runtime homónimo de B', () async {
      final service = ActiveChatService();
      addTearDown(service.dispose);
      final gatewayA = _OwnerScopedDesktopGateway(
        'A',
        gated: _OwnerOperation.redirect,
      );
      final gatewayB = _OwnerScopedDesktopGateway('B');
      final ownerA = attachOwner(service, gatewayA, 'profile-a');
      final ownerB = attachOwner(service, gatewayB, 'profile-b');
      await primeOwner(ownerA, 'profile-a');
      await primeOwner(ownerB, 'profile-b');
      final wireBBefore = List<String>.of(gatewayB.wire);

      final operation = ownerA.steer('redirect A');
      await gatewayA.entered.future.timeout(const Duration(seconds: 2));
      switchVisibleOwner(
        service: service,
        ownerA: ownerA,
        ownerB: ownerB,
        gatewayB: gatewayB,
      );
      gatewayA.release.complete();
      await operation;

      expect(gatewayA.wire.last, 'A:redirect:runtime-1:redirect A');
      expect(gatewayB.wire, wireBBefore);
      expect(ownerB.isStreaming, isTrue);
      expectCollidingIdsRemainOwnerScoped(
        service: service,
        ownerA: ownerA,
        ownerB: ownerB,
      );
    });
  });

  // ── Escenario 1 ─────────────────────────────────────────────────────────
  group('E2E 1 — flujo completo remoto (send → SSE → refetch)', () {
    test('los mensajes incluyen el turno del usuario y la respuesta del agente, '
        'y NO se persiste transcript local', () async {
      final api = ApiClient(
        baseUrl: _remoteConn().baseUrl,
        apiKey: 'test-key',
        // La secuencia running→completed del run se materializa en el SSE como
        // un message.delta parcial ("Hola") seguido de run.completed ("Hola
        // mundo"): es el contrato real del gateway (/v1/runs/{id}/events).
        httpClient: _gateway(
          events: _sse([
            {'event': 'message.delta', 'delta': 'Hola'},
            {'event': 'run.completed', 'output': 'Hola mundo'},
          ]),
          finalMessages: [
            {'role': 'user', 'content': 'di hola'},
            {'role': 'assistant', 'content': 'Hola mundo'},
          ],
        ),
      );

      final service = ActiveChatService();
      final chat = service.attach(
        connection: _remoteConn(),
        sessionId: 'sess-1',
        sessionTitle: 'Saludo',
        api: api,
      );
      final done = chat.changes.firstWhere((e) => e == ActiveChatEvent.done);

      chat.send(fullText: 'di hola', model: 'hermes-agent', history: const []);
      await done.timeout(const Duration(seconds: 5));

      // Estado terminal correcto y transcript refrescado desde el servidor.
      expect(chat.state, ChatPipelineState.completed);
      final roles = chat.messages.map((m) => m['role']).toList();
      expect(roles, contains('user'));
      expect(roles, contains('assistant'));
      expect(
        chat.messages.firstWhere((m) => m['role'] == 'user')['content'],
        'di hola',
      );
      expect(
        chat.messages.firstWhere((m) => m['role'] == 'assistant')['content'],
        'Hola mundo',
      );

      // Instancia remota: el historial vive server-side, así que la app NO
      // debe escribir nada en el almacén local cifrado.
      final localSaved = await LocalTranscriptStore.load(
        _remoteConn().id,
        'sess-1',
      );
      expect(localSaved, isEmpty);

      // Espera a que el cierre diferido (~800ms) del run corra antes de liberar
      // el servicio: así no se toca el ValueNotifier de activeIds ya dispuesto.
      await _waitUntil(() => chat.state == ChatPipelineState.idle);
      service.dispose();
    });
  });

  // ── Escenario 2 ─────────────────────────────────────────────────────────
  group('E2E 2 — persistencia y carga (instancia local / bridge)', () {
    test(
      'respuesta del bridge → persistida → reconstruida al reabrir el chat',
      () async {
        final conn = _localConn();
        expect(conn.kind, InstanceKind.localhost);

        // (1-2) El turno se ejecuta vía el Mobile Bridge. Ejercitamos el contrato
        // real de /bridge/chat con un MockClient: devuelve {ok, response}.
        final bridge = BridgeClient(
          baseUrl: conn.derivedBridgeUrl,
          token: 'bridge-token',
          httpClient: MockClient((request) async {
            if (request.method == 'POST' &&
                request.url.path == '/bridge/chat') {
              return http.Response(
                jsonEncode({'ok': true, 'response': 'Bien'}),
                200,
              );
            }
            return http.Response('not found', 404);
          }),
        );
        final response = await bridge.chat('¿qué tal?', history: const []);
        expect(response, 'Bien');
        bridge.close();

        // Como hace _sendViaBridge tras recibir la respuesta: persiste el turno
        // (lista viva del chat, index 0 = más nuevo = el asistente).
        await LocalTranscriptStore.saveFromNewestFirst(conn.id, 'sess-local', [
          {'role': 'assistant', 'content': 'Bien'},
          {'role': 'user', 'content': '¿qué tal?'},
        ]);

        // (3) El transcript guardado está en orden cronológico (más antiguo 1º).
        final saved = await LocalTranscriptStore.load(conn.id, 'sess-local');
        expect(saved, [
          {'role': 'user', 'content': '¿qué tal?'},
          {'role': 'assistant', 'content': 'Bien'},
        ]);

        // (4-5) Un ActiveChat NUEVO para la misma conexión+sesión reconstruye el
        // chat desde el almacén local (el bridge no expone /api/sessions/.../messages).
        final reopened = ActiveChat(
          connection: conn,
          sessionId: 'sess-local',
          sessionTitle: 'Chat local',
          notifications: null,
          onTerminal: () {},
        );
        await reopened.loadMessages();

        expect(reopened.messagesLoaded, isTrue);
        // index 0 = más nuevo en la lista viva (el asistente).
        expect(reopened.messages.first['role'], 'assistant');
        expect(reopened.messages.first['content'], 'Bien');
        expect(reopened.messages.last['role'], 'user');
        expect(reopened.messages.last['content'], '¿qué tal?');
        reopened.dispose();
      },
    );
  });

  // ── Escenario 3 ─────────────────────────────────────────────────────────
  group('E2E 3 — error del servidor (503 en startRun)', () {
    test(
      'el fallo deja el pipeline en estado terminal y conserva el turno previo',
      () async {
        final api = ApiClient(
          baseUrl: _remoteConn().baseUrl,
          apiKey: 'test-key',
          httpClient: _gateway(
            events: '',
            finalMessages: const [],
            runStatus: 503,
          ),
        );

        final service = ActiveChatService();
        final chat = service.attach(
          connection: _remoteConn(),
          sessionId: 'sess-1',
          sessionTitle: 'Con error',
          api: api,
        );
        // Conversación previa ya completada (no debe perderse por el fallo).
        chat.messages = [
          {'role': 'assistant', 'content': 'respuesta previa'},
          {'role': 'user', 'content': 'pregunta previa'},
        ];
        chat.messagesLoaded = true;

        final errored = chat.changes.firstWhere(
          (e) => e == ActiveChatEvent.error,
        );
        chat.send(
          fullText: 'nuevo intento',
          model: 'hermes-agent',
          history: const [],
        );
        await errored.timeout(const Duration(seconds: 5));

        // No queda colgado en connecting/streaming: estado terminal failed.
        expect(chat.state, ChatPipelineState.failed);
        expect(chat.isStreaming, isFalse);

        // El error se materializa como una entrada assistant_error con su contexto.
        final errEntry = chat.messages.firstWhere(
          (m) => m['role'] == 'assistant_error',
          orElse: () => <String, dynamic>{},
        );
        expect(errEntry['content']?.toString(), contains('503'));
        expect(errEntry['_prompt'], 'nuevo intento');

        // El turno previo sigue intacto: el fallo no corrompe la conversación.
        expect(
          chat.messages.any(
            (m) => m['role'] == 'user' && m['content'] == 'pregunta previa',
          ),
          isTrue,
        );
        expect(
          chat.messages.any(
            (m) =>
                m['role'] == 'assistant' && m['content'] == 'respuesta previa',
          ),
          isTrue,
        );

        // El run fallido no quedó vigilado en 2º plano.
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        expect(prefs.getString(_kWatchKey) ?? '[]', isNot(contains('run_1')));

        service.dispose();
      },
    );
  });

  // ── Escenario 4 ─────────────────────────────────────────────────────────
  group('E2E 4 — correcciones mientras hay una respuesta', () {
    test('barge-in conserva el settle oficial de Desktop', () {
      expect(activeChatVoiceBargeSettleTimeout, const Duration(seconds: 5));
      expect(
        activeChatVoiceBargeRunIsTerminal({'status': 'stopping'}),
        isFalse,
      );
      expect(
        activeChatVoiceBargeRunIsTerminal({'status': 'cancelled'}),
        isTrue,
      );
    });

    test('REST espera stopping hasta el terminal real', () async {
      final statuses = <String>['stopping', 'running', 'cancelled'];
      var reads = 0;

      await waitForActiveChatVoiceBargeTerminal(
        readStatus: () async => {'status': statuses[reads++]},
        timeout: const Duration(seconds: 1),
        pollInterval: Duration.zero,
      );

      expect(reads, 3);
    });

    test(
      'barge-in hoy → y ayer interrumpe primero y conserva el contexto hablado',
      () async {
        final desktop = _FakeDesktopGateway();
        final service = ActiveChatService();
        final chat = service.attach(
          connection: _remoteConn(),
          sessionId: 'sess-voice-context',
          sessionTitle: 'Noticias por voz',
          api: ApiClient(
            baseUrl: _remoteConn().baseUrl,
            apiKey: 'test-key',
            httpClient: MockClient(
              (_) async => http.Response('not found', 404),
            ),
          ),
          desktopGateway: desktop,
        );

        unawaited(
          chat.send(
            fullText: 'Dame las noticias de hoy',
            model: 'hermes-agent',
            history: const [],
          ),
        );
        await _waitUntil(() => desktop.prompts.isNotEmpty);
        desktop.emit('message.start');
        desktop.emit('message.delta', {'text': 'Hoy destaca...'});
        await _waitUntil(() => chat.assistantContent.isNotEmpty);

        await chat.interruptForVoiceBarge();
        expect(desktop.interrupts, ['runtime-1']);
        expect(chat.isStreaming, isFalse);

        unawaited(
          chat.send(
            fullText: 'Y también las de ayer',
            model: 'hermes-agent',
            history: chat.buildHistory(),
            voicePlaybackInterrupted: true,
          ),
        );
        await _waitUntil(() => desktop.interruptedPrompts.isNotEmpty);

        expect(desktop.prompts, [
          (sessionId: 'runtime-1', text: 'Dame las noticias de hoy'),
        ]);
        expect(desktop.interruptedPrompts, [
          (sessionId: 'runtime-1', text: 'Y también las de ayer'),
        ]);
        expect(desktop.calls, [
          'submit:Dame las noticias de hoy',
          'interrupt:runtime-1',
          'submit-interrupted:Y también las de ayer',
        ]);
        expect(desktop.steers, isEmpty);
        expect(
          chat.messages
              .where(
                (message) =>
                    message['role'] == 'user' && message['_pipeline'] != true,
              )
              .map((message) => message['content']),
          containsAll(['Dame las noticias de hoy', 'Y también las de ayer']),
        );

        desktop.emit('message.complete', {
          'text': 'Resumen conjunto de hoy y ayer.',
        });
        await _waitUntil(() => chat.state == ChatPipelineState.idle);
        service.dispose();
      },
    );

    test(
      'session.interrupt 4001 reanuda stored y perfil antes de un unico retry',
      () async {
        final desktop = _RecoveringInterruptDesktopGateway(
          firstInterruptErrorCode: 4001,
        );
        final service = ActiveChatService();
        final chat = service.attach(
          connection: _remoteConn(),
          sessionId: 'sess-interrupt-recovery',
          sessionTitle: 'Interrupt recovery',
          sessionProfile: 'profile-a',
          api: ApiClient(baseUrl: _remoteConn().baseUrl, apiKey: 'test-key'),
          desktopGateway: desktop,
        );

        unawaited(
          chat.send(
            fullText: 'prepara las noticias',
            model: 'hermes-agent',
            history: const [],
            profile: 'profile-a',
          ),
        );
        await _waitUntil(() => desktop.prompts.isNotEmpty);
        desktop.emit('message.start');

        await chat.interruptForVoiceBarge();

        expect(desktop.interrupts, ['runtime-1', 'runtime-2']);
        expect(desktop.resumeExistingCalls, 1);
        expect(desktop.resumeStoredIds, ['sess-interrupt-recovery']);
        expect(desktop.resumeProfiles, ['profile-a']);
        expect(desktop.resumeOmitMessages, [isTrue]);
        expect(desktop.createForFirstSubmitCalls, 0);
        expect(chat.desktopRuntimeSessionId, 'runtime-2');
        expect(chat.isStreaming, isFalse);
        service.dispose();
      },
    );

    for (final errorCode in const [4007, -32000]) {
      test('session.interrupt $errorCode no reanuda ni reintenta', () async {
        final desktop = _RecoveringInterruptDesktopGateway(
          firstInterruptErrorCode: errorCode,
        );
        final service = ActiveChatService();
        final chat = service.attach(
          connection: _remoteConn(),
          sessionId: 'sess-interrupt-no-retry-$errorCode',
          sessionTitle: 'Interrupt no retry',
          sessionProfile: 'profile-a',
          api: ApiClient(baseUrl: _remoteConn().baseUrl, apiKey: 'test-key'),
          desktopGateway: desktop,
        );

        unawaited(
          chat.send(
            fullText: 'prepara las noticias',
            model: 'hermes-agent',
            history: const [],
            profile: 'profile-a',
          ),
        );
        await _waitUntil(() => desktop.prompts.isNotEmpty);
        desktop.emit('message.start');

        await chat.interruptForVoiceBarge();

        expect(desktop.interrupts, ['runtime-1']);
        expect(desktop.resumeExistingCalls, 0);
        expect(desktop.createForFirstSubmitCalls, 0);
        expect(chat.desktopRuntimeSessionId, 'runtime-1');
        service.dispose();
      });
    }

    test(
      'un terminal tardío del turno interrumpido no cierra el nuevo turno',
      () async {
        final desktop = _FakeDesktopGateway()..completeInterrupts = false;
        final service = ActiveChatService();
        final chat = service.attach(
          connection: _remoteConn(),
          sessionId: 'sess-late-voice-terminal',
          sessionTitle: 'Barge tardío',
          api: ApiClient(
            baseUrl: _remoteConn().baseUrl,
            apiKey: 'test-key',
            httpClient: MockClient(
              (_) async => http.Response('not found', 404),
            ),
          ),
          desktopGateway: desktop,
        );

        unawaited(
          chat.send(
            fullText: 'Dame las noticias de hoy',
            model: 'hermes-agent',
            history: const [],
          ),
        );
        await _waitUntil(() => desktop.prompts.isNotEmpty);
        desktop.emit('message.start');
        await chat.interruptForVoiceBarge(
          settleTimeout: const Duration(milliseconds: 10),
        );
        expect(chat.hasPendingDesktopInterruptHandoff, isTrue);

        unawaited(
          chat.send(
            fullText: 'Y las de ayer',
            model: 'hermes-agent',
            history: chat.buildHistory(),
            voicePlaybackInterrupted: true,
          ),
        );
        await _waitUntil(() => desktop.interruptedPrompts.isNotEmpty);
        expect(chat.hasPendingDesktopInterruptHandoff, isTrue);
        expect(chat.isStreaming, isTrue);

        desktop.emit('message.complete', {
          'text': 'Operation interrupted by user.',
        });
        await Future<void>.delayed(Duration.zero);
        expect(chat.isStreaming, isTrue);

        desktop.emit('message.delta', {'text': 'Hoy y ayer...'});
        desktop.emit('message.complete', {'text': 'Hoy y ayer completos.'});
        await _waitUntil(() => chat.state == ChatPipelineState.idle);
        expect(chat.assistantContent, 'Hoy y ayer completos.');
        service.dispose();
      },
    );

    test(
      'usa session.redirect y conserva varias correcciones en el turno vivo',
      () async {
        var patchedEndpointCalls = 0;
        final desktop = _RedirectDesktopGateway();
        final client = MockClient((request) async {
          if (request.url.path.endsWith('/steer')) patchedEndpointCalls++;
          if (request.method == 'GET' &&
              request.url.path == '/api/sessions/sess-1/messages') {
            return http.Response(
              jsonEncode({
                'data': [
                  {'role': 'user', 'content': 'uno'},
                  {'role': 'assistant', 'content': 'respuesta uno documentada'},
                ],
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        });
        final api = ApiClient(
          baseUrl: _remoteConn().baseUrl,
          apiKey: 'test-key',
          httpClient: client,
        );

        final service = ActiveChatService();
        final chat = service.attach(
          connection: _remoteConn(),
          sessionId: 'sess-1',
          sessionTitle: 'Sin cola',
          api: api,
          desktopGateway: desktop,
        );

        chat.send(fullText: 'uno', model: 'hermes-agent', history: const []);
        await _waitUntil(() => desktop.prompts.isNotEmpty);
        desktop.emit('message.start');
        await chat.steer('y documéntalo');
        await chat.steer('y añade ejemplos');

        expect(desktop.resumedStoredId, 'sess-1');
        expect(desktop.prompts, [(sessionId: 'runtime-1', text: 'uno')]);
        expect(desktop.redirects, [
          (sessionId: 'runtime-1', text: 'y documéntalo'),
          (sessionId: 'runtime-1', text: 'y añade ejemplos'),
        ]);
        expect(desktop.steers, isEmpty);
        expect(desktop.interrupts, isEmpty);
        expect(patchedEndpointCalls, 0);

        desktop.emit('message.delta', {'text': 'respuesta uno'});
        desktop.emit('message.complete', {'text': 'respuesta uno documentada'});

        await _waitUntil(() => chat.state == ChatPipelineState.idle);
        expect(
          chat.messages.any(
            (m) =>
                m['role'] == 'assistant' &&
                m['content'] == 'respuesta uno documentada',
          ),
          isTrue,
        );
        expect(
          chat.messages
              .where((m) => m['_steer'] == true)
              .map((m) => m['content'])
              .toList(),
          ['y añade ejemplos', 'y documéntalo'],
        );
        service.dispose();
      },
    );

    test(
      'session.redirect proyecta la corrección antes del ACK del gateway',
      () async {
        final desktop = _GatedRedirectDesktopGateway();
        final service = ActiveChatService();
        final chat = service.attach(
          connection: _remoteConn(),
          sessionId: 'sess-redirect-optimistic',
          sessionTitle: 'Redirect optimista',
          api: ApiClient(baseUrl: _remoteConn().baseUrl, apiKey: 'test-key'),
          desktopGateway: desktop,
        );

        unawaited(
          chat.send(
            fullText: 'prepara el informe',
            model: 'hermes-agent',
            history: const [],
          ),
        );
        await _waitUntil(() => desktop.prompts.isNotEmpty);
        desktop.emit('message.start');

        final steering = chat.steer('añade una tabla');
        await _waitUntil(() => desktop.redirects.isNotEmpty);
        final visibleBeforeAck = chat.messages.any(
          (message) =>
              message['role'] == 'user' &&
              message['content'] == 'añade una tabla' &&
              message['_steer'] == true,
        );

        desktop.redirectGate.complete();
        await steering;

        expect(visibleBeforeAck, isTrue);
        expect(
          chat.messages.where(
            (message) => message['content'] == 'añade una tabla',
          ),
          hasLength(1),
        );
        service.dispose();
      },
    );

    test(
      'session.redirect queued mueve la misma optimista al tail sin duplicarla',
      () async {
        final desktop = _GatedRedirectDesktopGateway(
          disposition: DesktopRedirectDisposition.queued,
        );
        final service = ActiveChatService();
        final chat = service.attach(
          connection: _remoteConn(),
          sessionId: 'sess-redirect-queued',
          sessionTitle: 'Redirect queued',
          api: ApiClient(baseUrl: _remoteConn().baseUrl, apiKey: 'test-key'),
          desktopGateway: desktop,
        );

        unawaited(
          chat.send(
            fullText: 'prepara el informe',
            model: 'hermes-agent',
            history: const [],
          ),
        );
        await _waitUntil(() => desktop.prompts.isNotEmpty);
        desktop.emit('message.start');

        final steering = chat.steer('añade una tabla');
        await _waitUntil(() => desktop.redirects.isNotEmpty);
        final optimistic = chat.messages.singleWhere(
          (message) =>
              message['content'] == 'añade una tabla' &&
              message['_steer'] == true,
        );
        expect(chat.messages.indexOf(optimistic), 1);

        desktop.redirectGate.complete();
        await steering;

        // La fuente oficial conserva la misma fila aceptada. Android mantiene
        // el assistant vivo en la cabeza hasta su terminal; entonces materializa
        // el tail newest-first sin reconstruir la optimista.
        expect(
          chat.messages
              .where((message) => message['content'] == 'añade una tabla')
              .single,
          same(optimistic),
        );
        expect(optimistic['_steer'], isNot(true));
        expect(chat.queuedMessages, ['añade una tabla']);

        desktop.emit('message.delta', {'text': 'respuesta base'});
        await _waitUntil(() => chat.assistantContent == 'respuesta base');
        desktop.emit('message.complete', {'text': 'respuesta base completa'});
        await _waitUntil(
          () =>
              chat.state == ChatPipelineState.waiting &&
              chat.messages.first['_pipeline'] == true,
        );

        expect(chat.messages[1], same(optimistic));
        expect(
          chat.messages.where(
            (message) => message['content'] == 'añade una tabla',
          ),
          hasLength(1),
        );
        expect(
          chat.messages.any(
            (message) => message['content'] == 'respuesta base completa',
          ),
          isTrue,
        );
        expect(chat.queuedMessages, isEmpty);

        desktop.emit('message.delta', {'text': 'tabla lista'});
        desktop.emit('message.complete', {'text': 'tabla lista'});
        await _waitUntil(() => chat.state == ChatPipelineState.idle);
        expect(
          chat.messages.where(
            (message) => message['content'] == 'añade una tabla',
          ),
          hasLength(1),
        );
        service.dispose();
      },
    );

    test(
      'session.redirect 4001 reanuda el stored id con su perfil y reintenta una vez',
      () async {
        final desktop = _RecoveringRedirectDesktopGateway();
        final service = ActiveChatService();
        final chat = service.attach(
          connection: _remoteConn(),
          sessionId: 'sess-redirect-recovery',
          sessionTitle: 'Redirect recovery',
          sessionProfile: 'profile-a',
          api: ApiClient(baseUrl: _remoteConn().baseUrl, apiKey: 'test-key'),
          desktopGateway: desktop,
        );

        unawaited(
          chat.send(
            fullText: 'prepara el informe',
            model: 'hermes-agent',
            history: const [],
            profile: 'profile-a',
          ),
        );
        await _waitUntil(() => desktop.prompts.isNotEmpty);
        desktop.emit('message.start');

        await chat.steer('corrige la fecha');

        expect(desktop.redirects, [
          (sessionId: 'runtime-1', text: 'corrige la fecha'),
          (sessionId: 'runtime-2', text: 'corrige la fecha'),
        ]);
        expect(desktop.resumeExistingCalls, 1);
        expect(desktop.resumeStoredIds, ['sess-redirect-recovery']);
        expect(desktop.resumeProfiles, ['profile-a']);
        expect(desktop.createForFirstSubmitCalls, 0);
        expect(
          chat.messages.where(
            (message) => message['content'] == 'corrige la fecha',
          ),
          hasLength(1),
        );
        service.dispose();
      },
    );

    test(
      'session.redirect no reintenta un timeout ambiguo y revierte la fila optimista',
      () async {
        final desktop = _RecoveringRedirectDesktopGateway(
          firstRedirectErrorCode: -32000,
        );
        final service = ActiveChatService();
        final chat = service.attach(
          connection: _remoteConn(),
          sessionId: 'sess-redirect-timeout',
          sessionTitle: 'Redirect timeout',
          api: ApiClient(baseUrl: _remoteConn().baseUrl, apiKey: 'test-key'),
          desktopGateway: desktop,
        );

        unawaited(
          chat.send(
            fullText: 'prepara el informe',
            model: 'hermes-agent',
            history: const [],
          ),
        );
        await _waitUntil(() => desktop.prompts.isNotEmpty);
        desktop.emit('message.start');

        await expectLater(
          chat.steer('corrige la fecha'),
          throwsA(
            isA<TuiGatewayRpcError>().having(
              (error) => error.code,
              'code',
              -32000,
            ),
          ),
        );

        expect(desktop.redirects, [
          (sessionId: 'runtime-1', text: 'corrige la fecha'),
        ]);
        expect(desktop.resumeExistingCalls, 0);
        expect(
          chat.messages.any(
            (message) => message['content'] == 'corrige la fecha',
          ),
          isFalse,
        );
        service.dispose();
      },
    );

    test(
      'conserva el complemento al salir, terminar el run y volver al chat',
      () async {
        const mobileSessionId = 'sess-steer-navigation-mobile';
        const storedSessionId = 'sess-steer-navigation-server';
        ApiClient api() => ApiClient(
          baseUrl: _remoteConn().baseUrl,
          apiKey: 'test-key',
          httpClient: MockClient((request) async {
            if (request.method == 'GET' &&
                request.url.path == '/api/sessions/$storedSessionId/messages') {
              return http.Response(
                jsonEncode({
                  'data': [
                    {'role': 'user', 'content': 'dame noticias'},
                    {'role': 'assistant', 'content': 'aquí están las noticias'},
                  ],
                }),
                200,
              );
            }
            return http.Response('not found', 404);
          }),
        );

        final service = ActiveChatService();
        final desktop = _FakeDesktopGateway()
          ..returnedStoredId = storedSessionId;
        final chat = service.attach(
          connection: _remoteConn(),
          sessionId: mobileSessionId,
          sessionTitle: 'Navegación',
          api: api(),
          desktopGateway: desktop,
        );
        final screenSubscription = chat.changes.listen((_) {});

        chat.send(
          fullText: 'dame noticias',
          model: 'hermes-agent',
          history: const [],
        );
        await _waitUntil(() => desktop.prompts.isNotEmpty);
        desktop.emit('message.start');
        await chat.steer('¿y me das las de hoy?');

        // Equivale a salir de ChatScreen mientras el turno sigue activo.
        await screenSubscription.cancel();
        service.release(_remoteConn().id, mobileSessionId);
        expect(service.of(_remoteConn().id, mobileSessionId), same(chat));

        // La lista ya conoce el ID persistido devuelto por Hermes. Si el usuario
        // vuelve antes de terminar, ambos IDs deben resolver el mismo chat vivo.
        final reopenedWhileActive = service.attach(
          connection: _remoteConn(),
          sessionId: storedSessionId,
          sessionTitle: 'Navegación',
          api: api(),
          desktopGateway: _FakeDesktopGateway(),
        );
        expect(reopenedWhileActive, same(chat));
        service.release(_remoteConn().id, storedSessionId);

        desktop.emit('message.complete', {'text': 'aquí están las noticias'});
        await _waitUntil(
          () => service.of(_remoteConn().id, storedSessionId) == null,
        );

        // Al volver se crea otro transporte y se recarga el transcript remoto,
        // que no contiene session.redirect como mensaje independiente.
        final reopened = service.attach(
          connection: _remoteConn(),
          sessionId: storedSessionId,
          sessionTitle: 'Navegación',
          api: api(),
          desktopGateway: _FakeDesktopGateway(),
        );
        await reopened.loadMessages();

        expect(
          reopened.messages.reversed
              .map((message) => message['content'])
              .toList(),
          ['dame noticias', '¿y me das las de hoy?', 'aquí están las noticias'],
        );
        expect(
          reopened.messages.singleWhere(
            (message) => message['content'] == '¿y me das las de hoy?',
          )['_steer'],
          isTrue,
        );
        service.dispose();
      },
    );

    test('release conserva un chat idle mientras Voz sigue suscrita', () async {
      const sessionId = 'sess-voice-navigation-retention';
      final service = ActiveChatService();
      final chat = service.attach(
        connection: _remoteConn(),
        sessionId: sessionId,
        sessionTitle: 'Voz durante navegación',
        api: ApiClient(baseUrl: _remoteConn().baseUrl, apiKey: 'test-key'),
        desktopGateway: _FakeDesktopGateway(),
      );
      final voiceSubscription = chat.changes.listen((_) {});

      // Equivale a desmontar ChatScreen después de terminar una respuesta,
      // mientras el controlador global de Voz conserva el mismo ActiveChat.
      service.release(_remoteConn().id, sessionId);
      expect(service.of(_remoteConn().id, sessionId), same(chat));

      await voiceSubscription.cancel();
      await _waitUntil(() => service.of(_remoteConn().id, sessionId) == null);
      service.dispose();
    });

    test(
      'queued queda como turno siguiente y el servidor lo ejecuta una sola vez',
      () async {
        final desktop = _RedirectDesktopGateway(
          dispositions: const [
            DesktopRedirectDisposition.redirected,
            DesktopRedirectDisposition.queued,
          ],
        );
        final api = ApiClient(
          baseUrl: _remoteConn().baseUrl,
          apiKey: 'test-key',
          httpClient: MockClient((request) async {
            if (request.method == 'GET' &&
                request.url.path == '/api/sessions/sess-queued/messages') {
              return http.Response(
                jsonEncode({
                  'data': [
                    {'role': 'user', 'content': 'haz el informe'},
                    {'role': 'assistant', 'content': 'primer resultado'},
                    {'role': 'user', 'content': 'ahora publícalo'},
                    {'role': 'assistant', 'content': 'publicado'},
                  ],
                }),
                200,
              );
            }
            return http.Response('not found', 404);
          }),
        );
        final service = ActiveChatService();
        final chat = service.attach(
          connection: _remoteConn(),
          sessionId: 'sess-queued',
          sessionTitle: 'Redirect queued',
          api: api,
          desktopGateway: desktop,
        );

        unawaited(
          chat.send(
            fullText: 'haz el informe',
            model: 'hermes-agent',
            history: const [],
          ),
        );
        await _waitUntil(() => desktop.prompts.isNotEmpty);
        desktop.emit('message.start');

        await chat.steer('incluye una tabla');
        await chat.steer('ahora publícalo');

        expect(
          chat.messages
              .where((message) => message['_steer'] == true)
              .map((message) => message['content']),
          ['incluye una tabla'],
        );
        expect(chat.queuedMessages, ['ahora publícalo']);

        desktop.emit('message.complete', {'text': 'primer resultado'});
        await Future<void>.delayed(Duration.zero);
        desktop.emit('message.start');
        desktop.emit('message.delta', {'text': 'publicado'});
        desktop.emit('message.complete', {'text': 'publicado'});

        await _waitUntil(() => chat.state == ChatPipelineState.idle);
        expect(desktop.prompts, [
          (sessionId: 'runtime-1', text: 'haz el informe'),
        ]);
        expect(desktop.redirects, [
          (sessionId: 'runtime-1', text: 'incluye una tabla'),
          (sessionId: 'runtime-1', text: 'ahora publícalo'),
        ]);
        expect(desktop.steers, isEmpty);
        expect(chat.queuedMessages, isEmpty);
        expect(chat.messages.reversed.map((message) => message['content']), [
          'haz el informe',
          'incluye una tabla',
          'primer resultado',
          'ahora publícalo',
          'publicado',
        ]);
        service.dispose();
      },
    );
  });

  group('E2E media estructurada — image_generate', () {
    test(
      'tool.complete sin ruta en la prosa conserva una sola referencia por call id',
      () async {
        final desktop = _FakeDesktopGateway();
        final service = ActiveChatService();
        addTearDown(service.dispose);
        final chat = service.attach(
          connection: _remoteConn(),
          sessionId: 'sess-1',
          sessionTitle: 'Imagen estructurada',
          api: ApiClient(
            baseUrl: _remoteConn().baseUrl,
            apiKey: 'test-key',
            httpClient: _gateway(events: '', finalMessages: const []),
          ),
          desktopGateway: desktop,
        );

        unawaited(
          chat.send(
            fullText: 'Genera una imagen',
            model: 'hermes-agent',
            history: const [],
          ),
        );
        await _waitUntil(() => desktop.prompts.isNotEmpty);
        desktop.emit('message.start');
        const payload = {
          'name': 'image_generate',
          'tool_id': 'call-image-1',
          'result': {
            'success': true,
            'host_image': '/home/hermes/.hermes/cache/images/peacock.png',
            'image': '/home/hermes/.hermes/cache/images/peacock.png',
            'agent_visible_image': '/sandbox/cache/peacock.png',
          },
        };

        desktop.emit('tool.complete', payload);
        desktop.emit('tool.complete', payload);
        desktop.emit('message.complete', {'text': 'Aquí tienes la imagen.'});
        await _waitUntil(() => chat.state == ChatPipelineState.idle);

        final assistant = chat.messages.firstWhere(
          (message) => message['role'] == 'assistant',
        );
        final refs = _generatedImageRefs(assistant);
        expect(refs, hasLength(1));
        expect(refs.single['kind'], 'serverCache');
        expect(
          refs.single['source'],
          '/home/hermes/.hermes/cache/images/peacock.png',
        );
        expect(refs.single['basename'], 'peacock.png');
        expect(refs.single['tool_call_id'], 'call-image-1');
        expect(assistant['content'], 'Aquí tienes la imagen.');
        expect(
          (assistant['content'] as String?)?.contains('peacock.png') ?? false,
          isFalse,
        );
      },
    );

    test(
      'tool.complete HTTPS duplicado conserva una referencia segura',
      () async {
        final desktop = _FakeDesktopGateway();
        final service = ActiveChatService();
        addTearDown(service.dispose);
        final chat = service.attach(
          connection: _remoteConn(),
          sessionId: 'sess-https',
          sessionTitle: 'Imagen HTTPS',
          api: ApiClient(
            baseUrl: _remoteConn().baseUrl,
            apiKey: 'test-key',
            httpClient: _gateway(events: '', finalMessages: const []),
          ),
          desktopGateway: desktop,
        );

        unawaited(
          chat.send(
            fullText: 'Genera una imagen remota',
            model: 'hermes-agent',
            history: const [],
          ),
        );
        await _waitUntil(() => desktop.prompts.isNotEmpty);
        desktop.emit('message.start');
        const payload = {
          'name': 'image_generate',
          'tool_id': 'call-image-https',
          'result': {
            'success': true,
            'image': 'https://cdn.example/result.png?sig=private#preview',
          },
        };
        desktop.emit('tool.complete', payload);
        desktop.emit('tool.complete', payload);
        desktop.emit('message.complete', {'text': 'Lista.'});
        await _waitUntil(() => chat.state == ChatPipelineState.idle);

        final refs = _generatedImageRefs(
          chat.messages.firstWhere((message) => message['role'] == 'assistant'),
        );
        expect(refs, hasLength(1));
        expect(refs.single['kind'], 'https');
        expect(
          refs.single['source'],
          'https://cdn.example/result.png?sig=private',
        );
        expect(refs.single.containsKey('basename'), isFalse);
      },
    );

    test('dos calls con el mismo basename conservan dos referencias', () async {
      final desktop = _FakeDesktopGateway();
      final service = ActiveChatService();
      addTearDown(service.dispose);
      final chat = service.attach(
        connection: _remoteConn(),
        sessionId: 'sess-same-basename',
        sessionTitle: 'Dos imágenes',
        api: ApiClient(
          baseUrl: _remoteConn().baseUrl,
          apiKey: 'test-key',
          httpClient: _gateway(events: '', finalMessages: const []),
        ),
        desktopGateway: desktop,
      );

      unawaited(
        chat.send(
          fullText: 'Genera dos imágenes',
          model: 'hermes-agent',
          history: const [],
        ),
      );
      await _waitUntil(() => desktop.prompts.isNotEmpty);
      desktop.emit('message.start');
      for (final callId in ['call-a', 'call-b']) {
        desktop.emit('tool.complete', {
          'name': 'image_generate',
          'tool_id': callId,
          'result': const {
            'success': true,
            'host_image': '/home/hermes/.hermes/cache/images/shared.png',
          },
        });
      }
      desktop.emit('message.complete', {'text': 'Listas.'});
      await _waitUntil(() => chat.state == ChatPipelineState.idle);

      final refs = _generatedImageRefs(
        chat.messages.firstWhere((message) => message['role'] == 'assistant'),
      );
      expect(refs, hasLength(2));
      expect(refs.map((ref) => ref['tool_call_id']).toSet(), {
        'call-a',
        'call-b',
      });
      expect(refs.every((ref) => ref['basename'] == 'shared.png'), isTrue);
    });
  });

  group('E2E 5 — continuidad tras aprobaciones de herramientas', () {
    test(
      'mantiene el mismo run entre varias aprobaciones y la respuesta final',
      () async {
        final desktop = _FakeDesktopGateway();
        final api = ApiClient(
          baseUrl: _remoteConn().baseUrl,
          apiKey: 'test-key',
          httpClient: MockClient((request) async {
            if (request.method == 'GET' &&
                request.url.path == '/api/sessions/sess-1/messages') {
              return http.Response(
                jsonEncode({
                  'data': [
                    {'role': 'user', 'content': 'Haz la auditoría'},
                    {'role': 'assistant', 'content': 'Auditoría completada'},
                  ],
                }),
                200,
              );
            }
            return http.Response('not found', 404);
          }),
        );
        final service = ActiveChatService();
        final chat = service.attach(
          connection: _remoteConn(),
          sessionId: 'sess-1',
          sessionTitle: 'Aprobaciones',
          api: api,
          desktopGateway: desktop,
        );

        unawaited(
          chat.send(
            fullText: 'Haz la auditoría',
            model: 'hermes-agent',
            history: const [],
          ),
        );
        await _waitUntil(() => desktop.prompts.isNotEmpty);
        desktop.emit('message.start');
        desktop.emit('approval.request', {
          'command': 'ls -la',
          'pattern_key': 'ls',
        });
        await _waitUntil(() => chat.pendingApproval?['command'] == 'ls -la');

        await chat.resolveApproval('once');
        expect(desktop.approvals, [(sessionId: 'runtime-1', choice: 'once')]);
        expect(chat.pendingApproval, isNull);
        expect(chat.state, ChatPipelineState.executing);
        expect(chat.isStreaming, isTrue);

        desktop.emit('tool.complete', {'name': 'terminal'});
        desktop.emit('approval.request', {
          'command': 'cat informe.txt',
          'pattern_key': 'cat',
        });
        await _waitUntil(
          () => chat.pendingApproval?['command'] == 'cat informe.txt',
        );
        await chat.resolveApproval('once');
        expect(desktop.approvals, [
          (sessionId: 'runtime-1', choice: 'once'),
          (sessionId: 'runtime-1', choice: 'once'),
        ]);

        desktop.emit('message.delta', {'text': 'Auditoría completada'});
        desktop.emit('message.complete', {'text': 'Auditoría completada'});
        await _waitUntil(() => chat.state == ChatPipelineState.idle);

        expect(chat.pendingApproval, isNull);
        expect(chat.assistantContent, 'Auditoría completada');
        expect(desktop.prompts, [
          (sessionId: 'runtime-1', text: 'Haz la auditoría'),
        ]);
        service.dispose();
      },
    );
  });

  group('E2E 6 — fallback universal cuando steering no está disponible', () {
    test('conserva el seguimiento y lo envía al terminar el turno', () async {
      final bodies = <Map<String, dynamic>>[];
      final api = ApiClient(
        baseUrl: _remoteConn().baseUrl,
        apiKey: 'test-key',
        httpClient: _gateway(
          postBodies: bodies,
          events: _sse([
            {'event': 'run.completed', 'output': 'respuesta uno'},
          ]),
          finalMessages: [
            {'role': 'user', 'content': 'uno'},
            {'role': 'assistant', 'content': 'respuesta uno'},
          ],
        ),
      );

      final service = ActiveChatService();
      final chat = service.attach(
        connection: _remoteConn(),
        sessionId: 'sess-queue',
        sessionTitle: 'Fallback',
        api: api,
      );

      chat.send(fullText: 'uno', model: 'hermes-agent', history: const []);
      chat.enqueue('y añade ejemplos');

      expect(chat.queuedMessages, ['y añade ejemplos']);
      await _waitUntil(() => bodies.length >= 2);

      expect(chat.queuedMessages, isEmpty);
      expect(bodies[1]['input'], 'y añade ejemplos');
      expect(bodies[1]['conversation_history'], [
        {'role': 'user', 'content': 'uno'},
        {'role': 'assistant', 'content': 'respuesta uno'},
      ]);

      await _waitUntil(() => chat.state == ChatPipelineState.idle);
      service.dispose();
    });

    test('Stop descarta los seguimientos pendientes', () async {
      final desktop = _FakeDesktopGateway();
      final service = ActiveChatService();
      final chat = service.attach(
        connection: _remoteConn(),
        sessionId: 'sess-stop-queue',
        sessionTitle: 'Stop total',
        api: ApiClient(
          baseUrl: _remoteConn().baseUrl,
          apiKey: 'test-key',
          httpClient: MockClient((_) async => http.Response('not found', 404)),
        ),
        desktopGateway: desktop,
      );
      chat.send(fullText: 'primera', model: 'hermes-agent', history: const []);
      await _waitUntil(() => desktop.prompts.isNotEmpty);
      desktop.emit('message.delta', {'text': 'respuesta parcial'});
      await _waitUntil(() => chat.assistantContent.isNotEmpty);
      chat.enqueue('segunda');
      expect(chat.queuedMessages, ['segunda']);

      chat.cancel();

      expect(chat.queuedMessages, isEmpty);
      expect(desktop.interrupts, ['runtime-1']);
      final history = chat.buildHistory();
      final voiceCompatibleHistory = chat.buildHistory(excludeCancelled: true);
      expect(history, voiceCompatibleHistory);
      expect(history, hasLength(2));
      expect(history[0]['content'], contains('Turno detenido por el usuario'));
      expect(history[0]['content'], contains('primera'));
      expect(history[1]['content'], contains('respuesta parcial'));
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(desktop.prompts.length, 1);
      service.dispose();
    });
  });

  test(
    'gateway legacy-only falla antes de publicar transcript optimista',
    () async {
      final desktop = _LegacyOnlyRewindGateway();
      final service = ActiveChatService();
      final connection = _remoteConn();
      final chat = service.attach(
        connection: connection,
        sessionId: 'sess-legacy-rewind',
        sessionTitle: 'Legacy rewind',
        api: ApiClient(
          baseUrl: connection.baseUrl,
          apiKey: 'test-key',
          httpClient: MockClient((_) async => http.Response('not found', 404)),
        ),
        desktopGateway: desktop,
      );
      chat.messages = [
        {'role': 'assistant', 'content': 'respuesta original'},
        {'role': 'user', 'content': 'pregunta original', '_desktopRowId': 73},
      ];
      final observedContents = <List<String>>[];
      final subscription = chat.changes.listen((_) {
        observedContents.add(
          chat.messages
              .map((message) => (message['content'] ?? '').toString())
              .toList(growable: false),
        );
      });

      await expectLater(
        chat.rewrite(
          userOrdinal: 0,
          text: 'pregunta que nunca debe publicarse',
          model: 'hermes-agent',
        ),
        throwsA(
          isA<TuiGatewayRpcError>().having(
            (error) => error.code,
            'code',
            -32601,
          ),
        ),
      );

      expect(desktop.legacyRewinds, 0);
      expect(
        observedContents.any(
          (snapshot) => snapshot.contains('pregunta que nunca debe publicarse'),
        ),
        isFalse,
      );
      expect(chat.messages, [
        {'role': 'assistant', 'content': 'respuesta original'},
        {'role': 'user', 'content': 'pregunta original', '_desktopRowId': 73},
      ]);
      await subscription.cancel();
      service.dispose();
    },
  );

  test(
    'editar rebobina por ordinal e interrumpe primero un turno vivo',
    () async {
      final desktop = _FakeRewindGateway();
      final service = ActiveChatService();
      final chat = service.attach(
        connection: _remoteConn(),
        sessionId: 'sess-rewind',
        sessionTitle: 'Rewind',
        api: ApiClient(
          baseUrl: _remoteConn().baseUrl,
          apiKey: 'test-key',
          httpClient: MockClient((_) async => http.Response('not found', 404)),
        ),
        desktopGateway: desktop,
      );
      chat.messages = [
        {'role': 'assistant', 'content': 'respuesta antigua'},
        {'role': 'user', 'content': 'pregunta antigua'},
      ];

      chat.send(
        fullText: 'pregunta en curso',
        model: 'hermes-agent',
        history: chat.buildHistory(),
      );
      await _waitUntil(() => desktop.prompts.isNotEmpty);

      await chat.rewrite(
        userOrdinal: 1,
        text: 'pregunta corregida',
        model: 'hermes-agent',
      );
      await _waitUntil(() => desktop.rewinds.isNotEmpty);

      expect(desktop.interrupts, ['runtime-1']);
      expect(desktop.rewinds.single.sessionId, 'runtime-1');
      expect(desktop.rewinds.single.text, 'pregunta corregida');
      expect(desktop.rewinds.single.ordinal, 1);
      expect(chat.messages[1]['content'], 'pregunta corregida');
      expect(
        chat.messages.any((m) => m['content'] == 'pregunta en curso'),
        isFalse,
      );
      service.dispose();
    },
  );

  test(
    'editar espera el terminal de interrupción antes de enviar el texto nuevo',
    () async {
      final desktop = _FakeRewindGateway()..completeInterrupts = false;
      final service = ActiveChatService();
      final chat = service.attach(
        connection: _remoteConn(),
        sessionId: 'sess-rewind-race',
        sessionTitle: 'Rewind race',
        api: ApiClient(
          baseUrl: _remoteConn().baseUrl,
          apiKey: 'test-key',
          httpClient: MockClient((_) async => http.Response('not found', 404)),
        ),
        desktopGateway: desktop,
      );
      final events = chat.changes.listen((_) {});

      chat.send(
        fullText: 'emperador romano',
        model: 'hermes-agent',
        history: const [],
      );
      await _waitUntil(() => desktop.prompts.isNotEmpty);

      final rewrite = chat.rewrite(
        userOrdinal: 0,
        text: 'emperador griego',
        model: 'hermes-agent',
      );
      await _waitUntil(() => desktop.interrupts.isNotEmpty);
      expect(desktop.rewinds, isEmpty);

      desktop.emit('message.complete', {'text': 'Operation interrupted.'});
      await rewrite;
      await _waitUntil(() => desktop.rewinds.isNotEmpty);

      expect(desktop.rewinds.single.text, 'emperador griego');
      expect(
        chat.messages.any(
          (message) => message['content'] == 'emperador romano',
        ),
        isFalse,
      );
      desktop.emit('message.complete', {'text': 'Respuesta sobre Grecia'});
      await _waitUntil(() => chat.state == ChatPipelineState.idle);
      await events.cancel();
      service.dispose();
    },
  );

  test(
    '4018 reintenta solo el ordinal reparado tras un model_switch fusionado',
    () async {
      final desktop = _FakeRewindGateway()
        ..rejectRewindOrdinal = 2
        ..rewindErrorCode = 4018;
      final service = ActiveChatService();
      final chat = service.attach(
        connection: _remoteConn(),
        sessionId: 'sess-rewind-model-switch',
        sessionTitle: 'Rewind model switch',
        api: ApiClient(
          baseUrl: _remoteConn().baseUrl,
          apiKey: 'test-key',
          httpClient: MockClient((_) async => http.Response('not found', 404)),
        ),
        desktopGateway: desktop,
      );
      chat.messages = [
        {'role': 'assistant', 'content': 'respuesta tercera'},
        {'role': 'user', 'content': 'pregunta tercera', '_desktopRowId': 73},
        {'role': 'assistant', 'content': 'respuesta segunda'},
        {'role': 'user', 'content': 'pregunta segunda'},
        {
          'role': 'user',
          'content':
              '[System: The active model for this chat has changed to k3.]',
          'display_kind': 'model_switch',
        },
        {'role': 'assistant', 'content': 'respuesta primera'},
        {'role': 'user', 'content': 'pregunta primera'},
      ];
      chat.state = ChatPipelineState.completed;

      await chat.rewrite(
        userOrdinal: 2,
        text: 'pregunta tercera',
        model: 'hermes-agent',
      );

      expect(desktop.rewinds.map((rewind) => rewind.ordinal), [2, 1]);
      expect(chat.takeRewindRestoredOnError(), isFalse);

      desktop.emit('message.complete', {'text': 'respuesta regenerada'});
      await _waitUntil(() => chat.state == ChatPipelineState.idle);
      service.dispose();
    },
  );

  test('un rewind rechazado restaura la conversación optimista', () async {
    final desktop = _FakeRewindGateway()..rejectRewind = true;
    final service = ActiveChatService();
    final chat = service.attach(
      connection: _remoteConn(),
      sessionId: 'sess-rewind-error',
      sessionTitle: 'Rewind error',
      api: ApiClient(
        baseUrl: _remoteConn().baseUrl,
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('not found', 404)),
      ),
      desktopGateway: desktop,
    );
    chat.messages = [
      {'role': 'assistant', 'content': 'respuesta original'},
      {'role': 'user', 'content': 'pregunta original', '_desktopRowId': 73},
    ];
    chat.state = ChatPipelineState.completed;
    final errored = chat.changes.firstWhere(
      (event) => event == ActiveChatEvent.error,
    );

    await chat.rewrite(
      userOrdinal: 0,
      text: 'pregunta editada',
      model: 'hermes-agent',
    );
    await errored.timeout(const Duration(seconds: 5));

    expect(chat.messages, [
      {'role': 'assistant', 'content': 'respuesta original'},
      {'role': 'user', 'content': 'pregunta original', '_desktopRowId': 73},
    ]);
    expect(chat.state, ChatPipelineState.completed);
    expect(chat.takeRewindRestoredOnError(), isTrue);
    service.dispose();
  });

  test(
    'ACK perdido tras rewind no restaura una línea temporal posiblemente obsoleta',
    () async {
      final desktop = _FakeRewindGateway()..loseRewindAck = true;
      final service = ActiveChatService();
      final chat = service.attach(
        connection: _remoteConn(),
        sessionId: 'sess-rewind-ack-lost',
        sessionTitle: 'Rewind ACK lost',
        api: ApiClient(
          baseUrl: _remoteConn().baseUrl,
          apiKey: '',
          httpClient: MockClient((_) async => http.Response('not found', 404)),
        ),
        desktopGateway: desktop,
      );
      chat.messages = [
        {'role': 'assistant', 'content': 'respuesta original'},
        {'role': 'user', 'content': 'pregunta original', '_desktopRowId': 73},
      ];

      await chat.rewrite(
        userOrdinal: 0,
        text: 'pregunta corregida',
        model: 'hermes-agent',
      );

      expect(desktop.rewinds, hasLength(1));
      expect(
        chat.messages.any(
          (message) => message['content'] == 'respuesta original',
        ),
        isFalse,
      );
      expect(
        chat.messages.any(
          (message) => message['content'] == 'pregunta corregida',
        ),
        isTrue,
      );
      expect(chat.takeRewindRestoredOnError(), isFalse);
      service.dispose();
    },
  );
}
