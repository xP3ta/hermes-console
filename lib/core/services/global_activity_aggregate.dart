// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/desktop_active_session.dart';
import 'tui_gateway_client.dart';

/// Closed, display-safe vocabulary shared by Home, chat and badges.
enum GlobalActivityPhase {
  preparing,
  generating,
  usingTools,
  delegated,
  backgroundWork,
  compacting,
  waitingForUser,
  completing,
  completed,
  interrupted,
  failed,
  unknown,
}

enum GlobalActivityAuthority { journal, roster, snapshot, event, terminal }

@immutable
final class GlobalActivityScope {
  const GlobalActivityScope({
    required this.connectionId,
    required this.profile,
    required this.durableSessionId,
    required this.runtimeSessionId,
    required this.replayEpoch,
  });

  final String connectionId;
  final String profile;
  final String durableSessionId;
  final String runtimeSessionId;
  final String replayEpoch;

  String get durableKey => '$connectionId\u0000$profile\u0000$durableSessionId';
  String get exactKey => '$durableKey\u0000$runtimeSessionId\u0000$replayEpoch';
}

@immutable
final class GlobalActivity {
  const GlobalActivity({
    required this.scope,
    required this.phase,
    required this.terminal,
    required this.requiresAction,
    required this.toolCount,
    required this.subagentCount,
    required this.processCount,
    required this.observedAt,
    required this.authority,
    required this.stale,
    this.sequence,
  });

  final GlobalActivityScope scope;
  final GlobalActivityPhase phase;
  final bool terminal;
  final bool requiresAction;
  final int toolCount;
  final int subagentCount;
  final int processCount;
  final DateTime observedAt;
  final GlobalActivityAuthority authority;
  final bool stale;
  final int? sequence;

  bool get active =>
      !terminal &&
      switch (phase) {
        GlobalActivityPhase.completed ||
        GlobalActivityPhase.interrupted ||
        GlobalActivityPhase.failed => false,
        _ => true,
      };

  GlobalActivity copyWith({
    GlobalActivityPhase? phase,
    bool? terminal,
    bool? requiresAction,
    int? toolCount,
    int? subagentCount,
    int? processCount,
    DateTime? observedAt,
    GlobalActivityAuthority? authority,
    bool? stale,
    int? sequence,
    bool clearSequence = false,
  }) => GlobalActivity(
    scope: scope,
    phase: phase ?? this.phase,
    terminal: terminal ?? this.terminal,
    requiresAction: requiresAction ?? this.requiresAction,
    toolCount: toolCount ?? this.toolCount,
    subagentCount: subagentCount ?? this.subagentCount,
    processCount: processCount ?? this.processCount,
    observedAt: observedAt ?? this.observedAt,
    authority: authority ?? this.authority,
    stale: stale ?? this.stale,
    sequence: clearSequence ? null : sequence ?? this.sequence,
  );
}

/// The sole multi-session reducer. It stores no free-form producer payload.
final class GlobalActivityAggregate extends ChangeNotifier {
  // Public API intentionally keeps the parameter name `journal`.
  GlobalActivityAggregate({
    required GlobalActivityJournal journal,
    DateTime Function()? now,
    void Function(GlobalActivityScope scope, GlobalActivityPhase phase)?
    onTerminal,
  }) : _journal = journal,
       _now = now ?? DateTime.now,
       _onTerminal = onTerminal;

  GlobalActivityAggregate.inMemory({
    DateTime Function()? now,
    void Function(GlobalActivityScope scope, GlobalActivityPhase phase)?
    onTerminal,
  }) : _journal = null,
       _now = now ?? DateTime.now,
       _onTerminal = onTerminal;

  final DateTime Function() _now;
  final GlobalActivityJournal? _journal;

