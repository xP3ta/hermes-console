import 'package:hermes_android/core/design/hicons.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../design/content.dart'
    show HermesInlineNotice, HermesStatusText, HermesTag;
import '../design/list.dart'
    show HermesListGroup, HermesListRow, HermesSectionHeader;
import '../design/modal.dart'
    show HermesDialogAction, HermesDialogActionStyle, showHermesDialog;
import '../design/tokens.dart';
import '../services/connection_manager.dart';
import '../services/hermes_update_monitor.dart';
import '../services/messaging_pairing.dart';
import '../services/messaging_platforms.dart';
import '../theme/app_theme.dart';
import '../widgets/console_loader.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_premium_ui.dart' show HermesEmptyState;
import 'lock_screen.dart';
import 'messaging_platform_detail.dart';

/// Opens [url] outside the app; false when nothing could open it.
typedef MessagingOpenUrl = Future<bool> Function(String url);

/// Only web links leave the app (Desktop `lib/external-link.ts` validates
/// before it opens anything).
Future<bool> openMessagingUrl(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
    return false;
  }
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// The state Desktop's Messaging page keeps for one profile
/// (`app/messaging/index.tsx` `MessagingView`): the platforms, who is
/// waiting or approved on each, the unsaved edits of every platform and
/// whether a gateway restart is owed. The list and each platform's page
/// share one, so an edit survives going back to the list, as it survives
/// picking another platform on Desktop.
class MessagingSetupController extends ChangeNotifier {
  MessagingSetupController({
    required this.client,
    required this.pairingClient,
    required this.profile,
    this.settleDelay = const Duration(seconds: 4),
  });

  final MessagingPlatformsClient client;
  final MessagingPairingClient pairingClient;

  /// The profile every call names (`default` included).
  final String profile;

  /// Desktop's wait before re-reading the status of a platform the running
  /// gateway is connecting.
  final Duration settleDelay;

  List<MessagingPlatform>? _platforms;
  PairingSnapshot _pairing = const PairingSnapshot();
  final Map<String, Map<String, String>> _drafts = {};
  bool _routeMissing = false;
  bool _loadFailed = false;
  bool _restartNeeded = false;
  bool _restarting = false;
  String? _busy;
  Timer? _settle;
  int _generation = 0;
  bool _disposed = false;

  List<MessagingPlatform>? get platforms => _platforms;

  /// The server has no `/api/messaging/platforms`: it is too old.
  bool get routeMissing => _routeMissing;

  /// The last load the user asked for failed.
  bool get loadFailed => _loadFailed;

  /// A saved change waits for a gateway restart (Desktop `restartNeeded`).
  bool get restartNeeded => _restartNeeded;
  bool get restarting => _restarting;

  /// What is being written: `enabled:<id>`, `env:<id>`, `clear:<id>:<key>`,
  /// `test:<id>` or `pair:<platform>:<user>`.
  String? get busy => _busy;

  MessagingPlatform? platformById(String id) {
    for (final platform in _platforms ?? const <MessagingPlatform>[]) {
      if (platform.id == id) return platform;
    }
    return null;
  }

  List<PairingEntry> pendingOf(String platformId) => [
    for (final entry in _pairing.pending)
      if (entry.platform == platformId) entry,
  ];

  List<PairingEntry> approvedOf(String platformId) => [
    for (final entry in _pairing.approved)
      if (entry.platform == platformId) entry,
  ];

  /// What the user typed on [platformId], field by field.
  Map<String, String> draftOf(String platformId) =>
      Map.unmodifiable(_drafts[platformId] ?? const <String, String>{});

  void edit(String platformId, String key, String value) {
    (_drafts[platformId] ??= {})[key] = value;
    _changed();
  }

