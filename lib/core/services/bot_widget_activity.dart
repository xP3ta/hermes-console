// Widget activity layer (Grok-style Bot widgets): turns the live presence
// the listener proves each tick into what the home-screen widgets show:
//
// - short-lived outcomes: a Bot/room that stops working shows "done" (or
//   "failed" when the room blocked) for [outcomeWindow], then goes idle;
// - a step ticker (max 3, oldest first) built ONLY from public display
//   fields: worker/session titles and room round member progress. Never
//   tool arguments, previews, paths or free-form results;
// - the active list in widget priority (needs you > failed > working >
//   done, most recent first) and the 2x2 hero, rotated round-robin within
//   the top tier on each update unless a pinned Bot is in it.
//
// Pure except for [BotWidgetActivityStore], so the policy is unit-tested.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/bot_mode_widget_snapshot.dart';

/// Persisted memory of the previous tick (per connection).
class BotWidgetActivityMemory {
  /// id (`bot:<profile>` / `room:<id>`) → entry.
  final Map<String, BotWidgetActivityEntry> entries;
  final int rotation;
  final String? connectionId;

  const BotWidgetActivityMemory({
    this.entries = const {},
    this.rotation = 0,
    this.connectionId,
  });

  Map<String, Object?> toJson() => {
    'conn': connectionId,
    'rot': rotation,
    'e': {for (final e in entries.entries) e.key: e.value.toJson()},
  };

  static BotWidgetActivityMemory fromJson(Object? raw) {
    if (raw is! Map) return const BotWidgetActivityMemory();
    final e = raw['e'];
    return BotWidgetActivityMemory(
      connectionId: raw['conn'] as String?,
      rotation: raw['rot'] is int ? raw['rot'] as int : 0,
      entries: {
        if (e is Map)
          for (final entry in e.entries)
            if (entry.key is String)
              entry.key as String: BotWidgetActivityEntry.fromJson(entry.value),
      },
    );
  }
}

class BotWidgetActivityEntry {
  final String state; // WidgetBotState.name
  final int sinceMs;
  final List<String> steps;
  final String? roomId;
  final String? roomName;

  const BotWidgetActivityEntry({
    required this.state,
    required this.sinceMs,
    this.steps = const [],
    this.roomId,
    this.roomName,
  });

  Map<String, Object?> toJson() => {
    's': state,
    't': sinceMs,
    if (steps.isNotEmpty) 'st': steps,
    'r': ?roomId,
    'rn': ?roomName,
  };

  static BotWidgetActivityEntry fromJson(Object? raw) {
    if (raw is! Map) {
      return const BotWidgetActivityEntry(state: 'idle', sinceMs: 0);
    }
    final st = raw['st'];
    return BotWidgetActivityEntry(
      state: raw['s'] is String ? raw['s'] as String : 'idle',
      sinceMs: raw['t'] is int ? raw['t'] as int : 0,
      steps: [
        if (st is List)
          for (final s in st)
            if (s is String) s,
      ],
      roomId: raw['r'] as String?,
      roomName: raw['rn'] as String?,
    );
  }
}

abstract interface class BotWidgetActivityStore {
  BotWidgetActivityMemory load();
  Future<void> save(BotWidgetActivityMemory memory);
}

class PrefsBotWidgetActivityStore implements BotWidgetActivityStore {
  PrefsBotWidgetActivityStore(this.prefs);
  final SharedPreferences prefs;
  static const key = 'bg_widget_activity_v1';

  @override
  BotWidgetActivityMemory load() {
    try {
      final raw = prefs.getString(key);
      return raw == null
          ? const BotWidgetActivityMemory()
          : BotWidgetActivityMemory.fromJson(jsonDecode(raw));
    } catch (_) {
      return const BotWidgetActivityMemory();
    }
  }

  @override
  Future<void> save(BotWidgetActivityMemory memory) =>
      prefs.setString(key, jsonEncode(memory.toJson()));
}

class MemoryBotWidgetActivityStore implements BotWidgetActivityStore {
  BotWidgetActivityMemory memory = const BotWidgetActivityMemory();
  @override
  BotWidgetActivityMemory load() => memory;
  @override
  Future<void> save(BotWidgetActivityMemory memory) async =>
      this.memory = memory;
}

/// Maximum ticker length.
const botWidgetMaxSteps = 3;

