import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/bot_profile_client.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/console_loader.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/bot_settings_group.dart';
import '../widgets/bot_capabilities.dart';
import '../feedback/feedback_policy.dart';

/// Only fields present in the server snapshot can become editable patches.
/// The model is not one of them: it is chosen with a picker on the bot's
/// card and in the profile editor, never typed.
class BotProfileSettingsScreen extends StatefulWidget {
  final String profile;
  final BotProfileGateway gateway;
  const BotProfileSettingsScreen({
    super.key,
    required this.profile,
    required this.gateway,
  });
  @override
  State<BotProfileSettingsScreen> createState() =>
      _BotProfileSettingsScreenState();
}

class _BotProfileSettingsScreenState extends State<BotProfileSettingsScreen> {
  Map<String, dynamic>? _snapshot;
  final _changes = <String, dynamic>{};
  final _controllers = <String, TextEditingController>{};
  bool _busy = false;
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snapshot = await widget.gateway.describeBotProfile(widget.profile);
      if (mounted) {
        setState(() {
          _snapshot = snapshot;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || _changes.isEmpty) return;
    final s = Strings.of(context);
    setState(() => _busy = true);
    try {
      final changes = Map<String, dynamic>.from(_changes);
      final result = await widget.gateway.configureBotProfile(
        widget.profile,
        changes,
      );
      if (!mounted) return;
      final applied = result['applied'];
      final expected = changes.keys.map(
        (key) => switch (key) {
          'disabled_skills' => 'skills',
          'enabled_toolsets' => 'toolsets',
          'enabled_mcp_servers' => 'mcp_servers',
          _ => key,
        },
      );
      if (applied is! Map || expected.any((key) => applied[key] != true)) {
        throw StateError('Profile configuration incomplete');
      }
      Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        AppFeedback.of(context).notify(FeedbackKind.error, s.botProfileFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A field of the form: its label on its own line, the field, and the
  /// counter under it, with room before whatever follows.
  Widget _text(
    String key,
    String label,
    String value, {
    bool multiline = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: HermesField(
      fieldKey: ValueKey('bot-settings-$key'),
      label: label,
      controller: _controllers[key] ??= TextEditingController(text: value),
      enabled: !_busy,
      minLines: multiline ? 3 : 1,
      maxLines: multiline ? 8 : 1,
      maxLength: key == 'soul'
          ? 65536
          : key == 'description'
          ? 2048
          : 256,
      onChanged: (value) => setState(() {
        if (value == _snapshot![key]) {
          _changes.remove(key);
        } else {
          _changes[key] = value;
        }
      }),
    ),
  );

  /// "Guardar" stays at the bottom, with a line that says whether there is
  /// anything to save (the profile editor's and the create form's bar).
  Widget _saveBar(Strings s, HermesThemeColors colors) {
    final dirty = _changes.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 9, 20, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            dirty ? s.botUnsavedChanges : s.botNoPendingChanges,
            key: ValueKey(dirty ? 'bot-settings-dirty' : 'bot-settings-clean'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: dirty ? colors.accent : colors.textSecondary,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 7),
          HermesPrimaryButton(
            key: const ValueKey('bot-settings-save'),
            label: s.botSave,
            icon: _busy ? Icons.sync : Icons.check,
            onTap: _busy || !dirty ? null : _save,
          ),
        ],
      ),
    );
  }

  Widget _toggles(
    String field,
    String wire,
    String title, {
    bool disabled = false,
  }) {
    final entries = (_snapshot![field] as List)
        .whereType<Map>()
        .where((e) => e['name'] is String)
        .toList();
    final selected = _changes[wire] as List<String>?;
    final s = Strings.of(context);
    final options = [
      for (final entry in entries)
        BotCapabilityEntry.fromMap(
          entry,
          enabled: selected == null
              ? entry['enabled'] != false
              : disabled
              ? !selected.contains(entry['name'])
              : selected.contains(entry['name']),
        ),
    ];
    final inherited =
        field == 'toolsets' &&
        (selected != null
            ? selected.isEmpty
            : _snapshot!['toolsets_pinned'] == false);
    return BotCapabilitiesRow(
      key: ValueKey('bot-settings-$field-row'),
      title: title,
      summary: botCapabilitySummary(context, options, inherited: inherited),
      keyPrefix: 'bot-settings-$field',
      entries: options,
      emptyText: switch (field) {
        'skills' => s.botSkillsEmpty,
        'mcp_servers' => s.botMcpEmpty,
        _ => s.botToolsEmpty,
      },
      inheritedHint: field == 'toolsets' ? s.botToolsetsInherit : null,
      enabled: !_busy,
      onChanged: (name, value) => setState(() {
        final values =
            (_changes[wire] as List<String>?)?.toSet() ??
            entries
                .where(
                  (e) =>
                      disabled ? e['enabled'] == false : e['enabled'] != false,
                )
                .map((e) => e['name'] as String)
                .toSet();
        if (disabled ? !value : value) {
          values.add(name);
        } else {
          values.remove(name);
        }
        _changes[wire] = values.toList()..sort();
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final snapshot = _snapshot;
    return Scaffold(
      appBar: HermesAppBar(title: Text(s.botAdvanced)),
      body: SafeArea(
        child: snapshot == null
            ? Center(
                child: _failed
                    ? Text(s.botConfigUnavailable)
                    : const ConsoleLoader.large(),
              )
            : Column(
                children: [
                  Expanded(
                    child: ListView(
                      clipBehavior: hermesUnderHeader,
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                      children: [
                        Text(
                          widget.profile,
                          key: const ValueKey('bot-settings-heading'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 18),
                        if (snapshot['description'] is String)
                          _text(
                            'description',
                            s.botDescription,
                            snapshot['description'] as String,
                          ),
                        if (snapshot['soul'] is String)
                          _text(
                            'soul',
                            'SOUL.md',
                            snapshot['soul'] as String,
                            multiline: true,
                          ),
                        BotSettingsGroup(
                          children: [
                            if (snapshot['skills'] is List)
                              _toggles(
                                'skills',
                                'disabled_skills',
                                s.botSkills,
                                disabled: true,
                              ),
                            if (snapshot['toolsets'] is List)
                              _toggles(
                                'toolsets',
                                'enabled_toolsets',
                                s.botTools,
                              ),
                            if (snapshot['mcp_servers'] is List)
                              _toggles(
                                'mcp_servers',
                                'enabled_mcp_servers',
                                s.botMcp,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  _saveBar(s, colors),
                ],
              ),
      ),
    );
  }
}
