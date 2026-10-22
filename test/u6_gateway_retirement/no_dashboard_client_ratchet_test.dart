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
  'test/active_chat_auto_continue_banner_test.dart',
  'test/active_chat_background_task_test.dart',
  'test/active_chat_branch_test.dart',
  'test/active_chat_connection_request_test.dart',
  'test/active_chat_interactive_prompt_test.dart',
  'test/active_chat_profile_transcript_fallback_test.dart',
  'test/active_chat_public_messages_cache_test.dart',
  'test/active_chat_queue_screen_handoff_test.dart',
  'test/active_chat_reactions_test.dart',
  'test/active_chat_reopen_cached_transcript_test.dart',
  'test/active_chat_resume_order_test.dart',
  'test/active_chat_resume_snapshot_test.dart',
  'test/active_chat_rewrite_degrade_test.dart',
  'test/active_chat_service_test.dart',
  'test/active_chat_session_config_test.dart',
  'test/active_chat_stop_escalation_test.dart',
  'test/active_chat_stop_ownership_test.dart',
  'test/active_chat_stop_recovery_test.dart',
  'test/active_chat_stop_settle_test.dart',
  'test/active_chat_streaming_projection_benchmark_test.dart',
  'test/active_chat_streaming_projection_parity_test.dart',
  'test/active_chat_subagent_activity_test.dart',
  'test/active_chat_subagent_watch_lease_test.dart',
  'test/active_chat_transcript_pagination_test.dart',
  'test/active_chat_turn_side_test.dart',
  'test/activity_freshness_regression_test.dart',
  'test/activity_widget_regression_test.dart',
  'test/bot_mention_transport_test.dart',
  'test/busy_live_correction_1216_test.dart',
  'test/c3c/c3c_home_arrival_test.dart',
  'test/chat_composer_recall_test.dart',
  'test/chat_connection_recovery_state_test.dart',
  'test/chat_content_entry_test.dart',
  'test/chat_draft_store_test.dart',
  'test/chat_find_bar_test.dart',
  'test/chat_integration_test.dart',
  'test/chat_open_clears_notification_test.dart',
  'test/chat_quick_react_long_press_test.dart',
  'test/chat_replying_1215_test.dart',
  'test/chat_screen_cron_run_write_gate_test.dart',
  'test/chat_screen_profile_dashboard_access_test.dart',
  'test/chat_screen_reopen_cached_transcript_test.dart',
  'test/chat_screen_test.dart',
  'test/chat_scroll_1215_test.dart',
  'test/chat_scroll_reversal_stress_test.dart',
  'test/chat_send_durable_route_test.dart',
  'test/chat_without_rest/branch_test.dart',
  'test/co1215_warm_chat_gateway_test.dart',
  'test/compression_acquisition_wire_test.dart',
  'test/compression_authority_wire_test.dart',
  'test/connection_manager_test.dart',
  'test/console_desktop_transcript_reconcile_test.dart',
  'test/core_read_contract_test.dart',
  'test/cq1215_clarify_restart_test.dart',
  'test/cr1215_clarify_resume_test.dart',
  'test/cs1215_cold_start_route_test.dart',
  'test/cs1215_cold_start_store_test.dart',
  'test/cs1215_home_cold_start_recents_test.dart',
  'test/dashboard_redirect_origin_test.dart',
  'test/desktop_disconnect_recovery_test.dart',
  'test/desktop_interim_event_test.dart',
  'test/dock_single_test.dart',
  'test/dock_transition_rebuild_test.dart',
  'test/drawer_premium_layout_test.dart',
  'test/drawer_profile_faces_test.dart',
  'test/e2e_real_gateway/support/real_gateway.dart',
  'test/first_load_new_since_test.dart',
  'test/first_load_page_size_test.dart',
  'test/gateway_profile_rest_routing_test.dart',
  'test/gateway_wire_contract_active_chat_test.dart',
  'test/guided_tour_screens_test.dart',
  'test/hallo/season_drawer_test.dart',
  'test/hallo/season_home_test.dart',
  'test/hf1_chat_duplicate_missing_test.dart',
  'test/home/home_board_render_test.dart',
  'test/home/home_board_screen_test.dart',
  'test/home_app_lock_draft_admission_probe_test.dart',
  'test/home_dashboard_auth_status_test.dart',
  'test/home_dashboard_dispose_stale_test.dart',
  'test/home_status_requests_test.dart',
  'test/instance_status_word_l10n_test.dart',
  'test/kb1215_keyboard_inset_rebuild_test.dart',
  'test/kbc1215_covered_route_inset_test.dart',
  'test/kbf1215_focus_frames_test.dart',
  'test/kbp9494_long_chat_keyboard_test.dart',
  'test/lc1215_long_session_projection_test.dart',
  'test/legacy/b_gateway_only_recovery_test.dart',
  'test/live_viewer_attach_approval_test.dart',
  'test/local_pretransport_rejection_test.dart',
  'test/lr1215_live_reasoning_test.dart',
  'test/lt1215_late_cut_answer_test.dart',
  'test/main_chat_render_baseline_test.dart',
  'test/mk1215_model_options_sessionless_test.dart',
  'test/model_catalog_desktop_budget_test.dart',
  'test/n10_hidden_list_quiet_test.dart',
  'test/n10_rehydrate_not_transport_test.dart',
  'test/n10g_rehydrate_cost_test.dart',
  'test/n10i_connect_timeout_test.dart',
  'test/n10i_rest_read_flight_test.dart',
  'test/net1_connection_status_test.dart',
  'test/net1_one_socket_test.dart',
  'test/net1_recovery_reads_test.dart',
  'test/net1b_flap_test.dart',
  'test/net_meter_test.dart',
  'test/network_resilience_test.dart',
  'test/notifications/live_turn_chat_hook_test.dart',
  'test/ns1215_open_straight_into_app_test.dart',
  'test/onboarding_design_shots_test.dart',
  'test/os1215_one_socket_test.dart',
  'test/outbox_restart_fifo_guard_test.dart',
  'test/passive_transcript_bandwidth_test.dart',
  'test/pinned_prompt_jump_test.dart',
  'test/pm1215_scroll_perf_test.dart',
  'test/profile_named_session_read_test.dart',
  'test/profile_switch_home_test.dart',
  'test/profile_switch_lists_test.dart',
  'test/profile_switcher_test.dart',
  'test/ps1215_pill_capture_test.dart',
  'test/ps1215_pill_sync_test.dart',
  'test/px6/px6_expired_session_screens_test.dart',
  'test/queue_uncertain_abandon_test.dart',
  'test/re1215_compaction_prompt_reinsert_test.dart',
  'test/re1215_reentry_test.dart',
  'test/re1215_terminal_tail_read_test.dart',
  'test/rg1215_capture_test.dart',
  'test/roster_known_filter_home_test.dart',
  'test/rowerr/chat_row_boundary_test.dart',
  'test/session_authority_adversarial_test.dart',
  'test/session_deletion_surface_test.dart',
  'test/session_deletion_test.dart',
  'test/session_detail_artifacts_test.dart',
  'test/session_detail_shared_store_test.dart',
  'test/session_export_test.dart',
  'test/session_fence_writes_test.dart',
  'test/session_identity_peer_test.dart',
  'test/session_index_onestore_test.dart',
  'test/session_list_extras_test.dart',
  'test/session_list_hidden_view_test.dart',
  'test/session_list_merge_test.dart',
  'test/session_list_redesign_test.dart',
  'test/session_list_spec046_widget_test.dart',
  'test/session_list_state_sync_test.dart',
  'test/session_list_stop_action_test.dart',
  'test/session_onestore_branches_test.dart',
  'test/session_onestore_delete_test.dart',
  'test/session_onestore_new_chat_test.dart',
  'test/session_onestore_preview_test.dart',
  'test/session_recovery_cleanup_test.dart',
  'test/session_repository_test.dart',
  'test/session_usage_metrics_test.dart',
  'test/settings_history_cleanup_test.dart',
  'test/slash_commands_test.dart',
  'test/snapshot_privacy_boundary_test.dart',
  'test/spec054_accessibility_controls_test.dart',
  'test/spec060_bidirectional_live_integration_test.dart',
  'test/ss1215_open_running_chat_test.dart',
  'test/ss1215_status_sync_test.dart',
  'test/streaming_projection_identity_test.dart',
  'test/subagent_live_watch_chat_test.dart',
  'test/subagent_process_adaptive_refresh_test.dart',
  'test/support/a11y_main_screen_harness.dart',
  'test/t102_subagent_reconnect_test.dart',
  'test/tablet_chats_list_detail_test.dart',
  'test/tablet_single_active_chat_test.dart',
  'test/terminal_authority_test.dart',
  'test/tk1215_task_list_lifecycle_test.dart',
  'test/transcript_display_privacy_test.dart',
  'test/transcript_publication_receipt_test.dart',
  'test/transport_retained_activity_test.dart',
  'test/tui_gateway_server_requests_test.dart',
  'test/turn_error_surface_wire_test.dart',
  'test/turn_idempotency_contract_test.dart',
  'test/turn_recovery_test.dart',
  'test/u6_gateway_retirement/ids_and_constructors_test.dart',
  'test/u6_gateway_retirement/test_api_client_harness_test.dart',
  'test/voice/conversation/local_voice_conversation_controller_test.dart',
  'test/voice/conversation/local_voice_conversation_fence_test.dart',
  'test/voice/conversation/local_voice_conversation_p0_test.dart',
  'test/voice/voice_lifecycle_probe_test.dart',
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
