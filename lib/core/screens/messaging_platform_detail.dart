import 'package:hermes_android/core/design/hicons.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/content.dart'
    show HermesInlineNotice, HermesStatusText, HermesTag, HermesToggleRow;
import '../design/list.dart'
    show HermesListGroup, HermesListRow, HermesSectionHeader;
import '../design/modal.dart'
    show HermesDialogAction, HermesDialogActionStyle, showHermesDialog;
import '../design/page.dart' show HermesActionButton;
import '../design/tokens.dart';
import '../services/messaging_pairing.dart';
import '../services/messaging_platforms.dart';
import '../theme/app_theme.dart';
import '../widgets/console_loader.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_ui.dart' show HermesField;
import '../widgets/messaging_setup_cards.dart';
import 'env_key_sheet.dart' show pasteOnlyMenuItems;
import 'messaging_platforms_copy.dart';
import 'messaging_platforms_screen.dart';

/// One platform of Settings › Messaging: Desktop's detail pane
/// (`app/messaging/index.tsx` `PlatformDetail`, `DirectSetupSections`,
/// `PlatformActionBar`, `MessagingField`). The form comes from the
/// server's own field list; secrets are typed into empty, obscured fields
/// and only what was typed is ever sent.
class MessagingPlatformDetailScreen extends StatefulWidget {
  const MessagingPlatformDetailScreen({
    required this.controller,
    required this.platformId,
    required this.connectionId,
    required this.openUrl,
    this.readOnly = false,
    this.verifyLock,
    super.key,
  });

  final MessagingSetupController controller;
  final String platformId;
  final String connectionId;
  final bool readOnly;
  final Future<bool> Function(String reason)? verifyLock;
  final MessagingOpenUrl openUrl;

  @override
  State<MessagingPlatformDetailScreen> createState() =>
      _MessagingPlatformDetailScreenState();
}

