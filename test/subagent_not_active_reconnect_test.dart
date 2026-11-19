// Subagents that ended while the phone was away, after a real reconnection
// (socket cut → resumeAdvertisedExistingForRecovery → rotated runtime → fenced
// subagent.list that no longer names them, no durable closure): the capsule
// says they are not active and that the final result is not available; the
// rows stay `unknown` with their identity, the card stays mounted, dismiss
// works, Stop and the queue do not change, and the UI is told when the
// durable repair settles without any other event.
//
// Fixture below adapted from transport_retained_activity_test.dart.
//
// La pastilla de actividad no puede apagarse mientras Hermes sigue trabajando
// solo porque el socket se cortó o el runtime rotó (F1/F2/F4). Lo último visto
// se conserva como «último estado conocido» hasta una prueba real: un
// `process.list`/`subagent.list` con fence sobre una sesión viva, una fila
// durable de finalización o un tope de edad. Stop y los retiros explícitos
// siguen limpiando.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/core/models/desktop_compression_outcome.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/in_memory_compression_restore_storage.dart';
import 'support/test_api_client.dart';

const _runtimeId = 'runtime-retained';
const _storedId = 'stored-retained';

/// Modela el servidor real: `process.list`/`subagent.list` son
/// `live_session=True` (solo responden sobre un runtime vivo) y, tras el reap
/// de la sesión huérfana, la recuperación ligada al roster falla con
/// `ROSTER_SESSION_NOT_ACTIVE` (preflight local del cliente real).
class _RetainingGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopRecoverySessionLifecycleGateway,
        HermesDesktopRosterBoundRecoveryGateway,
        HermesDesktopSubagentGateway,
        HermesDesktopControlGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  bool connected = true;

  /// El servidor retiró la sesión huérfana: no hay runtime al que volver.
  bool reaped = false;
  String liveRuntimeId = _runtimeId;
  List<BackgroundProcessEntry> processes = const [];
  List<DesktopSubagentSnapshot> subagents = const [];
  int processCalls = 0;
  int subagentCalls = 0;

  /// Retiene la respuesta de `subagent.list` (el roster aún no contestó).
  Completer<void>? subagentListGate;
  int rosterResumeCalls = 0;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect() async => connected = true;

  void drop() {
    connected = false;
    _events.addError(StateError('socket dropped'));
  }

  void emit(String type, Map<String, dynamic> payload) {
    _events.add(
      TuiGatewayEvent(type: type, sessionId: liveRuntimeId, payload: payload),
    );
  }

  DesktopSessionSnapshot _snapshot(String storedSessionId) =>
      DesktopSessionSnapshot(
        runtimeSessionId: liveRuntimeId,
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
    if (reaped) {
      // Attach-on-load only rejoins an advertised runtime; a reaped session
      // has none (the real client checks the roster before resuming).
      throw const TuiGatewayRpcError(
        'session.active_list',
        'Hermes no longer advertises the durable session',
        origin: CompressionFailureOrigin.localPreflight,
        data: {'reason': rosterSessionNotActiveReason},
      );
    }
    return _snapshot(storedSessionId);
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => throw StateError('no create in this fixture');

  @override
  Future<DesktopSessionSnapshot> resumeExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) async => _snapshot(storedSessionId);

  @override
  Future<DesktopRosterBoundRecovery> resumeAdvertisedExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) async {
    rosterResumeCalls += 1;
    await connect();
    if (reaped) {
      throw const TuiGatewayRpcError(
        'session.active_list',
        'Hermes no longer advertises the durable session',
        origin: CompressionFailureOrigin.localPreflight,
        data: {'reason': rosterSessionNotActiveReason},
      );
    }
    return DesktopRosterBoundRecovery.forTesting(
      _snapshot(storedSessionId),
      this,
    );
  }

  @override
  bool consumeRosterBoundRecovery(DesktopRosterBoundRecovery recovery) => true;

  @override
  bool consumeRosterBoundViewerAttachment(
    DesktopRosterBoundRecovery recovery,
  ) => true;

  @override
  // ignore: deprecated_member_use_from_same_package
  void commitRecoveryRuntime(String runtimeSessionId) {}

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<List<DesktopSubagentSnapshot>> listSubagents(
    String runtimeSessionId,
  ) async {
    subagentCalls += 1;
    await subagentListGate?.future;
    if (reaped || runtimeSessionId != liveRuntimeId) {
      throw const TuiGatewayRpcError('subagent.list', 'session not live');
    }
    return subagents;
  }

  @override
  Future<AgentCenterSnapshot> agentCenterSnapshot({
    String runtimeSessionId = '',
  }) async {
    processCalls += 1;
    if (reaped || runtimeSessionId != liveRuntimeId) {
      throw const TuiGatewayRpcError('process.list', 'session not live');
    }
    return AgentCenterSnapshot(snapshots: const [], processes: processes);
  }

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
    connected = false;
    if (!_events.isClosed) await _events.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ActiveChat _chat(
  _RetainingGateway gateway, {
  StoredSessionMessageLoader? storedMessageLoader,
  Duration retainedActivityMaxAge = const Duration(minutes: 10),
  http.Client? httpClient,
  int transcriptPageSizeForTesting = 500,
}) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  connection: SavedConnection(
    id: 'conn-retained',
    label: 'Retained',
    host: 'example.invalid',
    port: 443,
    apiKey: 'test-key',
    useHttps: true,
    kind: InstanceKind.vps,
  ),
  sessionId: _storedId,
  sessionTitle: 'Retained',
  sessionProfile: 'default',
  notifications: null,
  onTerminal: () {},
  api: testApiClient(
    baseUrl: 'http://127.0.0.1:1',
    httpClient:
        httpClient ?? MockClient((_) async => http.Response('not found', 404)),
  ),
  transcriptPageSizeForTesting: transcriptPageSizeForTesting,
  desktopGateway: gateway,
  attachDesktopRuntimeOnLoad: true,
  allowUnownedDesktopSnapshotForTesting: true,
  storedMessageLoader: storedMessageLoader,
  desktopRecoveryBackoff: const [Duration.zero],
  retainedActivityMaxAge: retainedActivityMaxAge,
);