  /// Fired once per busy→terminal transition proven by an authoritative
  /// gateway event (never by a roster entry merely disappearing — that is
  /// ambiguous, not proof). Consumers use this to notify without duplicating
  /// the phase classification above.
  final void Function(GlobalActivityScope scope, GlobalActivityPhase phase)?
  _onTerminal;
  final Map<String, GlobalActivity> _byDurable = {};
  final Map<String, int> _terminalRosterGeneration = {};
  final Map<String, int> _rosterGeneration = {};
  final Map<String, int> _nonBusyRosterStreak = {};
  static const staleLivenessCeiling = Duration(minutes: 1);
  // Only `markTransportStale` (a transport-level disconnect) or a terminal
  // event ever set `stale`. A session whose backend went quiet without
  // either — its sandbox cleaned up after inactivity, no more roster/process
  // updates, but the socket itself never dropped — would otherwise claim
  // liveness forever from its last observation. This is the same fallback
  // idea as the durable compression fence: no signal ever arriving is not
  // proof of "still running", so an activity nobody has updated in this long
  // stops claiming it, same as an explicit stale mark past its own ceiling.
  static const silentLivenessCeiling = Duration(minutes: 15);
  bool _disposed = false;

  Future<void> initialize({String? connectionId, String? profile}) async {
    final restored =
        await _journal?.readEntries(
          connectionId: connectionId,
          profile: profile,
        ) ??
        const <GlobalActivity>[];
    for (final activity in restored) {
      _byDurable[activity.scope.durableKey] = activity;
    }
    if (restored.isNotEmpty) _changed(persist: false);
  }

  Future<void> flushJournal() => _journal?.flush() ?? Future<void>.value();

  Iterable<GlobalActivity> get activities =>
      List<GlobalActivity>.unmodifiable(_byDurable.values);

  String _ownerKey(String connectionId, String profile) =>
      '$connectionId\u0000$profile';

  int beginRosterRequest(String connectionId, String profile) {
    final key = _ownerKey(connectionId, profile);
    return _rosterGeneration[key] = (_rosterGeneration[key] ?? 0) + 1;
  }

  GlobalActivity? activityFor(
    String connectionId,
    String profile,
    String durableSessionId,
  ) =>
      _byDurable[GlobalActivityScope(
        connectionId: connectionId,
        profile: profile,
        durableSessionId: durableSessionId,
        runtimeSessionId: '',
        replayEpoch: '',
      ).durableKey];

  bool isActive(String connectionId, String profile, String durableSessionId) {
    final activity = activityFor(connectionId, profile, durableSessionId);
    if (activity == null || !activity.active) return false;
    final age = _now().toUtc().difference(activity.observedAt);
    if (activity.stale) return age <= staleLivenessCeiling;
    return age <= silentLivenessCeiling;
  }

