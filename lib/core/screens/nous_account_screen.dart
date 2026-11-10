// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// The Nous Portal account of one Hermes: where it is connected and
// disconnected from, and the shared flow every entry point (Models,
// Settings, the first run, the chat's model sheet) runs.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart' show HermesAppState;
import '../design/hermes_design.dart'
    show
        HermesAction,
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesSpace,
        HermesType,
        showHermesDialog,
        showHermesMenu;
import '../feedback/feedback_policy.dart';
import '../models/oauth_account.dart';
import '../services/active_profile_scope.dart';
import '../services/connection_manager.dart';
import '../services/provider_account_link.dart';
import '../theme/app_theme.dart';
import '../widgets/account_link_screen.dart';
import '../widgets/console_loader.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_ui.dart' show HermesNavRow;
import '../widgets/nous_account_card.dart';
import '../widgets/read_only.dart';
import 'lock_screen.dart';
import 'models_screen.dart' show ModelsScreen, normalizeProviderOAuthBrowserUrl;

/// What a sign-in ended with: whether the server confirmed it and, when it
/// said, who signed in.
typedef ProviderAccountOutcome = ({bool approved, String? accountEmail});

const ProviderAccountOutcome _notConnected = (
  approved: false,
  accountEmail: null,
);

/// Runs the device-code sign-in of [account] on [profile]; `approved` once
/// the server confirms it. Read-only connections are refused before
/// anything is sent. [start] lets a caller run the first request under its
/// own write guard; the screen then only polls.
Future<ProviderAccountOutcome> connectProviderAccount({
  required BuildContext context,
  required DashboardClient client,
  required SavedConnection connection,
  required OAuthAccount account,
  required String? profile,
  Future<bool> Function(Future<void> Function() body)? start,
  Future<bool> Function(Uri uri)? openUrl,
}) async {
  if (connection.readOnly) {
    showReadOnlyNotice(context);
    return _notConnected;
  }
  final link = ProviderAccountLink.forClient(
    client,
    providerId: account.id,
    profile: profile,
    readOnly: connection.readOnly,
    policy: AccountLinkUrlPolicy.forProvider(
      account.id,
      dashboardBaseUrl: client.baseUrl,
    ),
    normalizeUrl: (url) => normalizeProviderOAuthBrowserUrl(
      url,
      connection: connection,
      dashboardBaseUrl: client.baseUrl,
    ),
  );
  var started = false;
  if (start != null) {
    started = await start(link.start);
    if (!started || !context.mounted) {
      link.dispose();
      return _notConnected;
    }
  }
  final approved = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => AccountLinkScreen(
        link: link,
        providerName: account.name,
        autoStart: !started,
        openUrl: openUrl,
      ),
    ),
  );
  // The screen disposed the link on its way out; its last verdict stays
  // readable.
  if (approved == true && context.mounted) {
    forgetChatModelCatalogs(context, connection);
  }
  return (approved: approved == true, accountEmail: link.accountEmail);
}

/// An account linked or removed on the server changes the models every
/// profile of [connection] may offer: the chat's model picker asks again on
/// its next open instead of painting its copy.
void forgetChatModelCatalogs(BuildContext context, SavedConnection connection) {
  final app = context.findAncestorStateOfType<HermesAppState>();
  if (app == null) return;
  app.activeChats.modelPickerCache.invalidateConnection(connection.id);
  app.activeChats.modelCatalogCache.invalidateConnection(connection.id);
}