/// Keeps a ticker: appends [step] when it differs from the current one,
/// oldest first, at most [botWidgetMaxSteps].
/// Widget ticker words: at most [maxWords] whole words and [maxChars]
/// characters, never cut mid-word (a single over-long word is kept whole;
/// the widget ellipsizes it). Trailing punctuation and "…" are dropped.
String shortenWidgetStep(String step, {int maxWords = 4, int maxChars = 26}) {
  final words = step
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .split(' ')
      .where((w) => w.isNotEmpty)
      .toList();
  final kept = <String>[];
  var length = 0;
  for (final word in words) {
    final next = length == 0 ? word.length : length + 1 + word.length;
    if (kept.isNotEmpty && (kept.length >= maxWords || next > maxChars)) {
      break;
    }
    kept.add(word);
    length = next;
  }
  // Never end on a dangling connector ("Arreglar la").
  const connectors = {
    'a',
    'al',
    'de',
    'del',
    'el',
    'en',
    'la',
    'las',
    'los',
    'y',
    'o',
    'con',
    'para',
    'por',
    'un',
    'una',
    'the',
    'of',
    'to',
    'in',
    'on',
    'for',
    'and',
    'with',
    'an',
  };
  while (kept.length > 1 && connectors.contains(kept.last.toLowerCase())) {
    kept.removeLast();
  }
  return kept.join(' ').replaceAll(RegExp(r'[\s.,;:·…-]+$'), '');
}

List<String> appendStep(List<String> steps, String? step) {
  final value = shortenWidgetStep(step ?? '');
  if (value.isEmpty) return steps;
  if (steps.isNotEmpty && steps.last == value) return steps;
  final next = [...steps.where((s) => s != value), value];
  return next.length > botWidgetMaxSteps
      ? next.sublist(next.length - botWidgetMaxSteps)
      : next;
}

class BotWidgetActivityTracker {
  BotWidgetActivityTracker(this.store);

  final BotWidgetActivityStore store;

  /// How long "done"/"failed" stays on the widgets after work ends.
  static const outcomeWindow = Duration(minutes: 10);

  /// Applies outcomes, tickers, ordering and the hero to [live] (the
  /// snapshot built from this tick's server evidence) and persists memory.
  ///
  /// [botSteps] are the public step candidates per profile this tick
  /// (already privacy-filtered), [roomSteps] per room id (round progress).
  /// [roomFailed] marks rooms whose round blocked.
  Future<BotModeWidgetSnapshot> apply(
    BotModeWidgetSnapshot live, {
    required DateTime now,
    Map<String, String?> botSteps = const {},
    Map<String, List<String>> roomSteps = const {},
    Set<String> roomFailed = const {},
    bool rotate = true,
  }) async {
    final nowMs = now.millisecondsSinceEpoch;
    var memory = store.load();
    if (memory.connectionId != live.connectionId) {
      // Outcomes never cross connections.
      memory = BotWidgetActivityMemory(connectionId: live.connectionId);
    }
    final next = <String, BotWidgetActivityEntry>{};
    bool expired(BotWidgetActivityEntry e) =>
        nowMs - e.sinceMs > outcomeWindow.inMilliseconds || e.sinceMs > nowMs;

    final bots = <WidgetBot>[];
    for (final bot in live.bots) {
      final key = 'bot:${bot.profile}';
      final prev = memory.entries[key];
      final prevState = WidgetBotState.values.asNameMap()[prev?.state];
      var state = bot.state;
      var since = prev != null && prev.state == state.name
          ? prev.sinceMs
          : nowMs;
      var steps = prev?.steps ?? const <String>[];
      String? roomId = bot.roomId;
      String? roomName = bot.roomName;
      if (state.isLive) {
        steps = appendStep(
          prevState != null && prevState.isLive ? steps : const [],
          botSteps[bot.profile] ?? bot.line,
        );
      } else if (prevState != null && prevState.isLive) {
        // Work just ended: celebrate (or flag the blocked room).
        final failed = prev!.roomId != null && roomFailed.contains(prev.roomId);
        state = failed ? WidgetBotState.failed : WidgetBotState.done;
        since = nowMs;
        roomId = prev.roomId;
        roomName = prev.roomName;
      } else if (prevState != null && prevState.isOutcome && !expired(prev!)) {
        state = prevState;
        since = prev.sinceMs;
        roomId = prev.roomId;
        roomName = prev.roomName;
      } else {
        steps = const [];
      }
      next[key] = BotWidgetActivityEntry(
        state: state.name,
        sinceMs: since,
        steps: steps,
        roomId: roomId,
        roomName: roomName,
      );
      bots.add(
        WidgetBot(
          profile: bot.profile,
          name: bot.name,
          state: state,
          openPayload: bot.openPayload,
          line: state.isLive ? bot.line : null,
          facePath: bot.facePath,
          idleFacePath: bot.idleFacePath,
          steps: state == WidgetBotState.idle ? const [] : steps,
          sinceMs: state == WidgetBotState.idle ? null : since,
          role: bot.role,
          color: bot.color,
          roomId: state == WidgetBotState.idle ? null : roomId,
          roomName: state == WidgetBotState.idle ? null : roomName,
          pinned: bot.pinned,
        ),
      );
    }

    final rooms = <WidgetRoom>[];
    for (final room in live.rooms) {
      final key = 'room:${room.roomId}';
      final prev = memory.entries[key];
      final prevState = roomPhaseState(prev?.state ?? 'idle');
      var phase = roomFailed.contains(room.roomId) ? 'failed' : room.phase;
      var state = roomPhaseState(phase);
      var since = prev != null && prev.state == phase ? prev.sinceMs : nowMs;
      var steps = <String>[...roomSteps[room.roomId] ?? room.steps];
      if (steps.length > botWidgetMaxSteps) {
        steps = steps.sublist(steps.length - botWidgetMaxSteps);
      }
      if (state == WidgetBotState.idle) {
        if (prevState.isLive) {
          phase = 'done';
          since = nowMs;
          steps = prev!.steps;
        } else if (prevState.isOutcome && !expired(prev!)) {
          phase = prev.state;
          since = prev.sinceMs;
          steps = prev.steps;
        } else {
          steps = const [];
        }
      }
      state = roomPhaseState(phase);
      next[key] = BotWidgetActivityEntry(
        state: phase,
        sinceMs: since,
        steps: steps,
      );
      rooms.add(
        room.copyWith(
          phase: phase,
          steps: steps,
          sinceMs: state == WidgetBotState.idle ? null : since,
        ),
      );
    }

    final ordered = orderActive(bots: bots, rooms: rooms);
    final rotation = rotate ? memory.rotation + 1 : memory.rotation;
    final hero = pickHero(
      active: ordered,
      bots: bots,
      rooms: rooms,
      rotation: rotation,
    );
    await store.save(
      BotWidgetActivityMemory(
        connectionId: live.connectionId,
        rotation: rotation,
        entries: next,
      ),
    );
    return live.copyWith(
      bots: _sortBots(bots),
      rooms: rooms,
      active: ordered,
      hero: hero,
      clearHero: hero == null,
    );
  }

