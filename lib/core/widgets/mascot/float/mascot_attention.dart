import 'package:flutter/foundation.dart';

import 'mascot_sources.dart';

/// Where something happened: an instance (connection) and one of its
/// profiles ('' or 'default' is the default profile).
@immutable
final class MascotPlace {
  const MascotPlace({
    required this.connId,
    required this.connLabel,
    this.profile = '',
    this.profileLabel = '',
  });

  final String connId;

  /// How the instance is called on screen.
  final String connLabel;
  final String profile;

  /// How the profile is called on screen; empty for the default profile.
  final String profileLabel;

  String get owner {
    final name = profile.trim();
    return name.isEmpty ? 'default' : name;
  }
}

/// A chat that waits for the user right now: an approval to answer, or a
/// question that is answered in the chat.
@immutable
final class MascotWaiting {
  const MascotWaiting({
    required this.key,
    required this.place,
    required this.title,
    required this.open,
    this.command,
    this.resolve,
  });

  /// Stable identity of the request (connection + session + request id).
  final String key;
  final MascotPlace place;

  /// The chat's title; may be empty.
  final String title;

  /// Approval: the command asked for.
  final String? command;

  /// Approval: answers it. Null for a question.
  final Future<void> Function(bool allow)? resolve;

  /// Opens the chat.
  final VoidCallback open;

  bool get isQuestion => resolve == null;
}

/// Something that happened in a chat or a job the user is not looking at:
/// a reply arrived, a task finished, a cron job failed.
@immutable
final class MascotEvent {
  const MascotEvent({
    required this.id,
    required this.place,
    required this.text,
    required this.open,
    this.failed = false,
  });

  /// The thing it is about (session, job or task id): the same thing
  /// reported twice counts once.
  final String id;
  final MascotPlace place;

  /// What happened, in the user's language ("Hermes respondió en Login").
  final String text;
  final bool failed;

  /// Goes to the thing, the way a tap on its notification does.
  final VoidCallback open;
}

/// Turns what the app already knows into what the floating mascot says.
/// Pure: no timers, no I/O. The app pushes state in; the mascot listens to
/// [permissions] and [notices].
///
/// * approvals of every attached chat go to [permissions], named with the
///   place when it is not where the user is;
/// * questions become one notice each ("… te pregunta", "Ver el chat");
/// * events are grouped by place: one notice per other instance, one per
///   other profile of this instance, and one per thing for the profile the
///   user is in;
/// * suggestions come last.
class MascotAttention {
  MascotAttention({this.maxEvents = 40});

  /// Oldest events are dropped beyond this many.
  final int maxEvents;

  final ValueNotifier<List<MascotPermission>> _permissions =
      ValueNotifier<List<MascotPermission>>(const []);
  final ValueNotifier<List<MascotNotice>> _notices =
      ValueNotifier<List<MascotNotice>>(const []);

  ValueListenable<List<MascotPermission>> get permissions => _permissions;
  ValueListenable<List<MascotNotice>> get notices => _notices;

  String? _conn;
  String _owner = 'default';
  List<MascotWaiting> _waiting = const [];
  List<MascotNotice> _suggestions = const [];
  final List<(int, MascotEvent)> _events = <(int, MascotEvent)>[];
  int _serial = 0;

  /// What the published lists say, to skip publishing the same again.
  List<String> _signature = const [];

  /// Where the user is now. What happened there stops being "elsewhere":
  /// its events are dropped.
  void setScope({required String? connId, required String profile}) {
    final owner = profile.trim().isEmpty ? 'default' : profile.trim();
    if (connId == _conn && owner == _owner) return;
    _conn = connId;
    _owner = owner;
    _events.removeWhere((entry) => _groupOf(entry.$2.place) == null);
    _publish();
  }

  /// The chats that wait for the user right now (replaces the last list).
  void setWaiting(List<MascotWaiting> waiting) {
    _waiting = List.unmodifiable(waiting);
    _publish();
  }

  /// Help the user can refuse for good (replaces the last list).
  void setSuggestions(List<MascotNotice> suggestions) {
    assert(suggestions.every((s) => s.isSuggestion));
    _suggestions = List.unmodifiable(suggestions);
    _publish();
  }

  /// Something happened where the user is not looking.
  void report(MascotEvent event) {
    _events.removeWhere(
      (entry) =>
          entry.$2.id == event.id &&
          entry.$2.place.connId == event.place.connId,
    );
    _events.add((_serial++, event));
    if (_events.length > maxEvents) {
      _events.removeRange(0, _events.length - maxEvents);
    }
    _publish();
  }

  /// The user went to [id] (opened that chat): it is no longer news.
  /// [connId] null forgets it whatever instance it belongs to.
  void forget(String? connId, String id) {
    final before = _events.length;
    _events.removeWhere(
      (entry) =>
          entry.$2.id == id &&
          (connId == null || entry.$2.place.connId == connId),
    );
    if (_events.length != before) _publish();
  }

