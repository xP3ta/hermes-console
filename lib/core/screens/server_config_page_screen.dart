import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/list.dart';
import '../design/page.dart';
import '../services/server_config_repository.dart';
import '../settings/server_config_pages.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/server_config_field_row.dart';

/// Title of a Settings › Advanced page.
String serverConfigPageTitle(Strings s, ServerConfigPage page) =>
    switch (page) {
      ServerConfigPage.mainModel => s.ad1215PageMainModel,
      ServerConfigPage.behavior => s.ad1215PageBehavior,
      ServerConfigPage.projects => s.ad1215PageProjects,
      ServerConfigPage.shell => s.ad1215PageShell,
      ServerConfigPage.files => s.ad1215PageFiles,
      ServerConfigPage.network => s.ad1215PageNetwork,
      ServerConfigPage.context => s.ad1215PageContext,
      ServerConfigPage.conversation => s.ad1215PageConversation,
      ServerConfigPage.runtime => s.ad1215PageRuntime,
    };

/// The icon of a page row.
IconData serverConfigPageIcon(ServerConfigPage page) => switch (page) {
  ServerConfigPage.mainModel => Icons.psychology_outlined,
  ServerConfigPage.behavior => Icons.tune_outlined,
  ServerConfigPage.projects => Icons.folder_outlined,
  ServerConfigPage.shell => Icons.terminal_outlined,
  ServerConfigPage.files => Icons.description_outlined,
  ServerConfigPage.network => Icons.language_outlined,
  ServerConfigPage.context => Icons.compress_outlined,
  ServerConfigPage.conversation => Icons.record_voice_over_outlined,
  ServerConfigPage.runtime => Icons.memory_outlined,
};

/// One page of Settings › Advanced: the fields of its table row that the
/// schema brought, plus [leading] widgets the caller mounts above them (the
/// compression card on Context, the voice link on Conversation).
class ServerConfigPageScreen extends StatelessWidget {
  const ServerConfigPageScreen({
    required this.page,
    required this.fields,
    required this.repository,
    required this.writable,
    this.leading = const [],
    this.isCurrent,
    this.highlightPath,
    super.key,
  });

  final ServerConfigPage page;
  final List<ServerConfigField> fields;
  final ServerConfigRepository repository;
  final bool writable;
  final List<Widget> leading;
  final bool Function()? isCurrent;

  /// Field to scroll to and tint once.
  final String? highlightPath;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return HermesPage(
      title: serverConfigPageTitle(s, page),
      children: [
        if (!writable) HermesInfoBanner(s.readOnlyNotice),
        ...leading,
        if (fields.isNotEmpty)
          HermesListGroup(
            children: [
              for (final field in fields)
                ServerConfigFieldRow(
                  key: ValueKey('row-${field.path}'),
                  field: field,
                  repository: repository,
                  writable: writable,
                  isCurrent: isCurrent,
                  highlighted: field.path == highlightPath,
                ),
            ],
          ),
      ],
    );
  }
}
