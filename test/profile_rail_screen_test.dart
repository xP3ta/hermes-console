import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/services/session_repository.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/profile_face.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/core/widgets/workspace/profile_rail_chats.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_api_client.dart';

// The agent rail of the Chats screen on a wide window (a tablet: every
// profile but the active one had a bare face and no count, «hay perfiles con
// chats y no salen»). A fake roster of four profiles and a Dashboard that
// answers each profile's own sessions: every face is the roster's profile
// (its own face metadata, its own name), every profile the roster says has
// chats gets its count, and the reads are few, bounded and kept.

const _connectionId = 'conn-profile-rail';

Map<String, dynamic> _row(
  String id,
  String title,
  int lastActive, {
  String? profile,
  String source = 'mobile',
  bool archived = false,
  String? parent,
}) => {
  'id': id,
  '_lineage_root_id': id,
  'title': title,
  'preview': '',
  'model': 'model-a',
  'source': source,
  'message_count': 2,
  'is_active': false,
  'started_at': lastActive - 30,
  'ended_at': lastActive - 1,
  'last_active': lastActive,
  'archived': archived,
  'parent_session_id': ?parent,
  if (parent != null) 'is_internal_child': true,
  'profile': ?profile,
};

/// Rows of a page the list never shows as chats of their own: a subagent
/// child, a cron run, an archived chat, a kanban worker and an auxiliary
/// session of the app. The server's `total` may count them (and more it
/// never sends, such as rows hidden on the server).
List<Map<String, dynamic>> _noise(String prefix, int now, {String? profile}) =>
    [
      _row(
        '$prefix-child',
        'Subagente',
        now - 310,
        profile: profile,
        parent: '$prefix-1',
      ),
      _row(
        '$prefix-cron',
        'Informe diario',
        now - 320,
        profile: profile,
        source: 'cron',
      ),
      _row(
        '$prefix-old',
        'Archivada',
        now - 330,
        profile: profile,
        archived: true,
      ),
      _row(
        '$prefix-kanban',
        'Tablero',
        now - 340,
        profile: profile,
        source: 'kanban',
      ),
      _row('mob-aux-$prefix', 'Título auxiliar', now - 350, profile: profile),
    ];

SavedConnection _connection() => SavedConnection(
  id: _connectionId,
  label: 'Tablet QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'k',
  dashboardUrl: 'http://127.0.0.1:9119',
  kind: InstanceKind.vps,
);

AgentProfileSessionSummary _hint(String id, int at) =>
    AgentProfileSessionSummary(id: id, lastActive: at.toDouble());

/// The roster as a real server reports it, shortened: the main profile,
/// two with chats (one titled «Forja» with a boxy face), one never used.
List<AgentProfile> _roster(int now) => [
  AgentProfile(
    name: 'default',
    isDefault: true,
    displayName: 'xPeta',
    lastSession: _hint('s-1', now - 60),
  ),
  AgentProfile(
    name: 'console-builder',
    botModeUiMeta: const {'title': 'Forja', 'shape': 'boxy'},
    lastSession: _hint('cb-1', now - 300),
  ),
  AgentProfile(
    name: 'pi',
    botModeUiMeta: const {'shape': 'round'},
    lastSession: _hint('pi-1', now - 900),
  ),
  const AgentProfile(name: 'studio-qa', botModeUiMeta: {'shape': 'sun'}),
];

class _ChatProbe extends StatelessWidget {
  final Session session;
  const _ChatProbe(this.session);
  @override
  Widget build(BuildContext context) => Scaffold(
    key: ValueKey('chat-probe-${session.id}'),
    body: Text('chat ${session.id}'),
  );
}

/// The Dashboard: each profile's own rows; [failProfiles] answer 500.
class _Dashboard {
  _Dashboard(this.now);
  final int now;
  final profileReads = <String>[];
  bool failProfiles = false;

  /// While set, the reads of [holdProfile] wait for it.
  Completer<void>? hold;
  String? holdProfile;