  void applyRoster({
    required String connectionId,
    required String profile,
    required String replayEpoch,
    required int requestGeneration,
    required DesktopActiveSessionList roster,
  }) {
    final owner = _ownerKey(connectionId, profile);
    if (_rosterGeneration[owner] != requestGeneration) return;
    if (roster.hasMalformedRows) {
      markTransportStale(connectionId, profile);
      return;
    }
    final now = _now().toUtc();
    final rowsByDurable = <String, DesktopActiveSession>{};
    for (final row in roster.sessions) {
      final durable = row.storedSessionId;
      if (durable == null) continue;
      final prior = rowsByDurable[durable];
      if (prior == null ||
          (!rosterStatusIsBusy(prior.status) &&
              rosterStatusIsBusy(row.status))) {
        rowsByDurable[durable] = row;
      }
    }
    final observed = <String>{};
    for (final entry in rowsByDurable.entries) {
      final row = entry.value;
      final scope = GlobalActivityScope(
        connectionId: connectionId,
        profile: profile,
        durableSessionId: entry.key,
        runtimeSessionId: row.runtimeSessionId,
        replayEpoch: replayEpoch,
      );
      observed.add(scope.durableKey);
      final terminalGeneration = _terminalRosterGeneration[scope.exactKey];
      if (terminalGeneration != null &&
          requestGeneration <= terminalGeneration) {
        _byDurable.remove(scope.durableKey);
        _nonBusyRosterStreak.remove(scope.durableKey);
        continue;
      }
      if (terminalGeneration != null) {
        _terminalRosterGeneration.remove(scope.exactKey);
      }
      final prior = _byDurable[scope.durableKey];
      final sameIncarnation = prior?.scope.exactKey == scope.exactKey;
      if (!rosterStatusIsBusy(row.status)) {
        _recordNonBusyRoster(scope.durableKey);
        continue;
      }
      _nonBusyRosterStreak.remove(scope.durableKey);
      // A roster proves liveness, but never downgrades newer exact-incarnation
      // event detail. A recycled runtime starts from the general public phase.
      if (sameIncarnation &&
          prior != null &&
          (prior.authority == GlobalActivityAuthority.event ||
              prior.authority == GlobalActivityAuthority.terminal)) {
        _byDurable[scope.durableKey] = prior.copyWith(stale: false);
      } else {
        _byDurable[scope.durableKey] = GlobalActivity(
          scope: scope,
          phase: _phaseFromRoster(row.status),
          terminal: false,
          requiresAction:
              _phaseFromRoster(row.status) ==
              GlobalActivityPhase.waitingForUser,
          toolCount: 0,
          subagentCount: 0,
          processCount: 0,
          observedAt: now,
          authority: GlobalActivityAuthority.roster,
          stale: false,
        );
      }
    }
    for (final entry in _byDurable.entries.toList()) {
      final activity = entry.value;
      if (activity.scope.connectionId == connectionId &&
          activity.scope.profile == profile &&
          !observed.contains(entry.key)) {
        _recordNonBusyRoster(entry.key);
      }
    }
    _changed();
  }

  void _recordNonBusyRoster(String durableKey) {
    if (!_byDurable.containsKey(durableKey) &&
        !_nonBusyRosterStreak.containsKey(durableKey)) {
      return;
    }
    final streak = (_nonBusyRosterStreak[durableKey] ?? 0) + 1;
    if (streak < 2) {
      _nonBusyRosterStreak[durableKey] = streak;
      return;
    }
    _nonBusyRosterStreak.remove(durableKey);
    _byDurable.remove(durableKey);
  }

  void observeEvent({
    required GlobalActivityScope scope,
    required TuiGatewayEvent event,
  }) {
    if (event.sessionId != scope.runtimeSessionId) return;
    final current = _byDurable[scope.durableKey];
    if (current != null && current.scope.exactKey != scope.exactKey) return;
    final sequence = event.sequence;
    if (current?.sequence != null &&
        sequence != null &&
        sequence <= current!.sequence!) {
      return;
    }
    final reduction = _reduceEvent(event.type, event.payload, current);
    if (reduction == null) return;
    _nonBusyRosterStreak.remove(scope.durableKey);
    if (reduction.terminal) {
      // Terminal evidence is absorbing for this incarnation and must not be
      // persisted or revived by an older roster/journal.
      _terminalRosterGeneration[scope.exactKey] =
          _rosterGeneration[_ownerKey(scope.connectionId, scope.profile)] ?? 0;
      while (_terminalRosterGeneration.length > 256) {
        _terminalRosterGeneration.remove(_terminalRosterGeneration.keys.first);
      }
      _byDurable.remove(scope.durableKey);
      // Only a proven busy→terminal transition is notify-worthy; a terminal
      // event with no prior tracked activity (already removed, or one we
      // never saw as busy) carries nothing new to tell the user.
      if (current != null) _onTerminal?.call(scope, reduction.phase);
      _changed();
      return;
    }
    _byDurable[scope.durableKey] = GlobalActivity(
      scope: scope,
      phase: reduction.phase,
      terminal: false,
      requiresAction: reduction.requiresAction,
      toolCount: reduction.toolCount,
      subagentCount: reduction.subagentCount,
      processCount: reduction.processCount,
      observedAt: _now().toUtc(),
      authority: GlobalActivityAuthority.event,
      stale: false,
      sequence: sequence ?? current?.sequence,
    );
    _changed();
  }

