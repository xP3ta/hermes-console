import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart' show HermesAppState;
import '../feedback/feedback_policy.dart';
import '../services/connection_manager.dart';
import '../services/screen_security.dart';
import '../services/shared_gateway_pool.dart';
import '../services/vault_service.dart';
import '../theme/app_theme.dart';
import '../widgets/console_loader.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import '../feedback/haptics.dart';

// Settings → «Contraseñas e inicios de sesión»: Hermes Desktop's Settings →
// Passwords & Logins (`apps/desktop/src/app/settings/vault-settings.tsx`)
// for the Hermes server's vault. The page shows metadata only; a secret is
// typed into a masked field with no autofill, suggestions or IME learning,
// sent once and wiped. The whole page is kept out of screenshots, screen
// recordings and the recents thumbnail (FLAG_SECURE), like Backups.

/// Separator between the facts of a row (identifier · origin · date).
const String _factSeparator = ' · ';

/// Example origins for the Add form (data, not copy).
const String _loginOriginExample = 'https://github.com';
const String _checkoutOriginExample = 'https://shop.example.com';

/// Pushes FLAG_SECURE for the page and returns its release.
typedef VaultSecureScope = Future<Future<void> Function()> Function();

Future<Future<void> Function()> _defaultSecureScope() async {
  final prefs = await SharedPreferences.getInstance();
  final lease = await ScreenSecurityService(prefs).pushSecureScope();
  return lease.release;
}

class VaultScreen extends StatefulWidget {
  const VaultScreen({
    required this.connection,
    required this.profile,
    this.gateway,
    this.secureScope = _defaultSecureScope,
    this.appLocked,
    super.key,
  });

  final SavedConnection connection;

  /// The Settings profile whose vault this is (Desktop's settings scope).
  final String profile;

  /// Tests inject a fake; otherwise the connection's shared gateway.
  final VaultGateway? gateway;
  final VaultSecureScope secureScope;

  /// True while App Lock covers the app; the app's own lock by default.
  /// What was typed in Add or Unlock is emptied when it locks.
  final ValueListenable<bool>? appLocked;

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  SharedGatewayLease? _lease;
  late final VaultController _controller;
  Future<void> Function()? _releaseSecure;
  bool _disposed = false;
  ValueListenable<bool>? _appLocked;