  MessagingPlatformUpdate changesOf(MessagingPlatform platform) =>
      messagingChanges(platform, _drafts[platform.id] ?? const {});

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Desktop `refreshPlatforms`. A silent read (the poll, the re-read after
  /// a live change) never reports a failure; once the route is known to be
  /// missing it does not ask again.
  Future<void> refresh({bool silent = false}) async {
    if (silent && _routeMissing) return;
    final generation = ++_generation;
    try {
      final rows = await client.load(profile);
      if (_disposed || generation != _generation) return;
      _platforms = rows;
      _routeMissing = false;
      _loadFailed = false;
    } on MessagingRouteMissing {
      if (_disposed || generation != _generation) return;
      _routeMissing = true;
    } catch (_) {
      if (_disposed || generation != _generation) return;
      if (!silent) _loadFailed = true;
    }
    _changed();
  }

  /// Desktop `refreshPairing`: a failure keeps the rows already shown, and
  /// a server without `/api/pairing` simply shows none.
  Future<void> refreshPairing() async {
    try {
      final snapshot = await pairingClient.load(profile);
      if (_disposed) return;
      _pairing = snapshot;
      _changed();
    } catch (_) {}
  }

  Future<void> refreshAll({bool silent = false}) async {
    await Future.wait([refresh(silent: silent), refreshPairing()]);
  }

  /// A multiplexed profile was re-served from its new settings at once
  /// (`hot_served`): no restart is owed, its status is read again shortly.
  /// Anything else waits for a restart (Desktop `settleAfterUpdate`).
  void _settleAfter(bool hotServed) {
    if (hotServed) {
      _rereadLater();
      return;
    }
    _restartNeeded = true;
  }

  void _rereadLater() {
    _settle?.cancel();
    _settle = Timer(settleDelay, () => unawaited(refresh(silent: true)));
  }

  Future<T> _write<T>(String busy, Future<T> Function() write) async {
    _busy = busy;
    _changed();
    try {
      return await write();
    } finally {
      _busy = null;
      _changed();
    }
  }

  /// Desktop `handleToggle`: the row shows the new state at once.
  Future<MessagingUpdateResult> toggle(MessagingPlatform platform, bool on) =>
      _write('enabled:${platform.id}', () async {
        final result = await client.update(
          platform.id,
          MessagingPlatformUpdate(enabled: on),
          profile,
        );
        _platforms = [
          for (final row in _platforms ?? const <MessagingPlatform>[])
            row.id == platform.id ? row.toggled(on) : row,
        ];
        _settleAfter(result.hotServed);
        return result;
      });

  /// Desktop `handleSave`. Only what was typed is sent. The platforms are
  /// read again before the edits are dropped, so an allowlist shows the
  /// saved value; a failed save keeps every edit.
  Future<MessagingUpdateResult?> save(MessagingPlatform platform) async {
    final update = changesOf(platform);
    if (!update.hasChanges) return null;
    return _write('env:${platform.id}', () async {
      final result = await client.update(platform.id, update, profile);
      await refresh();
      _drafts.remove(platform.id);
      _settleAfter(result.hotServed);
      return result;
    });
  }

  /// Desktop `handleClear`.
  Future<MessagingUpdateResult> clear(MessagingPlatform platform, String key) =>
      _write('clear:${platform.id}:$key', () async {
        final result = await client.update(
          platform.id,
          MessagingPlatformUpdate(clearEnv: [key]),
          profile,
        );
        (_drafts[platform.id] ??= {})[key] = '';
        await refresh();
        _settleAfter(result.hotServed);
        return result;
      });

  Future<MessagingTestResult> test(MessagingPlatform platform) =>
      _write('test:${platform.id}', () => client.test(platform.id, profile));

  static String _pairKey(PairingEntry entry) =>
      'pair:${entry.platform}:${entry.userId}';

  /// Desktop `handleApprove`: the row leaves the list at once and comes
  /// back if the approval fails.
  Future<void> approve(PairingEntry entry) => _write(_pairKey(entry), () async {
    final snapshot = _pairing;
    _pairing = PairingSnapshot(
      pending: [
        for (final row in snapshot.pending)
          if (_pairKey(row) != _pairKey(entry)) row,
      ],
      approved: snapshot.approved,
    );
    try {
      await pairingClient.approve(entry, profile);
    } catch (_) {
      _pairing = snapshot;
      rethrow;
    }
    await refreshPairing();
  });

  /// Desktop `handleRevoke`.
  Future<void> revoke(PairingEntry entry) => _write(_pairKey(entry), () async {
    final snapshot = _pairing;
    _pairing = PairingSnapshot(
      pending: snapshot.pending,
      approved: [
        for (final row in snapshot.approved)
          if (_pairKey(row) != _pairKey(entry)) row,
      ],
    );
    try {
      await pairingClient.revoke(entry, profile);
    } catch (_) {
      _pairing = snapshot;
      rethrow;
    }
    await refreshPairing();
  });

  bool isBusyPairing(PairingEntry entry) => _busy == _pairKey(entry);

  /// Desktop `restartGatewayNow`: restart, follow the `gateway-restart`
  /// action, and drop the "restart needed" note only when it completed.
  Future<GatewayRestartOutcome> restartGateway() async {
    _restarting = true;
    _changed();
    try {
      final outcome = await runGatewayRestart(
        restart: () => client.requestGatewayRestart(profile),
        waitUntilBack: () => client.awaitGatewayRestart(profile),
      );
      if (outcome == GatewayRestartOutcome.back) {
        _restartNeeded = false;
        _rereadLater();
      }
      return outcome;
    } finally {
      _restarting = false;
      _changed();
    }
  }

  /// Desktop `watchGatewayRestartOutcome`: Telegram's quick setup asked the
  /// server to restart; only its outcome is followed.
  Future<bool> watchRestart() async {
    _restarting = true;
    _restartNeeded = false;
    _changed();
    var ok = false;
    try {
      ok = await client.awaitGatewayRestart(profile);
    } catch (_) {
      ok = false;
    }
    if (!ok) _restartNeeded = true;
    _restarting = false;
    _changed();
    unawaited(refresh(silent: true));
    return ok;
  }

  /// The quick setup saved but could not restart: one is owed.
  void markRestartNeeded() {
    _restartNeeded = true;
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _settle?.cancel();
    super.dispose();
  }
}

/// Asks App Lock (when the user has one) before a change; a custom check
/// replaces it in tests.
Future<bool> messagingVerify(
  BuildContext context,
  Future<bool> Function(String reason)? custom,
  String reason,
) async {
  if (custom != null) return custom(reason);
  final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
  if (lock == null || !lock.enabled) return true;
  return LockScreen.verify(context, lock, reason: reason);
}

/// "Restart now": the same confirmation, App Lock check and update guard
/// as Settings › Restart gateway, then Desktop's restart and follow.
/// Answers the sentence to show and whether it is an error; null when the
/// user stopped it.
Future<(String, bool)?> messagingRestartFlow(
  BuildContext context, {
  required MessagingSetupController controller,
  required String connectionId,
  required bool readOnly,
  Future<bool> Function(String reason)? verifyLock,
}) async {
  final s = Strings.of(context);
  if (readOnly || controller.restarting) return null;
  if (HermesUpdateGuard.isActive(connectionId)) {
    return (s.setUpdateAlreadyRunning, true);
  }
  final confirmed = await showHermesDialog<bool>(
    context: context,
    title: s.setRestartGateway,
    message: s.setRestartGatewayBody,
    actions: [
      HermesDialogAction(
        label: s.commonCancel,
        value: false,
        style: HermesDialogActionStyle.cancel,
      ),
      HermesDialogAction(label: s.setRestart, value: true),
    ],
  );
  if (confirmed != true || !context.mounted) return null;
  if (!await messagingVerify(context, verifyLock, s.setVerifyToRestart)) {
    return null;
  }
  final outcome = await controller.restartGateway();
  return switch (outcome) {
    GatewayRestartOutcome.back => (s.setGatewayRestarted, false),
    GatewayRestartOutcome.notBack ||
    GatewayRestartOutcome.failed => (s.msgPlatRestartFailed, true),
  };
}

/// The label of a platform state (Desktop `stateLabel`).
String messagingStateLabel(Strings s, String state) => switch (state) {
  'connected' => s.msgPlatStateConnected,
  'connecting' => s.msgPlatStateConnecting,
  'disabled' => s.msgPlatStateDisabled,
  'fatal' => s.msgPlatStateFatal,
  'gateway_stopped' => s.msgPlatStateGatewayStopped,
  'not_configured' => s.msgPlatStateNotConfigured,
  'pending_restart' => s.msgPlatStatePendingRestart,
  'retrying' => s.msgPlatStateRetrying,
  'startup_failed' => s.msgPlatStateStartupFailed,
  '' => s.msgPlatStateUnknown,
  _ => state.replaceAll('_', ' '),
};

HermesStatusTone messagingStatusTone(MessagingTone tone) => switch (tone) {
  MessagingTone.good => HermesStatusTone.ok,
  MessagingTone.warn => HermesStatusTone.warn,
  MessagingTone.bad => HermesStatusTone.error,
  MessagingTone.muted => HermesStatusTone.neutral,
};

/// Settings › Messaging: Desktop's Messaging page for the profile these
/// Settings show. A list of the server's platforms with their status, each
/// opening its setup: credentials from the server's own field list, enable
/// and disable, test, restart, Telegram's quick setup, Team Gateway links
/// and who may message the bot.
class MessagingPlatformsScreen extends StatefulWidget {
  const MessagingPlatformsScreen({
    required this.connection,
    required this.profile,
    this.client,
    this.pairingClient,
    this.verifyLock,
    this.openUrl,
    this.pollInterval = const Duration(seconds: 6),
    super.key,
  });

