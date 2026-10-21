// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../services/dashboard_address.dart';
import '../../services/native_password_login.dart';
import '../../theme/app_theme.dart';
import '../../widgets/hermes_ui.dart' show HermesField;
import '../recover_access_page.dart';
import 'onboarding_motion.dart';
import 'onboarding_widgets.dart';

/// Cleartext http needs the owner's word unless it stays on this phone.
bool needsCleartextConsent(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme == 'https') return false;
  return uri.host != 'localhost' &&
      !(InternetAddress.tryParse(uri.host)?.isLoopback ?? false);
}

/// The Dashboard address Connect signs in to, from what was typed.
String? manualDashboardUrl(String raw) {
  final t = parseDashboardAddress(raw);
  if (t == null) return null;
  return Uri(
    scheme: t.secure ? 'https' : 'http',
    host: t.host,
    port: t.secure && t.port == 443 ? null : t.port,
  ).toString();
}

/// Connect by hand, like Desktop: one address, a user and a password. The
/// page only asks; [connect] is the screen's own sign-in and saves a
/// Dashboard-only connection. The password never leaves this state.
class ManualConnectPage extends StatefulWidget {
  const ManualConnectPage({
    required this.connect,
    required this.onHelp,
    this.probe,
    super.key,
  });

  /// Null = connected and saved; otherwise why not.
  final Future<NativePasswordFailure?> Function(
    String url,
    String user,
    String password,
    bool consent,
  )
  connect;
  final VoidCallback onHelp;
  final Future<HostProbeResult> Function(DiscoveryTarget)? probe;

  @override
  State<ManualConnectPage> createState() => _ManualConnectPageState();
}

enum _Check { idle, checking, found, unreachable, publicHttp }

class _ManualConnectPageState extends State<ManualConnectPage> {
  final _address = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  Timer? _debounce;
  int _seq = 0;
  _Check _check = _Check.idle;
  bool _reveal = false;
  bool _consent = false;
  bool _busy = false;
  NativePasswordFailure? _failure;

