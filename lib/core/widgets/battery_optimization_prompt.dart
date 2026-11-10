// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../services/notifications/rich_notifications.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import 'hermes_ui.dart';

const kBatteryPromptDismissedPref = 'battery_optimization_prompt_dismissed';

/// A quiet reminder on Home, or an optional note during push setup.
class BatteryOptimizationPrompt extends StatefulWidget {
  const BatteryOptimizationPrompt({
    required this.hasConnection,
    this.prefs,
    this.dismissible = true,
    super.key,
  });

  final bool hasConnection;
  final SharedPreferences? prefs;
  final bool dismissible;

  @override
  State<BatteryOptimizationPrompt> createState() =>
      _BatteryOptimizationPromptState();
}

class _BatteryOptimizationPromptState extends State<BatteryOptimizationPrompt>
    with WidgetsBindingObserver {
  final _platform = PlatformRichNotifications();
  BatteryOptimizationStatus? _status;
  bool _dismissed = false;
  bool _opening = false;
  int _loadEpoch = 0;

  bool get _available =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      widget.hasConnection;

  bool get _savedDismissal =>
      widget.prefs?.getBool(kBatteryPromptDismissedPref) ?? _dismissed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didUpdateWidget(BatteryOptimizationPrompt oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Home is rebuilt when Settings is uncovered. Read the preference again
    // so its explicit restore action also reaches an already mounted Home.
    if (oldWidget.hasConnection != widget.hasConnection ||
        oldWidget.prefs != widget.prefs ||
        oldWidget.dismissible != widget.dismissible ||
        _savedDismissal != _dismissed) {
      _load();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load() async {
    final epoch = ++_loadEpoch;
    _dismissed = _savedDismissal;
    if (!_available || (widget.dismissible && _dismissed)) {
      if (mounted) setState(() => _status = null);
      return;
    }
    final status = await _platform.batteryStatus();
    if (!mounted || epoch != _loadEpoch) return;
    setState(() => _status = status);
  }

  Future<void> _openSettings() async {
    setState(() => _opening = true);
    try {
      // Exactly the same channel and Kotlin path as BatteryOptimizationRow.
      await _platform.openBatterySettings();
      // Covers settings that reply with the changed status immediately; a
      // separate resume read covers the usual external system activity.
      if (mounted) await _load();
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _dismiss() async {
    setState(() => _dismissed = true);
    await widget.prefs?.setBool(kBatteryPromptDismissedPref, true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_available ||
        (widget.dismissible && _dismissed) ||
        _status == null ||
        _status!.ignoringOptimizations) {
      return const SizedBox.shrink();
    }
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.battery_saver_outlined,
                size: HermesIcon.lg,
                color: colors.textSecondary,
              ),
              const SizedBox(width: HermesSpace.x2),
              Expanded(
                child: Text(
                  s.batPromptTitle,
                  style: HermesType.body.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: HermesSpace.x1),
          Text(
            widget.dismissible ? s.batPromptBody : s.batPushBatteryNote,
            style: HermesType.support.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: HermesSpace.x2),
          // Full-width, wrapping labels keep the text's chosen scale and a
          // 48 dp target even in narrow windows and the longer translations.
          TextButton(
            key: const ValueKey('battery-prompt-open'),
            onPressed: _opening ? null : _openSettings,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              foregroundColor: colors.accentText,
            ),
            child: Text(s.batOpenSettings, textAlign: TextAlign.center),
          ),
          if (widget.dismissible)
            TextButton(
              key: const ValueKey('battery-prompt-dismiss'),
              onPressed: _dismiss,
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                foregroundColor: colors.textSecondary,
              ),
              child: Text(s.batPromptNotNow, textAlign: TextAlign.center),
            ),
        ],
      ),
    );
    return widget.dismissible ? HermesPanel(child: content) : content;
  }
}
