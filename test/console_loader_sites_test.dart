// Guards the loader sweep: content loading states use ConsoleLoader, not a
// bare Material spinner. In-button/action spinners, determinate progress and
// the header/activity pill are deliberately left alone (see the PR notes).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Screens and panels whose content loading state is the Console loader.
const _sites = <String>[
  'lib/core/capabilities/capabilities_screen.dart',
  'lib/core/capabilities/catalog_deep_link_screen.dart',
  'lib/core/capabilities/connector_detail_screen.dart',
  'lib/core/capabilities/mcp_logs_screen.dart',
  'lib/core/screens/admin_integrations_screen.dart',
  'lib/core/screens/bot_create_screen.dart',
  'lib/core/screens/bot_profile_settings_screen.dart',
  'lib/core/screens/chat_content_screen.dart',
  'lib/core/screens/companion/petdex_gallery_screen.dart',
  'lib/core/screens/credential_pool_screen.dart',
  'lib/core/screens/dashboard_setup_screen.dart',
  'lib/core/screens/extensions_center_screen.dart',
  'lib/core/screens/foreign_session_import_screen.dart',
  'lib/core/screens/local_models_screen.dart',
  'lib/core/screens/memory_draft_screen.dart',
  'lib/core/screens/mission_control_screen.dart',
  'lib/core/screens/moa_recipe_screen.dart',
  'lib/core/screens/models_screen.dart',
  'lib/core/screens/profile_editor_screen.dart',
  'lib/core/screens/profiles_screen.dart',
  'lib/core/screens/projects_center_screen.dart',
  'lib/core/screens/recovery_center_screen.dart',
  'lib/core/screens/session_list_screen.dart',
  'lib/core/screens/sftp_browser_screen.dart',
  'lib/core/screens/soul_screen.dart',
  'lib/core/screens/ssh_screen.dart',
  'lib/core/screens/ssh_terminal_screen.dart',
  'lib/core/screens/subagent_detail_screen.dart',
  'lib/core/screens/tasks_screen.dart',
  'lib/core/widgets/artifact_viewer/artifact_viewer_screen.dart',
  'lib/core/widgets/attachment_history_preview.dart',
  'lib/core/widgets/chat_prompt_sheet.dart',
  'lib/core/widgets/profile_switcher.dart',
  'lib/core/widgets/projects/project_files_browser.dart',
];

Iterable<File> _dartFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

void main() {
  test('no centred Material spinner is left as a content loading state', () {
    final centred = RegExp(
      r'Center\(\s*child:\s*(const\s+)?CircularProgressIndicator\(',
    );
    final hits = <String>[];
    for (final f in _dartFiles()) {
      final src = f.readAsStringSync();
      if (centred.hasMatch(src)) hits.add(f.path);
    }
    // The generated-video frame keeps its thin ring on the black video
    // surface, where the theme accent is not guaranteed to read.
    hits.remove('lib/core/widgets/generated_video_card.dart');
    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  test('every swept site renders the Console loader', () {
    for (final path in _sites) {
      final src = File(path).readAsStringSync();
      expect(src, contains('ConsoleLoader.'), reason: path);
    }
  });

  test('the header activity pill and the splash keep their own indicators', () {
    for (final path in const [
      'lib/core/widgets/activity_pill.dart',
      'lib/core/widgets/hermes_status_indicator.dart',
    ]) {
      expect(
        File(path).readAsStringSync(),
        isNot(contains('ConsoleLoader')),
        reason: path,
      );
    }
    for (final f in _dartFiles().where((f) => f.path.contains('splash'))) {
      expect(
        f.readAsStringSync(),
        isNot(contains('ConsoleLoader')),
        reason: f.path,
      );
    }
  });
}
