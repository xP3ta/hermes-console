// ARTBLANCO: «Artefactos» opened from a chat that sits in the views host
// (as ChatScreen opens it: a page on the chat's own navigator) shows its
// header and its list or its empty state, on an opaque page that nothing
// covers, on the open Fold (split), upright and on a phone. ARTCAUSA: also
// with the Fold's escapes that are not UTF-8 in the transcript.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_content_screen.dart';
import 'package:hermes_android/core/services/app_error_log.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/malformed_artifact_rows.dart';

const _names = ['uno', 'dos', 'tres', 'cuatro', 'cinco'];

/// Newest first, one shared link per assistant message.
List<Map<String, dynamic>> _transcript(int count) => [
  for (final (i, name) in _names.take(count).indexed)
    {
      'role': 'assistant',
      'content': 'Mira https://example.com/docs/$name',
      'timestamp': 1781774300 - i,
    },
];

/// Stands in for the chat: a button that opens «Artefactos» the way
/// ChatScreen._openChatContent does.
class _Chat extends StatelessWidget {
  const _Chat(this.transcript);

  final List<Map<String, dynamic>> Function() transcript;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        key: const ValueKey('open-artifacts'),
        onPressed: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => ChatContentScreen(
              transcript: transcript,
              hasOlder: () => false,
              loadOlder: () async {},
              onOpenFile: (_, _) async {},
              launchExternal: (_) async => false,
            ),
          ),
        ),
        child: const Text('Artefactos del chat'),
      ),
    ),
  );
}

