// Widget tests de ChatScreen.
//
// ChatScreen depende de un ancestro `HermesAppState` (lo busca con
// `findAncestorStateOfType<HermesAppState>()!` en didChangeDependencies para
// resolver `activeChats`/`voiceConvo`), así que no se puede montar aislado: hay
// que montar el `HermesApp` real. Los canales de plugin que arranca su initState
// (secure storage, notificaciones, foreground task) se mockean a no-op; el fallo
// de inicialización de notificaciones se captura dentro del servicio y no rompe.
//
// El estado del chat (mensajes, pipeline) vive en `ActiveChat`, dentro de
// `ActiveChatService`. Pre-adjuntamos la sesión con un ApiClient de MockClient y
// mensajes sintéticos; ChatScreen reusa ese chat (attach devuelve el existente),
// así no hay red real para los mensajes.
//
// No se usa `pumpAndSettle` (la pantalla deja futuros de red en vuelo —p.ej. el
// modelo activo del Dashboard— y hay timers): se avanza con `pump()` fijo.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/main.dart';
import 'package:hermes_android/core/companion/render/companion_message_presence.dart';
import 'package:hermes_android/core/config/flavor.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/chat_preferences.dart';
import 'package:hermes_android/core/models/command_descriptor.dart';
import 'package:hermes_android/core/models/desktop_context_breakdown.dart';
import 'package:hermes_android/core/models/desktop_model_catalog.dart';
import 'package:hermes_android/core/models/desktop_session_config.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_room.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/screens/lock_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/attachment_uploader.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/chat_preference_store.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/kanban_client.dart';
import 'package:hermes_android/core/services/mission_bot_chat_store.dart';
import 'package:hermes_android/core/services/mission_room_store.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/conversation/native_voice.dart';
import 'package:hermes_android/core/services/voice/voice_phase.dart';
import 'package:hermes_android/core/widgets/attachment_card.dart';
import 'package:hermes_android/core/widgets/attachment_history_preview.dart';
import 'package:hermes_android/core/widgets/attachment_source_sheet.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/generated_image_card.dart';
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/core/widgets/mission_profile_avatar.dart';
import 'package:hermes_android/core/widgets/motion_entrance.dart';
import 'package:hermes_android/core/widgets/session_context_usage.dart';

AgentProfileAvatar _testProfileAvatar() => AgentProfileAvatar.fromDataUri(
  'data:image/png;base64,'
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Iterable<TextSpan> _flattenTextSpans(TextSpan root) sync* {
  yield root;
  for (final child in root.children ?? const <InlineSpan>[]) {
    if (child is TextSpan) yield* _flattenTextSpans(child);
  }
}

class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this.result);

  final FilePickerResult? result;
  bool? requestedAllowMultiple;
  FileType? requestedType;
  List<String>? requestedExtensions;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    @Deprecated('Kept to match FilePicker') bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    requestedAllowMultiple = allowMultiple;
    requestedType = type;
    requestedExtensions = allowedExtensions;
    return result;
  }
}

class _FakeImagePickerPlatform extends ImagePickerPlatform {
  _FakeImagePickerPlatform({required this.multi, this.single});

  final List<XFile> multi;
  final XFile? single;
  MultiImagePickerOptions? requestedMultiOptions;
  ImagePickerOptions? requestedSingleOptions;

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    requestedMultiOptions = options;
    return multi;
  }

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    requestedSingleOptions = options;
    return single;
  }
}

class _PartialSttEngine implements SttEngine {
  _PartialSttEngine({
    this.availabilityGate,
    this.stopGate,
    this.finalOnStop,
    this.closeOnStop = false,
  });

  final Completer<bool>? availabilityGate;
  final Completer<void>? stopGate;
  final String? finalOnStop;
  final bool closeOnStop;
  int availableCalls = 0;
  int stopCalls = 0;
  bool _disposed = false;
  StreamController<SttResult> _results =
      StreamController<SttResult>.broadcast();

  StreamController<SttResult> get results => _results;

  @override
  Future<bool> available() async {
    availableCalls++;
    if (_disposed) return false;
    return availabilityGate?.future ?? true;
  }

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
    await stopGate?.future;
    final text = finalOnStop;
    if (text != null) {
      await emitFinalAndClose(text);
    } else if (closeOnStop) {
      await endSegmentWithoutFinal();
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    if (!_results.isClosed) await _results.close();
  }

  Future<void> endSegmentWithoutFinal() async {
    final completed = _results;
    _results = StreamController<SttResult>.broadcast();
    await completed.close();
  }

  Future<void> emitFinalAndClose(String text) async {
    _results.add(SttResult(text, true));
    await endSegmentWithoutFinal();
  }
}

class _UiRewindGateway
    implements
        HermesDesktopGateway,
        HermesDesktopRewindResolverGateway,
        HermesDesktopDurableRewindGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopConfiguredSessionLifecycleGateway,
        HermesDesktopCommandGateway,
        HermesDesktopLifecycleGateway,
        HermesDesktopContextUsageGateway {
  _UiRewindGateway({
    this.resumeUsage,
    this.contextUnavailableOnce = false,
    this.contextUnavailableResponses = 0,
    this.resolvedRowId = 73,
    this.survivorUserRowIds = const [11],
  });

  final DesktopUsageStats? resumeUsage;
  final bool contextUnavailableOnce;
  final int contextUnavailableResponses;
  final int? resolvedRowId;

  final List<int?>? survivorUserRowIds;
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  final List<({String text, int ordinal})> rewinds = [];
  final List<int?> rewindRowIds = [];
  final List<({String text, int ordinal})> resolutionCalls = [];
  final List<String> submissions = [];
  final List<String> steers = [];
  final List<({String runtimeId, String command})> slashCalls = [];
  final List<({String runtimeId, String name, String arg})> dispatchCalls = [];
  final List<DesktopSessionCreateConfig> createConfigs = [];
  int idleDisconnects = 0;
  Completer<DesktopCommandRpcResult>? compressionGate;
  Completer<void>? submitGate;
  Completer<void>? rewindGate;
  Completer<int?>? resolutionGate;
  Completer<void>? interruptGate;
  int interruptCalls = 0;
  Object? slashError;
  Object? dispatchError;
  Object? rewindError;
  Object? resumeExistingError;
  Object? connectError;
  bool connected = true;
  bool _compressionAccepted = false;
  DesktopSessionSnapshot? compressedSnapshot;
  int contextBreakdownCalls = 0;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect() async {
    final error = connectError;
    if (error != null) throw error;
    connected = true;
  }

  @override
  Future<void> disconnectIdle() async {
    idleDisconnects += 1;
  }

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-ui-test',
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
    final error = resumeExistingError;
    if (error != null) throw error;
    return _compressionAccepted
        ? compressedSnapshot ?? _uiCompressedSnapshot()
        : DesktopSessionSnapshot(
            runtimeSessionId: 'runtime-ui-test',
            storedSessionId: storedSessionId,
            created: false,
            info: DesktopSessionRuntimeInfo(usage: resumeUsage),
          );
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-ui-test',
    storedSessionId: 'sess-test',
    created: true,
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmitConfigured({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    required DesktopSessionCreateConfig config,
  }) async {
    createConfigs.add(config);
    return createForFirstSubmit(
      profile: profile,
      seedMessages: seedMessages,
      model: config.model?.modelId ?? '',
    );
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submissions.add(text);
    await submitGate?.future;
  }

  @override
  Future<DesktopCommandCatalog> commandsCatalog() async =>
      DesktopCommandCatalog.fromJson(const {'commands': <Object>[]});

  @override
  Future<DesktopContextBreakdown> contextBreakdown(
    String runtimeSessionId,
  ) async {
    contextBreakdownCalls += 1;
    final unavailableCount = contextUnavailableOnce
        ? 1
        : contextUnavailableResponses;
    if (contextBreakdownCalls <= unavailableCount) {
      return const DesktopContextBreakdown();
    }
    return DesktopContextBreakdown.fromJson(const {
      'categories': [
        {'id': 'system_prompt', 'label': 'System prompt', 'tokens': 1200},
        {'id': 'conversation', 'label': 'Conversation', 'tokens': 3800},
      ],
      'context_used': 5000,
      'context_max': 20000,
      'context_percent': 25,
    });
  }

  @override
  Future<SlashCompletionBatch> completeSlash(String text) async =>
      SlashCompletionBatch.fromJson(const {'items': <Object>[]}, input: text);

  @override
  Future<DesktopCommandRpcResult> slashExec(
    String runtimeSessionId,
    String command,
  ) async {
    slashCalls.add((runtimeId: runtimeSessionId, command: command));
    final error = slashError;
    if (error != null) throw error;
    final gate = compressionGate;
    final result = gate == null ? _acceptedCommandResult : await gate.future;
    if (command == 'compress' || command.startsWith('compress ')) {
      _compressionAccepted =
          result.accepted == DesktopCommandAcceptance.accepted;
    }
    return result;
  }

  @override
  Future<DesktopCommandRpcResult> commandDispatch(
    String runtimeSessionId, {
    required String name,
    String arg = '',
  }) async {
    dispatchCalls.add((runtimeId: runtimeSessionId, name: name, arg: arg));
    final error = dispatchError;
    if (error != null) throw error;
    if (name == 'compress') _compressionAccepted = true;
    return _acceptedCommandResult;
  }

  @override
  Future<int?> resolveDurableUserRowId(
    String runtimeSessionId, {
    required String sourceText,
    required int expectedOrdinal,
  }) async {
    resolutionCalls.add((text: sourceText, ordinal: expectedOrdinal));
    final gate = resolutionGate;
    return gate == null ? resolvedRowId : await gate.future;
  }

  @override
  Future<DesktopRewindAck> submitDurableRewindPrompt(
    String runtimeSessionId,
    String text,
    int truncateBeforeUserOrdinal, {
    required int truncateBeforeRowId,
  }) async {
    rewinds.add((text: text, ordinal: truncateBeforeUserOrdinal));
    rewindRowIds.add(truncateBeforeRowId);
    await rewindGate?.future;
    final error = rewindError;
    if (error != null) throw error;
    return DesktopRewindAck(survivorUserRowIds: survivorUserRowIds);
  }

  @override
  Future<void> steer(String runtimeSessionId, String text) async {
    steers.add(text);
  }

  @override
  Future<void> interrupt(String runtimeSessionId) async {
    interruptCalls += 1;
    await interruptGate?.future;
    emit('message.complete', {'text': 'Operation interrupted.'});
  }

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  void emit(String type, [Map<String, dynamic> payload = const {}]) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: 'runtime-ui-test',
        payload: payload,
      ),
    );
  }

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

class _RecordingMissionRoomStore implements MissionRoomStoreContract {
  _RecordingMissionRoomStore(this.room);

  MissionRoom room;
  String? boundManagerSessionId;
  Completer<void>? bindGate;
  int bindCalls = 0;

  @override
  Future<MissionRoom> bindManagerSession({
    required String connectionId,
    required String roomId,
    required String managerProfile,
    required String managerSessionId,
  }) async {
    expect(connectionId, room.connectionId);
    expect(roomId, room.id);
    expect(managerProfile, room.managerProfile);
    bindCalls++;
    await bindGate?.future;
    boundManagerSessionId = managerSessionId;
    room = room.copyWith(managerSessionId: managerSessionId);
    return room;
  }

  @override
  Future<void> delete(String connectionId, String roomId) async {}

  @override
  Future<MissionRoom> linkTask(
    String connectionId,
    String roomId,
    String taskId, {
    required String boardId,
  }) async {
    room = room.withLinkedTask(taskId, boardId: boardId, updatedAtMs: 2);
    return room;
  }

  @override
  List<MissionRoom> load(String connectionId) => [room];

  @override
  Future<void> unlinkOrganization(
    String connectionId,
    String organizationId,
  ) async {}

  @override
  Future<MissionRoom> save({
    required String connectionId,
    required String name,
    String? purposeLabel,
    required String managerProfile,
    required Iterable<String> memberProfiles,
    String? organizationId,
    String? managerSessionId,
    MissionRoom? existing,
  }) async => room;
}

class _ColdHistoryGateway extends _UiRewindGateway {
  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async => DesktopSessionSnapshot.fromJson(
    {
      'session_id': 'runtime-ui-test',
      'stored_session_id': storedSessionId,
      'messages': const [
        {'role': 'user', 'content': 'Pregunta cargada en frío'},
        {'role': 'assistant', 'content': 'Respuesta histórica cargada en frío'},
      ],
      'message_count': 2,
    },
    requestedStoredSessionId: storedSessionId,
    created: false,
    method: 'session.resume',
  );
}

class _ModelConfigGateway extends _UiRewindGateway
    implements
        HermesDesktopSessionConfigGateway,
        HermesDesktopModelCatalogGateway {
  final DesktopModelCatalog catalog = DesktopModelCatalog.fromJson(const {
    'model': 'old-model',
    'provider': 'provider-a',
    'providers': [
      {
        'slug': 'provider-a',
        'name': 'Proveedor A',
        'is_current': true,
        'models': ['old-model', 'new-model', 'bad-model', 'server-model'],
      },
    ],
  });

  final List<DesktopModelSelection> modelSelections = [];
  Object? modelError;

  @override
  Future<DesktopModelCatalog> modelOptions(
    String runtimeSessionId, {
    bool refresh = false,
  }) async => catalog;

  @override
  Future<DesktopConfigSetResult> setSessionModel(
    String runtimeSessionId,
    DesktopModelSelection selection, {
    bool confirmExpensiveModel = false,
  }) async {
    modelSelections.add(selection);
    final error = modelError;
    if (error != null) throw error;
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
}

const _acceptedCommandResult = DesktopCommandRpcResult(
  kind: DesktopCommandDispatchKind.none,
  accepted: DesktopCommandAcceptance.accepted,
);

DesktopSessionSnapshot _uiCompressedSnapshot() =>
    DesktopSessionSnapshot.fromJson(
      {
        'session_id': 'runtime-ui-test',
        'session_key': 'stored-ui-compressed',
        'info': {
          'stored_session_id': 'stored-ui-compressed',
          'usage': {'context_used': 4100, 'context_max': 200000},
        },
        'messages': [
          {'role': 'user', 'content': 'Resumen durable'},
          {'role': 'assistant', 'content': 'Contexto listo'},
        ],
      },
      requestedStoredSessionId: 'sess-test',
      created: false,
      method: 'session.resume',
    );

class _SubmissionGateway
    implements HermesDesktopGateway, HermesDesktopAttachmentGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  final List<String> submissions = [];
  final List<String> steers = [];
  Completer<void>? submitGate;
  Object? submitError;
  int connectCalls = 0;
  int resumeCalls = 0;
  int imageAttachCalls = 0;
  int fileAttachCalls = 0;

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {
    connectCalls++;
  }

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async {
    resumeCalls++;
    return DesktopSessionBinding(
      runtimeSessionId: 'runtime-submission-test',
      storedSessionId: storedSessionId,
      created: false,
    );
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    submissions.add(text);
    await submitGate?.future;
    final error = submitError;
    if (error != null) throw error;
  }

  @override
  Future<DesktopAttachmentResult> attachImageBytes(
    String runtimeSessionId, {
    required String filename,
    required String contentBase64,
  }) async {
    imageAttachCalls++;
    return DesktopAttachmentResult(path: '/remote/$filename');
  }

  @override
  Future<DesktopAttachmentResult> attachFileBytes(
    String runtimeSessionId, {
    required String filename,
    required String mimeType,
    required String contentBase64,
  }) async {
    fileAttachCalls++;
    return DesktopAttachmentResult(
      path: '/remote/$filename',
      refText: '@file:.hermes/$filename',
    );
  }

  @override
  Future<void> detachImage(String runtimeSessionId, String path) async {}

  void emitComplete([String text = 'hecho']) {
    _events.add(
      TuiGatewayEvent(
        type: 'message.complete',
        sessionId: 'runtime-submission-test',
        payload: {'text': text},
      ),
    );
  }

  @override
  Future<void> steer(String runtimeSessionId, String text) async {
    steers.add(text);
  }

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

class _ReasonedPromptRejection extends TuiGatewayRpcError {
  const _ReasonedPromptRejection({required this.reason})
    : super(
        'prompt.submit',
        'Session private-id already has a live owner '
            '(desktop, pid 123456, running 33m)',
        code: 4090,
      );

  @override
  final String reason;
}

class _RecoverableSubmissionGateway extends _SubmissionGateway
    implements HermesDesktopIdempotentGateway {
  int statusCalls = 0;
  DesktopTurnState statusState = DesktopTurnState.running;
  Completer<DesktopTurnStatus>? statusGate;

  @override
  Future<DesktopTurnAck> submitPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async {
    submissions.add(text);
    return DesktopTurnAck(
      accepted: true,
      clientTurnId: clientTurnId,
      serverTurnId: 'server-$clientTurnId',
      state: DesktopTurnState.accepted,
      duplicate: false,
    );
  }

  @override
  Future<DesktopTurnStatus> getTurnStatus(
    String sessionId,
    String clientTurnId,
  ) async {
    statusCalls++;
    final gate = statusGate;
    if (gate != null) return gate.future;
    return DesktopTurnStatus(
      known: true,
      clientTurnId: clientTurnId,
      serverTurnId: 'server-$clientTurnId',
      state: statusState,
    );
  }
}

class _RecordingBotModeGateway extends TuiGatewayClient {
  _RecordingBotModeGateway(super.connection);

  final StreamController<TuiGatewayEvent> _testEvents =
      StreamController<TuiGatewayEvent>.broadcast();
  int hiddenCalls = 0;

  @override
  Stream<TuiGatewayEvent> get events => _testEvents.stream;

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
    runtimeSessionId: 'runtime-bot-read-only',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionBinding> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-bot-read-only',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<void> ensureCanonicalBotChatHidden(String runtimeSessionId) async {
    hiddenCalls++;
  }

  @override
  Future<DesktopCommandCatalog> commandsCatalog() async =>
      DesktopCommandCatalog.fromJson(const {'commands': <Object>[]});

  @override
  Future<DesktopContextBreakdown> contextBreakdown(
    String runtimeSessionId,
  ) async => const DesktopContextBreakdown();

  @override
  Future<void> disconnectIdle() async {}

  @override
  Future<void> close() async {
    if (!_testEvents.isClosed) await _testEvents.close();
  }
}

/// Conexión sintética. Host 127.0.0.1 → cualquier red real (p.ej. el badge de
/// modelo del Dashboard) falla de inmediato con «connection refused», sin colgar.
SavedConnection _conn() => SavedConnection(
  id: 'conn-test',
  label: 'Test',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'k',
);

SavedConnection _remoteConn([
  String id = 'conn-test-remote',
]) => SavedConnection(
  id: id,
  label: 'Test remoto',
  host: '192.168.255.254',
  port: 8642,
  apiKey: 'k',
  // El fixture sigue siendo una instancia remota/LAN, pero cualquier consulta
  // informativa del Dashboard falla de inmediato sin tocar la red pública.
  dashboardUrl: 'http://127.0.0.1:9119',
);

Session _session() => Session(
  id: 'sess-test',
  title: 'Conversación de prueba',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 0,
  isActive: true,
  preview: '',
  startedAt: 0,
);