  final SavedConnection connection;

  /// The profile whose platforms are read and written (`default` included).
  final String profile;

  // Seams for tests; the defaults are the real Dashboard, App Lock and the
  // platform's browser.
  final MessagingPlatformsClient? client;
  final MessagingPairingClient? pairingClient;
  final Future<bool> Function(String reason)? verifyLock;
  final MessagingOpenUrl? openUrl;

  /// Desktop's status poll for servers without change events
  /// (`window.setInterval(tick, 6000)`); null turns it off.
  final Duration? pollInterval;

  @override
  State<MessagingPlatformsScreen> createState() =>
      _MessagingPlatformsScreenState();
}

class _MessagingPlatformsScreenState extends State<MessagingPlatformsScreen> {
  DashboardClient? _dashboard;
  late final MessagingSetupController _controller;
  final TextEditingController _query = TextEditingController();
  Timer? _poll;
  MessagingTone? _filter;
  String? _status;
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    final client = widget.client;
    final pairing = widget.pairingClient;
    DashboardClient dashboard() =>
        _dashboard ??= DashboardClient.lazy(widget.connection);
    _controller = MessagingSetupController(
      client: client ?? MessagingPlatformsClient(dashboard()),
      pairingClient: pairing ?? MessagingPairingClient(dashboard()),
      profile: widget.profile,
    );
    unawaited(_controller.refreshAll());
    final interval = widget.pollInterval;
    if (interval != null) {
      _poll = Timer.periodic(interval, (_) => _tick());
    }
  }

