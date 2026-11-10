import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../capabilities/spp_safety.dart' show sppRedactHostText;
import '../design/hermes_design.dart'
    show
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesInlineNotice,
        HermesPage,
        HermesSpace,
        HermesStatusTone,
        showHermesDialog;
import '../feedback/feedback_policy.dart';
import '../feedback/screen_help.dart';
import '../models/desktop_control_center.dart';
import '../services/desktop_control_gateway.dart';
import '../theme/app_theme.dart';
import '../widgets/console_loader.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_row_switch.dart';

/// Which rows of the list the status filter keeps.
enum _ToolStatus { all, active, inactive }

final class _Captured<T> {
  final T? value;
  final Object? error;

  const _Captured.value(this.value) : error = null;
  const _Captured.error(this.error) : value = null;
}

Future<_Captured<T>> _capture<T>(Future<T> future) async {
  try {
    return _Captured<T>.value(await future);
  } catch (error) {
    return _Captured<T>.error(error);
  }
}

/// The tool groups (toolsets) of the instance, or of one conversation when
/// [runtimeSessionId] is set, and the reload of the MCP runtime.
///
/// This is the «Tool groups» entry of the ⋯ menu of the Extensions screen
/// (Skills · Plugins · MCP). Plugins and MCP servers live in that screen's own
/// tabs and are no longer listed here. Runtime inventory and toggles use the
/// TUI JSON-RPC contract; a gateway that does not publish the inventory gets
/// an explicit unsupported state instead of an empty claim.
class ExtensionsToolsScreen extends StatefulWidget {
  final HermesDesktopControlGateway gateway;
  final String runtimeSessionId;
  final bool readOnly;
  final Future<void> Function()? disposeGateway;

  const ExtensionsToolsScreen({
    required this.gateway,
    this.runtimeSessionId = '',
    this.readOnly = false,
    this.disposeGateway,
    super.key,
  });

  @override
  State<ExtensionsToolsScreen> createState() => _ExtensionsToolsScreenState();
}

