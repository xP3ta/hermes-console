// Hosted connector detail: the member's own switch and per-tool toggles over
// the organisation's locks. Tool edits are a local draft; one Save sends the
// full `disabled_tools` list against the member layer's revision. A stale
// revision keeps the draft and offers "Keep mine" or "Discard".
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_notice.dart';
import 'capabilities_repository.dart';
import 'capability_models.dart';
import 'capability_ui.dart';
import 'connector_policy.dart';

class ConnectorDetailScreen extends StatefulWidget {
  final HostedConnector connector;
  final CapabilitiesRepository repository;
  final bool readOnly;

  /// Called after every confirmed server change so the hub reloads.
  final VoidCallback? onChanged;

  const ConnectorDetailScreen({
    super.key,
    required this.connector,
    required this.repository,
    this.readOnly = false,
    this.onChanged,
  });

  @override
  State<ConnectorDetailScreen> createState() => _ConnectorDetailScreenState();
}

class _ConnectorDetailScreenState extends State<ConnectorDetailScreen> {
  ConnectorPolicy? _policy;
  List<ConnectorTool> _tools = const [];
  bool _toolsFailed = false;
  Set<String> _draft = {};
  Set<String> _baseline = {};
  String? _revision;
  bool _loading = true;
  bool _busy = false;
  bool _signedOut = false;
  Object? _error;

