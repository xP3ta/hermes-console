// Capability detail: one action that works now, trust and permissions, and
// secondary actions behind "More". Every action calls the repository for
// real; nothing flips locally until the server confirms it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../services/command_risk.dart';
import '../theme/app_theme.dart';
import '../widgets/action_approval.dart';
import '../widgets/hermes_notice.dart';
import 'capabilities_repository.dart';
import 'capability_models.dart';
import 'capability_ui.dart';
import 'mcp_runtime_status.dart';

enum CapabilityAction { install, update, enable, disable, remove, test, docs }

/// Actions the current snapshot allows, primary first. Pure so it can be
/// tested without widgets.
List<CapabilityAction> capabilityActions(
  CapabilityItem item, {
  required bool readOnly,
}) {
  final docs = Uri.tryParse(item.docsUrl);
  final hasDocs =
      docs != null &&
      docs.scheme.toLowerCase() == 'https' &&
      docs.host.isNotEmpty;
  final out = <CapabilityAction>[];
  if (!readOnly) {
    if (!item.installed) {
      final needsEnv = item.env.any((field) => field.required);
      if (item.installId.isNotEmpty && !needsEnv) {
        out.add(CapabilityAction.install);
      }
    } else {
      if (item.updateAvailable && item.kind == CapabilityKind.plugin) {
        out.add(CapabilityAction.update);
      }
      final togglable = item.installedName.isNotEmpty && item.enabled != null;
      if (togglable && item.enabled == false) out.add(CapabilityAction.enable);
      if (togglable && item.enabled == true) out.add(CapabilityAction.disable);
      if (item.kind == CapabilityKind.mcp &&
          item.id.startsWith('mcp:server:')) {
        out.add(CapabilityAction.test);
      }
      if (item.canRemove && item.installedName.isNotEmpty) {
        out.add(CapabilityAction.remove);
      }
    }
  }
  if (hasDocs) out.add(CapabilityAction.docs);
  return out;
}

class CapabilityDetailScreen extends StatefulWidget {
  final CapabilityItem item;
  final CapabilitiesRepository repository;
  final bool readOnly;
  final String instanceId;

  /// Called after every confirmed server change so the hub reloads.
  final VoidCallback? onChanged;

  const CapabilityDetailScreen({
    super.key,
    required this.item,
    required this.repository,
    this.readOnly = false,
    this.instanceId = '',
    this.onChanged,
  });

  @override
  State<CapabilityDetailScreen> createState() => _CapabilityDetailScreenState();
}

class _CapabilityDetailScreenState extends State<CapabilityDetailScreen> {
  late CapabilityItem _item = widget.item;
  McpRuntimeRow? _runtime;
  final GlobalKey _moreKey = GlobalKey(debugLabel: 'cph-detail-more');
  bool _busy = false;

  CapabilitiesRepository get _repo => widget.repository;

  @override
  void initState() {
    super.initState();
    if (_item.kind == CapabilityKind.mcp && _item.installed) {
      unawaited(_loadRuntime());
    }
  }

  /// One cached-state read when an MCP server opens; no refresh timer, and
  /// any failure just leaves the static status.
  Future<void> _loadRuntime() async {
    try {
      final all = await _repo.mcpRuntimeStatus();
      if (!mounted) return;
      final row = all[_item.name];
      if (row != null) setState(() => _runtime = row);
    } catch (_) {}
  }

  String _label(Strings s, CapabilityAction action) => switch (action) {
    CapabilityAction.install => s.cphActionInstall,
    CapabilityAction.update => s.cphActionUpdate,
    CapabilityAction.enable => s.cphActionEnable,
    CapabilityAction.disable => s.cphActionDisable,
    CapabilityAction.remove => s.cphActionRemove,
    CapabilityAction.test => s.cphActionTest,
    CapabilityAction.docs => s.cphActionDocs,
  };

  IconData _icon(CapabilityAction action) => switch (action) {
    CapabilityAction.install => Icons.download_rounded,
    CapabilityAction.update => Icons.system_update_alt_rounded,
    CapabilityAction.enable => Icons.toggle_on_outlined,
    CapabilityAction.disable => Icons.toggle_off_outlined,
    CapabilityAction.remove => Icons.delete_outline_rounded,
    CapabilityAction.test => Icons.network_check_rounded,
    CapabilityAction.docs => Icons.open_in_new_rounded,
  };

  Future<bool> _confirm(CapabilityAction action) {
    final s = Strings.of(context);
    final name = _item.name;
    final (title, detail, risk) = switch (action) {
      CapabilityAction.install => (
        s.cphConfirmInstall(name),
        s.cphConfirmInstallBody,
        CommandRisk.high,
      ),
      CapabilityAction.remove => (
        s.cphConfirmRemove(name),
        s.cphConfirmRemoveBody,
        CommandRisk.medium,
      ),
      CapabilityAction.update => (
        s.cphConfirmUpdate(name),
        '',
        CommandRisk.medium,
      ),
      _ => (_label(s, action), name, CommandRisk.low),
    };
    return confirmMutatingAction(
      context,
      instanceId: widget.instanceId,
      readOnlyInstance: widget.readOnly,
      risk: risk,
      title: title,
      detail: detail,
    );
  }