class _ExtensionsToolsScreenState extends State<ExtensionsToolsScreen> {
  ExtensionsInventory? _inventory;
  Object? _failure;
  bool _loading = true;
  final Set<String> _busyActions = {};
  _ToolStatus _status = _ToolStatus.all;
  String _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant ExtensionsToolsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway ||
        oldWidget.runtimeSessionId != widget.runtimeSessionId) {
      _inventory = null;
      _failure = null;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    final close = widget.disposeGateway;
    if (close != null) unawaited(close());
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _failure = null;
      });
    }
    final result = await _capture(
      widget.gateway.extensionsInventory(
        runtimeSessionId: widget.runtimeSessionId,
      ),
    );
    if (!mounted) return;
    setState(() {
      if (result.value != null) _inventory = result.value;
      _failure = result.error;
      _loading = false;
    });
  }

  Future<bool> _confirmChange({
    required String title,
    required String body,
    required String action,
  }) async {
    if (widget.readOnly) return false;
    final approved = await showHermesDialog<bool>(
      context: context,
      title: title,
      message: body,
      actions: [
        HermesDialogAction(
          label: Strings.of(context).commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          label: action,
          value: true,
          style: HermesDialogActionStyle.primary,
        ),
      ],
    );
    return approved == true;
  }

  Future<void> _toggleToolset(DesktopToolsetEntry toolset, bool enabled) async {
    final actionId = 'toolset:${toolset.name}';
    if (widget.readOnly || _busyActions.contains(actionId)) return;
    final strings = Strings.of(context);
    final scope = widget.runtimeSessionId.trim().isEmpty
        ? strings.extensionsCenterForInstance
        : strings.extensionsCenterForConversation;
    final approved = await _confirmChange(
      title: enabled
          ? strings.extensionsCenterEnableToolsetTitle
          : strings.extensionsCenterDisableToolsetTitle,
      body: strings.extensionsCenterChangeBody(
        enabled
            ? strings.extensionsCenterWillEnable
            : strings.extensionsCenterWillDisable,
        sppRedactHostText(toolset.name, strings),
        scope,
      ),
      action: strings.extensionsCenterConfirmChange,
    );
    if (!approved || !mounted) return;
    await _runAction(
      actionId,
      () => widget.gateway.setToolsetEnabled(
        toolset.name,
        enabled,
        runtimeSessionId: widget.runtimeSessionId,
      ),
    );
  }

  Future<void> _reloadMcp() async {
    const actionId = 'reload:mcp';
    if (widget.readOnly || _busyActions.contains(actionId)) return;
    final strings = Strings.of(context);
    final approved = await _confirmChange(
      title: strings.extensionsCenterReloadTitle,
      body: strings.extensionsCenterReloadBody,
      action: strings.extensionsCenterReloadNow,
    );
    if (!approved || !mounted) return;
    await _runAction(
      actionId,
      () => widget.gateway.reloadMcp(
        runtimeSessionId: widget.runtimeSessionId,
        confirmed: true,
      ),
      success: strings.extensionsCenterReloaded,
    );
  }

  Future<void> _runAction(
    String actionId,
    Future<void> Function() action, {
    String? success,
  }) async {
    if (!mounted || _busyActions.contains(actionId)) return;
    setState(() => _busyActions.add(actionId));
    try {
      await action();
      await _load();
      if (!mounted || success == null) return;
      AppFeedback.of(context).notify(FeedbackKind.routine, success);
    } catch (error) {
      if (!mounted) return;
      AppFeedback.of(context).notify(
        FeedbackKind.error,
        _extensionsMutationFailureText(error, Strings.of(context)),
      );
    } finally {
      if (mounted) setState(() => _busyActions.remove(actionId));
    }
  }

  List<DesktopToolsetEntry> _toolsets(ExtensionsInventory inventory) {
    final query = _query.trim().toLowerCase();
    final toolsets = inventory.builtinToolsets
        .where((toolset) {
          final keep = switch (_status) {
            _ToolStatus.all => true,
            _ToolStatus.active => toolset.enabled,
            _ToolStatus.inactive => !toolset.enabled,
          };
          if (!keep) return false;
          if (query.isEmpty) return true;
          return [
            toolset.name,
            toolset.description,
            ...toolset.tools,
          ].any((value) => value.toLowerCase().contains(query));
        })
        .toList(growable: false);
    return [...toolsets]..sort((a, b) {
      final active = (b.enabled ? 1 : 0).compareTo(a.enabled ? 1 : 0);
      return active != 0
          ? active
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final inventory = _inventory;
    final toolsets = inventory == null
        ? const <DesktopToolsetEntry>[]
        : _toolsets(inventory);
    final total = inventory?.builtinToolsets.length ?? 0;
    final active =
        inventory?.builtinToolsets.where((t) => t.enabled).length ?? 0;
    final reloading = _busyActions.contains('reload:mcp');

    final List<Widget> children;
    if (_loading && inventory == null) {
      children = const [Center(child: ConsoleLoader.large())];
    } else if (_failure != null && inventory == null) {
      children = [
        _ExtensionsFailure(
          message: _extensionsFailureText(_failure!, strings),
          onRetry: _load,
        ),
      ];
    } else {
      children = [
        Text(
          strings.exuToolGroupsSubtitle,
          key: const ValueKey('extensions-tools-subtitle'),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: HermesSpace.x3),
        if (widget.readOnly) ...[
          HermesInlineNotice(
            key: const ValueKey('extensions-readonly'),
            icon: Icons.lock_outline_rounded,
            tone: HermesStatusTone.warn,
            message: strings.extensionsCenterReadOnlyNotice,
          ),
          const SizedBox(height: HermesSpace.x3),
        ],
        if (widget.runtimeSessionId.trim().isEmpty) ...[
          HermesInlineNotice(
            key: const ValueKey('extensions-tools-scope'),
            message: strings.exuToolsScopeNote,
          ),
          const SizedBox(height: HermesSpace.x3),
        ],
        HermesSearchField(
          key: const ValueKey('extensions-search-tools'),
          hintText: strings.extensionsCenterSearchHint,
          clearTooltip: strings.extensionsCenterClearSearch,
          onChanged: (value) => setState(() => _query = value),
        ),
        const SizedBox(height: HermesSpace.x2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x1),
          child: Semantics(
            liveRegion: true,
            child: Text(
              strings.sppInstalledSummary(total, active),
              key: const ValueKey('extensions-summary'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
          ),
        ),
        const SizedBox(height: HermesSpace.x2),
        HermesSegmentedControl<_ToolStatus>(
          value: _status,
          semanticLabel: strings.sppStatusFilter,
          onChanged: (value) => setState(() => _status = value),
          segments: [
            HermesSegment(
              key: const ValueKey('extensions-status-all'),
              value: _ToolStatus.all,
              label: strings.sppFilterAll,
            ),
            HermesSegment(
              key: const ValueKey('extensions-status-active'),
              value: _ToolStatus.active,
              label: strings.sppFilterActive,
            ),
            HermesSegment(
              key: const ValueKey('extensions-status-inactive'),
              value: _ToolStatus.inactive,
              label: strings.sppFilterInactive,
            ),
          ],
        ),
        const SizedBox(height: HermesSpace.x3),
        if (total == 0)
          HermesEmptyState(
            compact: true,
            icon: Icons.handyman_outlined,
            title: strings.exuBuiltinToolsEmpty,
            body: strings.exuBuiltinToolsEmptyBody,
          )
        else if (toolsets.isEmpty)
          HermesEmptyState(
            compact: true,
            icon: Icons.filter_alt_off_outlined,
            title: strings.extensionsCenterNoMatches,
            body: strings.extensionsCenterNoMatchesBody,
          )
        else
          HermesListSection(
            margin: EdgeInsets.zero,
            title: strings.extensionsCenterAvailableToolsets,
            children: [
              for (final toolset in toolsets)
                _ToolsetRow(
                  toolset: toolset,
                  readOnly: widget.readOnly,
                  busy: _busyActions.contains('toolset:${toolset.name}'),
                  onChanged: (enabled) => _toggleToolset(toolset, enabled),
                ),
            ],
          ),
        const SizedBox(height: HermesSpace.x3),
        HermesListSection(
          margin: EdgeInsets.zero,
          title: strings.extensionsCenterMcpRuntimeSection,
          children: [
            HermesListRow(
              key: const ValueKey('extensions-reload-mcp'),
              icon: Icons.sync_rounded,
              title: strings.extensionsCenterReloadTitle,
              subtitle: strings.extensionsCenterReloadDescription,
              enabled: !widget.readOnly && !reloading,
              onTap: widget.readOnly || reloading ? null : _reloadMcp,
              trailing: reloading
                  ? const SizedBox.square(
                      dimension: 22,
                      child: ConsoleLoader.small(),
                    )
                  : const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
        if (_failure != null && inventory != null) ...[
          const SizedBox(height: HermesSpace.x3),
          HermesInlineNotice(
            tone: HermesStatusTone.warn,
            icon: Icons.warning_amber_rounded,
            message: strings.extensionsCenterStaleInventory(
              _extensionsFailureText(_failure!, strings),
            ),
          ),
        ],
      ];
    }

    return HermesPage(
      listKey: const ValueKey('extensions-tools-list'),
      title: strings.exuToolGroupsTitle,
      onRefresh: _load,
      actions: [
        ScreenHelpButton(
          title: strings.exuToolGroupsTitle,
          paragraphs: [
            strings.exuToolGroupsSubtitle,
            strings.exuToolsScopeNote,
          ],
        ),
        IconButton(
          tooltip: strings.extensionsCenterRefreshTooltip,
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      children: children,
    );
  }
}

class _ToolsetRow extends StatelessWidget {
  final DesktopToolsetEntry toolset;
  final bool readOnly;
  final bool busy;
  final ValueChanged<bool> onChanged;

  const _ToolsetRow({
    required this.toolset,
    required this.readOnly,
    required this.busy,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final name = sppRedactHostText(toolset.name, strings);
    final detail = toolset.description.isEmpty
        ? strings.extensionsCenterToolCount(toolset.toolCount)
        : strings.extensionsCenterToolCountWithDescription(
            toolset.toolCount,
            sppRedactHostText(toolset.description, strings),
          );
    return HermesListRow(
      icon: Icons.handyman_outlined,
      title: name,
      subtitle: detail,
      trailing: HermesRowSwitch(
        switchKey: ValueKey('toolset-toggle-${toolset.name}'),
        label: strings.sppSwitchLabel(name),
        value: toolset.enabled,
        enabled: !readOnly && !busy,
        onChanged: onChanged,
      ),
    );
  }
}

class _ExtensionsFailure extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _ExtensionsFailure({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => HermesEmptyState(
    icon: Icons.extension_off_outlined,
    title: Strings.of(context).extensionsCenterFailureTitle,
    body: message,
    primaryLabel: Strings.of(context).commonRetry,
    primaryIcon: Icons.refresh_rounded,
    onPrimary: onRetry,
  );
}

String _extensionsFailureText(Object failure, Strings strings) {
  if (failure is DesktopControlFailure) {
    return switch (failure.kind) {
      DesktopControlFailureKind.unsupported =>
        strings.extensionsCenterFailureUnsupported,
      DesktopControlFailureKind.forbidden =>
        strings.extensionsCenterFailureForbidden,
      DesktopControlFailureKind.invalidResponse =>
        strings.extensionsCenterFailureInvalidResponse,
      DesktopControlFailureKind.unavailable =>
        strings.extensionsCenterFailureUnavailable,
      DesktopControlFailureKind.rejected =>
        strings.extensionsCenterFailureRejected,
    };
  }
  return strings.extensionsCenterFailureUnknown;
}

String _extensionsMutationFailureText(Object failure, Strings strings) {
  if (failure is DesktopControlFailure) {
    return switch (failure.kind) {
      DesktopControlFailureKind.unsupported =>
        strings.extensionsCenterMutationFailureUnsupported,
      DesktopControlFailureKind.forbidden =>
        strings.extensionsCenterMutationFailureForbidden,
      DesktopControlFailureKind.invalidResponse =>
        strings.extensionsCenterMutationFailureInvalidResponse,
      DesktopControlFailureKind.unavailable =>
        strings.extensionsCenterMutationFailureUnavailable,
      DesktopControlFailureKind.rejected =>
        strings.extensionsCenterMutationFailureRejected,
    };
  }
  return strings.extensionsCenterMutationFailureUnknown;
}
