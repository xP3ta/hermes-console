import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/subagent_detail_screen.dart';
import 'package:hermes_android/core/services/subagent_live_watch.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_live_icon.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart'
    show SubagentTailView;
import 'package:hermes_android/core/widgets/subagent_stream_view.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// The text a review screenshot showed as one raw wall: the server's live
// transcript, its window cut in the middle of a result line, then three
// tool calls and their JSON results.
const String _screenshotTail =
    r'''"exit=1\n/home/user/relay/node_modules/miniflare/dist/src/index.js:137505\n const error123 = new MiniflareCoreError(\n ^\n\nMiniflareCoreError [ERR_VALIDATION]: Unexpected options passed to `new Miniflare()` constructor:\n✖ Unrecognized keys: \"name\", \"modules\", \"bin …(+712 chars)
16:56:09 tool     | -> terminal(grep -no "Persist[A-Za-z]*\??:\|defaultPersistRoot\|persist[A-Za-z]*?:" index.d.ts + 1 comando)
16:56:09 result   | terminal ok 0.1s: {"output": "3075:persist?:\n10076:export declare type V4SharedOptions = {", "exit_code": 0, "error": null, "cwd": "/home/user/relay/node_modules/miniflare/dist/src"}
16:56:11 tool     | -> terminal(sed -n 10060,10140p index.d.ts + 1 comando)
16:56:11 result   | terminal ok 0.2s: {"output": "};\r\n} | {\r\n external: {\r\n address: string;\r\n http?: unknown;\r\n https?: unknown;\r\n };\r\n} | {\r\n disk: {\r\n path: string;\r\n htt …(+2104 chars)
16:56:12 tool     | -> terminal(node harness.mjs)
16:56:13 result   | terminal ok 0.9s: {"output": "exit=1\nMiniflareCoreError [ERR_VALIDATION]: bad options", "exit_code": 0}
16:56:15 assistant| Las opciones de Miniflare 4 no aceptan esas claves; reviso el tipo.''';

const String _tenLines =
    r'''10:00:00 tool     | -> terminal(seq 1 10)
10:00:00 result   | terminal ok 0.1s: {"output": "uno\ndos\ntres\ncuatro\ncinco\nseis\nsiete\nocho\nnueve\ndiez", "exit_code": 0, "error": null}''';

const String _secretTail =
    r'''10:00:00 tool     | -> terminal(curl -H "Authorization: Bearer abcdef0123456789" --token s3cr3tvalue https://example.com/x)
10:00:01 result   | terminal ok 0.1s: {"output": "API_KEY=sk-abcdefghijklmnopqrstuv\nlog /srv/.hermes/cache/delegation/live/deleg_1/task-0.log\nhecho", "exit_code": 0}
10:00:02 assistant| Listo, sin errores.''';

