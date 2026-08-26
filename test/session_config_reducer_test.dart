import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_config.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/session_config_reducer.dart';

SessionConfigScope _scope({
  String connection = 'connection-a',
  String stored = 'stored-a',
  String runtime = 'runtime-a',
  String profile = 'default',
  int sessionEpoch = 1,
}) => SessionConfigScope(
  connectionId: connection,
  storedSessionId: stored,
  runtimeSessionId: runtime,
  profileName: profile,
  sessionEpoch: sessionEpoch,
);

SessionModelConfigValue _model(String model, String provider) =>
    SessionModelConfigValue.requested(
      DesktopModelSelection(modelId: model, providerSlug: provider),
    );

SessionConfigReducerState _observe(
  SessionConfigReducerState state,
  SessionConfigScope scope, {
  required int infoEpoch,
  required int observedRequestEpoch,
  String? model,
  String? provider,
  String? reasoning,
  bool? fast,
}) => SessionConfigReducer.reduce(
  state,
  SessionConfigInfoObserved(
    scope: scope,
    infoEpoch: infoEpoch,
    observedRequestEpoch: observedRequestEpoch,
    info: SessionConfigAuthoritativeInfo(
      model: model,
      provider: provider,
      reasoningEffort: reasoning,
      fast: fast,
    ),
  ),
);

SessionConfigReducerState _start(
  SessionConfigReducerState state,
  SessionConfigScope scope,
  SessionConfigValue value,
  int requestEpoch,
) => SessionConfigReducer.reduce(
  state,
  SessionConfigSendStarted(
    scope: scope,
    requestedValue: value,
    requestEpoch: requestEpoch,
  ),
);

