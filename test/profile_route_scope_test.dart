import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/skills_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('skills route override wins without mutating the active profile', () {
    expect(
      resolveSkillsRouteProfile(
        profileOverride: ' research ',
        activeProfile: 'default',
      ),
      'research',
    );
    expect(
      resolveSkillsRouteProfile(
        profileOverride: null,
        activeProfile: 'default',
      ),
      'default',
    );
  });

  test('skills load waits for profile dependencies before first request', () {
    expect(
      skillsInitialLoadProfile(
        dependenciesResolved: false,
        profileOverride: 'research',
        activeProfile: 'default',
      ),
      isNull,
    );
    expect(
      skillsInitialLoadProfile(
        dependenciesResolved: true,
        profileOverride: 'research',
        activeProfile: 'default',
      ),
      'research',
    );
  });

  test('secondary skills scope blocks mutations without blocking default', () {
    expect(skillsProfileMutationsBlocked('research'), isTrue);
    expect(skillsProfileMutationsBlocked('default'), isFalse);
    expect(skillsProfileMutationsBlocked(''), isFalse);
  });

  test('memory metadata request scopes the selected profile', () async {
    Uri? requested;
    final client = DashboardClient(
      host: 'hermes.local',
      manualToken: 'token',
      httpClientOverride: MockClient((request) async {
        requested = request.url;
        return http.Response(
          '{"active":"builtin","providers":[],"builtin_files":{}}',
          200,
        );
      }),
    );
    addTearDown(client.close);

    await client.getMemoryInfo(profile: 'research');

    expect(requested?.path, '/api/memory');
    expect(requested?.queryParameters['profile'], 'research');
  });
}
