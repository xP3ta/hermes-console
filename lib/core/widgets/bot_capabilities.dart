import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/list.dart';
import '../design/modal.dart';
import '../design/tokens.dart';
import '../theme/app_theme.dart';
import 'console_loader.dart';
import 'hermes_ui.dart' show HermesField, HermesSwitchTile;

/// A server capability, without inferring tools or connection status.
class BotCapabilityEntry {
  final String name;
  final String? label;
  final String? description;
  final String? group;
  final String? status;
  final bool enabled;

  const BotCapabilityEntry({
    required this.name,
    this.label,
    this.description,
    this.group,
    this.status,
    required this.enabled,
  });

  factory BotCapabilityEntry.fromMap(Map entry, {bool? enabled}) =>
      BotCapabilityEntry(
        name: entry['name'] as String,
        label: _text(entry['label']),
        description: _text(entry['description']),
        group: _text(entry['group']),
        status: _text(entry['status']),
        enabled: enabled ?? entry['enabled'] != false,
      );

  BotCapabilityEntry withEnabled(bool value) => BotCapabilityEntry(
    name: name,
    label: label,
    description: description,
    group: group,
    status: status,
    enabled: value,
  );

  static String? _text(Object? raw) {
    if (raw is! String) return null;
    final value = raw.trim();
    return value.isEmpty ? null : value;
  }
}

String botCapabilitySummary(
  BuildContext context,
  List<BotCapabilityEntry>? entries, {
  bool inherited = false,
}) {
  final s = Strings.of(context);
  if (entries != null && entries.isEmpty) return s.botCapabilitiesNone;
  if (inherited || entries == null) return s.botCapabilitiesIncluded;
  final count = entries.where((entry) => entry.enabled).length;
  return count == 0
      ? s.botCapabilitiesNone
      : s.botCapabilitiesCount(count, entries.length);
}

/// Skills, toolsets and MCP use the same row and the same floating editor.
/// The list is built only on tap; toggles update the form's draft immediately.
class BotCapabilitiesRow extends StatelessWidget {
  final String title;
  final String summary;
  final String keyPrefix;
  final String emptyText;
  final String? unavailableText;
  final String? inheritedHint;
  final List<BotCapabilityEntry>? entries;
  final Future<List<BotCapabilityEntry>?> Function()? loadEntries;
  final void Function(String name, bool enabled) onChanged;
  final bool enabled;

  const BotCapabilitiesRow({
    super.key,
    required this.title,
    required this.summary,
    required this.keyPrefix,
    required this.emptyText,
    required this.entries,
    required this.onChanged,
    this.loadEntries,
    this.unavailableText,
    this.inheritedHint,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) => HermesListRow(
    title: title,
    value: summary,
    onTap: !enabled
        ? null
        : () => showHermesSurface<void>(
            context: context,
            surfaceKey: ValueKey('$keyPrefix-picker'),
            maxWidth: 480,
            builder: (_) => _BotCapabilityPicker(
              title: title,
              keyPrefix: keyPrefix,
              emptyText: emptyText,
              unavailableText: unavailableText,
              inheritedHint: inheritedHint,
              entries: entries,
              loadEntries: loadEntries,
              onChanged: onChanged,
            ),
          ),
  );
}

class _BotCapabilityPicker extends StatefulWidget {
  final String title;
  final String keyPrefix;
  final String emptyText;
  final String? unavailableText;
  final String? inheritedHint;
  final List<BotCapabilityEntry>? entries;
  final Future<List<BotCapabilityEntry>?> Function()? loadEntries;
  final void Function(String name, bool enabled) onChanged;

  const _BotCapabilityPicker({
    required this.title,
    required this.keyPrefix,
    required this.emptyText,
    required this.entries,
    required this.loadEntries,
    required this.onChanged,
    this.unavailableText,
    this.inheritedHint,
  });

  @override
  State<_BotCapabilityPicker> createState() => _BotCapabilityPickerState();
}

class _BotCapabilityPickerState extends State<_BotCapabilityPicker> {
  final _search = TextEditingController();
  List<BotCapabilityEntry>? _entries;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _entries = widget.entries;
    if (_entries == null && widget.loadEntries != null) {
      _loading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  Future<void> _load() async {
    List<BotCapabilityEntry>? entries;
    try {
      entries = await widget.loadEntries!();
    } catch (_) {
      // A missing/failed catalog cannot be presented as an empty catalog.
    }
    if (mounted) {
      setState(() {
        _entries = entries;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String? _subtitle(BotCapabilityEntry entry, Strings s) {
    final status = switch (entry.status?.toLowerCase()) {
      'connected' => s.botCapabilityConnected,
      'disconnected' => s.botCapabilityDisconnected,
      'connecting' => s.botCapabilityConnecting,
      'error' || 'failed' => s.botCapabilityFailed,
      _ => entry.status,
    };
    final parts = [if (entry.description != null) entry.description!, ?status];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  void _toggle(BotCapabilityEntry entry, bool enabled) {
    widget.onChanged(entry.name, enabled);
    setState(() {
      _entries = [
        for (final item in _entries!)
          item.name == entry.name ? item.withEnabled(enabled) : item,
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final entries = _entries;
    final query = _search.text.trim().toLowerCase();
    final visible =
        entries
            ?.where(
              (entry) =>
                  '${entry.name} ${entry.label ?? ''} ${entry.description ?? ''} ${entry.group ?? ''}'
                      .toLowerCase()
                      .contains(query),
            )
            .toList() ??
        const <BotCapabilityEntry>[];
    // Preserve server order within its groups; never synthesize categories.
    final groups = <String?, List<BotCapabilityEntry>>{};
    for (final entry in visible) {
      (groups[entry.group] ??= []).add(entry);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HermesSurfaceHeader(title: widget.title, showClose: true),
        if (entries != null && entries.length > 12)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: HermesField(
              key: ValueKey('${widget.keyPrefix}-search'),
              label: s.designSearch,
              controller: _search,
              textInputAction: TextInputAction.search,
              onChanged: (_) => setState(() {}),
            ),
          ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: ConsoleLoader.large()),
                )
              else if (visible.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    entries == null
                        ? widget.unavailableText ?? s.botConfigUnavailable
                        : entries.isEmpty
                        ? widget.emptyText
                        : s.designNoMatches,
                    style: HermesType.support.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                )
              else
                for (final group in groups.entries) ...[
                  if (group.key != null) HermesSectionHeader(group.key!),
                  HermesListGroup(
                    dividerIndent: 16,
                    children: [
                      for (final entry in group.value)
                        Material(
                          type: MaterialType.transparency,
                          child: HermesSwitchTile(
                            key: ValueKey('${widget.keyPrefix}-${entry.name}'),
                            title: entry.label ?? entry.name,
                            subtitle: _subtitle(entry, s),
                            subtitleMaxLines: 1,
                            value: entry.enabled,
                            onChanged: (value) => _toggle(entry, value),
                          ),
                        ),
                    ],
                  ),
                ],
              if (entries != null &&
                  entries.isNotEmpty &&
                  !entries.any((entry) => entry.enabled) &&
                  widget.inheritedHint != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    widget.inheritedHint!,
                    style: HermesType.support.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
