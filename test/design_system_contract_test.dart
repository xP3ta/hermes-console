// Spec 080 design-system contracts. Each allow-list is the set of files that
// still use a deprecated primitive, with its current count. The lists may
// only SHRINK: a new file or a higher count fails, and a migrated file must
// be removed from its list (stale entries fail too) so progress is locked in.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _withoutComments(String source) => source
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .replaceAll(RegExp(r'//[^\r\n]*'), '');

Map<String, int> _scan(RegExp pattern, {Set<String> skip = const {}}) {
  final out = <String, int>{};
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = entity.path.replaceAll(r'\\', '/');
    if (path.startsWith('lib/l10n/') || skip.contains(path)) continue;
    final n = pattern
        .allMatches(_withoutComments(entity.readAsStringSync()))
        .length;
    if (n > 0) out[path] = n;
  }
  return out;
}

void _expectShrinkOnly(
  String what,
  Map<String, int> found,
  Map<String, int> allowed,
  String replacement,
) {
  final grew = <String>[
    for (final e in found.entries)
      if (e.value > (allowed[e.key] ?? 0))
        '${e.key}: ${e.value} (allowed ${allowed[e.key] ?? 0})',
  ];
  expect(
    grew,
    isEmpty,
    reason: 'New $what usage. Use $replacement instead: ${grew.join(', ')}',
  );
  final stale = <String>[
    for (final e in allowed.entries)
      if ((found[e.key] ?? 0) < e.value)
        '${e.key}: now ${found[e.key] ?? 0}, list says ${e.value}',
  ];
  expect(
    stale,
    isEmpty,
    reason:
        '$what usage shrank — lower/remove these allow-list entries so it '
        'cannot come back: ${stale.join(', ')}',
  );
}

void main() {
  test('no new AlertDialog (use showHermesDialog)', () {
    _expectShrinkOnly(
      'AlertDialog',
      _scan(RegExp(r'\bAlertDialog\s*\(')),
      _alertDialogAllowed,
      'showHermesDialog',
    );
  });

  test('no new showDialog (use showHermesDialog / showHermesSurface)', () {
    _expectShrinkOnly(
      'showDialog',
      _scan(RegExp(r'\bshowDialog\s*(?:<[^>{}()]*>)?\s*\(')),
      _showDialogAllowed,
      'showHermesDialog',
    );
  });

  test('no new DropdownButton (use HermesSelectRow + showHermesOptions)', () {
    _expectShrinkOnly(
      'DropdownButton',
      _scan(RegExp(r'\bDropdownButton(?:FormField)?\s*(?:<[^>{}()]*>)?\s*\(')),
      _dropdownButtonAllowed,
      'HermesSelectRow + showHermesOptions',
    );
  });

  test('no new PopupMenuButton (use showHermesMenu)', () {
    _expectShrinkOnly(
      'PopupMenuButton',
      _scan(RegExp(r'\bPopupMenuButton\s*(?:<[^>{}()]*>)?\s*\(')),
      _popupMenuButtonAllowed,
      'showHermesMenu',
    );
  });

  test('no new HermesPill (use HermesStatusText / HermesTag)', () {
    _expectShrinkOnly(
      'HermesPill',
      _scan(
        RegExp(r'\bHermesPill\s*\('),
        skip: const {'lib/core/widgets/hermes_pill.dart'},
      ),
      _hermesPillAllowed,
      'HermesStatusText or HermesTag',
    );
  });

  test('migrated screens stay clean', () {
    for (final path in const [
      'lib/core/screens/cron_screen.dart',
      'lib/core/screens/cron_detail_page.dart',
      'lib/core/screens/mission_bot_routine_sheet.dart',
      'lib/core/bots/ui/profile/bot_profile_screen.dart',
    ]) {
      final source = _withoutComments(File(path).readAsStringSync());
      for (final banned in const [
        'AlertDialog(',
        'showDialog',
        'DropdownButton',
        'PopupMenuButton',
        'HermesPill(',
        'showHermesFloatingSurface',
      ]) {
        expect(source, isNot(contains(banned)), reason: '$path uses $banned');
      }
    }
  });
}

