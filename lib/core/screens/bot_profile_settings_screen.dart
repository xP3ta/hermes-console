import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/bot_profile_client.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_notice.dart';

/// Only fields present in the server snapshot can become editable patches.
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
  final _controllers = <TextEditingController>[];
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
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save({bool confirmed = false}) async {
    if (_busy || _changes.isEmpty) return;
    final s = Strings.of(context);
    setState(() => _busy = true);
    try {
      final changes = Map<String, dynamic>.from(_changes);
      if (changes.containsKey('model') || changes.containsKey('provider')) {
        final initial = _snapshot!['model'] as Map? ?? {};
        changes['model'] ??= initial['default'] ?? '';
        changes['provider'] ??= initial['provider'] ?? '';
        if ((changes['model'] as String).trim().isEmpty ||
            (changes['provider'] as String).trim().isEmpty) {
          throw const FormatException('Incomplete model');
        }
      }
      if (confirmed) changes['confirm_expensive_model'] = true;
      final result = await widget.gateway.configureBotProfile(
        widget.profile,
        changes,
      );
      if (!mounted) return;
      if (result['confirm_required'] == true) {
        setState(() => _busy = false);
        final yes = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(s.botModel),
            content: Text((result['confirm_message'] as String?) ?? s.botModel),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(s.botCancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(s.botSave),
              ),
            ],
          ),
        );
        if (yes == true && mounted) await _save(confirmed: true);
        return;
      }
      final applied = result['applied'];
      final expected = changes.keys
          .map(
            (key) => switch (key) {
              'disabled_skills' => 'skills',
              'enabled_toolsets' => 'toolsets',
              'enabled_mcp_servers' => 'mcp_servers',
              'provider' => 'model',
              _ => key,
            },
          )
          .where((key) => key != 'confirm_expensive_model');
      if (applied is! Map || expected.any((key) => applied[key] != true)) {
        throw StateError('Profile configuration incomplete');
      }
      Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(s.botProfileFailed)),
          kind: HermesNoticeKind.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _text(
    String key,
    String label,
    String value, {
    bool multiline = false,
  }) => TextFormField(
    key: ValueKey('bot-settings-$key'),
    initialValue: value,
    enabled: !_busy,
    minLines: multiline ? 3 : 1,
    maxLines: multiline ? 8 : 1,
    maxLength: key == 'soul'
        ? 65536
        : key == 'description'
        ? 2048
        : 256,
    decoration: InputDecoration(labelText: label),
    onChanged: (value) => setState(() {
      if (value ==
          (key == 'model'
              ? (_snapshot!['model'] as Map)['default']
              : key == 'provider'
              ? (_snapshot!['model'] as Map)['provider']
              : _snapshot![key])) {
        _changes.remove(key);
      } else {
        _changes[key] = value;
      }
    }),
  );

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
    return ExpansionTile(
      title: Text(title),
      tilePadding: EdgeInsets.zero,
      children: [
        if (field == 'toolsets') Text(Strings.of(context).botToolsetsInherit),
        for (final entry in entries)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(entry['label'] is String ? entry['label'] as String : entry['name'] as String),
            value: selected == null
                ? entry['enabled'] != false
                : disabled
                ? !selected.contains(entry['name'])
                : selected.contains(entry['name']),
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    final values =
                        selected?.toSet() ??
                        entries
                            .where(
                              (e) => disabled
                                  ? e['enabled'] == false
                                  : e['enabled'] != false,
                            )
                            .map((e) => e['name'] as String)
                            .toSet();
                    if (disabled ? value != true : value == true) {
                      values.add(entry['name'] as String);
                    } else {
                      values.remove(entry['name']);
                    }
                    _changes[wire] = values.toList()..sort();
                  }),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final snapshot = _snapshot;
    return Scaffold(
      appBar: HermesAppBar(title: Text(s.botAdvanced)),
      body: SafeArea(
        child: snapshot == null
            ? Center(
                child: _failed
                    ? Text(s.botConfigUnavailable)
                    : const CircularProgressIndicator(),
              )
            : ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text(
                    widget.profile,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (snapshot['description'] is String)
                    _text(
                      'description',
                      s.botDescription,
                      snapshot['description'] as String,
                    ),
                  if (snapshot['model'] is Map) ...[
                    _text(
                      'provider',
                      s.botProvider,
                      snapshot['model']['provider'] is String ? snapshot['model']['provider'] as String : '',
                    ),
                    _text(
                      'model',
                      s.botModel,
                      snapshot['model']['default'] is String ? snapshot['model']['default'] as String : '',
                    ),
                  ],
                  if (snapshot['soul'] is String)
                    _text(
                      'soul',
                      'SOUL.md',
                      snapshot['soul'] as String,
                      multiline: true,
                    ),
                  if (snapshot['skills'] is List)
                    _toggles(
                      'skills',
                      'disabled_skills',
                      s.botSkills,
                      disabled: true,
                    ),
                  if (snapshot['toolsets'] is List)
                    _toggles('toolsets', 'enabled_toolsets', s.botTools),
                  if (snapshot['mcp_servers'] is List)
                    _toggles('mcp_servers', 'enabled_mcp_servers', s.botMcp),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy || _changes.isEmpty ? null : _save,
                    child: Text(s.botSave),
                  ),
                ],
              ),
      ),
    );
  }
}