  /// Desktop polls only a visible page; here, only while the app is in
  /// front, and never a server that lacks the route.
  void _tick() {
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return;
    if (_controller.routeMissing) {
      _poll?.cancel();
      return;
    }
    unawaited(_controller.refreshAll(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _controller.dispose();
    _query.dispose();
    _dashboard?.close();
    super.dispose();
  }

  bool _matches(MessagingPlatform platform, MessagingTone? tone) {
    final query = _query.text.trim().toLowerCase();
    if (tone != null && platform.tone != tone) return false;
    if (query.isEmpty) return true;
    return [
      platform.id,
      platform.name,
      platform.description,
      platform.state,
    ].any((value) => value.toLowerCase().contains(query));
  }

  Future<void> _restart() async {
    final said = await messagingRestartFlow(
      context,
      controller: _controller,
      connectionId: widget.connection.id,
      readOnly: widget.connection.readOnly,
      verifyLock: widget.verifyLock,
    );
    if (said == null || !mounted) return;
    setState(() {
      _status = said.$1;
      _statusIsError = said.$2;
    });
  }

  void _open(MessagingPlatform platform) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MessagingPlatformDetailScreen(
          controller: _controller,
          platformId: platform.id,
          connectionId: widget.connection.id,
          readOnly: widget.connection.readOnly,
          verifyLock: widget.verifyLock,
          openUrl: widget.openUrl ?? openMessagingUrl,
        ),
      ),
    );
  }

  static String _filterLabel(Strings s, MessagingTone? tone) =>
      switch (tone) {
        null => s.msgPlatFilterAll,
        MessagingTone.bad => s.msgPlatFilterBad,
        MessagingTone.warn => s.msgPlatFilterWarn,
        MessagingTone.good => s.msgPlatFilterGood,
        MessagingTone.muted => s.msgPlatFilterMuted,
      };

  Widget _row(MessagingPlatform platform) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final pending = _controller.pendingOf(platform.id).length;
    final tone = messagingStatusTone(platform.tone);
    return HermesListRow(
      key: ValueKey('msgplat-row-${platform.id}'),
      leading: ExcludeSemantics(
        child: SizedBox.square(
          dimension: HermesSpace.x3,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: tone.colorIn(colors),
            ),
          ),
        ),
      ),
      title: platform.name,
      subtitle: platform.relayExclusive
          ? s.msgPlatRelayTitle
          : messagingStateLabel(s, platform.state),
      // Someone is waiting to be let in: the only way the list says so
      // before the platform is opened.
      trailing: pending > 0
          ? Semantics(
              label: s.msgPlatPendingCount(pending),
              excludeSemantics: true,
              child: HermesTag(label: pending.toString()),
            )
          : null,
      onTap: () => _open(platform),
    );
  }

  Widget _body(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final platforms = _controller.platforms;
    if (_controller.routeMissing) {
      return HermesEmptyState(
        key: const ValueKey('msgplat-too-old'),
        icon: HIcons.forum_outlined,
        title: s.msgPlatTooOldTitle,
        body: s.msgPlatTooOld,
      );
    }
    if (platforms == null) {
      if (_controller.loadFailed) {
        return HermesEmptyState(
          key: const ValueKey('msgplat-load-failed'),
          icon: HIcons.error_outline_rounded,
          title: s.msgPlatLoadFailed,
          body: s.msgPlatIntro,
          primaryLabel: s.commonRetry,
          primaryIcon: HIcons.refresh_rounded,
          onPrimary: () => unawaited(_controller.refreshAll()),
        );
      }
      return const Center(child: ConsoleLoader.large());
    }
    if (platforms.isEmpty) {
      return HermesEmptyState(
        key: const ValueKey('msgplat-empty'),
        icon: HIcons.forum_outlined,
        title: s.msgPlatTitle,
        body: s.msgPlatEmpty,
        primaryLabel: s.commonRetry,
        primaryIcon: HIcons.refresh_rounded,
        onPrimary: () => unawaited(_controller.refreshAll()),
      );
    }
    // Desktop's filter order: what needs you first, then what is fine,
    // then what is off. Only tones some platform is in get a choice, and
    // a choice whose last platform left it falls back to All.
    final present = [
      for (final tone in const [
        MessagingTone.bad,
        MessagingTone.warn,
        MessagingTone.good,
        MessagingTone.muted,
      ])
        if (platforms.any((platform) => platform.tone == tone)) tone,
    ];
    final filter = present.contains(_filter) ? _filter : null;
    final visible = [
      for (final platform in platforms)
        if (_matches(platform, filter)) platform,
    ];
    return RefreshIndicator(
      onRefresh: _controller.refreshAll,
      child: ListView(
        clipBehavior: hermesUnderHeader,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          HermesSpace.pageH,
          HermesSpace.pageTop,
          HermesSpace.pageH,
          HermesSpace.pageBottom,
        ),
        children: [
          if (widget.connection.readOnly) ...[
            HermesInlineNotice(
              icon: HIcons.lock_outline_rounded,
              message: s.msgPlatReadOnly,
            ),
            const SizedBox(height: HermesSpace.x3),
          ],
          Text(
            s.msgPlatIntro,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
          ),
          if (_controller.restartNeeded || _controller.restarting) ...[
            const SizedBox(height: HermesSpace.x3),
            HermesInlineNotice(
              key: const ValueKey('msgplat-restart-needed'),
              icon: HIcons.restart_alt_rounded,
              tone: HermesStatusTone.warn,
              message: _controller.restarting
                  ? s.msgPlatRestarting
                  : s.msgPlatRestartNeeded,
              actionLabel:
                  widget.connection.readOnly || _controller.restarting
                  ? null
                  : s.msgPlatRestartNow,
              onAction: () => unawaited(_restart()),
            ),
          ],
          if (_controller.loadFailed) ...[
            const SizedBox(height: HermesSpace.x3),
            HermesInlineNotice(
              key: const ValueKey('msgplat-refresh-failed'),
              icon: HIcons.warning_amber_rounded,
              tone: HermesStatusTone.error,
              message: s.msgPlatLoadFailed,
              actionLabel: s.commonRetry,
              onAction: () => unawaited(_controller.refreshAll()),
            ),
          ],
          if (_status != null) ...[
            const SizedBox(height: HermesSpace.x3),
            Semantics(
              liveRegion: true,
              child: HermesStatusText(
                key: const ValueKey('msgplat-list-status'),
                label: _status!,
                tone: _statusIsError
                    ? HermesStatusTone.error
                    : HermesStatusTone.ok,
                maxLines: 4,
              ),
            ),
          ],
          const SizedBox(height: HermesSpace.x3),
          TextField(
            key: const ValueKey('msgplat-search'),
            controller: _query,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(HIcons.search_rounded),
              hintText: s.msgPlatSearch,
              border: const OutlineInputBorder(),
            ),
          ),
          if (present.length > 1) ...[
            const SizedBox(height: HermesSpace.x2),
            Wrap(
              spacing: HermesSpace.x2,
              children: [
                for (final tone in <MessagingTone?>[null, ...present])
                  ChoiceChip(
                    key: ValueKey('msgplat-filter-${tone?.name ?? 'all'}'),
                    label: Text(_filterLabel(s, tone)),
                    selected: filter == tone,
                    onSelected: (_) => setState(() => _filter = tone),
                  ),
              ],
            ),
          ],
          const SizedBox(height: HermesSpace.x3),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: HermesSpace.x6),
              child: Text(
                s.msgPlatNoMatches,
                key: const ValueKey('msgplat-no-matches'),
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
              ),
            )
          else ...[
            HermesSectionHeader(s.msgPlatTitle),
            HermesListGroup(children: [for (final p in visible) _row(p)]),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(s.msgPlatTitle),
        actions: [
          IconButton(
            key: const ValueKey('msgplat-refresh'),
            tooltip: s.commonRefresh,
            icon: const Icon(HIcons.refresh_rounded),
            onPressed: () => unawaited(_controller.refreshAll()),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => _body(context),
      ),
    );
  }
}
