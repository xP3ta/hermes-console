// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/hermes_design.dart'
    show
        HermesFadedEnd,
        HermesOption,
        HermesSelectField,
        HermesSpace,
        HermesType;
import '../../services/dashboard_address.dart';
import '../../services/native_password_login.dart';
import '../../services/server_warmup.dart' show isNousCloudHost;
import '../../services/ssh_manager.dart' show SshAuthMethod;
import '../../services/ssh_tunnel_connector.dart';
import '../../theme/app_theme.dart';
import '../../utils/ssh_error.dart' show localizedTunnelError;
import '../../widgets/hermes_ui.dart'
    show HermesField, HermesSectionHeader, HermesSwitchTile;
import '../../widgets/animated_hermes_logo.dart';
import '../../widgets/ssh_host_key_dialog.dart';
import '../recover_access_page.dart';
import 'connect_method_draft.dart';
import 'onboarding_motion.dart';
import 'onboarding_widgets.dart';

export 'connect_method_draft.dart'
    show ConnectDraft, ConnectMethod, ConnectRoute, ConnectWay;

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

/// Set when the address is the local end of an SSH tunnel: what the screen
/// needs to name the connection and to keep the SSH data once it signed in.
class ConnectTunnel {
  const ConnectTunnel({required this.sshHost, required this.remember});

  final String sshHost;

  /// Keep the SSH password (or the key's passphrase) on this phone.
  final bool remember;
}

/// What the form asks for, handed to the screen's own sign-in.
class ConnectRequest {
  const ConnectRequest({
    required this.url,
    required this.name,
    required this.method,
    required this.consent,
    this.user = '',
    this.secret = '',
    this.remember = false,
    this.connectionId,
    this.tunnel,
  });

  final String url;

  /// The label the person chose; empty keeps the address.
  final String name;
  final ConnectMethod method;
  final bool consent;
  final String user;

  /// The password, or the token; empty for the browser.
  final String secret;
  final bool remember;

  /// The id the connection must take, when something already carries it (an
  /// open SSH tunnel).
  final String? connectionId;
  final ConnectTunnel? tunnel;
}

/// Connect, like Desktop: the Dashboard's address (or an SSH host), then how
/// to sign in. The page only asks; [connect] is the screen's own sign-in and
/// saves a Dashboard-only connection. Secrets never leave this state.
class ManualConnectPage extends StatefulWidget {
  const ManualConnectPage({
    required this.connect,
    required this.onHelp,
    required this.onScan,
    this.onCancel,
    this.probe,
    this.tunnels,
    this.draft,
    this.way = ConnectWay.manual,
    super.key,
  });

  /// Null = connected and saved; otherwise why not.
  final Future<NativePasswordFailure?> Function(ConnectRequest request) connect;
  final VoidCallback onHelp;

  /// The typed state, when the screen that chose the way keeps it so that a
  /// change of way loses nothing. The page owns its own when null.
  final ConnectDraft? draft;

  /// The door this page was opened through: it sets the words at the top and
  /// what the form shows first; the fields are the same.
  final ConnectWay way;

  /// The QR scanner, for whoever installs the Hermes service.
  final VoidCallback onScan;

  /// Stops a browser sign-in that is waiting for the person.
  final VoidCallback? onCancel;
  final Future<HostProbeResult> Function(DiscoveryTarget)? probe;

  /// Opens the SSH tunnel of the SSH tab; the app's own when null.
  final SshTunnelOpener? tunnels;

  @override
  State<ManualConnectPage> createState() => _ManualConnectPageState();
}

enum _Check { idle, checking, found, unreachable, publicHttp }

/// Reads a copied Nous Cloud address out of free text.
abstract final class ManualConnectPageHosts {
  /// The first Nous Cloud host in [text] (`https://x.agents.nousresearch.com/…`
  /// or the bare host), lower-cased, or null. A host that only contains the
  /// Nous domain as a label of another one is not taken.
  static String? nousCloudHostIn(String text) {
    for (final m in RegExp(
      r'(?:https?://)?([A-Za-z0-9][A-Za-z0-9.-]*)',
    ).allMatches(text)) {
      final host = m.group(1)!;
      if (isNousCloudHost(host)) return host.toLowerCase();
    }
    return null;
  }
}

