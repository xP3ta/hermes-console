import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../services/install_source.dart';
import '../theme/app_theme.dart';

/// Settings → About: which channel delivers updates, a button to open it, and
/// why switching channel needs an uninstall (different signing keys).
class InstallSourceSection extends StatefulWidget {
  /// Test seam: skip the platform lookup.
  final InstallSource? initialSource;

  const InstallSourceSection({super.key, this.initialSource});

  @override
  State<InstallSourceSection> createState() => _InstallSourceSectionState();
}

class _InstallSourceSectionState extends State<InstallSourceSection> {
  InstallSource? _source;

  @override
  void initState() {
    super.initState();
    _source = widget.initialSource;
    if (_source == null) {
      InstallSourceInfo.detect().then((source) {
        if (mounted) setState(() => _source = source);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final source = _source;
    final label = switch (source) {
      InstallSource.googlePlay => s.aboutUpdatesPlay,
      InstallSource.githubObtainium => s.aboutUpdatesGithub,
      InstallSource.manual => s.aboutUpdatesManual,
      null => '…',
    };
    final isPlay = source == InstallSource.googlePlay;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HermesListGroup(
          children: [
            HermesListRow(
              key: const ValueKey('install-source-row'),
              icon: Icons.system_update_alt_rounded,
              title: s.aboutUpdatesTitle,
              value: label,
              showChevron: false,
            ),
            if (source != null)
              HermesListRow(
                key: const ValueKey('install-source-open'),
                icon: Icons.open_in_new_rounded,
                iconColor: colors.accentText,
                title: isPlay
                    ? s.aboutUpdatesOpenPlay
                    : s.aboutUpdatesOpenReleases,
                showChevron: false,
                onTap: () => launchUrl(
                  Uri.parse(InstallSourceInfo.updateUrl(source)),
                  mode: LaunchMode.externalApplication,
                ),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
          child: Text(
            s.aboutUpdatesSwitchNote,
            style: HermesType.support.copyWith(color: colors.textSecondary),
          ),
        ),
      ],
    );
  }
}
