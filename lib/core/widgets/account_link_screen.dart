// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// The page of a device-code sign-in: the code, large and copyable; the
// button that opens the provider's page in the system browser; the wait,
// counted down; and one clear verdict at the end with a way to try again.
// It reports what [ProviderAccountLink] knows and nothing the server wrote.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../design/tokens.dart';
import '../feedback/feedback_policy.dart';
import '../services/provider_account_link.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import 'console_loader.dart';
import 'hermes_app_bar.dart';
import 'hermes_ui.dart' show HermesPrimaryButton, HermesSecondaryButton;

/// Opens the provider's page as a tab of the system browser (a custom tab
/// when the device has one), so the person comes straight back here; a
/// device without one gets the browser itself. Never an embedded web view.
Future<bool> openAccountLinkPage(Uri uri) async {
  try {
    if (await launchUrl(uri, mode: LaunchMode.inAppBrowserView)) return true;
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// `m:ss` of a remaining time.
String formatAccountLinkCountdown(Duration left) {
  final seconds = left.inSeconds.clamp(0, 359999);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// Drives one [ProviderAccountLink] and pops `true` once the account is
/// connected. The screen owns the link: closing it cancels a pending
/// attempt and leaves no timer behind.
class AccountLinkScreen extends StatefulWidget {
  const AccountLinkScreen({
    required this.link,
    required this.providerName,
    this.autoStart = true,
    this.openUrl,
    super.key,
  });

  final ProviderAccountLink link;
  final String providerName;

  /// Whether to call [ProviderAccountLink.start] when the page opens (false
  /// when the caller already did, under its own write guard).
  final bool autoStart;

  /// How the verification page is opened; the system browser by default.
  final Future<bool> Function(Uri uri)? openUrl;

  @override
  State<AccountLinkScreen> createState() => _AccountLinkScreenState();
}

class _AccountLinkScreenState extends State<AccountLinkScreen>
    with WidgetsBindingObserver {
  String? _openedSession;
  bool _openFailed = false;

  ProviderAccountLink get _link => widget.link;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _link.addListener(_onLink);
    if (widget.autoStart) {
      unawaited(_link.start());
    } else {
      _onLink();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _link.removeListener(_onLink);
    _link.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` is a passing moment (the shade, a permission prompt): the
    // flow keeps its pace; only a real departure stops it.
    _link.setForeground(
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive,
    );
  }

  void _onLink() {
    if (!mounted) return;
    final code = _link.code;
    if (_link.phase == AccountLinkPhase.waiting &&
        code != null &&
        code.sessionId != _openedSession) {
      _openedSession = code.sessionId;
      _openFailed = false;
      unawaited(_open(code));
    }
    setState(() {});
  }

  Future<void> _open(AccountLinkCode code) async {
    final uri = code.verificationUrl;
    if (uri == null) return;
    final ok = await (widget.openUrl ?? openAccountLinkPage)(uri);
    if (mounted && !ok) setState(() => _openFailed = true);
  }

  Future<void> _copyCode() async {
    final code = _link.code?.userCode;
    if (code == null || code.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    AppFeedback.of(
      context,
    ).notify(FeedbackKind.routine, Strings.of(context).nacLinkCodeCopied);
  }

  Future<void> _copyAddress() async {
    final address = _link.code?.unvettedUrl;
    if (address == null || address.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: address));
    if (!mounted) return;
    AppFeedback.of(
      context,
    ).notify(FeedbackKind.routine, Strings.of(context).nacLinkAddressCopied);
  }

  Future<void> _close() async {
    final approved = _link.phase == AccountLinkPhase.approved;
    if (_link.isPending) unawaited(_link.cancel());
    if (mounted) Navigator.of(context).pop(approved);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final name = widget.providerName;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _link.isPending) unawaited(_link.cancel());
      },
      child: Scaffold(
        appBar: HermesAppBar(
          title: Text(s.nacLinkTitle(name)),
          leading: IconButton(
            key: const ValueKey('nac-link-close'),
            icon: const Icon(Icons.close),
            tooltip: s.commonClose,
            onPressed: _close,
          ),
        ),
        body: ListView(
          clipBehavior: hermesUnderHeader,
          padding: const EdgeInsets.fromLTRB(
            HermesSpace.pageH,
            HermesSpace.pageTop,
            HermesSpace.pageH,
            HermesSpace.pageBottom,
          ),
          children: [
            AnimatedSwitcher(
              duration: HermesMotion.duration(context, HermesMotion.base),
              switchInCurve: HermesMotion.standard,
              switchOutCurve: HermesMotion.exit,
              child: KeyedSubtree(
                key: ValueKey(_link.phase),
                child: switch (_link.phase) {
                  AccountLinkPhase.idle || AccountLinkPhase.starting =>
                    _Starting(label: s.nacLinkPreparing),
                  AccountLinkPhase.waiting => _waiting(s, colors, name),
                  AccountLinkPhase.approved => _approved(s, colors, name),
                  _ => _verdict(s, colors),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _waiting(Strings s, HermesThemeColors colors, String name) {
    final code = _link.code!;
    final url = code.verificationUrl;
    final left = _link.remaining;
    return Column(
      key: const ValueKey('nac-link-waiting'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          url == null ? s.nacLinkIntroNoBrowser(name) : s.nacLinkIntro(name),
          style: HermesType.style(HermesType.text, colors.textSecondary),
        ),
        if (url == null && code.unvettedUrl.isNotEmpty) ...[
          const SizedBox(height: HermesSpace.x4),
          _AddressBox(
            address: code.unvettedUrl,
            caution: s.nacLinkAddressUnvetted(name),
            onCopy: _copyAddress,
          ),
        ],
        if (code.userCode.isNotEmpty) ...[
          const SizedBox(height: HermesSpace.x5),
          _CodeBox(code: code.userCode, onCopy: _copyCode),
          const SizedBox(height: HermesSpace.x2),
          Row(
            children: [
              Expanded(
                child: Text(
                  s.nacLinkExpiresIn(formatAccountLinkCountdown(left)),
                  key: const ValueKey('nac-link-countdown'),
                  style: HermesType.style(
                    HermesType.support,
                    colors.textSecondary,
                  ),
                ),
              ),
              TextButton.icon(
                key: const ValueKey('nac-link-copy'),
                onPressed: _copyCode,
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: Text(s.nacLinkCopyCode),
              ),
            ],
          ),
        ],
        const SizedBox(height: HermesSpace.x5),
        if (url != null)
          HermesPrimaryButton(
            key: const ValueKey('nac-link-open'),
            label: _openedSession == code.sessionId && !_openFailed
                ? s.nacLinkOpenAgain
                : s.nacLinkOpen(name),
            icon: Icons.open_in_browser_rounded,
            onTap: () => unawaited(_open(code)),
          ),
        if (_openFailed)
          Padding(
            padding: const EdgeInsets.only(top: HermesSpace.x2),
            child: Text(
              s.nacLinkOpenFailed,
              key: const ValueKey('nac-link-open-failed'),
              style: HermesType.style(HermesType.support, colors.error),
            ),
          ),
        const SizedBox(height: HermesSpace.x3),
        HermesSecondaryButton(
          key: const ValueKey('nac-link-check'),
          label: s.nacLinkCheckNow,
          icon: Icons.refresh_rounded,
          onTap: () => unawaited(_link.checkNow()),
        ),
        const SizedBox(height: HermesSpace.x6),
        Semantics(
          liveRegion: true,
          child: Row(
            children: [
              const ConsoleLoader.small(),
              const SizedBox(width: HermesSpace.x3),
              Expanded(
                child: Text(
                  s.nacLinkWaiting,
                  style: HermesType.style(
                    HermesType.support,
                    colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: HermesSpace.x4),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: const ValueKey('nac-link-cancel'),
            onPressed: _close,
            child: Text(s.commonCancel),
          ),
        ),
      ],
    );
  }

  Widget _approved(Strings s, HermesThemeColors colors, String name) {
    final email = _link.accountEmail;
    return Column(
      key: const ValueKey('nac-link-approved'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _VerdictHeader(
          icon: Icons.check_circle_rounded,
          color: colors.success,
          title: s.nacLinkApprovedTitle(name),
          body: email == null
              ? s.nacLinkApprovedBody
              : s.nacLinkApprovedAs(email),
          bodyKey: const ValueKey('nac-link-approved-body'),
        ),
        const SizedBox(height: HermesSpace.x6),
        HermesPrimaryButton(
          key: const ValueKey('nac-link-done'),
          label: s.nacLinkDone,
          icon: Icons.check_rounded,
          onTap: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }

  Widget _verdict(Strings s, HermesThemeColors colors) {
    final (title, body, icon, color) = switch (_link.phase) {
      AccountLinkPhase.denied => (
        s.nacLinkDeniedTitle,
        s.nacLinkDeniedBody,
        Icons.block_rounded,
        colors.warning,
      ),
      AccountLinkPhase.expired => (
        s.nacLinkExpiredTitle,
        s.nacLinkExpiredBody,
        Icons.timer_off_outlined,
        colors.warning,
      ),
      AccountLinkPhase.cancelled => (
        s.nacLinkCancelledTitle,
        s.nacLinkCancelledBody,
        Icons.undo_rounded,
        colors.textSecondary,
      ),
      AccountLinkPhase.offline => (
        s.nacLinkOfflineTitle,
        s.nacLinkOfflineBody,
        Icons.wifi_off_rounded,
        colors.error,
      ),
      AccountLinkPhase.unsupported => (
        s.nacLinkUnsupportedTitle,
        s.nacLinkUnsupportedBody,
        Icons.update_disabled_rounded,
        colors.textSecondary,
      ),
      AccountLinkPhase.readOnly => (
        s.nacLinkReadOnlyTitle,
        s.nacLinkReadOnlyBody,
        Icons.lock_outline_rounded,
        colors.textSecondary,
      ),
      _ => (
        s.nacLinkFailedTitle,
        _failedBody(s),
        Icons.error_outline_rounded,
        colors.error,
      ),
    };
    return Column(
      key: const ValueKey('nac-link-verdict'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _VerdictHeader(
          icon: icon,
          color: color,
          title: title,
          body: body,
          bodyKey: const ValueKey('nac-link-verdict-body'),
        ),
        const SizedBox(height: HermesSpace.x6),
        if (_link.canRetry)
          HermesPrimaryButton(
            key: const ValueKey('nac-link-retry'),
            label: s.nacLinkTryAgain,
            icon: Icons.refresh_rounded,
            onTap: () => unawaited(_link.start()),
          ),
        if (_link.canRetry) const SizedBox(height: HermesSpace.x3),
        HermesSecondaryButton(
          key: const ValueKey('nac-link-verdict-close'),
          label: s.commonClose,
          onTap: () => Navigator.of(context).pop(false),
        ),
      ],
    );
  }

  String _failedBody(Strings s) {
    if (_link.retryable == false) return s.nacLinkFailedNoRetry;
    final after = _link.retryAfter;
    if (after == null) return s.nacLinkFailedBody;
    final wait = after.inMinutes >= 1
        ? s.nacDurationMinutes(after.inMinutes)
        : s.nacDurationSeconds(after.inSeconds);
    return s.nacLinkFailedRetryAfter(wait);
  }
}

class _Starting extends StatelessWidget {
  const _Starting({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey('nac-link-starting'),
    padding: const EdgeInsets.symmetric(vertical: HermesSpace.x8),
    child: Center(child: ConsoleLoader.medium(showLabel: true, label: label)),
  );
}

/// The code, large, monospaced and copyable with one tap. Scales down
/// rather than wrapping or overflowing at large text sizes.
class _CodeBox extends StatelessWidget {
  const _CodeBox({required this.code, required this.onCopy});

  final String code;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      label: s.nacLinkCodeLabel,
      value: code.split('').join(' '),
      hint: s.nacLinkCopyCode,
      excludeSemantics: true,
      child: Material(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(HermesRadius.row),
        child: InkWell(
          key: const ValueKey('nac-link-code'),
          borderRadius: BorderRadius.circular(HermesRadius.row),
          onTap: onCopy,
          child: Container(
            constraints: const BoxConstraints(minHeight: 72),
            padding: const EdgeInsets.symmetric(
              horizontal: HermesSpace.x4,
              vertical: HermesSpace.x4,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(HermesRadius.row),
              border: Border.all(color: colors.accent.withValues(alpha: 0.6)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.nacLinkCodeLabel.toUpperCase(),
                  style: TextStyle(
                    fontSize: HermesType.sectionSize,
                    fontWeight: FontWeight.w600,
                    letterSpacing: HermesType.sectionTracking,
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: HermesSpace.x2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    code,
                    key: const ValueKey('nac-link-code-text'),
                    maxLines: 1,
                    style: TextStyle(
                      fontFamily: HermesType.monoFamily,
                      fontSize: HermesType.codeSize,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 4,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An address the app does not open itself: selectable, copyable, with the
/// reason it is not a button.
class _AddressBox extends StatelessWidget {
  const _AddressBox({
    required this.address,
    required this.caution,
    required this.onCopy,
  });

  final String address;
  final String caution;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Container(
      key: const ValueKey('nac-link-address'),
      padding: const EdgeInsets.all(HermesSpace.x3),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(HermesRadius.row),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(
            address,
            key: const ValueKey('nac-link-address-text'),
            style: TextStyle(
              fontFamily: HermesType.monoFamily,
              fontSize: HermesType.supportSize,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: HermesSpace.x2),
          Text(
            caution,
            style: HermesType.style(HermesType.support, colors.textSecondary),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              key: const ValueKey('nac-link-copy-address'),
              onPressed: onCopy,
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: Text(s.nacLinkCopyAddress),
            ),
          ),
        ],
      ),
    );
  }
}

class _VerdictHeader extends StatelessWidget {
  const _VerdictHeader({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    this.bodyKey,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final Key? bodyKey;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 36, color: color),
          const SizedBox(height: HermesSpace.x3),
          Text(
            title,
            key: const ValueKey('nac-link-verdict-title'),
            style: HermesType.style(HermesType.title, colors.textPrimary),
          ),
          const SizedBox(height: HermesSpace.x2),
          Text(
            body,
            key: bodyKey,
            style: HermesType.style(HermesType.text, colors.textSecondary),
          ),
        ],
      ),
    );
  }
}
