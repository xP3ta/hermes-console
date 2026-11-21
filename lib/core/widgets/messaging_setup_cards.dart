import 'package:hermes_android/core/design/hicons.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../design/content.dart' show HermesStatusText, HermesTag;
import '../design/page.dart' show HermesActionButton;
import '../design/tokens.dart';
import '../services/messaging_platforms.dart';
import '../theme/app_theme.dart';

/// The bordered box both setup cards sit in.
class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.controlBorder),
        borderRadius: BorderRadius.circular(HermesRadius.row),
      ),
      child: Padding(
        padding: const EdgeInsets.all(HermesSpace.x3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

Widget _caption(BuildContext context, String text, {Key? key}) => Text(
  text,
  key: key,
  style: Theme.of(context).textTheme.bodySmall?.copyWith(
    color: Theme.of(context).hermes.textSecondary,
    height: 1.4,
  ),
);

/// "m:ss" until [expiresAt]; null once it passed (Desktop `formatExpiry`).
String? messagingExpiry(DateTime? expiresAt, DateTime now) {
  if (expiresAt == null) return null;
  final left = expiresAt.difference(now);
  if (left <= Duration.zero) return null;
  final seconds = (left.inMilliseconds / 1000).ceil();
  final minutes = seconds ~/ 60;
  return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}

enum _TelegramPhase { idle, starting, waiting, ready, applying }

/// Telegram's quick setup (Desktop `app/messaging/telegram-qr-setup.tsx`):
/// the server asks the pairing service for a bot, Telegram confirms it, the
/// user reviews who may talk to it, and the server saves the token and the
/// allowlist and restarts the gateway. Desktop shows the deep link as a QR
/// code to scan with a phone; on the phone the link itself opens Telegram.
class TelegramQuickSetupCard extends StatefulWidget {
  const TelegramQuickSetupCard({
    required this.client,
    required this.profile,
    required this.platformName,
    required this.configured,
    required this.onApplied,
    required this.openUrl,
    this.readOnly = false,
    this.clock,
    super.key,
  });

  final MessagingPlatformsClient client;

  /// Every call of one setup names this profile: the pairing lives in the
  /// server process that started it.
  final String profile;
  final String platformName;
  final bool configured;
  final bool readOnly;
  final ValueChanged<TelegramOnboardingApplied> onApplied;
  final Future<void> Function(String url) openUrl;
  final DateTime Function()? clock;

  @override
  State<TelegramQuickSetupCard> createState() => _TelegramQuickSetupCardState();
}

class _TelegramQuickSetupCardState extends State<TelegramQuickSetupCard> {
  // Desktop's pace: the first read after 1.2 s, then every 2 s.
  static const _firstPoll = Duration(seconds: 1, milliseconds: 200);
  static const _nextPoll = Duration(seconds: 2);

  _TelegramPhase _phase = _TelegramPhase.idle;
  TelegramOnboardingStart? _setup;
  String _bot = '';
  String _connectedBot = '';
  List<String> _allowed = [];
  String _owner = '';
  String? _error;
  bool _missing = false;
  final TextEditingController _newId = TextEditingController();
  Timer? _poll;
  Timer? _tick;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    _newId.dispose();
    super.dispose();
  }

  void _reset() {
    _poll?.cancel();
    _tick?.cancel();
    _setup = null;
    _phase = _TelegramPhase.idle;
    _bot = '';
    _allowed = [];
    _owner = '';
    _newId.clear();
    _error = null;
  }

  Future<void> _start() async {
    if (widget.readOnly) return;
    setState(() {
      _phase = _TelegramPhase.starting;
      _error = null;
      _bot = '';
      _connectedBot = '';
      _allowed = [];
      _owner = '';
      _newId.clear();
    });
    final s = Strings.of(context);
    try {
      final setup = await widget.client.startTelegram(widget.profile);
      if (!mounted) return;
      setState(() {
        _setup = setup;
        _phase = _TelegramPhase.waiting;
      });
      _poll = Timer(_firstPoll, () => unawaited(_read()));
      // A one-second tick keeps the expiry countdown honest.
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } on MessagingRouteMissing {
      if (!mounted) return;
      setState(() {
        _phase = _TelegramPhase.idle;
        _missing = true;
      });
    } catch (error) {
      if (!mounted) return;
      final detail = error is MessagingRequestFailed ? error.detail : '';
      setState(() {
        _phase = _TelegramPhase.idle;
        _error = detail.isEmpty
            ? s.msgPlatTgStartFailed
            : s.msgPlatFailedDetail(s.msgPlatTgStartFailed, detail);
      });
    }
  }

  /// Desktop's poll: ready stops it; a pairing that is gone (410) or past
  /// its expiry starts over; any other failure keeps waiting, saying so.
  Future<void> _read() async {
    final setup = _setup;
    if (setup == null || _phase != _TelegramPhase.waiting) return;
    final s = Strings.of(context);
    try {
      final status = await widget.client.telegramStatus(
        setup.pairingId,
        widget.profile,
      );
      if (!mounted || !identical(setup, _setup)) return;
      if (status.ready) {
        setState(() {
          _phase = _TelegramPhase.ready;
          _bot = status.botUsername;
          _error = null;
          if (status.ownerUserId.isNotEmpty) {
            _owner = status.ownerUserId;
            _allowed = [status.ownerUserId];
          }
        });
        return;
      }
      setState(() => _error = null);
    } catch (error) {
      if (!mounted || !identical(setup, _setup)) return;
      final expiresAt = setup.expiresAt;
      final expired = expiresAt != null && !_now().isBefore(expiresAt);
      if (error is TelegramOnboardingGone || expired) {
        setState(() {
          _reset();
          _error = s.msgPlatTgPairingExpired;
        });
        return;
      }
      setState(() => _error = s.msgPlatTgStillWaiting);
    }
    _poll = Timer(_nextPoll, () => unawaited(_read()));
  }

  Future<void> _cancel() async {
    final setup = _setup;
    setState(_reset);
    if (setup == null) return;
    try {
      await widget.client.cancelTelegram(setup.pairingId, widget.profile);
    } catch (_) {
      // Local cleanup still wins; the server prunes expired pairings.
    }
  }

  void _addId() {
    final s = Strings.of(context);
    final id = _newId.text.trim();
    if (!MessagingPlatformsClient.telegramUserIdPattern.hasMatch(id)) {
      setState(() => _error = s.msgPlatTgNumericOnly);
      return;
    }
    setState(() {
      _error = null;
      if (!_allowed.contains(id)) _allowed = [..._allowed, id];
      _newId.clear();
    });
  }

  Future<void> _apply() async {
    final setup = _setup;
    if (setup == null || widget.readOnly) return;
    final s = Strings.of(context);
    if (_allowed.isEmpty) {
      setState(() => _error = s.msgPlatTgAddAtLeastOne);
      return;
    }
    setState(() {
      _phase = _TelegramPhase.applying;
      _error = null;
    });
    try {
      final result = await widget.client.applyTelegram(
        setup.pairingId,
        _allowed,
        widget.profile,
      );
      if (!mounted) return;
      final bot = result.botUsername.isEmpty ? _bot : result.botUsername;
      setState(() {
        _reset();
        _connectedBot = bot;
      });
      widget.onApplied(result);
    } catch (error) {
      if (!mounted) return;
      final detail = error is MessagingRequestFailed ? error.detail : '';
      final failed = s.msgPlatFailedSave(widget.platformName);
      setState(() {
        _phase = _TelegramPhase.ready;
        _error = detail.isEmpty
            ? failed
            : s.msgPlatFailedDetail(failed, detail);
      });
    }
  }

  List<Widget> _pairing(Strings s, TelegramOnboardingStart setup) {
    final expiry = messagingExpiry(setup.expiresAt, _now());
    final ready =
        _phase == _TelegramPhase.ready || _phase == _TelegramPhase.applying;
    final applying = _phase == _TelegramPhase.applying;
    return [
      const SizedBox(height: HermesSpace.x3),
      Wrap(
        spacing: HermesSpace.x2,
        runSpacing: HermesSpace.x2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (ready)
            HermesTag(label: s.msgPlatTgReady, tone: HermesStatusTone.ok)
          else
            HermesTag(
              key: const ValueKey('msgplat-tg-waiting'),
              label: s.msgPlatTgWaiting,
            ),
          if (ready && _bot.isNotEmpty)
            HermesTag(
              label: s.msgPlatHandle(_bot),
              tone: HermesStatusTone.neutral,
            ),
          HermesTag(
            label: expiry == null
                ? s.msgPlatTgExpired
                : s.msgPlatTgExpiresIn(expiry),
            tone: expiry == null
                ? HermesStatusTone.error
                : HermesStatusTone.neutral,
          ),
        ],
      ),
      if (!ready) ...[
        const SizedBox(height: HermesSpace.x2),
        _caption(context, s.msgPlatTgOpenHint),
      ],
      const SizedBox(height: HermesSpace.x2),
      Wrap(
        spacing: HermesSpace.x2,
        children: [
          TextButton.icon(
            key: const ValueKey('msgplat-tg-open'),
            onPressed: () => unawaited(widget.openUrl(setup.deepLink)),
            icon: const Icon(HIcons.open_in_new_rounded),
            label: Text(s.msgPlatTgOpenTelegram),
          ),
          if (!ready)
            TextButton(
              key: const ValueKey('msgplat-tg-cancel'),
              onPressed: () => unawaited(_cancel()),
              child: Text(s.commonCancel),
            ),
        ],
      ),
      if (ready) ...[
        const SizedBox(height: HermesSpace.x2),
        Wrap(
          spacing: HermesSpace.x2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              s.msgPlatTgAllowedUsers,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            if (_owner.isNotEmpty && _allowed.contains(_owner))
              HermesTag(
                label: s.msgPlatTgOwnerDetected,
                tone: HermesStatusTone.ok,
              ),
          ],
        ),
        const SizedBox(height: HermesSpace.x1),
        if (_allowed.isEmpty)
          _caption(context, s.msgPlatTgAddAtLeastOne)
        else
          Wrap(
            spacing: HermesSpace.x2,
            children: [
              for (final id in _allowed)
                InputChip(
                  key: ValueKey('msgplat-tg-id-$id'),
                  label: Text(id),
                  deleteButtonTooltipMessage: s.msgPlatTgRemoveId(id),
                  onDeleted: applying
                      ? null
                      : () => setState(
                          () => _allowed = [
                            for (final other in _allowed)
                              if (other != id) other,
                          ],
                        ),
                ),
            ],
          ),
        const SizedBox(height: HermesSpace.x2),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('msgplat-tg-new-id'),
                controller: _newId,
                enabled: !applying,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onSubmitted: (_) => _addId(),
                decoration: InputDecoration(
                  isDense: true,
                  labelText: s.msgPlatTgUserIdLabel,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: HermesSpace.x2),
            TextButton(
              key: const ValueKey('msgplat-tg-add'),
              onPressed: applying ? null : _addId,
              child: Text(s.msgPlatTgAdd),
            ),
          ],
        ),
        const SizedBox(height: HermesSpace.x3),
        Row(
          children: [
            Expanded(
              child: HermesActionButton(
                key: const ValueKey('msgplat-tg-apply'),
                primary: true,
                icon: HIcons.check_rounded,
                label: applying ? s.msgPlatSaving : s.msgPlatTgSaveAndRestart,
                onPressed: applying || widget.readOnly
                    ? null
                    : () => unawaited(_apply()),
              ),
            ),
            const SizedBox(width: HermesSpace.x2),
            TextButton(
              key: const ValueKey('msgplat-tg-cancel-review'),
              onPressed: applying ? null : () => unawaited(_cancel()),
              child: Text(s.commonCancel),
            ),
          ],
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final setup = _setup;
    final idle = _phase == _TelegramPhase.idle;
    final error = _error;
    return _Card(
      children: [
        Wrap(
          spacing: HermesSpace.x2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              s.msgPlatTgQuickSetup,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            HermesTag(label: s.msgPlatRecommended, tone: HermesStatusTone.ok),
          ],
        ),
        const SizedBox(height: HermesSpace.x1),
        _caption(context, s.msgPlatTgQuickHelp),
        if (_missing) ...[
          const SizedBox(height: HermesSpace.x2),
          _caption(
            context,
            s.msgPlatTgUnavailable,
            key: const ValueKey('msgplat-tg-unavailable'),
          ),
        ] else if (idle || _phase == _TelegramPhase.starting) ...[
          const SizedBox(height: HermesSpace.x3),
          HermesActionButton(
            key: const ValueKey('msgplat-tg-start'),
            primary: true,
            icon: HIcons.send_rounded,
            label: idle ? s.msgPlatTgCreate : s.msgPlatTgStarting,
            onPressed: idle && !widget.readOnly
                ? () => unawaited(_start())
                : null,
          ),
        ],
        if (idle && _connectedBot.isNotEmpty) ...[
          const SizedBox(height: HermesSpace.x2),
          Wrap(
            spacing: HermesSpace.x2,
            children: [
              HermesTag(
                label: s.msgPlatStateConnected,
                tone: HermesStatusTone.ok,
              ),
              HermesTag(
                label: s.msgPlatHandle(_connectedBot),
                tone: HermesStatusTone.neutral,
              ),
            ],
          ),
        ],
        if (widget.configured && idle && _connectedBot.isEmpty) ...[
          const SizedBox(height: HermesSpace.x2),
          _caption(context, s.msgPlatTgReplaceWarning),
        ],
        if (error != null) ...[
          const SizedBox(height: HermesSpace.x2),
          Semantics(
            liveRegion: true,
            child: HermesStatusText(
              key: const ValueKey('msgplat-tg-error'),
              label: error,
              tone: HermesStatusTone.error,
              maxLines: 4,
            ),
          ),
        ],
        if (setup != null) ..._pairing(s, setup),
      ],
    );
  }
}