  Future<http.Response> handle(http.Request request) async {
    if (request.method != 'GET' || request.url.path != '/api/sessions') {
      return http.Response('{}', 404);
    }
    final profile = request.url.queryParameters['profile'];
    List<Map<String, dynamic>> rows;
    int total;
    switch (profile) {
      case null:
        // The active profile's list, through the same filters.
        rows = [
          _row('s-1', 'Firma del keystore en CI', now - 60),
          _row('s-2', 'Notas de la release', now - 120),
          ..._noise('s', now),
        ];
        total = 9;
      default:
        profileReads.add(profile);
        if (hold != null && profile == holdProfile) await hold!.future;
        if (failProfiles) return http.Response('{"detail":"boom"}', 500);
        switch (profile) {
          case 'console-builder':
            rows = [
              _row(
                'cb-1',
                'Saludo cordial inicial',
                now - 300,
                profile: profile,
              ),
              _row('cb-2', 'Iconos de la forja', now - 400, profile: profile),
              ..._noise('cb', now, profile: profile),
            ];
            // On a Fold (9960): «Forja · 7 chats» over a panel of two.
            total = 7;
          case 'pi':
            // A full first page (12 rows, the rail's page size), two of
            // them cron runs: ten chats listed and more on the server.
            rows = [
              _row('pi-1', 'Una sola charla', now - 900, profile: profile),
              for (var i = 2; i <= 10; i++)
                _row(
                  'pi-$i',
                  'Charla $i',
                  now - 900 - i * 60,
                  profile: profile,
                ),
              for (var i = 1; i <= 2; i++)
                _row(
                  'pi-cron-$i',
                  'Copia nocturna',
                  now - 2000 - i * 60,
                  profile: profile,
                  source: 'cron',
                ),
            ];
            total = 40;
          default:
            rows = const [];
            total = 0;
        }
    }
    return http.Response(
      jsonEncode({'sessions': rows, 'total': total, 'limit': 12, 'offset': 0}),
      200,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureValues = <String, String>{};

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureValues.clear();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = call.arguments is Map
                ? Map<Object?, Object?>.from(call.arguments as Map)
                : const <Object?, Object?>{};
            switch (call.method) {
              case 'write':
                secureValues[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secureValues[args['key']];
              case 'readAll':
                return Map<String, String>.of(secureValues);
              case 'delete':
                secureValues.remove(args['key']);
                return null;
            }
            return null;
          },
        );
  });

  tearDown(() async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
    BotRosterRegistry.shared.clear();
    ProfileRailChats.debugReset();
    await DockPreferencesController.instance.setUseDock(true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// The Chats screen at [size] physical pixels and [dpr], its list loaded
  /// and no chat open.
  Future<void> pumpList(
    WidgetTester tester, {
    required _Dashboard server,
    required ProfileRailChats railChats,
    Size size = const Size(933, 704),
    double dpr = 1,
    Key? key,
    List<AgentProfile> Function(List<AgentProfile> roster)? reorder,
  }) async {
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    BotRosterRegistry.shared.publish(
      _connectionId,
      'Tablet QA',
      reorder == null ? _roster(server.now) : reorder(_roster(server.now)),
      sessions: true,
    );
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final dashboard = DashboardClient(
      host: '127.0.0.1',
      port: 9119,
      manualToken: 'dashboard-token',
      httpClientOverride: MockClient(server.handle),
    );
    final gateway = testApiClient(
      baseUrl: 'http://127.0.0.1:8642',
      connectionId: _connectionId,
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/status' ||
            request.url.path == '/api/sessions') {
          return http.Response('{}', 200);
        }
        return http.Response('{}', 404);
      }),
    );
    final repository = SessionRepository(dashboard, gateway);
    addTearDown(() {
      repository.close();
      dashboard.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        key: key,
        locale: const Locale('en'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: SessionListScreen(
          connection: _connection(),
          connManager: manager,
          clientOverride: gateway,
          repositoryOverride: repository,
          railChatsOverride: railChats,
          chatScreenBuilderOverride: (session) => _ChatProbe(session),
        ),
      ),
    );
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      if (find.text('Notas de la release').evaluate().isNotEmpty) break;
    }
    await settle(tester);
  }

  /// The chat s-1 open from the list and the list folded beside it: the
  /// rail of agents.
  Future<void> openChatAndFold(WidgetTester tester) async {
    await tester.tap(find.text('Firma del keystore en CI'));
    await settle(tester);
    // The list folded beside the chat (a folded state may be remembered
    // from a screen built before).
    final views = ChatWorkspaceScope.maybeOf(
      tester.element(find.byKey(const ValueKey('chat-probe-s-1'))),
    )!;
    if (views.listVisible) views.toggleList();
    await settle(tester);
    expect(find.byKey(const ValueKey('chat-switcher-rail')), findsOneWidget);
  }

  /// The Chats screen on an open Fold, a chat open and the list folded:
  /// the rail of agents beside the chat.
  Future<void> pumpRail(
    WidgetTester tester, {
    required _Dashboard server,
    required ProfileRailChats railChats,
    Key? key,
  }) async {
    await pumpList(tester, server: server, railChats: railChats, key: key);
    await openChatAndFold(tester);
  }

  Finder face(String owner) =>
      find.byKey(ValueKey('chat-switcher-face-$owner'));
  Finder badge(String owner) =>
      find.byKey(ValueKey('chat-switcher-badge-$owner'));
  String? badgeText(WidgetTester tester, String owner) {
    final texts = find.descendant(
      of: badge(owner),
      matching: find.byType(Text),
    );
    if (texts.evaluate().isEmpty) return null;
    return tester.widget<Text>(texts.first).data;
  }

  ProfileFace railFace(WidgetTester tester, String owner) =>
      tester.widget<ProfileFace>(
        find.descendant(of: face(owner), matching: find.byType(ProfileFace)),
      );

  testWidgets('every face is the roster\'s own profile, and every profile '
      'with chats gets its count, read once', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final server = _Dashboard(now);
    final railChats = ProfileRailChats(spacing: Duration.zero);
    await pumpRail(tester, server: server, railChats: railChats);

    // The faces: the very profile the roster (and so Bots and Inicio) has,
    // with its face metadata; the active profile wears the ring.
    final roster = BotRosterRegistry.shared.store(_connectionId).profiles;
    for (final owner in ['default', 'console-builder', 'pi', 'studio-qa']) {
      expect(face(owner), findsOneWidget, reason: owner);
      final profile = railFace(tester, owner).profile!;
      final known = roster.firstWhere(
        (p) => (p.isDefault ? 'default' : p.name) == owner,
      );
      expect(identical(profile, known), isTrue, reason: owner);
    }
    expect(
      railFace(tester, 'console-builder').profile!.botFaceShape,
      'blobatar::boxy',
    );
    expect(railFace(tester, 'default').active, isTrue);
    expect(railFace(tester, 'console-builder').active, isFalse);

    // The counts: the chats each panel lists, by the list's own filters
    // (children, cron, archived, kanban and auxiliary rows out), never the
    // server's `total`; «N+» while the server has more; a profile without
    // chats has none. The main profile's come from the list itself.
    expect(badgeText(tester, 'default'), '2');
    expect(badgeText(tester, 'console-builder'), '2');
    expect(badgeText(tester, 'pi'), '10+');
    expect(badge('studio-qa'), findsNothing);

    // The name Bots gives the face: «Forja», not «console-builder».
    expect(
      tester
          .widget<Tooltip>(
            find.ancestor(
              of: face('console-builder'),
              matching: find.byType(Tooltip),
            ),
          )
          .message,
      'Forja',
    );

    // Read once, only the profiles the roster says have chats, most
    // recent first; never the active one, never one at rest.
    expect(server.profileReads, ['console-builder', 'pi']);
    expect(railChats.debugRequests, 2);

    // Its panel lists its chats; a row opens it in the pane.
    await tester.tap(face('console-builder'));
    await settle(tester);
    expect(find.text('2 chats'), findsOneWidget);
    final row = RegExp(r'^chat-switcher-row-(?!mark-)');
    expect(
      find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> && row.hasMatch(key.value);
      }),
      findsNWidgets(2),
    );
    expect(
      find.byKey(const ValueKey('chat-switcher-row-cb-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('chat-switcher-row-cb-2')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('chat-switcher-panel-name')))
          .data,
      'Forja',
    );
    await tester.tap(find.byKey(const ValueKey('chat-switcher-row-cb-1')));
    await settle(tester);
    expect(find.byKey(const ValueKey('chat-probe-cb-1')), findsOneWidget);

    // A profile with more on the server: its header says «N+» of the same
    // chats its face counts.
    await tester.tap(face('pi'));
    await settle(tester);
    expect(find.text('10+ chats'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('chat-switcher-row-pi-cron-1')),
      findsNothing,
    );

    // Rebuilds of the rail within the minute ask nothing more.
    expect(server.profileReads, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a screen built again paints the counts already read at once, '
      'and a failed read later keeps them', (tester) async {
    var clock = DateTime(2026, 11, 8, 12);
    final now = clock.millisecondsSinceEpoch ~/ 1000;
    final server = _Dashboard(now);
    final railChats = ProfileRailChats(
      spacing: Duration.zero,
      now: () => clock,
    );
    await pumpRail(tester, server: server, railChats: railChats);
    expect(badgeText(tester, 'console-builder'), '2');
    expect(server.profileReads, hasLength(2));

    // A new Chats screen (cold route, same app): the cache paints first,
    // no read within the minute.
    await tester.pumpWidget(const SizedBox());
    server.failProfiles = true;
    await pumpRail(
      tester,
      server: server,
      railChats: railChats,
      key: UniqueKey(),
    );
    expect(badgeText(tester, 'console-builder'), '2');
    expect(badgeText(tester, 'pi'), '10+');
    expect(server.profileReads, hasLength(2));

    // Past the minute, the next rebuild reads again; each profile fails and
    // is skipped (the others are still read), and the counts stay.
    clock = clock.add(const Duration(minutes: 2));
    // A roster read lands (any change repaints the rail).
    BotRosterRegistry.shared.publish(
      _connectionId,
      'Tablet QA',
      _roster(now),
      sessions: true,
    );
    await settle(tester);
    expect(server.profileReads, hasLength(4));
    expect(badgeText(tester, 'console-builder'), '2');
    expect(badgeText(tester, 'pi'), '10+');
    expect(tester.takeException(), isNull);
  });

  // ── The profile strip of the list (QA 9970 SC11) ─────────────────────────
  //
  // A phone on its side (Pixel 9 Pro, 2142x960 at 2.25 = 952 dp, expanded)
  // shows the list beside the pane with no chat open: no rail, only the
  // strip of faces over the list, and it had no number. Wherever the rail
  // exists the strip now wears the rail's counts, from the same source.

  Finder stripChip(String name) =>
      find.byKey(ValueKey('session-bot-filter-$name'));
  Finder stripBadge(String name) =>
      find.byKey(ValueKey('session-bot-filter-count-$name'));
  String? stripBadgeText(WidgetTester tester, String name) {
    final texts = find.descendant(
      of: stripBadge(name),
      matching: find.byType(Text),
    );
    if (texts.evaluate().isEmpty) return null;
    return tester.widget<Text>(texts.first).data;
  }

  /// What a screen reader hears for a chip: its own button node's label.
  String? stripLabel(WidgetTester tester, String name) => tester
      .widget<Semantics>(
        find
            .ancestor(
              of: stripChip(name),
              matching: find.byWidgetPredicate(
                (w) => w is Semantics && w.properties.button == true,
              ),
            )
            .first,
      )
      .properties
      .label;

  /// The name under a chip's face (the one-line Text; the badge's has no
  /// line limit).
  Finder stripName(String name) => find.descendant(
    of: stripChip(name),
    matching: find.byWidgetPredicate((w) => w is Text && w.maxLines == 1),
  );

  // The roster's profiles: the name keys the strip's chip and, being no
  // default but the main one, the rail's face too.
  const names = ['default', 'console-builder', 'pi', 'studio-qa'];

  /// Each badge stays inside its own chip (never over the next one) and
  /// above the chip's name; nothing overflowed.
  void expectBadgesClear(WidgetTester tester) {
    for (final name in names) {
      if (stripBadge(name).evaluate().isEmpty) continue;
      final badge = tester.getRect(stripBadge(name));
      final chip = tester.getRect(stripChip(name));
      final label = tester.getRect(stripName(name));
      expect(badge.left, greaterThanOrEqualTo(chip.left - 0.01), reason: name);
      expect(badge.right, lessThanOrEqualTo(chip.right + 0.01), reason: name);
      expect(badge.bottom, lessThanOrEqualTo(label.top + 0.01), reason: name);
    }
    expect(tester.takeException(), isNull);
  }

  Future<void> expectStripCounts(
    WidgetTester tester, {
    required Size size,
    required double dpr,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final server = _Dashboard(now);
    final railChats = ProfileRailChats(spacing: Duration.zero);
    final semantics = tester.ensureSemantics();
    await pumpList(
      tester,
      server: server,
      railChats: railChats,
      size: size,
      dpr: dpr,
    );

    // The list beside the pane, no chat open: no rail, the strip counts.
    expect(find.byKey(const ValueKey('chat-switcher-rail')), findsNothing);
    expect(find.byKey(const ValueKey('session-bot-filter')), findsOneWidget);
    final strip = {
      for (final name in names) name: stripBadgeText(tester, name),
    };
    // The rail's rule: the chats the list lists (children, cron, archived,
    // kanban and auxiliary rows out), never the server's `total`; «N+»
    // while the server has more; none for a profile with no chats.
    expect(strip, {
      'default': '2',
      'console-builder': '2',
      'pi': '10+',
      'studio-qa': null,
    });
    // Read as the rail's face is: «<agent>, N conversations».
    expect(
      stripLabel(tester, 'console-builder'),
      endsWith(', 2 conversations'),
    );
    expect(stripLabel(tester, 'pi'), endsWith(', 10+ conversations'));
    expect(stripLabel(tester, 'studio-qa'), endsWith(', 0 conversations'));
    // And it reaches the tree a screen reader (and uiautomator) reads: the
    // list column beside the pane is no longer blocked by its barrier.
    expect(
      find.bySemanticsLabel(RegExp(r', 10\+ conversations$')),
      findsOneWidget,
    );
    // The strip reads what the rail reads: once, the profiles with chats.
    expect(server.profileReads, ['console-builder', 'pi']);
    expectBadgesClear(tester);

    // A chat opened and the list folded: the rail's faces say the same.
    await openChatAndFold(tester);
    for (final name in names) {
      expect(badgeText(tester, name), strip[name], reason: name);
    }
    expect(server.profileReads, hasLength(2));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  }

  // QA 9980 SC11: the roster lists the profiles in its own order, the rail
  // by the newest chat; the strip followed the roster. One order for both.
  Future<void> expectSameOrder(
    WidgetTester tester, {
    required Size size,
    required double dpr,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final server = _Dashboard(now);
    final railChats = ProfileRailChats(spacing: Duration.zero);
    await pumpList(
      tester,
      server: server,
      railChats: railChats,
      size: size,
      dpr: dpr,
      reorder: (roster) => roster.reversed.toList(),
    );
    List<String> stripOrder() {
      final at = {
        for (final n in names)
          if (stripChip(n).evaluate().isNotEmpty)
            n: tester.getTopLeft(stripChip(n)).dx,
      };
      return (at.keys.toList()..sort((a, b) => at[a]!.compareTo(at[b]!)));
    }

    final strip = stripOrder();
    expect(strip, hasLength(names.length));
    await openChatAndFold(tester);
    final at = {
      for (final n in names) n: tester.getTopLeft(face(n)).dy,
    };
    final rail = at.keys.toList()..sort((a, b) => at[a]!.compareTo(at[b]!));
    expect(strip, rail);
    expect(rail, ['default', 'console-builder', 'pi', 'studio-qa']);
    expect(tester.takeException(), isNull);
  }

  testWidgets('a phone on its side (2142x960): the strip lists the profiles '
      'in the rail\'s order', (tester) async {
    await expectSameOrder(tester, size: const Size(2142, 960), dpr: 2.25);
  });

  testWidgets('a tablet with 4 profiles: the strip lists the profiles in the '
      'rail\'s order', (tester) async {
    await expectSameOrder(tester, size: const Size(2560, 1600), dpr: 2);
  });

  testWidgets('a phone on its side (Pixel 9 Pro, 2142x960): the strip '
      'wears the rail\'s counts, the rail agrees', (tester) async {
    await expectStripCounts(tester, size: const Size(2142, 960), dpr: 2.25);
  });

  testWidgets('a tablet (1280x800): the strip wears the rail\'s counts, the '
      'rail agrees', (tester) async {
    await expectStripCounts(tester, size: const Size(2560, 1600), dpr: 2);
  });

  testWidgets('larger text on a phone on its side: badges stay clear of the '
      'names and of the next face', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final server = _Dashboard(now);
    await pumpList(
      tester,
      server: server,
      railChats: ProfileRailChats(spacing: Duration.zero),
      size: const Size(2142, 960),
      dpr: 2.25,
    );
    expect(stripBadgeText(tester, 'pi'), '10+');
    expectBadgesClear(tester);
  });

  testWidgets('a phone held upright has no rail: the strip counts nothing '
      'and reads no other profile', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final server = _Dashboard(now);
    await pumpList(
      tester,
      server: server,
      railChats: ProfileRailChats(spacing: Duration.zero),
      size: const Size(960, 2142),
      dpr: 2.25,
    );
    expect(find.byKey(const ValueKey('session-bot-filter')), findsOneWidget);
    for (final name in names) {
      expect(stripBadge(name), findsNothing, reason: name);
    }
    expect(server.profileReads, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('while searching the strip drops its counts (the other '
      'profiles\' pages are not searched), and they come back', (
    tester,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final server = _Dashboard(now);
    await pumpList(
      tester,
      server: server,
      railChats: ProfileRailChats(spacing: Duration.zero),
      size: const Size(2142, 960),
      dpr: 2.25,
    );
    expect(stripBadgeText(tester, 'console-builder'), '2');
    await tester.enterText(find.byType(TextField).first, 'keystore');
    await settle(tester);
    for (final name in names) {
      expect(stripBadge(name), findsNothing, reason: name);
    }
    await tester.enterText(find.byType(TextField).first, '');
    await settle(tester);
    expect(stripBadgeText(tester, 'console-builder'), '2');
    expect(stripBadgeText(tester, 'pi'), '10+');
    expect(tester.takeException(), isNull);
  });

  // Flicker audit P2: switching profile empties the list while the new
  // profile's own read is on the wire; its face keeps the last count known
  // (the rail's page) instead of falling to 0.
  testWidgets('switching profile: the new active face keeps its last count '
      'until its read lands', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final server = _Dashboard(now);
    await pumpRail(
      tester,
      server: server,
      railChats: ProfileRailChats(spacing: Duration.zero),
    );
    expect(badgeText(tester, 'console-builder'), '2');

    server.holdProfile = 'console-builder';
    server.hold = Completer<void>();
    final screen = tester.widget<SessionListScreen>(
      find.byType(SessionListScreen),
    );
    unawaited(
      ActiveProfileScope.of(
        screen.connManager,
        _connectionId,
      ).switchTo('console-builder'),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // The new profile's read is still on the wire: its face does not fall
    // to 0 (no badge) but keeps the last known count.
    expect(badgeText(tester, 'console-builder'), '2');

    server.hold!.complete();
    await settle(tester);
    expect(badgeText(tester, 'console-builder'), '2');
    expect(tester.takeException(), isNull);
  });
}