void main() {
  late ValueNotifier<SubagentLiveTail> tail;
  late ValueNotifier<SubagentLiveWatchView> live;

  setUp(() {
    tail = ValueNotifier(const SubagentLiveTail());
    live = ValueNotifier(const SubagentLiveWatchView());
  });

  tearDown(() {
    tail.dispose();
    live.dispose();
  });

  Future<void> pumpView(
    WidgetTester tester,
    String content, {
    bool truncated = false,
    bool showTargets = true,
    bool working = false,
    String activityLabel = '',
  }) async {
    tail.value = tail.value.apply(
      SubagentTailView(
        available: true,
        content: content,
        truncated: truncated,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          body: SubagentStreamView(
            tail: tail,
            live: live,
            prompt: '',
            working: working,
            showTargets: showTargets,
            activityLabel: activityLabel,
            active: false,
            clock: () => DateTime.utc(2026, 11, 8, 17),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Iterable<String> visibleTexts(WidgetTester tester) => [
    for (final text in tester.widgetList<Text>(find.byType(Text)))
      text.data ?? text.textSpan?.toPlainText() ?? '',
    for (final text in tester.widgetList<SelectableText>(
      find.byType(SelectableText),
    ))
      text.data ?? text.textSpan?.toPlainText() ?? '',
  ];

  testWidgets('the screenshot tail is rows: tool, command, status, output', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpView(tester, _screenshotTail, truncated: true);

    expect(find.byType(SubagentTailToolRow), findsNWidgets(3));
    expect(find.byType(ChatMarkdownBody), findsNothing);
    expect(find.text('Comando ejecutado'), findsNWidgets(3));
    expect(
      find.text(
        r'grep -no "Persist[A-Za-z]*\??:\|defaultPersistRoot\|persist[A-Za-z]*?:" index.d.ts + 1 comando',
      ),
      findsOneWidget,
    );
    expect(find.text('sed -n 10060,10140p index.d.ts + 1 comando'), findsOneWidget);
    expect(find.text('ok · 0,1 s'), findsOneWidget);
    expect(find.text('ok · 0,2 s'), findsOneWidget);
    expect(find.text('falló · exit 1'), findsOneWidget);
    expect(find.text('16:56:09'), findsOneWidget);
    expect(
      find.text('3075:persist?:\n10076:export declare type V4SharedOptions = {'),
      findsOneWidget,
    );
    expect(
      find.text('Las opciones de Miniflare 4 no aceptan esas claves; reviso el tipo.'),
      findsOneWidget,
    );
    // Every row in the chat's own outline family, in the quiet ink.
    final icons = tester.widgetList<ChatLiveIcon>(find.byType(ChatLiveIcon));
    expect(icons, hasLength(3));
    for (final icon in icons) {
      expect(icon.glyph, ChatLiveGlyph.terminalAgent);
      expect(icon.live, isFalse);
    }
    for (final text in visibleTexts(tester)) {
      expect(text, isNot(contains('{"')));
      expect(text, isNot(contains('"exit_code"')));
      expect(text, isNot(contains(r'\n')));
      expect(text, isNot(contains(r'\r')));
      expect(text, isNot(contains(r'\"')));
      expect(text, isNot(contains('chars)')));
      expect(text, isNot(contains('16:56:09 tool')));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long output folds to six lines and opens with «Ver más»', (
    tester,
  ) async {
    await pumpView(tester, _tenLines);
    final output = find.byWidgetPredicate(
      (w) => w is SelectableText && w.key.toString().contains('subagent-tail-output-'),
    );
    String shown() => tester.widget<SelectableText>(output).data!;
    expect(shown(), 'uno\ndos\ntres\ncuatro\ncinco\nseis\n…');
    expect(find.text('Ver más'), findsOneWidget);

    await tester.tap(find.text('Ver más'));
    await tester.pump();
    expect(shown(), 'uno\ndos\ntres\ncuatro\ncinco\nseis\nsiete\nocho\nnueve\ndiez');
    expect(find.text('Ver menos'), findsOneWidget);

    await tester.tap(find.text('Ver menos'));
    await tester.pump();
    expect(shown(), endsWith('seis\n…'));
  });

  testWidgets('a new poll keeps an opened output open', (tester) async {
    await pumpView(tester, _tenLines);
    await tester.tap(find.text('Ver más'));
    await tester.pump();
    tail.value = tail.value.apply(
      const SubagentTailView(
        available: true,
        content: '$_tenLines\n10:00:05 tool     | -> terminal(ls)',
        truncated: false,
      ),
    );
    await tester.pump();
    expect(find.text('Ver menos'), findsOneWidget);
    expect(find.byType(SubagentTailToolRow), findsNWidgets(2));
  });

  testWidgets('the owner reads commands and outputs with secrets masked', (
    tester,
  ) async {
    await pumpView(tester, _secretTail);
    final all = visibleTexts(tester).join('\n');
    expect(all, contains('curl'));
    expect(all, contains('hecho'));
    expect(all, contains('Listo, sin errores.'));
    for (final secret in [
      'abcdef0123456789',
      's3cr3tvalue',
      'sk-abcdefghijklmnopqrstuv',
      'cache/delegation/live',
      'task-0.log',
    ]) {
      expect(all, isNot(contains(secret)));
    }
  });

  testWidgets('another opener sees which tools ran, never what or why', (
    tester,
  ) async {
    await pumpView(tester, _secretTail, showTargets: false);
    expect(find.byType(SubagentTailToolRow), findsOneWidget);
    expect(find.text('Comando ejecutado'), findsOneWidget);
    expect(find.text('ok · 0,1 s'), findsOneWidget);
    final all = visibleTexts(tester).join('\n');
    expect(all, isNot(contains('curl')));
    expect(all, isNot(contains('hecho')));
    expect(all, isNot(contains('Listo')));
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('a call in hand plays its icon and runs its clock', (
    tester,
  ) async {
    await pumpView(
      tester,
      '16:49:00 tool     | -> terminal(for i in 1 2 3 4 5 6 + 3 comandos)',
      working: true,
    );
    expect(find.text('Ejecutando comando'), findsOneWidget);
    expect(find.text('for i in 1 2 3 4 5 6 + 3 comandos'), findsOneWidget);
    expect(tester.widget<ChatLiveIcon>(find.byType(ChatLiveIcon)).live, isTrue);
    expect(find.text('0:00'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'the roster says «thinking» but the log shows the command in hand: the '
    'page shows the running command, not «Pensando…»',
    (tester) async {
      live.value = const SubagentLiveWatchView(
        status: SubagentLiveWatchStatus.live,
      );
      await pumpView(
        tester,
        '16:49:00 tool     | -> terminal(for i in 1 2 3 4 5 6 + 3 comandos)',
        working: true,
        activityLabel: 'Pensando el siguiente paso',
      );
      expect(find.text('Ejecutando comando'), findsOneWidget);
      expect(find.text('Pensando el siguiente paso'), findsNothing);

      // Once the command returned, «thinking» is what it does again.
      tail.value = tail.value.apply(
        const SubagentTailView(
          available: true,
          content:
              '16:49:00 tool     | -> terminal(for i in 1 2 3 4 5 6 + 3 comandos)\n'
              '16:49:30 result   | terminal ok 30.0s: {"output": "paso 6", "exit_code": 0}',
          truncated: false,
        ),
      );
      await tester.pump();
      expect(find.text('Comando ejecutado'), findsOneWidget);
      expect(find.text('ok · 30 s'), findsOneWidget);
      expect(find.text('Pensando el siguiente paso'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a tail that is prose still reads as Markdown', (tester) async {
    await pumpView(tester, 'Leyendo ficheros\n\n- uno\n- dos');
    expect(find.byType(SubagentTailToolRow), findsNothing);
    expect(find.byType(ChatMarkdownBody), findsWidgets);
  });
}