class _ManualConnectPageState extends State<ManualConnectPage>
    with WidgetsBindingObserver {
  /// The typed state: the caller's, or this page's own for as long as it is
  /// open. The draft is created in [initState] so that a page opened through
  /// one door starts turned towards it (route, sign-in method).
  late final ConnectDraft _draft;
  late final bool _ownsDraft;

  TextEditingController get _address => _draft.address;
  TextEditingController get _name => _draft.name;
  TextEditingController get _user => _draft.user;
  TextEditingController get _pass => _draft.pass;
  TextEditingController get _token => _draft.token;
  TextEditingController get _sshHost => _draft.sshHost;
  TextEditingController get _sshUser => _draft.sshUser;
  TextEditingController get _sshPort => _draft.sshPort;
  TextEditingController get _sshSecret => _draft.sshSecret;
  TextEditingController get _sshPassphrase => _draft.sshPassphrase;
  TextEditingController get _dashHost => _draft.dashHost;
  TextEditingController get _dashPort => _draft.dashPort;
  ConnectRoute get _route => _draft.route;
  set _route(ConnectRoute v) => _draft.route = v;
  ConnectMethod get _method => _draft.method;
  set _method(ConnectMethod v) => _draft.method = v;
  SshAuthMethod get _sshAuth => _draft.sshAuth;
  set _sshAuth(SshAuthMethod v) => _draft.sshAuth = v;
  bool get _remember => _draft.remember;
  set _remember(bool v) => _draft.remember = v;
  bool get _sshRemember => _draft.sshRemember;
  set _sshRemember(bool v) => _draft.sshRemember = v;

  Timer? _debounce;
  int _seq = 0;
  _Check _check = _Check.idle;
  bool _reveal = false;
  bool _consent = false;
  bool _busy = false;
  NativePasswordFailure? _failure;

  // SSH tab.
  final String _tunnelId = const Uuid().v4();
  String? _tunnelSignature;
  bool _tunnelOpening = false;
  bool _signedIn = false;
  SshKeyState _keyState = SshKeyState.empty;
  Object? _tunnelError;

  SshTunnelOpener? get _tunnels => widget.tunnels ?? SshTunnelConnector.current;

  bool get _nous => widget.way == ConnectWay.nous;

  @override
  void initState() {
    super.initState();
    final given = widget.draft;
    _ownsDraft = given == null;
    _draft = given ?? (ConnectDraft()..orient(widget.way));
    WidgetsBinding.instance.addObserver(this);
    // The Nous door never goes through SSH; the others keep the last route.
    if (_nous) _draft.route = ConnectRoute.direct;
    // A kept address is checked again on return.
    if (_address.text.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _typed();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    // A tunnel that never became a connection is closed with the page.
    if (!_signedIn && _tunnelSignature != null) {
      unawaited(_tunnels?.discard(_tunnelId));
    }
    if (_ownsDraft) _draft.dispose();
    super.dispose();
  }

  /// The Nous Portal page that lists the user's agents. The sign-in happens
  /// there, in the system browser, as on the Nous site.
  static final Uri _nousPortalAgents = Uri.parse(
    'https://portal.nousresearch.com/agents',
  );

  bool _portalOpened = false;
  bool _showNousAddress = false;
  bool _nousPasteFailed = false;

  Future<void> _openNousPortal() async {
    var opened = false;
    try {
      opened =
          await launchUrl(
            _nousPortalAgents,
            mode: LaunchMode.inAppBrowserView,
          ) ||
          await launchUrl(
            _nousPortalAgents,
            mode: LaunchMode.externalApplication,
          );
    } catch (_) {
      opened = false;
    }
    if (mounted && opened) {
      setState(() {
        _portalOpened = _address.text.trim().isEmpty;
        _nousPasteFailed = false;
      });
    }
  }

  /// The first Nous Cloud host in [text] (`https://x.agents.nousresearch.com/…`
  /// or the bare host), or null.
  static String? nousCloudHostIn(String text) =>
      ManualConnectPageHosts.nousCloudHostIn(text);

  Future<void> _pasteNousAddress() async {
    String? host;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      host = nousCloudHostIn(data?.text ?? '');
    } catch (_) {
      // Clipboard access can fail on return; keep manual entry reachable.
    }
    if (!mounted) return;
    setState(() {
      _portalOpened = false;
      _nousPasteFailed = host == null;
      if (host == null) _showNousAddress = true;
    });
    if (host == null) {
      return;
    }
    _address.text = host;
    _typed();
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the portal with an agent address copied: use it.
    if (state == AppLifecycleState.resumed &&
        _nous &&
        _portalOpened &&
        _address.text.trim().isEmpty) {
      // Consume this portal visit once, including when the clipboard is empty.
      _portalOpened = false;
      unawaited(_pasteNousAddress());
    }
  }

  /// What was typed, read as an address. Through the Nous door a bare host
  /// means https: Nous Cloud is never reached in the clear.
  String get _typedAddress {
    final text = _address.text.trim();
    return _nous && text.isNotEmpty && !text.contains('://')
        ? 'https://$text'
        : _address.text;
  }

  String? get _url => manualDashboardUrl(_typedAddress);

  /// The typed address names a Nous Cloud server.
  bool get _nousHost {
    final host = parseDashboardAddress(_typedAddress)?.host;
    return host != null && isNousCloudHost(host);
  }

  bool get _consentNeeded => _url != null && needsCleartextConsent(_url!);
  bool get _signInReady => switch (_method) {
    ConnectMethod.password =>
      _user.text.trim().isNotEmpty && _pass.text.isNotEmpty,
    ConnectMethod.browser => true,
    ConnectMethod.token => _token.text.trim().isNotEmpty,
  };

  bool get _ready =>
      _route == ConnectRoute.direct &&
      _url != null &&
      _check != _Check.publicHttp &&
      _signInReady &&
      (!_consentNeeded || _consent) &&
      !_busy;

  int? get _sshPortNumber => int.tryParse(_sshPort.text.trim());
  int? get _dashPortNumber => int.tryParse(_dashPort.text.trim());

  bool get _sshReady =>
      _route == ConnectRoute.ssh &&
      _tunnels != null &&
      _sshHost.text.trim().isNotEmpty &&
      _sshUser.text.trim().isNotEmpty &&
      SshTunnelRequest.validPort(_sshPortNumber) &&
      _sshSecret.text.trim().isNotEmpty &&
      (_sshAuth != SshAuthMethod.key ||
          (_keyState != SshKeyState.publicKey &&
              _keyState != SshKeyState.needsPassphrase)) &&
      _dashHost.text.trim().isNotEmpty &&
      SshTunnelRequest.validPort(_dashPortNumber) &&
      _signInReady &&
      !_busy;

  /// The key as it reads now; recomputed only when the key or its
  /// passphrase change.
  void _keyTyped() => setState(() {
    _tunnelError = null;
    _keyState = _sshAuth == SshAuthMethod.key
        ? checkSshKey(_sshSecret.text, _sshPassphrase.text)
        : SshKeyState.empty;
  });

  void _typed() {
    _debounce?.cancel();
    final seq = ++_seq;
    final target = parseDashboardAddress(_typedAddress);
    _consent = false;
    _failure = null;
    _nousPasteFailed = false;
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
    if (_route == ConnectRoute.ssh) return _goSsh();
    if (!_ready) return;
    final method = _method;
    setState(() {
      _busy = true;
      _failure = null;
    });
    final failure = await widget.connect(
      ConnectRequest(
        url: _url!,
        name: _name.text.trim(),
        method: method,
        consent: _consent,
        user: _user.text.trim(),
        secret: method == ConnectMethod.token ? _token.text.trim() : _pass.text,
        remember: _remember,
      ),
    );
    if (!mounted) return;
    if (failure == null) {
      _pass.clear();
      _token.clear();
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _failure = failure;
      if (failure == NativePasswordFailure.invalidCredentials) {
        _pass.clear();
        _token.clear();
      }
    });
  }

  /// SSH: the server key and the login (the tunnel), then the Dashboard
  /// sign-in through the local end of the tunnel.
  Future<void> _goSsh() async {
    final opener = _tunnels;
    if (!_sshReady || opener == null) return;
    final key = _sshAuth == SshAuthMethod.key;
    final request = SshTunnelRequest(
      id: _tunnelId,
      host: _sshHost.text.trim(),
      port: _sshPortNumber!,
      username: _sshUser.text.trim(),
      method: _sshAuth,
      secret: key ? _sshSecret.text.trim() : _sshSecret.text,
      passphrase: _sshPassphrase.text,
      dashHost: _dashHost.text.trim(),
      dashPort: _dashPortNumber!,
      remember: _sshRemember,
    );
    final method = _method;
    setState(() {
      _busy = true;
      _failure = null;
      _tunnelError = null;
      _tunnelOpening = true;
    });
    int port;
    try {
      // Another login or Dashboard than the open tunnel's is a new tunnel.
      if (_tunnelSignature != null && _tunnelSignature != request.signature) {
        await opener.discard(_tunnelId);
        _tunnelSignature = null;
      }
      port = await opener.open(request, (prompt) async {
        if (!mounted) return false;
        return showSshHostKeyDialog(context, prompt);
      });
      _tunnelSignature = request.signature;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _tunnelOpening = false;
        _tunnelError = e;
      });
      return;
    }
    if (!mounted) return;
    setState(() => _tunnelOpening = false);
    final failure = await widget.connect(
      ConnectRequest(
        url: 'http://127.0.0.1:$port',
        name: _name.text.trim().isEmpty ? request.host : _name.text.trim(),
        method: method,
        consent: false,
        user: _user.text.trim(),
        secret: method == ConnectMethod.token ? _token.text.trim() : _pass.text,
        remember: _remember,
        connectionId: _tunnelId,
        tunnel: ConnectTunnel(sshHost: request.host, remember: _sshRemember),
      ),
    );
    if (!mounted) return;
    if (failure == null) {
      _signedIn = true;
      _pass.clear();
      _token.clear();
      _sshSecret.clear();
      _sshPassphrase.clear();
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _failure = failure;
      if (failure == NativePasswordFailure.invalidCredentials) {
        _pass.clear();
        _token.clear();
      }
    });
  }

  Future<void> _importKey() async {
    final res = await FilePicker.platform.pickFiles(withData: true);
    final bytes = res == null || res.files.isEmpty
        ? null
        : res.files.first.bytes;
    if (bytes == null || !mounted) return;
    try {
      _sshSecret.text = utf8.decode(bytes).trim();
      _keyTyped();
    } catch (_) {
      // Not text: the field stays as it was.
    }
  }

  String? _errorText(Strings s) {
    final failure = _failure;
    if (failure == null) return null;
    return switch (_method) {
      ConnectMethod.browser => s.dashboardSetupBrowserIncomplete,
      ConnectMethod.token => switch (failure) {
        NativePasswordFailure.invalidCredentials => s.cnxTokenRejected,
        NativePasswordFailure.network => s.o2Unreachable,
        _ => s.o2ConnectionFailed,
      },
      ConnectMethod.password => switch (failure) {
        NativePasswordFailure.invalidCredentials => s.onb2WrongPassword,
        NativePasswordFailure.rateLimited => s.onb2TooManyTries,
        NativePasswordFailure.network => s.o2Unreachable,
        _ => s.o2ConnectionFailed,
      },
    };
  }

  /// The fields of a section, straight on the page: each one is already a
  /// box (its outline reads at 3:1), so no group is drawn around them; a box
  /// inside a box, split by a divider, read as neither on the device.
  Widget _fields(List<Widget> children) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: children,
  );

  /// A field of a section: its own row, rising on its own beat.
  Widget _row(int beat, Widget child) => RiseIn(
    delay: Duration(milliseconds: 140 + 25 * beat),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: HermesSpace.x2),
      child: child,
    ),
  );

  Widget _revealButton(Strings s) => IconButton(
    tooltip: _reveal ? s.onb2HidePassword : s.onb2ShowPassword,
    icon: Icon(
      _reveal ? Icons.visibility_off_rounded : Icons.visibility_rounded,
    ),
    onPressed: () => setState(() => _reveal = !_reveal),
  );

  /// The small supporting line every note, status and error shares.
  TextStyle _small(Color color, {FontWeight? weight}) =>
      TextStyle(fontSize: 13.5, height: 1.4, fontWeight: weight, color: color);

  Widget _note(String text, Color color, {Key? key}) => Padding(
    padding: const EdgeInsets.only(
      top: HermesSpace.x2,
      left: HermesSpace.x1,
      right: HermesSpace.x1,
    ),
    child: Text(text, key: key, style: _small(color)),
  );

  List<Widget> _direct(Strings s, HermesThemeColors c, String? status) {
    // The portal supplies the address. Manual entry is a fallback; the name
    // is the host and sign-in always uses the browser with the Nous account.
    if (_nous) {
      return [
        if (_portalOpened)
          Semantics(
            liveRegion: true,
            child: _note(
              s.nacNousWaitingAddress,
              c.textSecondary,
              key: const ValueKey('manual-nous-waiting'),
            ),
          ),
        if (_nousPasteFailed)
          Semantics(
            liveRegion: true,
            child: _note(
              s.nacNousPasteNone,
              c.textSecondary,
              key: const ValueKey('manual-nous-paste-failed'),
            ),
          ),
        if (_showNousAddress) ...[
          _fields([
            _row(
              0,
              HermesField(
                fieldKey: const ValueKey('manual-address'),
                controller: _address,
                label: s.onb4AddressLabel,
                hint: s.nacWayNousAddressHint,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.go,
                onChanged: (_) => _typed(),
                onSubmitted: (_) => unawaited(_go()),
              ),
            ),
          ]),
          OnbTextButton(
            key: const ValueKey('manual-nous-paste'),
            label: s.nacNousPasteAddress,
            onTap: _busy ? null : _pasteNousAddress,
          ),
        ] else
          OnbTextButton(
            key: const ValueKey('manual-nous-write-address'),
            label: s.nacNousWriteAddress,
            onTap: _busy ? null : () => setState(() => _showNousAddress = true),
          ),
        if (status != null)
          _note(
            status,
            _check == _Check.found ? c.textPrimary : c.textSecondary,
            key: const ValueKey('manual-status'),
          ),
      ];
    }
    return [
      HermesSectionHeader(s.cnxServer),
      _fields([
        _row(
          0,
          HermesField(
            fieldKey: const ValueKey('manual-address'),
            controller: _address,
            label: s.onb4AddressLabel,
            hint: _nous ? s.nacWayNousAddressHint : s.onb3AddressHint,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            onChanged: (_) => _typed(),
          ),
        ),
        _row(
          1,
          HermesField(
            fieldKey: const ValueKey('cnx-name'),
            controller: _name,
            label: s.cnxNameLabel,
            hint: s.cnxNameHint,
            textInputAction: TextInputAction.next,
          ),
        ),
      ]),
      if (status != null)
        _note(
          status,
          _check == _Check.found ? c.textPrimary : c.textSecondary,
          key: const ValueKey('manual-status'),
        ),
      _note(s.cnxAddressNote, c.textSecondary),
      if (_consentNeeded && _check != _Check.publicHttp)
        OnbConsent(
          key: const ValueKey('manual-consent'),
          value: _consent,
          label: s.dashboardSetupCredentialConsent,
          onChanged: (v) => setState(() => _consent = v),
        ),
      ..._signIn(s, c),
    ];
  }

  /// How the person proves who they are to the Dashboard.
  List<Widget> _signIn(Strings s, HermesThemeColors c) {
    final password = _method == ConnectMethod.password;
    return [
      HermesSectionHeader(s.cnxSignIn),
      _fields([
        _row(
          2,
          HermesSelectField<ConnectMethod>(
            key: const ValueKey('cnx-method'),
            value: _method,
            decoration: InputDecoration(labelText: s.cnxMethod),
            options: [
              HermesOption(
                key: const ValueKey('cnx-method-password'),
                value: ConnectMethod.password,
                label: s.cnxMethodPassword,
              ),
              HermesOption(
                key: const ValueKey('cnx-method-browser'),
                value: ConnectMethod.browser,
                label: s.cnxMethodBrowser,
              ),
              HermesOption(
                key: const ValueKey('cnx-method-token'),
                value: ConnectMethod.token,
                label: s.cnxMethodToken,
              ),
            ],
            onChanged: _busy
                ? null
                : (m) => setState(() {
                    _method = m;
                    _failure = null;
                  }),
          ),
        ),
        if (password) ...[
          _row(
            3,
            HermesField(
              fieldKey: const ValueKey('manual-user'),
              controller: _user,
              label: s.commonUser,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() {}),
            ),
          ),
          _row(
            4,
            HermesField(
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
              suffix: _revealButton(s),
            ),
          ),
          RiseIn(
            delay: const Duration(milliseconds: 265),
            // The tile paints its ink on the nearest Material.
            child: Material(
              type: MaterialType.transparency,
              child: HermesSwitchTile(
                controlKey: const ValueKey('cnx-remember'),
                title: s.cnxRemember,
                subtitle: s.cnxRememberNote,
                value: _remember,
                onChanged: _busy ? null : (v) => setState(() => _remember = v),
              ),
            ),
          ),
        ],
        if (_method == ConnectMethod.browser)
          _row(
            3,
            Text(
              s.cnxBrowserNote,
              key: const ValueKey('cnx-browser-note'),
              style: _small(c.textSecondary),
            ),
          ),
        if (_method == ConnectMethod.token)
          _row(
            3,
            HermesField(
              fieldKey: const ValueKey('cnx-token'),
              controller: _token,
              obscure: !_reveal,
              label: s.cnxTokenLabel,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              textInputAction: TextInputAction.go,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => unawaited(_go()),
              suffix: _revealButton(s),
            ),
          ),
      ]),
    ];
  }

  List<Widget> _ssh(Strings s, HermesThemeColors c) {
    final key = _sshAuth == SshAuthMethod.key;
    void changed(String _) => setState(() => _tunnelError = null);
    return [
      HermesSectionHeader(s.cnxServer),
      _fields([
        _row(
          0,
          HermesField(
            fieldKey: const ValueKey('cnx-ssh-host'),
            controller: _sshHost,
            label: s.cnxSshHost,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            onChanged: changed,
          ),
        ),
        _row(
          1,
          HermesField(
            fieldKey: const ValueKey('cnx-ssh-user'),
            controller: _sshUser,
            label: s.cnxSshUser,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            onChanged: changed,
          ),
        ),
        _row(
          2,
          HermesField(
            fieldKey: const ValueKey('cnx-ssh-port'),
            controller: _sshPort,
            label: s.cnxSshPort,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
            onChanged: changed,
          ),
        ),
        _row(
          3,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                s.cnxSshAuth,
                style: HermesType.text.copyWith(
                  fontWeight: FontWeight.w600,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(height: HermesSpace.x2),
              OnbSegmented<SshAuthMethod>(
                value: _sshAuth,
                onChanged: (v) => setState(() {
                  if (v == _sshAuth) return;
                  // A password and a key never share the field.
                  _sshAuth = v;
                  _sshSecret.clear();
                  _sshPassphrase.clear();
                  _keyState = SshKeyState.empty;
                  _tunnelError = null;
                }),
                options: [
                  (
                    SshAuthMethod.password,
                    s.cnxSshAuthPassword,
                    const ValueKey('cnx-ssh-auth-password'),
                  ),
                  (
                    SshAuthMethod.key,
                    s.cnxSshAuthKey,
                    const ValueKey('cnx-ssh-auth-key'),
                  ),
                ],
              ),
            ],
          ),
        ),
        _row(
          4,
          key
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    HermesField(
                      fieldKey: const ValueKey('cnx-ssh-key'),
                      controller: _sshSecret,
                      label: s.sshcPrivateKeyPem,
                      minLines: 3,
                      maxLines: 6,
                      autocorrect: false,
                      enableSuggestions: false,
                      onChanged: (_) => _keyTyped(),
                    ),
                    if (_keyState == SshKeyState.publicKey)
                      _note(
                        s.sshTPublicKey,
                        c.error,
                        key: const ValueKey('cnx-ssh-key-public'),
                      ),
                    const SizedBox(height: HermesSpace.x2),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OnbSmallPill(
                        key: const ValueKey('cnx-ssh-import'),
                        label: s.sshcImportFile,
                        onTap: () => unawaited(_importKey()),
                      ),
                    ),
                  ],
                )
              : HermesField(
                  fieldKey: const ValueKey('cnx-ssh-password'),
                  controller: _sshSecret,
                  obscure: !_reveal,
                  label: s.cnxSshPassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  onChanged: changed,
                  suffix: _revealButton(s),
                ),
        ),
        if (key &&
            (_keyState == SshKeyState.needsPassphrase ||
                _sshPassphrase.text.isNotEmpty))
          _row(
            5,
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                HermesField(
                  fieldKey: const ValueKey('cnx-ssh-passphrase'),
                  controller: _sshPassphrase,
                  obscure: !_reveal,
                  label: s.sshTPassphraseLabel,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  onChanged: (_) => _keyTyped(),
                  suffix: _revealButton(s),
                ),
                if (_sshPassphrase.text.isEmpty)
                  _note(
                    s.sshTPassphraseNeeded,
                    c.textSecondary,
                    key: const ValueKey('cnx-ssh-passphrase-note'),
                  ),
              ],
            ),
          ),
        Material(
          type: MaterialType.transparency,
          child: HermesSwitchTile(
            controlKey: const ValueKey('cnx-ssh-remember'),
            title: s.cnxRemember,
            subtitle: s.cnxRememberNote,
            value: _sshRemember,
            onChanged: _busy ? null : (v) => setState(() => _sshRemember = v),
          ),
        ),
        _row(
          6,
          HermesField(
            fieldKey: const ValueKey('cnx-dash-host'),
            controller: _dashHost,
            label: s.cnxDashHost,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            onChanged: changed,
          ),
        ),
        _row(
          7,
          HermesField(
            fieldKey: const ValueKey('cnx-dash-port'),
            controller: _dashPort,
            label: s.cnxDashPort,
            keyboardType: TextInputType.number,
            onChanged: changed,
          ),
        ),
      ]),
      _note(s.cnxSshNote, c.textSecondary),
      ..._signIn(s, c),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final c = Theme.of(context).hermes;
    // Through the Nous door a Nous Cloud address is named as such; the
    // reachability check still runs for any other address.
    final status = _nous && _nousHost && _check != _Check.publicHttp
        ? '✓ ${s.nacWayNousHostOk}'
        : switch (_check) {
            _Check.idle => null,
            _Check.checking => s.onb3Checking,
            _Check.found => '✓ ${s.onb3Found}',
            _Check.unreachable => s.onb3Unreachable,
            _Check.publicHttp => s.commonCleartextPublic,
          };
    final tunnelError = _tunnelError;
    final error = tunnelError != null
        ? localizedTunnelError(s, tunnelError)
        : _errorText(s);
    final direct = _route == ConnectRoute.direct;
    final waitingForBrowser =
        _busy && !_tunnelOpening && _method == ConnectMethod.browser;
    return Scaffold(
      backgroundColor: c.background,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The title sits in the header band beside the back
                // button, never in the scroll: there it was cut in half as
                // soon as the page scrolled a few pixels. The band grows
                // with the title (large text) and never below 56 dp.
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: kOnbGutter - HermesSpace.x2,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: HermesSpace.tap,
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: OnbBack(
                            onTap: () => Navigator.of(context).pop(),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: HermesSpace.tap,
                            vertical: HermesSpace.x1,
                          ),
                          child: RiseIn(
                            child: Semantics(
                              header: true,
                              child: Text(
                                _nous ? s.nacWayNousTitle : s.cnxTitle,
                                key: const ValueKey('cnx-title'),
                                textAlign: TextAlign.center,
                                textScaler: onbTitleScaler(context),
                                style: onbTitle(c, size: 26),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  // The rows dissolve into the page above the fixed button
                  // instead of being cut by it.
                  child: HermesFadedEnd(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: kOnbGutter,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: HermesSpace.x2),
                          // Through the Nous door: one line instead of the
                          // direct / SSH tabs (Nous Cloud is never SSH).
                          if (_nous) ...[
                            const Center(
                              child: AnimatedHermesLogo(
                                key: ValueKey('manual-nous-logo'),
                                size: HermesSpace.x8 * 2 + HermesSpace.x4,
                                animate: false,
                                orbit: false,
                                glow: false,
                              ),
                            ),
                            const SizedBox(height: HermesSpace.x4),
                            RiseIn(
                              delay: const Duration(milliseconds: 70),
                              child: Text(
                                s.nacWayNousPageBody,
                                key: const ValueKey('manual-nous-body'),
                                textAlign: TextAlign.center,
                                style: onbBody(c),
                              ),
                            ),
                            const SizedBox(height: HermesSpace.x3),
                            OnbSecondary(
                              key: const ValueKey('manual-nous-portal'),
                              label: s.nacNousOpenPortal,
                              onTap: _busy ? null : _openNousPortal,
                            ),
                          ] else
                            RiseIn(
                              delay: const Duration(milliseconds: 70),
                              child: OnbSegmented<ConnectRoute>(
                                value: _route,
                                onChanged: _busy
                                    ? (_) {}
                                    : (v) => setState(() => _route = v),
                                options: [
                                  (
                                    ConnectRoute.direct,
                                    s.cnxTabDirect,
                                    const ValueKey('cnx-tab-direct'),
                                  ),
                                  (
                                    ConnectRoute.ssh,
                                    s.cnxTabSsh,
                                    const ValueKey('cnx-tab-ssh'),
                                  ),
                                ],
                              ),
                            ),
                          ...direct ? _direct(s, c, status) : _ssh(s, c),
                          const SizedBox(height: 12),
                          if (!_nous) ...[
                            OnbTextButton(
                              key: const ValueKey('manual-scan'),
                              label: s.cnxScanQr,
                              onTap: widget.onScan,
                            ),
                            OnbTextButton(
                              key: const ValueKey('manual-dont-know'),
                              label: s.onb3DontKnow,
                              onTap: widget.onHelp,
                            ),
                          ],
                          // Room for the fade at the foot of the scroll.
                          const SizedBox(height: HermesSpace.x6),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    kOnbGutter,
                    HermesSpace.x2,
                    kOnbGutter,
                    HermesSpace.x4,
                  ),
                  child: RiseIn(
                    delay: const Duration(milliseconds: 300),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (error != null) ...[
                          Text(
                            error,
                            key: const ValueKey('manual-error'),
                            textAlign: TextAlign.center,
                            style: _small(c.error, weight: FontWeight.w600),
                          ),
                          if (tunnelError == null &&
                              _method == ConnectMethod.password &&
                              _failure ==
                                  NativePasswordFailure.invalidCredentials)
                            OnbTextButton(
                              key: const ValueKey('onb3-recover'),
                              label: s.dashboardSetupForgotPassword,
                              onTap: () =>
                                  unawaited(openRecoverAccess(context)),
                            ),
                          const SizedBox(height: 8),
                        ],
                        if (_tunnelOpening) ...[
                          Text(
                            s.sshTOpening,
                            key: const ValueKey('cnx-ssh-opening'),
                            textAlign: TextAlign.center,
                            style: _small(c.textSecondary),
                          ),
                          const SizedBox(height: 8),
                        ],
                        if (waitingForBrowser) ...[
                          Text(
                            '${s.dashboardSetupBrowserOpening} '
                            '${s.dashboardSetupBrowserComeBack}',
                            key: const ValueKey('cnx-browser-opening'),
                            textAlign: TextAlign.center,
                            style: _small(c.textSecondary),
                          ),
                          OnbTextButton(
                            key: const ValueKey('cnx-browser-cancel'),
                            label: s.commonCancel,
                            onTap: widget.onCancel,
                          ),
                        ],
                        OnbPrimary(
                          key: const ValueKey('manual-connect'),
                          label: s.o2Connect,
                          onTap: (direct ? _ready : _sshReady)
                              ? () => unawaited(_go())
                              : null,
                        ),
                      ],
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