/// Team Gateway account links for a platform the shared bot carries
/// (Desktop `app/messaging/relay-link.tsx` `RelayLinkSetup`): mint a
/// one-time code, send `/link <code>` to the bot, done. A Portal-managed
/// agent takes links only from the Portal, so there the card lists the
/// accounts and points to it.
class RelayLinkCard extends StatefulWidget {
  const RelayLinkCard({
    required this.client,
    required this.profile,
    required this.platformId,
    required this.platformName,
    required this.openUrl,
    this.readOnly = false,
    this.clock,
    super.key,
  });

  final MessagingPlatformsClient client;
  final String profile;
  final String platformId;
  final String platformName;
  final bool readOnly;
  final Future<void> Function(String url) openUrl;
  final DateTime Function()? clock;

  @override
  State<RelayLinkCard> createState() => _RelayLinkCardState();
}

class _RelayLinkCardState extends State<RelayLinkCard> {
  // Desktop `POLL_MS` and `MAX_POLL_ERRORS`.
  static const _pollEvery = Duration(seconds: 3);
  static const _maxPollErrors = 5;

  List<RelayAccount>? _accounts;
  String _botUrl = '';
  String _portalUrl = '';
  RelayLinkCode? _link;
  bool _busy = false;
  bool _missing = false;
  String? _error;
  String? _notice;
  Set<String> _linkedBefore = {};
  Timer? _poll;
  int _failures = 0;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  String _failureText(Strings s, Object error) {
    if (error is MessagingRequestFailed && error.detail.isNotEmpty) {
      return error.detail;
    }
    return s.msgPlatRelayFailed;
  }