  /// Routes a transport event only to one roster-proven exact runtime.
  bool observeGatewayEvent({
    required String connectionId,
    required String profile,
    required TuiGatewayEvent event,
  }) {
    final matches = _byDurable.values
        .where(
          (value) =>
              value.scope.connectionId == connectionId &&
              value.scope.profile == profile &&
              value.scope.runtimeSessionId == event.sessionId,
        )
        .toList(growable: false);
    if (matches.length != 1) return false;
    observeEvent(scope: matches.single.scope, event: event);
    return true;
  }

  void beginRecovery(String connectionId, String profile) {
    // Retain the last public projection while the authoritative cut is rebuilt.
    markTransportStale(connectionId, profile);
  }

  void applyRecoverySnapshot({
    required GlobalActivityScope scope,
    required bool running,
    required bool waitingForUser,
    required bool replayTruncated,
    required int processCount,
    String? rosterStatus,
  }) {
    if (processCount < 0 || processCount > 999) return;
    if (!running) {
      clearSession(scope.connectionId, scope.profile, scope.durableSessionId);
      return;
    }
    _nonBusyRosterStreak.remove(scope.durableKey);
    // Un replay truncado pierde el detalle, pero una fila busy del roster ya
    // prueba la fase general (trabajando/esperando), como el sidebar de
    // Desktop. Sin roster busy, la fase queda `unknown`.
    final rosterPhase = rosterStatusIsBusy(rosterStatus)
        ? _phaseFromRoster(rosterStatus)
        : null;
    _byDurable[scope.durableKey] = GlobalActivity(
      scope: scope,
      phase: replayTruncated
          ? rosterPhase ?? GlobalActivityPhase.unknown
          : waitingForUser
          ? GlobalActivityPhase.waitingForUser
          : processCount > 0
          ? GlobalActivityPhase.backgroundWork
          : GlobalActivityPhase.generating,
      terminal: false,
      requiresAction: waitingForUser,
      toolCount: 0,
      subagentCount: 0,
      processCount: processCount,
      observedAt: _now().toUtc(),
      authority: GlobalActivityAuthority.snapshot,
      stale: replayTruncated,
    );
    _changed();
  }

  void applyProcessList({
    required GlobalActivityScope scope,
    required int activeProcessCount,
  }) {
    if (activeProcessCount < 0 || activeProcessCount > 999) return;
    final current = _byDurable[scope.durableKey];
    if (current == null ||
        current.scope.exactKey != scope.exactKey ||
        current.terminal) {
      return;
    }
    _byDurable[scope.durableKey] = current.copyWith(
      phase: activeProcessCount > 0
          ? GlobalActivityPhase.backgroundWork
          : GlobalActivityPhase.generating,
      processCount: activeProcessCount,
      observedAt: _now().toUtc(),
      authority: GlobalActivityAuthority.snapshot,
      stale: false,
    );
    _changed();
  }

  void markTransportStale(String connectionId, String profile) {
    var changed = false;
    for (final entry in _byDurable.entries.toList()) {
      final value = entry.value;
      if (value.scope.connectionId == connectionId &&
          value.scope.profile == profile &&
          !value.stale) {
        _byDurable[entry.key] = value.copyWith(stale: true);
        changed = true;
      }
    }
    if (changed) _changed();
  }

  void clearSession(String connectionId, String profile, String durableId) {
    final durableKey = GlobalActivityScope(
      connectionId: connectionId,
      profile: profile,
      durableSessionId: durableId,
      runtimeSessionId: '',
      replayEpoch: '',
    ).durableKey;
    final removed = _byDurable.remove(durableKey);
    _nonBusyRosterStreak.remove(durableKey);
    _terminalRosterGeneration.removeWhere(
      (key, _) =>
          key.startsWith('$connectionId\u0000$profile\u0000$durableId\u0000'),
    );
    if (removed != null) _changed();
  }

