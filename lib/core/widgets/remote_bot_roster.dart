import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/bot_roster_store.dart';
import 'package:flutter/material.dart';
import '../models/agent_profile.dart';
import '../screens/mission_control_copy.dart';
import '../services/connection_manager.dart';
import '../services/shared_gateway_pool.dart';
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

  /// Roster shared with every other screen; [BotRosterRegistry.shared] by
  /// default.
  final BotRosterRegistry? registry;
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
    this.registry,
  });
  @override
  State<RemoteBotRoster> createState() => _RemoteBotRosterState();
}

class _RemoteBotRosterState extends State<RemoteBotRoster> {
  // Pooled leases (spec 070 T202): one shared socket per connection.
  final _leases = <String, SharedGatewayLease>{};
  final _avatars = <String, MissionProfileAvatarCache>{};
  final _failed = <String>{};
  final _loading = <String>{};
  final _watched = <BotRosterStore>[];
  DateTime? _lastRead;
  int _epoch = 0;

  BotRosterRegistry get _registry =>
      widget.registry ?? BotRosterRegistry.shared;

  @override
  void initState() {
    super.initState();
    _watch();
    _load();
  }

  /// Subscribes to the shared store of every shown connection; the cached
  /// roster (cold start) comes from the same store.
  void _watch() {
    for (final store in _watched) {
      store.removeListener(_onRoster);
    }
    _watched.clear();
    for (final connection in widget.connections) {
      _registry.hydrate(connection, prefs: widget.prefs);
      _watched.add(_registry.store(connection.id)..addListener(_onRoster));
    }
  }

  void _onRoster() {
    if (mounted) setState(() {});
  }

  bool _unavailable(String connectionId) =>
      _failed.contains(connectionId) ||
      (_registry.peek(connectionId)?.snapshot?.fromCache ?? false);

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
      // Same connection, different endpoint: its roster is no longer valid
      // anywhere, and reads still on the wire must not publish it.
      for (final old in oldWidget.connections) {
        final current = widget.connections.where((c) => c.id == old.id);
        if (current.isNotEmpty &&
            (current.first.gatewayUrl != old.gatewayUrl ||
                current.first.apiKey != old.apiKey ||
                current.first.onDeviceLoopback != old.onDeviceLoopback)) {
          _registry.forget(old.id);
        }
      }
      for (final lease in _leases.values) {
        lease.release();
      }
      _leases.clear();
      _avatars.clear();
      _epoch++;
      _failed.clear();
      _loading.clear();
      _watch();
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
        final ticket = _registry.beginRead(connection.id);
        TuiGatewayClient? client;
        try {
          final loader = widget.loader;
          if (loader == null) {
            client = _leases
                .putIfAbsent(
                  connection.id,
                  () => SharedGatewayPool.instance.acquire(connection),
                )
                .client;
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
          // The store persists it and keeps it only if nothing newer landed.
          _registry.publish(
            connection.id,
            connection.label,
            profiles,
            ticket: ticket,
            sessions: true,
          );
          setState(() => _failed.remove(connection.id));
        } catch (_) {
          if (mounted && epoch == _epoch) {
            setState(() => _failed.add(connection.id));
          }
        } finally {
          if (epoch == _epoch) _loading.remove(connection.id);
        }
      }),
    );
  }

  @override
  void dispose() {
    for (final store in _watched) {
      store.removeListener(_onRoster);
    }
    _epoch++;
    for (final lease in _leases.values) {
      lease.release();
    }
    _leases.clear();
    super.dispose();
  }

  List<AgentProfile> _ordered(String connectionId) {
    final profiles = [...?_registry.peek(connectionId)?.profiles];
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
          trailing: _unavailable(connection.id)
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
