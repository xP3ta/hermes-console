// On-demand log view of one MCP server. One read when it opens and one per
// manual refresh or source switch; there is no timer, and the lines live in
// this State only (never persisted, never exported).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_premium_ui.dart'
    show HermesSegment, HermesSegmentedControl;
import 'capabilities_repository.dart';
import 'capability_ui.dart';

enum _LogSource { server, agent }

class McpLogsScreen extends StatefulWidget {
  final CapabilitiesRepository repository;
  final String server;

  /// stdio servers have their own stderr log; others only show up in the
  /// agent log.
  final bool stdio;

  const McpLogsScreen({
    super.key,
    required this.repository,
    required this.server,
    required this.stdio,
  });

  @override
  State<McpLogsScreen> createState() => _McpLogsScreenState();
}

class _McpLogsScreenState extends State<McpLogsScreen> {
  late _LogSource _source = widget.stdio ? _LogSource.server : _LogSource.agent;
  List<String>? _lines;
  Object? _error;
  bool _loading = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final lines = await widget.repository.mcpLogLines(
        widget.server,
        stdio: _source == _LogSource.server,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _lines = lines;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _lines = null;
        _error = error;
        _loading = false;
      });
      // A server without the route has nothing to show: leave the screen so
      // the detail can hide its entry.
      if (capabilityFailureKindOf(error) == CapabilityFailureKind.unsupported) {
        Navigator.of(context).maybePop();
      }
    }
  }

  void _select(_LogSource source) {
    if (source == _source) return;
    _source = source;
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final lines = _lines;
    return HermesPage(
      listKey: const ValueKey('cph-logs-list'),
      title: '${s.cphLogsTitle} · ${widget.server}',
      actions: [
        IconButton(
          key: const ValueKey('cph-logs-refresh'),
          tooltip: s.cphLogsRefresh,
          icon: const Icon(Icons.refresh_rounded),
          onPressed: _loading ? null : _load,
        ),
      ],
      children: [
        if (widget.stdio) ...[
          HermesSegmentedControl<_LogSource>(
            value: _source,
            onChanged: _select,
            segments: [
              HermesSegment(
                key: const ValueKey('cph-logs-seg-server'),
                value: _LogSource.server,
                label: s.cphLogsSourceServer,
              ),
              HermesSegment(
                key: const ValueKey('cph-logs-seg-agent'),
                value: _LogSource.agent,
                label: s.cphLogsSourceAgent,
              ),
            ],
          ),
          const SizedBox(height: HermesSpace.x3),
        ],
        if (_loading)
          const Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(
              child: CircularProgressIndicator(key: ValueKey('cph-logs-busy')),
            ),
          )
        else if (_error != null)
          Text(
            capabilityFailureMessage(s, _error!),
            key: const ValueKey('cph-logs-error'),
            style: HermesType.support.copyWith(color: colors.textSecondary),
          )
        else if (lines == null || lines.isEmpty)
          Text(
            s.cphLogsEmpty,
            key: const ValueKey('cph-logs-empty'),
            style: HermesType.support.copyWith(color: colors.textSecondary),
          )
        else
          SelectableText(
            lines.join('\n'),
            key: const ValueKey('cph-logs-text'),
            style: HermesType.caption.copyWith(
              color: colors.textPrimary,
              fontFamily: 'monospace',
            ),
          ),
      ],
    );
  }
}