const _alertDialogAllowed = <String, int>{
  'lib/core/screens/admin_integrations_screen.dart': 1,
  'lib/core/screens/agent_center_screen.dart': 2,
  'lib/core/screens/bot_create_screen.dart': 1,
  'lib/core/screens/bot_profile_settings_screen.dart': 1,
  'lib/core/screens/bridge_editor_mixin.dart': 2,
  'lib/core/screens/chat_screen.dart': 11,
  'lib/core/screens/companion/mascotas_screen.dart': 1,
  'lib/core/screens/dock_settings_screen.dart': 1,
  'lib/core/screens/extensions_center_screen.dart': 1,
  'lib/core/screens/gateway_manager_screen.dart': 1,
  'lib/core/screens/home_dashboard_screen.dart': 1,
  'lib/core/screens/instance_edit_screen.dart': 3,
  'lib/core/screens/local_instance_control_screen.dart': 3,
  'lib/core/screens/memory_draft_screen.dart': 3,
  'lib/core/screens/mission_control_screen.dart': 4,
  'lib/core/screens/models_screen.dart': 2,
  'lib/core/screens/notification_settings_screen.dart': 1,
  'lib/core/screens/ollama_models_screen.dart': 6,
  'lib/core/screens/onboarding/local_agent_setup_screen.dart': 1,
  'lib/core/screens/onboarding/local_install_screen.dart': 1,
  'lib/core/screens/permissions_screen.dart': 1,
  'lib/core/screens/profile_editor_screen.dart': 1,
  'lib/core/screens/profiles_screen.dart': 1,
  'lib/core/screens/qr_scan_screen.dart': 1,
  'lib/core/screens/recovery_center_screen.dart': 1,
  'lib/core/screens/runs_screen.dart': 2,
  'lib/core/screens/security_info_screen.dart': 1,
  'lib/core/screens/session_detail_screen.dart': 2,
  'lib/core/screens/session_list_screen.dart': 1,
  'lib/core/screens/settings_screen.dart': 5,
  'lib/core/screens/sftp_browser_screen.dart': 1,
  'lib/core/screens/skills_screen.dart': 2,
  'lib/core/screens/soul_screen.dart': 3,
  'lib/core/screens/ssh_screen.dart': 1,
  'lib/core/screens/ssh_terminal_screen.dart': 1,
  'lib/core/screens/task_center_screen.dart': 2,
  'lib/core/screens/tasks_screen.dart': 3,
  'lib/core/screens/theme_studio_screen.dart': 1,
  'lib/core/screens/themes_screen.dart': 2,
  'lib/core/widgets/action_approval.dart': 1,
  'lib/core/widgets/api_key_help.dart': 1,
  'lib/core/widgets/bot_avatar_generate_button.dart': 1,
  'lib/core/widgets/bridge_update_banner.dart': 2,
  'lib/core/widgets/diagnostic_bundle_tile.dart': 1,
  'lib/core/widgets/room_member_status.dart': 2,
  'lib/core/widgets/session_deletion_dialogs.dart': 1,
  'lib/core/widgets/ssh_host_key_dialog.dart': 1,
  'lib/core/widgets/voice_disclosure_dialog.dart': 2,
};

