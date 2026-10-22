import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Ratchet of PLAN-RETIRO-RAMAS-SIN-DASHBOARD (C1): the test files that still
/// build an `ApiClient` with no Dashboard attached, directly or as the super
/// constructor of a subclass. Production never does (see
/// `ids_and_constructors_test.dart`), so these files are the only callers left
/// of the client's Gateway branches. Each migration batch builds its clients
/// with `testApiClient` / `testDashboardClient` (`test/support/
/// test_api_client.dart`) and removes its lines here; the branches are
/// deleted once the list is empty. A file counts while its constructions and
/// subclasses outnumber the Dashboards it attaches (a `null` one is none).
const _stillWithoutDashboard = {
  'test/active_chat_profile_transcript_fallback_test.dart',
  'test/active_chat_resume_snapshot_test.dart',
  'test/active_chat_transcript_pagination_test.dart',
  'test/chat_screen_profile_dashboard_access_test.dart',
  'test/chat_screen_test.dart',
  'test/connection_manager_test.dart',
  'test/core_read_contract_test.dart',
  'test/cs1215_home_cold_start_recents_test.dart',
  'test/dashboard_redirect_origin_test.dart',
  'test/drawer_premium_layout_test.dart',
  'test/drawer_profile_faces_test.dart',
  'test/e2e_real_gateway/support/real_gateway.dart',
  'test/gateway_profile_rest_routing_test.dart',
  'test/hf1_chat_duplicate_missing_test.dart',
  'test/home_app_lock_draft_admission_probe_test.dart',
  'test/home_status_requests_test.dart',
  'test/kbc1215_covered_route_inset_test.dart',
  'test/lc1215_long_session_projection_test.dart',
  'test/n10_hidden_list_quiet_test.dart',
  'test/n10g_rehydrate_cost_test.dart',
  'test/n10i_connect_timeout_test.dart',
  'test/passive_transcript_bandwidth_test.dart',
  'test/pinned_prompt_jump_test.dart',
  'test/profile_named_session_read_test.dart',
  'test/profile_switch_home_test.dart',
  'test/profile_switch_lists_test.dart',
  'test/profile_switcher_test.dart',
  'test/px6/px6_expired_session_screens_test.dart',
  'test/session_authority_adversarial_test.dart',
  'test/session_deletion_surface_test.dart',
  'test/session_deletion_test.dart',
  'test/session_export_test.dart',
  'test/session_list_extras_test.dart',
  'test/session_list_hidden_view_test.dart',
  'test/session_list_merge_test.dart',
  'test/session_list_redesign_test.dart',
  'test/session_list_spec046_widget_test.dart',
  'test/session_list_state_sync_test.dart',
  'test/session_onestore_branches_test.dart',
  'test/session_onestore_delete_test.dart',
  'test/session_onestore_new_chat_test.dart',
  'test/session_onestore_preview_test.dart',
  'test/session_recovery_cleanup_test.dart',
  'test/session_repository_test.dart',
  'test/settings_history_cleanup_test.dart',
  'test/tablet_chats_list_detail_test.dart',
  'test/tablet_single_active_chat_test.dart',
  'test/u6_gateway_retirement/ids_and_constructors_test.dart',
  'test/u6_gateway_retirement/test_api_client_harness_test.dart',
  'test/voice/conversation/local_voice_conversation_controller_test.dart',
  'test/widget_test.dart',
};

final _constructions = RegExp(r'\bApiClient(\.new\b|\()');
final _subclasses = RegExp(r'\bextends ApiClient\b');
final _attachedDashboards = RegExp(r'profileDashboard\s*:(?!\s*null\b)');

Set<String> _filesWithoutDashboard() {
  final found = <String>{};
  for (final entity in Directory('test').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final source = entity.readAsStringSync();
    final unattached =
        _constructions.allMatches(source).length +
        _subclasses.allMatches(source).length -
        _attachedDashboards.allMatches(source).length;
    if (unattached > 0) found.add(entity.path.replaceAll(r'\', '/'));
  }
  return found;
}

void main() {
  test('no new test builds an ApiClient without its Dashboard', () {
    expect(
      _filesWithoutDashboard().difference(_stillWithoutDashboard),
      isEmpty,
      reason:
          'build it with testApiClient (test/support/test_api_client.dart)',
    );
  });

  test('a migrated file leaves the ratchet', () {
    expect(
      _stillWithoutDashboard.difference(_filesWithoutDashboard()),
      isEmpty,
      reason: 'it already attaches its Dashboard: remove it from the list',
    );
  });
}