  /// Nothing to say (the mascot is off).
  void clear() {
    _waiting = const [];
    _events.clear();
    _publish();
  }

  // ---------------------------------------------------------------------

  /// 'instance:…' for another instance, 'profile:…' for another profile of
  /// this one, null for where the user is.
  String? _groupOf(MascotPlace place) {
    if (place.connId != _conn) return 'instance:${place.connId}';
    if (place.owner != _owner) return 'profile:${place.connId}:${place.owner}';
    return null;
  }

  /// How a place that is not here is called: the instance, or the profile.
  String? _nameOf(MascotPlace place) {
    if (place.connId != _conn) return place.connLabel;
    if (place.owner != _owner) {
      return place.profileLabel.isEmpty ? place.owner : place.profileLabel;
    }
    return null;
  }

  void _publish() {
    final permissions = <MascotPermission>[];
    final notices = <MascotNotice>[];
    final signature = <String>[];
    for (final item in _waiting) {
      final place = _nameOf(item.place);
      final title = place == null
          ? item.title
          : item.title.isEmpty
          ? place
          : '$place · ${item.title}';
      signature.add('${item.key}|$title|${item.command}');
      final resolve = item.resolve;
      if (resolve != null) {
        permissions.add(
          MascotPermission(
            key: item.key,
            title: title,
            command: item.command,
            resolve: resolve,
            openChat: item.open,
          ),
        );
        continue;
      }
      notices.add(
        MascotNotice(
          key: 'question:${item.key}',
          kind: place == null
              ? MascotNoticeKind.finished
              : item.place.connId != _conn
              ? MascotNoticeKind.instance
              : MascotNoticeKind.profile,
          waiting: true,
          text: (s) =>
              s.mascotNoticeAsks(title.isEmpty ? s.mascotNoticeAChat : title),
          action: (s) => s.mascotPermissionOpenChat,
          onAction: item.open,
        ),
      );
    }

    // Events, newest first; one notice per place that is not here.
    final groups = <String, List<(int, MascotEvent)>>{};
    final here = <(int, MascotEvent)>[];
    for (final entry in _events.reversed) {
      final group = _groupOf(entry.$2.place);
      if (group == null) {
        here.add(entry);
      } else {
        (groups[group] ??= <(int, MascotEvent)>[]).add(entry);
      }
    }
    void drop(Iterable<(int, MascotEvent)> entries) {
      final serials = {for (final entry in entries) entry.$1};
      _events.removeWhere((entry) => serials.contains(entry.$1));
      _publish();
    }

    // Other instances first, then other profiles.
    final ordered = groups.entries.toList()
      ..sort((a, b) {
        final ai = a.key.startsWith('instance:') ? 0 : 1;
        final bi = b.key.startsWith('instance:') ? 0 : 1;
        return ai != bi ? ai - bi : b.value.first.$1 - a.value.first.$1;
      });
    for (final group in ordered) {
      final entries = group.value;
      final latest = entries.first.$2;
      final name = _nameOf(latest.place)!;
      final count = entries.length;
      final instance = group.key.startsWith('instance:');
      signature.add('${group.key}#${entries.last.$1}|$count|${latest.text}');
      notices.add(
        MascotNotice(
          // A place the user already looked at speaks up again for what
          // comes later: its key carries its oldest event.
          key: '${group.key}#${entries.last.$1}',
          kind: instance ? MascotNoticeKind.instance : MascotNoticeKind.profile,
          text: (s) => count == 1
              ? s.mascotNoticeFrom(name, latest.text)
              : s.mascotNoticeMany(name, count),
          action: (s) => instance ? s.mascotNoticeGo : s.mascotNoticeView,
          onAction: latest.open,
          onSeen: () => drop(entries),
        ),
      );
    }
    for (final entry in here) {
      final event = entry.$2;
      signature.add('here:${entry.$1}');
      notices.add(
        MascotNotice(
          key: 'here:${event.place.connId}:${event.id}#${entry.$1}',
          kind: event.failed
              ? MascotNoticeKind.failed
              : MascotNoticeKind.finished,
          text: (_) => event.text,
          action: (s) => s.mascotNoticeView,
          onAction: event.open,
          onSeen: () => drop([entry]),
        ),
      );
    }
    notices.addAll(_suggestions);
    signature.addAll(_suggestions.map((s) => s.key));
    if (listEquals(signature, _signature)) return;
    _signature = signature;
    _permissions.value = List.unmodifiable(permissions);
    _notices.value = List.unmodifiable(notices);
  }

  void dispose() {
    _permissions.dispose();
    _notices.dispose();
  }
}
