import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/bot_screen_access.dart';
import 'package:hermes_android/core/bots/ui/profile/bot_profile_screen.dart';
import 'package:hermes_android/core/bots/ui/roster/dots_home_view.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/bots/ui/roster/roster_actions.dart';
import 'package:hermes_android/core/bots/ui/roster/roster_model.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screen/screen_controller.dart';
import 'package:hermes_android/core/screens/screen_peek_screen.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

BotRosterEntry _bot(String name, {bool isDefault = false}) => BotRosterEntry(
  agent: MissionAgent(
    profile: AgentProfile(name: name, isDefault: isDefault),
    status: MissionAgentStatus.idle,
    statusEvidence: '',
    usage: const MissionUsage(),
  ),
  signal: BotFaceSignal.idle,
  preview: '',
);

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: MediaQuery(
    data: const MediaQueryData(size: Size(420, 1400), disableAnimations: true),
    child: Scaffold(body: child),
  ),
);

/// An access whose answers are fixed by profile name.
BotScreenAccess _access(Map<String, BotScreenProbeResult> answers) =>
    BotScreenAccess(probe: (profile) async => answers[profile]!);

void main() {
  group('BotScreenAccess', () {
    test('asks once per bot, caps what runs at once and caches', () async {
      final pending = <String, Completer<BotScreenProbeResult>>{};
      var inFlight = 0;
      var peak = 0;
      final asked = <String>[];
      final access = BotScreenAccess(
        maxInFlight: 2,
        probe: (profile) {
          asked.add(profile);
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          final done = pending[profile] = Completer();
          return done.future.whenComplete(() => inFlight--);
        },
      );
      access.ensure(['a', 'b', 'c', 'a']);
      access.ensure(['b', 'c']);
      await Future<void>.delayed(Duration.zero);
      expect(asked, ['a', 'b'], reason: 'two at a time, no duplicates');
      expect(access.stateOf('a'), BotScreenState.unknown);

      pending['a']!.complete(BotScreenProbeResult.available);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(asked, ['a', 'b', 'c']);
      pending['b']!.complete(BotScreenProbeResult.none);
      pending['c']!.complete(BotScreenProbeResult.available);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(peak, 2);
      expect(access.stateOf('a'), BotScreenState.available);
      expect(access.stateOf('b'), BotScreenState.none);

      access.ensure(['a', 'b', 'c']);
      await Future<void>.delayed(Duration.zero);
      expect(asked.length, 3, reason: 'answers are cached');
      access.dispose();
    });

    test('a failed question stays unknown and a refresh asks again', () async {
      var fail = true;
      final access = BotScreenAccess(
        probe: (_) async {
          if (fail) throw StateError('offline');
          return BotScreenProbeResult.available;
        },
      );
      access.ensure(['a']);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(access.stateOf('a'), BotScreenState.unknown);
      fail = false;
      access.refresh(['a']);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(access.stateOf('a'), BotScreenState.available);
      access.dispose();
    });

    test('a Hermes without display.* marks every bot as having none', () async {
      final asked = <String>[];
      final access = BotScreenAccess(
        maxInFlight: 1,
        probe: (profile) async {
          asked.add(profile);
          return BotScreenProbeResult.instanceNone;
        },
      );
      access.ensure(['a', 'b', 'c']);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(asked, ['a'], reason: 'nobody else is asked');
      expect(access.stateOf('b'), BotScreenState.none);
      access.dispose();
    });

    test('over RPC it follows the peek: installed means a desktop', () async {
      final calls = <(String, Map<String, dynamic>)>[];
      Future<Map<String, dynamic>> rpc(
        String method,
        Map<String, dynamic> params,
      ) async {
        calls.add((method, params));
        return {'installed': params['profile'] != 'bare', 'running': false};
      }

      final access = BotScreenAccess.overRpc(rpc);
      access.ensure(['work', 'bare']);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(access.stateOf('work'), BotScreenState.available);
      expect(access.stateOf('bare'), BotScreenState.none);
      expect(calls.every((c) => c.$1 == 'display.status'), isTrue);

      final old = BotScreenAccess.overRpc(
        (m, p) async => throw const TuiGatewayRpcError(
          'display.status',
          'method not found',
          code: -32601,
        ),
      );
      old.ensure(['work']);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(old.stateOf('work'), BotScreenState.none);
      access.dispose();
      old.dispose();
    });

    test('the default bot is asked as the gateway default', () {
      expect(
        botScreenProfile(const AgentProfile(name: 'default', isDefault: true)),
        '',
      );
      expect(botScreenProfile(const AgentProfile(name: 'astra')), 'astra');
    });
  });

  group('bot list', () {
    testWidgets('the button shows only for bots with a desktop and opens '
        'that bot', (tester) async {
      final opened = <String>[];
      final access = _access({
        'astra': BotScreenProbeResult.available,
        'forja': BotScreenProbeResult.none,
        'radar': BotScreenProbeResult.available,
      });
      await tester.pumpWidget(
        _app(
          DotsHomeView(
            bots: [_bot('astra'), _bot('forja'), _bot('radar')],
            rooms: const [],
            avatarCache: null,
            searchOpen: ValueNotifier(false),
            onOpenBot: (_) {},
            onBotActions: (_) {},
            onOpenRoom: (_) {},
            screenAccess: access,
            onOpenScreen: (e) => opened.add(e.profile.name),
          ),
        ),
      );
      // Before any answer there is no button.
      expect(find.byKey(const ValueKey('roster-screen-astra')), findsNothing);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('roster-screen-astra')), findsOneWidget);
      expect(find.byKey(const ValueKey('roster-screen-radar')), findsOneWidget);
      expect(find.byKey(const ValueKey('roster-screen-forja')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('roster-screen-radar')));
      expect(opened, ['radar']);
      access.dispose();
    });

    testWidgets('without an access the list is the same as before', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          DotsHomeView(
            bots: [_bot('astra')],
            rooms: const [],
            avatarCache: null,
            searchOpen: ValueNotifier(false),
            onOpenBot: (_) {},
            onBotActions: (_) {},
            onOpenRoom: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('roster-screen-astra')), findsNothing);
    });

    testWidgets('the long-press sheet offers the screen, dimmed with the '
        'cause when there is none', (tester) async {
      Future<RosterBotAction?> pumpSheet(BotScreenState? state) async {
        RosterBotAction? picked;
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          _app(
            Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  picked = await showModalBottomSheet<RosterBotAction>(
                    context: context,
                    builder: (_) => RosterBotActionsSheet(
                      entry: _bot('astra'),
                      avatarCache: null,
                      canMutate: true,
                      canSection: false,
                      screen: state,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        return picked;
      }

      await pumpSheet(null);
      expect(find.byKey(const ValueKey('roster-action-screen')), findsNothing);

      await pumpSheet(BotScreenState.none);
      expect(find.text('No desktop'), findsOneWidget);
      final dimmed = tester.widget<ListTile>(
        find.byKey(const ValueKey('roster-action-screen')),
      );
      expect(dimmed.enabled, isFalse);

      await pumpSheet(BotScreenState.available);
      expect(find.text('No desktop'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('roster-action-screen')));
      await tester.pumpAndSettle();
      // The sheet popped with the screen action.
      expect(find.byKey(const ValueKey('roster-action-screen')), findsNothing);
    });
  });

  group('bot profile', () {
    Future<void> pumpProfile(
      WidgetTester tester, {
      BotScreenAccess? access,
      VoidCallback? onScreen,
    }) async {
      await tester.binding.setSurfaceSize(const Size(420, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(
          BotProfileScreen(
            data: () => const BotProfileData(
              profile: AgentProfile(name: 'astra'),
              signal: BotFaceSignal.idle,
            ),
            machineLabel: 'homelab',
            onChat: () {},
            onRoutines: () {},
            onSoul: () {},
            onSkills: () {},
            onMemory: () {},
            onScreen: onScreen,
            screenAccess: access,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('the pill sits at the top, in view without scrolling, and '
        'opens the screen', (tester) async {
      var taps = 0;
      final access = _access({'astra': BotScreenProbeResult.available});
      await pumpProfile(tester, access: access, onScreen: () => taps++);

      final pill = find.byKey(const ValueKey('bot-profile-screen'));
      expect(pill, findsOneWidget);
      expect(find.text('View screen'), findsOneWidget);
      expect(tester.getBottomLeft(pill).dy, lessThan(500));
      await tester.tap(pill);
      expect(taps, 1);
      access.dispose();
    });

    testWidgets('dimmed with the cause when the bot has no desktop', (
      tester,
    ) async {
      var taps = 0;
      final access = _access({'astra': BotScreenProbeResult.none});
      await pumpProfile(tester, access: access, onScreen: () => taps++);

      expect(find.text('No desktop'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bot-profile-screen')));
      expect(taps, 0);
      access.dispose();
    });

    testWidgets('no callback, no pill', (tester) async {
      await pumpProfile(tester);
      expect(find.byKey(const ValueKey('bot-profile-screen')), findsNothing);
    });
  });

  testWidgets('the opener pushes the peek of that bot', (tester) async {
    final calls = <(String, Map<String, dynamic>)>[];
    final controller = ScreenController(
      rpc: (method, params) async {
        calls.add((method, params));
        return {'installed': true, 'running': false, 'supported': true};
      },
      leasePayloads: const Stream.empty(),
      dashboardBase: () => Uri.parse('http://127.0.0.1:9119'),
    );
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => pushBotScreen(
              context,
              connection: SavedConnection(
                id: 'c1',
                label: 'homelab',
                host: '127.0.0.1',
                port: 9119,
                apiKey: 'k',
              ),
              profile: 'astra',
              builder: (profile) =>
                  ScreenPeekScreen(controller: controller, profile: profile),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final peek = tester.widget<ScreenPeekScreen>(find.byType(ScreenPeekScreen));
    expect(peek.profile, 'astra');
    expect(calls.first.$1, 'display.status');
    expect(calls.first.$2['profile'], 'astra');
  });
}