/// ApiClient que nunca toca la red real (404 a todo). Solo es la red de
/// seguridad: los mensajes se inyectan directamente en el chat.
ApiClient _safeApi() => ApiClient(
  baseUrl: 'http://127.0.0.1:8642',
  apiKey: 'k',
  httpClient: MockClient((_) async => http.Response('not found', 404)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};
  var failOutboxWrites = false;
  var outboxWriteCalls = 0;
  Completer<String?>? delayedOutboxRead;
  String? clipboardText;
  var foregroundServiceRunning = false;

  test('Chat no conserva superficies que entren desde abajo', () {
    final source = File('lib/core/screens/chat_screen.dart').readAsStringSync();
    expect(source, isNot(contains('showModalBottomSheet')));
    for (final key in const [
      'chat-edit-message-dialog',
      'chat-slash-help-dialog',
      'chat-session-details-dialog',
      'chat-artifacts-dialog',
      'chat-mode-dialog',
    ]) {
      expect(source, contains(key));
    }
  });

  test('Room 404/405 are deterministic unsupported writes', () {
    for (final status in const [400, 401, 403, 404, 405, 422]) {
      expect(
        isDeterministicRoomTaskWriteFailure(DashboardHttpException(status)),
        isTrue,
      );
    }
    for (final status in const [408, 409, 429, 500, 503]) {
      expect(
        isDeterministicRoomTaskWriteFailure(DashboardHttpException(status)),
        isFalse,
      );
    }
  });

  test('imagen inline respeta la frontera de privacidad antes del GET', () {
    expect(
      () => validateRemoteChatImageTransport(
        Uri.parse('http://8.8.8.8/beacon.png'),
      ),
      throwsArgumentError,
    );
    expect(
      () => validateRemoteChatImageTransport(
        Uri.parse('http://127.0.0.1:8642/local.png'),
      ),
      returnsNormally,
    );
    expect(
      () => validateRemoteChatImageRedirect(
        Uri.parse('https://images.example.test/start.png'),
        'http://8.8.8.8/beacon.png',
      ),
      throwsArgumentError,
    );
    expect(
      () => validateRemoteChatImageRedirect(
        Uri.parse('https://images.example.test/start.png'),
        'https://cdn.example.test/final.png',
      ),
      throwsArgumentError,
    );
    expect(
      validateRemoteChatImageRedirect(
        Uri.parse('https://images.example.test/start.png'),
        '/final.png',
      ),
      Uri.parse('https://images.example.test/final.png'),
    );
  });

  test('Stop escrito exige Voz, cero adjuntos y composer accesible', () {
    const stop = 'Hermes, stop.';
    expect(
      interceptsTypedVoiceStop(
        typedComposerSubmission: true,
        voiceRuntimeActive: true,
        attachmentsEmpty: true,
        composerAccessible: true,
        text: stop,
      ),
      isTrue,
    );
    for (final condition in const [
      (
        voiceRuntimeActive: false,
        attachmentsEmpty: true,
        composerAccessible: true,
      ),
      (
        voiceRuntimeActive: true,
        attachmentsEmpty: false,
        composerAccessible: true,
      ),
      (
        voiceRuntimeActive: true,
        attachmentsEmpty: true,
        composerAccessible: false,
      ),
    ]) {
      expect(
        interceptsTypedVoiceStop(
          typedComposerSubmission: true,
          voiceRuntimeActive: condition.voiceRuntimeActive,
          attachmentsEmpty: condition.attachmentsEmpty,
          composerAccessible: condition.composerAccessible,
          text: stop,
        ),
        isFalse,
      );
    }
    expect(
      interceptsTypedVoiceStop(
        typedComposerSubmission: true,
        voiceRuntimeActive: true,
        attachmentsEmpty: true,
        composerAccessible: true,
        text: 'stop the container',
      ),
      isFalse,
    );
    expect(
      interceptsTypedVoiceStop(
        typedComposerSubmission: false,
        voiceRuntimeActive: true,
        attachmentsEmpty: true,
        composerAccessible: true,
        text: stop,
      ),
      isFalse,
      reason: 'un prompt dirigido por slash/shortcut no fue texto escrito',
    );
  });

  test(
    'la galería usa multiselección y reserva modo individual al último hueco',
    () async {
      final original = ImagePickerPlatform.instance;
      final fake = _FakeImagePickerPlatform(
        multi: [XFile('/tmp/uno.png'), XFile('/tmp/dos.png')],
        single: XFile('/tmp/ultimo.png'),
      );
      ImagePickerPlatform.instance = fake;
      addTearDown(() => ImagePickerPlatform.instance = original);

      final picker = ImagePicker();
      final multi = await pickPendingGalleryImages(picker, remaining: 3);
      expect(multi, hasLength(2));
      expect(fake.requestedMultiOptions?.limit, 3);
      expect(fake.requestedSingleOptions, isNull);

      final last = await pickPendingGalleryImages(picker, remaining: 1);
      expect(last.single.path, '/tmp/ultimo.png');
      expect(fake.requestedSingleOptions, isNotNull);
    },
  );

  test('clasifica por separado límites de elemento y lote', () {
    const mib = 1024 * 1024;
    expect(
      pendingAttachmentLimitViolation(
        sizeBytes: 8 * mib,
        itemLimit: 8 * mib,
        currentBatchBytes: 16 * mib,
      ),
      isNull,
    );
    expect(
      pendingAttachmentLimitViolation(
        sizeBytes: 8 * mib + 1,
        itemLimit: 8 * mib,
        currentBatchBytes: 0,
      ),
      PendingAttachmentLimitViolation.item,
    );
    expect(
      pendingAttachmentLimitViolation(
        sizeBytes: 8 * mib,
        itemLimit: 8 * mib,
        currentBatchBytes: 16 * mib + 1,
      ),
      PendingAttachmentLimitViolation.batch,
    );
    expect(
      pendingAttachmentLimitViolation(
        sizeBytes: 0,
        itemLimit: 8 * mib,
        currentBatchBytes: 0,
      ),
      PendingAttachmentLimitViolation.invalid,
    );
  });

  void mockChannel(String name) {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }

  setUp(() {
    secureStore.clear();
    failOutboxWrites = false;
    outboxWriteCalls = 0;
    delayedOutboxRead = null;
    clipboardText = null;
    foregroundServiceRunning = false;
    TurnOutboxStore.resetSerializationForTesting();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboardText = (call.arguments as Map?)?['text'] as String?;
              return null;
            case 'Clipboard.getData':
              return clipboardText == null
                  ? null
                  : <String, dynamic>{'text': clipboardText};
          }
          return null;
        });
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                if (failOutboxWrites && args['key'] == 'chat_turn_outbox_v1') {
                  throw PlatformException(code: 'secure_unavailable');
                }
                if (args['key'] == 'chat_turn_outbox_v1') {
                  outboxWriteCalls++;
                }
                secureStore[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                final key = args['key'] as String;
                if (key == 'chat_turn_outbox_v1' && delayedOutboxRead != null) {
                  return delayedOutboxRead!.future;
                }
                return secureStore[key];
              case 'delete':
                secureStore.remove(args['key'] as String);
                return null;
              case 'readAll':
                return Map<String, String>.from(secureStore);
              case 'containsKey':
                return secureStore.containsKey(args['key'] as String);
            }
            return null;
          },
        );
    mockChannel('dexterous.com/flutter/local_notifications');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_foreground_task/methods'),
          (call) async {
            // Imita el ciclo real del servicio. Responder siempre `false`
            // dejaba al plugin sondeando cinco segundos después de un start y
            // ocultaba las carreras App Lock -> pausa -> Continuar.
            switch (call.method) {
              case 'isRunningService':
                return foregroundServiceRunning;
              case 'startService':
              case 'restartService':
                foregroundServiceRunning = true;
                return null;
              case 'stopService':
                foregroundServiceRunning = false;
                return null;
              case 'attachedActivity':
                return true;
            }
            return null;
          },
        );
    mockChannel('flutter_foreground_task/background');
  });

  /// Monta el HermesApp real (saltando splash/onboarding) y empuja ChatScreen
  /// sobre su Navigator. `messages` siembra el ActiveChat de la sesión.
  Future<ActiveChat> pumpChat(
    WidgetTester tester, {
    List<Map<String, dynamic>> messages = const [],
    _PartialSttEngine? stt,
    ChatPipelineState chatState = ChatPipelineState.idle,
    HermesDesktopGateway? desktopGateway,
    SavedConnection? connection,
    Session? session,
    bool messagesLoaded = true,
    String? initialPrompt,
    bool initialVoiceMode = false,
    bool requestComposerFocus = false,
    bool? legacyConversationEnabled,
    ChatPerformanceProbe? performanceProbe,
    ApiClient? api,
    Map<String, Object> initialPreferences = const {},
    String? initialActiveProfile,
    bool preAttach = true,
    Future<AttachmentDraft?> Function(AttachmentDraft)? attachmentMaterializer,
    Future<bool> Function(AttachmentDraft)? attachmentPrivateCopyDeleter,
    Future<void> Function()? cancelStreamOverride,
    VoidCallback? sendAttemptObserver,
    MissionRoom? missionRoom,
    MissionRoomStoreContract? missionRoomStore,
    Future<KanbanTask> Function(MissionMentionIntent intent)?
    missionRoomTaskCreator,
    Future<Iterable<String>> Function()? missionRoomWorkerRosterLoader,
    KanbanClient Function(SavedConnection connection)?
    missionRoomKanbanClientFactory,
    Future<bool> Function()? turnIdempotencyCapability,
    StoredSessionMessageLoader? storedMessageLoader,
    String? initialStoredSessionId,
    AgentProfile? missionBotProfile,
    Map<String, AgentProfile> missionRoomProfiles = const {},
    MissionProfileAvatarCache? missionAvatarCache,
  }) async {
    // Forzar locale español para que las cadenas i18n de ChatScreen coincidan
    // con las expectativas del test (el test fue escrito en español).
    tester.platformDispatcher.localesTestValue = [const Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    SharedPreferences.setMockInitialValues({
      ...initialPreferences,
      'onboarding_done': true,
      'voice_conversation_enabled': ?legacyConversationEnabled,
    });
    final prefs = await SharedPreferences.getInstance();
    final connManager = await ConnectionManager.create(prefs);
    final sec = SecureStorage();
    final activeChats = ActiveChatService();
    final targetConnection = connection ?? _conn();
    final targetSession = session ?? _session();
    if (initialActiveProfile != null) {
      await connManager.setActiveProfile(
        targetConnection.id,
        initialActiveProfile,
      );
    }

    // Pre-adjunta la sesión con mensajes ya cargados: ChatScreen reusará este
    // chat y no disparará la recarga de red.
    late ActiveChat chat;
    if (preAttach) {
      chat = activeChats.attach(
        connection: targetConnection,
        sessionId: targetSession.id,
        logicalSessionId: targetSession.logicalId,
        sessionTitle: targetSession.displayTitle,
        sessionProfile: targetSession.profile,
        initialStoredSessionId: initialStoredSessionId,
        api: api ?? _safeApi(),
        desktopGateway: desktopGateway,
        storedMessageLoader: storedMessageLoader,
        turnIdempotencyCapability: turnIdempotencyCapability,
        disableForegroundKeepAlive: desktopGateway != null,
      );
      chat.messages = List<Map<String, dynamic>>.from(messages);
      chat.messagesLoaded = messagesLoaded;
      chat.state = chatState;
    }

    await tester.pumpWidget(
      HermesApp(
        connManager: connManager,
        appLock: AppLockService(prefs),
        approvalPolicy: ApprovalPolicyService(prefs),
        fontSize: FontSizeService(prefs),
        bridgeManager: BridgeManager(sec, connManager),
        sshManager: SshManager(sec, connManager),
        sftpTransfers: SftpTransferService(
          SshManager(sec, connManager),
          NotificationService(prefs),
        ),
        sshSessions: SshSessionService(SshManager(sec, connManager)),
        notifications: NotificationService(prefs),
        activeChats: activeChats,
      ),
    );
    // Salta el splash (~3,5 s) hasta el home.
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    // La primera pasada permite que el bootstrap marque `ready`; ese cambio
    // programa la salida real 360 ms después.
    await tester.pump(const Duration(milliseconds: 400));
    // La segunda consume la salida ya programada y desmonta el Splash.
    await tester.pump(const Duration(milliseconds: 400));
    // La barra real alcanza 100 % antes del cross-fade (240 ms) y la salida
    // premium dura 460 ms. Espera a que la raíz quede totalmente estable antes
    // de medir rebuilds propios del chat.
    await tester.pump(const Duration(milliseconds: 500));

    if (stt != null) {
      tester
          .state<HermesAppState>(find.byType(HermesApp))
          .voice
          .debugSttFactory = () =>
          stt;
    }

    // Empuja ChatScreen sobre el Navigator del HermesApp usando un contexto del
    // árbol ya montado (así queda bajo HermesAppState).
    final ctx = tester.element(find.byType(Navigator).first);
    Navigator.of(ctx).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          connection: targetConnection,
          session: targetSession,
          initialPrompt: initialPrompt,
          initialVoiceMode: initialVoiceMode,
          requestComposerFocus: requestComposerFocus,
          performanceProbe: performanceProbe,
          attachmentMaterializer: attachmentMaterializer,
          attachmentPrivateCopyDeleter: attachmentPrivateCopyDeleter,
          cancelStreamOverride: cancelStreamOverride,
          sendAttemptObserver: sendAttemptObserver,
          missionRoom: missionRoom,
          missionRoomStore: missionRoomStore,
          missionRoomTaskCreator: missionRoomTaskCreator,
          missionRoomWorkerRosterLoader: missionRoomWorkerRosterLoader,
          missionRoomKanbanClientFactory: missionRoomKanbanClientFactory,
          initialStoredSessionId: initialStoredSessionId,
          missionBotProfile: missionBotProfile,
          missionRoomProfiles: missionRoomProfiles,
          missionAvatarCache: missionAvatarCache,
        ),
      ),
    );
    await tester.pump(); // procesa la navegación
    await tester.pump(const Duration(milliseconds: 350)); // transición de ruta
    if (!preAttach) {
      chat =
          activeChats.of(targetConnection.id, targetSession.id) ??
          (throw StateError('ChatScreen no enlazó la sesión esperada'));
    }
    return chat;
  }

  List<Map<String, dynamic>> scrollableChatHistory(String scope) =>
      List.generate(12, (index) {
        return {
          'id': '$scope-message-$index',
          'role': index.isEven ? 'assistant' : 'user',
          'content':
              '$scope histórico $index. '
              '${List.filled(18, 'Contenido estable.').join(' ')}',
        };
      });

  Finder chatListFinder() => find.descendant(
    of: find.byType(ChatScrollInteractionGuard),
    matching: find.byType(ListView),
  );

  Future<void> triggerChatRefresh(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('chat-control-trigger')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final dialog = find.byKey(const ValueKey('chat-control-dialog'));
    expect(dialog, findsOneWidget);
    await tester.tap(
      find.descendant(of: dialog, matching: find.byIcon(Icons.refresh_rounded)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  Future<void> pumpDesktopDelta(
    WidgetTester tester,
    _UiRewindGateway gateway,
    ActiveChat chat,
    String text, {
    required String expectedFragment,
  }) async {
    gateway.emit('message.delta', {'text': text});
    for (
      var frame = 0;
      frame < 100 && !chat.assistantContent.contains(expectedFragment);
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(chat.assistantContent, contains(expectedFragment));
    await tester.pump();
  }

  Future<ScrollController> dragChatAwayFromBottom(
    WidgetTester tester, {
    double distance = 180,
  }) async {
    final list = chatListFinder();
    expect(list, findsOneWidget);
    final controller = tester.widget<ListView>(list).controller!;
    final gesture = await tester.startGesture(tester.getCenter(list));
    await gesture.moveBy(Offset(0, distance));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(
      controller.position.pixels,
      greaterThan(controller.position.minScrollExtent),
    );
    return controller;
  }

  Future<void> settleVoiceTeardown(WidgetTester tester) async {
    foregroundServiceRunning = false;
    for (var frame = 0; frame < 3; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  void attachmentValidationFenceTest(
    String reason,
    Future<AttachmentDraft> Function(Directory temp) createAttachment, {
    Future<void> Function(AttachmentDraft attachment)? invalidateBeforeSend,
  }) {
    testWidgets('validación $reason conserva el lote y ejecuta cero RPC', (
      tester,
    ) async {
      late final Directory temp;
      late final AttachmentDraft attachment;
      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp(
          'chat-attachment-validation-',
        );
        attachment = await createAttachment(temp);
      });
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (call) async => temp.path);
      addTearDown(
        () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, null),
      );
      secureStore['chat_draft_v2_conn-test_sess-test'] = jsonEncode({
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'text': 'revisa',
        'attachments': [attachment.toJson()],
      });
      final gateway = _SubmissionGateway();

      await pumpChat(
        tester,
        connection: _remoteConn('conn-test'),
        desktopGateway: gateway,
        initialPreferences: {
          'approval_global_mode': ApprovalMode.yolo.storageKey,
        },
      );
      for (
        var frame = 0;
        frame < 20 && find.byType(AttachmentCard).evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      final transportBeforeSend = (
        connect: gateway.connectCalls,
        resume: gateway.resumeCalls,
        imageAttach: gateway.imageAttachCalls,
        fileAttach: gateway.fileAttachCalls,
        submissions: gateway.submissions.length,
        outboxWrites: outboxWriteCalls,
      );
      if (invalidateBeforeSend != null) {
        await tester.runAsync(() => invalidateBeforeSend(attachment));
      }
      await tester.tap(find.byKey(const ValueKey('send')));
      for (
        var frame = 0;
        frame < 40 &&
            find
                .text(
                  'Uno o más adjuntos ya no están disponibles o no son '
                  'válidos. Revísalos antes de volver a enviar.',
                )
                .evaluate()
                .isEmpty;
        frame++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(
        find.text(
          'Uno o más adjuntos ya no están disponibles o no son válidos. '
          'Revísalos antes de volver a enviar.',
        ),
        findsOneWidget,
      );
      expect(gateway.connectCalls, transportBeforeSend.connect);
      expect(gateway.resumeCalls, transportBeforeSend.resume);
      expect(gateway.imageAttachCalls, transportBeforeSend.imageAttach);
      expect(gateway.fileAttachCalls, transportBeforeSend.fileAttach);
      expect(gateway.submissions, hasLength(transportBeforeSend.submissions));
      expect(outboxWriteCalls, transportBeforeSend.outboxWrites);
      expect(find.byType(AttachmentCard), findsOneWidget);
    });
  }

  attachmentValidationFenceTest('de fichero ausente', (temp) async {
    final file = File('${temp.path}/ausente.pdf');
    await file.writeAsBytes([0x25, 0x50, 0x44, 0x46]);
    return AttachmentDraft(
      localId: 'missing',
      type: AttachmentType.document,
      name: 'ausente.pdf',
      mimeType: 'application/pdf',
      sizeBytes: await file.length(),
      localPath: file.path,
    );
  }, invalidateBeforeSend: (attachment) => File(attachment.localPath).delete());

  attachmentValidationFenceTest('de imagen corrupta', (temp) async {
    final image = File('${temp.path}/corrupta.gif');
    await image.writeAsBytes('<html>no es una imagen</html>'.codeUnits);
    return AttachmentDraft(
      localId: 'corrupt',
      type: AttachmentType.image,
      name: 'corrupta.gif',
      mimeType: 'image/gif',
      sizeBytes: await image.length(),
      localPath: image.path,
    );
  });

  attachmentValidationFenceTest('de límite individual', (temp) async {
    final file = File('${temp.path}/grande.pdf');
    final handle = await file.open(mode: FileMode.write);
    await handle.setPosition(AttachmentUploader.maxBytes);
    await handle.writeByte(0);
    await handle.close();
    return AttachmentDraft(
      localId: 'oversized',
      type: AttachmentType.document,
      name: 'grande.pdf',
      mimeType: 'application/pdf',
      sizeBytes: await file.length(),
      localPath: file.path,
    );
  });

  attachmentValidationFenceTest('de extensión bloqueada', (temp) async {
    final file = File('${temp.path}/payload.apk');
    await file.writeAsBytes([1]);
    return AttachmentDraft(
      localId: 'blocked',
      type: AttachmentType.document,
      name: 'payload.apk',
      mimeType: 'application/vnd.android.package-archive',
      sizeBytes: await file.length(),
      localPath: file.path,
    );
  });

  testWidgets(
    'texto y adjunto durante streaming se preparan y encolan durables',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('chat-stream-queue-');
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      final file = File('${temp.path}/cola.pdf')
        ..writeAsBytesSync([0x25, 0x50, 0x44, 0x46, 1]);
      final attachment = AttachmentDraft(
        localId: 'queued-attachment',
        type: AttachmentType.document,
        name: 'cola.pdf',
        mimeType: 'application/pdf',
        sizeBytes: file.lengthSync(),
        localPath: file.path,
      );
      secureStore['chat_draft_v2_conn-test_sess-test'] = jsonEncode({
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'text': 'Revisa después',
        'attachments': [attachment.toJson()],
      });
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (call) async => temp.path);
      addTearDown(
        () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, null),
      );

      final chat = await pumpChat(
        tester,
        chatState: ChatPipelineState.streaming,
        connection: _remoteConn('conn-test'),
        initialPreferences: {
          'approval_global_mode': ApprovalMode.yolo.storageKey,
        },
      );
      for (
        var frame = 0;
        frame < 20 && find.byType(AttachmentCard).evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(chat.state, ChatPipelineState.streaming);
      expect(find.byType(AttachmentCard), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller?.text,
        'Revisa después',
      );

      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      for (var frame = 0; frame < 40 && chat.queuedTurns.isEmpty; frame++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(chat.queuedTurns, hasLength(1));
      final queued = chat.queuedTurns.single.turn;
      expect(queued.text, 'Revisa después');
      expect(queued.fullText, contains('Revisa después'));
      expect(queued.fullText, contains('⟦hatt:v1:'));
      expect(queued.desktopText, contains('cola.pdf'));
      expect(queued.attachments.single.name, 'cola.pdf');
      expect(find.byType(AttachmentCard), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller?.text,
        isEmpty,
      );

      await tester.tap(find.byKey(const ValueKey('chat-queue-toggle')));
      await tester.pump();
      expect(find.textContaining('Revisa después'), findsOneWidget);
      expect(find.text('cola.pdf'), findsOneWidget);
    },
  );

  testWidgets('el control válido alcanza los RPC Desktop instrumentados', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync(
      'chat-attachment-transport-control-',
    );
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final file = File('${temp.path}/valido.pdf')
      ..writeAsBytesSync([0x25, 0x50, 0x44, 0x46, 1]);
    final attachment = AttachmentDraft(
      localId: 'valid-transport-control',
      type: AttachmentType.document,
      name: 'valido.pdf',
      mimeType: 'application/pdf',
      sizeBytes: file.lengthSync(),
      localPath: file.path,
    );
    secureStore['chat_draft_v2_conn-test_sess-test'] = jsonEncode({
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'text': 'revisa',
      'attachments': [attachment.toJson()],
    });
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async => temp.path);
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );
    final gateway = _SubmissionGateway();

    final chat = await pumpChat(
      tester,
      connection: _remoteConn('conn-test'),
      desktopGateway: gateway,
      initialPreferences: {
        'approval_global_mode': ApprovalMode.yolo.storageKey,
      },
    );
    for (
      var frame = 0;
      frame < 20 && find.byType(AttachmentCard).evaluate().isEmpty;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    final transportBeforeSend = (
      connect: gateway.connectCalls,
      resume: gateway.resumeCalls,
      imageAttach: gateway.imageAttachCalls,
      fileAttach: gateway.fileAttachCalls,
      submissions: gateway.submissions.length,
      outboxWrites: outboxWriteCalls,
    );
    await tester.tap(find.byKey(const ValueKey('send')));
    for (
      var frame = 0;
      frame < 80 &&
          (gateway.fileAttachCalls == 0 || gateway.submissions.isEmpty);
      frame++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(gateway.connectCalls, transportBeforeSend.connect + 1);
    expect(gateway.resumeCalls, transportBeforeSend.resume + 1);
    expect(gateway.imageAttachCalls, transportBeforeSend.imageAttach);
    expect(gateway.fileAttachCalls, transportBeforeSend.fileAttach + 1);
    expect(gateway.submissions, hasLength(transportBeforeSend.submissions + 1));
    expect(outboxWriteCalls, greaterThan(transportBeforeSend.outboxWrites));
    expect(gateway.submissions.single, contains('@file:.hermes/valido.pdf'));
    expect(
      gateway.submissions.single,
      contains(AttachmentHistoryReference.markerPrefix),
    );
    expect(gateway.submissions.single, isNot(contains(temp.path)));
    expect(gateway.submissions.single, isNot(contains(file.path)));
    final optimisticUser = chat.messages.firstWhere(
      (message) => message['role'] == 'user',
    );
    expect(
      optimisticUser['content'],
      contains(AttachmentHistoryReference.markerPrefix),
    );
    expect(optimisticUser['content'], isNot(contains(temp.path)));
    final historicalFiles = Directory(
      '${temp.path}/${AttachmentUploader.sentAttachmentDirectoryName}',
    ).listSync().whereType<File>().toList();
    expect(historicalFiles, hasLength(1));
    expect(historicalFiles.single.readAsBytesSync(), file.readAsBytesSync());
    gateway.emitComplete();
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets(
    'refresh pendiente conserva las burbujas existentes sin un frame vacío',
    (tester) async {
      final refresh = Completer<List<Map<String, dynamic>>>();
      const existingNewestFirst = <Map<String, dynamic>>[
        {'role': 'assistant', 'content': 'Respuesta visible durante refresh'},
        {'role': 'user', 'content': 'Pregunta visible durante refresh'},
      ];

      await pumpChat(
        tester,
        connection: _remoteConn('conn-refresh-keeps-transcript'),
        messages: existingNewestFirst,
        messagesLoaded: false,
        storedMessageLoader: (_, _) => refresh.future,
      );

      expect(find.text('Respuesta visible durante refresh'), findsOneWidget);
      expect(find.text('Pregunta visible durante refresh'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('chat-refresh-progress')),
        findsOneWidget,
      );

      refresh.complete(existingNewestFirst.reversed.toList(growable: false));
      await tester.pumpAndSettle();

      expect(find.text('Respuesta visible durante refresh'), findsOneWidget);
      expect(find.text('Pregunta visible durante refresh'), findsOneWidget);
    },
  );

  testWidgets(
    'refresh rechazado por streaming no invalida el vuelo pendiente',
    (tester) async {
      final refresh = Completer<List<Map<String, dynamic>>>();
      const existingNewestFirst = <Map<String, dynamic>>[
        {'role': 'assistant', 'content': 'Respuesta previa al streaming'},
        {'role': 'user', 'content': 'Pregunta previa al streaming'},
      ];
      final chat = await pumpChat(
        tester,
        connection: _remoteConn('conn-refresh-rejected-streaming'),
        messages: existingNewestFirst,
        messagesLoaded: false,
        storedMessageLoader: (_, _) => refresh.future,
      );
      expect(
        find.byKey(const ValueKey('chat-refresh-progress')),
        findsOneWidget,
      );

      chat.state = ChatPipelineState.streaming;
      await triggerChatRefresh(tester);
      chat.state = ChatPipelineState.idle;

      refresh.complete(existingNewestFirst.reversed.toList(growable: false));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const ValueKey('chat-refresh-progress')), findsNothing);
      expect(find.byKey(const ValueKey('chat-refresh-error')), findsNothing);
      expect(find.text('Respuesta previa al streaming'), findsOneWidget);
    },
  );

  testWidgets(
    'refresh fallido conserva las burbujas y superpone un error seguro',
    (tester) async {
      final refresh = Completer<List<Map<String, dynamic>>>();
      const existingNewestFirst = <Map<String, dynamic>>[
        {'role': 'assistant', 'content': 'Respuesta visible tras error'},
        {'role': 'user', 'content': 'Pregunta visible tras error'},
      ];

      await pumpChat(
        tester,
        connection: _remoteConn('conn-refresh-error-keeps-transcript'),
        messages: existingNewestFirst,
        messagesLoaded: false,
        storedMessageLoader: (_, _) => refresh.future,
      );
      refresh.completeError(StateError('raw injected refresh failure'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Respuesta visible tras error'), findsOneWidget);
      expect(find.text('Pregunta visible tras error'), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-refresh-error')), findsOneWidget);
      expect(find.textContaining('raw injected'), findsNothing);
    },
  );

  testWidgets(
    'solo el refresh vigente puede publicar estado al resolverse en orden inverso',
    (tester) async {
      final first = Completer<List<Map<String, dynamic>>>();
      final second = Completer<List<Map<String, dynamic>>>();
      final loads = [first, second];
      var loadCalls = 0;

      await pumpChat(
        tester,
        connection: _remoteConn('conn-refresh-latest-wins'),
        messages: const [
          {'role': 'assistant', 'content': 'Transcript previo'},
          {'role': 'user', 'content': 'Pregunta previa'},
        ],
        messagesLoaded: false,
        storedMessageLoader: (_, _) => loads[loadCalls++].future,
      );
      expect(loadCalls, 1);

      await triggerChatRefresh(tester);
      expect(loadCalls, 2);

      second.complete(const [
        {'role': 'user', 'content': 'Pregunta vigente'},
        {'role': 'assistant', 'content': 'Respuesta vigente'},
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Respuesta vigente'), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-refresh-progress')), findsNothing);

      first.completeError(StateError('refresh obsoleto'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Respuesta vigente'), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-refresh-error')), findsNothing);
      expect(find.textContaining('refresh obsoleto'), findsNothing);
    },
  );

  testWidgets(
    'refresh con inserciones nuevas conserva la burbuja visible del lector',
    (tester) async {
      final refresh = Completer<List<Map<String, dynamic>>>();
      final history = scrollableChatHistory('ancla refresh');
      await pumpChat(
        tester,
        connection: _remoteConn('conn-refresh-visible-anchor'),
        messages: history,
        storedMessageLoader: (_, _) => refresh.future,
      );

      final list = chatListFinder();
      final controller = tester.widget<ListView>(list).controller!;
      controller.jumpTo(controller.position.maxScrollExtent * 0.55);
      await tester.pump();
      expect(controller.position.pixels, greaterThan(100));

      final viewport = tester.getRect(list);
      Finder? marker;
      int? markerIndex;
      for (var index = 0; index < history.length; index++) {
        final candidate = find.textContaining(
          'ancla refresh histórico $index.',
        );
        if (candidate.evaluate().isEmpty) continue;
        final rect = tester.getRect(candidate.first);
        if (rect.top >= viewport.top && rect.bottom <= viewport.bottom) {
          marker = candidate.first;
          markerIndex = index;
          break;
        }
      }
      expect(marker, isNotNull, reason: 'el historial debe exponer un ancla');
      final markerY = tester.getTopLeft(marker!).dy;

      await triggerChatRefresh(tester);
      refresh.complete([
        ...history.reversed.map(Map<String, dynamic>.from),
        const {'role': 'user', 'content': 'Pregunta nueva del refresh'},
        const {
          'role': 'assistant',
          'content':
              'Respuesta nueva insertada. Respuesta nueva insertada. '
              'Respuesta nueva insertada. Respuesta nueva insertada.',
        },
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();

      final refreshedMarker = find.textContaining(
        'ancla refresh histórico $markerIndex.',
      );
      expect(refreshedMarker, findsOneWidget);
      expect(
        tester.getTopLeft(refreshedMarker).dy,
        closeTo(markerY, 1),
        reason: 'la burbuja visible, no el offset bruto, debe quedar anclada',
      );
    },
  );

  testWidgets(
    'desplazamiento voluntario durante refresh reemplaza el ancla inicial',
    (tester) async {
      final refresh = Completer<List<Map<String, dynamic>>>();
      final history = List.generate(24, (index) {
        return {
          'id': 'reader-refresh-message-$index',
          'role': index.isEven ? 'assistant' : 'user',
          'content':
              'lector durante refresh histórico $index. '
              '${List.filled(18, 'Contenido estable.').join(' ')}',
        };
      });
      final chat = await pumpChat(
        tester,
        connection: _remoteConn('conn-refresh-user-scroll'),
        messages: history,
        storedMessageLoader: (_, _) => refresh.future,
      );

      final list = chatListFinder();
      final controller = tester.widget<ListView>(list).controller!;
      controller.jumpTo(controller.position.maxScrollExtent * 0.65);
      await tester.pump();
      final offsetBeforeGesture = controller.position.pixels;
      expect(offsetBeforeGesture, greaterThan(100));
      await triggerChatRefresh(tester);
      chat.debugEmitMessagesHydrated();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      await tester.drag(list, const Offset(0, -220));
      await tester.pump();
      expect(
        (controller.position.pixels - offsetBeforeGesture).abs(),
        greaterThan(100),
      );

      final viewport = tester.getRect(list);
      Finder? marker;
      int? markerIndex;
      for (var index = 0; index < history.length; index++) {
        final candidate = find.textContaining(
          'lector durante refresh histórico $index.',
        );
        if (candidate.evaluate().isEmpty) continue;
        final rect = tester.getRect(candidate.first);
        if (rect.top >= viewport.top && rect.bottom <= viewport.bottom) {
          marker = candidate.first;
          markerIndex = index;
          break;
        }
      }
      expect(
        marker,
        isNotNull,
        reason: 'el gesto debe dejar una burbuja visible',
      );
      final markerYAfterGesture = tester.getTopLeft(marker!).dy;

      refresh.complete([
        ...history.reversed.map(Map<String, dynamic>.from),
        const {'role': 'user', 'content': 'Pregunta llegada tras el gesto'},
        const {
          'role': 'assistant',
          'content':
              'Respuesta llegada tras el gesto. Respuesta llegada tras el gesto. '
              'Respuesta llegada tras el gesto.',
        },
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();

      final refreshedMarker = find.textContaining(
        'lector durante refresh histórico $markerIndex.',
      );
      expect(refreshedMarker, findsOneWidget);
      expect(
        tester.getTopLeft(refreshedMarker).dy,
        closeTo(markerYAfterGesture, 1),
        reason: 'el refresh no puede deshacer el scroll posterior del lector',
      );
    },
  );

  testWidgets('éxito stale no publica sobre el refresh vigente pendiente', (
    tester,
  ) async {
    final first = Completer<List<Map<String, dynamic>>>();
    final second = Completer<List<Map<String, dynamic>>>();
    final loads = [first, second];
    var loadCalls = 0;
    await pumpChat(
      tester,
      connection: _remoteConn('conn-refresh-stale-success'),
      messages: const [
        {'role': 'assistant', 'content': 'Transcript previo al stale'},
        {'role': 'user', 'content': 'Pregunta previa al stale'},
      ],
      messagesLoaded: false,
      storedMessageLoader: (_, _) => loads[loadCalls++].future,
    );
    await triggerChatRefresh(tester);

    first.complete(const [
      {'role': 'user', 'content': 'Pregunta stale'},
      {'role': 'assistant', 'content': 'Respuesta stale'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('chat-refresh-progress')), findsOneWidget);

    second.complete(const [
      {'role': 'user', 'content': 'Pregunta vigente final'},
      {'role': 'assistant', 'content': 'Respuesta vigente final'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Respuesta vigente final'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-refresh-progress')), findsNothing);
  });

  testWidgets('renderiza el campo de entrada y el botón de acción', (
    tester,
  ) async {
    await pumpChat(tester);

    expect(find.byType(ChatScreen), findsOneWidget);
    final newSessionButton = find.byKey(const ValueKey('chat-new-session'));
    expect(newSessionButton, findsOneWidget);
    expect(
      find.descendant(
        of: newSessionButton,
        matching: find.byIcon(Icons.add_rounded),
      ),
      findsOneWidget,
    );
    // Campo de texto del composer (con su placeholder).
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Pregunta a Hermes…'), findsOneWidget);
    // Composer vacío: con el modo voz habilitado el hueco lo ocupa su botón;
    // con el modo retirado (spec 027) la flecha de enviar está siempre.
    expect(
      find.byKey(ValueKey(kVoiceModeEnabled ? 'voice' : 'send')),
      findsOneWidget,
    );
    if (kVoiceModeEnabled) {
      expect(find.byKey(const ValueKey('send')), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'imagen estructurada pinta una tarjeta aunque content no incluya ruta',
    (tester) async {
      await pumpChat(
        tester,
        messages: const [
          {
            'role': 'assistant',
            'content': 'La imagen ya está preparada.',
            '_generatedImages': [
              {
                'basename': 'solo-metadata.png',
                'tool_call_id': 'call-image-metadata-only',
                'echo_sources': <String>[],
              },
            ],
          },
          {'role': 'user', 'content': 'Genera una imagen'},
        ],
      );

      expect(find.byType(GeneratedImageCard), findsOneWidget);
      expect(
        find.textContaining('La imagen ya está preparada.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'imagen HTTPS estructurada crea tarjeta sin depender del Bridge',
    (tester) async {
      const source = 'https://127.0.0.1:1/generated.png?token=widget-secret';
      await pumpChat(
        tester,
        messages: const [
          {
            'role': 'assistant',
            'content': 'La imagen remota ya está preparada.\n$source',
            '_generatedImages': [
              {
                'kind': 'https',
                'source': source,
                'tool_call_id': 'call-image-https-widget',
                'echo_sources': [source],
              },
            ],
          },
          {'role': 'user', 'content': 'Genera una imagen remota'},
        ],
      );

      expect(find.byType(GeneratedImageCard), findsOneWidget);
      expect(find.textContaining(source), findsNothing);
      final renderedKeys = tester.allWidgets
          .map((widget) => widget.key?.toString() ?? '')
          .join('\n');
      expect(renderedKeys, isNot(contains('widget-secret')));
      expect(renderedKeys, isNot(contains('127.0.0.1')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dos calls con el mismo basename pintan dos tarjetas', (
    tester,
  ) async {
    await pumpChat(
      tester,
      messages: const [
        {
          'role': 'assistant',
          'content': 'Aquí están las dos variantes.',
          '_generatedImages': [
            {
              'kind': 'serverCache',
              'source': '/home/a/.hermes/cache/images/shared.png',
              'basename': 'shared.png',
              'tool_call_id': 'call-a',
            },
            {
              'kind': 'serverCache',
              'source': '/home/b/.hermes/cache/images/shared.png',
              'basename': 'shared.png',
              'tool_call_id': 'call-b',
            },
          ],
        },
        {'role': 'user', 'content': 'Genera dos variantes'},
      ],
    );

    expect(find.byType(GeneratedImageCard), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'metadata HTTP o con userinfo se ignora sin romper la respuesta',
    (tester) async {
      await pumpChat(
        tester,
        messages: const [
          {
            'role': 'assistant',
            'content': 'La respuesta útil permanece visible.',
            '_generatedImages': [
              {
                'kind': 'https',
                'source': 'http://cdn.example/insegura.png',
                'tool_call_id': 'call-http',
              },
              {
                'kind': 'https',
                'source': 'https://user:pass@cdn.example/insegura.png',
                'tool_call_id': 'call-userinfo',
              },
            ],
          },
          {'role': 'user', 'content': 'Prueba degradada'},
        ],
      );

      expect(find.byType(GeneratedImageCard), findsNothing);
      expect(
        find.textContaining('La respuesta útil permanece visible.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'imagen estructurada pinta una tarjeta y retira solo el eco de ruta',
    (tester) async {
      const path = '/home/hermes/.hermes/cache/images/resultado.png';
      await pumpChat(
        tester,
        messages: const [
          {
            'role': 'assistant',
            'content':
                'Imagen terminada.\n$path\nPuedes pedirme otra variante.',
            '_generatedImages': [
              {
                'basename': 'resultado.png',
                'tool_call_id': 'call-image-1',
                'echo_sources': [path],
              },
            ],
          },
          {'role': 'user', 'content': 'Genera una imagen'},
        ],
      );

      expect(find.byType(GeneratedImageCard), findsOneWidget);
      expect(find.textContaining('Imagen terminada.'), findsOneWidget);
      expect(
        find.textContaining('Puedes pedirme otra variante.'),
        findsOneWidget,
      );
      expect(find.textContaining(path), findsNothing);
    },
  );

  testWidgets(
    'respuesta larga no duplica la imagen estructurada entre slices',
    (tester) async {
      const path = '/home/hermes/.hermes/cache/images/long-answer.png';
      final firstSlice = List.filled(
        150,
        'Bloque inicial de respuesta larga estable.',
      ).join(' ');
      const footer = 'Cierre útil de la respuesta larga.';
      await pumpChat(
        tester,
        messages: [
          {
            'role': 'assistant',
            'content': '$firstSlice\n\n$path\n\n$footer',
            '_generatedImages': const [
              {
                'basename': 'long-answer.png',
                'tool_call_id': 'call-image-long',
                'echo_sources': [path],
              },
            ],
          },
          {'role': 'user', 'content': 'Genera una respuesta larga'},
        ],
      );

      expect(find.byType(GeneratedImageCard), findsOneWidget);
      expect(find.textContaining(path), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('metadata de imagen inválida no rompe la respuesta', (
    tester,
  ) async {
    await pumpChat(
      tester,
      messages: const [
        {
          'role': 'assistant',
          'content': 'La respuesta útil permanece visible.',
          '_generatedImages': [
            {
              'basename': '../../escape.png',
              'tool_call_id': 'call-image-invalid',
              'echo_sources': ['/tmp/escape.png'],
            },
          ],
        },
        {'role': 'user', 'content': 'Prueba degradada'},
      ],
    );

    expect(find.byType(GeneratedImageCard), findsNothing);
    expect(
      find.textContaining('La respuesta útil permanece visible.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('read-only official Bot Chat never hides or mutates remotely', (
    tester,
  ) async {
    final connection = _conn().copyWith(readOnly: true);
    final gateway = _RecordingBotModeGateway(connection);
    addTearDown(gateway.close);
    await pumpChat(
      tester,
      connection: connection,
      desktopGateway: gateway,
      initialStoredSessionId: 'stored-bot-read-only',
      session: const Session(
        id: 'mob-bot-manager',
        lineageRootId: 'stored-bot-read-only',
        title: 'Bot Chat',
        model: 'hermes-agent',
        source: 'bot-mode',
        messageCount: 0,
        isActive: true,
        preview: '',
        startedAt: 0,
        profile: 'manager',
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(gateway.hiddenCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('un draft móvil no consulta métricas antes de persistirse', (
    tester,
  ) async {
    var sessionDetailRequests = 0;
    final api = ApiClient(
      baseUrl: 'http://127.0.0.1:8642',
      apiKey: 'k',
      httpClient: MockClient((request) async {
        if (request.url.path.startsWith('/api/sessions/mob-voice-draft')) {
          sessionDetailRequests += 1;
        }
        return http.Response('not found', 404);
      }),
    );
    addTearDown(api.close);

    await pumpChat(
      tester,
      api: api,
      session: Session(
        id: 'mob-voice-draft',
        title: 'Nueva conversación',
        model: 'hermes-agent',
        source: 'mobile',
        messageCount: 0,
        isActive: true,
        preview: '',
        startedAt: DateTime.now().millisecondsSinceEpoch / 1000,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(sessionDetailRequests, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el + del chat abre y cierra el popover de tres fuentes', (
    tester,
  ) async {
    await pumpChat(tester);
    final anchor = find.byKey(const ValueKey('composer-add'));

    expect(tester.getSize(anchor), const Size(48, 48));
    await tester.tap(anchor);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(MenuItemButton), findsNWidgets(3));
    expect(find.text('Cámara'), findsOneWidget);
    expect(find.text('Galería'), findsOneWidget);
    expect(find.text('Archivos'), findsOneWidget);
    expect(find.text('Extensiones'), findsNothing);
    expect(find.text('Inteligencia'), findsNothing);

    await tester.tap(anchor);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(MenuItemButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el + sigue disponible mientras el turno está activo', (
    tester,
  ) async {
    await pumpChat(tester, chatState: ChatPipelineState.streaming);
    final anchor = find.byKey(const ValueKey('composer-add'));

    await tester.tap(anchor);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(MenuItemButton), findsNWidgets(3));
    expect(find.text('Cámara'), findsOneWidget);
    expect(find.text('Galería'), findsOneWidget);
    expect(find.text('Archivos'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el botón único cambia a Enviar al escribir durante streaming', (
    tester,
  ) async {
    await pumpChat(tester, chatState: ChatPipelineState.streaming);

    await tester.enterText(
      find.byType(TextField).last,
      'BORRADOR_DURANTE_TURNO',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('stop')), findsNothing);
    expect(find.byKey(const ValueKey('stop-stream')), findsNothing);
    expect(find.byKey(const ValueKey('send')), findsOneWidget);
    expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);
    expect(find.byIcon(Icons.stop_rounded), findsNothing);
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
  });

  testWidgets('Stop en vuelo bloquea steering hasta quedar durable', (
    tester,
  ) async {
    final cancelGate = Completer<void>();
    var cancelCalls = 0;
    final gateway = _SubmissionGateway();
    await pumpChat(
      tester,
      chatState: ChatPipelineState.streaming,
      desktopGateway: gateway,
      cancelStreamOverride: () async {
        cancelCalls++;
        await cancelGate.future;
      },
    );

    await tester.enterText(find.byType(TextField).last, 'steering pendiente');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('send')), findsOneWidget);
    expect(find.byKey(const ValueKey('stop')), findsNothing);

    await tester.enterText(find.byType(TextField).last, '');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('stop')).last);
    await tester.pump();
    expect(cancelCalls, 1);

    await tester.enterText(find.byType(TextField).last, 'steering pendiente');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();

    expect(gateway.steers, isEmpty);
    cancelGate.complete();
    await tester.pump(const Duration(milliseconds: 1300));
  });

  testWidgets('pegar imagen desde el IME crea un adjunto durante el turno', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('chat-ime-image-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async => temp.path);
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );
    await pumpChat(
      tester,
      chatState: ChatPipelineState.streaming,
      attachmentMaterializer: (attachment) async => attachment,
    );
    final field = tester.widget<TextField>(find.byType(TextField).last);
    expect(field.contentInsertionConfiguration, isNotNull);

    field.contentInsertionConfiguration!.onContentInserted(
      KeyboardInsertedContent(
        mimeType: 'image/png',
        uri: 'content://keyboard/pasted.png',
        data: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
          'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      ),
    );
    for (
      var frame = 0;
      frame < 30 && find.byType(AttachmentCard).evaluate().isEmpty;
      frame++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(find.byType(AttachmentCard), findsOneWidget);
  });

  testWidgets('pegados IME concurrentes se serializan y deduplican', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('chat-ime-race-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async => temp.path);
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );
    final materializeGate = Completer<void>();
    var materializations = 0;
    await pumpChat(
      tester,
      chatState: ChatPipelineState.streaming,
      attachmentMaterializer: (draft) async {
        materializations++;
        await materializeGate.future;
        return draft;
      },
      attachmentPrivateCopyDeleter: (_) async => true,
    );

    final field = tester.widget<TextField>(find.byType(TextField).last);
    final content = KeyboardInsertedContent(
      mimeType: 'image/png',
      uri: '',
      data: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
    field.contentInsertionConfiguration!.onContentInserted(content);
    field.contentInsertionConfiguration!.onContentInserted(content);
    for (var frame = 0; frame < 30 && materializations == 0; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    for (var frame = 0; frame < 5; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(materializations, 1);
    materializeGate.complete();
    for (
      var frame = 0;
      frame < 30 && find.byType(AttachmentCard).evaluate().isEmpty;
      frame++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(find.byType(AttachmentCard), findsOneWidget);
    expect(materializations, 1);
  });

  testWidgets('materialización IME en vuelo bloquea Send', (tester) async {
    final temp = Directory.systemTemp.createTempSync('chat-ime-send-race-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async => temp.path);
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );
    final materializeGate = Completer<void>();
    var materializations = 0;
    final gateway = _SubmissionGateway();
    var sendAttempts = 0;
    await pumpChat(
      tester,
      desktopGateway: gateway,
      sendAttemptObserver: () => sendAttempts++,
      attachmentMaterializer: (draft) async {
        materializations++;
        await materializeGate.future;
        return draft;
      },
      attachmentPrivateCopyDeleter: (_) async => true,
    );

    final field = tester.widget<TextField>(find.byType(TextField).last);
    field.contentInsertionConfiguration!.onContentInserted(
      KeyboardInsertedContent(
        mimeType: 'image/png',
        uri: '',
        data: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      ),
    );
    for (var frame = 0; frame < 30 && materializations == 0; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(materializations, 1);

    await tester.enterText(find.byType(TextField).last, 'no enviar todavía');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();

    expect(sendAttempts, 0);
    expect(gateway.submissions, isEmpty);
    materializeGate.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  });

  testWidgets(
    'Archivos admite lote, deduplica, aplica límite y limpia al quitar',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temp = Directory.systemTemp.createTempSync(
        'chat-attachment-picker-',
      );
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      File pdf(String name, int marker) =>
          File('${temp.path}/$name')
            ..writeAsBytesSync([0x25, 0x50, 0x44, 0x46, marker]);
      final first = pdf('primero.pdf', 1);
      final duplicate = pdf('duplicado.pdf', 1);
      final second = pdf('segundo.pdf', 2);
      final source = File('${temp.path}/tarea.py')
        ..writeAsStringSync('print("archivo visible")');
      final blocked = File('${temp.path}/payload.apk')
        ..writeAsBytesSync([0x50, 0x4b, 0x03, 0x04]);
      final oversized = File('${temp.path}/grande.pdf');
      final oversizedHandle = oversized.openSync(mode: FileMode.write);
      oversizedHandle
        ..setPositionSync(8 * 1024 * 1024)
        ..writeByteSync(0)
        ..closeSync();

      PlatformFile platformFile(File file) => PlatformFile(
        name: file.uri.pathSegments.last,
        path: file.path,
        size: file.lengthSync(),
      );
      final picker = _FakeFilePicker(
        FilePickerResult([
          platformFile(first),
          platformFile(duplicate),
          platformFile(second),
          platformFile(source),
          platformFile(blocked),
          platformFile(oversized),
        ]),
      );
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = _FakeFilePicker(null));

      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (call) async => temp.path);
      addTearDown(
        () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, null),
      );

      await pumpChat(tester);
      await tester.tap(find.byKey(const ValueKey('composer-add')));
      await tester.pump();
      tester
          .widget<MenuItemButton>(find.byType(MenuItemButton).last)
          .onPressed!();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      for (
        var frame = 0;
        frame < 240 && find.byType(AttachmentCard).evaluate().length < 3;
        frame++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(picker.requestedAllowMultiple, isTrue);
      expect(picker.requestedType, FileType.any);
      expect(picker.requestedExtensions, isNull);
      expect(find.byType(AttachmentCard), findsNWidgets(3));
      expect(find.text('primero.pdf'), findsOneWidget);
      expect(find.text('duplicado.pdf'), findsNothing);
      expect(find.text('segundo.pdf'), findsOneWidget);
      expect(find.text('tarea.py'), findsOneWidget);
      expect(find.text('payload.apk'), findsNothing);
      expect(find.textContaining('8 MB'), findsOneWidget);
      final draftsDir = Directory('${temp.path}/attachment_drafts');
      expect(draftsDir.listSync().whereType<File>(), hasLength(3));

      final firstCard = find.byType(AttachmentCard).first;
      await tester.tap(
        find.descendant(of: firstCard, matching: find.byIcon(Icons.close)),
      );
      await tester.pump();
      for (
        var frame = 0;
        frame < 40 && draftsDir.listSync().whereType<File>().length > 1;
        frame++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(find.byType(AttachmentCard), findsNWidgets(2));
      expect(draftsDir.listSync().whereType<File>(), hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('el límite total de adjuntos usa copy de lote, no de archivo', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('chat-batch-limit-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async => temp.path);
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );
    final existing = <AttachmentDraft>[];
    for (var index = 0; index < 3; index++) {
      final file = File('${temp.path}/existing-$index.pdf')
        ..writeAsBytesSync([0x25, 0x50, 0x44, 0x46, index]);
      existing.add(
        AttachmentDraft(
          localId: 'existing-$index',
          type: AttachmentType.document,
          name: 'existing-$index.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 8 * 1024 * 1024,
          localPath: file.path,
        ),
      );
    }
    secureStore['chat_draft_v2_conn-test_sess-test'] = jsonEncode({
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'text': '',
      'attachments': existing.map((attachment) => attachment.toJson()).toList(),
    });
    final extra = File('${temp.path}/extra.pdf')
      ..writeAsBytesSync([0x25, 0x50, 0x44, 0x46, 9]);
    final picker = _FakeFilePicker(
      FilePickerResult([
        PlatformFile(
          name: 'extra.pdf',
          path: extra.path,
          size: extra.lengthSync(),
        ),
      ]),
    );
    FilePicker.platform = picker;
    addTearDown(() => FilePicker.platform = _FakeFilePicker(null));

    await pumpChat(tester);
    for (
      var frame = 0;
      frame < 20 && find.byType(AttachmentCard).evaluate().length < 3;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.tap(find.byKey(const ValueKey('composer-add')));
    await tester.pump();
    tester
        .widget<MenuItemButton>(find.byType(MenuItemButton).last)
        .onPressed!();
    for (
      var frame = 0;
      frame < 40 &&
          find
              .text(
                'Los adjuntos seleccionados superan el límite total de 24 MB.',
              )
              .evaluate()
              .isEmpty;
      frame++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(
      find.text('Los adjuntos seleccionados superan el límite total de 24 MB.'),
      findsOneWidget,
    );
    expect(find.text('extra.pdf'), findsNothing);
    expect(find.byType(AttachmentCard), findsNWidgets(3));
  });

  testWidgets('Galería deduplica por contenido y conserva como máximo 10', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temp = Directory.systemTemp.createTempSync('chat-gallery-dedupe-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    File image(String name, List<int> bytes) =>
        File('${temp.path}/$name')..writeAsBytesSync(bytes);
    final firstBytes = <int>[...png, 0];
    final selected = <File>[
      image('primera.png', firstBytes),
      image('duplicada.png', firstBytes),
      for (var index = 1; index <= 10; index++)
        image('unica-$index.png', <int>[...png, index]),
    ];
    final original = ImagePickerPlatform.instance;
    final fake = _FakeImagePickerPlatform(
      multi: selected.map((file) => XFile(file.path)).toList(),
    );
    ImagePickerPlatform.instance = fake;
    addTearDown(() => ImagePickerPlatform.instance = original);
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async => temp.path);
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );

    await pumpChat(
      tester,
      attachmentMaterializer: (attachment) async => attachment,
    );
    await tester.tap(find.byKey(const ValueKey('composer-add')));
    await tester.pump();
    tester
        .widget<MenuItemButton>(find.byType(MenuItemButton).at(1))
        .onPressed!();
    for (
      var frame = 0;
      frame < 120 && find.byType(AttachmentCard).evaluate().length < 10;
      frame++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(fake.requestedMultiOptions?.limit, 10);
    expect(find.byType(AttachmentCard), findsNWidgets(10));
    final names = tester
        .widgetList<AttachmentCard>(find.byType(AttachmentCard))
        .map((card) => card.name)
        .toList();
    expect(names, contains('primera.png'));
    expect(names, isNot(contains('duplicada.png')));
    expect(names, contains('unica-9.png'));
    expect(names, isNot(contains('unica-10.png')));
  });

  testWidgets('Galería deduplica contra una imagen ya presente en el draft', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temp = Directory.systemTemp.createTempSync(
      'chat-gallery-existing-dedupe-',
    );
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    final existing = File('${temp.path}/existente.png')
      ..writeAsBytesSync([...png, 1]);
    final duplicate = File('${temp.path}/duplicada.png')
      ..writeAsBytesSync([...png, 1]);
    final unique = File('${temp.path}/nueva.png')
      ..writeAsBytesSync([...png, 2]);
    final existingDraft = AttachmentDraft(
      localId: 'existing-image',
      type: AttachmentType.image,
      name: 'existente.png',
      mimeType: 'image/png',
      sizeBytes: existing.lengthSync(),
      localPath: existing.path,
    );
    secureStore['chat_draft_v2_conn-test_sess-test'] = jsonEncode({
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'text': '',
      'attachments': [existingDraft.toJson()],
    });
    final original = ImagePickerPlatform.instance;
    final fake = _FakeImagePickerPlatform(
      multi: [XFile(duplicate.path), XFile(unique.path)],
    );
    ImagePickerPlatform.instance = fake;
    addTearDown(() => ImagePickerPlatform.instance = original);
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async => temp.path);
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );

    await pumpChat(
      tester,
      attachmentMaterializer: (attachment) async => attachment,
    );
    for (
      var frame = 0;
      frame < 20 && find.byType(AttachmentCard).evaluate().isEmpty;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(
      tester
          .widgetList<AttachmentCard>(find.byType(AttachmentCard))
          .map((card) => card.name),
      contains('existente.png'),
    );
    await tester.tap(find.byKey(const ValueKey('composer-add')));
    await tester.pump();
    tester
        .widget<MenuItemButton>(find.byType(MenuItemButton).at(1))
        .onPressed!();
    for (
      var frame = 0;
      frame < 80 && find.byType(AttachmentCard).evaluate().length < 2;
      frame++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(fake.requestedMultiOptions?.limit, 9);
    expect(find.byType(AttachmentCard), findsNWidgets(2));
    final names = tester
        .widgetList<AttachmentCard>(find.byType(AttachmentCard))
        .map((card) => card.name)
        .toList();
    expect(names, contains('existente.png'));
    expect(names, isNot(contains('duplicada.png')));
    expect(names, contains('nueva.png'));
  });

  testWidgets('Galería explica el máximo y no abre picker con 10 imágenes', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('chat-gallery-maximum-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async => temp.path);
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );
    final attachments = <AttachmentDraft>[];
    for (var index = 0; index < 10; index++) {
      final file = File('${temp.path}/image-$index.png')
        ..writeAsBytesSync([0x89, 0x50, 0x4e, 0x47, index]);
      attachments.add(
        AttachmentDraft(
          localId: 'image-$index',
          type: AttachmentType.image,
          name: 'image-$index.png',
          mimeType: 'image/png',
          sizeBytes: file.lengthSync(),
          localPath: file.path,
        ),
      );
    }
    secureStore['chat_draft_v2_conn-test_sess-test'] = jsonEncode({
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'text': '',
      'attachments': attachments
          .map((attachment) => attachment.toJson())
          .toList(),
    });
    final original = ImagePickerPlatform.instance;
    final fake = _FakeImagePickerPlatform(multi: const []);
    ImagePickerPlatform.instance = fake;
    addTearDown(() => ImagePickerPlatform.instance = original);

    await pumpChat(tester);
    await tester.tap(find.byKey(const ValueKey('composer-add')));
    await tester.pump();
    tester
        .widget<MenuItemButton>(find.byType(MenuItemButton).at(1))
        .onPressed!();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.text('Puedes adjuntar hasta 10 imágenes por mensaje.'),
      findsOneWidget,
    );
    expect(fake.requestedMultiOptions, isNull);
    expect(fake.requestedSingleOptions, isNull);
  });

  testWidgets('cerrar durante materialización limpia todas las copias nuevas', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync(
      'chat-attachment-unmount-',
    );
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    File document(String name, int marker) =>
        File('${temp.path}/$name')
          ..writeAsBytesSync([0x25, 0x50, 0x44, 0x46, marker]);
    final first = document('primero.pdf', 1);
    final second = document('segundo.pdf', 2);
    PlatformFile platformFile(File file) => PlatformFile(
      name: file.uri.pathSegments.last,
      path: file.path,
      size: file.lengthSync(),
    );
    final picker = _FakeFilePicker(
      FilePickerResult([platformFile(first), platformFile(second)]),
    );
    FilePicker.platform = picker;
    addTearDown(() => FilePicker.platform = _FakeFilePicker(null));
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async => temp.path);
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );
    final secondCopyGate = Completer<void>();
    final deleted = <String>[];
    var materializeCalls = 0;

    await pumpChat(
      tester,
      attachmentMaterializer: (attachment) async {
        materializeCalls++;
        if (materializeCalls == 2) await secondCopyGate.future;
        return attachment.copyWith(localPath: '/private/${attachment.localId}');
      },
      attachmentPrivateCopyDeleter: (attachment) async {
        deleted.add(attachment.localId);
        return true;
      },
    );
    await tester.tap(find.byKey(const ValueKey('composer-add')));
    await tester.pump();
    tester
        .widget<MenuItemButton>(find.byType(MenuItemButton).last)
        .onPressed!();
    for (var frame = 0; frame < 40 && materializeCalls < 2; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(materializeCalls, 2);

    Navigator.of(tester.element(find.byType(ChatScreen))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    secondCopyGate.complete();
    for (var frame = 0; frame < 40 && deleted.length < 2; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(deleted, hasLength(2));
    expect(deleted.toSet(), hasLength(2));
  });

  testWidgets('una imagen restaurada abre preview estable desde su chip', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final temp = Directory.systemTemp.createTempSync('chat-image-preview-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final image = File('${temp.path}/preview.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
          'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
    final attachment = AttachmentDraft(
      localId: 'preview-1',
      type: AttachmentType.image,
      name: 'preview.png',
      mimeType: 'image/png',
      sizeBytes: image.lengthSync(),
      localPath: image.path,
    );
    secureStore['chat_draft_v2_conn-test_sess-test'] = jsonEncode({
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'text': '',
      'attachments': [attachment.toJson()],
    });

    await pumpChat(tester);
    for (
      var frame = 0;
      frame < 20 &&
          find
              .byKey(const ValueKey('attachment-card-preview-1'))
              .evaluate()
              .isEmpty;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    final card = find.byKey(const ValueKey('attachment-card-preview-1'));
    expect(card, findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Previsualizar preview.png')),
      matchesSemantics(
        label: 'Previsualizar preview.png',
        isButton: true,
        hasTapAction: true,
      ),
    );
    await tester.tap(card);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byTooltip('Guardar en galería'), findsOneWidget);
    expect(find.byTooltip('Compartir'), findsOneWidget);
    expect(find.byTooltip('Cerrar'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('una imagen con error conserva disponible su preview', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync(
      'chat-image-error-preview-',
    );
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final image = File('${temp.path}/error.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
          'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
    final attachment = AttachmentDraft(
      localId: 'error-preview',
      type: AttachmentType.image,
      name: 'error.png',
      mimeType: 'image/png',
      sizeBytes: image.lengthSync(),
      localPath: image.path,
      uploadState: AttachmentUploadState.error,
      errorKind: AttachmentErrorKind.transport,
    );
    secureStore['chat_draft_v2_conn-test_sess-test'] = jsonEncode({
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'text': '',
      'attachments': [attachment.toJson()],
    });

    await pumpChat(tester);
    final card = find.byKey(const ValueKey('attachment-card-error-preview'));
    for (var frame = 0; frame < 20 && card.evaluate().isEmpty; frame++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(card, findsOneWidget);
    expect(tester.widget<AttachmentCard>(card).onTap, isNotNull);
    await tester.tap(card);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('una imagen subiendo bloquea preview hasta terminar', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final temp = Directory.systemTemp.createTempSync(
      'chat-image-uploading-preview-',
    );
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final image = File('${temp.path}/subiendo.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
          'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
    final attachment = AttachmentDraft(
      localId: 'uploading-preview',
      type: AttachmentType.image,
      name: 'subiendo.png',
      mimeType: 'image/png',
      sizeBytes: image.lengthSync(),
      localPath: image.path,
      uploadState: AttachmentUploadState.uploading,
      attempt: 1,
    );
    secureStore['chat_draft_v2_conn-test_sess-test'] = jsonEncode({
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'text': '',
      'attachments': [attachment.toJson()],
    });

    await pumpChat(tester);
    final card = find.byKey(
      const ValueKey('attachment-card-uploading-preview'),
    );
    for (var frame = 0; frame < 20 && card.evaluate().isEmpty; frame++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(card, findsOneWidget);
    expect(tester.widget<AttachmentCard>(card).onTap, isNull);
    expect(
      tester.getSemantics(
        find.bySemanticsLabel('Subiendo subiendo.png. Espera a que termine.'),
      ),
      matchesSemantics(
        label: 'Subiendo subiendo.png. Espera a que termine.',
        isLiveRegion: true,
      ),
    );
    await tester.tap(card);
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byType(InteractiveViewer), findsNothing);
    semantics.dispose();
  });

  testWidgets('una imagen adjuntada no abre un visor sobre copia liberable', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('chat-image-attached-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final image = File('${temp.path}/attached.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
          'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
    final attachment = AttachmentDraft(
      localId: 'attached-preview',
      type: AttachmentType.image,
      name: 'attached.png',
      mimeType: 'image/png',
      sizeBytes: image.lengthSync(),
      localPath: image.path,
      uploadState: AttachmentUploadState.attached,
      remoteRef: '/remote/attached.png',
      remoteSessionId: 'runtime-ui-test',
      remoteTransport: AttachmentRemoteTransport.desktop,
    );
    secureStore['chat_draft_v2_conn-test_sess-test'] = jsonEncode({
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'text': '',
      'attachments': [attachment.toJson()],
    });

    await pumpChat(tester);
    for (
      var frame = 0;
      frame < 20 &&
          find
              .byKey(const ValueKey('attachment-card-attached-preview'))
              .evaluate()
              .isEmpty;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    final card = find.byKey(const ValueKey('attachment-card-attached-preview'));
    expect(card, findsOneWidget);
    expect(tester.widget<AttachmentCard>(card).onTap, isNull);
    await tester.tap(card);
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('un restore tardío no resucita un adjunto retirado', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('chat-restore-fence-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final file = File('${temp.path}/informe.pdf')
      ..writeAsBytesSync([0x25, 0x50, 0x44, 0x46, 1]);
    final attachment = AttachmentDraft(
      localId: 'restore-race',
      type: AttachmentType.document,
      name: 'informe.pdf',
      mimeType: 'application/pdf',
      sizeBytes: file.lengthSync(),
      localPath: file.path,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    final turn = PreparedTurn(
      connectionId: 'conn-test',
      sessionId: 'sess-test',
      clientTurnId: 'restore-race-turn',
      createdAtMs: now,
      updatedAtMs: now,
      text: '',
      attachments: [attachment],
      model: 'hermes-agent',
      profile: '',
    );
    secureStore['chat_draft_v2_conn-test_sess-test'] = jsonEncode({
      'savedAt': now,
      'text': '',
      'attachments': [attachment.toJson()],
    });
    secureStore['chat_turn_outbox_v1'] = jsonEncode({
      turn.storageId: turn.toJson(),
    });
    final outboxGate = Completer<String?>();
    delayedOutboxRead = outboxGate;

    await pumpChat(tester);
    final card = find.byKey(const ValueKey('attachment-card-restore-race'));
    expect(card, findsOneWidget);
    await tester.tap(
      find.descendant(of: card, matching: find.byIcon(Icons.close)),
    );
    await tester.pump();
    expect(card, findsNothing);

    delayedOutboxRead = null;
    outboxGate.complete(secureStore['chat_turn_outbox_v1']);
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(card, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'recuperación no drena queued antes de reconciliar turno ambiguo',
    (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final ambiguous = PreparedTurn(
        connectionId: 'conn-test',
        sessionId: 'sess-test',
        clientTurnId: 'startup-ambiguous-turn',
        createdAtMs: now,
        updatedAtMs: now,
        text: 'turno anterior incierto',
        attachments: const [],
        model: 'hermes-agent',
        profile: '',
        state: PreparedTurnState.ambiguous,
        restoresComposer: false,
      );
      final queued = PreparedTurn(
        connectionId: 'conn-test',
        sessionId: 'sess-test',
        clientTurnId: 'startup-queued-turn',
        createdAtMs: now + 1,
        updatedAtMs: now + 1,
        text: 'turno queued posterior',
        fullText: 'turno queued posterior',
        attachments: const [],
        model: 'hermes-agent',
        profile: '',
        queued: true,
        restoresComposer: false,
      );
      secureStore['chat_turn_outbox_v1'] = jsonEncode({
        ambiguous.storageId: ambiguous.toJson(),
        queued.storageId: queued.toJson(),
      });
      final statusGate = Completer<DesktopTurnStatus>();
      final gateway = _RecoverableSubmissionGateway()..statusGate = statusGate;

      await pumpChat(
        tester,
        connection: _remoteConn('conn-test'),
        desktopGateway: gateway,
        initialStoredSessionId: 'sess-test',
        turnIdempotencyCapability: () async => true,
      );
      for (var frame = 0; frame < 40; frame++) {
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(gateway.statusCalls, 1);
      expect(gateway.submissions, isEmpty);

      statusGate.complete(
        const DesktopTurnStatus(
          known: true,
          clientTurnId: 'startup-ambiguous-turn',
          serverTurnId: 'server-startup-ambiguous-turn',
          state: DesktopTurnState.terminal,
        ),
      );
      for (var frame = 0; frame < 120 && gateway.submissions.isEmpty; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(gateway.submissions, ['turno queued posterior']);
      gateway.emitComplete('respuesta queued');
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('un submit espera la outbox inicial antes de tomar ownership', (
    tester,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final recovered = PreparedTurn(
      connectionId: 'conn-test',
      sessionId: 'sess-test',
      clientTurnId: 'startup-recovered-turn',
      createdAtMs: now,
      updatedAtMs: now,
      text: 'turno dirigido pendiente',
      attachments: const [],
      model: 'hermes-agent',
      profile: '',
      state: PreparedTurnState.failedBeforeAcceptance,
      restoresComposer: false,
    );
    secureStore['chat_turn_outbox_v1'] = jsonEncode({
      recovered.storageId: recovered.toJson(),
    });
    final outboxGate = Completer<String?>();
    delayedOutboxRead = outboxGate;
    final gateway = _SubmissionGateway();

    await pumpChat(
      tester,
      connection: _remoteConn('conn-test'),
      desktopGateway: gateway,
    );
    await tester.enterText(find.byType(TextField).last, 'turno nuevo');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(gateway.submissions, isEmpty);

    delayedOutboxRead = null;
    outboxGate.complete(secureStore['chat_turn_outbox_v1']);
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(gateway.submissions, isEmpty);
    final stored = jsonDecode(secureStore['chat_turn_outbox_v1']!) as Map;
    expect(stored, hasLength(1));
    expect(
      (stored.values.single as Map)['client_turn_id'],
      'startup-recovered-turn',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'un fallo de lectura outbox bloquea transporte y conserva draft',
    (tester) async {
      final outboxGate = Completer<String?>();
      delayedOutboxRead = outboxGate;
      final gateway = _SubmissionGateway();
      await pumpChat(
        tester,
        connection: _remoteConn('conn-test'),
        desktopGateway: gateway,
      );
      final field = find.byType(TextField).last;
      await tester.enterText(field, 'draft retenido');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();

      delayedOutboxRead = null;
      outboxGate.completeError(PlatformException(code: 'keystore_unavailable'));
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(gateway.submissions, isEmpty);
      expect(
        tester.widget<TextField>(field).controller?.text,
        'draft retenido',
      );
      expect(find.byType(SnackBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('un fallo outbox impide iniciar transporte de Voz', (
    tester,
  ) async {
    final outboxGate = Completer<String?>();
    delayedOutboxRead = outboxGate;
    final stt = _PartialSttEngine();
    await pumpChat(
      tester,
      stt: stt,
      initialVoiceMode: true,
      initialPreferences: const {
        'voice_conversation_disclosure_accepted_v1': true,
        'voice_conversation_enabled': true,
      },
    );

    delayedOutboxRead = null;
    outboxGate.completeError(PlatformException(code: 'keystore_unavailable'));
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(stt.availableCalls, 0);
    expect(
      find.byKey(const ValueKey('voice-conversation-surface')),
      findsNothing,
    );
    expect(find.byType(SnackBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el foco ensancha el composer del chat sin perder el borrador', (
    tester,
  ) async {
    await pumpChat(tester);

    final field = find.byType(TextField);
    final surface = find.byKey(
      const ValueKey('hermes-composer-visible-surface'),
    );
    final textField = tester.widget<TextField>(field);
    final composer = find.byType(HermesComposerSurface);
    expect(
      find.ancestor(of: composer, matching: find.byType(SafeArea)),
      findsOneWidget,
    );
    final controller = textField.controller;
    expect(controller, isA<TextEditingController>());
    final resting = tester.getRect(surface);

    await tester.enterText(field, 'borrador conservado');
    await tester.pump(const Duration(milliseconds: 200));

    final focused = tester.getRect(surface);
    expect(focused.width, greaterThan(resting.width));
    expect(focused.left, lessThan(resting.left));
    expect(
      tester.widget<TextField>(field).controller?.text,
      'borrador conservado',
    );
    expect(tester.widget<TextField>(field).controller, same(controller));
    expect(tester.widget<TextField>(field).focusNode?.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Reduce Motion elimina la animación nueva del composer del chat',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      await pumpChat(tester);

      final surface = find.byKey(
        const ValueKey('hermes-composer-visible-surface'),
      );
      final animatedPadding = find
          .ancestor(of: surface, matching: find.byType(AnimatedPadding))
          .first;
      expect(
        tester.widget<AnimatedPadding>(animatedPadding).duration,
        Duration.zero,
      );
      expect(tester.widget<AnimatedContainer>(surface).duration, Duration.zero);

      final cursor = find.byKey(const ValueKey('empty-chat-cursor'));
      expect(cursor, findsOneWidget);
      expect(tester.widget<Opacity>(cursor).opacity, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(tester.widget<Opacity>(cursor).opacity, 1);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cursor del chat vacío usa un reloj discreto y se pausa fuera de escena',
    (tester) async {
      await pumpChat(tester);

      final clock = find.byKey(const ValueKey('empty-chat-blink-clock'));
      final cursor = find.byKey(const ValueKey('empty-chat-cursor'));
      final dynamic state = tester.state(clock);
      expect(state.debugClockActive, isTrue);

      final initialBlinks = state.debugBlinkCount as int;
      final initialOpacity = tester.widget<Opacity>(cursor).opacity;
      await tester.pump(const Duration(milliseconds: 100));
      expect(state.debugBlinkCount, initialBlinks);
      expect(tester.widget<Opacity>(cursor).opacity, initialOpacity);

      await tester.pump(const Duration(milliseconds: 450));
      expect(state.debugBlinkCount, initialBlinks + 1);
      expect(tester.widget<Opacity>(cursor).opacity, isNot(initialOpacity));

      final navigator = Navigator.of(tester.element(find.byType(ChatScreen)));
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: SizedBox.expand()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.debugClockActive, isFalse);
      final pausedBlinks = state.debugBlinkCount as int;

      await tester.pump(const Duration(seconds: 1));
      expect(state.debugBlinkCount, pausedBlinks);

      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.debugClockActive, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(state.debugClockActive, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(state.debugClockActive, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('el acceso Nueva conversación enfoca el composer una sola vez', (
    tester,
  ) async {
    await pumpChat(tester, requestComposerFocus: true);
    await tester.pump();

    final editable = tester.widget<EditableText>(
      find.byType(EditableText).last,
    );
    expect(editable.focusNode.hasFocus, isTrue);

    editable.focusNode.unfocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(editable.focusNode.hasFocus, isFalse);
  });

  testWidgets('la proyección terminal se reutiliza en rebuilds del chat', (
    tester,
  ) async {
    final performance = ChatPerformanceProbe();
    await pumpChat(
      tester,
      performanceProbe: performance,
      messages: const [
        {
          'role': 'assistant',
          'content':
              '## Respuesta estable\n\nTexto **fijo**.\n\n'
              '| Clave | Valor |\n| --- | --- |\n| uno | dos |',
        },
        {'role': 'user', 'content': 'Pregunta anterior'},
      ],
    );

    final computations = performance.terminalProjectionComputations;
    final terminalBuilds = performance.terminalAssistantBuilds;
    expect(computations, greaterThan(0));

    await tester.tap(find.byType(TextField));
    await tester.pump();

    expect(performance.terminalAssistantBuilds, greaterThan(terminalBuilds));
    expect(
      performance.terminalProjectionComputations,
      computations,
      reason: 'focus/rebuild no vuelve a normalizar ni partir el Markdown',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('una preferencia antigua no oculta el acceso a conversación', (
    tester,
  ) async {
    await pumpChat(tester, legacyConversationEnabled: false);

    expect(
      find.byKey(ValueKey(kVoiceModeEnabled ? 'voice' : 'send')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('el prompt enviado desde Inicio no reaparece en el composer', (
    tester,
  ) async {
    final submitGate = Completer<void>();
    final gateway = _UiRewindGateway()..submitGate = submitGate;
    await pumpChat(
      tester,
      desktopGateway: gateway,
      connection: _remoteConn('conn-home-prompt'),
      messagesLoaded: false,
      initialPrompt: 'Resume el estado del proyecto',
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(gateway.submissions, ['Resume el estado del proyecto']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );

    submitGate.complete();
    gateway.emit('message.complete', {'text': 'hecho'});
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'session.info actualiza el trigger aislado y abre el desglose Desktop',
    (tester) async {
      final gateway = _UiRewindGateway();
      final probe = ChatPerformanceProbe();
      final chat = await pumpChat(
        tester,
        desktopGateway: gateway,
        connection: _remoteConn('conn-usage'),
        messagesLoaded: false,
        performanceProbe: probe,
      );
      await tester.pump(const Duration(milliseconds: 100));
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(chat.hasDesktopRuntime, isTrue);
      expect(
        find.byKey(const ValueKey('desktop-context-usage-status')),
        findsOneWidget,
      );
      expect(gateway.contextBreakdownCalls, 1);
      final contextTrigger = tester.widget<SessionContextTrigger>(
        find.byType(SessionContextTrigger),
      );
      expect(contextTrigger.metrics.value.percent, 25);
      expect(find.text('25%'), findsOneWidget);
      final screenBuildsBeforeUsage = probe.screenBuilds;

      gateway.emit('session.info', const {
        'info': {
          'usage': {'context_used': 250, 'context_max': 1000},
        },
      });
      await tester.pump();

      expect(chat.desktopRuntimeInfo.usage?.contextUsed, 250);
      expect(chat.desktopRuntimeInfo.usage?.contextMax, 1000);
      expect(find.text('25%'), findsOneWidget);
      expect(probe.screenBuilds, screenBuildsBeforeUsage);

      final semantics = tester.getSemantics(
        find.byKey(const ValueKey('desktop-context-usage-status')),
      );
      expect(
        semantics.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
      );

      await tester.tap(
        find.byKey(const ValueKey('desktop-context-usage-status')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('desktop-context-usage-popover')),
        findsOneWidget,
      );
      expect(find.text('Uso de contexto'), findsOneWidget);
      expect(find.text('Prompt del sistema'), findsOneWidget);
      expect(find.text('Conversación'), findsOneWidget);
      expect(gateway.contextBreakdownCalls, 2);
      expect(find.byKey(const ValueKey('context-compress-now')), findsNothing);

      final popoverRect = tester.getRect(
        find.byKey(const ValueKey('desktop-context-usage-popover')),
      );
      final logicalWidth =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final outsidePoint = popoverRect.left > 16
          ? Offset(8, popoverRect.center.dy)
          : Offset(logicalWidth - 8, popoverRect.center.dy);
      await tester.tapAt(outsidePoint);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('desktop-context-usage-popover')),
        findsNothing,
      );

      gateway.emit('session.info', const {
        'info': {
          'usage': {'context_used': 750, 'context_max': 1000},
        },
      });
      await tester.pump();

      expect(chat.desktopRuntimeInfo.usage?.contextUsed, 750);
      expect(find.text('75%'), findsOneWidget);

      // Hermes omite el gauge mientras espera la primera medición real tras
      // compactar. El móvil no conserva el 75 % antiguo ni usa `total` como
      // sustituto de la ocupación de ventana.
      gateway.emit('status.update', const {'kind': 'compacting'});
      await tester.pump();
      gateway.emit('session.info', const {
        'info': {
          'running': false,
          'usage': {'total': 99000},
        },
      });
      await tester.pump();
      expect(find.text('75%'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('desktop-context-usage-status')),
          matching: find.text('99k tok'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'la precarga reutiliza session.info y evita pedir otro desglose',
    (tester) async {
      final gateway = _UiRewindGateway(
        resumeUsage: const DesktopUsageStats(
          contextUsed: 400,
          contextMax: 1000,
          contextPercent: 40,
        ),
      );

      await pumpChat(
        tester,
        desktopGateway: gateway,
        connection: _remoteConn('conn-usage-snapshot'),
        messagesLoaded: false,
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('40%'), findsOneWidget);
      expect(gateway.contextBreakdownCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'la precarga reintenta una vez si Hermes aún no publica la ventana',
    (tester) async {
      final gateway = _UiRewindGateway(contextUnavailableOnce: true);

      await pumpChat(
        tester,
        desktopGateway: gateway,
        connection: _remoteConn('conn-usage-late-window'),
      );
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(gateway.contextBreakdownCalls, 2);
      expect(find.text('25%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'un snapshot inicialmente vacío se reintenta en el siguiente session.info',
    (tester) async {
      final gateway = _UiRewindGateway(contextUnavailableResponses: 2);

      await pumpChat(
        tester,
        desktopGateway: gateway,
        connection: _remoteConn('conn-usage-event-retry'),
      );
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(gateway.contextBreakdownCalls, 2);
      expect(find.text('25%'), findsNothing);

      gateway.emit('session.info', const {
        'info': {'model': 'model-after-start'},
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(gateway.contextBreakdownCalls, 3);
      expect(find.text('25%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'un chat móvil nuevo carga contexto al obtener runtime en el primer envío',
    (tester) async {
      final gateway = _UiRewindGateway();
      const draft = Session(
        id: 'mob-context-draft',
        title: 'Nuevo chat',
        model: 'hermes-agent',
        source: 'mobile',
        messageCount: 0,
        isActive: true,
        preview: '',
        startedAt: 0,
      );
      final chat = await pumpChat(
        tester,
        desktopGateway: gateway,
        connection: _remoteConn('conn-context-draft'),
        session: draft,
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(chat.hasDesktopRuntime, isFalse);
      expect(gateway.contextBreakdownCalls, 0);

      await tester.enterText(find.byType(TextField), 'Primer mensaje');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(chat.hasDesktopRuntime, isTrue);
      expect(gateway.contextBreakdownCalls, 1);
      expect(find.text('25%'), findsOneWidget);
      expect(tester.takeException(), isNull);

      gateway.emit('message.complete', const {'text': 'hecho'});
      await tester.pump(const Duration(milliseconds: 400));
    },
  );

  testWidgets(
    'lineage revelado retira preferencias ocultas de esta conversación',
    (tester) async {
      final gateway = _UiRewindGateway();
      final chat = await pumpChat(
        tester,
        desktopGateway: gateway,
        connection: _remoteConn('conn-lineage-prefs'),
        messagesLoaded: false,
      );
      await tester.pump(const Duration(milliseconds: 100));

      final prefs = await SharedPreferences.getInstance();
      final store = ChatPreferenceStore(prefs);
      const legacy = ChatPreferences(
        density: TranscriptDensity.compact,
        notifications: ChatPreferenceToggle.off,
      );
      await store.save(
        connectionId: 'conn-lineage-prefs',
        logicalSessionId: 'sess-test',
        value: legacy,
      );

      gateway.emit('status.update', const {
        'kind': 'compacting',
        'lineage_root_id': 'lineage-root-qa',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(chat.desktopCompactionLineageId, 'lineage-root-qa');
      expect(
        find.byKey(const ValueKey('desktop-session-compression-progress')),
        findsNothing,
      );
      expect(find.text('Optimizando la conversación…'), findsNothing);
      // El 2 % del snapshot es ocupación de contexto, no progreso de la
      // operación. Durante la compresión no debe presentarse como tal.
      expect(find.text('2%'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      expect(
        await store.load(
          connectionId: 'conn-lineage-prefs',
          logicalSessionId: 'lineage-root-qa',
        ),
        const ChatPreferences(),
      );
      expect(
        await store.load(
          connectionId: 'conn-lineage-prefs',
          logicalSessionId: 'sess-test',
        ),
        const ChatPreferences(),
      );
    },
  );

  testWidgets(
    'borrar desde ChatControl exige App Lock y cancelar conserva chat',
    (tester) async {
      await pumpChat(tester);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('app_lock_enabled', true);

      await tester.tap(find.byKey(const ValueKey('chat-control-trigger')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('chat-control-delete')),
        260,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('chat-control-sheet')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byKey(const ValueKey('chat-control-delete')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      final dialogActions = find.descendant(
        of: dialog,
        matching: find.byType(TextButton),
      );
      await tester.tap(dialogActions.last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byType(LockScreen), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byType(LockScreen), findsNothing);
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('/compact queda local, explica /compress y no toca el agente', (
    tester,
  ) async {
    final gateway = _UiRewindGateway();
    await pumpChat(
      tester,
      desktopGateway: gateway,
      connection: _remoteConn('conn-compact-unavailable'),
      messagesLoaded: false,
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(
      find.byType(TextField),
      '/compact decisiones de release',
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();

    expect(gateway.slashCalls, isEmpty);
    expect(gateway.dispatchCalls, isEmpty);
    expect(gateway.submissions, isEmpty);
    expect(
      find.textContaining('/compact no es un comando de Hermes Desktop'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('desktop-session-compression-progress')),
      findsNothing,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '/compress usa slash.exec y reconcilia el snapshot autoritativo',
    (tester) async {
      final compressionGate = Completer<DesktopCommandRpcResult>();
      final gateway = _UiRewindGateway()..compressionGate = compressionGate;
      final chat = await pumpChat(
        tester,
        desktopGateway: gateway,
        connection: _remoteConn('conn-compress-ui'),
        messagesLoaded: false,
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(chat.hasDesktopRuntime, isTrue);

      await tester.enterText(
        find.byType(TextField),
        '/compress decisiones de release',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();

      expect(gateway.slashCalls, hasLength(1));
      expect(gateway.slashCalls.single.runtimeId, 'runtime-ui-test');
      expect(
        gateway.slashCalls.single.command,
        'compress decisiones de release',
      );
      expect(gateway.dispatchCalls, isEmpty);
      expect(gateway.submissions, isEmpty);
      expect(
        find.byKey(const ValueKey('desktop-session-compression-progress')),
        findsOneWidget,
      );
      expect(find.text('Optimizando la conversación…'), findsOneWidget);
      expect(find.text('2%'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);

      compressionGate.complete(_acceptedCommandResult);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(
        find.byKey(const ValueKey('desktop-session-compression-progress')),
        findsNothing,
      );
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      expect(chat.storedSessionId, 'stored-ui-compressed');
      expect(find.textContaining('Contexto listo'), findsOneWidget);
      expect(
        find.textContaining('Hermes aceptó la compresión'),
        findsOneWidget,
      );
      expect(gateway.submissions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('/compress no reemplaza el chat por un snapshot parcial', (
    tester,
  ) async {
    final gateway = _UiRewindGateway()
      ..compressedSnapshot = DesktopSessionSnapshot(
        runtimeSessionId: 'runtime-ui-test',
        storedSessionId: 'stored-ui-compressed',
        created: false,
        messagesProvided: true,
        messages: [
          DesktopSessionMessage.tryParse(const {
            'message_id': 'partial-compression-row',
            'role': 'assistant',
            'content': 'fila parcial',
          })!,
        ],
        messageCount: 20,
      );
    final chat = await pumpChat(
      tester,
      desktopGateway: gateway,
      connection: _remoteConn('conn-compress-partial'),
      messagesLoaded: false,
    );
    chat.messages.addAll(const [
      {
        'id': 'visible-answer',
        'role': 'assistant',
        'content': 'respuesta visible preservada',
      },
      {
        'id': 'visible-user',
        'role': 'user',
        'content': 'pregunta visible preservada',
      },
    ]);
    await tester.pump();

    await tester.enterText(find.byType(TextField), '/compress parcial');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(
      chat.messages.any((message) => message['id'] == 'visible-answer'),
      isTrue,
    );
    expect(
      chat.messages.any(
        (message) => message['_desktopMessageId'] == 'partial-compression-row',
      ),
      isFalse,
    );
    expect(gateway.submissions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('/compress usa command.dispatch solo si slash.exec falla', (
    tester,
  ) async {
    final gateway = _UiRewindGateway()
      ..slashError = const TuiGatewayRpcError(
        'slash.exec',
        'unsupported in fixture',
        code: -32601,
      );
    final chat = await pumpChat(
      tester,
      desktopGateway: gateway,
      connection: _remoteConn('conn-compress-fallback'),
      messagesLoaded: false,
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField), '/compress prioridades');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump(const Duration(milliseconds: 350));

    expect(gateway.slashCalls, hasLength(1));
    expect(gateway.dispatchCalls, hasLength(1));
    expect(gateway.dispatchCalls.single.runtimeId, 'runtime-ui-test');
    expect(gateway.dispatchCalls.single.name, 'compress');
    expect(gateway.dispatchCalls.single.arg, 'prioridades');
    expect(gateway.submissions, isEmpty);
    expect(chat.storedSessionId, 'stored-ui-compressed');
    expect(tester.takeException(), isNull);
  });

  testWidgets('el doble fallo de compresión conserva el diagnóstico seguro', (
    tester,
  ) async {
    final gateway = _UiRewindGateway()
      ..slashError = const TuiGatewayRpcError(
        'slash.exec',
        'unsupported in fixture',
        code: -32601,
      )
      ..dispatchError = const TuiGatewayRpcError(
        'command.dispatch',
        'synthetic backend failure',
        code: 5005,
      );
    await pumpChat(
      tester,
      desktopGateway: gateway,
      connection: _remoteConn('conn-compress-double-failure'),
      messagesLoaded: false,
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField), '/compress prioridades');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump(const Duration(milliseconds: 350));

    expect(gateway.slashCalls, hasLength(1));
    expect(gateway.dispatchCalls, hasLength(1));
    expect(gateway.submissions, isEmpty);
    expect(
      find.textContaining('Hermes no pudo generar el resumen'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('un slash desconocido nunca llega a prompt.submit', (
    tester,
  ) async {
    final gateway = _UiRewindGateway();
    await pumpChat(
      tester,
      desktopGateway: gateway,
      connection: _remoteConn('conn-unknown-command'),
      messagesLoaded: false,
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField), '/inventado hola');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();

    expect(gateway.slashCalls, isEmpty);
    expect(gateway.dispatchCalls, isEmpty);
    expect(gateway.submissions, isEmpty);
    expect(
      find.text('El comando /inventado no está disponible en este servidor.'),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '/inventado hola',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('un chat móvil nuevo acepta el 404 inicial como vacío', (
    tester,
  ) async {
    final chat = await pumpChat(tester, messagesLoaded: false);
    await tester.pump(const Duration(milliseconds: 500));

    expect(chat.messagesLoaded, isTrue);
    expect(find.text('No se pudieron cargar los mensajes'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('al escribir aparece el botón de envío', (tester) async {
    await pumpChat(tester);

    await tester.enterText(find.byType(TextField), 'hola');
    await tester.pump();
    // Deja terminar la transición del AnimatedSwitcher (mientras dura, el botón
    // de voz saliente sigue en el árbol).
    await tester.pump(const Duration(milliseconds: 250));

    // Con texto en el composer, el botón cambia a "enviar".
    expect(find.byKey(const ValueKey('send')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el composer no desborda con teclado en horizontal', (
    tester,
  ) async {
    await pumpChat(tester, connection: _remoteConn());
    tester.view.physicalSize = const Size(2142, 960);
    tester.view.devicePixelRatio = 2;
    tester.view.viewInsets = const FakeViewPadding(bottom: 545);
    addTearDown(tester.view.reset);

    await tester.enterText(
      find.byType(TextField),
      'Un borrador largo que debe seguir visible al abrir el teclado',
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byKey(const ValueKey('send')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el borrador reaparece al salir y volver al mismo chat', (
    tester,
  ) async {
    final connection = _remoteConn();
    await pumpChat(tester, connection: connection);

    await tester.enterText(
      find.byType(TextField),
      'mensaje todavía sin enviar',
    );
    await tester.pump(const Duration(milliseconds: 400));
    Navigator.of(tester.element(find.byType(ChatScreen))).pop();
    await tester.pump(const Duration(milliseconds: 400));

    final ctx = tester.element(find.byType(Navigator).first);
    Navigator.of(ctx).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(connection: connection, session: _session()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'mensaje todavía sin enviar',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('el borrador se guarda al mandar la app al fondo', (
    tester,
  ) async {
    final connection = _remoteConn();
    await pumpChat(tester, connection: connection);

    await tester.enterText(find.byType(TextField), 'borrador antes de pausar');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 100));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    Navigator.of(tester.element(find.byType(ChatScreen))).pop();
    await tester.pump(const Duration(milliseconds: 100));
    final ctx = tester.element(find.byType(Navigator).first);
    Navigator.of(ctx).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(connection: connection, session: _session()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'borrador antes de pausar',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('el lifecycle nunca desconecta el canal Desktop', (tester) async {
    final gateway = _UiRewindGateway();
    await pumpChat(
      tester,
      desktopGateway: gateway,
      connection: _remoteConn('conn-background-grace'),
      messagesLoaded: false,
    );
    await tester.pump(const Duration(milliseconds: 100));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 19));
    expect(gateway.idleDisconnects, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 2));
    expect(gateway.idleDisconnects, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 21));
    expect(gateway.idleDisconnects, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await tester.pump();
    expect(gateway.idleDisconnects, 0);
  });

  testWidgets('process death durante submitting restaura sin autoenvío', (
    tester,
  ) async {
    final connection = _remoteConn('conn-process-death');
    final now = DateTime.now().millisecondsSinceEpoch;
    final pending = PreparedTurn(
      connectionId: connection.id,
      sessionId: 'sess-test',
      clientTurnId: 'turno-en-vuelo',
      createdAtMs: now,
      updatedAtMs: now,
      text: 'mensaje cuya entrega no está confirmada',
      attachments: const [],
      model: 'hermes-agent',
      profile: '',
      state: PreparedTurnState.submitting,
    );
    secureStore['chat_turn_outbox_v1'] = jsonEncode({
      pending.storageId: pending.toJson(),
    });
    final gateway = _SubmissionGateway();

    await pumpChat(tester, connection: connection, desktopGateway: gateway);
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'mensaje cuya entrega no está confirmada',
    );
    expect(gateway.submissions, isEmpty);
    final stored =
        jsonDecode(secureStore['chat_turn_outbox_v1']!) as Map<String, dynamic>;
    expect(
      (stored.values.single as Map<String, dynamic>)['state'],
      PreparedTurnState.ambiguous.name,
    );
    expect(
      find.textContaining('No se pudo confirmar si este turno llegó'),
      findsOneWidget,
    );
    tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
    expect(secureStore.containsKey('chat_turn_outbox_v1'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'un error owner guardado por una build anterior nunca revela el RPC',
    (tester) async {
      const prompt = 'continúa esta conversación desde el móvil';
      const raw =
          'TuiGatewayRpcError(prompt.submit, 4090): Session private-id '
          'already has a live owner (desktop, pid 1234)';

      await pumpChat(
        tester,
        messages: const [
          {'role': 'assistant_error', 'content': raw, '_prompt': prompt},
          {'role': 'user', 'content': prompt},
        ],
      );

      expect(
        find.text(
          'Hermes could not reserve this conversation. '
          'Check other active sessions and try again.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('TuiGatewayRpcError'), findsNothing);
      expect(find.textContaining('private-id'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rechazo por owner muestra copia segura y reintenta sin duplicar el turno',
    (tester) async {
      const prompt = 'continúa esta conversación desde el móvil';
      const safeMessage =
          'This conversation is open in another window or device. '
          'Close it there and try again.';
      final connection = _remoteConn('conn-owned-elsewhere');
      final gateway = _SubmissionGateway()
        ..submitError = const _ReasonedPromptRejection(
          reason: 'SESSION_NOT_OWNED',
        );
      final chat = await pumpChat(
        tester,
        connection: connection,
        desktopGateway: gateway,
      );

      final field = find.byType(TextField).last;
      await tester.enterText(field, prompt);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send')));
      for (
        var frame = 0;
        frame < 40 && chat.state != ChatPipelineState.failed;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(chat.state, ChatPipelineState.failed);
      expect(find.text(safeMessage), findsOneWidget);
      expect(find.textContaining('TuiGatewayRpcError'), findsNothing);
      expect(find.textContaining('private-id'), findsNothing);
      expect(
        chat.messages.where((message) => message['role'] == 'user'),
        hasLength(1),
      );
      var stored =
          jsonDecode(secureStore['chat_turn_outbox_v1']!)
              as Map<String, dynamic>;
      expect(
        (stored.values.single as Map<String, dynamic>)['state'],
        PreparedTurnState.failedBeforeAcceptance.name,
      );

      // El rechazo conserva el lote en el composer. Pulsar la flecha verde es
      // también un retry explícito y no debe apilar otra copia local del mismo
      // user/error antes de volver a intentar el RPC.
      expect(tester.widget<TextField>(field).controller?.text, prompt);
      await tester.tap(find.byKey(const ValueKey('send')));
      for (
        var frame = 0;
        frame < 40 && gateway.submissions.length < 2;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump();

      expect(gateway.submissions, [prompt, prompt]);
      expect(
        chat.messages.where((message) => message['role'] == 'user'),
        hasLength(1),
      );
      expect(
        chat.messages.where((message) => message['role'] == 'assistant_error'),
        hasLength(1),
      );
      expect(find.text(safeMessage), findsOneWidget);
      expect(find.textContaining('TuiGatewayRpcError'), findsNothing);
      stored =
          jsonDecode(secureStore['chat_turn_outbox_v1']!)
              as Map<String, dynamic>;
      expect(
        (stored.values.single as Map<String, dynamic>)['state'],
        PreparedTurnState.failedBeforeAcceptance.name,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'submit vivo limpia el input y no permite doble envío o steering',
    (tester) async {
      final connection = _remoteConn('conn-live-submit');
      final gateway = _SubmissionGateway()..submitGate = Completer<void>();
      await pumpChat(tester, connection: connection, desktopGateway: gateway);

      await tester.enterText(find.byType(TextField), 'turno vivo al navegar');
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'turno vivo al navegar',
      );
      await tester.tap(find.byKey(const ValueKey('send')));
      // Segundo gesto en el mismo frame: la valla local debe estar levantada
      // antes del primer await, aunque el botón aún no se haya reconstruido.
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(gateway.submissions, ['turno vivo al navegar']);
      expect(gateway.steers, isEmpty);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );

      Navigator.of(tester.element(find.byType(ChatScreen))).pop();
      await tester.pump(const Duration(milliseconds: 400));
      final ctx = tester.element(find.byType(Navigator).first);
      Navigator.of(ctx).push(
        MaterialPageRoute(
          builder: (_) =>
              ChatScreen(connection: connection, session: _session()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final stored =
          jsonDecode(secureStore['chat_turn_outbox_v1']!)
              as Map<String, dynamic>;
      expect(
        (stored.values.single as Map<String, dynamic>)['state'],
        PreparedTurnState.submitting.name,
      );
      expect(gateway.submissions, hasLength(1));
      expect(
        find.textContaining('No se pudo confirmar si este turno llegó'),
        findsNothing,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );

      gateway.submitGate!.complete();
      await tester.pump(const Duration(milliseconds: 500));
      gateway.emitComplete();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rechazo antes del ACK restaura exactamente el composer', (
    tester,
  ) async {
    final connection = _remoteConn('conn-submit-rejected');
    final gateway = _SubmissionGateway()
      ..submitGate = Completer<void>()
      ..submitError = StateError('submit rejected before acceptance');
    await pumpChat(tester, connection: connection, desktopGateway: gateway);

    await tester.enterText(find.byType(TextField), 'texto recuperable');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(gateway.submissions, ['texto recuperable']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );

    gateway.submitGate!.complete();
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'texto recuperable',
    );
    expect(gateway.submissions, hasLength(1));
    expect(gateway.steers, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('un ACK persistido no vuelve a ofrecer un draft antiguo', (
    tester,
  ) async {
    final connection = _remoteConn('conn-accepted-draft');
    final now = DateTime.now().millisecondsSinceEpoch;
    final accepted = PreparedTurn(
      connectionId: connection.id,
      sessionId: 'sess-test',
      clientTurnId: 'turno-aceptado',
      createdAtMs: now,
      updatedAtMs: now,
      text: 'mensaje ya aceptado',
      attachments: const [],
      model: 'hermes-agent',
      profile: '',
      state: PreparedTurnState.accepted,
    );
    secureStore['chat_turn_outbox_v1'] = jsonEncode({
      accepted.storageId: accepted.toJson(),
    });
    secureStore['chat_draft_v2_${connection.id}_sess-test'] = jsonEncode({
      'savedAt': now,
      'text': 'draft viejo que no debe reaparecer',
      'attachments': <Object>[],
    });
    final gateway = _SubmissionGateway();

    await pumpChat(tester, connection: connection, desktopGateway: gateway);
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
    expect(gateway.submissions, isEmpty);
    expect(secureStore.containsKey('chat_turn_outbox_v1'), isTrue);
    expect(
      secureStore.containsKey('chat_draft_v2_${connection.id}_sess-test'),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Room operation survives accepted manager outbox reconciliation',
    (tester) async {
      const connectionId = 'conn-room-accepted-outbox';
      const sessionId = 'stored-room-accepted-outbox';
      final now = DateTime.now().millisecondsSinceEpoch;
      final accepted = PreparedTurn(
        connectionId: connectionId,
        sessionId: sessionId,
        clientTurnId: 'accepted-manager-turn',
        createdAtMs: now,
        updatedAtMs: now,
        text: 'manager turn already accepted',
        attachments: const [],
        model: 'hermes-agent',
        profile: 'manager',
        state: PreparedTurnState.accepted,
      );
      secureStore['chat_turn_outbox_v1'] = jsonEncode({
        accepted.storageId: accepted.toJson(),
      });
      final legacyDraftKey = 'chat_draft_v2_${connectionId}_$sessionId';
      final recoveryDraftKey = ChatDraftStore.keyForTesting(
        connectionId,
        'mob-room-room-accepted-outbox',
        profile: 'manager',
      );
      secureStore[legacyDraftKey] = jsonEncode({
        'savedAt': now,
        'text': '@infra verifica el despliegue',
        'attachments': <Object>[],
        'missionRoomIntentId': 'room-operation-after-manager-ack',
        'missionRoomWorkerProfile': 'infra',
        'missionRoomBoardId': MissionRoomTaskLink.legacyCurrentBoard,
        'missionRoomTaskPhase': MissionRoomTaskPhase.submitting.name,
      });
      final room = MissionRoom(
        id: 'room-accepted-outbox',
        connectionId: connectionId,
        name: 'release',
        managerProfile: 'manager',
        memberProfiles: const ['manager', 'infra'],
        managerSessionId: sessionId,
        createdAtMs: 1,
        updatedAtMs: 1,
      );

      await pumpChat(
        tester,
        connection: _remoteConn(connectionId),
        session: const Session(
          id: sessionId,
          title: '#release',
          model: 'hermes-agent',
          source: 'api',
          messageCount: 1,
          isActive: false,
          preview: '',
          startedAt: 1,
          profile: 'manager',
        ),
        desktopGateway: _SubmissionGateway(),
        missionRoom: room,
        missionRoomStore: _RecordingMissionRoomStore(room),
      );
      await tester.pump(const Duration(milliseconds: 600));

      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        '@infra verifica el despliegue',
      );
      final persisted =
          jsonDecode(secureStore[recoveryDraftKey]!) as Map<String, dynamic>;
      expect(secureStore.containsKey(legacyDraftKey), isFalse);
      expect(
        persisted['missionRoomTaskPhase'],
        MissionRoomTaskPhase.outcomeUnknown.name,
      );
      expect(
        persisted['missionRoomIntentId'],
        'room-operation-after-manager-ack',
      );
      expect(secureStore.containsKey('chat_turn_outbox_v1'), isTrue);
      expect(
        find.textContaining('esto no cancela el turno remoto'),
        findsOneWidget,
      );
      tester
          .widget<SnackBarAction>(find.byType(SnackBarAction).last)
          .onPressed();
      await tester.pump(const Duration(milliseconds: 300));
      expect(secureStore.containsKey('chat_turn_outbox_v1'), isFalse);
      final afterDiscard =
          jsonDecode(secureStore[recoveryDraftKey]!) as Map<String, dynamic>;
      expect(afterDiscard['text'], '@infra verifica el despliegue');
      expect(
        afterDiscard['missionRoomTaskPhase'],
        MissionRoomTaskPhase.outcomeUnknown.name,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Room accepted manager outbox reattaches and terminal unlocks worker dispatch',
    (tester) async {
      const connectionId = 'conn-room-accepted-terminal';
      const sessionId = 'stored-room-accepted-terminal';
      final now = DateTime.now().millisecondsSinceEpoch;
      final accepted = PreparedTurn(
        connectionId: connectionId,
        sessionId: sessionId,
        clientTurnId: 'accepted-manager-terminal',
        createdAtMs: now,
        updatedAtMs: now,
        text: 'manager turn running remotely',
        attachments: const [],
        model: 'hermes-agent',
        profile: 'manager',
        state: PreparedTurnState.accepted,
      );
      secureStore['chat_turn_outbox_v1'] = jsonEncode({
        accepted.storageId: accepted.toJson(),
      });
      secureStore['chat_draft_v2_${connectionId}_$sessionId'] = jsonEncode({
        'savedAt': now,
        'text': '@infra verifica la release',
        'attachments': const <Object>[],
        'missionRoomIntentId': 'room-after-manager-terminal',
        'missionRoomWorkerProfile': 'infra',
        'missionRoomBoardId': MissionRoomTaskLink.legacyCurrentBoard,
        'missionRoomTaskPhase': MissionRoomTaskPhase.prepared.name,
      });
      final room = MissionRoom(
        id: 'room-accepted-terminal',
        connectionId: connectionId,
        name: 'release',
        managerProfile: 'manager',
        memberProfiles: const ['manager', 'infra'],
        managerSessionId: sessionId,
        createdAtMs: 1,
        updatedAtMs: 1,
      );
      final gateway = _RecoverableSubmissionGateway();
      final store = _RecordingMissionRoomStore(room);
      var creatorCalls = 0;

      await pumpChat(
        tester,
        connection: _remoteConn(connectionId),
        session: const Session(
          id: sessionId,
          title: '#release',
          model: 'hermes-agent',
          source: 'gateway',
          messageCount: 1,
          isActive: false,
          preview: '',
          startedAt: 1,
          profile: 'manager',
        ),
        desktopGateway: gateway,
        turnIdempotencyCapability: () async => true,
        missionRoom: room,
        missionRoomStore: store,
        missionRoomTaskCreator: (intent) async {
          creatorCalls++;
          return KanbanTask(
            id: 'task-after-manager-terminal',
            title: intent.taskTitle,
            body: intent.rawText,
            status: 'ready',
            assignee: intent.workerProfile,
          );
        },
        missionRoomWorkerRosterLoader: () async => const ['manager', 'infra'],
      );
      await tester.pump(const Duration(milliseconds: 600));

      expect(gateway.statusCalls, 1);
      expect(find.byType(SnackBarAction), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        '@infra verifica la release',
      );
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
      expect(creatorCalls, 0);
      expect(find.byKey(const ValueKey('room-confirm-task')), findsNothing);

      gateway.emitComplete('manager finished');
      await tester.pump(const Duration(milliseconds: 500));
      expect(secureStore.containsKey('chat_turn_outbox_v1'), isFalse);
      ScaffoldMessenger.of(
        tester.element(find.byType(ChatScreen)),
      ).clearSnackBars();
      await tester.pump(const Duration(milliseconds: 500));
      ScaffoldMessenger.of(
        tester.element(find.byType(ChatScreen)),
      ).removeCurrentSnackBar();
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);

      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
      expect(find.byKey(const ValueKey('room-confirm-task')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('room-confirm-task')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(creatorCalls, 1);
      expect(store.room.linkedTaskIds, contains('task-after-manager-terminal'));

      // The worker task is intentionally allowed while ActiveChat finishes
      // read-only terminal transcript catch-up. Drain that background retry
      // budget so the widget-test binding also verifies it leaves no timer.
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
    },
  );

  for (final recoveredState in const [
    PreparedTurnState.prepared,
    PreparedTurnState.failedBeforeAcceptance,
    PreparedTurnState.ambiguous,
  ]) {
    testWidgets(
      'Room prepared survives hidden manager ${recoveredState.name} until explicit discard',
      (tester) async {
        final connectionId = 'conn-room-hidden-${recoveredState.name}';
        final sessionId = 'stored-room-hidden-${recoveredState.name}';
        final now = DateTime.now().millisecondsSinceEpoch;
        const roomAttachment = AttachmentDraft(
          localId: 'room-attachment',
          type: AttachmentType.document,
          name: 'room-plan.md',
          mimeType: 'text/markdown',
          sizeBytes: 12,
          localPath: '',
          uploadState: AttachmentUploadState.attached,
          remoteRef: '@file:room-plan.md',
          remoteSessionId: 'stored-room-attachment',
          remoteTransport: AttachmentRemoteTransport.desktop,
        );
        final managerTurn = PreparedTurn(
          connectionId: connectionId,
          sessionId: sessionId,
          clientTurnId: 'manager-${recoveredState.name}',
          createdAtMs: now,
          updatedAtMs: now,
          text: recoveredState == PreparedTurnState.prepared
              ? '@infra verifica el despliegue'
              : 'turno pendiente del manager',
          attachments: recoveredState == PreparedTurnState.prepared
              ? const [roomAttachment]
              : const [],
          model: 'hermes-agent',
          profile: 'manager',
          state: recoveredState,
        );
        final draftKey = ChatDraftStore.keyForTesting(
          connectionId,
          'mob-room-room-hidden-${recoveredState.name}',
          profile: 'manager',
        );
        final legacyDraftKey = 'chat_draft_v2_${connectionId}_$sessionId';
        secureStore['chat_turn_outbox_v1'] = jsonEncode({
          managerTurn.storageId: managerTurn.toJson(),
        });
        secureStore[legacyDraftKey] = jsonEncode({
          'savedAt': now,
          'text': '@infra verifica el despliegue',
          'attachments': [roomAttachment.toJson()],
          'missionRoomIntentId': 'immutable-room-intent',
          'missionRoomWorkerProfile': 'infra',
          'missionRoomBoardId': MissionRoomTaskLink.legacyCurrentBoard,
          'missionRoomTaskPhase': MissionRoomTaskPhase.prepared.name,
        });
        final originalDraft =
            jsonDecode(secureStore[legacyDraftKey]!) as Map<String, dynamic>
              ..remove('savedAt');
        final room = MissionRoom(
          id: 'room-hidden-${recoveredState.name}',
          connectionId: connectionId,
          name: 'release',
          managerProfile: 'manager',
          memberProfiles: const ['manager', 'infra'],
          managerSessionId: sessionId,
          createdAtMs: 1,
          updatedAtMs: 1,
        );
        final store = _RecordingMissionRoomStore(room);
        var creatorCalls = 0;

        await pumpChat(
          tester,
          connection: _remoteConn(connectionId),
          session: Session(
            id: sessionId,
            title: '#release',
            model: 'hermes-agent',
            source: 'gateway',
            messageCount: 1,
            isActive: false,
            preview: '',
            startedAt: 1,
            profile: 'manager',
          ),
          desktopGateway: _SubmissionGateway(),
          missionRoom: room,
          missionRoomStore: store,
          missionRoomTaskCreator: (intent) async {
            creatorCalls++;
            expect(intent.rawText, '@infra verifica el despliegue');
            return KanbanTask(
              id: 'task-${recoveredState.name}',
              title: intent.taskTitle,
              body: intent.rawText,
              status: 'ready',
              assignee: intent.workerProfile,
            );
          },
          missionRoomWorkerRosterLoader: () async => const ['manager', 'infra'],
        );
        await tester.pump(const Duration(milliseconds: 600));

        final composer = find.byType(TextField).last;
        expect(
          tester.widget<TextField>(composer).controller!.text,
          '@infra verifica el despliegue',
        );
        expect(find.text('room-plan.md'), findsOneWidget);
        final migratedDraft =
            jsonDecode(secureStore[draftKey]!) as Map<String, dynamic>
              ..remove('savedAt');
        expect(migratedDraft, originalDraft);
        expect(secureStore.containsKey(legacyDraftKey), isFalse);
        expect(creatorCalls, 0);

        // The initial recovery notice may expire, but a blocked worker action
        // must expose the same explicit discard again instead of deadlocking.
        ScaffoldMessenger.of(
          tester.element(find.byType(ChatScreen)),
        ).clearSnackBars();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.byKey(const ValueKey('send')));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('room-confirm-task')), findsNothing);
        expect(creatorCalls, 0);
        tester
            .widget<SnackBarAction>(find.byType(SnackBarAction).last)
            .onPressed();
        await tester.pump(const Duration(milliseconds: 300));
        ScaffoldMessenger.of(
          tester.element(find.byType(ChatScreen)),
        ).clearSnackBars();
        await tester.pump(const Duration(milliseconds: 500));

        expect(secureStore.containsKey('chat_turn_outbox_v1'), isFalse);
        final draftAfterDiscard =
            jsonDecode(secureStore[draftKey]!) as Map<String, dynamic>
              ..remove('savedAt');
        expect(draftAfterDiscard, originalDraft);
        expect(
          tester.widget<TextField>(composer).controller!.text,
          '@infra verifica el despliegue',
        );
        expect(find.text('room-plan.md'), findsOneWidget);

        final removeAttachment = find.descendant(
          of: find.byTooltip('Quitar adjunto').last,
          matching: find.byType(GestureDetector),
        );
        tester.widget<GestureDetector>(removeAttachment).onTap!();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('room-plan.md'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('send')));
        await tester.pump();
        expect(find.byKey(const ValueKey('room-confirm-task')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('room-confirm-task')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(creatorCalls, 1);
        expect(
          store.room.linkedTaskIds,
          contains('task-${recoveredState.name}'),
        );
      },
    );
  }

  testWidgets('si Keystore no guarda la outbox no toca el transporte', (
    tester,
  ) async {
    final gateway = _SubmissionGateway();
    final connection = _remoteConn('conn-secure-failure');
    await pumpChat(tester, connection: connection, desktopGateway: gateway);
    failOutboxWrites = true;

    await tester.enterText(
      find.byType(TextField),
      'mensaje que debe quedarse en el teléfono',
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'mensaje que debe quedarse en el teléfono',
    );
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump(const Duration(milliseconds: 600));

    expect(gateway.submissions, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'mensaje que debe quedarse en el teléfono',
    );
    expect(
      find.textContaining('No se pudo guardar el turno de forma segura'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat vacío muestra el estado vacío, no la lista de mensajes', (
    tester,
  ) async {
    await pumpChat(tester);

    // Sin mensajes: ningún ListView de conversación renderiza burbujas.
    expect(find.byType(ListView), findsNothing);
    // Pero el composer sigue presente y utilizable.
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('los mensajes del ActiveChat aparecen en la lista', (
    tester,
  ) async {
    await pumpChat(
      tester,
      messages: [
        // index 0 = más nuevo (la lista es reverse:true).
        {'role': 'assistant', 'content': 'Hola, soy Hermes'},
        {'role': 'user', 'content': 'hola mundo'},
      ],
    );

    expect(find.byType(ListView), findsOneWidget);
    expect(find.textContaining('hola mundo'), findsOneWidget);
    expect(find.textContaining('Hola, soy Hermes'), findsOneWidget);
    expect(find.text('>_ HERMES CONSOLE'), findsOneWidget);
    final agentLabel = tester.widget<Text>(find.text('>_ HERMES CONSOLE'));
    expect(agentLabel.style?.fontSize, greaterThanOrEqualTo(12.5));
    expect(
      find.byIcon(Icons.edit_outlined),
      findsOneWidget,
      reason: 'una pregunta respondida conserva el rewind tipo ChatGPT',
    );
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    final copyTarget = find
        .ancestor(
          of: find.byIcon(Icons.copy_rounded).first,
          matching: find.byType(InkWell),
        )
        .first;
    expect(tester.getSize(copyTarget), const Size(48, 48));
    await tester.tap(copyTarget);
    await tester.pump();
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    expect(clipboard?.text, 'Hola, soy Hermes');
    expect(tester.takeException(), isNull);
  });

  testWidgets('oculta el snapshot interno de tareas tras compactar', (
    tester,
  ) async {
    const internalSnapshot =
        '[Your active task list was preserved across context compression]\n'
        '- [>] verify. Ejecutar pruebas focalizadas (in_progress)\n\n'
        '[Skills pruned during compression — reload before acting on these tasks]\n'
        'The task list above crossed the compression boundary verbatim.';

    await pumpChat(
      tester,
      messages: const [
        {'role': 'assistant', 'content': 'Respuesta visible'},
        {'role': 'user', 'content': internalSnapshot},
        {'role': 'user', 'content': 'Pregunta visible'},
      ],
    );

    expect(find.textContaining('Respuesta visible'), findsOneWidget);
    expect(find.textContaining('Pregunta visible'), findsOneWidget);
    expect(
      find.textContaining('Your active task list was preserved'),
      findsNothing,
    );
    expect(
      find.textContaining('Skills pruned during compression'),
      findsNothing,
    );
    expect(
      find.byIcon(Icons.copy_rounded),
      findsNWidgets(2),
      reason: 'el snapshot oculto no debe conservar una burbuja accionable',
    );
  });

  testWidgets('mensajes terminales ofrecen selección parcial estable', (
    tester,
  ) async {
    await pumpChat(
      tester,
      messages: const [
        {'role': 'assistant', 'content': '**Respuesta** terminal'},
        {'role': 'user', 'content': 'Pregunta terminal'},
      ],
    );

    expect(find.byKey(const ValueKey('chat-select-text')), findsNothing);
    expect(find.byType(SelectionArea), findsNWidgets(2));
    expect(find.byType(SelectableText), findsNothing);
    expect(
      find.descendant(
        of: find.byType(SelectionArea),
        matching: find.byType(EditableText),
      ),
      findsNothing,
    );

    final assistantText = find.text('Respuesta terminal');
    await tester.longPress(assistantText);
    await tester.pumpAndSettle();
    final assistantArea = find
        .ancestor(of: assistantText, matching: find.byType(SelectionArea))
        .first;
    final selection = tester
        .state<SelectionAreaState>(assistantArea)
        .selectableRegion;
    expect(
      selection.contextMenuButtonItems.any(
        (item) => item.type == ContextMenuButtonType.copy,
      ),
      isTrue,
    );
    expect(selection.selectionOverlay, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el asistente en streaming no registra acción de selección', (
    tester,
  ) async {
    await pumpChat(
      tester,
      chatState: ChatPipelineState.streaming,
      messages: const [
        {
          'role': 'assistant',
          'content': 'Respuesta parcial',
          '_pipeline': false,
        },
        {'role': 'user', 'content': 'Pregunta terminal'},
      ],
    );

    expect(find.byKey(const ValueKey('chat-select-text')), findsNothing);
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    expect(
      find.descendant(
        of: find.byType(SelectionArea),
        matching: find.byType(EditableText),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('el encabezado conserva el modelo mientras Hermes ejecuta', (
    tester,
  ) async {
    await pumpChat(
      tester,
      chatState: ChatPipelineState.executing,
      messages: const [
        {'role': 'assistant', 'content': '', '_pipeline': true},
        {'role': 'user', 'content': 'trabaja'},
      ],
    );

    expect(find.text('Modelo del servidor'), findsOneWidget);
    expect(find.text('ejecutando…'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'el composer conserva el placeholder normal mientras Hermes ejecuta',
    (tester) async {
      await pumpChat(
        tester,
        chatState: ChatPipelineState.executing,
        messages: const [
          {'role': 'assistant', 'content': '', '_pipeline': true},
          {'role': 'user', 'content': 'trabaja'},
        ],
      );

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration?.hintText, 'Pregunta a Hermes…');
      expect(field.decoration?.hintText, isNot('Hermes está respondiendo…'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'un turno activo pipeline false vacío proyecta Thinking sin cabecera huérfana',
    (tester) async {
      await pumpChat(
        tester,
        chatState: ChatPipelineState.executing,
        messages: const [
          {'role': 'assistant', 'content': '', '_pipeline': false},
          {'role': 'user', 'content': 'trabaja sin respuesta visible aún'},
        ],
      );

      expect(find.byType(ThinkingTraceCard), findsOneWidget);
      expect(find.text('>_ HERMES CONSOLE'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'un turno activo pipeline false con whitespace conserva estado visible',
    (tester) async {
      await pumpChat(
        tester,
        chatState: ChatPipelineState.waiting,
        messages: const [
          {'role': 'assistant', 'content': ' \n\t ', '_pipeline': false},
          {'role': 'user', 'content': 'espera la respuesta'},
        ],
      );

      expect(find.byType(ThinkingTraceCard), findsOneWidget);
      expect(find.text('>_ HERMES CONSOLE'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'un evento tool filtrado mantiene actividad sin burbuja solo cabecera',
    (tester) async {
      await pumpChat(
        tester,
        chatState: ChatPipelineState.executing,
        messages: const [
          {
            'role': 'assistant',
            'content': '',
            '_pipeline': false,
            'tool_calls': [
              {
                'function': {
                  'name': 'search',
                  'arguments': '{"query":"estado"}',
                },
              },
            ],
          },
          {'role': 'user', 'content': 'busca el estado'},
        ],
      );

      expect(find.byType(ToolActivityGroup), findsOneWidget);
      expect(find.text('>_ HERMES CONSOLE'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'el estado vacío sobrevive al desmontaje y reenganche del chat activo',
    (tester) async {
      final connection = _conn();
      final session = _session();
      await pumpChat(
        tester,
        connection: connection,
        session: session,
        chatState: ChatPipelineState.executing,
        messages: const [
          {'role': 'assistant', 'content': '', '_pipeline': false},
          {'role': 'user', 'content': 'continúa en segundo plano'},
        ],
      );
      expect(find.byType(ThinkingTraceCard), findsOneWidget);

      Navigator.of(tester.element(find.byType(ChatScreen))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(ChatScreen), findsNothing);

      final context = tester.element(find.byType(Navigator).first);
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(connection: connection, session: session),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byType(ThinkingTraceCard), findsOneWidget);
      expect(find.text('>_ HERMES CONSOLE'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'una sesión legacy resuelve el perfil activo antes del primer attach',
    (tester) async {
      final connection = _remoteConn('conn-legacy-profile-owner');
      const session = Session(
        id: 'sess-legacy-profile-owner',
        title: 'Sesión legacy',
        model: 'hermes-agent',
        source: 'desktop',
        messageCount: 0,
        isActive: false,
        preview: '',
        startedAt: 0,
        profile: null,
      );

      final chat = await pumpChat(
        tester,
        connection: connection,
        session: session,
        preAttach: false,
        initialActiveProfile: 'trabajo',
      );

      expect(chat.sessionProfile, 'trabajo');
      final app = tester.state<HermesAppState>(find.byType(HermesApp));
      expect(
        app.activeChats.of(connection.id, session.id, profile: 'trabajo'),
        same(chat),
      );
      expect(
        app.activeChats.of(connection.id, session.id, profile: 'default'),
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('un pipeline histórico no reaparece como ejecución activa', (
    tester,
  ) async {
    await pumpChat(
      tester,
      chatState: ChatPipelineState.completed,
      messages: const [
        {'role': 'assistant', 'content': 'Turno terminado'},
        {'role': 'user', 'content': '¿sigues trabajando?'},
        {'role': 'assistant', 'content': '', '_pipeline': true},
        {'role': 'user', 'content': 'haz el cambio anterior'},
      ],
    );

    expect(find.text('Turno terminado'), findsOneWidget);
    expect(find.text('¿sigues trabajando?'), findsOneWidget);
    expect(find.byType(ThinkingTraceCard), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('los controles del chat se abren como ventana flotante', (
    tester,
  ) async {
    await pumpChat(tester);

    await tester.tap(find.byKey(const ValueKey('chat-control-trigger')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));

    expect(find.byKey(const ValueKey('chat-control-dialog')), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Modelo y razonamiento'), findsNothing);
    expect(find.text('Preferencias'), findsNothing);
    expect(find.text('Densidad del chat'), findsNothing);
    expect(find.text('Agentes y subagentes'), findsNothing);
    expect(find.text('Artefactos'), findsOneWidget);
    final surfaceSize = tester.getSize(
      find.byKey(const ValueKey('chat-control-dialog')),
    );
    expect(surfaceSize.width, lessThanOrEqualTo(520));
    expect(
      surfaceSize.height,
      lessThan(480),
      reason: 'the menu should fit its actions instead of filling the viewport',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('permisos del chat se abren como ventana flotante', (
    tester,
  ) async {
    await pumpChat(tester);

    await tester.tap(find.byKey(const ValueKey('chat-control-trigger')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    await tester.tap(find.text('Permisos / modo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));

    expect(find.byKey(const ValueKey('chat-mode-dialog')), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('artefactos del chat se abren como ventana flotante', (
    tester,
  ) async {
    await pumpChat(tester);

    await tester.tap(find.byKey(const ValueKey('chat-control-trigger')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    await tester.tap(find.text('Artefactos'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));

    expect(find.byKey(const ValueKey('chat-artifacts-dialog')), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('composingRange normaliza y acota el rango de composición', (
    tester,
  ) async {
    await pumpChat(tester);
    final input = find.byType(TextField).first;
    final field = tester.widget<TextField>(input);
    final controller = field.controller!;

    TextRange callComposingRange(TextEditingValue value, bool withComposing) {
      return (controller as dynamic).composingRange(value, withComposing)
          as TextRange;
    }

    const normal = TextEditingValue(
      text: 'hola',
      composing: TextRange(start: 0, end: 4),
    );
    expect(callComposingRange(normal, true), const TextRange(start: 0, end: 4));

    final inverted = normal.copyWith(
      composing: const TextRange(start: 4, end: 2),
    );
    expect(callComposingRange(inverted, true), TextRange.empty);

    final outOfBounds = normal.copyWith(
      composing: const TextRange(start: 0, end: 100),
    );
    expect(callComposingRange(outOfBounds, true), TextRange.empty);

    expect(callComposingRange(normal, false), TextRange.empty);
  });

  testWidgets('solo comandos slash conocidos usan color accent', (
    tester,
  ) async {
    await pumpChat(tester);
    final input = find.byType(TextField).first;
    final context = tester.element(input);
    final colors = Theme.of(context).hermes;

    List<TextSpan> textLeaves(TextSpan root) {
      final leaves = <TextSpan>[];
      void visit(InlineSpan span) {
        if (span is! TextSpan) return;
        if ((span.text ?? '').isNotEmpty) leaves.add(span);
        for (final child in span.children ?? const <InlineSpan>[]) {
          visit(child);
        }
      }

      visit(root);
      return leaves;
    }

    List<TextSpan> composerLeaves() {
      final field = tester.widget<TextField>(input);
      return textLeaves(
        field.controller!.buildTextSpan(
          context: context,
          style: TextStyle(color: colors.textPrimary),
          withComposing: true,
        ),
      );
    }

    Future<void> checkSlash(String text, String token, bool colored) async {
      await tester.enterText(input, text);
      await tester.pump();
      final leaves = composerLeaves();
      expect(leaves.map((span) => span.text).join(), text);
      final tokenLeaf = leaves.firstWhere((leaf) => leaf.text == token);
      if (colored) {
        expect(tokenLeaf.style?.color, colors.accent);
      } else {
        expect(tokenLeaf.style?.color, isNot(colors.accent));
      }
    }

    await tester.enterText(input, '/help argumento');
    await tester.pump();
    final valid = composerLeaves();
    expect(valid.map((span) => span.text).toList(), ['/help', ' argumento']);
    expect(valid.first.style?.color, colors.accent);
    expect(valid.last.style?.color, colors.textPrimary);

    await checkSlash('/compact', '/compact', true);
    await checkSlash('/HELP', '/HELP', true);
    await checkSlash('  /help arg', '/help', true);
    await checkSlash('/helpful', '/helpful', false);
    await checkSlash('/comando-inexistente', '/comando-inexistente', false);
  });

  testWidgets('slash accent aplica composing underline solo al rango', (
    tester,
  ) async {
    await pumpChat(tester);
    final input = find.byType(TextField).first;
    final context = tester.element(input);
    final colors = Theme.of(context).hermes;

    await tester.enterText(input, '/help mundo');
    await tester.pump();

    final field = tester.widget<TextField>(input);
    field.controller!.value = field.controller!.value.copyWith(
      composing: const TextRange(start: 6, end: 11),
    );
    await tester.pump();

    final span = field.controller!.buildTextSpan(
      context: context,
      style: TextStyle(color: colors.textPrimary),
      withComposing: true,
    );
    final leaves = _flattenTextSpans(
      span,
    ).where((leaf) => leaf.text?.isNotEmpty ?? false).toList();

    final slashLeaf = leaves.firstWhere((leaf) => leaf.text == '/help');
    expect(slashLeaf.style?.color, colors.accent);
    expect(slashLeaf.style?.decoration, isNot(TextDecoration.underline));

    final spaceLeaf = leaves.firstWhere((leaf) => leaf.text == ' ');
    expect(spaceLeaf.style?.color, colors.textPrimary);
    expect(spaceLeaf.style?.decoration, isNot(TextDecoration.underline));

    final composingLeaf = leaves.firstWhere((leaf) => leaf.text == 'mundo');
    expect(composingLeaf.style?.decoration, TextDecoration.underline);
  });

  testWidgets('la ayuda slash se abre como ventana flotante', (tester) async {
    await pumpChat(tester);

    await tester.enterText(find.byType(TextField), '/help');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));

    expect(
      find.byKey(const ValueKey('chat-slash-help-dialog')),
      findsOneWidget,
    );
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'el selector de modelo es flotante y libera el buscador al cerrar',
    (tester) async {
      await pumpChat(tester);

      await tester.tap(find.bySemanticsLabel('Modelo y sesión'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));

      expect(find.byKey(const ValueKey('chat-model-dialog')), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      final search = find.byKey(const ValueKey('chat-model-search'));
      expect(search, findsOneWidget);
      await tester.enterText(search, 'modelo');
      await tester.pump();

      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      expect(find.byKey(const ValueKey('chat-model-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'el modelo aceptado cambia al instante, rechaza con rollback y reconcilia session info',
    (tester) async {
      final gateway = _ModelConfigGateway();
      final chat = await pumpChat(
        tester,
        desktopGateway: gateway,
        connection: _remoteConn('conn-model-projection'),
        messagesLoaded: false,
      );
      for (var frame = 0; !chat.hasDesktopRuntime && frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(chat.hasDesktopRuntime, isTrue);

      gateway.emit('session.info', const {
        'info': {'model': 'old-model', 'provider': 'provider-a'},
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('old-model')), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Modelo y sesión'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('chat-model-dialog')), findsOneWidget);
      await tester.tap(find.text('new-model').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));

      expect(gateway.modelSelections.last.modelId, 'new-model');
      expect(
        find.byKey(const ValueKey('new-model')),
        findsOneWidget,
        reason: 'el ACK aceptado no debe esperar al siguiente session.info',
      );

      gateway.emit('session.info', const {
        'info': {'model': 'server-model', 'provider': 'provider-a'},
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('server-model')), findsOneWidget);

      gateway.modelError = const TuiGatewayRpcError(
        'config.set',
        'rejected',
        code: 5001,
      );
      await tester.tap(find.bySemanticsLabel('Modelo y sesión'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('bad-model').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(gateway.modelSelections.last.modelId, 'bad-model');
      expect(
        find.byKey(const ValueKey('server-model')),
        findsOneWidget,
        reason: 'un rechazo conserva el último modelo efectivo',
      );
      expect(find.byKey(const ValueKey('bad-model')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dos conexiones homónimas no comparten preferencia legacy', (
    tester,
  ) async {
    final gateway = _UiRewindGateway()
      ..resumeExistingError = const TuiGatewayRpcError(
        'session.resume',
        'not found',
        code: 4007,
      );
    const connectionId = 'conn-profile-model';
    const sessionId = 'mob-shared-model';
    await pumpChat(
      tester,
      desktopGateway: gateway,
      connection: _remoteConn(connectionId),
      session: _session().copyWith(id: sessionId, title: 'Draft work'),
      initialPreferences: const {
        'selected_model_$sessionId': 'leaked-model',
        'selected_provider_${connectionId}_$sessionId': 'provider-a',
      },
    );
    await tester.enterText(find.byType(TextField), 'primer turno');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(gateway.createConfigs.single.model, isNull);
    expect(gateway.submissions, ['primer turno']);
    gateway.emit('message.complete', const {'text': 'hecho'});
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets(
    'un session.info con el modelo previo no revierte una elección aceptada',
    (tester) async {
      final gateway = _ModelConfigGateway();
      final chat = await pumpChat(
        tester,
        desktopGateway: gateway,
        connection: _remoteConn('conn-model-stale-info'),
        messagesLoaded: false,
      );
      for (var frame = 0; !chat.hasDesktopRuntime && frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(chat.hasDesktopRuntime, isTrue);

      gateway.emit('session.info', const {
        'info': {'model': 'old-model', 'provider': 'provider-a'},
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('old-model')), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Modelo y sesión'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('new-model').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      expect(gateway.modelSelections.last.modelId, 'new-model');
      expect(find.byKey(const ValueKey('new-model')), findsOneWidget);

      // Un session.info generado antes de que el servidor aplique el cambio
      // (switch diferido a mitad de turno) sigue reportando el modelo previo.
      // El extra 'note' solo fuerza el repintado que cualquier evento real
      // posterior (token, métricas, otro info) provocaría.
      gateway.emit('session.info', const {
        'info': {
          'model': 'old-model',
          'provider': 'provider-a',
          'note': 'stale',
        },
      });
      await tester.pump();
      expect(
        find.byKey(const ValueKey('new-model')),
        findsOneWidget,
        reason: 'un info previo a la aplicación no repinta el modelo viejo',
      );
      expect(find.byKey(const ValueKey('old-model')), findsNothing);

      // Cuando el switch aterriza, session.info confirma el modelo pedido y la
      // cabecera lo sigue mostrando.
      gateway.emit('session.info', const {
        'info': {'model': 'new-model', 'provider': 'provider-a'},
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('new-model')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cerrar selección antes de rewind no retiene el Overlay', (
    tester,
  ) async {
    final gateway = _UiRewindGateway();
    final chat = await pumpChat(
      tester,
      desktopGateway: gateway,
      connection: _remoteConn('conn-selection-rewind'),
      messages: [
        {'role': 'assistant', 'content': 'Respuesta para seleccionar'},
        {'role': 'user', 'content': 'pregunta original'},
      ],
    );

    expect(find.byKey(const ValueKey('chat-select-text')), findsNothing);
    final assistantText = find.text('Respuesta para seleccionar');
    await tester.longPress(assistantText);
    await tester.pumpAndSettle();
    final assistantArea = find
        .ancestor(of: assistantText, matching: find.byType(SelectionArea))
        .first;
    expect(
      tester
          .state<SelectionAreaState>(assistantArea)
          .selectableRegion
          .selectionOverlay,
      isNotNull,
    );
    expect(
      find.descendant(of: assistantArea, matching: find.byType(EditableText)),
      findsNothing,
    );

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.enterText(
      find.byKey(const ValueKey('edit-message-composer')),
      'pregunta corregida tras seleccionar',
    );
    await tester.tap(find.text('Guardar y enviar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(gateway.rewinds, [
      (text: 'pregunta corregida tras seleccionar', ordinal: 0),
    ]);
    expect(tester.takeException(), isNull);
    gateway.emit('message.complete', {'text': 'Respuesta corregida'});
    for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(chat.isStreaming, isFalse);
  });

  testWidgets(
    'auth Dashboard ausente al editar restaura el historial sin envío REST',
    (tester) async {
      final gateway = _UiRewindGateway()
        ..connected = false
        ..connectError = const DashboardAuthException(
          DashboardAuthFailureCode.loginRequired,
        );
      final chat = await pumpChat(
        tester,
        desktopGateway: gateway,
        connection: _remoteConn('conn-auth-rewrite'),
        messages: const [
          {'role': 'assistant', 'content': 'Respuesta original'},
          {'role': 'user', 'content': 'pregunta original', '_desktopRowId': 73},
        ],
      );

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('edit-message-composer')),
        'pregunta que no debe enviarse',
      );
      await tester.tap(find.text('Guardar y enviar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      expect(find.textContaining('pregunta original'), findsOneWidget);
      expect(
        find.textContaining('pregunta que no debe enviarse'),
        findsNothing,
      );
      expect(chat.state, ChatPipelineState.idle);
      expect(gateway.rewinds, isEmpty);
      expect(
        find.text(
          'El Dashboard requiere iniciar sesión. Configura su usuario y contraseña en esta instancia.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('editar en reposo rebobina y reenvía desde el mensaje elegido', (
    tester,
  ) async {
    final gateway = _UiRewindGateway();
    final chat = await pumpChat(
      tester,
      desktopGateway: gateway,
      connection: _remoteConn('conn-idle-rewrite'),
      messages: [
        {'role': 'assistant', 'content': 'Respuesta original'},
        {'role': 'user', 'content': 'pregunta original'},
      ],
    );

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      find.byKey(const ValueKey('chat-edit-message-dialog')),
      findsOneWidget,
    );
    expect(find.byType(BottomSheet), findsNothing);
    final editor = find.byKey(const ValueKey('edit-message-composer'));
    expect(editor, findsOneWidget);
    await tester.enterText(editor, 'pregunta corregida');
    await tester.tap(find.text('Guardar y enviar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(gateway.resolutionCalls, [(text: 'pregunta original', ordinal: 0)]);
    expect(gateway.rewinds, [(text: 'pregunta corregida', ordinal: 0)]);
    expect(gateway.rewindRowIds, [73]);
    expect(find.textContaining('pregunta original'), findsOneWidget);
    expect(tester.takeException(), isNull);
    gateway.emit('message.complete', {'text': 'Respuesta corregida'});
    for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(find.textContaining('pregunta corregida'), findsOneWidget);
    expect(chat.isStreaming, isFalse);
  });

  testWidgets('prompt.submit de rewind reserva la sesión frente a otro envío', (
    tester,
  ) async {
    final gateway = _UiRewindGateway()..rewindGate = Completer<void>();
    final chat = await pumpChat(
      tester,
      desktopGateway: gateway,
      connection: _remoteConn('conn-submit-reservation-rewrite'),
      messages: [
        {'role': 'assistant', 'content': 'respuesta original'},
        {'role': 'user', 'content': 'pregunta original'},
      ],
    );

    final rewrite = chat.rewrite(
      userOrdinal: 0,
      text: 'pregunta corregida reservada',
      model: 'test-model',
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(gateway.rewinds, hasLength(1));

    final competingAccepted = await chat.send(
      fullText: 'turno competidor',
      model: 'test-model',
      history: const [],
    );
    gateway.rewindGate!.complete();
    await rewrite;

    expect(competingAccepted, isFalse);
    expect(gateway.submissions, isEmpty);
    expect(
      chat.messages.any((message) => message['content'] == 'turno competidor'),
      isFalse,
    );
    gateway.emit('message.complete', {'text': 'respuesta corregida'});
    for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(chat.isStreaming, isFalse);
  });

  testWidgets('rewind usa directamente el id numérico de una fila REST', (
    tester,
  ) async {
    final gateway = _UiRewindGateway();
    final chat = await pumpChat(
      tester,
      desktopGateway: gateway,
      connection: _remoteConn('conn-rest-row-rewrite'),
      messages: const [
        {'id': 74, 'role': 'assistant', 'content': 'respuesta durable'},
        {'id': 73, 'role': 'user', 'content': 'pregunta durable'},
      ],
    );

    await chat.rewrite(
      userOrdinal: 0,
      text: 'pregunta durable corregida',
      model: 'test-model',
    );

    expect(gateway.resolutionCalls, isEmpty);
    expect(gateway.rewindRowIds, [73]);
    gateway.emit('message.complete', {'text': 'respuesta corregida'});
    for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
  });

  testWidgets(
    'ACK sin survivor_user_row_ids invalida identidades del prefijo',
    (tester) async {
      final gateway = _UiRewindGateway(survivorUserRowIds: null);
      final chat = await pumpChat(
        tester,
        desktopGateway: gateway,
        connection: _remoteConn('conn-missing-survivor-ack'),
        messages: [
          {
            'role': 'assistant',
            'content': 'respuesta segunda',
            '_desktopSnapshotKind': 'persisted',
          },
          {
            'role': 'user',
            'content': 'pregunta segunda',
            '_desktopSnapshotKind': 'persisted',
            '_desktopRowId': 73,
          },
          {
            'role': 'assistant',
            'content': 'respuesta primera',
            '_desktopSnapshotKind': 'persisted',
          },
          {
            'role': 'user',
            'content': 'pregunta primera',
            '_desktopSnapshotKind': 'persisted',
            '_desktopRowId': 11,
          },
        ],
      );

      await chat.rewrite(
        userOrdinal: 1,
        text: 'pregunta segunda editada',
        model: 'test-model',
      );

      final survivor = chat.messages.singleWhere(
        (message) => message['content'] == 'pregunta primera',
      );
      expect(survivor.containsKey('_desktopRowId'), isFalse);
      gateway.emit('message.complete', {'text': 'respuesta editada'});
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(chat.isStreaming, isFalse);
    },
  );

  testWidgets('dos rewinds consecutivos reutilizan survivor_user_row_ids', (
    tester,
  ) async {
    final gateway = _UiRewindGateway(
      resolvedRowId: 73,
      survivorUserRowIds: const [111],
    );
    final chat = await pumpChat(
      tester,
      desktopGateway: gateway,
      connection: _remoteConn('conn-survivor-rewrite'),
      messages: [
        {'role': 'assistant', 'content': 'respuesta dos'},
        {'role': 'user', 'content': 'pregunta dos'},
        {'role': 'assistant', 'content': 'respuesta uno'},
        {'role': 'user', 'content': 'pregunta uno'},
      ],
    );

    await chat.rewrite(
      userOrdinal: 1,
      text: 'pregunta dos corregida',
      model: 'test-model',
    );
    expect(gateway.rewindRowIds, [73]);
    gateway.emit('message.complete', {'text': 'respuesta dos corregida'});
    for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
      await tester.pump(const Duration(milliseconds: 33));
    }

    await chat.rewrite(
      userOrdinal: 0,
      text: 'pregunta uno corregida',
      model: 'test-model',
    );
    expect(gateway.rewindRowIds, [73, 111]);
    expect(gateway.resolutionCalls, [(text: 'pregunta dos', ordinal: 1)]);
    gateway.emit('message.complete', {'text': 'respuesta uno corregida'});
    for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(chat.isStreaming, isFalse);
  });

  testWidgets('turno nuevo durante session.history aborta rewind sin truncar', (
    tester,
  ) async {
    final gateway = _UiRewindGateway()..resolutionGate = Completer<int?>();
    final chat = await pumpChat(
      tester,
      desktopGateway: gateway,
      connection: _remoteConn('conn-history-race-rewrite'),
      messages: [
        {'role': 'assistant', 'content': 'Respuesta original'},
        {'role': 'user', 'content': 'pregunta original'},
      ],
    );

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('edit-message-composer')),
      'pregunta corregida que debe abortar',
    );
    await tester.tap(find.text('Guardar y enviar'));
    await tester.pump();
    expect(gateway.resolutionCalls, [(text: 'pregunta original', ordinal: 0)]);

    final newTurn = chat.send(
      fullText: 'turno nuevo autoritativo',
      model: 'test-model',
      history: const [],
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(await newTurn, isTrue);
    gateway.resolutionGate!.complete(73);
    await tester.pump(const Duration(milliseconds: 700));

    expect(gateway.rewinds, isEmpty);
    expect(
      chat.messages.any(
        (message) => message['content'] == 'turno nuevo autoritativo',
      ),
      isTrue,
    );
    expect(
      chat.messages.any(
        (message) =>
            message['content'] == 'pregunta corregida que debe abortar',
      ),
      isFalse,
    );
    gateway.emit('message.complete', {'text': 'Respuesta del turno nuevo'});
    for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(chat.isStreaming, isFalse);
  });

  testWidgets(
    'guardar edición sigue siendo táctil con teclado Android compacto',
    (tester) async {
      tester.view
        ..physicalSize = const Size(360, 640)
        ..devicePixelRatio = 1
        ..viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.reset);
      final gateway = _UiRewindGateway();
      final chat = await pumpChat(
        tester,
        desktopGateway: gateway,
        connection: _remoteConn('conn-compact-rewrite'),
        messages: [
          {'role': 'assistant', 'content': 'Respuesta original'},
          {'role': 'user', 'content': 'pregunta original'},
        ],
      );

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('edit-message-composer')),
        'pregunta corregida desde Android',
      );

      final apply = find.text('Guardar y enviar');
      expect(apply, findsOneWidget);
      expect(apply.hitTestable(), findsOneWidget);
      await tester.tap(apply);
      await tester.pump(const Duration(milliseconds: 700));

      expect(gateway.rewinds, [
        (text: 'pregunta corregida desde Android', ordinal: 0),
      ]);
      gateway.emit('message.complete', {'text': 'Respuesta corregida Android'});
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(find.text('Respuesta corregida Android'), findsOneWidget);
      expect(chat.isStreaming, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  Finder transcript(String text) => find.descendant(
    of: chatListFinder(),
    matching: find.textContaining(text),
  );

  Future<({ActiveChat chat, _UiRewindGateway gateway})> openRewriteEditor(
    WidgetTester tester,
    String connectionId, {
    _UiRewindGateway? gateway,
    StoredSessionMessageLoader? storedMessageLoader,
  }) async {
    gateway ??= _UiRewindGateway();
    final chat = await pumpChat(
      tester,
      desktopGateway: gateway,
      connection: _remoteConn(connectionId),
      storedMessageLoader: storedMessageLoader,
      messages: const [
        {'role': 'assistant', 'content': 'Respuesta original'},
        {'role': 'user', 'content': 'pregunta original'},
      ],
    );
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    return (chat: chat, gateway: gateway);
  }

  Future<void> submitEdit(WidgetTester tester, [String? text]) async {
    if (text != null) {
      await tester.enterText(
        find.byKey(const ValueKey('edit-message-composer')),
        text,
      );
    }
    await tester.tap(find.text('Guardar y enviar'));
  }

  testWidgets('editar a texto vacío no rebobina ni altera el turno', (
    tester,
  ) async {
    final (:chat, :gateway) = await openRewriteEditor(tester, 'conn-empty');
    await submitEdit(tester, '   ');
    await tester.pumpAndSettle();
    expect(gateway.rewinds, isEmpty);
    expect(transcript('pregunta original'), findsOneWidget);
    expect(chat.state, ChatPipelineState.idle);
    expect(find.byIcon(Icons.edit_outlined).hitTestable(), findsOneWidget);
  });

  testWidgets('guardar texto idéntico no rebobina ni altera el turno', (
    tester,
  ) async {
    final (:chat, :gateway) = await openRewriteEditor(tester, 'conn-same');
    await submitEdit(tester);
    await tester.pumpAndSettle();
    expect(gateway.rewinds, isEmpty);
    expect(transcript('pregunta original'), findsOneWidget);
    expect(chat.state, ChatPipelineState.idle);
    expect(find.byIcon(Icons.edit_outlined).hitTestable(), findsOneWidget);
  });

  testWidgets('auth Dashboard al resolver identidad muestra configuración', (
    tester,
  ) async {
    final failing = _UiRewindGateway()
      ..resumeExistingError = const DashboardAuthException(
        DashboardAuthFailureCode.loginRequired,
      );
    final (:chat, gateway: _) = await openRewriteEditor(
      tester,
      'conn-rewrite-identity-auth',
      gateway: failing,
    );
    await submitEdit(tester, 'pregunta sin identidad');
    await tester.pump(const Duration(milliseconds: 700));

    expect(failing.rewinds, isEmpty);
    expect(transcript('pregunta original'), findsOneWidget);
    expect(transcript('pregunta sin identidad'), findsNothing);
    expect(chat.state, ChatPipelineState.idle);
    expect(
      find.text(
        'El Dashboard requiere iniciar sesión. Configura su usuario y contraseña en esta instancia.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('auth Dashboard rechazada por rewind restaura transcript', (
    tester,
  ) async {
    final failing = _UiRewindGateway()
      ..rewindError = const DashboardAuthException(
        DashboardAuthFailureCode.invalidCredentials,
        statusCode: 401,
      );
    final (:chat, gateway: _) = await openRewriteEditor(
      tester,
      'conn-rewind-auth-failed',
      gateway: failing,
    );
    await submitEdit(tester, 'pregunta no autorizada');
    await tester.pump(const Duration(milliseconds: 700));

    expect(failing.rewinds, [(text: 'pregunta no autorizada', ordinal: 0)]);
    expect(transcript('pregunta original'), findsOneWidget);
    expect(transcript('pregunta no autorizada'), findsNothing);
    expect(chat.state, ChatPipelineState.idle);
    expect(
      find.text(
        'El Dashboard requiere iniciar sesión. Configura su usuario y contraseña en esta instancia.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('fallo RPC restaura transcript y vuelve a habilitar editar', (
    tester,
  ) async {
    final failing = _UiRewindGateway()
      ..rewindError = const TuiGatewayRpcError(
        'prompt.submit',
        'synthetic rewind failure',
        code: 5005,
      );
    final (:chat, gateway: _) = await openRewriteEditor(
      tester,
      'conn-failed',
      gateway: failing,
    );
    await submitEdit(tester, 'pregunta rechazada');
    await tester.pump(const Duration(milliseconds: 700));
    expect(failing.rewinds, [(text: 'pregunta rechazada', ordinal: 0)]);
    expect(transcript('pregunta original'), findsOneWidget);
    expect(transcript('pregunta rechazada'), findsNothing);
    expect(chat.state, ChatPipelineState.idle);
    expect(
      find.text(
        'No se pudo editar el mensaje. La conversación original sigue disponible.',
      ),
      findsOneWidget,
    );
    final edit = find.byIcon(Icons.edit_outlined).hitTestable();
    expect(edit, findsOneWidget);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('chat-edit-message-dialog')),
      findsOneWidget,
    );
  });

  testWidgets('rewind conserva snapshot hasta terminal e hidratación tardíos', (
    tester,
  ) async {
    final restGate = Completer<List<Map<String, dynamic>>>();
    final (:chat, :gateway) = await openRewriteEditor(
      tester,
      'conn-hydrated',
      storedMessageLoader: (_, _) => restGate.future,
    );
    await submitEdit(tester, 'pregunta hidratada');
    await tester.pump(const Duration(milliseconds: 700));
    expect(gateway.rewinds, [(text: 'pregunta hidratada', ordinal: 0)]);
    expect(transcript('pregunta original'), findsOneWidget);
    expect(transcript('pregunta hidratada'), findsNothing);
    gateway.emit('message.complete', {'text': 'Respuesta hidratada'});
    await tester.pump();
    expect(chat.isStreaming, isTrue);
    expect(transcript('pregunta original'), findsOneWidget);
    restGate.complete(const [
      {'role': 'user', 'content': 'pregunta hidratada'},
      {'role': 'assistant', 'content': 'Respuesta hidratada'},
    ]);
    for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    await tester.pump(const Duration(milliseconds: 700));
    expect(transcript('pregunta original'), findsNothing);
    expect(transcript('pregunta hidratada'), findsOneWidget);
    expect(find.text('Respuesta hidratada'), findsOneWidget);
    expect(
      chat.messages.where((m) => m['content'] == 'Respuesta hidratada'),
      hasLength(1),
    );
    expect(chat.isStreaming, isFalse);
  });

  testWidgets('regenerar ignora el pseudo-turno de cambio de modelo', (
    tester,
  ) async {
    final gateway = _UiRewindGateway();
    final chat = await pumpChat(
      tester,
      desktopGateway: gateway,
      connection: _remoteConn('conn-regenerate-model-switch'),
      messages: [
        {'role': 'assistant', 'content': 'Respuesta más reciente'},
        {'role': 'user', 'content': 'Segunda pregunta'},
        {
          'role': 'user',
          'content':
              '[System: The active model for this chat has changed to k3.]',
          'display_kind': 'model_switch',
        },
        {'role': 'assistant', 'content': 'Respuesta anterior'},
        {'role': 'user', 'content': 'Primera pregunta'},
      ],
    );

    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Regenerar respuesta'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(gateway.rewinds, hasLength(1));
    expect(gateway.rewinds.single.text, 'Segunda pregunta');
    expect(gateway.rewinds.single.ordinal, 1);
    gateway.emit('message.complete', {'text': 'Respuesta regenerada'});
    for (var frame = 0; frame < 20 && chat.isStreaming; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(chat.isStreaming, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'delegación terminada se muestra como fila editorial sin payload interno',
    (tester) async {
      const raw =
          '[ASYNC DELEGATION BATCH COMPLETE — deleg_123]\n'
          'Role: worker\nModel: secret\nPath: /home/demo-user/project';
      await pumpChat(
        tester,
        messages: [
          {
            'role': 'user',
            'content': raw,
            'display_kind': 'async_delegation_complete',
            'display_metadata': {
              'task_count': 3,
              'completed_count': 2,
              'failed_count': 1,
              'duration_seconds': 42,
            },
          },
          {'role': 'user', 'content': 'Pregunta real'},
        ],
      );

      expect(find.text('Trabajo en segundo plano'), findsOneWidget);
      expect(
        find.text('3 agentes finalizados · 1 con error · 42 s'),
        findsOneWidget,
      );
      expect(find.textContaining('[ASYNC DELEGATION'), findsNothing);
      expect(find.textContaining('/home/demo-user'), findsNothing);
      expect(find.text('Pregunta real'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('scroll durante streaming conserva todo el texto ya recibido', (
    tester,
  ) async {
    final gateway = _UiRewindGateway();
    final performance = ChatPerformanceProbe();
    final chat = await pumpChat(
      tester,
      connection: _remoteConn('conn-stream-scroll-stable'),
      desktopGateway: gateway,
      performanceProbe: performance,
      messages: const [
        {'role': 'assistant', 'content': 'Respuesta histórica **estable**.'},
        {'role': 'user', 'content': 'Pregunta anterior'},
      ],
    );

    await chat.send(
      fullText: 'respuesta larga',
      model: 'hermes-agent',
      history: const [],
    );
    gateway.emit('message.start');
    gateway.emit('message.delta', {
      'text': 'Primera parte visible. Segunda parte también visible.',
    });
    for (
      var frame = 0;
      frame < 100 &&
          !chat.assistantContent.contains('Segunda parte también visible.');
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(
      chat.assistantContent,
      'Primera parte visible. Segunda parte también visible.',
    );

    await tester.tap(find.byType(ChatScrollInteractionGuard));
    await tester.pump();
    // HermesApp anima el tema inicial durante 420 ms. Esa transición legítima
    // actualiza la ruta completa aunque no llegue ningún token; termina antes
    // de medir para que el probe contabilice solo el delta que sigue.
    await tester.pump(const Duration(milliseconds: 450));
    performance.reset();

    expect(
      find.textContaining(
        'Primera parte visible. Segunda parte también visible.',
      ),
      findsOneWidget,
    );

    gateway.emit('message.delta', {'text': ' Tercera parte recibida.'});
    for (
      var frame = 0;
      frame < 100 && !chat.assistantContent.contains('Tercera parte recibida.');
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    // El toque reenganchó el seguimiento al no arrastrar: el reveal gradual
    // enseña el tramo nuevo en unos pocos ticks; drena antes de afirmar.
    for (
      var frame = 0;
      frame < 100 &&
          find.textContaining('Tercera parte recibida.').evaluate().isEmpty;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 33));
    }

    expect(
      find.textContaining(
        'Primera parte visible. Segunda parte también visible. '
        'Tercera parte recibida.',
      ),
      findsOneWidget,
      reason: 'pausar el auto-scroll no puede truncar el transcript',
    );
    expect(
      performance.screenBuilds,
      0,
      reason: 'un delta posterior no reconstruye el Scaffold',
    );
    expect(
      performance.composerBuilds,
      0,
      reason: 'el composer queda fuera del subtree vivo',
    );
    expect(
      performance.terminalAssistantBuilds,
      0,
      reason: 'las respuestas históricas no se reconstruyen por token',
    );
    expect(performance.terminalProjectionComputations, 0);
    expect(performance.liveAssistantBuilds, greaterThan(0));
    expect(tester.takeException(), isNull);

    gateway.emit('message.complete', {
      'text':
          'Primera parte visible. Segunda parte también visible. '
          'Tercera parte recibida.',
    });
    for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
  });

  testWidgets('tap sobre el texto en streaming no duplica la burbuja viva', (
    tester,
  ) async {
    final gateway = _UiRewindGateway();
    final chat = await pumpChat(
      tester,
      connection: _remoteConn('conn-stream-tap-no-dup'),
      desktopGateway: gateway,
      messages: const [
        {'role': 'assistant', 'content': 'Respuesta histórica previa.'},
        {'role': 'user', 'content': 'Pregunta anterior'},
      ],
    );
    await chat.send(
      fullText: 'respuesta larga con split estable',
      model: 'hermes-agent',
      history: const [],
    );
    gateway.emit('message.start');
    // >1600 chars y varios bloques: activa prefijo estable + cola mutable.
    final blockA = List.filled(
      50,
      'MARCA-ALFA texto estable del primer bloque.',
    ).join(' ');
    final blockB = List.filled(
      40,
      'MARCA-BETA texto estable del segundo bloque.',
    ).join(' ');
    gateway.emit('message.delta', {'text': '$blockA\n\n$blockB\n\nCola viva.'});
    for (
      var frame = 0;
      frame < 100 && !chat.assistantContent.contains('Cola viva.');
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    // El usuario toca a mitad de la escritura: espera solo a que el reveal
    // enseñe el primer marcador, sin drenar el texto completo.
    for (
      var frame = 0;
      frame < 100 && find.textContaining('MARCA-ALFA').evaluate().isEmpty;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 33));
    }

    await tester.tap(find.textContaining('MARCA-ALFA').first);
    await tester.pump();

    // Tras el toque se pinta todo lo recibido, exactamente una vez.
    expect(
      find.textContaining('MARCA-ALFA'),
      findsOneWidget,
      reason: 'el prefijo estable no puede pintarse dos veces tras un tap',
    );
    expect(find.textContaining('MARCA-BETA'), findsOneWidget);
    expect(find.textContaining('Cola viva.'), findsOneWidget);

    // El stream sigue en la MISMA burbuja: nuevos deltas no abren una copia.
    gateway.emit('message.delta', {'text': ' MARCA-GAMMA cola posterior.'});
    for (
      var frame = 0;
      frame < 100 && !chat.assistantContent.contains('MARCA-GAMMA');
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    for (
      var frame = 0;
      frame < 100 && find.textContaining('MARCA-GAMMA').evaluate().isEmpty;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(find.textContaining('MARCA-ALFA'), findsOneWidget);
    expect(find.textContaining('MARCA-BETA'), findsOneWidget);
    expect(find.textContaining('MARCA-GAMMA'), findsOneWidget);
    expect(tester.takeException(), isNull);

    gateway.emit('message.complete', {
      'text': '$blockA\n\n$blockB\n\nCola viva. MARCA-GAMMA cola posterior.',
    });
    for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(find.textContaining('MARCA-ALFA'), findsOneWidget);
    expect(find.textContaining('MARCA-GAMMA'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el streaming no reproyecta el prefijo estable en cada frame', (
    tester,
  ) async {
    final gateway = _UiRewindGateway();
    final probe = ChatPerformanceProbe();
    final chat = await pumpChat(
      tester,
      connection: _remoteConn('conn-live-stable-split'),
      desktopGateway: gateway,
      performanceProbe: probe,
      messages: const [
        {'role': 'assistant', 'content': 'Respuesta histórica previa.'},
        {'role': 'user', 'content': 'Pregunta anterior'},
      ],
    );
    await chat.send(
      fullText: 'respuesta larga en streaming',
      model: 'hermes-agent',
      history: const [],
    );
    gateway.emit('message.start');
    // Primer bloque cerrado que supera el umbral de split + inicio de cola.
    final prefix = List.filled(120, 'Bloque estable del prefijo.').join(' ');
    gateway.emit('message.delta', {'text': '$prefix\n\nCola viva inicial.'});
    for (
      var frame = 0;
      frame < 100 && !chat.assistantContent.contains('Cola viva inicial.');
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    // Deja que el reveal cruce la frontera: el prefijo se proyecta UNA vez.
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(probe.liveStableProjectionComputations, 1);
    // La transición de tema inicial de HermesApp puede reconstruir la ruta; se
    // mide solo el tramo de streaming posterior.
    probe.reset();

    for (var delta = 0; delta < 8; delta++) {
      gateway.emit('message.delta', {'text': ' Fragmento de cola $delta.'});
      for (
        var frame = 0;
        frame < 100 &&
            !chat.assistantContent.contains('Fragmento de cola $delta.');
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 33));
      }
    }
    // Drena el reveal para contar todos los frames vivos del tramo medido.
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 33));
    }

    expect(
      probe.liveAssistantBuilds,
      greaterThan(6),
      reason: 'el host vivo sí se reconstruye con cada frame de streaming',
    );
    expect(
      probe.liveStableProjectionComputations,
      0,
      reason:
          'N flushes no reproyectan el prefijo cerrado N veces: solo la '
          'cola mutable se normaliza y parsea por frame',
    );
    expect(
      probe.terminalProjectionComputations,
      0,
      reason: 'el streaming nunca pasa por la proyección terminal',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cancelar una respuesta larga la trocea en vez de pintarla entera',
    (tester) async {
      final gateway = _UiRewindGateway();
      final probe = ChatPerformanceProbe();
      final chat = await pumpChat(
        tester,
        connection: _remoteConn('conn-cancel-chunked'),
        desktopGateway: gateway,
        performanceProbe: probe,
      );
      await chat.send(
        fullText: 'respuesta muy larga cancelable',
        model: 'hermes-agent',
        history: const [],
      );
      gateway.emit('message.start');
      final paragraph = List.filled(
        90,
        'Párrafo cancelable con texto estable.',
      ).join(' ');
      gateway.emit('message.delta', {
        'text': List.filled(4, paragraph).join('\n\n'),
      });
      for (
        var frame = 0;
        frame < 100 && !chat.assistantContent.contains(paragraph);
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(
        probe.terminalProjectionComputations,
        0,
        reason: 'siguiendo el fondo, el vivo nunca usa la proyección terminal',
      );

      chat.cancel();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 33));

      expect(chat.state, ChatPipelineState.cancelled);
      expect(chat.messages.first['_cancelled'], isTrue);
      expect(
        find.text('cancelled'),
        findsOneWidget,
        reason:
            'la marca pertenece al mensaje: solo la lleva el slice de cierre',
      );
      expect(
        probe.terminalProjectionComputations,
        greaterThan(1),
        reason:
            'el parcial cancelado largo genera un plan troceado (varios '
            'slices proyectados), no un único MarkdownBody gigante',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'el reveal del asistente vivo es gradual y alcanza todo el texto',
    (tester) async {
      final gateway = _UiRewindGateway();
      final chat = await pumpChat(
        tester,
        connection: _remoteConn('conn-gradual-reveal'),
        desktopGateway: gateway,
      );
      await chat.send(
        fullText: 'cuenta algo largo',
        model: 'hermes-agent',
        history: const [],
      );
      gateway.emit('message.start');
      final body =
          'INICIO-DEL-TEXTO '
          '${List.filled(300, 'palabra').join(' ')} FIN-DEL-TEXTO';
      gateway.emit('message.delta', {'text': body});
      await tester.pump(const Duration(milliseconds: 34));

      expect(
        chat.assistantContent,
        body,
        reason:
            'el transcript recibe el delta completo: el reveal es solo '
            'visual, nunca trocea el contenido autoritativo',
      );
      expect(find.textContaining('INICIO-DEL-TEXTO'), findsOneWidget);
      expect(
        find.textContaining('FIN-DEL-TEXTO'),
        findsNothing,
        reason:
            'a mitad de stream el contenido revelado es menor que el '
            'recibido: el texto se escribe de forma gradual',
      );

      for (
        var frame = 0;
        frame < 100 && find.textContaining('FIN-DEL-TEXTO').evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(
        find.textContaining('FIN-DEL-TEXTO'),
        findsOneWidget,
        reason: 'el reveal alcanza siempre todo lo recibido',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'la pausa entre segmentos no duplica ni reinicia la burbuja sellada',
    (tester) async {
      final gateway = _UiRewindGateway();
      final chat = await pumpChat(
        tester,
        connection: _remoteConn('conn-multisegment-pause'),
        desktopGateway: gateway,
      );
      await chat.send(
        fullText: 'respuesta en dos segmentos',
        model: 'hermes-agent',
        history: const [],
      );
      gateway.emit('message.start');
      gateway.emit('message.delta', const {
        'text': 'PRIMER-SEGMENTO visible antes de la herramienta.',
      });
      for (
        var frame = 0;
        frame < 100 && !chat.assistantContent.contains('PRIMER-SEGMENTO');
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      // Drena el reveal del primer segmento.
      for (
        var frame = 0;
        frame < 100 &&
            find
                .textContaining('visible antes de la herramienta.')
                .evaluate()
                .isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(find.textContaining('PRIMER-SEGMENTO'), findsOneWidget);

      // El servidor sella el segmento y abre otro dentro del MISMO turno.
      gateway.emit('message.interim', const {
        'text': 'PRIMER-SEGMENTO visible antes de la herramienta.',
      });
      for (
        var frame = 0;
        frame < 100 && chat.messages.first['_pipeline'] != true;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      await tester.pump(const Duration(milliseconds: 33));

      expect(
        find.textContaining('PRIMER-SEGMENTO'),
        findsOneWidget,
        reason:
            'durante la pausa entre segmentos el texto sellado se pinta UNA '
            'vez (su fila histórica); el host vivo pasa a "sigue trabajando"',
      );

      // El segundo segmento continúa en la burbuja viva sin borrar el primero.
      gateway.emit('message.delta', const {'text': 'SEGUNDO-SEGMENTO listo.'});
      for (
        var frame = 0;
        frame < 100 && !chat.assistantContent.contains('SEGUNDO-SEGMENTO');
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      for (
        var frame = 0;
        frame < 100 &&
            find.textContaining('SEGUNDO-SEGMENTO listo.').evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(find.textContaining('PRIMER-SEGMENTO'), findsOneWidget);
      expect(find.textContaining('SEGUNDO-SEGMENTO'), findsOneWidget);

      gateway.emit('message.complete', const {
        'text': 'SEGUNDO-SEGMENTO listo.',
      });
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(find.textContaining('PRIMER-SEGMENTO'), findsOneWidget);
      expect(find.textContaining('SEGUNDO-SEGMENTO'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('las ráfagas con pausas se revelan sin cortar ni repetir texto', (
    tester,
  ) async {
    final gateway = _UiRewindGateway();
    final chat = await pumpChat(
      tester,
      connection: _remoteConn('conn-bursty-reveal'),
      desktopGateway: gateway,
    );
    await chat.send(
      fullText: 'modelo local lento a ráfagas',
      model: 'hermes-agent',
      history: const [],
    );
    gateway.emit('message.start');

    Future<void> drainReveal(String sentinel) async {
      for (
        var frame = 0;
        frame < 100 && find.textContaining(sentinel).evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 33));
      }
    }

    // Primera ráfaga: el final aún no visible mientras se revela.
    gateway.emit('message.delta', {
      'text': '${List.filled(30, 'primera ráfaga').join(' ')} RAFAGA-1-FIN',
    });
    for (
      var frame = 0;
      frame < 100 && !chat.assistantContent.contains('RAFAGA-1-FIN');
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(
      chat.assistantContent,
      contains('RAFAGA-1-FIN'),
      reason: 'el transcript recibe la ráfaga completa aunque aún no se vea',
    );
    await drainReveal('RAFAGA-1-FIN');
    expect(find.textContaining('RAFAGA-1-FIN'), findsOneWidget);

    // Pausa larga del modelo local: el texto revelado no se mueve ni corta.
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(find.textContaining('RAFAGA-1-FIN'), findsOneWidget);

    // Segunda ráfaga tras la pausa: continúa en la misma burbuja.
    gateway.emit('message.delta', {
      'text': ' ${List.filled(30, 'segunda ráfaga').join(' ')} RAFAGA-2-FIN',
    });
    for (
      var frame = 0;
      frame < 100 && !chat.assistantContent.contains('RAFAGA-2-FIN');
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    await drainReveal('RAFAGA-2-FIN');
    expect(find.textContaining('RAFAGA-1-FIN'), findsOneWidget);
    expect(find.textContaining('RAFAGA-2-FIN'), findsOneWidget);

    gateway.emit('message.complete', {'text': chat.assistantContent});
    for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(find.textContaining('RAFAGA-1-FIN'), findsOneWidget);
    expect(find.textContaining('RAFAGA-2-FIN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('arrastre corto durante streaming conserva la posición elegida', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    final gateway = _UiRewindGateway();
    final chat = await pumpChat(
      tester,
      connection: _remoteConn('conn-stream-manual-scroll'),
      desktopGateway: gateway,
      messages: List.generate(12, (index) {
        return {
          'role': index.isEven ? 'assistant' : 'user',
          'content':
              'Mensaje histórico $index. '
              '${List.filled(20, 'Contenido estable.').join(' ')}',
        };
      }),
    );

    await chat.send(
      fullText: 'genera una respuesta larga',
      model: 'hermes-agent',
      history: const [],
    );
    gateway.emit('message.start');
    gateway.emit('message.delta', {
      'text': List.filled(40, 'Fragmento inicial.').join(' '),
    });
    for (var frame = 0; frame < 100 && chat.assistantContent.isEmpty; frame++) {
      await tester.pump(const Duration(milliseconds: 33));
    }

    final listFinder = find.descendant(
      of: find.byType(ChatScrollInteractionGuard),
      matching: find.byType(ListView),
    );
    expect(listFinder, findsOneWidget);
    final controller = tester.widget<ListView>(listFinder).controller!;
    expect(controller.position.pixels, closeTo(0, 0.5));
    expect(chat.isStreaming, isTrue);

    final gesture = await tester.startGesture(tester.getCenter(listFinder));
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();

    final initialReaderOffset = controller.position.pixels;
    final liveAssistant = find.byKey(chatLiveAssistantViewportKey);
    expect(liveAssistant, findsOneWidget);
    expect(
      find.ancestor(of: liveAssistant, matching: find.byType(MotionEntrance)),
      findsNothing,
      reason:
          'el asistente vivo no debe desplazarse con una animación de entrada '
          'mientras el usuario intenta fijar el viewport',
    );
    final shortDragAnchorY = tester.getTopLeft(liveAssistant).dy;
    expect(initialReaderOffset, greaterThan(0));
    expect(
      initialReaderOffset,
      lessThanOrEqualTo(100),
      reason: 'cubre el margen que antes reactivaba el auto-follow',
    );

    Future<void> emitGrowingDelta(int delta) async {
      gateway.emit('message.delta', {
        'text':
            '\n\nBloque nuevo $delta. '
            '${List.filled(24, 'Texto que aumenta la respuesta.').join(' ')}',
      });
      for (
        var frame = 0;
        frame < 20 && !chat.assistantContent.contains('Bloque nuevo $delta.');
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      await tester.pump();
    }

    // Los primeros reflows llegan con el dedo todavía apoyado. La corrección
    // ocurre dentro del layout y no cancela ni bloquea la actividad de drag.
    for (var delta = 0; delta < 3; delta++) {
      await emitGrowingDelta(delta);
    }
    expect(
      tester.getTopLeft(liveAssistant).dy,
      closeTo(shortDragAnchorY, 1),
      reason: 'el contenido no se mueve bajo un dedo que se mantiene quieto',
    );

    // Continúa el mismo gesto bastante más arriba y vuelve a dejar el dedo
    // quieto mientras siguen entrando tokens: reproduce el arrastre largo real.
    await gesture.moveBy(const Offset(0, 180));
    await tester.pump();
    final longDragAnchorY = tester.getTopLeft(liveAssistant).dy;
    for (var delta = 3; delta < 6; delta++) {
      await emitGrowingDelta(delta);
    }

    expect(
      tester.getTopLeft(liveAssistant).dy,
      closeTo(longDragAnchorY, 1),
      reason:
          'varios reflows deben conservar el mismo contenido bajo el lector',
    );
    await gesture.up();
    await tester.pump();
    final readerAnchorY = tester.getTopLeft(liveAssistant).dy;

    gateway.emit('message.complete', {'text': chat.assistantContent});
    for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(chat.isStreaming, isFalse);
    expect(
      liveAssistant,
      findsOneWidget,
      reason:
          'el cierre mantiene el host estable hasta que el lector vuelva abajo',
    );
    expect(
      tester.getTopLeft(liveAssistant).dy,
      closeTo(readerAnchorY, 1),
      reason: 'el cierre del turno tampoco mueve el contenido bajo el lector',
    );

    // Si el lector vuelve manualmente al final, libera el host estable y monta
    // la proyección terminal completa (acciones, chunks y sugerencias).
    controller.jumpTo(controller.position.minScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(liveAssistant, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'lectura a mitad durante streaming: los tokens nuevos no tiran del scroll',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      final gateway = _UiRewindGateway();
      final chat = await pumpChat(
        tester,
        connection: _remoteConn('conn-stream-reader-hold'),
        desktopGateway: gateway,
        messages: scrollableChatHistory('lectura quieta'),
      );
      await chat.send(
        fullText: 'genera una respuesta larga',
        model: 'hermes-agent',
        history: const [],
      );
      gateway.emit('message.start');
      await pumpDesktopDelta(
        tester,
        gateway,
        chat,
        List.filled(10, 'Fragmento inicial del stream.').join(' '),
        expectedFragment: 'Fragmento inicial del stream.',
      );

      // El lector sube y SUELTA el dedo: el seguimiento queda congelado y la
      // vista no puede volver a moverse sola mientras llegan tokens.
      final controller = await dragChatAwayFromBottom(tester, distance: 320);
      final marker = find.textContaining('lectura quieta histórico').first;
      expect(marker, findsOneWidget);
      final markerY = tester.getTopLeft(marker).dy;
      final readerPixels = controller.position.pixels;

      for (var delta = 0; delta < 6; delta++) {
        gateway.emit('message.delta', {
          'text':
              '\n\nBloque posterior $delta. '
              '${List.filled(24, 'Texto que aumenta la respuesta.').join(' ')}',
        });
        for (
          var frame = 0;
          frame < 20 &&
              !chat.assistantContent.contains('Bloque posterior $delta.');
          frame++
        ) {
          await tester.pump(const Duration(milliseconds: 33));
        }
        await tester.pump();
        expect(
          controller.position.pixels,
          greaterThanOrEqualTo(readerPixels - 0.5),
          reason:
              'delta $delta: reverse:true → píxeles menores acercan al fondo; '
              'el viewport no puede tirar hacia abajo con el lector quieto',
        );
      }
      expect(
        tester.getTopLeft(marker).dy,
        closeTo(markerY, 1.5),
        reason: 'el texto que el usuario lee no se mueve al llegar más tokens',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'un turno que empieza con el lector arriba no reengancha el seguimiento',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      final gateway = _UiRewindGateway();
      final chat = await pumpChat(
        tester,
        connection: _remoteConn('conn-stream-remote-turn-reader'),
        desktopGateway: gateway,
        messages: scrollableChatHistory('turno remoto'),
      );

      // El lector sube ANTES de que empiece el turno (un run de cron o de un
      // bot de la Room aterriza en la sesión abierta): el seguimiento no
      // puede heredar el "sigue el fondo" del turno anterior.
      final list = chatListFinder();
      final controller = tester.widget<ListView>(list).controller!;
      controller.jumpTo(320);
      await tester.pump();
      expect(controller.position.pixels, greaterThan(0));
      // Ancla en un mensaje histórico ÚNICO y cómodamente visible: la
      // virtualización puede cambiar qué elemento monta `.first`, y uno en el
      // borde del viewport sale del árbol con una deriva mínima.
      final candidates = find
          .textContaining('turno remoto histórico')
          .evaluate();
      Element? markerElement;
      for (final element in candidates) {
        final dy = tester.getTopLeft(find.byWidget(element.widget)).dy;
        if (dy > 120 && dy < 380) {
          markerElement = element;
          break;
        }
      }
      expect(markerElement, isNotNull);
      final markerWidget = markerElement!.widget;
      final markerText = markerWidget is Text
          ? (markerWidget.data ?? markerWidget.textSpan!.toPlainText())
          : (markerWidget as RichText).text.toPlainText();
      final marker = find.textContaining(markerText);
      final markerY = tester.getTopLeft(marker).dy;
      final readerPixels = controller.position.pixels;

      await chat.send(
        fullText: 'turno con el lector arriba',
        model: 'hermes-agent',
        history: const [],
      );
      gateway.emit('message.start');
      for (var delta = 0; delta < 6; delta++) {
        gateway.emit('message.delta', {
          'text':
              'Bloque del turno $delta. '
              '${List.filled(24, 'Texto que aumenta la respuesta.').join(' ')}'
              '\n\n',
        });
        for (
          var frame = 0;
          frame < 20 &&
              !chat.assistantContent.contains('Bloque del turno $delta.');
          frame++
        ) {
          await tester.pump(const Duration(milliseconds: 33));
        }
        await tester.pump();
        expect(
          controller.position.pixels,
          greaterThanOrEqualTo(readerPixels - 0.5),
          reason:
              'delta $delta: el turno nuevo no puede tirar del viewport hacia '
              'el fondo con el lector arriba',
        );
      }
      expect(
        tester.getTopLeft(marker).dy,
        closeTo(markerY, 1.5),
        reason: 'la burbuja viva crece por debajo sin desplazar el texto leído',
      );
      // La flecha "ir al final" refleja que el lector está lejos del fondo.
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'la respuesta final se pinta aunque el usuario pausara el seguimiento',
    (tester) async {
      final gateway = _SubmissionGateway();
      final chat = await pumpChat(
        tester,
        connection: _remoteConn('conn-final-after-scroll'),
        desktopGateway: gateway,
      );

      await chat.send(
        fullText: 'trabaja con muchas herramientas',
        model: 'hermes-agent',
        history: const [],
      );
      await tester.pump();

      // Tocar/desplazar el historial mientras el agente trabaja desactiva el
      // seguimiento automático. Si el turno termina sin deltas y entrega todo
      // el texto en message.complete, el contador visual sigue todavía en cero.
      await tester.tap(find.byType(ChatScrollInteractionGuard));
      await tester.pump();

      gateway.emitComplete('Respuesta final después de 34 pasos');
      for (
        var i = 0;
        i < 110 && chat.state != ChatPipelineState.completed;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(chat.assistantContent, 'Respuesta final después de 34 pasos');
      expect(
        find.textContaining('Respuesta final después de 34 pasos'),
        findsOneWidget,
        reason: 'un mensaje completado nunca debe quedar congelado e invisible',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'el asistente aparece estable sin animación mientras crece el texto',
    (tester) async {
      final gateway = _SubmissionGateway();
      final chat = await pumpChat(
        tester,
        connection: _remoteConn('conn-stable-stream-entrance'),
        desktopGateway: gateway,
      );
      chat.smoothStreaming = true;

      await chat.send(
        fullText: 'Genera una respuesta larga y fluida',
        model: 'hermes-agent',
        history: const [],
      );
      await tester.pump();

      final finalText = List<String>.generate(
        48,
        (index) => 'Fragmento visible ${index + 1}.',
      ).join(' ');
      gateway.emitComplete(finalText);

      // El cierre sin deltas se publica como un único batch en la siguiente
      // cadencia de 33 ms. Espera a que aparezca la respuesta real que
      // sustituye al placeholder del pipeline.
      for (
        var frame = 0;
        frame < 10 && find.textContaining(finalText).evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(chat.assistantContent, finalText);
      expect(find.textContaining(finalText), findsOneWidget);
      expect(
        find.byType(MotionEntrance),
        findsNothing,
        reason:
            'el turno vivo ya aporta movimiento mediante el streaming; un '
            'translate adicional desplaza el viewport del lector',
      );

      // Los frames posteriores no pueden introducir tarde un wrapper de
      // entrada, volver transparente la respuesta ni desplazarla al cerrar.
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump(const Duration(milliseconds: 40));
        expect(find.byType(MotionEntrance), findsNothing);
        expect(find.textContaining(finalText), findsOneWidget);
      }

      for (var frame = 0; frame < 240 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(chat.assistantContent, finalText);
      expect(chat.isStreaming, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'edge viewport: reabrir antes del primer delta no duplica el histórico',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      final gateway = _UiRewindGateway()
        ..resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'missing prior Room session',
          code: 4007,
        );
      final connection = _remoteConn('conn-reopen-before-first-delta');
      final session = _session();
      final chat = await pumpChat(
        tester,
        connection: connection,
        session: session,
        desktopGateway: gateway,
        messages: const [
          {
            'role': 'assistant',
            'content': 'Respuesta histórica única antes del delta',
          },
          {'role': 'user', 'content': 'Pregunta histórica única'},
        ],
      );

      await chat.send(
        fullText: 'Petición nueva todavía sin delta',
        model: 'hermes-agent',
        history: const [],
      );
      gateway.emit('message.start');
      await tester.pump();
      expect(chat.isStreaming, isTrue);
      expect(find.byKey(chatLiveAssistantViewportKey), findsNothing);

      final navigator = Navigator.of(tester.element(find.byType(ChatScreen)));
      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(ChatScreen), findsNothing);

      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => ChatScreen(connection: connection, session: session),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byKey(chatLiveAssistantViewportKey), findsNothing);
      expect(
        find.textContaining('Respuesta histórica única antes del delta'),
        findsOneWidget,
      );

      await pumpDesktopDelta(
        tester,
        gateway,
        chat,
        'Primer delta visible tras reabrir.',
        expectedFragment: 'Primer delta visible',
      );
      expect(find.byKey(chatLiveAssistantViewportKey), findsOneWidget);
      expect(
        find.textContaining('Respuesta histórica única antes del delta'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      gateway.emit('message.complete');
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
    },
  );

  testWidgets(
    'edge viewport: complete vacío retiene host terminal y lo libera al fondo',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      final gateway = _UiRewindGateway();
      final chat = await pumpChat(
        tester,
        connection: _remoteConn('conn-empty-complete-retained-host'),
        desktopGateway: gateway,
        messages: scrollableChatHistory('complete vacío'),
      );
      await chat.send(
        fullText: 'Genera el cierre vacío',
        model: 'hermes-agent',
        history: const [],
      );
      gateway.emit('message.start');
      await pumpDesktopDelta(
        tester,
        gateway,
        chat,
        'Cierre vacío conserva este parcial. '
        '${List.filled(45, 'Texto vivo estable.').join(' ')}',
        expectedFragment: 'Cierre vacío conserva este parcial',
      );

      final streamedMessage = chat.messages.first;
      final controller = await dragChatAwayFromBottom(tester);
      final liveAssistant = find.byKey(chatLiveAssistantViewportKey);
      expect(liveAssistant, findsOneWidget);
      expect(
        find.descendant(
          of: liveAssistant,
          matching: find.byType(SelectionArea),
        ),
        findsNothing,
      );
      expect(
        find.ancestor(of: liveAssistant, matching: find.byType(MotionEntrance)),
        findsNothing,
      );
      final readerAnchorY = tester.getTopLeft(liveAssistant).dy;

      gateway.emit('message.complete');
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }

      expect(chat.isStreaming, isFalse);
      expect(identical(chat.messages.first, streamedMessage), isTrue);
      expect(liveAssistant, findsOneWidget);
      expect(tester.getTopLeft(liveAssistant).dy, closeTo(readerAnchorY, 1));
      expect(
        find.descendant(
          of: liveAssistant,
          matching: find.byType(SelectionArea),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(of: liveAssistant, matching: find.byType(MotionEntrance)),
        findsNothing,
      );

      controller.jumpTo(controller.position.minScrollExtent);
      await tester.pump();
      await tester.pump();
      expect(liveAssistant, findsNothing);
      final terminalText = find
          .textContaining('Cierre vacío conserva este parcial')
          .first;
      expect(
        find.ancestor(of: terminalText, matching: find.byType(SelectionArea)),
        findsOneWidget,
      );
      expect(
        find.ancestor(of: terminalText, matching: find.byType(MotionEntrance)),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'edge viewport: cancelar sin parcial deja la petición cero sin entrada',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      final gateway = _UiRewindGateway();
      final chat = await pumpChat(
        tester,
        connection: _remoteConn('conn-cancel-without-partial'),
        desktopGateway: gateway,
      );
      await chat.send(
        fullText: 'Petición cancelada antes de responder',
        model: 'hermes-agent',
        history: const [],
      );
      gateway.emit('message.start');
      await tester.pump();
      expect(chat.messages.first['_pipeline'], isTrue);

      chat.cancel();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 33));

      expect(chat.state, ChatPipelineState.cancelled);
      expect(chat.messages.first['role'], 'user');
      expect(
        chat.messages.first['content'],
        'Petición cancelada antes de responder',
      );
      final request = find.textContaining(
        'Petición cancelada antes de responder',
      );
      expect(request, findsOneWidget);
      expect(
        find.ancestor(of: request, matching: find.byType(MotionEntrance)),
        findsNothing,
      );
      expect(find.byKey(chatLiveAssistantViewportKey), findsNothing);
      expect(find.text('cancelled'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'edge viewport: cancelar con parcial retiene host seleccionable',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      final gateway = _UiRewindGateway();
      final chat = await pumpChat(
        tester,
        connection: _remoteConn('conn-cancel-partial-retained-host'),
        desktopGateway: gateway,
        messages: scrollableChatHistory('cancel parcial'),
      );
      await chat.send(
        fullText: 'Cancela después del parcial',
        model: 'hermes-agent',
        history: const [],
      );
      gateway.emit('message.start');
      await pumpDesktopDelta(
        tester,
        gateway,
        chat,
        'Parcial cancelable conservado. '
        '${List.filled(42, 'Contenido parcial.').join(' ')}',
        expectedFragment: 'Parcial cancelable conservado',
      );
      await dragChatAwayFromBottom(tester);

      chat.cancel();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 33));

      final liveAssistant = find.byKey(chatLiveAssistantViewportKey);
      expect(chat.state, ChatPipelineState.cancelled);
      expect(chat.messages.first['_cancelled'], isTrue);
      expect(liveAssistant, findsOneWidget);
      expect(find.text('cancelled'), findsOneWidget);
      expect(
        find.descendant(
          of: liveAssistant,
          matching: find.byType(SelectionArea),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(of: liveAssistant, matching: find.byType(MotionEntrance)),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('edge viewport: error parcial aislado conserva host y ancla', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    final gateway = _UiRewindGateway();
    final chat = await pumpChat(
      tester,
      connection: _remoteConn('conn-partial-error-metrics-delta'),
      desktopGateway: gateway,
      messages: [
        {
          'role': 'assistant',
          'content':
              '```text\n'
              '${List.generate(20, (index) => 'Histórico estable $index').join('\n')}\n'
              '```',
        },
        {'role': 'user', 'content': 'Pregunta histórica geométrica'},
      ],
    );
    await chat.send(
      fullText: 'Falla después del parcial',
      model: 'hermes-agent',
      history: const [],
    );
    gateway.emit('message.start');
    await pumpDesktopDelta(
      tester,
      gateway,
      chat,
      '```text\n'
      'Parcial para error anclado\n'
      '${List.generate(38, (index) => 'Línea estable $index').join('\n')}\n'
      '```',
      expectedFragment: 'Parcial para error anclado',
    );
    final controller = await dragChatAwayFromBottom(tester, distance: 100);
    final liveAssistant = find.byKey(chatLiveAssistantViewportKey);
    final liveAnchor = find
        .ancestor(of: liveAssistant, matching: find.byType(ChatAnswerAnchor))
        .first;
    final anchorY = tester.getTopLeft(liveAnchor).dy;
    final oldPixels = controller.position.pixels;
    final oldMax = controller.position.maxScrollExtent;

    gateway.emit('error', {'message': 'Fallo parcial único'});
    for (
      var frame = 0;
      frame < 20 && chat.state != ChatPipelineState.failed;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    await tester.pump();

    expect(chat.state, ChatPipelineState.failed);
    expect(liveAssistant, findsOneWidget);
    final metricsDelta = controller.position.maxScrollExtent - oldMax;
    expect(metricsDelta.abs(), greaterThan(1));

    final error = find.textContaining('Fallo parcial único').first;
    expect(
      find.descendant(of: liveAssistant, matching: error),
      findsOneWidget,
      reason: 'el error y el parcial comparten el reporter retenido',
    );
    expect(
      find.ancestor(of: error, matching: find.byType(MotionEntrance)),
      findsNothing,
    );
    final partial = find.textContaining('Parcial para error anclado').first;
    final terminalAnchor = find
        .ancestor(of: partial, matching: find.byType(ChatAnswerAnchor))
        .first;
    final terminalAnchorY = tester.getTopLeft(terminalAnchor).dy;
    expect(
      terminalAnchorY,
      closeTo(anchorY, 1.5),
      reason:
          'el cambio live→error terminal debe conservar el ancla aislada; '
          'oldY=$anchorY newY=$terminalAnchorY metricsDelta=$metricsDelta',
    );
    expect(
      controller.position.pixels - oldPixels,
      closeTo(metricsDelta, 1.5),
      reason:
          'sin virtualización la estimación debe coincidir con la altura real '
          'reportada por la entrada compuesta; '
          'oldPixels=$oldPixels newPixels=${controller.position.pixels} '
          'metricsDelta=$metricsDelta',
    );
    expect(
      find.ancestor(of: partial, matching: find.byType(SelectionArea)),
      findsOneWidget,
    );
    controller.jumpTo(controller.position.minScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(liveAssistant, findsNothing);
    expect(error, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'edge viewport: error parcial virtualizado conserva el contenido leído',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      final gateway = _UiRewindGateway();
      final chat = await pumpChat(
        tester,
        connection: _remoteConn('conn-partial-error-virtualized'),
        desktopGateway: gateway,
        messages: scrollableChatHistory('error virtualizado'),
      );
      await chat.send(
        fullText: 'Falla con historial virtualizado',
        model: 'hermes-agent',
        history: const [],
      );
      gateway.emit('message.start');
      await pumpDesktopDelta(
        tester,
        gateway,
        chat,
        'Parcial virtualizado anclado. '
        '${List.filled(44, 'Bloque estable durante la lectura.').join(' ')}',
        expectedFragment: 'Parcial virtualizado anclado',
      );
      final controller = await dragChatAwayFromBottom(tester, distance: 240);
      final liveAssistant = find.byKey(chatLiveAssistantViewportKey);
      final liveAnchor = find
          .ancestor(of: liveAssistant, matching: find.byType(ChatAnswerAnchor))
          .first;
      final anchorY = tester.getTopLeft(liveAnchor).dy;
      final oldPixels = controller.position.pixels;
      final oldMax = controller.position.maxScrollExtent;

      gateway.emit('error', {'message': 'Fallo virtualizado único'});
      for (
        var frame = 0;
        frame < 20 && chat.state != ChatPipelineState.failed;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      await tester.pump();

      expect(chat.state, ChatPipelineState.failed);
      expect(liveAssistant, findsOneWidget);
      final metricsDelta = controller.position.maxScrollExtent - oldMax;
      expect(metricsDelta.abs(), greaterThan(1));

      final error = find.textContaining('Fallo virtualizado único').first;
      expect(
        find.descendant(of: liveAssistant, matching: error),
        findsOneWidget,
        reason: 'la tarjeta nueva no crea un segundo slot lazy mientras lee',
      );
      expect(
        find.ancestor(of: error, matching: find.byType(MotionEntrance)),
        findsNothing,
      );
      final partial = find.textContaining('Parcial virtualizado anclado').first;
      final terminalAnchor = find
          .ancestor(of: partial, matching: find.byType(ChatAnswerAnchor))
          .first;
      final terminalAnchorY = tester.getTopLeft(terminalAnchor).dy;
      expect(
        terminalAnchorY,
        closeTo(anchorY, 1.5),
        reason:
            'el historial virtualizado no puede mover el contenido leído; '
            'oldY=$anchorY newY=$terminalAnchorY metricsDelta=$metricsDelta',
      );
      expect(
        (controller.position.pixels - oldPixels - metricsDelta).abs(),
        greaterThan(64),
        reason:
            'el historial virtualizado exige el delta real del reporter, no la '
            'estimación de maxScrollExtent; '
            'oldPixels=$oldPixels newPixels=${controller.position.pixels} '
            'metricsDelta=$metricsDelta',
      );
      expect(
        find.ancestor(of: partial, matching: find.byType(SelectionArea)),
        findsOneWidget,
      );
      controller.jumpTo(controller.position.minScrollExtent);
      await tester.pump();
      await tester.pump();
      expect(liveAssistant, findsNothing);
      expect(error, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'edge viewport: el gesto sigue activo cuando termina con error parcial',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      final gateway = _UiRewindGateway();
      final chat = await pumpChat(
        tester,
        connection: _remoteConn('conn-partial-error-active-gesture'),
        desktopGateway: gateway,
        messages: scrollableChatHistory('error con dedo'),
      );
      await chat.send(
        fullText: 'Falla mientras sigo arrastrando',
        model: 'hermes-agent',
        history: const [],
      );
      gateway.emit('message.start');
      await pumpDesktopDelta(
        tester,
        gateway,
        chat,
        'Parcial bajo el dedo. '
        '${List.filled(44, 'Contenido estable durante el gesto.').join(' ')}',
        expectedFragment: 'Parcial bajo el dedo',
      );

      final listFinder = find.descendant(
        of: find.byType(ChatScrollInteractionGuard),
        matching: find.byType(ListView),
      );
      final controller = tester.widget<ListView>(listFinder).controller!;
      final gesture = await tester.startGesture(tester.getCenter(listFinder));
      await gesture.moveBy(const Offset(0, 180));
      await tester.pump();

      final liveAssistant = find.byKey(chatLiveAssistantViewportKey);
      final liveAnchor = find
          .ancestor(of: liveAssistant, matching: find.byType(ChatAnswerAnchor))
          .first;
      final anchorY = tester.getTopLeft(liveAnchor).dy;

      gateway.emit('error', {'message': 'Fallo con gesto activo'});
      for (
        var frame = 0;
        frame < 20 && chat.state != ChatPipelineState.failed;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 33));
      }

      expect(chat.state, ChatPipelineState.failed);
      expect(liveAssistant, findsOneWidget);
      expect(tester.getTopLeft(liveAnchor).dy, closeTo(anchorY, 1.5));
      final pixelsBeforeContinuing = controller.position.pixels;
      await gesture.moveBy(const Offset(0, 90));
      await tester.pump();
      expect(
        controller.position.pixels,
        greaterThan(pixelsBeforeContinuing),
        reason: 'el terminal no puede cancelar la actividad del mismo dedo',
      );
      await gesture.up();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'edge viewport: un turno en cola no secuestra la lectura tras el error',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      final gateway = _UiRewindGateway();
      final chat = await pumpChat(
        tester,
        connection: _remoteConn('conn-error-queued-reader-anchor'),
        desktopGateway: gateway,
        messages: scrollableChatHistory('cola tras error'),
      );
      await chat.send(
        fullText: 'Primer turno que fallará',
        model: 'hermes-agent',
        history: const [],
      );
      gateway.emit('message.start');
      await pumpDesktopDelta(
        tester,
        gateway,
        chat,
        'Parcial antes del turno en cola. '
        '${List.filled(42, 'Contenido que sigo leyendo.').join(' ')}',
        expectedFragment: 'Parcial antes del turno en cola',
      );
      chat.enqueue('Segundo turno ya en cola');
      await tester.pump();
      await dragChatAwayFromBottom(tester, distance: 240);

      gateway.emit('error', {'message': 'Fallo antes de drenar la cola'});
      for (
        var frame = 0;
        frame < 20 && chat.state != ChatPipelineState.failed;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      final partial = find.textContaining('Parcial antes del turno en cola');
      final retainedAnchor = find
          .ancestor(of: partial, matching: find.byType(ChatAnswerAnchor))
          .first;
      final anchorY = tester.getTopLeft(retainedAnchor).dy;

      await tester.pump(const Duration(milliseconds: 850));
      await tester.pump();
      expect(chat.isStreaming, isTrue);
      expect(partial, findsOneWidget);
      final queuedAnchor = find
          .ancestor(of: partial, matching: find.byType(ChatAnswerAnchor))
          .first;
      expect(
        tester.getTopLeft(queuedAnchor).dy,
        closeTo(anchorY, 1.5),
        reason: 'el siguiente turno puede generar sin mover lo que se leía',
      );
      expect(tester.takeException(), isNull);

      chat.cancel();
      await tester.pump();
    },
  );

  testWidgets(
    'edge viewport: una cola alta no virtualiza el contenido leído tras error',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      final gateway = _UiRewindGateway();
      final chat = await pumpChat(
        tester,
        connection: _remoteConn('conn-error-tall-queued-reader-anchor'),
        desktopGateway: gateway,
        messages: scrollableChatHistory('cola alta tras error'),
      );
      await chat.send(
        fullText: 'Primer turno que fallará antes de la cola alta',
        model: 'hermes-agent',
        history: const [],
      );
      gateway.emit('message.start');
      await pumpDesktopDelta(
        tester,
        gateway,
        chat,
        'Parcial visible antes de la cola alta. '
        '${List.filled(42, 'Contenido retenido para lectura.').join(' ')}',
        expectedFragment: 'Parcial visible antes de la cola alta',
      );
      chat.enqueue(
        List.filled(
          20,
          'Segundo turno deliberadamente alto para probar virtualización.',
        ).join(' '),
      );
      await tester.pump();
      final controller = await dragChatAwayFromBottom(tester, distance: 240);

      gateway.emit('error', {'message': 'Fallo antes de drenar cola alta'});
      for (
        var frame = 0;
        frame < 20 && chat.state != ChatPipelineState.failed;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(chat.state, ChatPipelineState.failed);

      final partial = find.textContaining(
        'Parcial visible antes de la cola alta',
      );
      expect(partial, findsOneWidget);
      final retainedAnchor = find
          .ancestor(of: partial, matching: find.byType(ChatAnswerAnchor))
          .first;
      final anchorY = tester.getTopLeft(retainedAnchor).dy;
      final snapshots = <String>[];

      void expectReaderAnchor(String label) {
        final partialCount = partial.evaluate().length;
        final currentY = partialCount == 1
            ? tester
                  .getTopLeft(
                    find
                        .ancestor(
                          of: partial,
                          matching: find.byType(ChatAnswerAnchor),
                        )
                        .first,
                  )
                  .dy
            : null;
        snapshots.add(
          '$label streaming=${chat.isStreaming} '
          'pixels=${controller.position.pixels} '
          'max=${controller.position.maxScrollExtent} y=$currentY',
        );
        expect(partialCount, 1, reason: snapshots.join('\n'));
        expect(currentY, closeTo(anchorY, 1.5), reason: snapshots.join('\n'));
      }

      for (var frame = 0; frame < 60 && !chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expectReaderAnchor('espera-$frame');
      }
      expect(chat.isStreaming, isTrue, reason: snapshots.join('\n'));
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expectReaderAnchor('stream-$frame');
      }
      expect(tester.takeException(), isNull);

      chat.cancel();
      await tester.pump();
    },
  );

  testWidgets('edge viewport: historia fría conserva MotionEntrance', (
    tester,
  ) async {
    final gateway = _ColdHistoryGateway();
    final chat = await pumpChat(
      tester,
      connection: _remoteConn('conn-cold-history-entrance'),
      session: _session().copyWith(messageCount: 2),
      desktopGateway: gateway,
      messagesLoaded: false,
    );

    for (
      var frame = 0;
      frame < 30 &&
          find
              .textContaining('Respuesta histórica cargada en frío')
              .evaluate()
              .isEmpty;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(chat.messagesLoaded, isTrue);
    final historical = find.textContaining(
      'Respuesta histórica cargada en frío',
    );
    expect(historical, findsOneWidget);
    expect(
      find.ancestor(of: historical, matching: find.byType(MotionEntrance)),
      findsOneWidget,
    );
    expect(find.byKey(chatLiveAssistantViewportKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el lápiz solo aparece en la petición que sigue trabajando', (
    tester,
  ) async {
    await pumpChat(
      tester,
      chatState: ChatPipelineState.executing,
      messages: [
        {'role': 'assistant', 'content': '', '_pipeline': true},
        {'role': 'user', 'content': 'pregunta todavía activa'},
      ],
    );

    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fallback sin gateway deja el texto en cola sin cortar el turno', (
    tester,
  ) async {
    final chat = await pumpChat(
      tester,
      chatState: ChatPipelineState.executing,
      messages: const [
        {
          'role': 'assistant',
          'content': 'Respuesta todavía creciendo',
          '_pipeline': true,
        },
        {'role': 'user', 'content': 'Primera petición'},
      ],
    );

    await tester.enterText(find.byType(TextField), 'Siguiente pregunta');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();

    expect(chat.state, ChatPipelineState.executing);
    expect(chat.queuedMessages, ['Siguiente pregunta']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
    expect(
      find.text(
        'Mensaje en cola: se enviará como siguiente turno cuando Hermes termine.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('chat-queue-toggle')), findsOneWidget);
    expect(find.text('Siguiente pregunta'), findsNothing);
    expect(find.byTooltip('Quitar mensaje de la cola'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('chat-queue-toggle')));
    await tester.pump();

    expect(find.text('Siguiente pregunta'), findsOneWidget);
    final removeQueued = find.byTooltip('Quitar mensaje de la cola');
    expect(removeQueued, findsOneWidget);
    expect(tester.getSize(removeQueued), const Size(48, 48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('steering espera el ACK y después se une al turno vivo', (
    tester,
  ) async {
    final submitGate = Completer<void>();
    final gateway = _UiRewindGateway()..submitGate = submitGate;
    final chat = await pumpChat(
      tester,
      desktopGateway: gateway,
      connection: _remoteConn('conn-live-steer'),
      messagesLoaded: false,
    );

    await tester.enterText(find.byType(TextField), 'Primera petición');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(gateway.submissions, ['Primera petición']);

    await tester.enterText(find.byType(TextField), 'y añade ejemplos');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump(const Duration(milliseconds: 100));

    // Mientras prompt.submit no ha confirmado el primer turno, la misma
    // superficie no puede convertir otro tap en un redirect ambiguo.
    expect(gateway.steers, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'y añade ejemplos',
    );

    submitGate.complete();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(gateway.steers, ['y añade ejemplos']);
    expect(chat.queuedMessages, isEmpty);
    expect(
      chat.messages.any(
        (message) =>
            message['role'] == 'user' &&
            message['content'] == 'y añade ejemplos' &&
            message['_steer'] == true,
      ),
      isTrue,
    );
    expect(find.text('Añadido mientras Hermes trabajaba'), findsWidgets);

    gateway.emit('message.complete', {'text': 'hecho'});
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pulsar una oferta final larga la envia como sugerencia', (
    tester,
  ) async {
    final gateway = _UiRewindGateway();
    await pumpChat(
      tester,
      desktopGateway: gateway,
      connection: _remoteConn('conn-direct-suggestion'),
      messages: const [
        {
          'role': 'assistant',
          'content':
              'Orden recomendado.\n\n---\n\n'
              'Si quieres, en el siguiente paso te preparo un **plan de '
              'recorte con números concretos por escenario** (conservador / '
              'medio / agresivo) y el set de comandos con valores exactos.',
        },
      ],
    );

    const action =
        'Prepara un plan de recorte con números concretos por escenario';
    expect(find.textContaining('Si quieres'), findsNothing);
    expect(find.text(action), findsOneWidget);
    await tester.tap(find.text(action));
    await tester.pump(const Duration(milliseconds: 120));

    expect(gateway.submissions, [action]);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
    gateway.emit('message.complete', {'text': 'Resumen'});
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.takeException(), isNull);
  });

  testWidgets('una respuesta histórica nunca ofrece steering sugerido', (
    tester,
  ) async {
    await pumpChat(
      tester,
      messages: const [
        {'role': 'assistant', 'content': 'Respuesta más reciente.'},
        {'role': 'user', 'content': 'Segunda pregunta'},
        {
          'role': 'assistant',
          'content':
              'Respuesta antigua.\n\n'
              'Si quieres, puedo:\n'
              '- resumirlo',
        },
        {'role': 'user', 'content': 'Primera pregunta'},
      ],
    );

    expect(
      find.byKey(const ValueKey('assistant-suggestions-rail')),
      findsNothing,
    );
  });

  testWidgets('un run activo y un draft ocultan las sugerencias', (
    tester,
  ) async {
    await pumpChat(
      tester,
      chatState: ChatPipelineState.executing,
      messages: const [
        {'role': 'assistant', 'content': '', '_pipeline': true},
        {'role': 'user', 'content': 'Petición activa'},
        {
          'role': 'assistant',
          'content':
              'Respuesta anterior.\n\n'
              'Si quieres, puedo:\n'
              '- resumirlo',
        },
      ],
    );

    expect(
      find.byKey(const ValueKey('assistant-suggestions-rail')),
      findsNothing,
    );
    await tester.enterText(find.byType(TextField), 'Mi siguiente borrador');
    await tester.pump();
    expect(
      find.byKey(const ValueKey('assistant-suggestions-rail')),
      findsNothing,
    );
  });

  testWidgets('el ACK de una sugerencia no borra un draft escrito después', (
    tester,
  ) async {
    final submitGate = Completer<void>();
    final gateway = _UiRewindGateway()..submitGate = submitGate;
    await pumpChat(
      tester,
      desktopGateway: gateway,
      connection: _remoteConn('conn-suggestion-draft'),
      messages: const [
        {
          'role': 'assistant',
          'content':
              'Resultado listo.\n\n'
              'Si quieres, puedo:\n'
              '- resumirlo',
        },
      ],
    );

    await tester.tap(find.text('resumirlo'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(gateway.submissions, ['resumirlo']);

    await tester.enterText(find.byType(TextField), 'Borrador nuevo intacto');
    await tester.pump();
    submitGate.complete();
    await tester.pump(const Duration(milliseconds: 120));

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'Borrador nuevo intacto',
    );
    gateway.emit('message.complete', {'text': 'Resumen'});
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'Borrador nuevo intacto',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'solo lectura conserva la huella del composer sin campo editable',
    (tester) async {
      await pumpChat(tester, connection: _conn().copyWith(readOnly: true));

      expect(
        find.text('Instancia en solo lectura — acción desactivada'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('editar y guardar durante streaming rebobina sin pantalla roja', (
    tester,
  ) async {
    final gateway = _UiRewindGateway();
    final chat = await pumpChat(
      tester,
      chatState: ChatPipelineState.executing,
      desktopGateway: gateway,
      connection: _remoteConn(),
      messages: [
        {
          'role': 'assistant',
          'content': 'El mayor emperador fue',
          '_pipeline': true,
        },
        {'role': 'user', 'content': '¿Quién fue el mayor emperador romano?'},
      ],
    );

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    final editor = find.byKey(const ValueKey('edit-message-composer'));
    expect(editor, findsOneWidget);
    await tester.enterText(editor, '¿Quién fue el mayor emperador griego?');
    await tester.tap(find.text('Guardar y enviar'));

    // El pop de la hoja y el rewind del transcript ocurren en la misma
    // transición. Avanzar varios frames reproduce la carrera del dispositivo.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));

    expect(editor, findsNothing);
    expect(
      find.textContaining('¿Quién fue el mayor emperador griego?'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    gateway.emit('message.complete', {'text': 'Respuesta griega de prueba'});
    for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(chat.isStreaming, isFalse);
  });

  testWidgets(
    'turno nuevo durante interrupt drain conserva ownership y aborta rewind',
    (tester) async {
      final gateway = _UiRewindGateway()..interruptGate = Completer<void>();
      final chat = await pumpChat(
        tester,
        chatState: ChatPipelineState.executing,
        desktopGateway: gateway,
        connection: _remoteConn('conn-interrupt-race-rewrite'),
        messages: [
          {
            'role': 'assistant',
            'content': 'Respuesta parcial original',
            '_pipeline': true,
          },
          {'role': 'user', 'content': 'pregunta original'},
        ],
      );

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(
        find.byKey(const ValueKey('edit-message-composer')),
        'pregunta corregida obsoleta',
      );
      await tester.tap(find.text('Guardar y enviar'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(gateway.interruptCalls, 1);
      expect(gateway.rewinds, isEmpty);

      final newTurn = chat.send(
        fullText: 'turno nuevo durante drain',
        model: 'test-model',
        history: const [],
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(await newTurn, isTrue);
      gateway.interruptGate!.complete();
      await tester.pump(const Duration(milliseconds: 700));

      expect(gateway.rewinds, isEmpty);
      expect(
        chat.messages.any(
          (message) => message['content'] == 'turno nuevo durante drain',
        ),
        isTrue,
      );
      expect(
        chat.messages.any(
          (message) => message['content'] == 'pregunta corregida obsoleta',
        ),
        isFalse,
      );
      gateway.emit('message.complete', {'text': 'Respuesta del turno nuevo'});
      for (var frame = 0; frame < 60 && chat.isStreaming; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(chat.isStreaming, isFalse);
    },
  );

  testWidgets('cancelar el editor conserva el turno original trabajando', (
    tester,
  ) async {
    final chat = await pumpChat(
      tester,
      chatState: ChatPipelineState.executing,
      messages: [
        {'role': 'assistant', 'content': '', '_pipeline': true},
        {'role': 'user', 'content': 'pregunta original'},
      ],
    );

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('edit-message-composer')), findsOneWidget);

    await tester.tap(find.text('Cancelar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(chat.state, ChatPipelineState.executing);
    expect(find.textContaining('pregunta original'), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'agrupa las indicaciones en vivo dentro de la petición original',
    (tester) async {
      await pumpChat(
        tester,
        messages: [
          {'role': 'assistant', 'content': 'Aquí tienes el resultado'},
          {'role': 'user', 'content': 'y añade ejemplos', '_steer': true},
          {'role': 'user', 'content': 'y documéntalo', '_steer': true},
          {'role': 'user', 'content': 'Implementa la función'},
        ],
      );

      expect(find.text('Implementa la función'), findsOneWidget);
      expect(find.text('Añadido mientras Hermes trabajaba'), findsOneWidget);
      expect(find.text('y documéntalo'), findsOneWidget);
      expect(find.text('y añade ejemplos'), findsOneWidget);
      expect(find.byIcon(Icons.add_comment_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('un mensaje renderiza varias imágenes adjuntas', (tester) async {
    await pumpChat(
      tester,
      messages: [
        {
          'role': 'user',
          'content':
              '[📎 una.jpg · 1 KB]\n'
              '[📎 dos.png · 2 KB]\n'
              'Revisa estas imágenes\n'
              '⟦adjunto⟧\nSECRETO\n'
              '⟦img:0:/ruta/inexistente/una.jpg⟧\n'
              '⟦img:1:/ruta/inexistente/dos.png⟧',
        },
      ],
    );

    expect(find.byType(AttachmentCard), findsNWidgets(2));
    expect(find.text('una.jpg'), findsOneWidget);
    expect(find.text('dos.png'), findsOneWidget);
    expect(find.text('Revisa estas imágenes'), findsOneWidget);
    expect(find.textContaining('SECRETO'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('un documento histórico abre los bytes de texto privados reales', (
    tester,
  ) async {
    late final Directory temp;
    late final AttachmentHistoryReference reference;
    const exactText = 'línea privada exacta\nsegunda línea: 1234';
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('chat-history-text-');
      final file = File('${temp.path}/notas.txt');
      await file.writeAsString(exactText);
      reference = (await AttachmentUploader.persistForHistory(
        AttachmentDraft(
          type: AttachmentType.document,
          name: 'notas.txt',
          mimeType: 'text/plain',
          sizeBytes: await file.length(),
          localPath: file.path,
        ),
        index: 0,
        baseDir: temp,
      ))!;
    });
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => temp.path);
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );

    await pumpChat(
      tester,
      messages: [
        {
          'role': 'user',
          'content':
              '[📎 notas.txt · 42 B]\nComprueba el texto\n${reference.toMarker()}',
        },
      ],
    );
    final card = find.byKey(
      ValueKey('history-attachment-0-${reference.storageKey}'),
    );
    for (var frame = 0; frame < 30 && card.evaluate().isEmpty; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(card, findsOneWidget);
    final innerCard = find.descendant(
      of: card,
      matching: find.byType(AttachmentCard),
    );
    for (
      var frame = 0;
      frame < 30 &&
          (innerCard.evaluate().isEmpty ||
              tester.widget<AttachmentCard>(innerCard).onTap == null);
      frame++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(tester.widget<AttachmentCard>(innerCard).onTap, isNotNull);
    expect(
      find.textContaining(AttachmentHistoryReference.markerPrefix),
      findsNothing,
    );

    await tester.tap(card);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    for (
      var frame = 0;
      frame < 30 && find.text(exactText).evaluate().isEmpty;
      frame++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(find.byType(AttachmentBytesPreviewScreen), findsOneWidget);
    expect(find.text(exactText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('PDF histórico usa el canal nativo con sus bytes exactos', (
    tester,
  ) async {
    late final Directory temp;
    late final AttachmentHistoryReference reference;
    late final List<int> pdfBytes;
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('chat-history-pdf-');
      pdfBytes = <int>[...'%PDF-1.4\nobjeto privado\n%%EOF'.codeUnits];
      final file = File('${temp.path}/contrato.pdf');
      await file.writeAsBytes(pdfBytes);
      reference = (await AttachmentUploader.persistForHistory(
        AttachmentDraft(
          type: AttachmentType.document,
          name: 'contrato.pdf',
          mimeType: 'application/pdf',
          sizeBytes: pdfBytes.length,
          localPath: file.path,
        ),
        index: 0,
        baseDir: temp,
      ))!;
    });
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => temp.path);
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );
    Map<Object?, Object?>? nativeArguments;
    List<int>? nativeFileBytes;
    const previewChannel = MethodChannel(attachmentDocumentPreviewChannelName);
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(previewChannel, (call) async {
          nativeArguments = (call.arguments as Map).cast<Object?, Object?>();
          final key = nativeArguments!['storageKey'] as String;
          nativeFileBytes = File(
            '${temp.path}/${AttachmentUploader.sentAttachmentDirectoryName}/$key',
          ).readAsBytesSync();
          return <String, Object>{
            'pngBytes': base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
              'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            ),
            'pageCount': 1,
            'pageIndex': 0,
          };
        });
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(previewChannel, null),
    );

    await pumpChat(
      tester,
      messages: [
        {
          'role': 'user',
          'content': '[📎 contrato.pdf · 31 B]\n${reference.toMarker()}',
        },
      ],
    );
    final card = find.byKey(
      ValueKey('history-attachment-0-${reference.storageKey}'),
    );
    for (var frame = 0; frame < 30 && card.evaluate().isEmpty; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    final innerCard = find.descendant(
      of: card,
      matching: find.byType(AttachmentCard),
    );
    for (
      var frame = 0;
      frame < 30 &&
          (innerCard.evaluate().isEmpty ||
              tester.widget<AttachmentCard>(innerCard).onTap == null);
      frame++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(tester.widget<AttachmentCard>(innerCard).onTap, isNotNull);
    await tester.tap(card);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    for (
      var frame = 0;
      frame < 40 &&
          (nativeFileBytes == null ||
              find
                  .byKey(const ValueKey('attachment-pdf-page-0'))
                  .evaluate()
                  .isEmpty);
      frame++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(nativeArguments?['storageKey'], reference.storageKey);
    expect(nativeArguments?['expectedSize'], pdfBytes.length);
    expect(nativeArguments?['expectedSha256'], reference.sha256Hex);
    expect(nativeArguments, isNot(contains('path')));
    expect(nativeFileBytes, pdfBytes);
    expect(find.byKey(const ValueKey('attachment-pdf-page-0')), findsOneWidget);
    expect(find.text('Página 1 de 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('un marcador válido con copia ausente conserva un chip inerte', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('chat-history-missing-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => temp.path);
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );
    final digest = List.filled(64, 'a').join();
    final reference = AttachmentHistoryReference(
      index: 0,
      storageKey: digest,
      type: AttachmentType.document,
      mimeType: 'application/pdf',
      sizeBytes: 128,
      sha256Hex: digest,
    );

    await pumpChat(
      tester,
      messages: [
        {
          'role': 'user',
          'content': '[📎 ausente.pdf · 128 B]\n${reference.toMarker()}',
        },
      ],
    );
    for (var frame = 0; frame < 20; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }

    final card = find.widgetWithText(AttachmentCard, 'ausente.pdf');
    expect(card, findsOneWidget);
    expect(tester.widget<AttachmentCard>(card).onTap, isNull);
    expect(find.byType(AttachmentBytesPreviewScreen), findsNothing);
    expect(
      find.textContaining(AttachmentHistoryReference.markerPrefix),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dictado conserva el transcript fuera del controller hasta parar',
    (tester) async {
      final stt = _PartialSttEngine();
      await pumpChat(tester, stt: stt);

      final idleMic = tester.widget<HermesTactileAction>(
        find.byKey(const ValueKey('mic')),
      );
      expect(idleMic.icon, Icons.mic_none_rounded);
      expect(idleMic.iconSize, 25);
      expect(idleMic.backgroundColor, Colors.transparent);

      await tester.tap(find.byKey(const ValueKey('mic')));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('dictation-visualizer')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('dictation-bars')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('dictation-wave-history')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('dictation-pill')), findsNothing);
      expect(find.byKey(const ValueKey('dictation-duration')), findsNothing);
      expect(find.text('Escuchando…'), findsNothing);
      final dictationPaint = tester.widget<CustomPaint>(
        find.byKey(const ValueKey('dictation-bars-paint')),
      );
      final dynamic dictationPainter = dictationPaint.painter;
      final dynamic samples = dictationPainter.samples;
      final initialSamples = List<double>.from(samples.value as List);
      await tester.pump(const Duration(milliseconds: 40));
      expect(samples.value, isNot(same(initialSamples)));
      expect(find.byKey(const ValueKey('dictation-cancel')), findsOneWidget);
      expect(find.byKey(const ValueKey('dictation-stop')), findsOneWidget);
      expect(find.byKey(const ValueKey('dictation-send')), findsOneWidget);

      stt.results.add(const SttResult('hola', false));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('dictation-live-preview')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('dictation-bars')), findsOneWidget);
      expect(find.text('hola'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );

      stt.results.add(const SttResult('hola mundo', false));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(find.byKey(const ValueKey('dictation-bars')), findsOneWidget);

      await stt.emitFinalAndClose('hola mundo');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('dictation-live-preview')),
        findsNothing,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'hola mundo',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'segundo dictado conserva altura y onda centrada tras materializar texto largo',
    (tester) async {
      final stt = _PartialSttEngine();
      await pumpChat(tester, stt: stt);

      await tester.tap(find.byKey(const ValueKey('mic')));
      await tester.pump();

      Finder recordingArea() => find
          .ancestor(
            of: find.byKey(const ValueKey('dictation-visualizer')),
            matching: find.byType(Stack),
          )
          .first;
      final firstHeight = tester.getSize(recordingArea()).height;

      await stt.emitFinalAndClose(
        List.filled(40, 'transcripción extensa').join(' '),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('recording')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('mic')));
      await tester.pump();

      final secondArea = recordingArea();
      final visualizer = find.byKey(const ValueKey('dictation-visualizer'));
      expect(tester.getSize(secondArea).height, firstHeight);
      expect(tester.getSize(secondArea).height, 48);
      expect(
        tester.getCenter(visualizer).dy,
        closeTo(tester.getCenter(secondArea).dy, 0.01),
      );
      expect(tester.getSize(visualizer).height, 28);
    },
  );

  testWidgets('borrador multilinea no cambia altura ni centrado del dictado', (
    tester,
  ) async {
    final stt = _PartialSttEngine();
    await pumpChat(tester, stt: stt);

    await tester.tap(find.byKey(const ValueKey('mic')));
    await tester.pump();
    final firstVisualizer = find.byKey(const ValueKey('dictation-visualizer'));
    final firstArea = find
        .ancestor(of: firstVisualizer, matching: find.byType(Stack))
        .first;
    final firstHeight = tester.getSize(firstArea).height;

    await stt.emitFinalAndClose('');
    await tester.pump();
    await tester.enterText(
      find.byType(TextField),
      'línea uno\nlínea dos\nlínea tres\nlínea cuatro',
    );
    await tester.tap(find.byKey(const ValueKey('mic')));
    await tester.pump();

    final visualizer = find.byKey(const ValueKey('dictation-visualizer'));
    final recordingArea = find
        .ancestor(of: visualizer, matching: find.byType(Stack))
        .first;
    expect(tester.getSize(recordingArea).height, firstHeight);
    expect(tester.getSize(recordingArea).height, 48);
    expect(
      tester.getCenter(visualizer).dy,
      closeTo(tester.getCenter(recordingArea).dy, 0.01),
    );
    expect(tester.getSize(visualizer).height, 28);
  });

  testWidgets('dictado deja tocar el campo a través de la onda', (
    tester,
  ) async {
    final stt = _PartialSttEngine();
    await pumpChat(tester, stt: stt);

    final fieldFinder = find.byType(TextField);
    final field = tester.widget<TextField>(fieldFinder);

    await tester.tap(find.byKey(const ValueKey('mic')));
    await tester.pump();

    field.focusNode!.unfocus();
    await tester.pump();
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('dictation-visualizer'))),
    );
    await tester.pump();

    expect(field.focusNode!.hasFocus, isTrue);
  });

  testWidgets('dictado conserva foco IME y Cancel restaura el borrador', (
    tester,
  ) async {
    final stt = _PartialSttEngine();
    final gateway = _SubmissionGateway();
    await pumpChat(
      tester,
      stt: stt,
      desktopGateway: gateway,
      connection: _remoteConn('conn-dictation-cancel'),
      requestComposerFocus: true,
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isTrue);
    await tester.enterText(find.byType(TextField), 'Borrador intacto');
    await tester.tap(find.byKey(const ValueKey('mic')));
    await tester.pump();
    expect(field.focusNode!.hasFocus, isTrue);

    stt.results.add(const SttResult('texto que descarto', false));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Borrador intacto',
    );

    await tester.tap(find.byKey(const ValueKey('dictation-cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('recording')), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Borrador intacto',
    );
    expect(field.focusNode!.hasFocus, isTrue);
    expect(gateway.submissions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Enviar dictado espera el final y lo entrega exactamente una vez',
    (tester) async {
      final stt = _PartialSttEngine(finalOnStop: 'resultado correcto');
      final gateway = _SubmissionGateway();
      await pumpChat(
        tester,
        stt: stt,
        desktopGateway: gateway,
        connection: _remoteConn('conn-dictation-send'),
      );

      await tester.enterText(find.byType(TextField), 'Inicio');
      await tester.tap(find.byKey(const ValueKey('mic')));
      await tester.pump();
      stt.results.add(const SttResult('resultado pobre', false));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Inicio',
      );

      await tester.tap(find.byKey(const ValueKey('dictation-send')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(stt.stopCalls, 1);
      expect(gateway.submissions, ['Inicio resultado correcto']);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(find.byKey(const ValueKey('recording')), findsNothing);
      gateway.emitComplete();
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dictado compacto usa una fila continua con controles tactiles de 48dp',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final semantics = tester.ensureSemantics();
      final stt = _PartialSttEngine();
      await pumpChat(tester, stt: stt);

      await tester.tap(find.byKey(const ValueKey('mic')));
      await tester.pump();

      final cancel = find.byKey(const ValueKey('dictation-cancel'));
      final history = find.byKey(const ValueKey('dictation-wave-history'));
      final stop = find.byKey(const ValueKey('dictation-stop'));
      final send = find.byKey(const ValueKey('dictation-send'));
      expect(find.byKey(const ValueKey('dictation-pill')), findsNothing);
      expect(cancel, findsOneWidget);
      expect(history, findsOneWidget);
      expect(stop, findsOneWidget);
      expect(send, findsOneWidget);
      expect(find.bySemanticsLabel('Escuchando…'), findsOneWidget);
      expect(
        find.ancestor(of: stop, matching: find.byType(RotationTransition)),
        findsNothing,
      );

      final cancelRect = tester.getRect(cancel);
      final historyRect = tester.getRect(history);
      final stopRect = tester.getRect(stop);
      final sendRect = tester.getRect(send);
      expect(cancelRect.width, greaterThanOrEqualTo(48));
      expect(cancelRect.height, greaterThanOrEqualTo(48));
      expect(historyRect.left, greaterThanOrEqualTo(cancelRect.right));
      expect(stopRect.left, greaterThanOrEqualTo(historyRect.right));
      expect(sendRect.left, greaterThanOrEqualTo(stopRect.right));
      expect(stopRect.width, greaterThanOrEqualTo(48));
      expect(stopRect.height, greaterThanOrEqualTo(48));
      expect(sendRect.width, greaterThanOrEqualTo(48));
      expect(sendRect.height, greaterThanOrEqualTo(48));
      final sendAction = tester.widget<HermesTactileAction>(
        find.descendant(of: send, matching: find.byType(HermesTactileAction)),
      );
      expect(sendAction.backgroundColor, isNot(Colors.white));

      stt.results.add(const SttResult('parcial oculto', false));
      await tester.pump(const Duration(milliseconds: 40));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      final enabledSendAction = tester.widget<HermesTactileAction>(
        find.descendant(of: send, matching: find.byType(HermesTactileAction)),
      );
      expect(enabledSendAction.backgroundColor, Colors.white);
      expect(tester.takeException(), isNull);

      await stt.emitFinalAndClose('parcial oculto');
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'parcial oculto',
      );
      expect(find.byKey(const ValueKey('recording')), findsNothing);
      semantics.dispose();
    },
  );

  testWidgets(
    'transcribiendo congela el historial y sustituye Stop por progreso',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final semantics = tester.ensureSemantics();
      final stopGate = Completer<void>();
      final stt = _PartialSttEngine(stopGate: stopGate);
      await pumpChat(tester, stt: stt);

      await tester.tap(find.byKey(const ValueKey('mic')));
      await tester.pump();
      stt.results.add(const SttResult('texto pendiente', false));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('dictation-stop')));
      await tester.pump();

      expect(stt.stopCalls, 1);
      expect(
        find.byKey(const ValueKey('dictation-wave-history')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('dictation-stop')), findsNothing);
      expect(
        find.byKey(const ValueKey('dictation-transcribing')),
        findsOneWidget,
      );
      final statusSemantics = tester.widget<Semantics>(
        find.byKey(const ValueKey('dictation-status-semantics')),
      );
      expect(statusSemantics.properties.label, 'Transcribiendo tu voz…');
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('recording')),
          matching: find.byType(RotationTransition),
        ),
        findsNothing,
      );
      final dictationPaint = tester.widget<CustomPaint>(
        find.byKey(const ValueKey('dictation-bars-paint')),
      );
      final dynamic dictationPainter = dictationPaint.painter;
      final dynamic samples = dictationPainter.samples;
      expect(dictationPainter.transcribing, isTrue);
      final initialSamples = List<double>.from(samples.value as List);
      await tester.pump(const Duration(milliseconds: 80));
      expect(samples.value, orderedEquals(initialSamples));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);

      stopGate.complete();
      await tester.pump();
      await stt.emitFinalAndClose('texto pendiente');
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'texto pendiente',
      );
      expect(find.byKey(const ValueKey('recording')), findsNothing);
      semantics.dispose();
    },
  );

  testWidgets(
    'Reduce Motion conserva el historial causal a 30 fps sin ornamentos',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final stt = _PartialSttEngine();
      await pumpChat(tester, stt: stt);

      expect(
        tester
            .widget<AnimatedSwitcher>(
              find.byKey(const ValueKey('composer-primary-action-switcher')),
            )
            .duration,
        Duration.zero,
      );

      await tester.tap(find.byKey(const ValueKey('mic')));
      await tester.pump();

      final recording = find.byKey(const ValueKey('recording'));
      final stop = find.byKey(const ValueKey('dictation-stop'));
      expect(recording, findsOneWidget);
      expect(stop, findsOneWidget);
      expect(
        find.ancestor(of: stop, matching: find.byType(RotationTransition)),
        findsNothing,
      );
      final initialStopRect = tester.getRect(stop);
      final dictationPaint = tester.widget<CustomPaint>(
        find.byKey(const ValueKey('dictation-bars-paint')),
      );
      final dynamic dictationPainter = dictationPaint.painter;
      final dynamic samples = dictationPainter.samples;
      final dynamic visualizer = tester.widget(
        find.byKey(const ValueKey('dictation-visualizer')),
      );
      final dynamic level = visualizer.level;
      final initialSamples = List<double>.from(samples.value as List);

      level.value = 0.85;
      await tester.pump(const Duration(milliseconds: 16));
      expect(samples.value, orderedEquals(initialSamples));

      await tester.pump(const Duration(milliseconds: 18));
      expect((samples.value as List<double>).last, greaterThan(0.9));

      await tester.pump(const Duration(seconds: 1));
      expect(tester.getRect(stop), initialStopRect);
      expect(
        find.ancestor(of: stop, matching: find.byType(RotationTransition)),
        findsNothing,
      );
      expect((samples.value as List<double>).last, greaterThan(0.9));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dictado anuncia solo el estado y suspende relojes fuera de TickerMode',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final stt = _PartialSttEngine();
      await pumpChat(tester, stt: stt);

      await tester.tap(find.byKey(const ValueKey('mic')));
      await tester.pump();

      expect(find.bySemanticsLabel('Escuchando…'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'00:00')), findsNothing);

      final visualizer = find.byKey(const ValueKey('dictation-visualizer'));
      final dynamic visualizerState = tester.state(visualizer);
      expect(visualizerState.debugClockActive, isTrue);

      await tester.pump(const Duration(seconds: 1));
      expect(find.bySemanticsLabel(RegExp(r'00:01')), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(visualizerState.debugClockActive, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(visualizerState.debugClockActive, isTrue);

      final navigator = Navigator.of(tester.element(find.byType(ChatScreen)));
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: SizedBox.expand()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(visualizerState.debugClockActive, isFalse);

      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(visualizerState.debugClockActive, isTrue);
      semantics.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dictado materializa cada tramo solo al parar y continúa al reanudar',
    (tester) async {
      final stt = _PartialSttEngine();
      await pumpChat(tester, stt: stt);

      await tester.enterText(find.byType(TextField), 'Inicio');
      await tester.tap(find.byKey(const ValueKey('mic')));
      await tester.pump();

      stt.results.add(const SttResult('uno', false));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Inicio',
      );
      expect(find.byKey(const ValueKey('dictation-bars')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('recording')));
      await stt.endSegmentWithoutFinal();
      await tester.pump();
      expect(find.byKey(const ValueKey('recording')), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Inicio uno',
      );

      await tester.tap(find.byKey(const ValueKey('mic')));
      await tester.pump();
      stt.results.add(const SttResult('dos', false));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Inicio uno',
      );
      expect(find.byKey(const ValueKey('dictation-bars')), findsOneWidget);

      await stt.emitFinalAndClose('dos');
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Inicio uno dos',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dictado vacío pide cierre al motor y vuelve a reposo', (
    tester,
  ) async {
    final stt = _PartialSttEngine(closeOnStop: true);
    await pumpChat(tester, stt: stt);

    await tester.tap(find.byKey(const ValueKey('mic')));
    await tester.pump();
    expect(find.byKey(const ValueKey('recording')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('recording')));
    await tester.pump();

    expect(find.byKey(const ValueKey('recording')), findsNothing);
    expect(find.byKey(const ValueKey('mic')), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(stt.stopCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Stop materializa el resultado final una sola vez', (
    tester,
  ) async {
    final stt = _PartialSttEngine(
      finalOnStop: 'Mañana tengo una cita a las cinco y media',
    );
    await pumpChat(tester, stt: stt);

    await tester.tap(find.byKey(const ValueKey('mic')));
    await tester.pump();
    expect(find.byKey(const ValueKey('recording')), findsOneWidget);

    stt.results.add(
      const SttResult('Mañana tengo una cita a las cinco y media', false),
    );
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );

    await tester.tap(find.byKey(const ValueKey('recording')));
    await tester.pump();
    await tester.pump();

    expect(stt.stopCalls, 1);
    expect(find.byKey(const ValueKey('recording')), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Mañana tengo una cita a las cinco y media',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('el micro sigue disponible mientras el agente ejecuta', (
    tester,
  ) async {
    final stt = _PartialSttEngine();
    await pumpChat(
      tester,
      stt: stt,
      chatState: ChatPipelineState.executing,
      messages: const [
        {'role': 'assistant', 'content': '', '_pipeline': true},
        {'role': 'user', 'content': 'busca información'},
      ],
    );

    expect(find.byKey(const ValueKey('mic')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mic')));
    await tester.pump();
    stt.results.add(const SttResult('para y responde esto', false));
    await tester.pump();

    expect(find.byKey(const ValueKey('recording')), findsOneWidget);
    expect(find.byKey(const ValueKey('dictation-bars')), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'modo voz espera RECORD_AUDIO antes de publicar la sesión activa',
    (tester) async {
      final permission = Completer<bool>();
      final stt = _PartialSttEngine(availabilityGate: permission);
      await pumpChat(tester, stt: stt);
      final app = tester.state<HermesAppState>(find.byType(HermesApp));
      await app.voice.acceptVoiceDisclosure(continueWhenLocked: true);

      await tester.tap(find.byKey(const ValueKey('voice')));
      await tester.pump();

      expect(
        app.voiceConvo.active,
        isFalse,
        reason: 'el FGS observa active; no debe verlo antes del permiso',
      );

      permission.complete(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(app.voiceConvo.active, isTrue);
      app.voiceConvo.exit();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'otro chat no cambia la ruta servidor ni el owner de Voz activa',
    (tester) async {
      final ownerConnection = _remoteConn('conn-voice-owner');
      final ownerSession = Session(
        id: 'sess-voice-owner',
        title: 'Voz propietaria',
        model: 'hermes-agent',
        source: 'mobile',
        messageCount: 0,
        isActive: true,
        preview: '',
        startedAt: 0,
      );
      final ownerChat = await pumpChat(
        tester,
        stt: _PartialSttEngine(),
        connection: ownerConnection,
        session: ownerSession,
      );
      final app = tester.state<HermesAppState>(find.byType(HermesApp));
      await app.voice.acceptVoiceDisclosure(continueWhenLocked: false);
      app.voice.enableNativeVoice(
        speak: (text) async => {
          'ok': true,
          'data_url': 'data:audio/mpeg;base64,${base64Encode([1, 2])}',
        },
        transcribe: (dataUrl, mime) async => {
          'ok': true,
          'transcript': 'owner',
        },
      );
      await app.voiceConvo.enter(chat: ownerChat, model: 'hermes-agent');
      app.voiceConvo.minimizeOverlay();
      await tester.pump();
      final routeEpoch = app.voice.activeVoiceRoute?.createdAtEpoch;

      final otherConnection = _remoteConn('conn-voice-other');
      final prefs = await SharedPreferences.getInstance();
      await NativeVoiceModeStore(
        prefs,
      ).write(otherConnection.dashboardUrl!, NativeVoiceMode.server);
      final otherSession = Session(
        id: 'sess-voice-other',
        title: 'Otro chat',
        model: 'hermes-agent',
        source: 'mobile',
        messageCount: 0,
        isActive: true,
        preview: '',
        startedAt: 0,
      );
      final context = tester.element(find.byType(ChatScreen).last);
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              ChatScreen(connection: otherConnection, session: otherSession),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byKey(const ValueKey('voice')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('voice')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(app.voiceConvo.ownerChat, same(ownerChat));
      expect(app.voiceConvo.active, isTrue);
      expect(app.voice.nativeVoiceActive, isTrue);
      expect(app.voice.onDeviceVoiceActive, isFalse);
      expect(app.voice.activeVoiceRoute?.kind.name, 'server');
      expect(app.voice.activeVoiceRoute?.createdAtEpoch, routeEpoch);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.byType(ChatScreen, skipOffstage: false),
        findsOneWidget,
        reason:
            'el intento B sustituye la pila por la superficie propietaria A',
      );
      expect(
        tester.widget<ChatScreen>(find.byType(ChatScreen)).connection.id,
        ownerConnection.id,
      );

      unawaited(app.voiceConvo.exit());
      await tester.pump();
      await settleVoiceTeardown(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dos preflights solapados conservan la ruta del primer owner', (
    tester,
  ) async {
    final permission = Completer<bool>();
    final ownerConnection = _remoteConn('conn-voice-race-owner');
    final ownerSession = Session(
      id: 'sess-voice-race-owner',
      title: 'Owner en preparación',
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: 0,
    );
    final ownerChat = await pumpChat(
      tester,
      stt: _PartialSttEngine(availabilityGate: permission),
      connection: ownerConnection,
      session: ownerSession,
    );
    final app = tester.state<HermesAppState>(find.byType(HermesApp));
    await app.voice.acceptVoiceDisclosure(continueWhenLocked: false);

    await tester.tap(find.byKey(const ValueKey('voice')));
    await tester.pump();
    expect(app.voiceConvo.active, isFalse);
    expect(app.voice.onDeviceVoiceActive, isTrue);

    final otherConnection = SavedConnection(
      id: 'conn-voice-race-other',
      label: 'Otra ruta',
      host: '192.168.255.253',
      port: 8642,
      apiKey: 'k',
      dashboardUrl: 'http://127.0.0.1:9120',
    );
    final prefs = await SharedPreferences.getInstance();
    await NativeVoiceModeStore(
      prefs,
    ).write(otherConnection.dashboardUrl!, NativeVoiceMode.server);
    final otherSession = Session(
      id: 'sess-voice-race-other',
      title: 'Segundo preflight',
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: 0,
    );
    final context = tester.element(find.byType(ChatScreen).last);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ChatScreen(connection: otherConnection, session: otherSession),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byKey(const ValueKey('voice')));
    await tester.pump();

    expect(app.voice.onDeviceVoiceActive, isTrue);
    expect(find.byType(AlertDialog), findsNothing);

    permission.complete(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 350));

    expect(app.voiceConvo.ownerChat, same(ownerChat));
    expect(app.voiceConvo.active, isTrue);
    expect(app.voice.onDeviceVoiceActive, isTrue);
    expect(app.voice.activeVoiceRoute?.kind.name, 'phone');
    expect(find.byType(AlertDialog), findsNothing);

    unawaited(app.voiceConvo.exit());
    await tester.pump();
    await settleVoiceTeardown(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('modo voz ocupa el cuerpo y conserva un único foco', (
    tester,
  ) async {
    final stt = _PartialSttEngine();
    await pumpChat(tester, stt: stt);
    final app = tester.state<HermesAppState>(find.byType(HermesApp));
    await app.voice.acceptVoiceDisclosure(continueWhenLocked: false);

    await tester.tap(find.byKey(const ValueKey('voice')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.byKey(const ValueKey('voice-conversation-surface')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('voice-user-transcript')), findsNothing);
    expect(find.byKey(const ValueKey('voice-assistant-panel')), findsNothing);
    expect(find.byKey(const ValueKey('voice-stage-cancel')), findsNothing);
    expect(find.byKey(const ValueKey('voice')), findsNothing);

    stt.results.add(const SttResult('hola parcial', false));
    await tester.pump();
    expect(find.byKey(const ValueKey('voice-user-transcript')), findsNothing);
    expect(find.text('hola parcial'), findsNothing);

    final longPartial = List.filled(70, 'texto').join(' ');
    stt.results.add(SttResult(longPartial, false));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('voice-user-transcript')), findsNothing);
    expect(find.text(longPartial), findsNothing);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('voice-conversation-surface')))
          .height,
      greaterThan(500),
    );

    // El factory inicial de pumpChat devuelve deliberadamente el mismo fake
    // para poder inyectarle parciales. Antes de destruirlo al pausar, imita el
    // factory productivo dejando preparado un motor nuevo para la reanudación.
    app.voice.debugSttFactory = _PartialSttEngine.new;
    await tester.tap(find.byKey(const ValueKey('voice-stage-pause')));
    await tester.pump();
    // La superficie mantiene una sola pista causal visible; nunca muestra el
    // transcript ni la respuesta, pero sí confirma que el turno está pausado.
    expect(find.text('En pausa'), findsOneWidget);
    expect(find.bySemanticsLabel('En pausa'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('voice-stage-resume')));
    await tester.pump();
    // Phone libera STT/TTS al pausar y Play espera el ACK de ese teardown antes
    // de reconstruir una única captura. Comprueba la transición causal en vez
    // de imponer que dos plugins distintos terminen dentro de un frame fijo.
    for (var frame = 0; app.voiceConvo.userPaused && frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(app.voiceConvo.userPaused, isFalse);

    await tester.tap(find.byKey(const ValueKey('voice-stage-close')));
    await tester.pump();
    expect(app.voiceConvo.active, isFalse);
    expect(
      find.byKey(const ValueKey('voice-conversation-surface')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('voice-user-transcript')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Stop escrito consume el draft y termina Voz sin enviarlo al agente',
    (tester) async {
      final gateway = _SubmissionGateway();
      final stt = _PartialSttEngine();
      final chat = await pumpChat(tester, stt: stt, desktopGateway: gateway);
      final app = tester.state<HermesAppState>(find.byType(HermesApp));
      await app.voiceConvo.enter(chat: chat, model: 'hermes-agent');
      app.voiceConvo.minimizeOverlay();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Stop.');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(app.voiceConvo.active, isFalse);
      expect(gateway.submissions, isEmpty);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(chat.lastPrompt, isEmpty);
      await settleVoiceTeardown(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Stop escrito con Voz inactiva sigue siendo un prompt normal', (
    tester,
  ) async {
    final gateway = _SubmissionGateway();
    await pumpChat(
      tester,
      connection: _remoteConn('conn-typed-stop-inactive'),
      desktopGateway: gateway,
    );

    await tester.enterText(find.byType(TextField), 'stop');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump(const Duration(milliseconds: 500));

    expect(gateway.submissions, ['stop']);
    final app = tester.state<HermesAppState>(find.byType(HermesApp));
    expect(app.voiceConvo.active, isFalse);
    gateway.emitComplete();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Stop no consume el draft mientras la superficie de Voz tapa el composer',
    (tester) async {
      final gateway = _SubmissionGateway();
      final stt = _PartialSttEngine();
      final chat = await pumpChat(
        tester,
        stt: stt,
        connection: _remoteConn('conn-typed-stop-inaccessible'),
        desktopGateway: gateway,
      );
      await tester.enterText(find.byType(TextField), 'Stop.');
      await tester.pump();
      final app = tester.state<HermesAppState>(find.byType(HermesApp));

      await app.voiceConvo.enter(chat: chat, model: 'hermes-agent');
      await tester.pump();

      expect(find.byType(TextField), findsNothing);
      expect(app.voiceConvo.active, isTrue);
      expect(gateway.submissions, isEmpty);

      unawaited(app.voiceConvo.exit());
      await tester.pump();
      await settleVoiceTeardown(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Stop.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'una petición que solo contiene stop no termina la conversación de Voz',
    (tester) async {
      final gateway = _SubmissionGateway();
      final stt = _PartialSttEngine();
      final chat = await pumpChat(
        tester,
        stt: stt,
        connection: _remoteConn('conn-typed-stop-substantive'),
        desktopGateway: gateway,
      );
      final app = tester.state<HermesAppState>(find.byType(HermesApp));
      await app.voiceConvo.enter(chat: chat, model: 'hermes-agent');
      app.voiceConvo.minimizeOverlay();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'stop the container');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump(const Duration(milliseconds: 500));

      expect(app.voiceConvo.active, isTrue);
      expect(gateway.submissions, ['stop the container']);
      gateway.emitComplete();
      await tester.pump(const Duration(milliseconds: 100));
      unawaited(app.voiceConvo.exit());
      await tester.pump();
      await settleVoiceTeardown(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'App Lock pausa Voz manual y desbloquear no la reanuda sin Continuar',
    (tester) async {
      final stt = _PartialSttEngine();
      final chat = await pumpChat(tester, stt: stt);
      final app = tester.state<HermesAppState>(find.byType(HermesApp));
      await app.voice.acceptVoiceDisclosure(continueWhenLocked: true);
      await app.voiceConvo.enter(chat: chat, model: 'hermes-agent');
      await tester.pump();
      expect(app.voiceConvo.active, isTrue);
      expect(app.voiceConvo.userPaused, isFalse);

      app.appLock.locked.value = true;
      await tester.runAsync(app.voiceConvo.suspendForPrivacy);
      expect(
        app.voiceConvo.userPaused,
        isTrue,
        reason: 'App Lock manda también sobre Voz iniciada manualmente',
      );

      app.appLock.unlock();
      await tester.runAsync(app.voiceConvo.resumeFullDuplexCaptureIfNeeded);
      expect(
        app.voiceConvo.userPaused,
        isTrue,
        reason: 'desbloquear la app no equivale a pulsar Continuar',
      );

      app.voice.debugSttFactory = _PartialSttEngine.new;
      await tester.runAsync(app.voiceConvo.resumeFromSystemControl);
      expect(app.voiceConvo.userPaused, isFalse);

      // Este caso prueba App Lock, no el teardown del plugin FGS. Simula que
      // Android ya retiró el servicio para no programar la reafirmación de
      // notificación de 300 ms, cubierta por sus propios tests.
      foregroundServiceRunning = false;
      await tester.runAsync(app.voiceConvo.exit);
      await tester.pump();
      await settleVoiceTeardown(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sin barge-in armado ofrece Parar y hablar; pausa y cancelar siguen separados',
    (tester) async {
      final stt = _PartialSttEngine();
      final chat = await pumpChat(
        tester,
        stt: stt,
        chatState: ChatPipelineState.executing,
        messages: const [
          {'role': 'assistant', 'content': 'Respuesta parcial.'},
          {'role': 'user', 'content': 'Haz una tarea'},
        ],
      );
      final app = tester.state<HermesAppState>(find.byType(HermesApp));
      await app.voiceConvo.enter(chat: chat, model: 'hermes-agent');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Respuesta parcial.'), findsNothing);
      expect(
        find.byKey(const ValueKey('voice-assistant-transcript')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('voice-stage-stop-and-talk')),
        findsOneWidget,
      );
      expect(find.text('Puedes hablar en cualquier momento.'), findsNothing);
      expect(
        find.text(
          'Puedes interrumpir hablando mientras Hermes piensa o responde. '
          'También puedes pausar la voz o cancelar la tarea.',
        ),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('voice-stage-cancel')), findsOneWidget);

      expect(chat.isStreaming, isTrue);
      expect(app.voiceConvo.phase, isNot(VoicePhase.listening));

      await tester.tap(find.byKey(const ValueKey('voice-stage-close')));
      await tester.pump();
      expect(chat.isStreaming, isTrue, reason: 'X no cancela la tarea remota');
      chat.cancel();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'minimizar conserva la voz y permite usar el chat antes de volver',
    (tester) async {
      final stt = _PartialSttEngine();
      final chat = await pumpChat(tester, stt: stt);
      final app = tester.state<HermesAppState>(find.byType(HermesApp));
      await app.voiceConvo.enter(chat: chat, model: 'hermes-agent');
      await tester.pump();

      expect(
        find.byKey(const ValueKey('voice-conversation-surface')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('voice-stage-minimize')));
      await tester.pump();

      expect(app.voiceConvo.active, isTrue);
      expect(app.voiceConvo.overlayMinimized, isTrue);
      expect(
        find.byKey(const ValueKey('voice-conversation-surface')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('voice-return-overlay')),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('voice-return-overlay')));
      await tester.pump();
      expect(app.voiceConvo.overlayMinimized, isFalse);
      expect(
        find.byKey(const ValueKey('voice-conversation-surface')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('voice-stage-close')));
      await tester.pump();
      expect(app.voiceConvo.active, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('una aprobación pendiente sigue siendo táctil', (tester) async {
    final stt = _PartialSttEngine();
    final chat = await pumpChat(
      tester,
      stt: stt,
      chatState: ChatPipelineState.executing,
      messages: const [
        {'role': 'assistant', 'content': ''},
        {'role': 'user', 'content': 'Ejecuta esto'},
      ],
    );
    chat.pendingApproval = {
      'command': 'touch /tmp/voice-approval-test',
      'description': 'Crear archivo de prueba',
      'choices': ['once', 'deny'],
    };
    final app = tester.state<HermesAppState>(find.byType(HermesApp));
    await app.voiceConvo.enter(chat: chat, model: 'hermes-agent');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('voice-stage-review')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('voice-stage-review')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('voice-conversation-surface')),
      findsNothing,
    );
    expect(find.text('touch /tmp/voice-approval-test'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-return-overlay')), findsOneWidget);
    expect(chat.pendingApproval, isNotNull);

    await tester.tap(find.byKey(const ValueKey('voice-return-overlay')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('voice-conversation-surface')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('voice-stage-close')));
    await tester.pump();
    // El chat ejecutándose es un estado artificial del fixture (no hay
    // transporte que cancelar). Déjalo terminal para que el teardown lo libere
    // sin invocar el foreground service de plataforma.
    chat
      ..pendingApproval = null
      ..state = ChatPipelineState.cancelled;
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'official Bot Chat pin missing fails closed without creating a session',
    (tester) async {
      final gateway = _UiRewindGateway()
        ..resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'missing official pin',
          code: 4007,
        );
      addTearDown(gateway.close);
      await pumpChat(
        tester,
        connection: _remoteConn('conn-official-bot'),
        session: const Session(
          id: 'official-missing',
          title: 'Bot Chat',
          model: 'hermes-agent',
          source: 'bot-mode',
          messageCount: 0,
          isActive: false,
          preview: '',
          startedAt: 1,
          profile: 'infra',
        ),
        desktopGateway: gateway,
      );

      expect(find.byKey(const ValueKey('voice')), findsNothing);
      expect(find.byKey(const ValueKey('send')), findsOneWidget);

      final composer = find.byType(TextField).last;
      await tester.enterText(composer, 'no crear otra identidad');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();

      expect(gateway.createConfigs, isEmpty);
      expect(gateway.submissions, isEmpty);
      expect(
        tester.widget<TextField>(composer).controller!.text,
        'no crear otra identidad',
      );
    },
  );

  testWidgets(
    'local Bot Chat pin missing recreates hidden and refreshable identity',
    (tester) async {
      final gateway = _UiRewindGateway()
        ..resumeExistingError = const TuiGatewayRpcError(
          'session.resume',
          'missing local pin',
          code: 4007,
        );
      addTearDown(gateway.close);
      await pumpChat(
        tester,
        connection: _remoteConn('conn-local-bot'),
        session: const Session(
          id: 'local-missing',
          title: 'Bot Chat',
          model: 'hermes-agent',
          source: 'bot-mode-local',
          messageCount: 0,
          isActive: false,
          preview: '',
          startedAt: 1,
          profile: 'infra',
        ),
        desktopGateway: gateway,
      );

      expect(find.byKey(const ValueKey('voice')), findsNothing);
      expect(find.byKey(const ValueKey('send')), findsOneWidget);

      final composer = find.byType(TextField).last;
      await tester.enterText(composer, 'recupera el chat local');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();

      expect(gateway.createConfigs, hasLength(1));
      expect(gateway.createConfigs.single.title, 'Bot Chat');
      expect(gateway.createConfigs.single.hidden, isTrue);
      expect(gateway.createConfigs.single.createIfMissing, isTrue);
      expect(gateway.createConfigs.single.allowTransportFallback, isFalse);
      expect(gateway.submissions, ['recupera el chat local']);
      await tester.pump(const Duration(milliseconds: 50));
      final prefs = await SharedPreferences.getInstance();
      expect(
        await MissionBotChatStore(prefs).load('conn-local-bot', 'infra'),
        'sess-test',
      );
      gateway.emit('message.complete', {'text': 'ok'});
      await tester.pump();
    },
  );

  testWidgets(
    'Room migrates a manager-session draft to its stable recovery id',
    (tester) async {
      const connectionId = 'conn-room-draft-alias';
      const managerSessionId = 'stored-room-manager-before';
      final room = MissionRoom(
        id: 'room-draft-alias',
        connectionId: connectionId,
        name: 'release',
        managerProfile: 'manager',
        memberProfiles: const ['manager', 'qa'],
        managerSessionId: managerSessionId,
        createdAtMs: 1,
        updatedAtMs: 1,
      );
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final drafts = ChatDraftStore(prefs);
      await drafts.save(
        connectionId,
        managerSessionId,
        'mensaje recuperable del Room',
        const [],
        profile: 'manager',
      );

      await pumpChat(
        tester,
        connection: _remoteConn(connectionId),
        session: const Session(
          id: managerSessionId,
          title: '#release',
          model: 'hermes-agent',
          source: 'gateway',
          messageCount: 0,
          isActive: false,
          preview: '',
          startedAt: 1,
          profile: 'manager',
        ),
        missionRoom: room,
        missionRoomStore: _RecordingMissionRoomStore(room),
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        'mensaje recuperable del Room',
      );
      expect(
        (await drafts.load(
          connectionId,
          'mob-room-${room.id}',
          profile: 'manager',
        )).text,
        'mensaje recuperable del Room',
      );
      expect(
        (await drafts.load(
          connectionId,
          managerSessionId,
          profile: 'manager',
        )).text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Room chrome is compact and keeps model and controls in overflow',
    (tester) async {
      final room = MissionRoom(
        id: 'room-visual-shell',
        connectionId: 'conn-room-visual-shell',
        name: 'homelab',
        managerProfile: 'manager',
        memberProfiles: const ['manager', 'infra', 'security'],
        managerSessionId: 'room-visual-session',
        createdAtMs: 1,
        updatedAtMs: 1,
      );
      await pumpChat(
        tester,
        connection: _remoteConn('conn-room-visual-shell'),
        session: const Session(
          id: 'room-visual-session',
          title: '#homelab',
          model: 'hermes-agent',
          source: 'gateway',
          messageCount: 0,
          isActive: false,
          preview: '',
          startedAt: 1,
          profile: 'manager',
        ),
        missionRoom: room,
        missionRoomStore: _RecordingMissionRoomStore(room),
      );

      expect(tester.widget<AppBar>(find.byType(AppBar)).centerTitle, isFalse);
      expect(find.text('#homelab'), findsOneWidget);
      expect(find.text('@manager · manager · 3 miembros'), findsOneWidget);
      expect(find.text('Perfil: manager'), findsNothing);
      expect(find.byKey(const ValueKey('chat-new-session')), findsNothing);
      expect(
        find.byKey(const ValueKey('mission-room-members-appbar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mission-room-overflow-appbar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mission-room-empty-state')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('voice')), findsNothing);
      expect(find.byKey(const ValueKey('send')), findsOneWidget);
      for (final profile in const ['manager', 'infra', 'security']) {
        expect(
          find.byKey(ValueKey('mission-avatar-geometry-$profile')),
          findsOneWidget,
        );
      }
      expect(find.text('Empieza con el equipo'), findsOneWidget);
      expect(
        find.text(
          'Habla con @manager o menciona otro bot para asignarle una tarea.',
        ),
        findsOneWidget,
      );
      expect(find.text('HERMES CONSOLE'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('mission-room-overflow-appbar')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mission-room-model-action')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mission-room-control-action')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('mission-room-model-action')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      expect(find.byKey(const ValueKey('chat-model-dialog')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));

      await tester.tap(
        find.byKey(const ValueKey('mission-room-overflow-appbar')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('mission-room-control-action')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      expect(find.byKey(const ValueKey('chat-control-dialog')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-control-sheet')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-control-delete')), findsNothing);
      expect(find.text('Eliminar conversación'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Room renders persisted photo and Blobatar in empty roster, mentions and members',
    (tester) async {
      final room = MissionRoom(
        id: 'room-real-avatars',
        connectionId: 'conn-room-real-avatars',
        name: 'orchestration',
        managerProfile: 'manager',
        memberProfiles: const ['manager', 'infra'],
        managerSessionId: 'room-real-avatars-session',
        createdAtMs: 1,
        updatedAtMs: 1,
      );
      final avatarLoads = <String>[];
      final avatarCache = MissionProfileAvatarCache(
        loader: (profile) async {
          avatarLoads.add(profile);
          return profile == 'infra' ? _testProfileAvatar() : null;
        },
      );
      const profiles = <String, AgentProfile>{
        'manager': AgentProfile(
          name: 'manager',
          botModeUiMeta: {
            'shape': 'blobatar::triangle',
            'imageKind': 'shape',
            'custom': true,
          },
        ),
        'infra': AgentProfile(
          name: 'infra',
          hasAvatar: true,
          botModeUiMeta: {'imageKind': 'photo', 'custom': true},
        ),
      };

      await pumpChat(
        tester,
        connection: _remoteConn('conn-room-real-avatars'),
        session: const Session(
          id: 'room-real-avatars-session',
          title: '#orchestration',
          model: 'hermes-agent',
          source: 'gateway',
          messageCount: 0,
          isActive: false,
          preview: '',
          startedAt: 1,
          profile: 'manager',
        ),
        missionRoom: room,
        missionRoomStore: _RecordingMissionRoomStore(room),
        missionRoomProfiles: profiles,
        missionAvatarCache: avatarCache,
      );
      await tester.pump();

      final managerEmpty = find.byKey(
        const ValueKey('mission-room-empty-avatar-manager'),
      );
      final managerFace = tester.widget<HermesBotFace>(
        find.descendant(of: managerEmpty, matching: find.byType(HermesBotFace)),
      );
      expect(managerFace.visual, isA<HermesBlobatarFaceVisual>());
      expect(
        (managerFace.visual as HermesBlobatarFaceVisual).pinnedKind,
        'triangle',
      );
      final infraEmpty = find.byKey(
        const ValueKey('mission-room-empty-avatar-infra'),
      );
      expect(
        find.descendant(of: infraEmpty, matching: find.byType(Image)),
        findsOneWidget,
      );
      expect(avatarLoads, ['infra']);

      final composer = find.byType(TextField).last;
      await tester.enterText(composer, '@i');
      await tester.pump();
      await tester.pump();
      final mentionAvatar = find.byKey(
        const ValueKey('room-mention-avatar-infra'),
      );
      expect(
        find.descendant(of: mentionAvatar, matching: find.byType(Image)),
        findsOneWidget,
      );
      expect(avatarLoads, ['infra']);

      await tester.tap(
        find.byKey(const ValueKey('mission-room-members-appbar')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      await tester.pump();
      final memberAvatar = find.byKey(
        const ValueKey('mission-room-member-avatar-infra'),
      );
      expect(memberAvatar, findsOneWidget);
      expect(
        find.descendant(of: memberAvatar, matching: find.byType(Image)),
        findsOneWidget,
      );
      expect(avatarLoads, ['infra']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Bot Chat chrome leads with bot identity, not the model picker', (
    tester,
  ) async {
    final avatarLoads = <String>[];
    final avatarCache = MissionProfileAvatarCache(
      loader: (profile) async {
        avatarLoads.add(profile);
        return _testProfileAvatar();
      },
    );
    await pumpChat(
      tester,
      connection: _remoteConn('conn-bot-chrome'),
      session: const Session(
        id: 'mob-bot-infra',
        lineageRootId: 'stored-bot-chrome',
        title: 'Bot Chat',
        model: 'hermes-agent',
        source: 'bot-mode',
        messageCount: 0,
        isActive: false,
        preview: '',
        startedAt: 1,
        profile: 'infra',
      ),
      missionBotProfile: const AgentProfile(
        name: 'infra',
        hasAvatar: true,
        botModeUiMeta: {
          'title': 'Infra Bot',
          'shape': 'blobatar::triangle',
          'imageKind': 'photo',
        },
      ),
      missionAvatarCache: avatarCache,
    );
    await tester.pump();

    expect(tester.widget<AppBar>(find.byType(AppBar)).centerTitle, isFalse);
    expect(find.byKey(const ValueKey('bot-chat-header')), findsOneWidget);
    expect(find.text('Infra Bot'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bot-chat-header-subtitle')),
      findsOneWidget,
    );
    expect(find.text('@infra'), findsOneWidget);
    final botAvatar = find.byKey(const ValueKey('bot-chat-avatar-infra'));
    expect(
      find.descendant(of: botAvatar, matching: find.byType(Image)),
      findsOneWidget,
    );
    expect(avatarLoads, ['infra']);
    expect(find.byKey(const ValueKey('voice')), findsNothing);
    expect(find.byKey(const ValueKey('send')), findsOneWidget);
    // Sin drawer ni "nueva sesión": el modelo y los controles van al overflow.
    expect(find.byKey(const ValueKey('chat-new-session')), findsNothing);
    expect(find.byKey(const ValueKey('chat-control-trigger')), findsNothing);
    expect(
      find.byKey(const ValueKey('bot-chat-overflow-appbar')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('bot-chat-overflow-appbar')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bot-chat-model-action')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bot-chat-control-action')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Bot Chat header falls back to the session profile name', (
    tester,
  ) async {
    await pumpChat(
      tester,
      connection: _remoteConn('conn-bot-fallback'),
      session: const Session(
        id: 'mob-bot-solo',
        title: 'Bot Chat',
        model: 'hermes-agent',
        source: 'mobile-bot',
        messageCount: 0,
        isActive: false,
        preview: '',
        startedAt: 1,
        profile: 'qa',
      ),
    );

    expect(find.byKey(const ValueKey('bot-chat-header')), findsOneWidget);
    expect(find.text('qa'), findsOneWidget);
    expect(find.text('@qa'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice')), findsNothing);
    expect(find.byKey(const ValueKey('send')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Room combina slash accent con mención seleccionada', (
    tester,
  ) async {
    final room = MissionRoom(
      id: 'room-slash-mention',
      connectionId: 'conn-room-slash',
      name: 'slash-room',
      managerProfile: 'manager',
      memberProfiles: const ['manager', 'infra'],
      managerSessionId: 'room-slash-session',
      createdAtMs: 1,
      updatedAtMs: 1,
    );
    await pumpChat(
      tester,
      connection: _remoteConn('conn-room-slash'),
      session: const Session(
        id: 'room-slash-session',
        title: '#slash-room',
        model: 'hermes-agent',
        source: 'api',
        messageCount: 0,
        isActive: false,
        preview: '',
        startedAt: 1,
        profile: 'manager',
      ),
      missionRoom: room,
      missionRoomStore: _RecordingMissionRoomStore(room),
      missionRoomWorkerRosterLoader: () async => const ['manager', 'infra'],
    );
    final composer = find.byType(TextField).last;
    await tester.enterText(composer, '@i');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('room-mention-infra')));
    await tester.pump();
    await tester.enterText(composer, '/help @infra');
    await tester.pump();

    final field = tester.widget<TextField>(composer);
    field.controller!.value = field.controller!.value.copyWith(
      composing: const TextRange(start: 6, end: 12),
    );
    await tester.pump();

    final context = tester.element(composer);
    final colors = Theme.of(context).hermes;
    final span = field.controller!.buildTextSpan(
      context: context,
      style: TextStyle(color: colors.textPrimary),
      withComposing: true,
    );
    final leaves = _flattenTextSpans(
      span,
    ).where((leaf) => leaf.text?.isNotEmpty ?? false).toList();
    expect(
      leaves.where(
        (leaf) => leaf.text == '/help' && leaf.style?.color == colors.accent,
      ),
      hasLength(1),
    );
    final mentionLeaves = leaves.where(
      (leaf) =>
          leaf.text == '@infra' && leaf.style?.fontWeight == FontWeight.w800,
    );
    expect(mentionLeaves, hasLength(1));
    expect(mentionLeaves.first.style?.decoration, TextDecoration.underline);
  });

  testWidgets(
    'Room mention selection previews and creates exactly one native task',
    (tester) async {
      final room = MissionRoom(
        id: 'room-homelab',
        connectionId: 'conn-test',
        name: 'homelab',
        managerProfile: 'manager',
        memberProfiles: const ['manager', 'infra', 'security'],
        managerSessionId: 'room-session',
        createdAtMs: 1,
        updatedAtMs: 1,
      );
      var taskCalls = 0;
      var rosterCalls = 0;
      MissionMentionIntent? captured;
      await pumpChat(
        tester,
        connection: _remoteConn('conn-test'),
        session: Session(
          id: 'room-session',
          title: '#homelab',
          model: 'hermes-agent',
          source: 'api',
          messageCount: 0,
          isActive: false,
          preview: '',
          startedAt: 1,
          profile: 'manager',
        ),
        missionRoom: room,
        missionRoomStore: _RecordingMissionRoomStore(room),
        missionRoomTaskCreator: (intent) async {
          taskCalls++;
          captured = intent;
          return const KanbanTask(
            id: 'HC-42',
            title: 'revisa backups',
            body: '@infra revisa backups',
            status: 'ready',
            assignee: 'infra',
          );
        },
        missionRoomWorkerRosterLoader: () async {
          rosterCalls++;
          return const ['manager', 'infra', 'security'];
        },
      );

      expect(find.text('#homelab'), findsOneWidget);
      expect(find.byKey(const ValueKey('room-routing-bar')), findsNothing);
      expect(find.text('Escribe al equipo…'), findsOneWidget);
      final composer = find.byType(TextField).last;
      await tester.enterText(composer, '@infra escrito a mano');
      await tester.pump();
      final unselectedSpan = tester
          .widget<TextField>(composer)
          .controller!
          .buildTextSpan(
            context: tester.element(composer),
            style: const TextStyle(),
            withComposing: true,
          );
      expect(
        _flattenTextSpans(unselectedSpan).where(
          (span) =>
              span.text == '@infra' &&
              span.style?.fontWeight == FontWeight.w800,
        ),
        isEmpty,
      );

      await tester.enterText(composer, '@m');
      await tester.pump();
      final palette = find.byKey(const ValueKey('room-mention-palette'));
      expect(palette, findsOneWidget);
      expect(
        find.byKey(const ValueKey('room-mention-manager')),
        findsOneWidget,
      );
      expect(find.text('Hablar'), findsOneWidget);
      await tester.enterText(composer, '@i');
      await tester.pump();
      expect(find.byKey(const ValueKey('room-mention-infra')), findsOneWidget);
      expect(find.text('Asignar tarea'), findsOneWidget);
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
      expect(
        (tester.widget<Container>(palette).margin! as EdgeInsets).bottom,
        greaterThanOrEqualTo(8),
        reason: 'the floating mention palette must not touch the composer',
      );
      await tester.tap(find.byKey(const ValueKey('room-mention-infra')));
      await tester.pump();
      expect(palette, findsNothing);
      await tester.enterText(composer, '@infra revisa backups');
      await tester.pump(const Duration(milliseconds: 400));
      final draftKey = ChatDraftStore.keyForTesting(
        'conn-test',
        'mob-room-${room.id}',
        profile: 'manager',
      );
      final beforeCancel = secureStore[draftKey];
      expect(beforeCancel, isNotNull);
      await tester.pump();
      expect(find.byKey(const ValueKey('room-routing-bar')), findsNothing);
      expect(find.text('Tarea Kanban → @infra'), findsNothing);
      final selectedSpan = tester
          .widget<TextField>(composer)
          .controller!
          .buildTextSpan(
            context: tester.element(composer),
            style: const TextStyle(),
            withComposing: true,
          );
      final mentionSpan = _flattenTextSpans(
        selectedSpan,
      ).singleWhere((span) => span.text == '@infra');
      expect(mentionSpan.style?.fontWeight, FontWeight.w800);
      expect(mentionSpan.style?.color, isNotNull);
      expect(
        mentionSpan.style?.backgroundColor,
        isNull,
        reason: 'selected mentions must not regain the legacy yellow box',
      );

      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
      expect(find.text('¿Crear tarea Kanban nativa?'), findsOneWidget);
      expect(find.text('Tablero: Hermes current board'), findsOneWidget);
      await tester.tap(find.text('Cancelar').last);
      await tester.pump(const Duration(milliseconds: 400));
      expect(taskCalls, 0);
      expect(rosterCalls, 0);
      expect(secureStore[draftKey], beforeCancel);
      expect(
        tester.widget<TextField>(composer).controller!.text,
        contains('backups'),
      );

      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('room-confirm-task')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(taskCalls, 1);
      expect(rosterCalls, 1);
      expect(captured?.workerProfile, 'infra');
      expect(captured?.idempotencyKey, contains('room:room-homelab:mention:'));
      expect(find.byKey(const ValueKey('room-routing-bar')), findsNothing);
      expect(find.text('Escribe al equipo…'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Room worker flight freezes composer routing and draft until link completes',
    (tester) async {
      const connectionId = 'conn-room-frozen';
      const sessionId = 'stored-room-frozen';
      final room = MissionRoom(
        id: 'room-frozen',
        connectionId: connectionId,
        name: 'ops',
        managerProfile: 'manager',
        memberProfiles: const ['manager', 'infra'],
        managerSessionId: sessionId,
        createdAtMs: 1,
        updatedAtMs: 1,
      );
      final store = _RecordingMissionRoomStore(room);
      final taskGate = Completer<KanbanTask>();
      var taskCalls = 0;
      await pumpChat(
        tester,
        connection: _remoteConn(connectionId),
        session: const Session(
          id: sessionId,
          title: '#ops',
          model: 'hermes-agent',
          source: 'gateway',
          messageCount: 1,
          isActive: false,
          preview: '',
          startedAt: 1,
          profile: 'manager',
        ),
        missionRoom: room,
        missionRoomStore: store,
        missionRoomTaskCreator: (_) {
          taskCalls++;
          return taskGate.future;
        },
        missionRoomWorkerRosterLoader: () async => const ['manager', 'infra'],
      );

      final composer = find.byType(TextField).last;
      await tester.enterText(composer, '@i');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('room-mention-infra')));
      await tester.pump();
      const frozenText = '@infra inspecciona el cluster';
      await tester.enterText(composer, frozenText);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('room-confirm-task')));
      await tester.pump();

      expect(taskCalls, 1);
      expect(tester.widget<TextField>(composer).enabled, isFalse);
      expect(
        tester
            .widget<AttachmentSourceMenuButton>(
              find.byKey(const ValueKey('composer-add')),
            )
            .enabled,
        isFalse,
      );
      expect(find.byTooltip('Quitar routing'), findsNothing);
      tester.widget<TextField>(composer).controller!.text = 'texto mutado';
      await tester.pump();
      expect(tester.widget<TextField>(composer).controller!.text, frozenText);
      final draftKey = ChatDraftStore.keyForTesting(
        connectionId,
        'mob-room-${room.id}',
        profile: 'manager',
      );
      final pending =
          jsonDecode(secureStore[draftKey]!) as Map<String, dynamic>;
      expect(pending['text'], frozenText);
      expect(
        pending['missionRoomTaskPhase'],
        MissionRoomTaskPhase.submitting.name,
      );

      taskGate.complete(
        const KanbanTask(
          id: 'task-frozen',
          title: 'inspecciona el cluster',
          body: frozenText,
          status: 'ready',
          assignee: 'infra',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(taskCalls, 1);
      expect(store.room.linkedTaskIds, contains('task-frozen'));
      expect(secureStore.containsKey(draftKey), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Room normal turn binds the authoritative manager session exactly once',
    (tester) async {
      final room = MissionRoom(
        id: 'room-manager-bind',
        connectionId: 'conn-room-bind',
        name: 'homelab',
        managerProfile: 'manager',
        memberProfiles: const ['manager', 'infra'],
        managerSessionId: '',
        createdAtMs: 1,
        updatedAtMs: 1,
      );
      final store = _RecordingMissionRoomStore(room);
      final bindGate = Completer<void>();
      store.bindGate = bindGate;
      final gateway = _UiRewindGateway();
      addTearDown(gateway.close);
      await pumpChat(
        tester,
        connection: _remoteConn('conn-room-bind'),
        session: Session(
          id: 'mob-room-${room.id}',
          title: '#homelab',
          model: 'hermes-agent',
          source: 'mobile-room',
          messageCount: 0,
          isActive: false,
          preview: '',
          startedAt: 1,
          profile: 'manager',
        ),
        desktopGateway: gateway,
        missionRoom: room,
        missionRoomStore: store,
      );

      final composer = find.byType(TextField).last;
      await tester.enterText(composer, 'Prepara el plan de release');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send')));
      for (var frame = 0; frame < 20 && store.bindCalls == 0; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(store.bindCalls, 1);
      expect(gateway.submissions, isEmpty);
      bindGate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(gateway.submissions, ['Prepara el plan de release']);
      expect(gateway.createConfigs.single.title, '#homelab');
      expect(gateway.createConfigs.single.hidden, isFalse);
      expect(gateway.createConfigs.single.allowTransportFallback, isFalse);
      expect(store.boundManagerSessionId, 'sess-test');
      gateway.emit('message.complete', {'text': 'Plan listo'});
      await tester.pump();
      expect(
        find.byKey(const ValueKey('mission-room-assistant-label')),
        findsOneWidget,
      );
      expect(find.text('@manager'), findsOneWidget);
      expect(find.text('>_ HERMES CONSOLE'), findsNothing);
      expect(find.byType(CompanionMessagePresence), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Room worker confirmation refreshes roster and fails closed when stale',
    (tester) async {
      final room = MissionRoom(
        id: 'room-stale-worker',
        connectionId: 'conn-stale-worker',
        name: 'homelab',
        managerProfile: 'manager',
        memberProfiles: const ['manager', 'infra'],
        managerSessionId: 'stored-manager',
        createdAtMs: 1,
        updatedAtMs: 1,
      );
      var taskCalls = 0;
      var rosterCalls = 0;
      await pumpChat(
        tester,
        connection: _remoteConn('conn-stale-worker'),
        session: Session(
          id: 'stored-manager',
          title: '#homelab',
          model: 'hermes-agent',
          source: 'gateway',
          messageCount: 1,
          isActive: false,
          preview: 'hola',
          startedAt: 1,
          profile: 'manager',
        ),
        missionRoom: room,
        missionRoomTaskCreator: (_) async {
          taskCalls++;
          return const KanbanTask(
            id: 'must-not-exist',
            title: 'stale',
            body: 'stale',
            status: 'ready',
          );
        },
        missionRoomWorkerRosterLoader: () async {
          rosterCalls++;
          return const ['manager'];
        },
      );

      final composer = find.byType(TextField).last;
      await tester.enterText(composer, '@i');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('room-mention-infra')));
      await tester.pump();
      await tester.enterText(composer, '@infra revisa backups');
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('room-confirm-task')));
      await tester.pump();

      expect(rosterCalls, 1);
      expect(taskCalls, 0);
      expect(
        find.textContaining('ya no aparece en el roster autoritativo'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(composer).controller!.text,
        contains('backups'),
      );
    },
  );

  testWidgets(
    'Room HTTP 409 reconciles with GET and stays unknown when no task matches',
    (tester) async {
      const connectionId = 'conn-room-rejected';
      const sessionId = 'stored-room-rejected';
      final room = MissionRoom(
        id: 'room-rejected',
        connectionId: connectionId,
        name: 'security',
        managerProfile: 'manager',
        memberProfiles: const ['manager', 'infra'],
        managerSessionId: sessionId,
        createdAtMs: 1,
        updatedAtMs: 1,
      );
      var createCalls = 0;
      MissionMentionIntent? attempted;
      var boardGetCount = 0;
      var dashboardPostCount = 0;
      final dashboard = DashboardClient(
        host: 'hermes.local',
        manualToken: 'dashboard-test-token',
        httpClientOverride: MockClient((request) async {
          if (request.method == 'POST') dashboardPostCount++;
          if (request.method == 'GET' &&
              request.url.path == '/api/plugins/kanban/board') {
            boardGetCount++;
          }
          if (boardGetCount < 2) {
            return http.Response(
              jsonEncode({'columns': const <Object>[]}),
              HttpStatus.ok,
            );
          }
          final original = attempted!;
          return http.Response(
            jsonEncode({
              'columns': [
                {
                  'name': 'ready',
                  'tasks': [
                    {
                      'id': 'task-original-payload',
                      'title': original.taskTitle,
                      'body': original.rawText,
                      'status': 'ready',
                      'assignee': original.workerProfile,
                      'idempotency_key': original.idempotencyKey,
                    },
                  ],
                },
              ],
            }),
            HttpStatus.ok,
          );
        }),
      );
      await pumpChat(
        tester,
        connection: _remoteConn(connectionId),
        session: const Session(
          id: sessionId,
          title: '#security',
          model: 'hermes-agent',
          source: 'gateway',
          messageCount: 1,
          isActive: false,
          preview: '',
          startedAt: 1,
          profile: 'manager',
        ),
        missionRoom: room,
        missionRoomStore: _RecordingMissionRoomStore(room),
        missionRoomTaskCreator: (intent) async {
          createCalls++;
          attempted = intent;
          throw const DashboardHttpException(409);
        },
        missionRoomWorkerRosterLoader: () async => const ['manager', 'infra'],
        missionRoomKanbanClientFactory: (connection) =>
            KanbanClient(connection, dashboardClient: dashboard),
      );

      final composer = find.byType(TextField).last;
      await tester.enterText(composer, '@i');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('room-mention-infra')));
      await tester.pump();
      await tester.enterText(composer, '@infra comprueba la política');
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('room-confirm-task')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(createCalls, 1);
      expect(boardGetCount, 1);
      expect(dashboardPostCount, 0);
      expect(
        find.textContaining(
          'resultado de la tarea anterior sigue siendo incierto',
        ),
        findsOneWidget,
      );
      final draftKey = ChatDraftStore.keyForTesting(
        connectionId,
        'mob-room-${room.id}',
        profile: 'manager',
      );
      final persisted =
          jsonDecode(secureStore[draftKey]!) as Map<String, dynamic>;
      expect(
        persisted['missionRoomTaskPhase'],
        MissionRoomTaskPhase.outcomeUnknown.name,
      );
      expect(
        tester.widget<TextField>(composer).controller!.text,
        contains('política'),
      );
      final originalText = attempted!.rawText;
      final originalIntentId = persisted['missionRoomIntentId'];
      expect(tester.widget<TextField>(composer).enabled, isFalse);

      tester.widget<TextField>(composer).controller!.text =
          '@infra payload editado que no debe reconciliar';
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<TextField>(composer).controller!.text, originalText);
      final afterEdit =
          jsonDecode(secureStore[draftKey]!) as Map<String, dynamic>;
      expect(afterEdit['text'], originalText);
      expect(afterEdit['missionRoomIntentId'], originalIntentId);

      ScaffoldMessenger.of(
        tester.element(find.byType(ChatScreen)),
      ).clearSnackBars();
      await tester.pump(const Duration(milliseconds: 500));
      ScaffoldMessenger.of(
        tester.element(find.byType(ChatScreen)),
      ).removeCurrentSnackBar();
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(boardGetCount, 2);
      expect(createCalls, 1);
      expect(dashboardPostCount, 0);
      expect(
        find.textContaining('Tarea task-original-payload recuperada'),
        findsOneWidget,
      );
    },
  );

  testWidgets('Room HTTP 409 adopts the matching task found by GET', (
    tester,
  ) async {
    const connectionId = 'conn-room-conflict-recovered';
    const sessionId = 'stored-room-conflict-recovered';
    final room = MissionRoom(
      id: 'room-conflict-recovered',
      connectionId: connectionId,
      name: 'security',
      managerProfile: 'manager',
      memberProfiles: const ['manager', 'infra'],
      managerSessionId: sessionId,
      createdAtMs: 1,
      updatedAtMs: 1,
    );
    final store = _RecordingMissionRoomStore(room);
    MissionMentionIntent? attempted;
    var boardGetCount = 0;
    var dashboardPostCount = 0;
    final dashboard = DashboardClient(
      host: 'hermes.local',
      manualToken: 'dashboard-test-token',
      httpClientOverride: MockClient((request) async {
        if (request.method == 'POST') dashboardPostCount++;
        if (request.method == 'GET' &&
            request.url.path == '/api/plugins/kanban/board') {
          boardGetCount++;
        }
        final intent = attempted!;
        return http.Response(
          jsonEncode({
            'columns': [
              {
                'name': 'ready',
                'tasks': [
                  {
                    'id': 'task-reconciled-409',
                    'title': intent.taskTitle,
                    'body': intent.rawText,
                    'status': 'ready',
                    'assignee': intent.workerProfile,
                    'idempotency_key': intent.idempotencyKey,
                  },
                ],
              },
            ],
          }),
          HttpStatus.ok,
        );
      }),
    );
    await pumpChat(
      tester,
      connection: _remoteConn(connectionId),
      session: const Session(
        id: sessionId,
        title: '#security',
        model: 'hermes-agent',
        source: 'gateway',
        messageCount: 1,
        isActive: false,
        preview: '',
        startedAt: 1,
        profile: 'manager',
      ),
      missionRoom: room,
      missionRoomStore: store,
      missionRoomTaskCreator: (intent) async {
        attempted = intent;
        throw const DashboardHttpException(409);
      },
      missionRoomWorkerRosterLoader: () async => const ['manager', 'infra'],
      missionRoomKanbanClientFactory: (connection) =>
          KanbanClient(connection, dashboardClient: dashboard),
    );

    final composer = find.byType(TextField).last;
    await tester.enterText(composer, '@i');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('room-mention-infra')));
    await tester.pump();
    await tester.enterText(composer, '@infra comprueba la política');
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('room-confirm-task')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(boardGetCount, 1);
    expect(dashboardPostCount, 0);
    expect(
      store.room.linkedTasks,
      contains(
        MissionRoomTaskLink(
          boardId: MissionRoomTaskLink.legacyCurrentBoard,
          taskId: 'task-reconciled-409',
        ),
      ),
    );
    expect(
      find.textContaining('Tarea task-reconciled-409 recuperada'),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
    expect(
      secureStore.containsKey(
        ChatDraftStore.keyForTesting(
          connectionId,
          'mob-room-${room.id}',
          profile: 'manager',
        ),
      ),
      isFalse,
    );
  });

  testWidgets(
    'Room process death converts submitting to unknown and performs zero POSTs',
    (tester) async {
      const connectionId = 'conn-room-process-death';
      const sessionId = 'stored-room-process-death';
      const recoverySessionId = 'mob-room-room-process-death';
      var postCount = 0;
      var boardGetCount = 0;
      final dashboard = DashboardClient(
        host: 'hermes.local',
        manualToken: 'dashboard-test-token',
        httpClientOverride: MockClient((request) async {
          if (request.method == 'POST') postCount++;
          if (request.method == 'GET' &&
              request.url.path == '/api/plugins/kanban/board') {
            boardGetCount++;
          }
          return http.Response(
            jsonEncode({'columns': const <Object>[]}),
            HttpStatus.ok,
          );
        }),
      );
      final connection = SavedConnection(
        id: connectionId,
        label: 'Room process death',
        host: '192.168.255.254',
        port: 8642,
        apiKey: 'test-only',
        kind: InstanceKind.vps,
        dashboardUrl: 'http://hermes.local:9119',
        dashboardAuthMode: AuthMode.sessionToken,
      );
      final room = MissionRoom(
        id: 'room-process-death',
        connectionId: connectionId,
        name: 'release',
        managerProfile: 'manager',
        memberProfiles: const ['manager', 'infra'],
        managerSessionId: sessionId,
        createdAtMs: 1,
        updatedAtMs: 1,
      );
      final recoveryDraftKey = ChatDraftStore.keyForTesting(
        connectionId,
        recoverySessionId,
        profile: 'manager',
      );
      secureStore[recoveryDraftKey] = jsonEncode({
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'text': '@infra valida la release',
        'attachments': const <Object>[],
        'missionRoomIntentId': 'intent-after-death',
        'missionRoomWorkerProfile': 'infra',
        'missionRoomBoardId': MissionRoomTaskLink.legacyCurrentBoard,
        'missionRoomTaskPhase': MissionRoomTaskPhase.submitting.name,
      });
      await pumpChat(
        tester,
        connection: connection,
        session: const Session(
          id: sessionId,
          title: '#release',
          model: 'hermes-agent',
          source: 'gateway',
          messageCount: 1,
          isActive: false,
          preview: '',
          startedAt: 1,
          profile: 'manager',
        ),
        missionRoom: room,
        missionRoomStore: _RecordingMissionRoomStore(room),
        missionRoomKanbanClientFactory: (connection) =>
            KanbanClient(connection, dashboardClient: dashboard),
      );
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();

      expect(postCount, 0);
      expect(boardGetCount, 1);
      final persisted =
          jsonDecode(secureStore[recoveryDraftKey]!) as Map<String, dynamic>;
      expect(
        persisted['missionRoomTaskPhase'],
        MissionRoomTaskPhase.outcomeUnknown.name,
      );
      expect(
        secureStore.containsKey(
          ChatDraftStore.keyForTesting(
            connectionId,
            sessionId,
            profile: 'manager',
          ),
        ),
        isFalse,
      );
    },
  );

  testWidgets('Room manager turn fails closed on the local Mobile Bridge', (
    tester,
  ) async {
    final connection = SavedConnection(
      id: 'conn-local-room',
      label: 'Local room',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'test-only',
      kind: InstanceKind.localhost,
      onDeviceLoopback: true,
    );
    final room = MissionRoom(
      id: 'room-local',
      connectionId: connection.id,
      name: 'local',
      managerProfile: 'manager',
      memberProfiles: const ['manager'],
      managerSessionId: '',
      createdAtMs: 1,
      updatedAtMs: 1,
    );
    final chat = await pumpChat(
      tester,
      connection: connection,
      session: Session(
        id: 'mob-room-room-local',
        title: '#local',
        model: 'hermes-agent',
        source: 'mobile-room',
        messageCount: 0,
        isActive: false,
        preview: '',
        startedAt: 1,
        profile: 'manager',
      ),
      missionRoom: room,
    );

    final composer = find.byType(TextField).last;
    await tester.enterText(composer, 'Prepara el plan');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();

    expect(
      chat.messages.where((message) => message['role'] == 'user'),
      isEmpty,
    );
    expect(
      find.textContaining('no puede demostrar una sesión durable'),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(composer).controller!.text,
      'Prepara el plan',
    );
  });

  testWidgets('Room accepts a modern lifecycle Gateway reached via localhost', (
    tester,
  ) async {
    final connection = SavedConnection(
      id: 'conn-adb-reverse-room',
      label: 'ADB reverse Room',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'test-only',
      kind: InstanceKind.localhost,
    );
    final room = MissionRoom(
      id: 'room-adb-reverse',
      connectionId: connection.id,
      name: 'android-qa',
      managerProfile: 'manager',
      memberProfiles: const ['manager'],
      managerSessionId: 'stored-adb-room',
      createdAtMs: 1,
      updatedAtMs: 1,
    );
    final gateway = _UiRewindGateway();
    addTearDown(gateway.close);
    await pumpChat(
      tester,
      connection: connection,
      session: const Session(
        id: 'stored-adb-room',
        title: '#android-qa',
        model: 'hermes-agent',
        source: 'cli',
        messageCount: 1,
        isActive: false,
        preview: '',
        startedAt: 1,
        profile: 'manager',
      ),
      desktopGateway: gateway,
      missionRoom: room,
      missionRoomStore: _RecordingMissionRoomStore(room),
    );

    final composer = find.byType(TextField).last;
    await tester.enterText(composer, 'Ejecuta la QA por adb reverse');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();

    expect(gateway.submissions, ['Ejecuta la QA por adb reverse']);
    gateway.emit('message.complete', {'text': 'QA lista'});
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
