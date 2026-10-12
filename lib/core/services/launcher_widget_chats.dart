// Feeds the Chats launcher widget from the listing the Chats screen ALREADY
// makes. It never makes a request, a timer or a wake-up of its own, and
// nothing in the background feeds it: with the app closed the widget keeps
// the last list and says since when.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/launcher_widget_chats.dart';
import '../models/session.dart';
import 'launcher_widget_cron.dart'
    show
        LauncherWidgetSectionStore,
        PluginLauncherWidgetSectionStore,
        launcherWidgetPreferredConnection;

/// Android receiver of the Chats launcher widget.
const launcherWidgetChatsProvider =
    'com.hermesagent.hermes_android.HermesChatsWidgetProvider';

/// The owner's "hide sensitive content" choice for notifications also keeps
/// answers off the home screen.
Future<bool> _storedHideSensitive() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('notif_hide_sensitive_content') ?? false;
}

/// One line of plain text from a preview: its first non-empty line, with the
/// common Markdown marks dropped.
String? launcherWidgetChatLine(String? preview) {
  if (preview == null) return null;
  for (final raw in preview.split('\n')) {
    final line = raw
        .replaceAll(RegExp(r'[*_`#>]+'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (line.isEmpty) continue;
    return line.length <= 100 ? line : '${line.substring(0, 100).trimRight()}…';
  }
  return null;
}

/// A conversation as the widget lists it; null for one the widget could not
/// open (a draft that is not on the server yet).
LauncherWidgetChat? launcherWidgetChat(
  Session session, {
  bool hideSensitive = false,
}) {
  if (session.isDraftOnly || !LauncherWidgetChat.addressable(session.id)) {
    return null;
  }
  final title = session.displayTitle.trim();
  if (title.isEmpty) return null;
  final owner = Session.profileOwner(session.profile);
  final activity = session.lastActivityAt;
  return LauncherWidgetChat(
    id: session.id,
    title: title,
    line: hideSensitive
        ? null
        : launcherWidgetChatLine(
            session.lastAssistantPreview ?? session.preview,
          ),
    atMs: activity.isFinite && activity > 0 ? (activity * 1000).round() : null,
    profile: owner == 'default' ? null : owner,
  );
}

/// Serial owner of the Chats section.
class LauncherWidgetChatsPublisher {
  LauncherWidgetChatsPublisher({
    this.store = const PluginLauncherWidgetSectionStore(),
    int Function()? nowMs,
    Future<String?> Function()? preferredConnection,
    Future<bool> Function()? hideSensitive,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _preferredConnection =
           preferredConnection ?? launcherWidgetPreferredConnection,
       _hideSensitive = hideSensitive ?? _storedHideSensitive;

  static final LauncherWidgetChatsPublisher instance =
      LauncherWidgetChatsPublisher();

  /// An unchanged list is still re-stamped this often, so the widget keeps
  /// knowing its data is current.
  static const restampAfter = Duration(minutes: 5);

  final LauncherWidgetSectionStore store;
  final int Function() _nowMs;
  final Future<String?> Function() _preferredConnection;
  final Future<bool> Function() _hideSensitive;
  Future<void> _tail = Future<void>.value();

  /// Offers the conversations just listed for [connectionId], most recent
  /// first. Never throws: a widget must not break the screen that fed it.
  Future<void> offer({
    required String connectionId,
    required Iterable<Session> sessions,
  }) {
    final listed = sessions
        .take(LauncherWidgetChatsSnapshot.maxChats * 3)
        .toList(growable: false);
    final operation = _tail.then((_) async {
      try {
        await _publish(connectionId, listed);
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[launcher-widget] chats (${error.runtimeType})');
        }
      }
    });
    _tail = operation;
    return operation;
  }

  Future<void> _publish(String connectionId, List<Session> sessions) async {
    final preferred = await _preferredConnection();
    final previous = LauncherWidgetChatsSnapshot.tryDecode(
      await store.read(LauncherWidgetChatsSnapshot.storageKey),
    );
    if (preferred != null &&
        preferred != connectionId &&
        previous?.connectionId == preferred) {
      // Another connection's list: the widget stays on the one in use.
      return;
    }
    final hide = await _hideSensitive();
    final now = _nowMs();
    final next = LauncherWidgetChatsSnapshot(
      connectionId: connectionId,
      updatedAtMs: now,
      chats: [
        for (final session in sessions)
          ?launcherWidgetChat(session, hideSensitive: hide),
      ].take(LauncherWidgetChatsSnapshot.maxChats).toList(growable: false),
    );
    final unchanged = previous != null && previous.content == next.content;
    if (unchanged && now - previous.updatedAtMs < restampAfter.inMilliseconds) {
      return;
    }
    await store.write(LauncherWidgetChatsSnapshot.storageKey, next.encode());
    await store.redraw(launcherWidgetChatsProvider);
  }

  Future<void> flush() => _tail;
}