class _MessagingPlatformDetailScreenState
    extends State<MessagingPlatformDetailScreen> {
  MessagingSetupController get _c => widget.controller;
  String? _status;
  bool _statusIsError = false;
  bool _showAdvanced = false;

  void _say(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = message;
      _statusIsError = error;
    });
  }

  /// The sentence of a failed write: Desktop's title, then the server's
  /// own reason when it gave one (a 409 multiplex conflict, a value it
  /// refused…).
  String _failure(Strings s, String message, Object error) {
    final detail = error is MessagingRequestFailed ? error.detail : '';
    return detail.isEmpty ? message : s.msgPlatFailedDetail(message, detail);
  }

  Future<void> _toggle(MessagingPlatform platform, bool on) async {
    if (widget.readOnly) return;
    final s = Strings.of(context);
    try {
      final result = await _c.toggle(platform, on);
      final title = on
          ? s.msgPlatPlatformEnabled(platform.name)
          : s.msgPlatPlatformDisabled(platform.name);
      final detail = result.hotServed
          ? s.msgPlatAppliedLive
          : s.msgPlatRestartToApply;
      _say('$title. $detail');
    } on MessagingBusy {
      // Another write is pending; its own outcome is the one reported.
    } catch (error) {
      _say(
        _failure(s, s.msgPlatFailedUpdate(platform.name), error),
        error: true,
      );
    }
  }

  Future<void> _save(MessagingPlatform platform) async {
    if (widget.readOnly) return;
    final s = Strings.of(context);
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      final result = await _c.save(platform);
      if (result == null) return;
      final detail = result.hotServed
          ? s.msgPlatConnectingLive
          : s.msgPlatRestartToReconnect;
      _say('${s.msgPlatSetupSaved(platform.name)}. $detail');
    } on MessagingBusy {
      // Another write is pending; its own outcome is the one reported.
    } catch (error) {
      _say(_failure(s, s.msgPlatFailedSave(platform.name), error), error: true);
    }
  }

  Future<void> _clear(MessagingPlatform platform, String key) async {
    if (widget.readOnly) return;
    final s = Strings.of(context);
    try {
      await _c.clear(platform, key);
      _say(s.msgPlatKeyCleared(key));
    } on MessagingBusy {
      // Another write is pending; its own outcome is the one reported.
    } catch (error) {
      _say(_failure(s, s.msgPlatFailedClear(key), error), error: true);
    }
  }

  /// The dashboard's Channels "Test": the server's verdict, as it says it.
  Future<void> _test(MessagingPlatform platform) async {
    final s = Strings.of(context);
    try {
      final result = await _c.test(platform);
      final message = result.message.isEmpty
          ? messagingStateLabel(s, platform.state)
          : result.message;
      _say(s.msgPlatTestResult(platform.name, message), error: !result.ok);
    } on MessagingBusy {
      // Another write is pending; its own outcome is the one reported.
    } catch (error) {
      _say(_failure(s, s.msgPlatTestFailed, error), error: true);
    }
  }

  Future<void> _restart() async {
    final said = await messagingRestartFlow(
      context,
      controller: _c,
      connectionId: widget.connectionId,
      readOnly: widget.readOnly,
      verifyLock: widget.verifyLock,
    );
    if (said != null) _say(said.$1, error: said.$2);
  }

  Future<void> _open(String url) async {
    final s = Strings.of(context);
    if (!await widget.openUrl(url)) _say(s.msgPlatOpenFailed, error: true);
  }

  Future<void> _approve(PairingEntry entry) async {
    if (widget.readOnly || !entry.canApprove || _c.busy != null) return;
    final s = Strings.of(context);
    if (!await messagingVerify(
          context,
          widget.verifyLock,
          s.msgPairVerifyApprove,
        ) ||
        !mounted) {
      return;
    }
    try {
      await _c.approve(entry);
      _say(s.msgPairApprovedDone(entry.label));
    } on PairingLockedOut {
      _say(s.msgPairLockedOut, error: true);
    } on MessagingBusy {
      // Another write is pending.
    } catch (_) {
      _say(s.msgPairApproveFailed(entry.label), error: true);
    }
  }

  Future<void> _revoke(PairingEntry entry) async {
    if (widget.readOnly || _c.busy != null) return;
    final s = Strings.of(context);
    final confirmed = await showHermesDialog<bool>(
      context: context,
      title: s.msgPairRevokeTitle,
      message: s.msgPairRevokeBody(entry.label),
      actions: [
        HermesDialogAction(
          label: s.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          label: s.msgPairRevoke,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    if (!await messagingVerify(
          context,
          widget.verifyLock,
          s.msgPairVerifyRevoke,
        ) ||
        !mounted) {
      return;
    }
    try {
      await _c.revoke(entry);
      _say(s.msgPairRevokedDone(entry.label));
    } on MessagingBusy {
      // Another write is pending.
    } catch (_) {
      _say(s.msgPairRevokeFailed(entry.label), error: true);
    }
  }

  /// Desktop `handleTelegramApplied`.
  Future<void> _telegramApplied(TelegramOnboardingApplied result) async {
    final s = Strings.of(context);
    await _c.refresh(silent: true);
    if (result.restartStarted) {
      _say(s.msgPlatTgSavedRestarting);
      final ok = await _c.watchRestart();
      if (!ok) _say(s.msgPlatRestartFailed, error: true);
      return;
    }
    if (result.needsRestart) {
      _c.markRestartNeeded();
      _say(
        result.restartError.isEmpty
            ? s.msgPlatRestartNeeded
            : s.msgPlatFailedDetail(
                s.msgPlatTgSavedRestartFailed,
                result.restartError,
              ),
        error: result.restartError.isNotEmpty,
      );
      if (mounted) await _restart();
    }
  }

  Widget _caption(String text, {Key? key}) {
    final colors = Theme.of(context).hermes;
    return Text(
      text,
      key: key,
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: colors.textSecondary, height: 1.4),
    );
  }

  /// Desktop `PlatformHint`.
  String? _hint(Strings s, MessagingPlatform platform) {
    if (platform.ingressUrl.isNotEmpty) {
      return s.msgPlatSharedListener(platform.ingressUrl);
    }
    if (!platform.enabled || platform.state == 'connected') return null;
    if (platform.state == 'pending_restart') return s.msgPlatHintPendingRestart;
    return platform.gatewayRunning ? null : s.msgPlatHintGatewayStopped;
  }

  List<Widget> _header(Strings s, MessagingPlatform platform) {
    final viaRelay = platform.relayExclusive;
    final hint = _hint(s, platform);
    return [
      Wrap(
        spacing: HermesSpace.x2,
        runSpacing: HermesSpace.x2,
        children: [
          if (viaRelay)
            HermesTag(label: s.msgPlatRelayTitle, tone: HermesStatusTone.ok)
          else
            HermesTag(
              key: const ValueKey('msgplat-state'),
              label: messagingStateLabel(s, platform.state),
              tone: messagingStatusTone(platform.tone),
            ),
          // Resting states earn no tag, only the ones to act on.
          if (!platform.configured && !viaRelay)
            HermesTag(
              label: s.msgPlatStateNotConfigured,
              tone: HermesStatusTone.neutral,
            ),
          // The state already reads "gateway stopped" when that is the
          // whole story; only add it when it is not.
          if (!platform.gatewayRunning && platform.state != 'gateway_stopped')
            HermesTag(
              label: s.msgPlatStateGatewayStopped,
              tone: HermesStatusTone.neutral,
            ),
        ],
      ),
      if (platform.description.isNotEmpty) ...[
        const SizedBox(height: HermesSpace.x2),
        _caption(platform.description),
      ],
      if (hint != null) ...[
        const SizedBox(height: HermesSpace.x2),
        _caption(hint, key: const ValueKey('msgplat-hint')),
      ],
      if (platform.errorMessage.isNotEmpty) ...[
        const SizedBox(height: HermesSpace.x3),
        HermesInlineNotice(
          key: const ValueKey('msgplat-error'),
          icon: HIcons.error_outline_rounded,
          tone: HermesStatusTone.error,
          message: platform.errorMessage,
        ),
      ],
    ];
  }

  List<Widget> _controls(Strings s, MessagingPlatform platform) {
    // Under an exclusive relay the direct adapter never runs: the link
    // card is the whole setup.
    if (platform.relayExclusive) return const [];
    final busy = _c.busy;
    final testing = busy == 'test:${platform.id}';
    return [
      const SizedBox(height: HermesSpace.x3),
      HermesListGroup(
        children: [
          HermesToggleRow(
            switchKey: const ValueKey('msgplat-enabled'),
            title: platform.disabledByRelay
                ? s.msgPlatRelayManaged
                : platform.enabled
                ? s.msgPlatEnabled
                : s.msgPlatDisabled,
            value: platform.enabled,
            onChanged:
                widget.readOnly ||
                    platform.disabledByRelay ||
                    busy != null
                ? null
                : (on) => unawaited(_toggle(platform, on)),
          ),
          HermesListRow(
            key: const ValueKey('msgplat-test'),
            icon: HIcons.send_rounded,
            title: testing ? s.msgPlatTesting : s.msgPlatTest,
            showChevron: false,
            // Not while anything is being written: a save in flight owns
            // the form until it settles.
            onTap: busy != null ? null : () => unawaited(_test(platform)),
          ),
        ],
      ),
    ];
  }

  List<Widget> _pairing(Strings s, MessagingPlatform platform) {
    final pending = _c.pendingOf(platform.id);
    final approved = _c.approvedOf(platform.id);
    final writable = !widget.readOnly && _c.busy == null;
    String waited(int minutes) =>
        minutes < 1 ? s.msgPairJustNow : s.msgPairMinutesAgo(minutes);
    return [
      // Only when someone is actually waiting: an empty card would be
      // permanent chrome on a page that is about credentials.
      if (pending.isNotEmpty) ...[
        HermesSectionHeader(s.msgPairPending(pending.length)),
        HermesListGroup(
          children: [
            for (final entry in pending)
              HermesListRow(
                key: ValueKey('msgplat-pending-${entry.userId}'),
                title: entry.label,
                subtitle: [
                  if (entry.userName.isNotEmpty) entry.userId,
                  if (entry.ageMinutes != null) waited(entry.ageMinutes!),
                ].join(' · '),
                showChevron: false,
                trailing: _c.isBusyPairing(entry)
                    ? const ConsoleLoader.small()
                    : TextButton(
                        key: ValueKey('msgplat-approve-${entry.userId}'),
                        onPressed: writable && entry.canApprove
                            ? () => unawaited(_approve(entry))
                            : null,
                        child: Text(s.msgPairApprove),
                      ),
              ),
          ],
        ),
      ],
      if (approved.isNotEmpty) ...[
        HermesSectionHeader(s.msgPairApproved(approved.length)),
        HermesListGroup(
          children: [
            for (final entry in approved)
              HermesListRow(
                key: ValueKey('msgplat-approved-${entry.userId}'),
                title: entry.label,
                subtitle: entry.userName.isNotEmpty ? entry.userId : null,
                showChevron: false,
                trailing: TextButton(
                  key: ValueKey('msgplat-revoke-${entry.userId}'),
                  onPressed: writable ? () => unawaited(_revoke(entry)) : null,
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).hermes.error,
                  ),
                  child: Text(s.msgPairRevoke),
                ),
              ),
          ],
        ),
      ],
    ];
  }

  Widget _field(MessagingPlatform platform, MessagingEnvField field) {
    final s = Strings.of(context);
    final draft = _c.draftOf(platform.id)[field.key];
    final label =
        messagingFieldLabel(s, field.key) ??
        (field.prompt.isEmpty ? field.key : field.prompt);
    final help =
        messagingFieldHelp(s, field.key) ??
        (field.description.isEmpty ? null : field.description);
    final placeholder =
        messagingFieldHint(s, field.key) ??
        (field.prompt.isEmpty ? null : field.prompt);
    // Read-only while anything is being written, the save of this form
    // included: an edit made then could not be told from what was sent.
    final writable = !widget.readOnly && _c.busy == null;
    final clearing = _c.busy == 'clear:${platform.id}:${field.key}';
    final tools = <Widget>[
      if (field.isSet)
        HermesTag(label: s.msgPlatSaved, tone: HermesStatusTone.ok),
      const Spacer(),
      if (field.url.isNotEmpty)
        IconButton(
          tooltip: s.msgPlatOpenDocs,
          icon: const Icon(HIcons.open_in_new_rounded),
          onPressed: () => unawaited(_open(field.url)),
        ),
      // A list clears by removing its last entry and saving; a second
      // trash icon would read as "remove row".
      if (field.isSet && !field.isList)
        IconButton(
          key: ValueKey('msgplat-clear-${field.key}'),
          tooltip: s.msgPlatClearField(field.key),
          icon: const Icon(HIcons.delete_outline_rounded),
          onPressed: widget.readOnly || clearing || _c.busy != null
              ? null
              : () => unawaited(_clear(platform, field.key)),
        ),
    ];
    return Padding(
      key: ValueKey('msgplat-field-${field.key}'),
      padding: const EdgeInsets.symmetric(vertical: HermesSpace.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (field.isList)
            MessagingAllowlistInput(
              field: field,
              label: label,
              help: help,
              draft: draft,
              enabled: writable,
              onChanged: (value) => _c.edit(platform.id, field.key, value),
            )
          else
            MessagingValueInput(
              field: field,
              label: label,
              help: help,
              // A saved value is never put in the field: its preview is
              // only the hint (Desktop `credentialPreview`).
              hint: field.isSet
                  ? (credentialPreview(field.redactedValue).isEmpty
                        ? s.msgPlatReplaceValue
                        : credentialPreview(field.redactedValue))
                  : placeholder,
              draft: draft,
              enabled: writable,
              onChanged: (value) => _c.edit(platform.id, field.key, value),
            ),
          if (tools.length > 1) Row(children: tools),
        ],
      ),
    );
  }

  List<Widget> _directSetup(Strings s, MessagingPlatform platform) {
    final required = [
      for (final field in platform.envVars)
        if (field.required) field,
    ];
    final optional = [
      for (final field in platform.envVars)
        if (!field.required && !field.isAdvanced) field,
    ];
    final advanced = [
      for (final field in platform.envVars)
        if (!field.required && field.isAdvanced) field,
    ];
    return [
      if (platform.id == 'telegram') ...[
        HermesSectionHeader(s.msgPlatTgQuickSetup),
        TelegramQuickSetupCard(
          key: ValueKey('msgplat-telegram-${_c.profile}'),
          client: _c.client,
          profile: _c.profile,
          platformName: platform.name,
          configured: platform.configured,
          readOnly: widget.readOnly,
          openUrl: _open,
          onApplied: (result) => unawaited(_telegramApplied(result)),
        ),
      ],
      HermesSectionHeader(s.msgPlatGetCredentials),
      _caption(messagingPlatformIntro(s, platform.id) ?? platform.description),
      if (platform.docsUrl.isNotEmpty)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const ValueKey('msgplat-docs'),
            onPressed: () => unawaited(_open(platform.docsUrl)),
            icon: const Icon(HIcons.open_in_new_rounded),
            label: Text(s.msgPlatOpenSetupGuide),
          ),
        ),
      HermesSectionHeader(s.msgPlatRequired),
      if (required.isEmpty)
        _caption(s.msgPlatNoTokenNeeded)
      else
        for (final field in required) _field(platform, field),
      if (optional.isNotEmpty) ...[
        HermesSectionHeader(s.msgPlatRecommended),
        for (final field in optional) _field(platform, field),
      ],
      if (advanced.isNotEmpty) ...[
        const SizedBox(height: HermesSpace.x3),
        HermesListGroup(
          children: [
            HermesListRow(
              key: const ValueKey('msgplat-advanced'),
              title: s.msgPlatAdvanced(advanced.length),
              showChevron: false,
              trailing: Icon(
                _showAdvanced
                    ? HIcons.expand_less_rounded
                    : HIcons.expand_more_rounded,
              ),
              onTap: () => setState(() => _showAdvanced = !_showAdvanced),
            ),
          ],
        ),
        if (_showAdvanced)
          for (final field in advanced) _field(platform, field),
      ],
    ];
  }

  Widget _actionBar(Strings s, MessagingPlatform platform) {
    final colors = Theme.of(context).hermes;
    final status = _status;
    final saving = _c.busy == 'env:${platform.id}';
    final changes = _c.changesOf(platform).hasChanges;
    final showSave = !platform.relayExclusive && !widget.readOnly;
    if (status == null && !showSave) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          HermesSpace.pageH,
          HermesSpace.x2,
          HermesSpace.pageH,
          HermesSpace.x2,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (status != null)
              Semantics(
                liveRegion: true,
                child: HermesStatusText(
                  key: const ValueKey('msgplat-status'),
                  label: status,
                  tone: _statusIsError
                      ? HermesStatusTone.error
                      : HermesStatusTone.ok,
                  maxLines: 4,
                ),
              ),
            if (showSave) ...[
              if (status != null) const SizedBox(height: HermesSpace.x2),
              if (changes) ...[
                Text(
                  s.msgPlatUnsavedChanges,
                  key: const ValueKey('msgplat-unsaved'),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                ),
                const SizedBox(height: HermesSpace.x1),
              ],
              HermesActionButton(
                key: const ValueKey('msgplat-save'),
                primary: true,
                icon: HIcons.check_rounded,
                label: saving ? s.msgPlatSaving : s.msgPlatSaveChanges,
                onPressed: !changes || saving || _c.busy != null
                    ? null
                    : () => unawaited(_save(platform)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _body(Strings s, MessagingPlatform platform) {
    return ListView(
      clipBehavior: hermesUnderHeader,
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.pageH,
        HermesSpace.pageTop,
        HermesSpace.pageH,
        HermesSpace.pageBottom,
      ),
      children: [
        if (widget.readOnly) ...[
          HermesInlineNotice(
            icon: HIcons.lock_outline_rounded,
            message: s.msgPlatReadOnly,
          ),
          const SizedBox(height: HermesSpace.x3),
        ],
        if (_c.restartNeeded || _c.restarting) ...[
          HermesInlineNotice(
            key: const ValueKey('msgplat-restart-needed'),
            icon: HIcons.restart_alt_rounded,
            tone: HermesStatusTone.warn,
            message: _c.restarting
                ? s.msgPlatRestarting
                : s.msgPlatRestartNeeded,
            actionLabel: widget.readOnly || _c.restarting
                ? null
                : s.msgPlatRestartNow,
            onAction: () => unawaited(_restart()),
          ),
          const SizedBox(height: HermesSpace.x3),
        ],
        ..._header(s, platform),
        ..._controls(s, platform),
        ..._pairing(s, platform),
        if (platform.relayFronted) ...[
          HermesSectionHeader(s.msgPlatRelayTitle),
          RelayLinkCard(
            key: ValueKey('msgplat-relay-${_c.profile}-${platform.id}'),
            client: _c.client,
            profile: _c.profile,
            platformId: platform.id,
            platformName: platform.name,
            readOnly: widget.readOnly,
            openUrl: _open,
          ),
        ],
        // Not carried by the shared bot yet switched off at every start:
        // say so instead of a switch that reverts.
        if (platform.disabledByRelay && !platform.relayExclusive) ...[
          const SizedBox(height: HermesSpace.x3),
          _caption(s.msgPlatRelayManagedNote(platform.name)),
        ],
        if (!platform.relayExclusive) ..._directSetup(s, platform),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final platform = _c.platformById(widget.platformId);
        return Scaffold(
          appBar: HermesAppBar(title: Text(platform?.name ?? s.msgPlatTitle)),
          body: platform == null
              ? const Center(child: ConsoleLoader.large())
              : _body(s, platform),
          bottomNavigationBar: platform == null
              ? null
              : _actionBar(s, platform),
        );
      },
    );
  }
}

/// One text field of a platform (Desktop `MessagingField`'s input). It
/// starts empty: a saved value only shows as the hint. A password is
/// obscured and its typed text is shown only while the field has the focus
/// and the app is in front, with no autocorrect, suggestions, keyboard
/// learning or autofill and a menu that can paste but not copy
/// (`env_key_sheet.dart`).
class MessagingValueInput extends StatefulWidget {
  const MessagingValueInput({
    required this.field,
    required this.label,
    required this.draft,
    required this.onChanged,
    this.help,
    this.hint,
    this.enabled = true,
    super.key,
  });

  final MessagingEnvField field;
  final String label;
  final String? help;
  final String? hint;

  /// What the user typed and has not saved; null when untouched.
  final String? draft;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  State<MessagingValueInput> createState() => _MessagingValueInputState();
}

class _MessagingValueInputState extends State<MessagingValueInput>
    with WidgetsBindingObserver {
  late final TextEditingController _text = TextEditingController(
    text: widget.draft ?? '',
  );
  final FocusNode _focus = FocusNode();
  bool _reveal = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(MessagingValueInput old) {
    super.didUpdateWidget(old);
    // A save or a clear dropped the edit: the field empties with it.
    final draft = widget.draft ?? '';
    if (draft != _text.text) _text.text = draft;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    _text
      ..clear()
      ..dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!_focus.hasFocus) _hide();
  }

  void _hide() {
    if (_reveal && mounted) setState(() => _reveal = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _hide();
  }

  void _toggleReveal() {
    if (!_reveal) _focus.requestFocus();
    setState(() => _reveal = !_reveal);
  }

  static Widget _pasteOnlyMenu(BuildContext context, EditableTextState state) =>
      AdaptiveTextSelectionToolbar.buttonItems(
        anchors: state.contextMenuAnchors,
        buttonItems: pasteOnlyMenuItems(state.contextMenuButtonItems),
      );

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final secret = messagingFieldIsSecret(widget.field);
    final field = HermesField(
      fieldKey: ValueKey('msgplat-input-${widget.field.key}'),
      label: widget.label,
      controller: _text,
      focusNode: _focus,
      hint: widget.hint,
      helperText: widget.help,
      obscure: secret && !_reveal,
      enabled: widget.enabled,
      keyboardType: secret ? TextInputType.visiblePassword : TextInputType.text,
      autocorrect: false,
      enableSuggestions: false,
      // Every field of this form is a setting of the bot's account: none
      // of them teaches the keyboard or is offered to autofill, whatever
      // the server says about it.
      enableIMEPersonalizedLearning: false,
      autofill: false,
      contextMenuBuilder: secret ? _pasteOnlyMenu : null,
      onChanged: widget.onChanged,
      suffix: secret
          ? ExcludeFocus(
              child: IconButton(
                key: ValueKey('msgplat-eye-${widget.field.key}'),
                tooltip: _reveal ? s.kluHideValue : s.kluRevealValue,
                constraints: const BoxConstraints(
                  minWidth: HermesSpace.tap,
                  minHeight: HermesSpace.tap,
                ),
                onPressed: widget.enabled ? _toggleReveal : null,
                icon: Icon(
                  _reveal
                      ? HIcons.visibility_off_outlined
                      : HIcons.visibility_outlined,
                  color: colors.textSecondary,
                ),
              ),
            )
          : null,
    );
    if (!secret) return field;
    // Copy and cut are off for the keyboard shortcuts too.
    return Actions(
      actions: <Type, Action<Intent>>{
        CopySelectionTextIntent: DoNothingAction(),
      },
      child: field,
    );
  }
}

/// Desktop `AllowlistField`: one box per allowed id, + to add and × to
/// remove, saved as one comma-separated value. Ids are not secrets: the
/// saved list is shown as it is.
class MessagingAllowlistInput extends StatefulWidget {
  const MessagingAllowlistInput({
    required this.field,
    required this.label,
    required this.draft,
    required this.onChanged,
    this.help,
    this.enabled = true,
    super.key,
  });

  final MessagingEnvField field;
  final String label;
  final String? help;

  /// The unsaved value, or null when untouched.
  final String? draft;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  State<MessagingAllowlistInput> createState() =>
      _MessagingAllowlistInputState();
}

class _AllowlistRow {
  _AllowlistRow(String value)
    : text = TextEditingController(text: value),
      focus = FocusNode();

  final TextEditingController text;
  final FocusNode focus;

  void dispose() {
    text.dispose();
    focus.dispose();
  }
}

class _MessagingAllowlistInputState extends State<MessagingAllowlistInput> {
  List<_AllowlistRow> _rows = [];

  @override
  void initState() {
    super.initState();
    _rows = _seed(widget.draft ?? widget.field.value);
  }

  static List<_AllowlistRow> _seed(String raw) {
    final entries = splitAllowlist(raw);
    return [
      for (final entry in entries.isEmpty ? const [''] : entries)
        _AllowlistRow(entry),
    ];
  }

  @override
  void didUpdateWidget(MessagingAllowlistInput old) {
    super.didUpdateWidget(old);
    // A save or a clear changed the server's value: re-seed from it.
    if (widget.field.value != old.field.value) _replace(widget.field.value);
  }

  void _replace(String raw) {
    _retire(_rows);
    _rows = _seed(raw);
  }

  /// The fields of [rows] still hold their controllers until the next
  /// frame has rebuilt without them.
  void _retire(List<_AllowlistRow> rows) {
    final gone = List.of(rows);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final row in gone) {
        row.dispose();
      }
    });
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _commit() =>
      widget.onChanged(joinAllowlist([for (final row in _rows) row.text.text]));

  void _change(_AllowlistRow row, String value) {
    // A pasted "123, 456" becomes one box per entry.
    if (RegExp('[,\n]').hasMatch(value)) {
      final parts = splitAllowlist(value);
      final index = _rows.indexOf(row);
      setState(() {
        row.text.text = parts.isEmpty ? '' : parts.first;
        _rows.insertAll(index + 1, [
          for (final part in parts.skip(1)) _AllowlistRow(part),
        ]);
      });
    }
    _commit();
  }

  void _add() {
    final row = _AllowlistRow('');
    setState(() => _rows.add(row));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) row.focus.requestFocus();
    });
  }

  void _remove(_AllowlistRow row) {
    setState(() {
      _rows.remove(row);
      if (_rows.isEmpty) _rows.add(_AllowlistRow(''));
    });
    _retire([row]);
    _commit();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final lone = _rows.length == 1 && _rows.first.text.text.isEmpty;
    final help = widget.help;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.label,
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: HermesSpace.x1),
        for (final (index, row) in _rows.indexed)
          Padding(
            key: ObjectKey(row),
            padding: const EdgeInsets.only(bottom: HermesSpace.x1),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    label: s.msgPlatEntryLabel(widget.label, index + 1),
                    child: TextField(
                      controller: row.text,
                      focusNode: row.focus,
                      enabled: widget.enabled,
                      autocorrect: false,
                      enableSuggestions: false,
                      // Who may write to the bot: like the rest of the form,
                      // it does not teach the keyboard nor go to autofill.
                      enableIMEPersonalizedLearning: false,
                      autofillHints: null,
                      textInputAction: TextInputAction.next,
                      onChanged: (value) => _change(row, value),
                      onSubmitted: (value) {
                        if (value.trim().isNotEmpty) _add();
                      },
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: s.msgPlatEntryPlaceholder,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: s.msgPlatRemoveEntry,
                  icon: const Icon(HIcons.close_rounded),
                  onPressed: widget.enabled && !lone
                      ? () => _remove(row)
                      : null,
                ),
              ],
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: ValueKey('msgplat-add-${widget.field.key}'),
            onPressed: widget.enabled ? _add : null,
            icon: const Icon(HIcons.add_rounded),
            label: Text(s.msgPlatAddEntry),
          ),
        ),
        if (help != null)
          Text(
            help,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
          ),
      ],
    );
  }
}


/// Names that are credentials whatever flag the server sends with them:
/// both server versions describe `WECOM_CALLBACK_TOKEN` without the
/// password flag.
final _credentialName = RegExp(
  r'(^|_)(TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|APIKEY|AES_KEY|PRIVATE_KEY)'
  r'(_|$)',
);

/// Whether [field] is typed and shown as a secret: the server's flag, or a
/// name that says so.
bool messagingFieldIsSecret(MessagingEnvField field) =>
    field.isPassword || _credentialName.hasMatch(field.key.toUpperCase());