  void clearProfile(String connectionId, String profile) {
    final before = _byDurable.length;
    _byDurable.removeWhere(
      (_, value) =>
          value.scope.connectionId == connectionId &&
          value.scope.profile == profile,
    );
    _terminalRosterGeneration.removeWhere(
      (key, _) => key.startsWith('$connectionId\u0000$profile\u0000'),
    );
    _nonBusyRosterStreak.removeWhere(
      (key, _) => key.startsWith('$connectionId\u0000$profile\u0000'),
    );
    if (before != _byDurable.length) _changed();
  }

  void _changed({bool persist = true}) {
    if (persist) _journal?.replace(_byDurable.values);
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Encrypted, bounded journal containing only the closed public projection.
final class GlobalActivityJournal {
  // Public dependency-injection names are intentionally `read` and `write`.
  GlobalActivityJournal({
    required Future<String?> Function() read,
    required Future<void> Function(String value) write,
    DateTime Function()? now,
    this.maxEntries = 128,
    this.ttl = const Duration(hours: 24),
  }) : _read = read,
       _write = write,
       _now = now ?? DateTime.now;

  factory GlobalActivityJournal.secure({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) => GlobalActivityJournal(
    read: () => storage.read(key: _storageKey),
    write: (value) => storage.write(key: _storageKey, value: value),
  );

  static const _storageKey = 'global_public_activity_journal_v1';
  final Future<String?> Function() _read;
  final Future<void> Function(String value) _write;
  final DateTime Function() _now;
  final int maxEntries;
  final Duration ttl;
  Future<void> _tail = Future<void>.value();

  Future<List<GlobalActivity>> readEntries({
    String? connectionId,
    String? profile,
  }) async {
    final raw = await _read();
    if (raw == null || raw.isEmpty) return const [];
    try {
      final root = jsonDecode(raw);
      if (root is! Map || root['version'] != 1 || root['entries'] is! List) {
        return const [];
      }
      final cutoff = _now().toUtc().subtract(ttl);
      final result = <GlobalActivity>[];
      for (final value in (root['entries'] as List).take(maxEntries)) {
        final item = _decode(value);
        if (item == null ||
            item.terminal ||
            item.observedAt.isBefore(cutoff) ||
            (connectionId != null && item.scope.connectionId != connectionId) ||
            (profile != null && item.scope.profile != profile)) {
          continue;
        }
        result.add(item);
      }
      return List.unmodifiable(result);
    } catch (_) {
      return const [];
    }
  }

  void replace(Iterable<GlobalActivity> entries) {
    final candidate = entries.where((item) => !item.terminal).toList()
      ..sort((a, b) => b.observedAt.compareTo(a.observedAt));
    final bounded = candidate.take(maxEntries).map(_encode).toList();
    final operation = _tail.then(
      (_) => _write(jsonEncode({'version': 1, 'entries': bounded})),
    );
    _tail = operation.catchError((_) {});
  }

  Future<void> flush() => _tail;

  Map<String, Object?> _encode(GlobalActivity value) => {
    'connection': value.scope.connectionId,
    'profile': value.scope.profile,
    'durable': value.scope.durableSessionId,
    'runtime': value.scope.runtimeSessionId,
    'epoch': value.scope.replayEpoch,
    'phase': _phaseToken(value.phase),
    'terminal': value.terminal,
    'requires_action': value.requiresAction,
    'tools': value.toolCount.clamp(0, 999),
    'subagents': value.subagentCount.clamp(0, 999),
    'processes': value.processCount.clamp(0, 999),
    'observed_at': value.observedAt.millisecondsSinceEpoch,
    if (value.sequence != null) 'seq': value.sequence,
  };

  GlobalActivity? _decode(Object? raw) {
    if (raw is! Map) return null;
    String? id(String key) {
      final value = raw[key];
      return value is String &&
              value.isNotEmpty &&
              value.length <= 1024 &&
              value == value.trim()
          ? value
          : null;
    }

    int? count(String key) {
      final value = raw[key];
      return value is int && value >= 0 && value <= 999 ? value : null;
    }

    final connection = id('connection');
    final owner = id('profile');
    final durable = id('durable');
    final runtime = id('runtime');
    final epoch = id('epoch');
    final phase = _phaseFromToken(raw['phase']);
    final observedAt = raw['observed_at'];
    final tools = count('tools');
    final subagents = count('subagents');
    final processes = count('processes');
    final sequence = raw['seq'];
    if (connection == null ||
        owner == null ||
        durable == null ||
        runtime == null ||
        epoch == null ||
        phase == null ||
        observedAt is! int ||
        observedAt < 0 ||
        raw['terminal'] is! bool ||
        raw['requires_action'] is! bool ||
        tools == null ||
        subagents == null ||
        processes == null ||
        (sequence != null && (sequence is! int || sequence <= 0))) {
      return null;
    }
    return GlobalActivity(
      scope: GlobalActivityScope(
        connectionId: connection,
        profile: owner,
        durableSessionId: durable,
        runtimeSessionId: runtime,
        replayEpoch: epoch,
      ),
      phase: phase,
      terminal: raw['terminal'] as bool,
      requiresAction: raw['requires_action'] as bool,
      toolCount: tools,
      subagentCount: subagents,
      processCount: processes,
      observedAt: DateTime.fromMillisecondsSinceEpoch(observedAt, isUtc: true),
      authority: GlobalActivityAuthority.journal,
      stale: true,
      sequence: sequence as int?,
    );
  }
}

String _phaseToken(GlobalActivityPhase phase) => switch (phase) {
  GlobalActivityPhase.usingTools => 'using_tools',
  GlobalActivityPhase.backgroundWork => 'background_work',
  GlobalActivityPhase.waitingForUser => 'waiting_for_user',
  _ => phase.name,
};

GlobalActivityPhase? _phaseFromToken(Object? raw) => switch (raw) {
  'preparing' => GlobalActivityPhase.preparing,
  'generating' => GlobalActivityPhase.generating,
  'using_tools' => GlobalActivityPhase.usingTools,
  'delegated' => GlobalActivityPhase.delegated,
  'background_work' => GlobalActivityPhase.backgroundWork,
  'compacting' => GlobalActivityPhase.compacting,
  'waiting_for_user' => GlobalActivityPhase.waitingForUser,
  'completing' => GlobalActivityPhase.completing,
  'completed' => GlobalActivityPhase.completed,
  'interrupted' => GlobalActivityPhase.interrupted,
  'failed' => GlobalActivityPhase.failed,
  'unknown' => GlobalActivityPhase.unknown,
  _ => null,
};

bool rosterStatusIsBusy(String? raw) => switch (raw?.trim().toLowerCase()) {
  'working' ||
  'running' ||
  'active' ||
  'busy' ||
  'starting' ||
  'waiting' => true,
  _ => false,
};

GlobalActivityPhase _phaseFromRoster(String? raw) =>
    switch (raw?.trim().toLowerCase()) {
      'starting' => GlobalActivityPhase.preparing,
      'waiting' => GlobalActivityPhase.waitingForUser,
      _ => GlobalActivityPhase.generating,
    };

/// Wire form of a terminal [GlobalActivityPhase] for the cross-surface
/// activity notification. Only `completed`/`failed`/`interrupted` ever reach
/// [GlobalActivityAggregate]'s `onTerminal` callback (see `_reduceEvent`'s
/// `terminal(...)` calls) — any other phase is defensive, not reachable.
String sessionActivityPhaseWire(GlobalActivityPhase phase) => switch (phase) {
  GlobalActivityPhase.failed => 'failed',
  GlobalActivityPhase.interrupted => 'interrupted',
  _ => 'completed',
};

typedef _EventReduction = ({
  GlobalActivityPhase phase,
  bool terminal,
  bool requiresAction,
  int toolCount,
  int subagentCount,
  int processCount,
});

_EventReduction? _reduceEvent(
  String type,
  Map<String, dynamic> payload,
  GlobalActivity? current,
) {
  final tools = current?.toolCount ?? 0;
  final subagents = current?.subagentCount ?? 0;
  final processes = current?.processCount ?? 0;
  _EventReduction live(
    GlobalActivityPhase phase, {
    bool action = false,
    int? toolCount,
    int? subagentCount,
    int? processCount,
  }) => (
    phase: phase,
    terminal: false,
    requiresAction: action,
    toolCount: toolCount ?? tools,
    subagentCount: subagentCount ?? subagents,
    processCount: processCount ?? processes,
  );
  _EventReduction terminal(GlobalActivityPhase phase) => (
    phase: phase,
    terminal: true,
    requiresAction: false,
    toolCount: tools,
    subagentCount: subagents,
    processCount: processes,
  );

  final blockingFamily = _blockingPromptFamily(type);
  if (blockingFamily != null) {
    return type.endsWith('.request')
        ? live(GlobalActivityPhase.waitingForUser, action: true)
        : live(GlobalActivityPhase.generating);
  }

  return switch (type) {
    'message.start' => live(GlobalActivityPhase.preparing),
    'message.delta' ||
    'message.interim' => live(GlobalActivityPhase.generating),
    'tool.start' => live(GlobalActivityPhase.usingTools, toolCount: tools + 1),
    'tool.generating' => live(GlobalActivityPhase.usingTools),
    'tool.complete' => live(GlobalActivityPhase.generating),
    'subagent.start' ||
    'subagent.thinking' ||
    'subagent.tool' ||
    'subagent.text' => live(
      GlobalActivityPhase.delegated,
      subagentCount: type == 'subagent.start' ? subagents + 1 : subagents,
    ),
    // `subagent.start` raised this count, so its completion has to lower it
    // again or the aggregate keeps reporting delegated children that already
    // finished. Clamped at zero: a duplicate or unmatched completion (replay,
    // reconnect) must not drive it negative.
    'subagent.complete' => live(
      processes > 0
          ? GlobalActivityPhase.backgroundWork
          : GlobalActivityPhase.generating,
      subagentCount: subagents > 0 ? subagents - 1 : 0,
    ),
    'status.update' => switch ((payload['kind'] ?? payload['status'])) {
      'compacting' => live(GlobalActivityPhase.compacting),
      'compacted' => live(GlobalActivityPhase.generating),
      _ => null,
    },
    'message.complete' => terminal(
      payload['status'] == 'error'
          ? GlobalActivityPhase.failed
          : payload['status'] == 'interrupted' ||
                payload['status'] == 'cancelled'
          ? GlobalActivityPhase.interrupted
          : GlobalActivityPhase.completed,
    ),
    'error' => terminal(GlobalActivityPhase.failed),
    _ => null,
  };
}

String? _blockingPromptFamily(String type) {
  if (!type.endsWith('.request') && !type.endsWith('.expire')) return null;
  final family = type.substring(0, type.lastIndexOf('.'));
  if (family == 'approval' ||
      family == 'clarify' ||
      family == 'input' ||
      family == 'sudo' ||
      family == 'secret' ||
      family == 'handoff' ||
      family == 'tour' ||
      family == 'terminal.read' ||
      family == 'window.read' ||
      family == 'mcp.setup' ||
      family.startsWith('vault.') ||
      family.startsWith('preview.')) {
    return family;
  }
  return null;
}