const _showDialogAllowed = <String, int>{
  'lib/core/screens/admin_integrations_screen.dart': 1,
  'lib/core/screens/agent_center_screen.dart': 2,
  'lib/core/screens/bot_create_screen.dart': 1,
  'lib/core/screens/bot_profile_settings_screen.dart': 1,
  'lib/core/screens/bridge_editor_mixin.dart': 2,
  'lib/core/screens/chat_screen.dart': 10,
  'lib/core/screens/companion/mascotas_screen.dart': 1,
  'lib/core/screens/dock_settings_screen.dart': 1,
  'lib/core/screens/extensions_center_screen.dart': 1,
  'lib/core/screens/gateway_manager_screen.dart': 1,
  'lib/core/screens/home_dashboard_screen.dart': 1,
  'lib/core/screens/instance_edit_screen.dart': 3,
  'lib/core/screens/local_instance_control_screen.dart': 3,
  'lib/core/screens/memory_draft_screen.dart': 3,
  'lib/core/screens/mission_control_screen.dart': 4,
  'lib/core/screens/models_screen.dart': 2,
  'lib/core/screens/notification_settings_screen.dart': 1,
  'lib/core/screens/ollama_models_screen.dart': 6,
  'lib/core/screens/onboarding/local_agent_setup_screen.dart': 1,
  'lib/core/screens/onboarding/local_install_screen.dart': 1,
  'lib/core/screens/permissions_screen.dart': 1,
  'lib/core/screens/profile_editor_screen.dart': 1,
  'lib/core/screens/profiles_screen.dart': 1,
  'lib/core/screens/qr_scan_screen.dart': 1,
  'lib/core/screens/recovery_center_screen.dart': 1,
  'lib/core/screens/runs_screen.dart': 2,
  'lib/core/screens/security_info_screen.dart': 1,
  'lib/core/screens/session_detail_screen.dart': 2,
  'lib/core/screens/session_list_screen.dart': 1,
  'lib/core/screens/settings_screen.dart': 5,
  'lib/core/screens/sftp_browser_screen.dart': 1,
  'lib/core/screens/skills_screen.dart': 2,
  'lib/core/screens/soul_screen.dart': 3,
  'lib/core/screens/ssh_screen.dart': 1,
  'lib/core/screens/ssh_terminal_screen.dart': 1,
  'lib/core/screens/task_center_screen.dart': 2,
  'lib/core/screens/tasks_screen.dart': 3,
  'lib/core/screens/theme_studio_screen.dart': 1,
  'lib/core/screens/themes_screen.dart': 2,
  'lib/core/widgets/action_approval.dart': 1,
  'lib/core/widgets/api_key_help.dart': 1,
  'lib/core/widgets/bot_avatar_generate_button.dart': 1,
  'lib/core/widgets/bridge_update_banner.dart': 2,
  'lib/core/widgets/diagnostic_bundle_tile.dart': 1,
  'lib/core/widgets/room_member_status.dart': 2,
  'lib/core/widgets/session_deletion_dialogs.dart': 1,
  'lib/core/widgets/ssh_host_key_dialog.dart': 1,
  'lib/core/widgets/voice_disclosure_dialog.dart': 2,
};

const _dropdownButtonAllowed = <String, int>{
  'lib/core/screens/bot_create_screen.dart': 1,
  'lib/core/screens/instance_edit_screen.dart': 1,
  'lib/core/screens/mission_control_screen.dart': 1,
  'lib/core/screens/onboarding/local_install_screen.dart': 1,
  'lib/core/screens/security_info_screen.dart': 1,
  'lib/core/screens/settings_screen.dart': 1,
  'lib/core/screens/theme_studio_screen.dart': 1,
  'lib/core/screens/voice_settings_screen.dart': 2,
  'lib/core/widgets/mcp_provisioning_surface.dart': 1,
  'lib/core/widgets/server_voice_control_surface.dart': 2,
  'lib/core/widgets/webhook_admin_surfaces.dart': 1,
};

const _popupMenuButtonAllowed = <String, int>{
  'lib/core/screens/admin_integrations_screen.dart': 1,
  'lib/core/screens/chat_screen.dart': 1,
  'lib/core/screens/extensions_center_screen.dart': 2,
  'lib/core/screens/gateway_manager_screen.dart': 1,
  'lib/core/screens/mission_control_screen.dart': 2,
  'lib/core/screens/session_list_screen.dart': 1,
  'lib/core/screens/sftp_browser_screen.dart': 1,
  'lib/core/screens/tasks_screen.dart': 1,
  'lib/core/screens/themes_screen.dart': 1,
};

const _hermesPillAllowed = <String, int>{
  'lib/core/screens/litert_store_screen.dart': 4,
  'lib/core/screens/local_instance_control_screen.dart': 1,
  'lib/core/screens/ollama_models_screen.dart': 1,
  'lib/core/screens/permissions_screen.dart': 3,
  'lib/core/screens/runs_screen.dart': 4,
  'lib/core/screens/session_detail_screen.dart': 1,
  'lib/core/screens/task_center_screen.dart': 1,
  'lib/core/widgets/chat_event_cards.dart': 2,
};