  /// The linked accounts, or null when they could not be read.
  Future<List<RelayAccount>?> _load() async {
    try {
      final links = await widget.client.relayLinks(
        widget.platformId,
        widget.profile,
      );
      if (!mounted) return null;
      setState(() {
        _accounts = links.accounts;
        _botUrl = links.botUrl;
        _portalUrl = links.portalUrl;
        _error = null;
        _missing = false;
      });
      return links.accounts;
    } on MessagingRouteMissing {
      if (mounted) setState(() => _missing = true);
      return null;
    } catch (error) {
      if (mounted) {
        setState(() {
          _accounts = null;
          _error = _failureText(Strings.of(context), error);
        });
      }
      return null;
    }
  }

  bool _expired(RelayLinkCode link) {
    final at = link.expiresAt;
    return at != null && !_now().isBefore(at);
  }

  Future<void> _start() async {
    if (widget.readOnly || _busy) return;
    final s = Strings.of(context);
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      // What is linked right now: a failed load must not make every
      // account look new.
      final before = await _load();
      if (before == null || !mounted) return;
      final link = await widget.client.requestRelayLink(
        widget.platformId,
        widget.profile,
      );
      if (!mounted) return;
      _linkedBefore = {for (final a in before) a.platformUserId};
      _failures = 0;
      setState(() => _link = link);
      _poll = Timer(_pollEvery, () => unawaited(_read(link)));
    } catch (error) {
      if (mounted) setState(() => _error = _failureText(s, error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _read(RelayLinkCode link) async {
    if (!identical(link, _link)) return;
    final s = Strings.of(context);
    final RelayLinkState state;
    try {
      state = await widget.client.relayLinkState(link.code, widget.profile);
    } catch (error) {
      if (!mounted || !identical(link, _link)) return;
      _failures += 1;
      if (_failures >= _maxPollErrors || _expired(link)) {
        setState(() {
          _link = null;
          _error = _failureText(s, error);
        });
        return;
      }
      _poll = Timer(_pollEvery, () => unawaited(_read(link)));
      return;
    }
    if (!mounted || !identical(link, _link)) return;
    _failures = 0;
    switch (state) {
      case RelayLinkState.pending:
        _poll = Timer(_pollEvery, () => unawaited(_read(link)));
      case RelayLinkState.refused:
        setState(() {
          _link = null;
          _error = s.msgPlatRelayRefused(widget.platformName);
        });
      case RelayLinkState.inactive:
        await _settle(link);
    }
  }

  /// The code is no longer active. Reload first, then close the code.
  Future<void> _settle(RelayLinkCode link) async {
    final s = Strings.of(context);
    final after = await _load();
    if (!mounted) return;
    setState(() {
      _link = null;
      if (after == null) return;
      // `inactive` alone means used, expired or unknown: only a new
      // account id proves the link.
      if (after.any((a) => !_linkedBefore.contains(a.platformUserId))) {
        _notice = s.msgPlatRelayLinked(widget.platformName);
      } else if (_expired(link)) {
        _error = s.msgPlatRelayExpired;
      } else {
        _notice = s.msgPlatRelayNoNewAccount(widget.platformName);
      }
    });
  }

  Future<void> _unlink(RelayAccount account) async {
    if (widget.readOnly) return;
    final s = Strings.of(context);
    try {
      await widget.client.unlinkRelayAccount(
        widget.platformId,
        account.platformUserId,
        widget.profile,
      );
      await _load();
    } catch (_) {
      if (mounted) setState(() => _error = s.msgPlatRelayUnlinkFailed);
    }
  }

  Future<void> _copy(RelayLinkCode link) async {
    final s = Strings.of(context);
    await Clipboard.setData(ClipboardData(text: link.command));
    if (mounted) setState(() => _notice = s.msgPlatRelayCopied);
  }

  String _accountLabel(Strings s, RelayAccount account) {
    if (account.displayName.isNotEmpty) return account.displayName;
    final handle = account.handle.replaceFirst(RegExp('^@'), '');
    if (handle.isNotEmpty) return s.msgPlatHandle(handle);
    return account.platformUserId;
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final name = widget.platformName;
    final accounts = _accounts;
    final link = _link;
    final portal = _portalUrl;
    final openUrl = link == null || link.botUrl.isEmpty ? _botUrl : link.botUrl;
    final error = _error;
    final notice = _notice;
    if (_missing) {
      return _Card(
        children: [
          _caption(
            context,
            s.msgPlatRelayUnavailable,
            key: const ValueKey('msgplat-relay-unavailable'),
          ),
        ],
      );
    }
    return _Card(
      children: [
        Wrap(
          spacing: HermesSpace.x2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              s.msgPlatRelayTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            HermesTag(label: s.msgPlatRelayBadge, tone: HermesStatusTone.ok),
          ],
        ),
        const SizedBox(height: HermesSpace.x1),
        _caption(
          context,
          portal.isNotEmpty
              ? s.msgPlatRelayManagedIntro
              : s.msgPlatRelayIntro(name),
        ),
        const SizedBox(height: HermesSpace.x3),
        if (portal.isNotEmpty)
          HermesActionButton(
            key: const ValueKey('msgplat-relay-portal'),
            primary: true,
            icon: HIcons.open_in_new_rounded,
            label: s.msgPlatRelayOpenPortal,
            onPressed: () => unawaited(widget.openUrl(portal)),
          )
        else if (link == null)
          HermesActionButton(
            key: const ValueKey('msgplat-relay-link'),
            primary: true,
            icon: HIcons.link_rounded,
            label: accounts != null && accounts.isNotEmpty
                ? s.msgPlatRelayLinkAnother(name)
                : s.msgPlatRelayLink(name),
            onPressed: _busy || widget.readOnly
                ? null
                : () => unawaited(_start()),
          ),
        if (accounts != null && accounts.isNotEmpty) ...[
          const SizedBox(height: HermesSpace.x3),
          _caption(context, s.msgPlatRelayLinkedAccounts),
          for (final account in accounts)
            Row(
              key: ValueKey('msgplat-relay-account-${account.platformUserId}'),
              children: [
                Expanded(
                  child: Text(
                    _accountLabel(s, account),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (portal.isEmpty)
                  TextButton(
                    onPressed: widget.readOnly
                        ? null
                        : () => unawaited(_unlink(account)),
                    child: Text(s.msgPlatRelayUnlink),
                  ),
              ],
            ),
        ],
        if (notice != null) ...[
          const SizedBox(height: HermesSpace.x2),
          Semantics(
            liveRegion: true,
            child: _caption(
              context,
              notice,
              key: const ValueKey('msgplat-relay-notice'),
            ),
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: HermesSpace.x2),
          Semantics(
            liveRegion: true,
            child: HermesStatusText(
              key: const ValueKey('msgplat-relay-error'),
              label: error,
              tone: HermesStatusTone.error,
              maxLines: 4,
            ),
          ),
        ],
        if (link != null) ...[
          const SizedBox(height: HermesSpace.x3),
          Text(s.msgPlatRelayStepOpen(name)),
          const SizedBox(height: HermesSpace.x1),
          Text(s.msgPlatRelayStepSend),
          const SizedBox(height: HermesSpace.x1),
          SelectableText(
            link.command,
            key: const ValueKey('msgplat-relay-command'),
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          const SizedBox(height: HermesSpace.x2),
          Wrap(
            spacing: HermesSpace.x2,
            children: [
              if (openUrl.isNotEmpty)
                TextButton.icon(
                  onPressed: () => unawaited(widget.openUrl(openUrl)),
                  icon: const Icon(HIcons.open_in_new_rounded),
                  label: Text(s.msgPlatRelayOpen(name)),
                ),
              TextButton.icon(
                key: const ValueKey('msgplat-relay-copy'),
                onPressed: () => unawaited(_copy(link)),
                icon: const Icon(HIcons.copy_rounded),
                label: Text(s.msgPlatRelayCopy),
              ),
              TextButton(
                onPressed: () => setState(() {
                  _poll?.cancel();
                  _link = null;
                }),
                child: Text(s.commonCancel),
              ),
            ],
          ),
          const SizedBox(height: HermesSpace.x1),
          _caption(context, s.msgPlatRelayWaiting),
        ],
      ],
    );
  }
}