Future<void> _open(
  WidgetTester tester, {
  required Size size,
  required ThemeData theme,
  required List<Map<String, dynamic>> Function() transcript,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1
    ..padding = const FakeViewPadding(top: 24, bottom: 16);
  addTearDown(tester.view.reset);
  final controller = ChatWorkspaceController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: const [
        Strings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: Strings.supportedLocales,
      theme: theme,
      home: ChatWorkspaceHost(
        controller: controller,
        chat: _Chat(transcript),
        tabBuilder: (_, tab) => Scaffold(body: Text('tab ${tab.name}')),
      ),
    ),
  );
  // A tab open: on the open Fold the chat is a pane beside the workspace.
  controller.open(ChatWorkspaceTab.terminal);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  if (!chatWorkspaceSplitFits(size.width)) {
    // Compact opens Trabajo with no rail: return through the chat segment of
    // its own bar before opening a route from the retained chat.
    final openArtifacts = find.byKey(const ValueKey('open-artifacts'));
    expect(openArtifacts, findsNothing);
    expect(
      find.byKey(const ValueKey('open-artifacts'), skipOffstage: false),
      findsOneWidget,
    );
    // Under 600 dp there is no rail at all; from there it is the rail.
    final railed = find.byKey(const ValueKey('chat-workspace-rail'));
    final showChat = find.byKey(
      ValueKey(
        size.width < 600 ? 'chat-workspace-collapse' : 'chat-workspace-show-chat',
      ),
    );
    expect(railed.evaluate().isEmpty, size.width < 600);
    expect(showChat, findsOneWidget);
    await tester.tap(showChat);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.active, ChatWorkspaceTab.terminal);
    expect(controller.mode, ChatWorkspaceMode.chat);
  }
  expect(
    find.byKey(const ValueKey('open-artifacts')).hitTestable(),
    findsOneWidget,
  );
  await tester.tap(find.byKey(const ValueKey('open-artifacts')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// The page covers the screen with an opaque background, its header and
/// [content] are on screen and nothing paints over it.
void _expectVisible(WidgetTester tester, Size size, Finder content) {
  final screen = Offset.zero & size;
  final page = find.byType(ChatContentScreen);
  expect(page, findsOneWidget);
  final scaffold = find.descendant(of: page, matching: find.byType(Scaffold));
  expect(tester.getRect(scaffold.first), screen);
  final background = tester.widget<Material>(
    find.descendant(of: scaffold.first, matching: find.byType(Material)).first,
  );
  expect(background.color, isNotNull);
  expect(background.color!.a, 1.0, reason: 'an opaque page');

  for (final (what, finder) in [
    ('header', find.descendant(of: page, matching: find.text('Artefactos'))),
    ('content', content),
  ]) {
    final rect = tester.getRect(finder.first);
    expect(rect.isEmpty, isFalse, reason: what);
    expect(screen.intersect(rect).isEmpty, isFalse, reason: what);
    expect(rect.top, greaterThanOrEqualTo(0), reason: what);
  }

  // Nothing over it: the middle of the screen belongs to the page.
  final hit = tester.hitTestOnBinding(screen.center);
  final pageBox = tester.renderObject(scaffold.first);
  expect(hit.path.any((entry) => entry.target == pageBox), isTrue);
}

void main() {
  final sizes = {
    'open Fold 933x704': const Size(933, 704),
    'upright Fold 657x870': const Size(657, 870),
    'phone 360x640': const Size(360, 640),
  };
  final themes = {
    'dark': AppTheme.hermesRedDark,
    'light': AppTheme.hermesRedLight,
  };
  for (final size in sizes.entries) {
    for (final theme in themes.entries) {
      final name = '${size.key}, ${theme.key}';
      testWidgets('$name, nothing shared: header and empty state', (
        tester,
      ) async {
        await _open(
          tester,
          size: size.value,
          theme: theme.value,
          transcript: () => _transcript(0),
        );
        expect(tester.takeException(), isNull);
        _expectVisible(
          tester,
          size.value,
          find.text('Aún no hay nada compartido'),
        );
      });

      testWidgets('$name, five links: header and the list', (tester) async {
        await _open(
          tester,
          size: size.value,
          theme: theme.value,
          transcript: () => _transcript(5),
        );
        expect(tester.takeException(), isNull);
        _expectVisible(
          tester,
          size.value,
          find.byKey(const ValueKey('sa1215-item-uno')),
        );
        expect(find.byKey(const ValueKey('sa1215-list')), findsOneWidget);
      });
    }
  }

  // ARTCAUSA: escapes that are not UTF-8 threw a FormatException on the
  // Fold. Now the page lists the good items beside them, without falling
  // back to the empty state (nothing is logged).
  for (final size in sizes.entries) {
    testWidgets('${size.key}, escapes that are not UTF-8: the good items', (
      tester,
    ) async {
      AppErrorLog.resetForTesting();
      addTearDown(AppErrorLog.resetForTesting);
      await _open(
        tester,
        size: size.value,
        theme: AppTheme.hermesRedDark,
        transcript: () => malformedArtifactRows().reversed.toList(),
      );
      expect(tester.takeException(), isNull);
      _expectVisible(
        tester,
        size.value,
        find.byKey(const ValueKey('sa1215-list')),
      );
      expect(find.text('Aún no hay nada compartido'), findsNothing);
      final list = find
          .descendant(
            of: find.byKey(const ValueKey('sa1215-list')),
            matching: find.byType(Scrollable),
          )
          .first;
      for (final label in ['informe.pdf', 'notas.txt', 'uno']) {
        final item = find.byKey(ValueKey('sa1215-item-$label'));
        await tester.scrollUntilVisible(item, 200, scrollable: list);
        expect(item, findsOneWidget, reason: label);
      }
      expect(tester.takeException(), isNull);
      expect(AppErrorLog.recent, isEmpty);
    });
  }

  // The page never goes blank, and a failure is never «nothing shared»
  // (review R5A B3-3): a transcript that cannot be read shows the header,
  // says it could not read, offers to retry, and is logged (type only).
  testWidgets('a transcript that throws: header, error and retry', (
    tester,
  ) async {
    AppErrorLog.resetForTesting();
    addTearDown(AppErrorLog.resetForTesting);
    var fails = true;
    await _open(
      tester,
      size: const Size(933, 704),
      theme: AppTheme.hermesRedDark,
      transcript: () =>
          fails ? throw StateError('unreadable transcript') : _transcript(2),
    );
    expect(tester.takeException(), isNull);
    _expectVisible(
      tester,
      const Size(933, 704),
      find.text('No se pudo leer esta conversación'),
    );
    expect(find.text('Aún no hay nada compartido'), findsNothing);
    expect(
      AppErrorLog.recent.map((record) => record.source),
      contains('artifacts'),
    );

    fails = false;
    await tester.tap(find.byKey(const ValueKey('sa1215-read-retry')));
    await tester.pump();
    expect(find.byKey(const ValueKey('sa1215-read-failed')), findsNothing);
    expect(find.byKey(const ValueKey('sa1215-item-uno')), findsOneWidget);
    expect(find.byKey(const ValueKey('sa1215-item-dos')), findsOneWidget);
  });

  // What was read stays when a later read fails: the items, and a notice
  // that this is not the whole conversation, with its retry.
  testWidgets('a read that fails later keeps what was read', (tester) async {
    AppErrorLog.resetForTesting();
    addTearDown(AppErrorLog.resetForTesting);
    var fails = false;
    await _open(
      tester,
      size: const Size(933, 704),
      theme: AppTheme.hermesRedDark,
      transcript: () =>
          fails ? throw StateError('unreadable transcript') : _transcript(3),
    );
    expect(find.byKey(const ValueKey('sa1215-item-tres')), findsOneWidget);

    fails = true;
    // Any rebuild reads the transcript again, e.g. the search box.
    await tester.enterText(find.byType(TextField), 'example');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('sa1215-read-partial')), findsOneWidget);
    for (final name in ['uno', 'dos', 'tres']) {
      expect(find.byKey(ValueKey('sa1215-item-$name')), findsOneWidget);
    }
    expect(find.text('Aún no hay nada compartido'), findsNothing);

    fails = false;
    await tester.tap(find.byKey(const ValueKey('sa1215-read-retry')));
    await tester.pump();
    expect(find.byKey(const ValueKey('sa1215-read-partial')), findsNothing);
    expect(find.byKey(const ValueKey('sa1215-item-tres')), findsOneWidget);
  });
}
