// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
//
// M6: Ajustes → Notificaciones dice si Android puede frenar la app en segundo
// plano (optimización de batería, restricción en segundo plano, «apps en
// suspensión» de Samsung) y abre la pantalla del sistema para cambiarlo.
// Solo informa: la app nunca pide REQUEST_IGNORE_BATTERY_OPTIMIZATIONS.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../services/notifications/rich_notifications.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import 'battery_optimization_prompt.dart';
import 'hermes_ui.dart';

class BatteryOptimizationRow extends StatefulWidget {
  const BatteryOptimizationRow({
    required this.load,
    required this.openSettings,
    this.prefs,
    super.key,
  });

  /// Lee el estado; `null` = no se sabe (lado nativo antiguo) y no se
  /// muestra nada.
  final Future<BatteryOptimizationStatus?> Function() load;
  final Future<bool> Function() openSettings;
  final SharedPreferences? prefs;

  @override
  State<BatteryOptimizationRow> createState() => _BatteryOptimizationRowState();
}

class _BatteryOptimizationRowState extends State<BatteryOptimizationRow>
    with WidgetsBindingObserver {
  BatteryOptimizationStatus? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Al volver de la pantalla del sistema, el estado puede haber cambiado.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    BatteryOptimizationStatus? status;
    try {
      status = await widget.load();
    } catch (_) {
      status = null;
    }
    if (mounted) setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    if (status == null) return const SizedBox.shrink();
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final restricted = status.backgroundRestricted;
    final free = !restricted && status.ignoringOptimizations;
    final state = restricted
        ? s.batStateRestricted
        : free
        ? s.batStateUnrestricted
        : s.batStateOptimized;
    final body = restricted
        ? s.batRestrictedBody
        : free
        ? null
        : s.batOptimizedBody;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: HermesSpace.x2,
            runSpacing: HermesSpace.x1,
            children: [
              Text(
                s.batTitle,
                style: HermesType.body.copyWith(color: colors.textPrimary),
              ),
              Text(
                state,
                style: HermesType.support.copyWith(
                  color: restricted
                      ? colors.error
                      : free
                      ? colors.success
                      : colors.textSecondary,
                ),
              ),
            ],
          ),
          if (body != null) ...[
            const SizedBox(height: HermesSpace.x1),
            Text(
              body,
              style: HermesType.support.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: HermesSpace.x2),
            HermesSecondaryButton(
              label: s.batOpenSettings,
              onTap: () => widget.openSettings(),
            ),
          ],
          if (!status.ignoringOptimizations &&
              widget.prefs?.getBool(kBatteryPromptDismissedPref) == true)
            TextButton(
              key: const ValueKey('battery-prompt-restore'),
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                foregroundColor: colors.accentText,
              ),
              onPressed: () async {
                await widget.prefs!.remove(kBatteryPromptDismissedPref);
                if (mounted) setState(() {});
              },
              child: Text(s.batPromptRestore),
            ),
        ],
      ),
    );
  }
}