/// Asks, verifies App Lock when the app has one, and removes the credential
/// of [account] on the server. True when the server removed it. [run] lets
/// a caller send the request under its own write guard (a confirmation
/// opened for one profile is never replayed on another).
Future<bool> disconnectProviderAccount({
  required BuildContext context,
  required DashboardClient client,
  required SavedConnection connection,
  required OAuthAccount account,
  required String? profile,
  Future<bool> Function(Future<void> Function() body)? run,
}) async {
  final s = Strings.of(context);
  if (connection.readOnly) {
    showReadOnlyNotice(context);
    return false;
  }
  final confirmed = await showHermesDialog<bool>(
    context: context,
    title: s.nacCardDisconnectTitle(account.name),
    message: s.nacCardDisconnectBody,
    actions: [
      HermesDialogAction(
        label: s.commonCancel,
        value: false,
        style: HermesDialogActionStyle.cancel,
      ),
      HermesDialogAction(
        key: const ValueKey('nac-disconnect-confirm'),
        label: s.nacCardDisconnect,
        value: true,
        style: HermesDialogActionStyle.destructive,
      ),
    ],
  );
  if (confirmed != true || !context.mounted) return false;
  final lock = context.findAncestorStateOfType<HermesAppState>()?.appLock;
  if (lock != null) {
    final ok = await LockScreen.verify(
      context,
      lock,
      reason: s.nacCardUnlockReason(account.name),
    );
    if (!ok || !context.mounted) return false;
  }
  final link = ProviderAccountLink.forClient(
    client,
    providerId: account.id,
    profile: profile,
    readOnly: connection.readOnly,
  );
  var removed = false;
  Future<void> body() async {
    removed = await link.disconnect();
  }

  try {
    final sent = run == null ? await body().then((_) => true) : await run(body);
    if (!sent || !context.mounted) return removed;
    if (removed) forgetChatModelCatalogs(context, connection);
    if (!removed) {
      AppFeedback.of(context).notify(FeedbackKind.error, switch (link.phase) {
        AccountLinkPhase.unsupported => s.nacLinkUnsupportedTitle,
        AccountLinkPhase.offline => s.nacLinkOfflineTitle,
        _ => s.nacCardStillConnected(account.name),
      });
    }
    return removed;
  } finally {
    link.dispose();
  }
}

/// The actions of a connected account: sign in with another one, or
/// disconnect.
enum ProviderAccountAction { reconnect, disconnect }

Future<ProviderAccountAction?> showProviderAccountMenu(
  BuildContext context,
  OAuthAccount account,
) {
  final s = Strings.of(context);
  return showHermesMenu<ProviderAccountAction>(
    context: context,
    title: account.name,
    actions: [
      if (account.canSignInHere)
        HermesAction(
          key: ValueKey('models-account-signin-${account.id}'),
          value: ProviderAccountAction.reconnect,
          label: account.isNous ? s.nacCardReconnect : s.mdlAccountSignInAgain,
        ),
      if (account.disconnectable)
        HermesAction(
          key: ValueKey('models-account-disconnect-${account.id}'),
          value: ProviderAccountAction.disconnect,
          label: account.isNous ? s.nacCardDisconnect : s.mdlRemove,
          destructive: true,
        ),
    ],
  );
}

/// Settings › Server › Nous Portal account, and the page the first run
/// offers after a server is connected.
class NousAccountScreen extends StatefulWidget {
  const NousAccountScreen({
    required this.connection,
    this.profileScope,
    this.dashboardClientForTesting,
    this.openUrlForTesting,
    super.key,
  });

  final SavedConnection connection;
  final ActiveProfileScope? profileScope;
  final DashboardClient? dashboardClientForTesting;
  final Future<bool> Function(Uri uri)? openUrlForTesting;

  @override
  State<NousAccountScreen> createState() => _NousAccountScreenState();
}

class _NousAccountScreenState extends State<NousAccountScreen> {
  late final DashboardClient _client;
  late final bool _ownsClient;
  bool _loading = true;
  bool _busy = false;
  bool _failed = false;
  bool _offline = false;
  OAuthAccount? _account;
  String? _email;

  String? get _profile {
    final name = widget.profileScope?.name.trim();
    return name == null || name.isEmpty ? null : name;
  }