void main() {
  test('sending captura el efectivo anterior sin mutarlo', () {
    final scope = _scope();
    var state = _observe(
      const SessionConfigReducerState.empty(),
      scope,
      infoEpoch: 0,
      observedRequestEpoch: 0,
      model: 'model-a',
      provider: 'provider-a',
      reasoning: 'medium',
      fast: false,
    );
    final requested = _model('model-b', 'provider-b');
    state = _start(state, scope, requested, 1);

    final change = state.changeFor(scope, DesktopSessionConfigKey.model)!;
    expect(change.status, SessionConfigChangeStatus.sending);
    expect(change.requestEpoch, 1);
    expect(change.requestedValue, requested);
    expect(change.previousEffectiveValue, _model('model-a', 'provider-a'));
    expect(change.displayValue, requested);
    expect(state[scope]!.effective.model, 'model-a');
    expect(state[scope]!.effective.provider, 'provider-a');
  });

  test('ACK acepta el comando y solo session.info confirma el efectivo', () {
    final scope = _scope();
    var state = _observe(
      const SessionConfigReducerState.empty(),
      scope,
      infoEpoch: 0,
      observedRequestEpoch: 0,
      model: 'model-a',
      provider: 'provider-a',
    );
    state = _start(state, scope, _model('model-b', 'provider-b'), 1);
    state = SessionConfigReducer.reduce(
      state,
      SessionConfigRpcAccepted(
        scope: scope,
        requestEpoch: 1,
        result: const DesktopConfigSetResult(
          key: DesktopSessionConfigKey.model,
          value: 'model-b',
          warning: 'bounded warning',
        ),
      ),
    );

    expect(
      state.changeFor(scope, DesktopSessionConfigKey.model)!.status,
      SessionConfigChangeStatus.accepted,
    );
    expect(state[scope]!.effective.model, 'model-a');

    state = _observe(
      state,
      scope,
      infoEpoch: 1,
      observedRequestEpoch: 1,
      model: 'model-b',
      provider: 'provider-b',
    );
    final confirmed = state.changeFor(scope, DesktopSessionConfigKey.model)!;
    expect(confirmed.status, SessionConfigChangeStatus.confirmed);
    expect(confirmed.authoritativeValue, _model('model-b', 'provider-b'));
    expect(confirmed.requestedWasApplied, isTrue);
    expect(state[scope]!.effective.model, 'model-b');

    final terminal = state;
    state = SessionConfigReducer.reduce(
      state,
      SessionConfigRpcRejected(
        scope: scope,
        key: DesktopSessionConfigKey.model,
        requestEpoch: 1,
        failureKind: SessionConfigFailureKind.rejected,
      ),
    );
    expect(identical(state, terminal), isTrue);
  });

  test('confirmRequired revierte y el cambio de scope cancela la puerta', () {
    final scope = _scope();
    var state = _observe(
      const SessionConfigReducerState.empty(),
      scope,
      infoEpoch: 0,
      observedRequestEpoch: 0,
      model: 'model-a',
      provider: 'provider-a',
    );
    state = _start(state, scope, _model('model-costly', 'provider-b'), 1);
    state = SessionConfigReducer.reduce(
      state,
      SessionConfigRpcAccepted(
        scope: scope,
        requestEpoch: 1,
        result: const DesktopConfigSetResult(
          key: DesktopSessionConfigKey.model,
          value: 'model-a',
          confirmRequired: true,
          confirmMessage: 'This model may be expensive',
        ),
      ),
    );

    var change = state.changeFor(scope, DesktopSessionConfigKey.model)!;
    expect(change.status, SessionConfigChangeStatus.confirmRequired);
    expect(change.displayValue, _model('model-a', 'provider-a'));
    expect(change.confirmMessage, 'This model may be expensive');
    expect(state[scope]!.effective.model, 'model-a');

    state = SessionConfigReducer.reduce(
      state,
      SessionConfigScopeSuperseded(scope),
    );
    change = state.changeFor(scope, DesktopSessionConfigKey.model)!;
    expect(change.status, SessionConfigChangeStatus.superseded);
    expect(change.confirmMessage, isNull);
    expect(state[scope]!.isSuperseded, isTrue);

    final retired = state;
    state = _observe(
      state,
      scope,
      infoEpoch: 1,
      observedRequestEpoch: 1,
      model: 'late-model',
      provider: 'late-provider',
    );
    expect(identical(state, retired), isTrue);
  });

  test('rejected conserva el efectivo y expone solo error tipado', () {
    final scope = _scope();
    var state = _observe(
      const SessionConfigReducerState.empty(),
      scope,
      infoEpoch: 0,
      observedRequestEpoch: 0,
      fast: false,
    );
    state = _start(state, scope, const SessionFastConfigValue(true), 1);
    state = SessionConfigReducer.reduce(
      state,
      SessionConfigRpcRejected(
        scope: scope,
        key: DesktopSessionConfigKey.fast,
        requestEpoch: 1,
        failureKind: SessionConfigFailureKind.unsupported,
      ),
    );

    final change = state.changeFor(scope, DesktopSessionConfigKey.fast)!;
    expect(change.status, SessionConfigChangeStatus.rejected);
    expect(change.failureKind, SessionConfigFailureKind.unsupported);
    expect(change.displayValue, const SessionFastConfigValue(false));
    expect(state[scope]!.effective.fast, isFalse);
  });

  test('timedOut queda ambiguo hasta reconciliar con session.info nuevo', () {
    final scope = _scope();
    var state = _observe(
      const SessionConfigReducerState.empty(),
      scope,
      infoEpoch: 0,
      observedRequestEpoch: 0,
      fast: false,
    );
    state = _start(state, scope, const SessionFastConfigValue(true), 1);
    state = SessionConfigReducer.reduce(
      state,
      SessionConfigTimedOut(
        scope: scope,
        key: DesktopSessionConfigKey.fast,
        requestEpoch: 1,
      ),
    );
    var change = state.changeFor(scope, DesktopSessionConfigKey.fast)!;
    expect(change.status, SessionConfigChangeStatus.timedOut);
    expect(change.failureKind, SessionConfigFailureKind.timeout);
    expect(change.displayValue, const SessionFastConfigValue(false));

    state = _observe(
      state,
      scope,
      infoEpoch: 1,
      observedRequestEpoch: 0,
      fast: true,
    );
    change = state.changeFor(scope, DesktopSessionConfigKey.fast)!;
    expect(change.status, SessionConfigChangeStatus.timedOut);
    expect(state[scope]!.effective.fast, isFalse);

    final beforeLateAck = state;
    state = SessionConfigReducer.reduce(
      state,
      SessionConfigRpcAccepted(
        scope: scope,
        requestEpoch: 1,
        result: const DesktopConfigSetResult(
          key: DesktopSessionConfigKey.fast,
          value: 'fast',
        ),
      ),
    );
    expect(identical(state, beforeLateAck), isTrue);

    state = _observe(
      state,
      scope,
      infoEpoch: 2,
      observedRequestEpoch: 1,
      fast: true,
    );
    change = state.changeFor(scope, DesktopSessionConfigKey.fast)!;
    expect(change.status, SessionConfigChangeStatus.confirmed);
    expect(change.requestedWasApplied, isTrue);
    expect(state[scope]!.effective.fast, isTrue);
  });

  test('dos elecciones rápidas ignoran ACK e info de la primera', () {
    final scope = _scope();
    var state = _observe(
      const SessionConfigReducerState.empty(),
      scope,
      infoEpoch: 0,
      observedRequestEpoch: 0,
      model: 'model-a',
      provider: 'provider-a',
    );
    state = _start(state, scope, _model('model-b', 'provider-b'), 1);
    state = _start(state, scope, _model('model-c', 'provider-c'), 2);
    final latest = state;

    state = SessionConfigReducer.reduce(
      state,
      SessionConfigRpcAccepted(
        scope: scope,
        requestEpoch: 1,
        result: const DesktopConfigSetResult(
          key: DesktopSessionConfigKey.model,
          value: 'model-b',
        ),
      ),
    );
    expect(identical(state, latest), isTrue);

    state = _observe(
      state,
      scope,
      infoEpoch: 1,
      // El payload tardío de A se recibe cuando B ya es el epoch vigente.
      observedRequestEpoch: 2,
      model: 'model-b',
      provider: 'provider-b',
    );
    expect(state[scope]!.effective.model, 'model-a');
    expect(
      state.changeFor(scope, DesktopSessionConfigKey.model)!.requestedValue,
      _model('model-c', 'provider-c'),
    );
    expect(
      state.changeFor(scope, DesktopSessionConfigKey.model)!.status,
      SessionConfigChangeStatus.sending,
    );

    state = SessionConfigReducer.reduce(
      state,
      SessionConfigRpcAccepted(
        scope: scope,
        requestEpoch: 2,
        result: const DesktopConfigSetResult(
          key: DesktopSessionConfigKey.model,
          value: 'model-c',
        ),
      ),
    );
    state = _observe(
      state,
      scope,
      infoEpoch: 2,
      observedRequestEpoch: 2,
      model: 'model-c',
      provider: 'provider-c',
    );
    expect(state[scope]!.effective.model, 'model-c');
    expect(
      state.changeFor(scope, DesktopSessionConfigKey.model)!.status,
      SessionConfigChangeStatus.confirmed,
    );
  });

  test('connection, stored, runtime, perfil y epoch aíslan homónimos', () {
    final a = _scope();
    final otherConnection = _scope(connection: 'connection-b');
    final otherStored = _scope(stored: 'stored-b');
    final otherRuntime = _scope(runtime: 'runtime-b');
    final otherProfile = _scope(profile: 'work');
    final nextSessionEpoch = _scope(sessionEpoch: 2);
    var state = const SessionConfigReducerState.empty();
    state = _observe(
      state,
      a,
      infoEpoch: 0,
      observedRequestEpoch: 0,
      reasoning: 'high',
    );
    state = _observe(
      state,
      otherConnection,
      infoEpoch: 0,
      observedRequestEpoch: 0,
      reasoning: 'low',
    );
    state = _observe(
      state,
      otherStored,
      infoEpoch: 0,
      observedRequestEpoch: 0,
      reasoning: 'xhigh',
    );
    state = _observe(
      state,
      otherRuntime,
      infoEpoch: 0,
      observedRequestEpoch: 0,
      reasoning: 'minimal',
    );
    state = _observe(
      state,
      otherProfile,
      infoEpoch: 0,
      observedRequestEpoch: 0,
      reasoning: 'medium',
    );
    state = _observe(
      state,
      nextSessionEpoch,
      infoEpoch: 0,
      observedRequestEpoch: 0,
      reasoning: 'ultra',
    );

    state = _start(
      state,
      a,
      SessionReasoningConfigValue.requested(DesktopReasoningEffort.max),
      1,
    );
    state = SessionConfigReducer.reduce(
      state,
      SessionConfigRequestSuperseded(
        scope: a,
        key: DesktopSessionConfigKey.reasoning,
        requestEpoch: 1,
      ),
    );

    expect(
      state.changeFor(a, DesktopSessionConfigKey.reasoning)!.status,
      SessionConfigChangeStatus.superseded,
    );
    expect(state[otherConnection]!.effective.reasoningEffort, 'low');
    expect(state[otherStored]!.effective.reasoningEffort, 'xhigh');
    expect(state[otherRuntime]!.effective.reasoningEffort, 'minimal');
    expect(state[otherProfile]!.effective.reasoningEffort, 'medium');
    expect(state[nextSessionEpoch]!.effective.reasoningEffort, 'ultra');
    expect(
      state.changeFor(otherConnection, DesktopSessionConfigKey.reasoning),
      isNull,
    );
  });

  test('campos ausentes no borran efectivo ni confirman otra clave', () {
    final scope = _scope();
    var state = _observe(
      const SessionConfigReducerState.empty(),
      scope,
      infoEpoch: 0,
      observedRequestEpoch: 0,
      model: 'model-a',
      provider: 'provider-a',
      reasoning: 'future-reasoning-level',
      fast: false,
    );
    state = _start(state, scope, _model('model-b', 'provider-b'), 1);
    state = _observe(
      state,
      scope,
      infoEpoch: 1,
      observedRequestEpoch: 1,
      reasoning: 'ultra',
      fast: true,
    );

    expect(state[scope]!.effective.model, 'model-a');
    expect(state[scope]!.effective.provider, 'provider-a');
    expect(state[scope]!.effective.reasoningEffort, 'ultra');
    expect(state[scope]!.effective.fast, isTrue);
    expect(
      state.changeFor(scope, DesktopSessionConfigKey.model)!.status,
      SessionConfigChangeStatus.sending,
    );
  });

  test('proyecta session.info sin conservar payloads crudos', () {
    const rawMarker = 'raw-value-that-must-not-survive';
    final runtimeInfo = DesktopSessionRuntimeInfo.fromJson(const {
      'model': 'model-safe',
      'provider': 'provider-safe',
      'reasoning_effort': 'future-level',
      'fast': true,
      'system_prompt': rawMarker,
      'unexpected': rawMarker,
    });
    expect(runtimeInfo.raw['unexpected'], rawMarker);

    final projection = SessionConfigAuthoritativeInfo.fromRuntimeInfo(
      runtimeInfo,
    );
    final scope = _scope();
    final state = SessionConfigReducer.reduce(
      const SessionConfigReducerState.empty(),
      SessionConfigInfoObserved(
        scope: scope,
        infoEpoch: 0,
        observedRequestEpoch: 0,
        info: projection,
      ),
    );

    expect(state[scope]!.effective.model, 'model-safe');
    expect(state[scope]!.effective.reasoningEffort, 'future-level');
    expect(state.toString(), isNot(contains(rawMarker)));
    expect(state[scope]!.effective.toString(), isNot(contains(rawMarker)));
  });

  test('success malformado se vuelve rechazo tipado con rollback', () {
    final scope = _scope();
    var state = _observe(
      const SessionConfigReducerState.empty(),
      scope,
      infoEpoch: 0,
      observedRequestEpoch: 0,
      reasoning: 'medium',
    );
    state = _start(
      state,
      scope,
      SessionReasoningConfigValue.requested(DesktopReasoningEffort.high),
      1,
    );
    state = SessionConfigReducer.reduce(
      state,
      SessionConfigRpcAccepted(
        scope: scope,
        requestEpoch: 1,
        result: const DesktopConfigSetResult(
          key: DesktopSessionConfigKey.reasoning,
          value: '',
        ),
      ),
    );

    final change = state.changeFor(scope, DesktopSessionConfigKey.reasoning)!;
    expect(change.status, SessionConfigChangeStatus.rejected);
    expect(change.failureKind, SessionConfigFailureKind.invalidResponse);
    expect(
      change.displayValue,
      SessionReasoningConfigValue.effective('medium'),
    );
  });
}
