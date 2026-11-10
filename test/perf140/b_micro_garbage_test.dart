// B1-B3 (performance audit 1.4.0): small per-frame and per-build garbage.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/screens/chat_screen.dart'
    show friendlyModelName;
import 'package:hermes_android/core/services/bot_mention_roster.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_mention_palette.dart';
import 'package:hermes_android/core/widgets/hermes_status_indicator.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  testWidgets('B1 the working pulse beats without rebuilding anything', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.hermesRedDark,
        home: const Scaffold(body: Center(child: HermesStatusPulse())),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final inside = <Element>{
      ...find
          .descendant(
            of: find.byType(HermesStatusPulse),
            matching: find.byWidgetPredicate((_) => true),
          )
          .evaluate(),
    };
    expect(inside, isNotEmpty);
    var rebuilt = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (inside.contains(element)) rebuilt++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    debugOnRebuildDirtyWidget = null;

    expect(tester.hasRunningAnimations, isTrue);
    expect(rebuilt, 0, reason: 'the pulse must repaint, not rebuild');
  });

  testWidgets('B2 the mention palette keeps one merged listenable', (
    tester,
  ) async {
    final roster = BotMentionRoster();
    final first = TextEditingController();
    final second = TextEditingController();
    final focus = FocusNode();
    addTearDown(() {
      first.dispose();
      second.dispose();
      focus.dispose();
      roster.dispose();
    });
    roster.replace('local', 'Local', [const AgentProfile(name: 'default')]);
    var controller = first;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Column(
                children: [
                  ChatMentionPalette(
                    controller: controller,
                    focusNode: focus,
                    connectionId: 'local',
                    profile: 'default',
                    roster: roster,
                  ),
                  TextField(controller: controller, focusNode: focus),
                ],
              );
            },
          ),
        ),
      ),
    );
    Listenable listened() => tester
        .widget<ListenableBuilder>(
          find
              .descendant(
                of: find.byType(ChatMentionPalette),
                matching: find.byType(ListenableBuilder),
              )
              .first,
        )
        .listenable;
    final before = listened();

    rebuild(() {});
    await tester.pump();
    expect(identical(listened(), before), isTrue);

    // Another controller: the palette follows the new one.
    rebuild(() => controller = second);
    await tester.pump();
    expect(identical(listened(), before), isFalse);
    roster.replace('local', 'Local', [
      const AgentProfile(name: 'default'),
      const AgentProfile(name: 'writer'),
    ]);
    await tester.enterText(find.byType(TextField), '@wr');
    await tester.pump();
    expect(find.text('@writer'), findsOneWidget);
  });

  test('B3 model names read the same', () {
    expect(friendlyModelName('claude-opus-4-8-20251101'), 'Opus 4.8');
    expect(friendlyModelName('anthropic/claude-sonnet-4-6'), 'Sonnet 4.6');
    expect(friendlyModelName('anthropic/claude-sonnet-4.6'), 'Sonnet 4.6');
    expect(friendlyModelName('claude-haiku-4-5'), 'Haiku 4.5');
    expect(friendlyModelName('claude-sonnet-4-20250514'), 'Sonnet 4');
    expect(friendlyModelName('claude-3-5-sonnet-20241022'), 'Sonnet 3.5');
    expect(friendlyModelName('claude-opus-4-1-thinking'), 'Opus 4.1 Thinking');
    expect(friendlyModelName('gpt-4o'), 'GPT-4o');
    expect(
      friendlyModelName('un-modelo-local-muy-largo-de-prueba'),
      'un-modelo-local-muy…',
    );
  });
}
