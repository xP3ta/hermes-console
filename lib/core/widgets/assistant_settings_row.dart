// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
//
// Issue #217: Ajustes → Voz dice si Console es el asistente digital de Android
// y abre la pantalla del sistema donde se elige. Solo informa: Console no puede
// ponerse como asistente por su cuenta y nunca lee la pantalla.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/list.dart';
import '../design/tokens.dart';

class AssistantSettingsGroup extends StatefulWidget {
  const AssistantSettingsGroup({
    required this.load,
    required this.openSettings,
    super.key,
  });

  /// `null` = no se sabe (lado nativo antiguo): no se muestra nada.
  final Future<bool?> Function() load;
  final Future<bool> Function() openSettings;

  @override
  State<AssistantSettingsGroup> createState() => _AssistantSettingsGroupState();
}

class _AssistantSettingsGroupState extends State<AssistantSettingsGroup>
    with WidgetsBindingObserver {
  bool? _isDefault;

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

  // Al volver de la pantalla del sistema la elección puede haber cambiado.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    bool? value;
    try {
      value = await widget.load();
    } catch (_) {
      value = null;
    }
    if (mounted) setState(() => _isDefault = value);
  }

  @override
  Widget build(BuildContext context) {
    final isDefault = _isDefault;
    if (isDefault == null) return const SizedBox.shrink();
    final s = Strings.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: HermesSpace.x4),
      child: HermesListGroup(
        key: const ValueKey('assistant_settings_group'),
        children: [
          HermesListRow(
            key: const ValueKey('assistant_settings_row'),
            icon: Icons.assistant_outlined,
            title: s.assistRowTitle,
            subtitle: isDefault ? s.assistRowOn : s.assistRowOff,
            subtitleMaxLines: 3,
            onTap: () => widget.openSettings(),
          ),
        ],
      ),
    );
  }
}