  @override
  void dispose() {
    _debounce?.cancel();
    _address.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  String? get _url => manualDashboardUrl(_address.text);
  bool get _consentNeeded => _url != null && needsCleartextConsent(_url!);
  bool get _ready =>
      _url != null &&
      _check != _Check.publicHttp &&
      _user.text.trim().isNotEmpty &&
      _pass.text.isNotEmpty &&
      (!_consentNeeded || _consent) &&
      !_busy;

  void _typed() {
    _debounce?.cancel();
    final seq = ++_seq;
    final target = parseDashboardAddress(_address.text);
    _consent = false;
    _failure = null;
    if (target == null) {
      setState(() => _check = _Check.idle);
      return;
    }
    if (target.publicCleartext) {
      // Nothing to ask: cleartext to a public host never leaves the phone.
      setState(() => _check = _Check.publicHttp);
      return;
    }
    setState(() => _check = _Check.checking);
    _debounce = Timer(const Duration(milliseconds: 600), () async {
      HostProbeResult r;
      try {
        r = await (widget.probe ?? probeHost)(target);
      } catch (_) {
        r = const HostProbeResult(HostVerdict.silent);
      }
      if (!mounted || seq != _seq) return;
      setState(
        () => _check = switch (r.verdict) {
          HostVerdict.hermes => _Check.found,
          HostVerdict.publicCleartext => _Check.publicHttp,
          _ => _Check.unreachable,
        },
      );
    });
  }

  Future<void> _go() async {
    if (!_ready) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    final failure = await widget.connect(
      _url!,
      _user.text.trim(),
      _pass.text,
      _consent,
    );
    if (!mounted) return;
    if (failure == null) {
      _pass.clear();
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _failure = failure;
      if (failure == NativePasswordFailure.invalidCredentials) _pass.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final c = Theme.of(context).hermes;
    final status = switch (_check) {
      _Check.idle => null,
      _Check.checking => s.onb3Checking,
      _Check.found => '✓ ${s.onb3Found}',
      _Check.unreachable => s.onb3Unreachable,
      _Check.publicHttp => s.commonCleartextPublic,
    };
    final error = switch (_failure) {
      null => null,
      NativePasswordFailure.invalidCredentials => s.onb2WrongPassword,
      NativePasswordFailure.rateLimited => s.onb2TooManyTries,
      NativePasswordFailure.network => s.o2Unreachable,
      _ => s.o2ConnectionFailed,
    };
    return Scaffold(
      backgroundColor: c.background,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              kOnbGutter,
              0,
              kOnbGutter,
              MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: box.maxHeight,
                  maxWidth: 520,
                ),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: 56,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Transform.translate(
                            offset: const Offset(-8, 0),
                            child: OnbBack(
                              onTap: () => Navigator.of(context).pop(),
                            ),
                          ),
                        ),
                      ),
                      RiseIn(
                        child: Semantics(
                          header: true,
                          child: Text(
                            s.o2Manual,
                            textAlign: TextAlign.center,
                            textScaler: onbTitleScaler(context),
                            style: onbTitle(c, size: 26),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      RiseIn(
                        delay: const Duration(milliseconds: 70),
                        child: Text(
                          s.onb4ManualBody,
                          textAlign: TextAlign.center,
                          style: onbBody(c),
                        ),
                      ),
                      const SizedBox(height: 22),
                      RiseIn(
                        delay: const Duration(milliseconds: 140),
                        child: HermesField(
                          fieldKey: const ValueKey('manual-address'),
                          controller: _address,
                          label: s.onb4AddressLabel,
                          hint: s.onb3AddressHint,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          enableSuggestions: false,
                          textInputAction: TextInputAction.next,
                          onChanged: (_) => _typed(),
                        ),
                      ),
                      if (status != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6, left: 4),
                          child: Text(
                            status,
                            key: const ValueKey('manual-status'),
                            style: TextStyle(
                              fontSize: 13.5,
                              color: _check == _Check.found
                                  ? c.textPrimary
                                  : c.textSecondary,
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      RiseIn(
                        delay: const Duration(milliseconds: 190),
                        child: HermesField(
                          fieldKey: const ValueKey('manual-user'),
                          controller: _user,
                          label: s.commonUser,
                          autocorrect: false,
                          enableSuggestions: false,
                          textInputAction: TextInputAction.next,
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(height: 12),
                      RiseIn(
                        delay: const Duration(milliseconds: 240),
                        child: HermesField(
                          fieldKey: const ValueKey('manual-password'),
                          controller: _pass,
                          obscure: !_reveal,
                          label: s.commonPassword,
                          autocorrect: false,
                          enableSuggestions: false,
                          enableIMEPersonalizedLearning: false,
                          textInputAction: TextInputAction.go,
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => unawaited(_go()),
                          suffix: IconButton(
                            tooltip: _reveal
                                ? s.onb2HidePassword
                                : s.onb2ShowPassword,
                            icon: Icon(
                              _reveal
                                  ? Icons.visibility_off_rounded
                                  : Icons.visibility_rounded,
                            ),
                            onPressed: () => setState(() => _reveal = !_reveal),
                          ),
                        ),
                      ),
                      if (_consentNeeded && _check != _Check.publicHttp)
                        OnbConsent(
                          key: const ValueKey('manual-consent'),
                          value: _consent,
                          label: s.dashboardSetupCredentialConsent,
                          onChanged: (v) => setState(() => _consent = v),
                        ),
                      if (error != null) ...[
                        RiseIn(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              error,
                              key: const ValueKey('manual-error'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13.5,
                                height: 1.35,
                                fontWeight: FontWeight.w600,
                                color: c.error,
                              ),
                            ),
                          ),
                        ),
                        if (_failure ==
                            NativePasswordFailure.invalidCredentials)
                          OnbTextButton(
                            key: const ValueKey('onb3-recover'),
                            label: s.dashboardSetupForgotPassword,
                            onTap: () => unawaited(openRecoverAccess(context)),
                          ),
                      ],
                      const SizedBox(height: 28),
                      RiseIn(
                        delay: const Duration(milliseconds: 300),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            OnbPrimary(
                              key: const ValueKey('manual-connect'),
                              label: s.o2Connect,
                              onTap: _ready ? () => unawaited(_go()) : null,
                            ),
                            const SizedBox(height: 6),
                            OnbTextButton(
                              key: const ValueKey('manual-dont-know'),
                              label: s.onb3DontKnow,
                              onTap: widget.onHelp,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