  String get _slug => widget.connector.slug;
  CapabilitiesRepository get _repo => widget.repository;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final toolsRead = _repo
        .connectorTools(_slug)
        .then<List<ConnectorTool>?>((tools) => tools)
        .catchError((Object _) => null);
    try {
      final policy = await _repo.connectorPolicy();
      final tools = await toolsRead;
      if (!mounted) return;
      setState(() {
        _tools = tools ?? const [];
        _toolsFailed = tools == null;
        _adopt(policy, keepDraft: false);
        _loading = false;
      });
    } catch (error) {
      unawaited(toolsRead);
      if (!mounted) return;
      setState(() {
        _signedOut =
            error is CapabilityFailure && error.detail == 'NEEDS_NOUS_AUTH';
        _error = error;
        _loading = false;
      });
    }
  }

  /// Takes the server's rules as the new baseline (and the draft, unless the
  /// user's edits are kept).
  void _adopt(ConnectorPolicy policy, {required bool keepDraft}) {
    _policy = policy;
    _revision = policy.memberRevision;
    _baseline = policy.memberDisabledTools(_slug);
    if (!keepDraft) _draft = {..._baseline};
  }

  bool get _editable =>
      !widget.readOnly && (_policy?.writable ?? false) && !_busy;

  bool get _dirty =>
      _draft.length != _baseline.length || !_draft.containsAll(_baseline);

  void _toggleTool(ConnectorTool tool, bool on) {
    setState(() {
      if (on) {
        _draft.remove(tool.slug);
      } else {
        _draft.add(tool.slug);
      }
    });
  }

  String _failure(Strings s, Object error) {
    final reason = error is CapabilityFailure ? error.detail : '';
    if (reason == 'FORBIDDEN_SCOPE' || reason == 'ORG_ACCESS_DENIED') {
      return s.cphConnectorPolicyForbidden;
    }
    return capabilityFailureMessage(s, error);
  }

  Future<void> _toggleConnector(bool enabled) async {
    final revision = _revision;
    if (revision == null) return;
    final s = Strings.of(context);
    final notices = HermesNotice.of(context);
    setState(() => _busy = true);
    try {
      await _repo.setConnectorEnabled(
        _slug,
        enabled,
        expectedRevision: revision,
      );
      widget.onChanged?.call();
      final fresh = await _repo.connectorPolicy();
      if (!mounted) return;
      setState(() => _adopt(fresh, keepDraft: true));
    } catch (error) {
      if (!mounted) return;
      if (error is CapabilityFailure && error.detail == 'POLICY_CONFLICT') {
        await _refreshAfterConflict();
        notices.show(
          message: s.cphConnectorConflictBody,
          kind: HermesNoticeKind.error,
        );
      } else {
        notices.show(message: _failure(s, error), kind: HermesNoticeKind.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshAfterConflict() async {
    try {
      final fresh = await _repo.connectorPolicy();
      if (mounted) setState(() => _adopt(fresh, keepDraft: true));
    } catch (_) {}
  }

  Future<void> _save() async {
    final revision = _revision;
    if (revision == null || _busy) return;
    final s = Strings.of(context);
    final notices = HermesNotice.of(context);
    setState(() => _busy = true);
    var retry = false;
    try {
      final next = await _repo.setConnectorTools(
        _slug,
        disabledToolsToSave(_draft),
        expectedRevision: revision,
      );
      if (!mounted) return;
      setState(() {
        _revision = next;
        _baseline = {..._draft};
      });
      notices.show(
        message: s.cphConnectorSaved,
        kind: HermesNoticeKind.success,
      );
      widget.onChanged?.call();
    } catch (error) {
      if (!mounted) return;
      if (error is CapabilityFailure && error.detail == 'POLICY_CONFLICT') {
        retry = await _resolveConflict();
      } else {
        notices.show(message: _failure(s, error), kind: HermesNoticeKind.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (retry && mounted) await _save();
  }

  /// Re-reads the rules, keeps the draft and asks. Returns whether to
  /// re-save against the new revision.
  Future<bool> _resolveConflict() async {
    final s = Strings.of(context);
    final ConnectorPolicy fresh;
    try {
      fresh = await _repo.connectorPolicy();
    } catch (error) {
      if (!mounted) return false;
      HermesNotice.of(
        context,
      ).show(message: _failure(s, error), kind: HermesNoticeKind.error);
      return false;
    }
    if (!mounted) return false;
    final names = {for (final tool in _tools) tool.slug: tool.name};
    final other = fresh.memberDisabledTools(_slug);
    final changed =
        other
            .difference(_baseline)
            .union(_baseline.difference(other))
            .map((slug) => names[slug] ?? slug)
            .toList()
          ..sort();
    final keep = await showHermesDialog<bool>(
      context: context,
      title: s.cphConnectorConflictTitle,
      message: [
        s.cphConnectorConflictBody,
        if (changed.isNotEmpty)
          s.cphConnectorConflictChanged(changed.join(', ')),
      ].join('\n'),
      actions: [
        HermesDialogAction(
          key: const ValueKey('cph-conflict-discard'),
          label: s.cphConnectorDiscard,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('cph-conflict-keep'),
          label: s.cphConnectorKeepMine,
          value: true,
        ),
      ],
    );
    if (!mounted) return false;
    setState(() => _adopt(fresh, keepDraft: keep == true));
    return keep == true;
  }

  String _facetLabel(Strings s, ToolFacet facet) => switch (facet) {
    ToolFacet.read => s.cphToolFacetRead,
    ToolFacet.write => s.cphToolFacetWrite,
    ToolFacet.destructive => s.cphToolFacetDestructive,
    ToolFacet.unclassified => s.cphToolFacetUnclassified,
  };

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final policy = _policy;
    final connector = widget.connector;

    String? reason;
    if (_signedOut) {
      reason = s.cphConnectorsSignedOut;
    } else if (_error != null) {
      reason = capabilityFailureMessage(s, _error!);
    } else if (widget.readOnly) {
      reason = s.cphReadOnly;
    } else if (policy != null && !policy.writable) {
      reason = s.cphConnectorPolicyManaged;
    }

    final sections = <Widget>[];
    if (_loading) {
      sections.add(
        const Padding(
          padding: EdgeInsets.only(top: 48),
          child: Center(
            child: CircularProgressIndicator(
              key: ValueKey('cph-connector-busy'),
            ),
          ),
        ),
      );
    } else if (policy != null) {
      final state = policy.connectorState(_slug);
      sections.add(const SizedBox(height: HermesSpace.x4));
      sections.add(
        HermesListGroup(
          children: [
            HermesToggleRow(
              key: const ValueKey('cph-connector-enabled'),
              icon: Icons.power_settings_new_rounded,
              title: s.cphConnectorEnabled,
              subtitle: state.locked ? s.cphConnectorLockedByOrg : null,
              value: state.enabled,
              onChanged: _editable && !state.locked ? _toggleConnector : null,
            ),
          ],
        ),
      );
      if (_toolsFailed) {
        sections.add(
          Padding(
            padding: const EdgeInsets.only(top: HermesSpace.x3),
            child: Text(
              s.cphConnectorToolsFailed,
              style: HermesType.support.copyWith(color: colors.textSecondary),
            ),
          ),
        );
      }
      for (final group in groupToolsByFacet(_tools)) {
        sections.add(HermesSectionHeader(_facetLabel(s, group.facet)));
        sections.add(
          HermesListGroup(
            children: [
              for (final tool in group.tools) _toolRow(s, policy, tool),
            ],
          ),
        );
      }
    }

    return HermesDetailScaffold(
      listKey: const ValueKey('cph-connector-list'),
      title: connector.name,
      status: HermesStatusText(
        label: connector.connected ? s.cphConnected : s.cphNotConnected,
        tone: connector.connected
            ? HermesStatusTone.ok
            : HermesStatusTone.neutral,
      ),
      reason: reason,
      primaryAction: _dirty && _editable
          ? HermesActionButton(
              key: const ValueKey('cph-connector-save'),
              primary: true,
              label: s.commonSave,
              icon: Icons.check_rounded,
              onPressed: _save,
            )
          : null,
      sections: sections,
    );
  }

  Widget _toolRow(Strings s, ConnectorPolicy policy, ConnectorTool tool) {
    final locked = policy.toolLocked(_slug, tool);
    final description = tool.description.trim();
    return HermesToggleRow(
      key: ValueKey('cph-tool-${tool.slug}'),
      title: tool.name,
      subtitle: locked
          ? s.cphToolLockedByOrg
          : description.isEmpty
          ? null
          : description,
      value: policy.toolEnabled(_slug, tool, _draft),
      onChanged: _editable && !locked ? (on) => _toggleTool(tool, on) : null,
    );
  }
}