  static List<WidgetBot> _sortBots(List<WidgetBot> bots) {
    final indexed = [for (var i = 0; i < bots.length; i++) (i, bots[i])];
    indexed.sort((a, b) {
      final p = a.$2.state.priority.compareTo(b.$2.state.priority);
      if (p != 0) return p;
      final t = (b.$2.sinceMs ?? 0).compareTo(a.$2.sinceMs ?? 0);
      return t != 0 ? t : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  /// Active items in widget priority, most recent first within a priority.
  /// A Bot whose work belongs to a listed active room is represented by
  /// that room (one row per room, with its members' faces).
  static List<WidgetActiveRef> orderActive({
    required List<WidgetBot> bots,
    required List<WidgetRoom> rooms,
  }) {
    final activeRooms = {
      for (final r in rooms)
        if (r.state != WidgetBotState.idle) r.roomId,
    };
    final items = <(WidgetActiveRef, WidgetBotState, int)>[
      for (final r in rooms)
        if (r.state != WidgetBotState.idle)
          (WidgetActiveRef.room(r.roomId), r.state, r.sinceMs ?? 0),
      for (final b in bots)
        if (b.state != WidgetBotState.idle &&
            !(b.roomId != null && activeRooms.contains(b.roomId)))
          (WidgetActiveRef.bot(b.profile), b.state, b.sinceMs ?? 0),
    ];
    items.sort((a, b) {
      final p = a.$2.priority.compareTo(b.$2.priority);
      if (p != 0) return p;
      final t = b.$3.compareTo(a.$3);
      if (t != 0) return t;
      // Same priority and age: rooms (several Bots) before single Bots.
      final k = b.$1.kind.compareTo(a.$1.kind);
      return k != 0 ? k : a.$1.id.compareTo(b.$1.id);
    });
    return [for (final i in items) i.$1];
  }

  /// Hero: round-robin across the top-priority tier; a pinned Bot in that
  /// tier always wins.
  static WidgetActiveRef? pickHero({
    required List<WidgetActiveRef> active,
    required List<WidgetBot> bots,
    required List<WidgetRoom> rooms,
    required int rotation,
  }) {
    if (active.isEmpty) return null;
    WidgetBotState stateOf(WidgetActiveRef ref) {
      if (ref.kind == 'bot') {
        return bots.firstWhere((b) => b.profile == ref.id).state;
      }
      return rooms.firstWhere((r) => r.roomId == ref.id).state;
    }

    final top = stateOf(active.first).priority;
    final tier = [
      for (final ref in active)
        if (stateOf(ref).priority == top) ref,
    ];
    for (final ref in tier) {
      if (ref.kind == 'bot' &&
          bots.any((b) => b.profile == ref.id && b.pinned)) {
        return ref;
      }
    }
    return tier[rotation.abs() % tier.length];
  }
}
