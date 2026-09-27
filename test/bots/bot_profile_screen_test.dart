import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/profile/bot_profile_screen.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/desktop_model_catalog.dart';
import 'package:hermes_android/core/services/bot_profile_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

final class _FakeGateway implements BotModelGateway, BotProfileGateway {
  final configures = <(String, Map<String, dynamic>)>[];
  final reasoningWrites = <(String, String)>[];
  String? reasoning = 'medium';
  bool confirmFirst = false;

  @override
  Future<DesktopModelCatalog> botModelOptions(String profile) async =>
      DesktopModelCatalog.fromJson({
        'model': 'gpt-5.5',
        'provider': 'openai',
        'providers': [
          {
            'slug': 'openai',
            'name': 'OpenAI',
            'is_current': true,
            'authenticated': true,
            'models': ['gpt-5.5', 'gpt-5.5-mini'],
          },
        ],
      });

  @override
  Future<String?> botReasoning(String profile) async => reasoning;

  @override
  Future<void> setBotReasoning(String profile, String effort) async {
    reasoningWrites.add((profile, effort));
    reasoning = effort;
  }

  @override
  Future<Map<String, dynamic>> configureBotProfile(
    String profile,
    Map<String, dynamic> changes,
  ) async {
    configures.add((profile, changes));
    if (confirmFirst && changes['confirm_expensive_model'] != true) {
      return {'confirm_required': true, 'confirm_message': 'Expensive'};
    }
    return {
      'ok': true,
      'applied': {'model': true},
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _RpcRecorder {
  final calls = <(String, Map<String, dynamic>)>[];
  Map<String, dynamic> Function(String, Map<String, dynamic>) reply = (_, _) =>
      {};

  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    calls.add((method, params));
    return reply(method, params);
  }
}

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: MediaQuery(
    data: const MediaQueryData(size: Size(420, 1400), disableAnimations: true),
    child: child,
  ),
);

void main() {
  const profile = AgentProfile(
    name: 'builder',
    model: 'gpt-5.5',
    provider: 'openai',
    description: 'Builds and tests Console',
    skillCount: 24,
    botModeUiMeta: {'title': 'Console Builder'},
  );

  Future<_FakeGateway> pumpProfile(
    WidgetTester tester, {
    List<BotNowItem> now = const [],
    bool readOnly = false,
    void Function()? onChanged,
  }) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final gateway = _FakeGateway();
    await tester.pumpWidget(
      _app(
        BotProfileScreen(
          data: () => BotProfileData(
            profile: profile,
            signal: now.isEmpty ? BotFaceSignal.idle : BotFaceSignal.working,
            now: now,
            roomCount: 2,
          ),
          modelGateway: gateway,
          profileGateway: gateway,
          readOnly: readOnly,
          machineLabel: 'homelab',
          onChat: () {},
          onRoutines: () {},
          onSoul: () {},
          onSkills: () {},
          onMemory: () {},
          onRooms: () {},
          onChanged: onChanged,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return gateway;
  }

  testWidgets('hero, shortcuts, Now idle, model and profile links', (
    tester,
  ) async {
    await pumpProfile(tester);
    expect(find.byKey(const ValueKey('bot-profile-hero')), findsOneWidget);
    expect(find.text('Console Builder'), findsOneWidget);
    expect(find.text('@builder · Builds and tests Console'), findsOneWidget);
    expect(find.text('Rooms · 2'), findsOneWidget);
    expect(find.text('Not working on anything right now'), findsOneWidget);
    expect(find.text('openai · gpt-5.5'), findsOneWidget);
    expect(find.text('Medium'), findsOneWidget);
    expect(find.text('homelab'), findsOneWidget);
    expect(find.text('24'), findsOneWidget);
    for (final key in const [
      'bot-profile-soul',
      'bot-profile-skills',
      'bot-profile-memory',
      'bot-profile-machine',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }
  });

  testWidgets('changing the model calls profiles.configure', (tester) async {
    var changed = 0;
    final gateway = await pumpProfile(tester, onChanged: () => changed++);
    await tester.tap(find.byKey(const ValueKey('bot-profile-model')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('bot-profile-model-openai-gpt-5.5-mini')),
    );
    await tester.pumpAndSettle();
    expect(gateway.configures.single.$1, 'builder');
    expect(gateway.configures.single.$2, {
      'model': 'gpt-5.5-mini',
      'provider': 'openai',
    });
    expect(find.text('openai · gpt-5.5-mini'), findsOneWidget);
    expect(changed, 1);
  });

  testWidgets('expensive model asks for confirmation and resends', (
    tester,
  ) async {
    final gateway = await pumpProfile(tester)
      ..confirmFirst = true;
    await tester.tap(find.byKey(const ValueKey('bot-profile-model')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('bot-profile-model-openai-gpt-5.5-mini')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Expensive'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
    expect(gateway.configures, hasLength(2));
    expect(gateway.configures.last.$2['confirm_expensive_model'], isTrue);
  });

  testWidgets('reasoning is editable per bot', (tester) async {
    final gateway = await pumpProfile(tester);
    await tester.tap(find.byKey(const ValueKey('bot-profile-reasoning')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bot-profile-reasoning-high')));
    await tester.pumpAndSettle();
    expect(gateway.reasoningWrites.single, ('builder', 'high'));
    expect(find.text('High'), findsOneWidget);
  });

  testWidgets('read-only profile cannot change model or reasoning', (
    tester,
  ) async {
    final gateway = await pumpProfile(tester, readOnly: true);
    await tester.tap(find.byKey(const ValueKey('bot-profile-model')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bot-profile-model-list')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('bot-profile-reasoning')));
    await tester.pumpAndSettle();
    expect(gateway.configures, isEmpty);
    expect(gateway.reasoningWrites, isEmpty);
  });

  testWidgets('Now lists live work and Stop runs the server action', (
    tester,
  ) async {
    var stops = 0;
    await pumpProfile(
      tester,
      now: [
        BotNowItem(
          label: 'Working in «Design Review»',
          onStop: () async => stops++,
        ),
        const BotNowItem(label: 'Needs you in «Ops»', attention: true),
      ],
    );
    expect(find.text('Working in «Design Review»'), findsOneWidget);
    expect(find.byKey(const ValueKey('bot-profile-stop-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('bot-profile-stop-1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('bot-profile-stop-0')));
    await tester.pumpAndSettle();
    expect(stops, 1);
  });

  group('BotProfileClient model and reasoning RPCs', () {
    test('model.options and config reasoning are profile-scoped', () async {
      final rpc = _RpcRecorder()
        ..reply = (method, params) => switch (method) {
          'model.options' => {'providers': []},
          'config.get' => {'key': 'reasoning', 'value': 'high'},
          'config.set' => {'key': 'reasoning', 'value': params['value']},
          _ => {},
        };
      final client = BotProfileClient(rpc.call);
      await client.botModelOptions('builder');
      expect(await client.botReasoning('builder'), 'high');
      await client.setBotReasoning('builder', 'low');
      expect(rpc.calls.map((c) => c.$1), [
        'model.options',
        'config.get',
        'config.set',
      ]);
      expect(rpc.calls[0].$2['profile'], 'builder');
      expect(rpc.calls[1].$2, {'key': 'reasoning', 'profile': 'builder'});
      expect(rpc.calls[2].$2, {
        'key': 'reasoning',
        'value': 'low',
        'profile': 'builder',
        'scope': 'global',
      });
      expect(
        () => client.setBotReasoning('builder', 'bogus'),
        throwsFormatException,
      );
    });
  });
}
