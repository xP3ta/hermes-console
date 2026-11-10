import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/chat_folder_learning.dart';
import 'package:hermes_android/core/utils/chat_inline_refs.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_viewer_screen.dart';
import 'package:hermes_android/core/widgets/chat/chat_file_opener.dart';
import 'package:hermes_android/core/widgets/chat/chat_inline_chips.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'chat_file_search_test.dart' show TreeFiles;
import 'support/fake_webview_platform.dart';

/// The chip of a reply, inside a conversation whose folder is `/home/u/a`
/// while the agent worked (a tool said so) in `/home/u/b/sub`.
Future<void> _pump(
  WidgetTester tester,
  String markdown, {
  required ChatFileOpener opener,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.fromMode(AppThemeMode.dark),
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: Scaffold(
        body: ChatFileChipScope(
          opener: opener,
          child: ChatMarkdownBody(data: markdown),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }
}

List<String> _mockClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}

/// An opener like the chat's: `cwd` is the conversation's folder and the
/// learned folders come from the paths [learnedFrom] a tool was given.
ChatFileOpener _opener(
  TreeFiles files, {
  String? cwd = '/home/u/a',
  List<String> learnedFrom = const ['/home/u/b/sub/pair.py'],
  void Function()? onLearn,
}) => ChatFileOpener(
  gateway: () => files,
  cwd: () => cwd,
  roots: () => [?cwd],
  learnedRoots: () {
    onLearn?.call();
    return chatLearnFolders(learnedFrom, known: [?cwd]);
  },
);

void main() {
  setUp(() {
    WebViewPlatform.instance = FakeWebViewPlatform();
  });

  testWidgets('a bare name said from another repository opens from there', (
    tester,
  ) async {
    final files = TreeFiles({
      '/home/u/a/README.md': 'a',
      '/home/u/b/sub/pair.py': 'print("pair")',
    });
    var learned = 0;
    final opener = _opener(files, onLearn: () => learned++);
    await _pump(
      tester,
      'He cambiado `pair.py` para emparejar.',
      opener: opener,
    );
    // Building the chip never learns the folders; a tap does, once.
    expect(find.byType(ChatFileChip), findsOneWidget);
    expect(learned, 0);
    expect(opener.canOpen(chatFileRefFor('pair.py')!), isTrue);
    expect(learned, 0);
    await tester.tap(find.byType(ChatFileChip));
    await _settle(tester);
    expect(learned, 1);
    // The conversation's folder first, then the learned one; no walk needed.
    expect(files.reads, ['/home/u/a/pair.py', '/home/u/b/sub/pair.py']);
    expect(files.listed, isEmpty);
    expect(find.byType(ArtifactViewerScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-file-error')), findsNothing);
  });

  testWidgets('a relative path resolves against the learned repository', (
    tester,
  ) async {
    final files = TreeFiles({
      '/home/u/a/README.md': 'a',
      '/home/u/b/docs/sync/CONTRATO.md': '# Contrato',
    });
    final opener = _opener(files, learnedFrom: ['/home/u/b/plugin/x.py']);
    await _pump(tester, 'Ver `docs/sync/CONTRATO.md`.', opener: opener);
    await tester.tap(find.byType(ChatFileChip));
    await _settle(tester);
    expect(files.reads, [
      '/home/u/a/docs/sync/CONTRATO.md',
      '/home/u/b/plugin/docs/sync/CONTRATO.md',
      '/home/u/b/docs/sync/CONTRATO.md',
    ]);
    expect(find.byType(ArtifactViewerScreen), findsOneWidget);
  });

  testWidgets('when no candidate exists the learned folders are walked', (
    tester,
  ) async {
    final files = TreeFiles({
      '/home/u/a/README.md': 'a',
      '/home/u/b/manifest.json': '{}',
      '/home/u/b/sub/deep/pair.py': 'x',
    });
    final opener = _opener(files, learnedFrom: ['/home/u/b/manifest.json']);
    await _pump(tester, 'Mira `pair.py`.', opener: opener);
    await tester.tap(find.byType(ChatFileChip));
    await _settle(tester);
    expect(files.listed, ['/home/u/b', '/home/u/b/sub', '/home/u/b/sub/deep']);
    expect(files.reads.last, '/home/u/b/sub/deep/pair.py');
    expect(find.byType(ArtifactViewerScreen), findsOneWidget);
  });

  testWidgets('several matches offer a choice in a design-system sheet', (
    tester,
  ) async {
    final files = TreeFiles({
      '/home/u/b/x/pair.py': 'uno',
      '/home/u/b/y/pair.py': 'dos',
    });
    final opener = _opener(files, learnedFrom: ['/home/u/b']);
    await _pump(tester, 'Mira `pair.py`.', opener: opener);
    await tester.tap(find.byType(ChatFileChip));
    await _settle(tester);
    expect(find.byKey(const ValueKey('chat-file-choice')), findsOneWidget);
    expect(find.byType(ArtifactViewerScreen), findsNothing);
    expect(find.text('Elegir archivo'), findsWidgets);
    await tester.tap(find.widgetWithText(FilledButton, 'Elegir archivo'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('chat-file-choice-sheet')), findsOne);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    expect(find.text('x/pair.py'), findsOneWidget);
    expect(find.text('y/pair.py'), findsOneWidget);
    await tester.tap(find.text('y/pair.py'));
    await _settle(tester);
    expect(files.reads.last, '/home/u/b/y/pair.py');
    expect(find.byType(ArtifactViewerScreen), findsOneWidget);
    expect(find.textContaining('dos', findRichText: true), findsWidgets);
  });

  testWidgets('a real miss says where it was looked for and copies the best '
      'path', (tester) async {
    final copied = _mockClipboard(tester);
    final files = TreeFiles({
      '/home/u/a/README.md': 'a',
      '/home/u/b/manifest.json': '{}',
    });
    final opener = _opener(files, learnedFrom: ['/home/u/b/manifest.json']);
    await _pump(tester, 'Mira `pair.py`.', opener: opener);
    await tester.tap(find.byType(ChatFileChip));
    await _settle(tester);
    expect(find.byKey(const ValueKey('chat-file-error')), findsOneWidget);
    expect(find.textContaining('No se encuentra el archivo'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-file-tried')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('chat-file-tried-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('chat-file-tried')), findsOneWidget);
    expect(find.text('/home/u/a'), findsOneWidget);
    expect(find.text('/home/u/b'), findsOneWidget);
    await tester.tap(find.text('Copiar ruta'));
    await tester.pump();
    expect(copied, ['/home/u/a/pair.py']);
  });

  testWidgets('a file that usually holds secrets still asks first', (
    tester,
  ) async {
    final files = TreeFiles({'/home/u/b/secrets.json': '{"k":1}'});
    final opener = _opener(files, learnedFrom: ['/home/u/b']);
    await _pump(tester, 'Mira `secrets.json`.', opener: opener);
    await tester.tap(find.byType(ChatFileChip));
    await _settle(tester);
    expect(find.byKey(const ValueKey('chat-file-confirm')), findsOneWidget);
    expect(files.reads, isEmpty);
    expect(files.listed, isEmpty);
  });

  testWidgets('without a conversation folder the chip still only copies', (
    tester,
  ) async {
    final copied = _mockClipboard(tester);
    final files = TreeFiles({'/home/u/b/sub/pair.py': 'x'});
    final opener = _opener(files, cwd: null);
    await _pump(tester, 'Mira `pair.py`.', opener: opener);
    expect(opener.canOpen(chatFileRefFor('pair.py')!), isFalse);
    await tester.tap(find.byType(ChatFileChip));
    await _settle(tester);
    expect(copied, ['pair.py']);
    expect(files.reads, isEmpty);
  });
}
