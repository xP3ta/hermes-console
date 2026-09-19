import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/bot_roster_cache.dart';
import 'package:flutter/material.dart';
import '../models/agent_profile.dart';
import '../screens/mission_control_copy.dart';
import '../services/connection_manager.dart';
import '../services/tui_gateway_client.dart';
import 'mission_profile_avatar.dart';

typedef RemoteBotLoader =
    Future<List<AgentProfile>> Function(SavedConnection connection);

class RemoteBotRoster extends StatefulWidget {
  final List<SavedConnection> connections;
  final String query;
  final bool showHidden;
  final DateTime refreshedAt;
  final void Function(SavedConnection, AgentProfile) onOpen;
  final void Function(SavedConnection, AgentProfile) onDetails;
  final RemoteBotLoader? loader;
  final SharedPreferences? prefs;
  const RemoteBotRoster({
    super.key,
    required this.connections,
    required this.query,
    required this.showHidden,
    required this.refreshedAt,
    required this.onOpen,
    required this.onDetails,
    this.loader,
    this.prefs,
  });
  @override
  State<RemoteBotRoster> createState() => _RemoteBotRosterState();
}

class _RemoteBotRosterState extends State<RemoteBotRoster> {
  final _clients = <String, TuiGatewayClient>{};
  final _avatars = <String, MissionProfileAvatarCache>{};
  final _profiles = <String, List<AgentProfile>>{};
  final _unavailable = <String>{};
  final _loading = <String>{};
  DateTime? _lastRead;
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    if (widget.prefs case final prefs?) {
      for (final connection in widget.connections) {
        final cached = BotRosterCache(prefs).read(connection);
        if (cached.isNotEmpty) {
          _profiles[connection.id] = cached;
          _unavailable.add(connection.id);
        }
      }
    }
    _load();
  }

  @override
  void didUpdateWidget(RemoteBotRoster oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed =
        oldWidget.connections.length != widget.connections.length ||
        oldWidget.connections.any(
          (old) => !widget.connections.any(
            (c) =>
                c.id == old.id &&
                c.gatewayUrl == old.gatewayUrl &&
                c.apiKey == old.apiKey &&
                c.readOnly == old.readOnly &&
                c.onDeviceLoopback == old.onDeviceLoopback,
          ),
        );
    if (changed) {
      if (widget.prefs case final prefs?) {
        for (final old in oldWidget.connections) {
          unawaited(
            BotRosterCache(prefs).remove(old).catchError((Object _) {}),
          );
        }
      }
      for (final client in _clients.values) {
        unawaited(client.close());
      }
      _clients.clear();
      _avatars.clear();
      _epoch++;
      _profiles.clear();
      _unavailable.clear();
      _loading.clear();
    }
    if (changed ||
        (widget.refreshedAt != oldWidget.refreshedAt &&
            DateTime.now().difference(_lastRead ?? DateTime(2000)).inSeconds >=
                30)) {
      _load();
    }
  }

  Future<void> _load() async {
    _lastRead = DateTime.now();
    final epoch = _epoch;
    await Future.wait(
      widget.connections.map((connection) async {
        if (!_loading.add(connection.id)) return;
        TuiGatewayClient? client;
        try {
          final loader = widget.loader;
          if (loader == null) {
            client = _clients.putIfAbsent(
              connection.id,
              () => TuiGatewayClient(connection),
            );
            _avatars.putIfAbsent(
              connection.id,
              () => MissionProfileAvatarCache(
                connectionId: connection.id,
                loader: client!.profileAvatar,
              ),
            );
          }
          final profiles =
              await (loader?.call(connection) ??
                  client!.listProfiles(includeSessions: true));
          if (!mounted || epoch != _epoch) return;
          if (widget.prefs case final prefs?) {
            // Queue synchronously after the ownership check; storage failure must not hide a live roster.
            unawaited(
              BotRosterCache(
                prefs,
              ).write(connection, profiles).catchError((Object _) {}),
            );
          }
          setState(() {
            _profiles[connection.id] = profiles;
            _unavailable.remove(connection.id);
          });
        } catch (_) {
          if (mounted && epoch == _epoch) {
            setState(() => _unavailable.add(connection.id));
          }
        } finally {
          if (epoch == _epoch) _loading.remove(connection.id);
        }
      }),
    );
  }

  @override
  void dispose() {
    _epoch++;
    for (final client in _clients.values) {
      unawaited(client.close());
    }
    super.dispose();
  }

  List<AgentProfile> _ordered(String connectionId) {
    final profiles = [...?_profiles[connectionId]];
    profiles.sort((a, b) {
      final pin = (b.botPinned ? 1 : 0).compareTo(a.botPinned ? 1 : 0);
      if (pin != 0) return pin;
      final active = (remoteBotIsActive(b) ? 1 : 0).compareTo(
        remoteBotIsActive(a) ? 1 : 0,
      );
      return active != 0 ? active : a.name.compareTo(b.name);
    });
    return profiles;
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final connection in widget.connections) ...[
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(
            connection.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: _unavailable.contains(connection.id)
              ? const Icon(Icons.cloud_off_outlined, size: 18)
              : null,
        ),
        for (final profile in _ordered(connection.id))
          if ((widget.showHidden || !profile.botHidden) &&
              '${profile.name} ${profile.botTitle ?? ''} ${connection.label}'
                  .toLowerCase()
                  .contains(widget.query.toLowerCase()))
            Opacity(
              opacity: profile.botHidden ? 0.5 : 1,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: MissionProfileAvatar(
                  profileName: profile.name,
                  size: 36,
                  hasAvatar: profile.hasAvatar,
                  cache: _avatars[connection.id],
                  imageKind: profile.botImageKind,
                  shape: profile.botShape,
                  colorHex: profile.botColorHex,
                ),
                title: Text(
                  profile.botTitle ?? profile.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '@${profile.name} · ${remoteBotIsActive(profile) ? MissionControlCopy.of(context).activeNow : connection.label}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => widget.onOpen(connection, profile),
                onLongPress: () => widget.onDetails(connection, profile),
                trailing: IconButton(
                  icon: const Icon(Icons.more_horiz),
                  tooltip: MaterialLocalizations.of(context).showMenuTooltip,
                  onPressed: () => widget.onDetails(connection, profile),
                ),
              ),
            ),
      ],
    ],
  );
}

bool remoteBotIsActive(AgentProfile profile, {DateTime? now}) {
  final worker = profile.workerSession;
  if (worker == null) return false;
  final age =
      (now ?? DateTime.now()).millisecondsSinceEpoch / 1000 - worker.lastActive;
  return age >= -60 && age <= 150;
}
