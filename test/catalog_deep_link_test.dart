import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_repository.dart';
import 'package:hermes_android/core/capabilities/catalog_deep_link.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardHttpException;
import 'package:hermes_android/core/services/pairing_link_delivery_gate.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart'
    show TuiGatewayRpcError, TuiGatewayRpcFailureKind;

import 'capabilities/capabilities_fakes.dart';

CatalogDeepLinkAction? _resolve(String link) =>
    resolveCatalogDeepLink(Uri.parse(link));

void main() {
  group('resolveCatalogDeepLink (ported from Desktop deeplink-routes)', () {
    test('a catalog name opens the catalog install', () {
      expect(
        _resolve('hermes://plugin/install?catalog=weather'),
        isA<PluginCatalogInstallLink>().having(
          (a) => a.name,
          'name',
          'weather',
        ),
      );
      expect(
        _resolve('hermes://plugin/install?catalog=Foo.bar_1-x'),
        isA<PluginCatalogInstallLink>(),
      );
    });

    test('a bad catalog name is an error, never a git install', () {
      for (final link in [
        'hermes://plugin/install?catalog=bad%20name',
        'hermes://plugin/install?catalog=',
        'hermes://plugin/install?catalog=-lead',
        'hermes://plugin/install?catalog=a/b',
        'hermes://plugin/install?catalog=%20weather',
        'hermes://plugin/install?catalog=${'a' * 65}',
      ]) {
        expect(
          _resolve(link),
          isA<CatalogLinkNotice>().having(
            (a) => a.kind,
            'kind',
            CatalogLinkNoticeKind.invalidName,
          ),
          reason: link,
        );
      }
    });

    test('catalog claims the link even when repo rides along', () {
      expect(
        _resolve(
          'hermes://plugin/install?catalog=weather&repo=owner/repo&force=1',
        ),
        isA<PluginCatalogInstallLink>(),
      );
      expect(
        _resolve('hermes://plugin/install?catalog=&repo=owner/repo'),
        isA<CatalogLinkNotice>().having(
          (a) => a.kind,
          'kind',
          CatalogLinkNoticeKind.invalidName,
        ),
      );
    });

    test('repo and agent/desktop plugin links only explain, never install', () {
      for (final link in const [
        'hermes://plugin/install?repo=owner/repo',
        'hermes://plugin/install?repo=owner/repo&enable=1&force=1',
        'hermes://plugin-agent/install?repo=owner/repo',
        'hermes://plugin-desktop/install?name=x',
      ]) {
        expect(
          _resolve(link),
          isA<CatalogLinkNotice>().having(
            (a) => a.kind,
            'kind',
            CatalogLinkNoticeKind.gitRepository,
          ),
          reason: link,
        );
      }
    });

    test('a skill identifier must equal its trim', () {
      expect(
        _resolve('hermes://skill/install?identifier=official/devops/docker'),
        isA<SkillInstallLink>().having(
          (a) => a.identifier,
          'identifier',
          'official/devops/docker',
        ),
      );
      expect(_resolve('hermes://skill/install?identifier=a%2Fb'), isNotNull);
      for (final link in const [
        'hermes://skill/install?identifier=%20a/b',
        'hermes://skill/install?identifier=a/b%20',
        'hermes://skill/install?identifier=',
        'hermes://skill/install',
        'hermes://skill/other?identifier=a/b',
      ]) {
        expect(_resolve(link), isNull, reason: link);
      }
    });

    test('links that are not catalog links are left to their owners', () {
      for (final link in const [
        'hermes://pair?host=h&port=1&token=t',
        'https://example.test/plugin/install?catalog=weather',
        'http://skill/install?identifier=a/b',
        'other://plugin/install?catalog=weather',
        'hermes://plugin/other?catalog=weather',
        'hermes://plugin/install',
      ]) {
        expect(_resolve(link), isNull, reason: link);
      }
    });
  });

  group('CatalogDeepLinkInbox', () {
    late DateTime now;
    late CatalogDeepLinkInbox inbox;
    final link = Uri.parse('hermes://plugin/install?catalog=weather');

    setUp(() {
      now = DateTime.utc(2026, 10, 4, 12);
      inbox = CatalogDeepLinkInbox(
        gate: PairingLinkDeliveryGate(now: () => now),
      );
    });

    CatalogDeepLinkAction? take({
      bool locked = false,
      bool onboarding = false,
      bool connected = true,
    }) => inbox.take(
      locked: locked,
      onboarding: onboarding,
      connected: connected,
    );

    test('offer claims catalog links only', () {
      expect(inbox.offer(link), isTrue);
      expect(inbox.offer(Uri.parse('hermes://pair?host=h')), isFalse);
    });

    test('a link delivered twice opens once', () {
      expect(inbox.offer(link), isTrue);
      expect(inbox.offer(link), isTrue); // claimed, but not queued again
      expect(take(), isA<PluginCatalogInstallLink>());
      expect(take(), isNull);
    });

    test('held while locked, onboarding or without a server', () {
      inbox.offer(link);
      expect(take(locked: true), isNull);
      expect(take(onboarding: true), isNull);
      expect(take(connected: false), isNull);
      expect(inbox.hasPending, isTrue);
      expect(take(), isA<PluginCatalogInstallLink>());
      expect(inbox.hasPending, isFalse);
    });

    test('the same link delivered again while held is not queued twice', () {
      inbox.offer(link);
      now = now.add(const Duration(seconds: 10));
      inbox.offer(link);
      expect(take(), isNotNull);
      expect(take(), isNull);
    });

    test('distinct links held while locked all open, in order', () {
      inbox.offer(link);
      inbox.offer(Uri.parse('hermes://skill/install?identifier=a/b'));
      expect(take(locked: true), isNull);
      expect(take(), isA<PluginCatalogInstallLink>());
      expect(take(), isA<SkillInstallLink>());
      expect(take(), isNull);
    });
  });

  group('CatalogDestination', () {
    test('a changed connection or profile is not the same destination', () {
      const base = CatalogDestination(connectionId: 'c1', profile: 'work');
      expect(
        base.sameAs(
          const CatalogDestination(connectionId: 'c1', profile: 'work'),
        ),
        isTrue,
      );
      expect(
        base.sameAs(
          const CatalogDestination(connectionId: 'c2', profile: 'work'),
        ),
        isFalse,
      );
      expect(
        base.sameAs(
          const CatalogDestination(connectionId: 'c1', profile: 'home'),
        ),
        isFalse,
      );
      expect(
        const CatalogDestination(connectionId: 'c1', profile: '').sameAs(
          const CatalogDestination(connectionId: 'c1', profile: 'default'),
        ),
        isTrue,
      );
    });
  });

  group('resolveCatalogLinkTarget', () {
    ScriptedRest server({bool removed = false}) =>
        ScriptedRest()
          ..gets['dashboard/plugins/catalog'] = {
            'entries': [
              {
                'name': 'weather',
                'tier': 'community',
                'repo': 'https://git.example.test/labs/weather',
                'installed': false,
              },
              {'name': 'installed-one', 'installed': true},
            ],
            if (removed)
              'removed': [
                {'name': 'weather', 'reason': 'Abandoned'},
              ],
          };

    Future<CatalogLinkTarget> resolve(
      ScriptedRest rest,
      String name, {
      CapabilitiesRpc? rpc,
    }) => resolveCatalogLinkTarget(
      CapabilitiesRepository(
        rest: rest,
        // Installed state of the named profile: nothing installed by default.
        rpc: rpc ?? (method, params) async => {'plugins': <Object>[]},
        profile: 'work',
      ),
      PluginCatalogInstallLink(name),
    );

    test('a known entry opens its detail with the server catalog', () async {
      final rest = server();
      final target = await resolve(rest, 'weather');
      expect(target, isA<CatalogLinkShow>());
      expect((target as CatalogLinkShow).item.installId, 'weather');
      // Only the connected server's catalog is read: one GET, no mutation.
      expect(rest.calls, ['GET dashboard/plugins/catalog']);
    });

    test('unknown names are a hard unknown, never a guess', () async {
      final target = await resolve(server(), 'weathr');
      expect(
        target,
        isA<CatalogLinkLeave>().having(
          (t) => t.reason,
          'reason',
          CatalogLinkLeaveReason.unknown,
        ),
      );
    });

    test(
      'a removed entry still opens, with the reason and no install',
      () async {
        final target = await resolve(server(removed: true), 'weather');
        expect(
          (target as CatalogLinkShow).item.disclosure.removedReason,
          'Abandoned',
        );
      },
    );

    test('installed without an update is already installed', () async {
      final target = await resolve(
        server(),
        'installed-one',
        rpc: (method, params) async => {
          'plugins': [
            {'name': 'installed-one', 'catalog_name': 'installed-one'},
          ],
        },
      );
      expect(
        target,
        isA<CatalogLinkLeave>().having(
          (t) => t.reason,
          'reason',
          CatalogLinkLeaveReason.alreadyInstalled,
        ),
      );
    });

    test(
      'installed state follows the hub profile, not the launch one',
      () async {
        // The REST catalog says installed (launch profile); `work` has nothing.
        final target = await resolve(
          server(),
          'installed-one',
          rpc: (method, params) async => {'plugins': <Object>[]},
        );
        expect(target, isA<CatalogLinkShow>());
      },
    );

    test('a named profile with no installed state is unavailable', () async {
      // REST says installed (launch profile); `work` could not be read.
      final target = await resolve(
        server(),
        'installed-one',
        rpc: (method, params) async => throw const TuiGatewayRpcError(
          'plugins.manage',
          'timed out',
          failureKind: TuiGatewayRpcFailureKind.timeout,
        ),
      );
      expect(
        target,
        isA<CatalogLinkLeave>().having(
          (t) => t.reason,
          'reason',
          CatalogLinkLeaveReason.unavailable,
        ),
      );
    });

    test('a named profile whose list is unsupported is unavailable', () async {
      final target = await resolve(
        server(),
        'installed-one',
        rpc: (method, params) async =>
            throw const TuiGatewayRpcError('plugins.manage', 'x', code: -32601),
      );
      expect(
        target,
        isA<CatalogLinkLeave>().having(
          (t) => t.reason,
          'reason',
          CatalogLinkLeaveReason.unavailable,
        ),
      );
    });

    test('an unreadable catalog is unavailable', () async {
      final rest = ScriptedRest()
        ..gets['dashboard/plugins/catalog'] = const DashboardHttpException(500);
      expect(
        await resolve(rest, 'weather'),
        isA<CatalogLinkLeave>().having(
          (t) => t.reason,
          'reason',
          CatalogLinkLeaveReason.unavailable,
        ),
      );
    });
  });

  group('resolveSkillLinkTarget', () {
    ScriptedRest hub() => ScriptedRest()
      ..gets['skills/hub/search'] = {
        'results': [
          {'name': 'docker', 'identifier': 'official/docker', 'source': 'x'},
          {'name': 'other', 'identifier': 'acme/docker-other'},
        ],
        'installed': {'official/installed': true},
      };

    Future<CatalogLinkTarget> resolve(ScriptedRest rest, String id) =>
        resolveSkillLinkTarget(
          CapabilitiesRepository(rest: rest),
          SkillInstallLink(id),
        );

    CatalogLinkLeaveReason? reasonOf(CatalogLinkTarget t) =>
        t is CatalogLinkLeave ? t.reason : null;

    test('an identifier the server lists opens its detail', () async {
      final target = await resolve(hub(), 'official/docker');
      expect(target, isA<CatalogLinkShow>());
      expect((target as CatalogLinkShow).item.installId, 'official/docker');
    });

    test('an identifier the server does not list is unknown', () async {
      expect(
        reasonOf(await resolve(hub(), 'official/nothing')),
        CatalogLinkLeaveReason.unknown,
      );
    });

    test('a server without the hub routes is unavailable', () async {
      expect(
        reasonOf(await resolve(ScriptedRest(), 'official/docker')),
        CatalogLinkLeaveReason.unavailable,
      );
    });
  });
}
