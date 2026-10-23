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
  'test/active_chat_transcript_pagination_test.dart',
  'test/chat_screen_profile_dashboard_access_test.dart',
  'test/e2e_real_gateway/support/real_gateway.dart',
  'test/home_status_requests_test.dart',
  'test/lc1215_long_session_projection_test.dart',
  // Kept until C13 on purpose: its ~210 KB pages would decode off the main
  // isolate through the Dashboard, and the reads it measures happen inside
  // fake-time pumps, where that decode never completes. C13 ports it with a
  // test-only inline-decode hook next to `debugJsonDecodePathObserver`.
  'test/passive_transcript_bandwidth_test.dart',
  'test/session_list_spec046_widget_test.dart',
  'test/u6_gateway_retirement/ids_and_constructors_test.dart',
  'test/u6_gateway_retirement/test_api_client_harness_test.dart',
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