  @override
  void initState() {
    super.initState();
    _appLocked =
        widget.appLocked ??
        context.findAncestorStateOfType<HermesAppState>()?.appLock.locked;
    final injected = widget.gateway;
    final VaultGateway gateway;
    if (injected != null) {
      gateway = injected;
    } else {
      final lease = SharedGatewayPool.instance.acquire(widget.connection);
      _lease = lease;
      gateway = TuiVaultGateway(
        lease.client,
        profile: widget.profile,
        readOnly: widget.connection.readOnly,
      );
    }
    _controller = VaultController(gateway)..addListener(_onChanged);
    unawaited(_enterSecureScope());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) unawaited(_controller.refresh());
    });
  }

  Future<void> _enterSecureScope() async {
    try {
      final release = await widget.secureScope();
      if (_disposed) {
        await release();
        return;
      }
      _releaseSecure = release;
    } catch (error) {
      debugPrint('[vault] secure scope failed (${error.runtimeType})');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    _lease?.release();
    final release = _releaseSecure;
    if (release != null) unawaited(release());
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  bool get _readOnly => _controller.gateway.readOnly;

  String _profileName() {
    final value = widget.profile.trim();
    return value.isEmpty ? 'default' : value;
  }

  Future<void> _openAdd() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            VaultAddScreen(controller: _controller, appLocked: _appLocked),
      ),
    );
    if (saved == true && mounted) {
      AppFeedback.notify(
        context,
        FeedbackKind.routine,
        Strings.of(context).vltAdded,
      );
    }
  }

  Future<void> _remove(VaultItem item) async {
    final s = Strings.of(context);
    final feedback = AppFeedback.of(context);
    final confirmed = await showHermesConfirmDialog(
      context: context,
      title: s.vltDeleteTitle,
      message: s.vltDeleteBody(item.label),
      confirmLabel: s.vltDeleteConfirm,
      cancelLabel: s.commonCancel,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await _controller.run(() => _controller.gateway.remove(item.id));
    } on VaultFailure {
      feedback.notify(FeedbackKind.error, s.vltRemoveFailed);
    }
  }

  Future<void> _setSourceEnabled(VaultSource source, bool enabled) async {
    final s = Strings.of(context);
    final feedback = AppFeedback.of(context);
    HermesHaptics.selection();
    try {
      await _controller.run(
        () => _controller.gateway.setSourceEnabled(
          source.name,
          enabled: enabled,
        ),
      );
    } on VaultFailure {
      feedback.notify(FeedbackKind.error, s.vltSourceToggleFailed);
    }
  }

  Future<void> _lock(VaultSource source) async {
    final s = Strings.of(context);
    final feedback = AppFeedback.of(context);
    try {
      await _controller.run(() => _controller.gateway.lock(source.name));
    } on VaultFailure {
      feedback.notify(FeedbackKind.error, s.vltSourceToggleFailed);
    }
  }

  Future<void> _unlock(VaultSource source) async {
    final unlocked = await showHermesFloatingSurface<bool>(
      context: context,
      surfaceKey: const ValueKey('vault-unlock-dialog'),
      maxWidth: 420,
      builder: (_) => _UnlockDialog(
        controller: _controller,
        source: source,
        appLocked: _appLocked,
      ),
    );
    if (unlocked == true && mounted) {
      AppFeedback.notify(
        context,
        FeedbackKind.routine,
        Strings.of(context).vltUnlocked(source.displayName),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return Scaffold(
      key: const ValueKey('vault-screen'),
      appBar: HermesAppBar(
        title: Text(s.vltSettingsTitle),
        actions: [
          if (!_readOnly && _controller.phase == VaultPhase.ready)
            IconButton(
              key: const ValueKey('vault-add'),
              tooltip: s.commonAdd,
              onPressed: _controller.busy ? null : _openAdd,
              icon: const Icon(Icons.add_rounded),
            ),
        ],
      ),
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    switch (_controller.phase) {
      case VaultPhase.loading:
        return const Center(child: ConsoleLoader.medium());
      case VaultPhase.unsupported:
        return _StateMessage(
          key: const ValueKey('vault-unsupported'),
          text: s.vltUnsupported,
        );
      case VaultPhase.failed:
        return _StateMessage(
          key: const ValueKey('vault-failed'),
          text: _controller.failure == VaultFailureKind.unavailable
              ? s.vltUnavailable
              : s.vltLoadFailed,
          onRetry: _controller.refresh,
        );
      case VaultPhase.ready:
        break;
    }
    final items = _controller.items;
    return RefreshIndicator(
      onRefresh: _controller.refresh,
      child: ListView(
        key: const ValueKey('vault-list'),
        // Q9-CRISTAL: the vault passes under the glass header.
        clipBehavior: hermesUnderHeader,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          // Desktop names the profile so a non-default vault never looks
          // like the default one with entries missing (#121966).
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            // As wide as its text, not the whole row.
            child: Align(
              key: const ValueKey('vault-profile-badge'),
              alignment: AlignmentDirectional.centerStart,
              child: HermesBadge(
                s.vltProfile(_profileName()),
                color: colors.accent,
                dot: false,
              ),
            ),
          ),
          Text(
            s.vltBlurb,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: colors.textSecondary,
            ),
          ),
          if (_readOnly) ...[
            const SizedBox(height: 12),
            HermesInfoBanner(
              s.vltReadOnly,
              key: const ValueKey('vault-read-only'),
              icon: Icons.lock_outline_rounded,
            ),
          ],
          HermesSectionHeader(
            [
              s.vltSettingsTitle,
              if (items.isNotEmpty) s.vltCount(items.length),
            ].join(_factSeparator),
          ),
          if (items.isEmpty)
            HermesEmptyState(
              key: const ValueKey('vault-empty'),
              icon: Icons.key_outlined,
              title: s.vltEmpty,
              body: s.vltEmptyDesc,
              compact: true,
              primaryLabel: _readOnly ? null : s.commonAdd,
              primaryIcon: Icons.add_rounded,
              onPrimary: _readOnly || _controller.busy ? null : _openAdd,
            )
          else
            HermesGroup(
              children: [
                for (final item in items)
                  _ItemRow(
                    item: item,
                    sourceName: _sourceName(item.backend),
                    onRemove: _readOnly || !item.isLocal || _controller.busy
                        ? null
                        : () => _remove(item),
                  ),
              ],
            ),
          HermesSectionHeader(s.vltSourcesTitle),
          Text(
            s.vltSourcesBlurb,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          if (!_controller.sourcesKnown)
            Text(
              s.vltSourcesUnavailable,
              key: const ValueKey('vault-sources-unavailable'),
              style: TextStyle(fontSize: 13, color: colors.textSecondary),
            )
          else if (_controller.sources.isNotEmpty)
            HermesGroup(
              children: [
                for (final source in _controller.sources)
                  _SourceRow(
                    source: source,
                    busy: _controller.busy,
                    readOnly: _readOnly,
                    onToggle: (enabled) => _setSourceEnabled(source, enabled),
                    onUnlock: () => _unlock(source),
                    onLock: () => _lock(source),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  String _sourceName(String backend) {
    for (final source in _controller.sources) {
      if (source.name == backend) return source.displayName;
    }
    return backend;
  }
}

class _StateMessage extends StatelessWidget {
  const _StateMessage({required this.text, this.onRetry, super.key});

  final String text;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final retry = onRetry;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: colors.textSecondary),
            ),
            if (retry != null) ...[
              const SizedBox(height: 16),
              HermesSecondaryButton(
                key: const ValueKey('vault-retry'),
                label: Strings.of(context).commonRetry,
                onTap: () => unawaited(retry()),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One saved item: label, kind and «2FA auto» on the first line; the
/// identifier, the origin and the date under it. Never a secret.
class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.item,
    required this.sourceName,
    required this.onRemove,
  });

  final VaultItem item;
  final String sourceName;
  final VoidCallback? onRemove;

  String _kind(Strings s) => switch (item.kind) {
    'login' => s.vltKindLogin,
    'payment' => s.vltKindPayment,
    'address' => s.vltKindAddress,
    _ => item.kind,
  };

  String? _date(BuildContext context) {
    final parsed = DateTime.tryParse(item.createdAt);
    if (parsed == null) return null;
    return MaterialLocalizations.of(
      context,
    ).formatMediumDate(parsed.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final origin = item.origin;
    final date = _date(context);
    // The origin is left out when the label already is the host (items
    // saved on a page are labelled by host), as Desktop does.
    final shownOrigin =
        origin != null &&
            origin.replaceFirst(RegExp(r'^https?://'), '') != item.label
        ? origin
        : null;
    final facts = <String>[
      ?item.identifier,
      ?shownOrigin,
      if (date != null) s.vltCreatedOn(date),
    ].join(_factSeparator);
    return Padding(
      key: ValueKey('vault-item-${item.id}'),
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      item.label,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    HermesBadge(
                      _kind(s),
                      color: item.kind == 'login'
                          ? colors.accent
                          : colors.textSecondary,
                      dot: false,
                    ),
                    if (item.hasOtp)
                      HermesBadge(
                        s.vltTwoFactorBadge,
                        key: ValueKey('vault-otp-${item.id}'),
                        color: colors.success,
                        dot: false,
                      ),
                    if (!item.isLocal)
                      HermesBadge(
                        sourceName,
                        color: colors.textSecondary,
                        dot: false,
                      ),
                  ],
                ),
                if (facts.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    facts,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (item.isLocal && onRemove != null)
            IconButton(
              key: ValueKey('vault-remove-${item.id}'),
              // Each row says which item it removes, also to TalkBack.
              tooltip: s.vltRemoveItem(item.label),
              onPressed: onRemove,
              icon: Icon(Icons.delete_outline_rounded, color: colors.error),
            ),
        ],
      ),
    );
  }
}

/// One password manager: its status, the switch and Unlock / Lock.
class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.source,
    required this.busy,
    required this.readOnly,
    required this.onToggle,
    required this.onUnlock,
    required this.onLock,
  });

  final VaultSource source;
  final bool busy;
  final bool readOnly;
  final ValueChanged<bool> onToggle;
  final VoidCallback onUnlock;
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final status = !source.installed
        ? s.vltStatusNotDetected
        : !source.enabled
        ? s.vltStatusOff
        : source.unlocked
        ? s.vltStatusUnlocked
        : s.vltStatusLocked;
    final description = !source.installed
        ? s.vltSourceNotInstalled(source.displayName)
        : !source.enabled
        ? s.vltSourceDisabled
        : source.unlocked
        ? s.vltSourceUnlockedDesc
        : s.vltSourceLockedDesc;
    final canAct = !busy && !readOnly;
    return Padding(
      key: ValueKey('vault-source-${source.name}'),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      source.displayName,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    HermesBadge(
                      status,
                      color: source.enabled && source.unlocked
                          ? colors.accent
                          : colors.textSecondary,
                      dot: false,
                    ),
                  ],
                ),
              ),
              if (source.installed)
                Semantics(
                  label: source.displayName,
                  child: Switch(
                    key: ValueKey('vault-source-switch-${source.name}'),
                    value: source.enabled,
                    onChanged: canAct ? onToggle : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
          ),
          if (source.installed && source.enabled && !readOnly) ...[
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: source.unlocked
                  ? TextButton.icon(
                      key: ValueKey('vault-lock-${source.name}'),
                      onPressed: canAct ? onLock : null,
                      icon: const Icon(Icons.lock_outline_rounded, size: 18),
                      label: Text(s.vltLock),
                    )
                  : OutlinedButton.icon(
                      key: ValueKey('vault-unlock-${source.name}'),
                      onPressed: canAct ? onUnlock : null,
                      icon: const Icon(Icons.key_rounded, size: 18),
                      label: Text(s.vltUnlock),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The master password, typed once: wiped from the field as it is sent,
/// and after a refusal. It never reaches a store, a log or the clipboard.
class _UnlockDialog extends StatefulWidget {
  const _UnlockDialog({
    required this.controller,
    required this.source,
    required this.appLocked,
  });

  final VaultController controller;
  final VaultSource source;
  final ValueListenable<bool>? appLocked;

  @override
  State<_UnlockDialog> createState() => _UnlockDialogState();
}

class _UnlockDialogState extends State<_UnlockDialog> {
  final TextEditingController _password = TextEditingController();
  late final _HideWatch _hide = _HideWatch(widget.appLocked, _forget);
  bool _sending = false;

  /// Why the last try failed; null before any failure.
  VaultFailureKind? _failure;

  @override
  void initState() {
    super.initState();
    _hide.start();
  }

  /// The app went to the background or locked: the master password typed
  /// so far is dropped.
  void _forget() {
    if (_password.text.isEmpty) return;
    setState(_password.clear);
  }

  @override
  void dispose() {
    _hide.stop();
    _password
      ..clear()
      ..dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_sending || _password.text.isEmpty) return;
    var secret = _password.text;
    _password.clear();
    setState(() {
      _sending = true;
      _failure = null;
    });
    VaultFailureKind? failure;
    try {
      await widget.controller.run(
        () => widget.controller.gateway.unlock(widget.source.name, secret),
      );
    } on VaultFailure catch (error) {
      failure = error.kind;
    } finally {
      secret = '';
    }
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _sending = false;
      _failure = failure;
    });
  }

  /// A refusal is the master password; a dropped connection is not.
  String? _errorText(Strings s) => switch (_failure) {
    null => null,
    VaultFailureKind.rejected => s.vltUnlockFailed,
    VaultFailureKind.unavailable => s.vltUnavailable,
    VaultFailureKind.unsupported => s.vltUnsupported,
    VaultFailureKind.readOnly => s.vltReadOnly,
  };

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              s.vltUnlockTitle(widget.source.displayName),
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            s.vltUnlockBody,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 14),
          HermesField(
            fieldKey: const ValueKey('vault-master-password'),
            label: s.vltMasterPassword,
            controller: _password,
            obscure: true,
            autofill: false,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            // No visiblePassword: with it Android gets a «visible password»
            // field, and the keyboard may show or learn what is typed.
            autofocus: true,
            enabled: !_sending,
            errorText: _errorText(s),
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => unawaited(_submit()),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _sending
                    ? null
                    : () => Navigator.of(context).pop(false),
                child: Text(s.commonCancel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('vault-unlock-submit'),
                onPressed: _sending || _password.text.isEmpty
                    ? null
                    : () => unawaited(_submit()),
                child: Text(_sending ? s.vltUnlocking : s.vltUnlock),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The Add form (Desktop's Add dialog, full screen on a phone). Every field
/// is cleared before its controller is disposed; secret fields are masked,
/// with no autofill, no suggestions and no IME learning.
class VaultAddScreen extends StatefulWidget {
  const VaultAddScreen({required this.controller, this.appLocked, super.key});

  final VaultController controller;

  /// True while App Lock covers the app: every field is emptied then.
  final ValueListenable<bool>? appLocked;

  @override
  State<VaultAddScreen> createState() => _VaultAddScreenState();
}

class _VaultAddScreenState extends State<VaultAddScreen> {
  VaultKind _kind = VaultKind.login;
  VaultIdentifierType _idType = VaultIdentifierType.email;
  final _label = TextEditingController();
  final _origin = TextEditingController();
  final _identifier = TextEditingController();
  final _password = TextEditingController();
  final _otp = TextEditingController();
  final _cardNumber = TextEditingController();
  final _cardName = TextEditingController();
  final _expMonth = TextEditingController();
  final _expYear = TextEditingController();
  final _cvc = TextEditingController();
  final _postal = TextEditingController();
  final _line1 = TextEditingController();
  final _line2 = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _country = TextEditingController();

  late final List<TextEditingController> _all = [
    _label,
    _origin,
    _identifier,
    _password,
    _otp,
    _cardNumber,
    _cardName,
    _expMonth,
    _expYear,
    _cvc,
    _postal,
    _line1,
    _line2,
    _city,
    _state,
    _country,
  ];

  String? Function(Strings s)? _error;
  bool _saving = false;
  late final _HideWatch _hide = _HideWatch(widget.appLocked, _forget);

  @override
  void initState() {
    super.initState();
    _hide.start();
  }

  /// The app went to the background or locked: nothing typed waits in the
  /// form for whoever opens it next (R5C C-K2).
  void _forget() {
    if (_all.every((field) => field.text.isEmpty)) return;
    setState(() {
      for (final field in _all) {
        field.clear();
      }
    });
  }

  @override
  void dispose() {
    _hide.stop();
    for (final field in _all) {
      field
        ..clear()
        ..dispose();
    }
    super.dispose();
  }

  /// Desktop's `buildSecret`: the payload `vault.add` stores encrypted.
  Map<String, String> _secret() => switch (_kind) {
    VaultKind.login => {
      'identifier_type': _idType.wire,
      'identifier': _identifier.text.trim(),
      'password': _password.text,
      if (_otp.text.trim().isNotEmpty) 'otp_secret': _otp.text.trim(),
    },
    VaultKind.payment => {
      'card_number': _cardNumber.text.replaceAll(RegExp(r'\s+'), ''),
      'cardholder_name': _cardName.text.trim(),
      'exp_month': _expMonth.text.trim(),
      'exp_year': _expYear.text.trim(),
      'cvc': _cvc.text,
      'billing_postal_code': _postal.text.trim(),
    },
    VaultKind.address => {
      'address_line1': _line1.text.trim(),
      if (_line2.text.trim().isNotEmpty) 'address_line2': _line2.text.trim(),
      'city': _city.text.trim(),
      if (_state.text.trim().isNotEmpty) 'state': _state.text.trim(),
      'postal_code': _postal.text.trim(),
      'country': _country.text.trim(),
    },
  };

  String? Function(Strings s)? _validate() {
    if (_label.text.trim().isEmpty) return (s) => s.vltLabelRequired;
    if (!isValidVaultOrigin(_origin.text)) return (s) => s.vltOriginInvalid;
    switch (_kind) {
      case VaultKind.login:
        if (_identifier.text.trim().isEmpty || _password.text.isEmpty) {
          return (s) => s.vltLoginFieldsRequired;
        }
        if (!isValidVaultOtp(_otp.text)) return (s) => s.vltOtpInvalid;
      case VaultKind.payment:
        if (_cardNumber.text.trim().isEmpty ||
            _expMonth.text.trim().isEmpty ||
            _expYear.text.trim().isEmpty ||
            _cvc.text.isEmpty) {
          return (s) => s.vltPaymentFieldsRequired;
        }
      case VaultKind.address:
        if (_line1.text.trim().isEmpty ||
            _city.text.trim().isEmpty ||
            _postal.text.trim().isEmpty ||
            _country.text.trim().isEmpty) {
          return (s) => s.vltAddressFieldsRequired;
        }
    }
    return null;
  }

  Future<void> _submit() async {
    if (_saving) return;
    final invalid = _validate();
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    var secret = _secret();
    var ok = false;
    // No answer: it may have been saved (the list was read again).
    var unsure = false;
    try {
      await widget.controller.run(
        () => widget.controller.gateway.add(
          kind: _kind,
          label: _label.text.trim(),
          origin: _origin.text.trim(),
          secret: secret,
        ),
      );
      ok = true;
    } on VaultFailure catch (failure) {
      ok = false;
      unsure = failure.kind == VaultFailureKind.unavailable;
    } finally {
      // The only copy outside the fields: dropped either way.
      secret = const {};
    }
    if (!mounted) return;
    if (ok) {
      for (final field in _all) {
        field.clear();
      }
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _saving = false;
      _error = unsure ? (s) => s.vltSaveUnsure : (s) => s.vltSaveFailed;
    });
  }

  Widget _gap() => const SizedBox(height: 14);

  /// A field with no keyboard learning and no autofill; [secret] also
  /// masks it.
  Widget _field(
    String label,
    TextEditingController controller, {
    bool secret = false,
    String? hint,
    TextInputType? keyboard,
    int? maxLength,
    String? helper,
    Key? key,
  }) => HermesField(
    fieldKey: key,
    label: label,
    controller: controller,
    hint: hint,
    helperText: helper,
    obscure: secret,
    autofill: false,
    autocorrect: false,
    enableSuggestions: false,
    enableIMEPersonalizedLearning: false,
    // A masked field keeps the plain text keyboard, so Android is told it
    // is a password; visiblePassword would tell it the opposite.
    keyboardType: keyboard,
    maxLength: maxLength,
    enabled: !_saving,
  );

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final error = _error;
    return Scaffold(
      key: const ValueKey('vault-add-screen'),
      appBar: HermesAppBar(title: Text(s.vltAddTitle)),
      body: SafeArea(
        child: ListView(
          clipBehavior: hermesUnderHeader,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Text(
              s.vltAddDescription,
              style: TextStyle(fontSize: 13, color: colors.textSecondary),
            ),
            _gap(),
            Text(
              s.vltKindField,
              style: TextStyle(fontSize: 13, color: colors.textSecondary),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final kind in VaultKind.values)
                  ChoiceChip(
                    key: ValueKey('vault-kind-${kind.wire}'),
                    label: Text(switch (kind) {
                      VaultKind.login => s.vltKindLogin,
                      VaultKind.payment => s.vltKindPayment,
                      VaultKind.address => s.vltKindAddress,
                    }),
                    selected: _kind == kind,
                    onSelected: _saving
                        ? null
                        : (_) => setState(() {
                            _kind = kind;
                            _error = null;
                          }),
                  ),
              ],
            ),
            _gap(),
            _field(
              s.vltLabelField,
              _label,
              hint: s.vltLabelHint,
              key: const ValueKey('vault-label'),
            ),
            _gap(),
            _field(
              s.vltOriginField,
              _origin,
              hint: _kind == VaultKind.login
                  ? _loginOriginExample
                  : _checkoutOriginExample,
              keyboard: TextInputType.url,
              key: const ValueKey('vault-origin'),
            ),
            _gap(),
            ...switch (_kind) {
              VaultKind.login => _loginFields(s),
              VaultKind.payment => _paymentFields(s),
              VaultKind.address => _addressFields(s),
            },
            if (error != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  error(s) ?? '',
                  key: const ValueKey('vault-form-error'),
                  style: TextStyle(fontSize: 13, color: colors.error),
                ),
              ),
            ],
            const SizedBox(height: 20),
            HermesPrimaryButton(
              key: const ValueKey('vault-save'),
              label: _saving ? s.vltSaving : s.commonSave,
              onTap: _saving ? null : () => unawaited(_submit()),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _loginFields(Strings s) => [
    Text(
      s.vltIdTypeField,
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).hermes.textSecondary,
      ),
    ),
    const SizedBox(height: 6),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final type in VaultIdentifierType.values)
          ChoiceChip(
            key: ValueKey('vault-id-${type.wire}'),
            label: Text(switch (type) {
              VaultIdentifierType.email => s.vltIdEmail,
              VaultIdentifierType.phone => s.vltIdPhone,
              VaultIdentifierType.username => s.vltIdUsername,
            }),
            selected: _idType == type,
            onSelected: _saving ? null : (_) => setState(() => _idType = type),
          ),
      ],
    ),
    _gap(),
    _field(
      s.vltIdentifierField,
      _identifier,
      keyboard: switch (_idType) {
        VaultIdentifierType.email => TextInputType.emailAddress,
        VaultIdentifierType.phone => TextInputType.phone,
        VaultIdentifierType.username => TextInputType.text,
      },
      key: const ValueKey('vault-identifier'),
    ),
    _gap(),
    _field(
      s.commonPassword,
      _password,
      secret: true,
      key: const ValueKey('vault-password'),
    ),
    _gap(),
    _field(
      s.vltOtpFieldOptional,
      _otp,
      secret: true,
      hint: s.vltOtpPlaceholder,
      helper: s.vltOtpHint,
      key: const ValueKey('vault-otp'),
    ),
  ];

  List<Widget> _paymentFields(Strings s) => [
    _field(
      s.vltCardNumber,
      _cardNumber,
      secret: true,
      keyboard: TextInputType.number,
      key: const ValueKey('vault-card-number'),
    ),
    _gap(),
    _field(
      s.vltCardNameOptional,
      _cardName,
      key: const ValueKey('vault-card-name'),
    ),
    _gap(),
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _field(
            s.vltExpMonth,
            _expMonth,
            keyboard: TextInputType.number,
            maxLength: 2,
            key: const ValueKey('vault-exp-month'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _field(
            s.vltExpYear,
            _expYear,
            keyboard: TextInputType.number,
            maxLength: 4,
            key: const ValueKey('vault-exp-year'),
          ),
        ),
      ],
    ),
    _gap(),
    _field(
      s.vltCvc,
      _cvc,
      secret: true,
      keyboard: TextInputType.number,
      maxLength: 4,
      key: const ValueKey('vault-cvc'),
    ),
    _gap(),
    _field(
      s.vltPostalOptional,
      _postal,
      key: const ValueKey('vault-payment-postal'),
    ),
  ];

  List<Widget> _addressFields(Strings s) => [
    _field(s.vltLine1, _line1, key: const ValueKey('vault-line1')),
    _gap(),
    _field(s.vltLine2Optional, _line2, key: const ValueKey('vault-line2')),
    _gap(),
    _field(s.vltCity, _city, key: const ValueKey('vault-city')),
    _gap(),
    _field(s.vltStateOptional, _state, key: const ValueKey('vault-state')),
    _gap(),
    _field(s.vltPostal, _postal, key: const ValueKey('vault-address-postal')),
    _gap(),
    _field(s.vltCountry, _country, key: const ValueKey('vault-country')),
  ];
}

/// Calls [onHide] when the app goes to the background or App Lock locks
/// it, as Copias de seguridad does: what was typed in a vault form must not
/// wait there.
class _HideWatch with WidgetsBindingObserver {
  _HideWatch(this.locked, this.onHide);

  final ValueListenable<bool>? locked;
  final VoidCallback onHide;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    locked?.addListener(_onLock);
  }

  void stop() {
    WidgetsBinding.instance.removeObserver(this);
    locked?.removeListener(_onLock);
  }

  void _onLock() {
    if (locked?.value ?? false) onHide();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      onHide();
    }
  }
}
