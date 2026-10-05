import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/quick_reply_prefs.dart';
import 'package:hermes_android/core/widgets/chat/chat_quick_reply_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Harness {
  final composer = TextEditingController();
  final filled = <String>[];
  var smartCalls = 0;
  Completer<List<String>>? gate;
  List<String> smartResult = const ['Sí, hazlo', 'Enséñame el diff'];

  Future<List<String>> loadSmart() async {
    smartCalls++;
    final pending = gate;
    if (pending != null) return pending.future;
    return smartResult;
  }

  Widget build({
    Object? turnKey = 'turn-1',
    List<String> replies = const ['Adelante', 'Hazlo paso a paso'],
    bool smart = true,
  }) => MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: ChatQuickReplyBar(
          turnKey: turnKey,
          replies: replies,
          composer: composer,
          onFill: filled.add,
          loadSmart: smart ? loadSmart : null,
          smartLabel: 'Sugerir respuestas con IA',
        ),
      ),
    ),
  );
}

Finder _chip(String text) =>
    find.widgetWithText(OutlinedButton, text, skipOffstage: false);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    QuickReplyPrefs.debugUse(
      QuickReplyPrefs.forTesting(await SharedPreferences.getInstance()),
    );
  });
  tearDown(() => QuickReplyPrefs.debugUse(null));

  testWidgets('shows the local chips and never asks the model by itself', (
    tester,
  ) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());
    await tester.pump(const Duration(seconds: 5));

    expect(_chip('Adelante'), findsOneWidget);
    expect(_chip('Hazlo paso a paso'), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-reply-smart')), findsOneWidget);
    expect(h.smartCalls, 0);
  });

  testWidgets('tapping a chip only fills the composer', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());

    await tester.tap(_chip('Hazlo paso a paso'));
    await tester.pump();

    expect(h.filled, ['Hazlo paso a paso']);
    expect(h.smartCalls, 0);
  });

  testWidgets('hidden while the composer holds text', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());
    h.composer.text = 'h';
    await tester.pump();
    expect(_chip('Adelante'), findsNothing);
    expect(find.byKey(const ValueKey('quick-reply-smart')), findsNothing);

    h.composer.clear();
    await tester.pump();
    expect(_chip('Adelante'), findsOneWidget);
  });

  testWidgets('without contextual chips there is no lone ✨', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build(replies: const []));
    await tester.pump();
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byKey(const ValueKey('quick-reply-smart')), findsNothing);
    expect(h.smartCalls, 0);
  });

  testWidgets('the chips are transparent and keep a 48 dp target', (
    tester,
  ) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());
    for (final finder in [
      _chip('Adelante'),
      find.byKey(const ValueKey('quick-reply-smart')),
    ]) {
      final button = tester.widget<OutlinedButton>(finder);
      expect(
        button.style!.backgroundColor!.resolve(const {}),
        Colors.transparent,
      );
      expect(tester.getSize(finder).height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('the setting turns every chip off', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());
    await QuickReplyPrefs.shared.setEnabled(false);
    await tester.pump();

    expect(_chip('Adelante'), findsNothing);
    expect(find.byKey(const ValueKey('quick-reply-smart')), findsNothing);
  });

  testWidgets('no turn offers nothing', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build(turnKey: null));
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('without the capability there is no ✨ chip', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build(smart: false));
    expect(_chip('Adelante'), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-reply-smart')), findsNothing);
  });

  testWidgets('✨ asks once on tap, shows the ideas and caches them', (
    tester,
  ) async {
    final h = _Harness()..gate = Completer<List<String>>();
    await tester.pumpWidget(h.build());

    await tester.tap(find.byKey(const ValueKey('quick-reply-smart')));
    await tester.pump();
    expect(h.smartCalls, 1);
    // A second tap while it runs does not ask again.
    await tester.tap(find.byKey(const ValueKey('quick-reply-smart')));
    await tester.pump();
    expect(h.smartCalls, 1);

    h.gate!.complete(const ['Sí, hazlo', 'Enséñame el diff']);
    await tester.pump();
    expect(_chip('Sí, hazlo'), findsOneWidget);
    expect(_chip('Enséñame el diff'), findsOneWidget);
    expect(_chip('Adelante'), findsNothing);

    // Typing hides the rail; clearing brings back the cached ideas.
    h.composer.text = 'x';
    await tester.pump();
    h.composer.clear();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('quick-reply-smart')));
    await tester.pump();
    expect(_chip('Sí, hazlo'), findsOneWidget);
    expect(h.smartCalls, 1);

    await tester.tap(_chip('Sí, hazlo'));
    expect(h.filled, ['Sí, hazlo']);
  });

  testWidgets('a failed ✨ request leaves the local chips', (tester) async {
    final h = _Harness()..smartResult = const [];
    await tester.pumpWidget(h.build());

    await tester.tap(find.byKey(const ValueKey('quick-reply-smart')));
    await tester.pump();

    expect(h.smartCalls, 1);
    expect(_chip('Adelante'), findsOneWidget);
    expect(_chip('Hazlo paso a paso'), findsOneWidget);
  });

  testWidgets('a new turn drops the cached ideas and late answers', (
    tester,
  ) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());
    await tester.tap(find.byKey(const ValueKey('quick-reply-smart')));
    await tester.pump();
    expect(_chip('Sí, hazlo'), findsOneWidget);

    h.gate = Completer<List<String>>();
    await tester.pumpWidget(h.build(turnKey: 'turn-2'));
    expect(_chip('Sí, hazlo'), findsNothing);
    expect(_chip('Adelante'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('quick-reply-smart')));
    await tester.pump();
    expect(h.smartCalls, 2);
    await tester.pumpWidget(h.build(turnKey: 'turn-3'));
    h.gate!.complete(const ['Tarde']);
    await tester.pump();
    expect(_chip('Tarde'), findsNothing);
    expect(_chip('Adelante'), findsOneWidget);
  });
}