  Future<void> _run(CapabilityAction action) async {
    if (_busy) return;
    if (action == CapabilityAction.docs) {
      final uri = Uri.parse(_item.docsUrl);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    if (action != CapabilityAction.test && !await _confirm(action)) return;
    if (!mounted) return;
    final s = Strings.of(context);
    final notices = HermesNotice.of(context);
    final name = _item.name;
    final progressLabel = switch (action) {
      CapabilityAction.install => s.cphProgressInstalling(name),
      CapabilityAction.remove => s.cphProgressRemoving(name),
      CapabilityAction.update => s.cphProgressUpdating(name),
      CapabilityAction.test => s.cphProgressTesting(name),
      _ => s.cphProgressSaving,
    };
    setState(() => _busy = true);
    try {
      final outcome = await runCapabilityProgress<_Outcome>(
        context,
        label: progressLabel,
        task: (line) => _perform(action, line),
      );
      if (!mounted) return;
      if (outcome.consent != null) {
        await _handleConsent(outcome.consent!);
        return;
      }
      if (outcome.message.isNotEmpty) {
        notices.show(
          message: outcome.message,
          kind: outcome.ok
              ? HermesNoticeKind.success
              : HermesNoticeKind.warning,
        );
      }
      if (outcome.changed) widget.onChanged?.call();
      if (outcome.next != null) {
        setState(() => _item = outcome.next!);
      } else if (outcome.changed && action == CapabilityAction.remove) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (!mounted) return;
      notices.show(
        message: capabilityFailureMessage(s, error),
        kind: HermesNoticeKind.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<_Outcome> _perform(
    CapabilityAction action,
    ValueNotifier<String> line,
  ) async {
    final s = Strings.of(context);
    final item = _item;
    final name = item.name;
    void progress(CapabilityActionStatus status) => line.value = status.tail;
    String restartNote(PluginMutationResult result) =>
        result.restartRequired ? '\n${s.cphRestartRequired}' : '';

    switch (action) {
      case CapabilityAction.install:
        switch (item.kind) {
          case CapabilityKind.skill:
            await _repo.installSkill(item.installId, onProgress: progress);
          case CapabilityKind.plugin:
            final result = await _repo.installPlugin(item.installId);
            if (result.consentRequired) {
              return _Outcome.message(s.cphConsentNeeded, ok: false);
            }
            return _Outcome(
              message: '${s.cphDoneInstalled(name)}${restartNote(result)}',
              next: item.copyWith(installed: true, enabled: true),
            );
          case CapabilityKind.mcp:
            await _repo.installMcp(item.installId);
        }
        return _Outcome(
          message: s.cphDoneInstalled(name),
          next: item.copyWith(
            installed: true,
            enabled: true,
            canRemove: item.kind != CapabilityKind.skill || item.canRemove,
          ),
        );
      case CapabilityAction.update:
        final result = await _repo.updatePlugin(item.installedName);
        if (result.consentRequired) return _Outcome.consent(result);
        return _Outcome(
          message: '${s.cphDoneUpdated(name)}${restartNote(result)}',
          next: item.copyWith(updateAvailable: false),
        );
      case CapabilityAction.enable:
      case CapabilityAction.disable:
        final enabled = action == CapabilityAction.enable;
        switch (item.kind) {
          case CapabilityKind.skill:
            await _repo.setSkillEnabled(item.installedName, enabled);
          case CapabilityKind.plugin:
            await _repo.setPluginEnabled(item.installedName, enabled);
          case CapabilityKind.mcp:
            await _repo.setMcpEnabled(item.installedName, enabled);
        }
        return _Outcome(
          message: enabled ? s.cphDoneEnabled(name) : s.cphDoneDisabled(name),
          next: item.copyWith(enabled: enabled),
        );
      case CapabilityAction.remove:
        switch (item.kind) {
          case CapabilityKind.skill:
            await _repo.uninstallSkill(
              item.installedName,
              onProgress: progress,
            );
          case CapabilityKind.plugin:
            await _repo.removePlugin(item.installedName);
          case CapabilityKind.mcp:
            await _repo.removeMcp(item.installedName);
        }
        // Catalog rows stay meaningful after removal; installed-only rows
        // (configured servers, local skills) leave the detail.
        final catalogRow = item.installId.isNotEmpty;
        return _Outcome(
          message: s.cphDoneRemoved(name),
          next: catalogRow
              ? CapabilityItem(
                  kind: item.kind,
                  id: item.id,
                  name: item.name,
                  description: item.description,
                  category: item.category,
                  source: item.source,
                  trust: item.trust,
                  author: item.author,
                  version: item.version,
                  installId: item.installId,
                  installedName: item.installedName,
                  tags: item.tags,
                  tools: item.tools,
                  requirements: item.requirements,
                  env: item.env,
                  transport: item.transport,
                  command: item.command,
                  url: item.url,
                  docsUrl: item.docsUrl,
                )
              : null,
        );
      case CapabilityAction.test:
        final probe = await _repo.testMcp(item.installedName);
        return _Outcome.message(
          probe.ok ? s.cphTestOk : s.cphTestFailed,
          ok: probe.ok,
        );
      case CapabilityAction.docs:
        return const _Outcome.message('');
    }
  }

  Future<void> _handleConsent(PluginMutationResult pending) async {
    final s = Strings.of(context);
    final accept = await showHermesDialog<bool>(
      context: context,
      title: s.cphConsentTitle(_item.name),
      message: [...pending.deltaLines, ...pending.warnings].join('\n'),
      actions: [
        HermesDialogAction(
          label: s.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('cph-consent-accept'),
          label: s.cphConsentAccept,
          value: true,
        ),
      ],
    );
    if (accept != true || !mounted) return;
    final notices = HermesNotice.of(context);
    setState(() => _busy = true);
    try {
      final result = await runCapabilityProgress(
        context,
        label: s.cphProgressUpdating(_item.name),
        task: (_) =>
            _repo.updatePlugin(_item.installedName, acceptCapabilities: true),
      );
      if (!mounted) return;
      notices.show(
        message:
            '${s.cphDoneUpdated(_item.name)}'
            '${result.restartRequired ? '\n${s.cphRestartRequired}' : ''}',
        kind: HermesNoticeKind.success,
      );
      widget.onChanged?.call();
      setState(() => _item = _item.copyWith(updateAvailable: false));
    } catch (error) {
      if (!mounted) return;
      notices.show(
        message: capabilityFailureMessage(s, error),
        kind: HermesNoticeKind.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openMore(List<CapabilityAction> secondary) async {
    final s = Strings.of(context);
    final chosen = await showHermesMenu<CapabilityAction>(
      context: context,
      anchorKey: _moreKey,
      actions: [
        for (final action in secondary)
          HermesAction(
            key: ValueKey('cph-action-${action.name}'),
            value: action,
            label: _label(s, action),
            icon: _icon(action),
            destructive: action == CapabilityAction.remove,
          ),
      ],
    );
    if (chosen != null) await _run(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final item = _item;
    final actions = capabilityActions(item, readOnly: widget.readOnly);
    // Remove is never the primary action when anything else is possible:
    // the destructive choice stays one step away, in "More".
    final primary = actions.firstWhere(
      (a) => a != CapabilityAction.docs && a != CapabilityAction.test,
      orElse: () => CapabilityAction.docs,
    );
    final hasPrimary =
        actions.isNotEmpty &&
        primary != CapabilityAction.docs &&
        !(primary == CapabilityAction.remove && actions.length > 1);
    final secondary = [
      for (final action in actions)
        if (!hasPrimary || action != primary) action,
    ];
    final runtime = _runtime;
    final status = runtime == null
        ? capabilityDetailStatus(s, item)
        : mcpRuntimeStatusLabel(s, runtime.status);
    final needsEnv = !item.installed && item.env.any((field) => field.required);

    String? reason;
    if (widget.readOnly) {
      reason = s.cphReadOnly;
    } else if (needsEnv) {
      reason = s.cphNeedsCredentials(
        item.env.where((f) => f.required).map((f) => f.name).join(', '),
      );
    } else if (!item.installed && item.installId.isEmpty) {
      reason = s.cphNotInstallable;
    } else if (item.installed &&
        item.kind == CapabilityKind.skill &&
        item.provenance == 'bundled') {
      reason = s.cphBuiltIn;
    }

    return HermesDetailScaffold(
      listKey: const ValueKey('cph-detail-list'),
      title: item.name,
      eyebrow: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            capabilityKindIcon(item.kind),
            size: 15,
            color: Theme.of(context).hermes.textSecondary,
          ),
          const SizedBox(width: 6),
          Text(
            capabilityKindLabel(s, item.kind),
            style: HermesType.support.copyWith(
              color: Theme.of(context).hermes.textSecondary,
            ),
          ),
        ],
      ),
      status: Wrap(
        spacing: 10,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          HermesStatusText(
            key: const ValueKey('cph-detail-status'),
            label: status.label,
            tone: status.tone,
          ),
          if (widget.readOnly)
            HermesTag(
              key: const ValueKey('cph-detail-readonly'),
              label: s.cphReadOnlyTag,
              tone: HermesStatusTone.neutral,
              icon: Icons.lock_outline_rounded,
            ),
        ],
      ),
      reason: reason,
      primaryAction: hasPrimary
          ? HermesActionButton(
              key: const ValueKey('cph-primary'),
              primary: true,
              label: _label(s, primary),
              icon: _icon(primary),
              onPressed: _busy ? null : () => _run(primary),
            )
          : null,
      actions: [
        if (secondary.isNotEmpty)
          IconButton(
            key: _moreKey,
            tooltip: s.cphMore,
            icon: const Icon(Icons.more_vert_rounded),
            onPressed: _busy ? null : () => _openMore(secondary),
          ),
      ],
      sections: [
        if (item.description.isNotEmpty && item.description != 'oauth') ...[
          const SizedBox(height: HermesSpace.x4),
          HermesTextBlock(text: item.description, collapsedLines: 6),
        ],
        HermesSectionHeader(s.cphSecTrust),
        HermesListGroup(
          children: [
            HermesListRow(
              icon: item.trust == CapabilityTrust.official
                  ? Icons.verified_outlined
                  : Icons.shield_outlined,
              title: capabilityTrustLabel(s, item.trust),
              subtitle: capabilityTrustBody(s, item.trust),
              subtitleMaxLines: 3,
            ),
            if (item.author.isNotEmpty)
              HermesListRow(
                icon: Icons.person_outline_rounded,
                title: s.cphRowPublisher,
                value: item.author,
              ),
            // Skip when the source only repeats the trust tier.
            if (item.source.isNotEmpty &&
                item.source.toLowerCase() != item.trust.name)
              HermesListRow(
                icon: Icons.inventory_2_outlined,
                title: s.cphRowSource,
                value: capabilityLabel(item.source),
              ),
            if (item.version.isNotEmpty)
              HermesListRow(
                icon: Icons.sell_outlined,
                title: s.cphRowVersion,
                value: item.version,
              ),
            if (item.category.isNotEmpty && item.category != 'mcp')
              HermesListRow(
                icon: Icons.category_outlined,
                title: s.cphRowCategory,
                value: capabilityLabel(item.category),
              ),
          ],
        ),
        HermesSectionHeader(s.cphSecPermissions),
        HermesListGroup(
          children: [
            if (item.tools.isNotEmpty)
              HermesListRow(
                icon: Icons.build_outlined,
                title: s.cphRowTools,
                subtitle: item.tools.join(', '),
                subtitleMaxLines: 4,
              ),
            if (item.requirements.isNotEmpty)
              HermesListRow(
                icon: Icons.key_outlined,
                title: s.cphRowRequires,
                subtitle: item.requirements.join(', '),
                subtitleMaxLines: 4,
              ),
            if (item.description == 'oauth')
              HermesListRow(
                icon: Icons.lock_person_outlined,
                title: s.cphRowAuth,
                value: 'OAuth',
              ),
            if (item.tools.isEmpty &&
                item.requirements.isEmpty &&
                item.description != 'oauth')
              HermesListRow(
                icon: Icons.check_circle_outline_rounded,
                title: s.cphNoPermissions,
                muted: true,
              ),
          ],
        ),
        if (item.transport.isNotEmpty ||
            item.command.isNotEmpty ||
            item.url.isNotEmpty) ...[
          HermesSectionHeader(s.cphSecTechnical),
          HermesListGroup(
            children: [
              if (runtime != null && runtime.tools > 0)
                HermesListRow(
                  icon: Icons.build_outlined,
                  title: s.cphRowTools,
                  value: s.cphMcpToolCount(runtime.tools),
                ),
              if (item.transport.isNotEmpty)
                HermesListRow(
                  icon: Icons.swap_horiz_rounded,
                  title: s.cphRowTransport,
                  value: item.transport,
                ),
              if (item.command.isNotEmpty)
                HermesListRow(
                  icon: Icons.terminal_rounded,
                  title: s.cphRowCommand,
                  subtitle: item.command,
                  subtitleMaxLines: 4,
                ),
              if (item.url.isNotEmpty)
                HermesListRow(
                  icon: Icons.link_rounded,
                  title: s.cphRowUrl,
                  subtitle: item.url,
                  subtitleMaxLines: 3,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

final class _Outcome {
  final String message;
  final bool ok;
  final CapabilityItem? next;
  final PluginMutationResult? consent;
  final bool changed;

  const _Outcome({required this.message, this.next})
    : ok = true,
      consent = null,
      changed = true;

  const _Outcome.message(this.message, {this.ok = true})
    : next = null,
      consent = null,
      changed = false;

  const _Outcome.consent(PluginMutationResult result)
    : message = '',
      ok = true,
      next = null,
      consent = result,
      changed = false;
}