  @override
  void initState() {
    super.initState();
    final testing = widget.dashboardClientForTesting;
    _ownsClient = testing == null;
    _client = testing ?? DashboardClient.lazy(widget.connection);
    unawaited(_load());
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
      _offline = false;
    });
    try {
      final rows = OAuthAccount.listFromJson(
        await _client.getOAuthProviders(profile: _profile),
      );
      if (!mounted) return;
      OAuthAccount? nous;
      for (final row in rows) {
        if (row.isNous) nous = row;
      }
      setState(() {
        _account = nous;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // An older server has no Accounts route: not a failure to report.
        _failed =
            !(error is DashboardHttpException &&
                (error.statusCode == 404 || error.statusCode == 405));
        _offline = _failed && error is! DashboardHttpException;
        _account = null;
      });
    }
  }

  Future<void> _connect() async {
    final account = _account;
    if (account == null || _busy) return;
    setState(() => _busy = true);
    final outcome = await connectProviderAccount(
      context: context,
      client: _client,
      connection: widget.connection,
      account: account,
      profile: _profile,
      openUrl: widget.openUrlForTesting,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (outcome.approved) _email = outcome.accountEmail;
    });
    if (outcome.approved) await _load();
  }

  Future<void> _manage() async {
    final account = _account;
    if (account == null || _busy) return;
    final action = await showProviderAccountMenu(context, account);
    if (!mounted) return;
    switch (action) {
      case ProviderAccountAction.reconnect:
        await _connect();
      case ProviderAccountAction.disconnect:
        setState(() => _busy = true);
        final removed = await disconnectProviderAccount(
          context: context,
          client: _client,
          connection: widget.connection,
          account: account,
          profile: _profile,
        );
        if (!mounted) return;
        setState(() {
          _busy = false;
          _email = null;
        });
        if (removed) {
          AppFeedback.of(context).notify(
            FeedbackKind.routine,
            Strings.of(context).nacCardDisconnected(account.name),
          );
          await _load();
        }
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(title: Text(s.nacScreenTitle)),
      body: ListView(
        clipBehavior: hermesUnderHeader,
        padding: const EdgeInsets.fromLTRB(
          HermesSpace.pageH,
          HermesSpace.pageTop,
          HermesSpace.pageH,
          HermesSpace.pageBottom,
        ),
        children: [
          Text(
            s.nacScreenBody,
            style: HermesType.style(HermesType.text, colors.textSecondary),
          ),
          const SizedBox(height: HermesSpace.x4),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: HermesSpace.x8),
              child: Center(child: ConsoleLoader.medium()),
            )
          else ...[
            if (_failed)
              Padding(
                padding: const EdgeInsets.only(bottom: HermesSpace.x3),
                child: Text(
                  _offline ? s.nacLinkOfflineTitle : s.nacScreenLoadFailed,
                  key: const ValueKey('nac-screen-load-failed'),
                  style: HermesType.style(HermesType.support, colors.error),
                ),
              ),
            if (!_failed)
              NousAccountCard(
                account: _account,
                enabled: !_busy && !widget.connection.readOnly,
                onConnect: _connect,
                onManage: _manage,
                compact: true,
              ),
            if (_email case final email? when _account?.signedIn == true)
              Padding(
                padding: const EdgeInsets.only(top: HermesSpace.x2),
                child: Text(
                  s.nacLinkApprovedAs(email),
                  style: HermesType.style(
                    HermesType.support,
                    colors.textSecondary,
                  ),
                ),
              ),
            if (_failed)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('nac-screen-retry'),
                  onPressed: () => unawaited(_load()),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(s.commonRetry),
                ),
              ),
            const SizedBox(height: HermesSpace.x4),
            HermesNavRow(
              key: const ValueKey('nac-screen-models'),
              icon: Icons.memory_outlined,
              title: s.nacScreenManageModels,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ModelsScreen(
                    connection: widget.connection,
                    profileScope: widget.profileScope,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