/// `/api/sessions/{id}/messages` con la semántica `order=latest` de Hermes
/// (hermes_cli/web_routers/sessions.py): `offset` cuenta hacia atrás desde el
/// mensaje más reciente, la página llega en orden cronológico y cada fila
/// lleva su `id` SQLite y su `timestamp`.
class _PagedTranscriptServer {
  final List<Map<String, dynamic>> rows = [];
  final List<Uri> requests = [];

  http.Client client() => MockClient((request) async {
    requests.add(request.url);
    final limit = int.parse(request.url.queryParameters['limit'] ?? '120');
    final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
    final end = math.max(0, rows.length - offset);
    final start = math.max(0, end - limit);
    final page = rows.sublist(start, end);
    return http.Response(
      jsonEncode({
        'object': 'list',
        'session_id': _storedId,
        'data': page,
        'pagination': {
          'limit': limit,
          'offset': offset,
          'order': 'latest',
          'returned': page.length,
        },
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not reached before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<ActiveChat> _boundWithLiveWork(
  _RetainingGateway gateway, {
  StoredSessionMessageLoader? storedMessageLoader,
}) async {
  final chat = _chat(gateway, storedMessageLoader: storedMessageLoader);
  chat.messagesLoaded = true;
  expect(
    await chat.ensureDesktopRuntime(acquireForExplicitAction: true),
    isTrue,
  );
  // A live child keeps the pipeline executing; end that turn first so the
  // cut happens after it, while its delegated work is still running.
  if (gateway.subagents.isNotEmpty) await _endTurn(chat, gateway);
  await chat.refreshBackgroundProcessesForTesting();
  await chat.refreshSubagentsForTesting();
  return chat;
}

Future<void> _endTurn(ActiveChat chat, _RetainingGateway gateway) async {
  expect(
    await chat.send(
      fullText: 'start the background work',
      model: 'hermes-agent',
      history: const [],
    ),
    isTrue,
  );
  gateway.emit('message.start', const {});
  gateway.emit('message.complete', const {'text': 'Started.'});
  await _waitUntil(() => !chat.isStreaming);
}

// Ruta real de reconexión:
// corte de socket → resumeAdvertisedExistingForRecovery → runtime reacuñado →
// process.list / subagent.list con fence. Fixture de 8 hijos inspirado en el
// reporte, NO son los 8 reales del dueño.
const _n = 8;

class _ProbeGateway extends _RetainingGateway
    implements HermesDesktopSessionHistoryGateway {
  List<Map<String, dynamic>> history = const [];
  int historyCalls = 0;
  bool failNextProcessList = false;

  /// Responde aunque el runtime ya no sea el vivo (respuesta tardía).
  Completer<void>? historyGate;
  bool answerStaleRuntime = false;
  Completer<void>? staleGate;

  @override
  Future<SessionMessagesPage> sessionHistory({
    required String sessionId,
    String? profile,
  }) async {
    historyCalls += 1;
    await historyGate?.future;
    return SessionMessagesPage(messages: history, pagination: null);
  }

  @override
  Future<AgentCenterSnapshot> agentCenterSnapshot({
    String runtimeSessionId = '',
  }) async {
    if (failNextProcessList) {
      failNextProcessList = false;
      processCalls += 1;
      throw StateError('process.list socket cut');
    }
    return super.agentCenterSnapshot(runtimeSessionId: runtimeSessionId);
  }

  @override
  Future<List<DesktopSubagentSnapshot>> listSubagents(
    String runtimeSessionId,
  ) async {
    if (answerStaleRuntime && runtimeSessionId != liveRuntimeId) {
      subagentCalls += 1;
      await staleGate?.future;
      return const [];
    }
    return super.listSubagents(runtimeSessionId);
  }
}

Future<ActiveChat> _eightLive(
  _ProbeGateway gateway, {
  bool presented = true,
  _PagedTranscriptServer? server,
}) async {
  gateway.subagents = [
    for (var i = 1; i <= _n; i++)
      DesktopSubagentSnapshot(
        subagentId: 'child-$i',
        delegationId: 'deleg-$i',
        status: 'running',
      ),
  ];
  final chat = server == null
      ? await _boundWithLiveWork(gateway)
      : await _boundWithLiveWorkRest(gateway, server);
  chat.acquireSubagentForegroundPresentation();
  for (var i = 1; i <= _n; i++) {
    gateway.emit('subagent.start', {
      'subagent_id': 'child-$i',
      'delegation_id': 'deleg-$i',
      'status': 'running',
      'event_id': 'e$i',
      'event_revision': 1,
    });
  }
  await Future<void>.delayed(Duration.zero);
  await chat.refreshSubagentsForTesting();
  // La UI visible lee el roster en cada build (chat_screen :2288). Precondición
  // del caso real: el dueño vio los subagentes en marcha antes del hueco.
  if (presented) {}
  return chat;
}

Future<ActiveChat> _boundWithLiveWorkRest(
  _RetainingGateway gateway,
  _PagedTranscriptServer server,
) async {
  final chat = _chat(
    gateway,
    httpClient: server.client(),
    transcriptPageSizeForTesting: 120,
  );
  chat.messagesLoaded = true;
  expect(
    await chat.ensureDesktopRuntime(acquireForExplicitAction: true),
    isTrue,
  );
  if (gateway.subagents.isNotEmpty) await _endTurn(chat, gateway);
  await chat.refreshBackgroundProcessesForTesting();
  await chat.refreshSubagentsForTesting();
  return chat;
}

/// Wired as chat_screen.dart `_buildDelegatedCapsule`.
class _Capsule extends StatefulWidget {
  const _Capsule({required this.chat});
  final ActiveChat chat;
  @override
  State<_Capsule> createState() => _CapsuleState();
}

class _CapsuleState extends State<_Capsule> {
  StreamSubscription<ActiveChatEvent>? _sub;
  final Set<String> closed = {};
  int rebuilds = 0;

  @override
  void initState() {
    super.initState();
    _sub = widget.chat.changes.listen((_) {
      if (mounted) setState(() => rebuilds++);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void dismiss() => setState(() {
    closed.addAll(widget.chat.conversationSubagents.map((a) => a.key.stableId));
  });

  @override
  Widget build(BuildContext context) {
    final chat = widget.chat;
    return MaterialApp(
      theme: AppTheme.fromId('dark'),
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SubagentActivityCard(
            capsule: true,
            activities: chat.conversationSubagents,
            unconfirmed: chat.subagentRosterUnconfirmed,
            absentConfirmed: chat.subagentAbsentConfirmedKeys,
            safeChildCount: chat.safeActiveSubagentCount,
            background: chat.safeActiveSubagentCount > 0,
            onDismiss: dismiss,
            closedIds: closed,
            turnSnapshot: const ActivitySnapshot(),
            canInterrupt: (_) => false,
            clock: () => DateTime.utc(2026, 11, 15, 12),
          ),
        ),
      ),
    );
  }
}

final _capText = find.byKey(const ValueKey('delegates-capsule-text'));
final _cap = find.byKey(const ValueKey('delegates-capsule'));
final _doneClaim = RegExp(r'✓|terminaron|terminados|\blistos?\b');
final _clock = RegExp(r'\b\d+:\d{2}\b');
const _inactive = '8 subagentes · No activos · Resultado final no disponible';

String? _capsuleLabel(WidgetTester tester) =>
    _capText.evaluate().isEmpty ? null : tester.widget<Text>(_capText).data;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('after a real reconnection the children that ended away are '
      'shown not active, final result unavailable; rows, card, dismiss, Stop '
      'and queue unchanged', (tester) async {
    late ActiveChat chat;
    late _ProbeGateway g;
    late Completer<void> hgate;
    await tester.runAsync(() async {
      g = _ProbeGateway();
      chat = await _eightLive(g);
      g.history = const [
        {'role': 'user', 'content': 'delegar', 'message_id': 'u-1'},
      ];
      hgate = g.historyGate = Completer<void>();
    });
    await tester.pumpWidget(_Capsule(chat: chat));
    await tester.pump();
    // Turno padre cerrado: la cápsula viva es «Ejecutando 8 subagentes»
    // (delegatedCapsuleRunningIdle), como en chat_screen.
    expect(
      _capsuleLabel(tester),
      'Ejecutando 8 subagentes',
      reason: 'precondición: trabajo vivo presentado',
    );

    // Reconexión real: corte → resume → runtime rotado → lista vacía.
    await tester.runAsync(() async {
      g.liveRuntimeId = 'runtime-rotated';
      g.subagents = const [];
      g.drop();
      await _waitUntil(() => chat.desktopRuntimeSessionId == 'runtime-rotated');
      await chat.refreshSubagentsForTesting();
      await _waitUntil(() => g.historyCalls >= 1);
    });
    await tester.pump();
    final during = _capsuleLabel(tester);
    expect(
      during,
      contains('Sin confirmar'),
      reason: '(h) hueco honesto mientras la reparación está en vuelo',
    );

    // (h) La reparación termina sin evento, sondeo ni gesto.
    final rebuildsBefore = tester
        .state<_CapsuleState>(find.byType(_Capsule))
        .rebuilds;
    await tester.runAsync(() async {
      g.historyGate = null;
      hgate.complete();
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    final scheduled = tester.binding.hasScheduledFrame;
    final rebuildsAfter = tester
        .state<_CapsuleState>(find.byType(_Capsule))
        .rebuilds;
    expect(
      rebuildsAfter - rebuildsBefore,
      greaterThan(0),
      reason:
          '(h) el servicio notifica al cerrar la reparación, sin otro '
          'evento, sondeo ni gesto',
    );
    expect(scheduled, isTrue, reason: '(h) frame ya agendado antes del pump');
    await tester.pump();
    final label = _capsuleLabel(tester);
    final roster = chat.conversationSubagents;

    // (a) agregado de ocupación honesto.
    expect(label, _inactive);
    expect(_doneClaim.hasMatch(label ?? ''), isFalse);
    expect(_clock.hasMatch(label ?? ''), isFalse);
    // (b) filas conservadas, unknown, mismos ids.
    expect(roster.map((a) => a.subagentId).toList(), [
      for (var i = 1; i <= _n; i++) 'child-$i',
    ]);
    expect(
      roster.map((a) => a.phase),
      everyElement(SubagentActivityPhase.unknown),
    );
    // (c) Stop/cola iguales a la base.
    expect(chat.canStopSessionWork, isFalse);
    expect(chat.safeActiveSubagentCount, 0);
    // (d) identidad.
    expect(chat.sessionId, _storedId);
    expect(chat.desktopRuntimeSessionId, 'runtime-rotated');
    // (e) tarjeta montada con 8 filas y descartar disponible.
    final card = tester.widget<SubagentActivityCard>(
      find.byType(SubagentActivityCard),
    );
    expect(card.activities, hasLength(_n));
    expect(card.onDismiss, isNotNull);
    // (f) fuente del menú «Subagentes · N».
    expect(chat.conversationSubagents, hasLength(_n));
    // (g) discriminante: visible → descartar → oculta.
    expect(_cap, findsOneWidget);
    tester.state<_CapsuleState>(find.byType(_Capsule)).dismiss();
    await tester.pump();
    expect(_cap, findsNothing);
    expect(chat.conversationSubagents, hasLength(_n));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
    await tester.runAsync(() async => chat.dispose());
  });
}
