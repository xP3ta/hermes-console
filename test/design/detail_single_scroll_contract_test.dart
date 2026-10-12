// Spec 080: detail routes have ONE vertical page scroll. A vertical
// Scrollable nested in another vertical Scrollable is the "bubble" users
// complained about. Every migrated detail route is listed here; the list only
// grows. Step 8 added memory, logs (bridge/gateway/run result) and
// the diff review page (memory draft / bridge editor).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/profile/bot_profile_screen.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/screens/memory_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// Vertical scrollables that have a vertical scrollable ancestor.
List<Element> nestedVerticalScrollables(WidgetTester tester) {
  final out = <Element>[];
  for (final element in find.byType(Scrollable).evaluate()) {
    final widget = element.widget as Scrollable;
    if (axisDirectionToAxis(widget.axisDirection) != Axis.vertical) continue;
    var nested = false;
    element.visitAncestorElements((ancestor) {
      final w = ancestor.widget;
      if (w is Scrollable &&
          axisDirectionToAxis(w.axisDirection) == Axis.vertical) {
        nested = true;
        return false;
      }
      return true;
    });
    if (nested) out.add(element);
  }
  return out;
}

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      home: home,
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

final _long = List.generate(40, (i) => 'Line $i of a long text').join('\n');

void main() {
  testWidgets('Bot profile: one vertical scroll', (tester) async {
    await _pump(
      tester,
      BotProfileScreen(
        data: () => const BotProfileData(
          profile: AgentProfile(name: 'builder', model: 'm', provider: 'p'),
          signal: BotFaceSignal.idle,
        ),
        machineLabel: 'x',
        onChat: () {},
        onRoutines: () {},
        onSoul: () {},
        onSkills: () {},
        onMemory: () {},
      ),
    );
    expect(nestedVerticalScrollables(tester), isEmpty);
  });

  testWidgets('HermesDetailScaffold with long text: one vertical scroll', (
    tester,
  ) async {
    await _pump(
      tester,
      HermesDetailScaffold(
        title: 'Detail',
        sections: [
          const HermesSectionHeader('What it does'),
          HermesTextBlock(text: _long),
        ],
      ),
    );
    await tester.tap(find.text('Show all'));
    await tester.pumpAndSettle();
    expect(nestedVerticalScrollables(tester), isEmpty);
  });

  testWidgets('HermesLogPage: one vertical scroll', (tester) async {
    await _pump(tester, HermesLogPage(title: 'Log', text: _long));
    expect(nestedVerticalScrollables(tester), isEmpty);
  });

  testWidgets('Memory file detail: one vertical scroll', (tester) async {
    await _pump(
      tester,
      MemoryFileDetailPage(
        name: 'MEMORY',
        bytes: 10,
        hasDraft: false,
        onOpenDraft: () {},
      ),
    );
    expect(nestedVerticalScrollables(tester), isEmpty);
  });

  testWidgets('Review page (diffs): one vertical scroll', (tester) async {
    await _pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showHermesReviewPage(
            context: context,
            title: 'Diff',
            text: _long,
            confirmLabel: 'Apply',
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(nestedVerticalScrollables(tester), isEmpty);
  });
}
