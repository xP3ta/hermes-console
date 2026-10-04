import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/content.dart';
import '../theme/app_theme.dart';
import '../widgets/chat/embeds/embed_consent_store.dart';
import '../widgets/chat/embeds/embed_detector.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_ui.dart';

/// Settings › Chat › Rich embeds: one switch per type, all off by default.
/// Per device; nothing here is synced or sent to the server.
class EmbedSettingsScreen extends StatelessWidget {
  final EmbedConsentStore? store;

  const EmbedSettingsScreen({this.store, super.key});

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final consent = store ?? EmbedConsentStore.shared;
    final types = [
      for (final type in EmbedType.values)
        if (type != EmbedType.mermaid || embedMermaidAvailable) type,
    ];
    return Scaffold(
      appBar: AppBar(title: Text(s.embedSettingsTitle)),
      body: ListenableBuilder(
        listenable: consent,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                s.embedSettingsIntro,
                style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
              ),
            ),
            HermesGroup(
              children: [
                for (final type in types) ...[
                  HermesToggleRow(
                    key: ValueKey('embed-type-${type.name}'),
                    switchKey: ValueKey('embed-type-${type.name}-switch'),
                    title: type.label,
                    value: consent.modeFor(type) != EmbedMode.off,
                    onChanged: (on) => consent.setMode(
                      type,
                      on ? EmbedMode.ask : EmbedMode.off,
                    ),
                  ),
                  if (consent.modeFor(type) != EmbedMode.off)
                    HermesToggleRow(
                      key: ValueKey('embed-type-${type.name}-always'),
                      switchKey: ValueKey(
                        'embed-type-${type.name}-always-switch',
                      ),
                      title: s.embedSettingsAlways,
                      subtitle: consent.modeFor(type) == EmbedMode.always
                          ? null
                          : s.embedSettingsAskEachTime,
                      value: consent.modeFor(type) == EmbedMode.always,
                      onChanged: (on) => consent.setMode(
                        type,
                        on ? EmbedMode.always : EmbedMode.ask,
                      ),
                    ),
                ],
              ],
            ),
            if (consent.anyAllowed)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('embed-clear-allowed'),
                  onPressed: () async {
                    await consent.clearAllowed();
                    if (!context.mounted) return;
                    HermesNotice.of(context).showSnackBar(
                      SnackBar(content: Text(s.embedSettingsCleared)),
                      kind: HermesNoticeKind.success,
                    );
                  },
                  child: Text(s.embedSettingsClear),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
