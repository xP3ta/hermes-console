import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/cron_job.dart';
import 'package:hermes_android/core/services/profile_chat_mode.dart';

import 'support/fake_dashboard_sessions.dart';
import 'support/test_api_client.dart';

/// Hermes stores profile ids lowercase and normalizes what a client sends
/// before it validates it (`hermes_cli/profiles.py` `normalize_profile_name`:
/// `Pi` is `pi`, `Default` is the default profile). The client puts that same
/// id on the wire instead of refusing a display-cased name.
void main() {
  group('validateCronProfile', () {
    test('lowercases a named profile like the server does', () {
      expect(validateCronProfile('Pi'), 'pi');
      expect(validateCronProfile(' Social-Writer '), 'social-writer');
      expect(validateCronProfile('OPS_2'), 'ops_2');
    });

    test('any casing of default is the default profile', () {
      for (final value in ['default', 'Default', ' DEFAULT ', '', '  ']) {
        expect(validateCronProfile(value), isNull, reason: value);
      }
      expect(validateCronProfile(null), isNull);
    });

    test('still refuses what is not a profile id once lowercased', () {
      for (final invalid in const [
        '../Other',
        'Team Alpha',
        'a.b',
        'Pí',
        '-lead',
        'a/b',
      ]) {
        expect(
          () => validateCronProfile(invalid),
          throwsArgumentError,
          reason: invalid,
        );
      }
    });

    test('the creation form keeps its strict lowercase grammar', () {
      expect(isValidProfileName('pi'), isTrue);
      expect(isValidProfileName('Pi'), isFalse);
    });
  });

  test('a display-cased named profile reads its own store', () async {
    final fake = FakeDashboardSessions(profiles: {'pi'})
      ..putSession({
        'id': 's',
        'title': 'Pi chat',
        'started_at': 1,
      }, profile: 'pi')
      ..putMessages('s', [
        {'id': 1, 'role': 'user', 'content': 'hola'},
      ], profile: 'pi');
    final client = testApiClient(httpClient: fake.client());
    addTearDown(client.close);

    final page = await client.getMessagesPage('s', profile: 'Pi');
    final rows = await client.getSessions(profile: 'Pi');
    final row = await client.getSession('s', profile: 'Pi');

    expect(page.messages.single['content'], 'hola');
    expect(rows.single.profile, 'pi');
    expect(row.title, 'Pi chat');
    expect(
      fake.requests.map((r) => r.url.queryParameters['profile']),
      everyElement('pi'),
    );
    expect(fake.gatewayShaped, isEmpty);
  });
}
