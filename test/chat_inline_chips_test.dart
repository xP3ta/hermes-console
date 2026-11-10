import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/project_files.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/chat_inline_refs.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_viewer_screen.dart';
import 'package:hermes_android/core/widgets/chat/chat_file_opener.dart';
import 'package:hermes_android/core/widgets/chat/chat_file_viewer_screen.dart';
import 'package:hermes_android/core/widgets/chat/chat_inline_chips.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

ChatFileRef? _ref(String text, {bool plain = false}) =>
    chatFileRefFor(text, plain: plain);

List<String> _citations(String text) => [
  for (final m in RegExp(chatCitationPattern).allMatches(text)) m[0]!,
];

List<String> _plainPaths(String text) => [
  for (final m in RegExp(
    chatFilePattern,
    caseSensitive: false,
  ).allMatches(text))
    m[0]!,
];

class _Files implements HermesProjectFilesGateway {
  _Files({this.fail = false});

  final bool fail;
  final List<String> reads = [];

  @override
  bool get projectFilesKnownUnsupported => false;

  final List<String> listed = [];

  @override
  Future<ProjectDirectoryListing> listProjectDirectory(String path) async {
    listed.add(path);
    return const ProjectDirectoryListing(entries: []);
  }

  @override
  Future<ProjectFilePreview> readProjectFileText(String path) async {
    reads.add(path);
    if (fail) throw StateError('gone');
    return ProjectFilePreview(
      path: path,
      text: 'hola',
      binary: false,
      truncated: false,
      byteSize: 4,
      mimeType: 'text/plain',
    );
  }

  @override
  Future<Uint8List> readProjectFileBytes(String path) =>
      throw UnimplementedError();
}

class _RecordingOpener extends ChatFileOpener {
  _RecordingOpener() : super(gateway: () => null, cwd: () => null);

  final List<String> opened = [];

  @override
  bool canOpen(ChatFileRef ref) => true;

  @override
  Future<void> open(BuildContext context, ChatFileRef ref) async {
    opened.add(ref.path);
  }
}

Widget _app(
  Widget child, {
  AppThemeMode mode = AppThemeMode.dark,
  double width = 360,
  double textScale = 1,
  bool reduceMotion = false,
}) => MaterialApp(
  theme: AppTheme.fromMode(mode),
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: reduceMotion,
    ),
    child: home!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: child),
      ),
    ),
  ),
);

Future<void> _pump(
  WidgetTester tester,
  String data, {
  void Function(String? href)? onLinkTap,
  ChatFileOpener? opener,
  AppThemeMode mode = AppThemeMode.dark,
  double width = 360,
  double textScale = 1,
  bool reduceMotion = false,
}) async {
  Widget body = ChatMarkdownBody(data: data, onLinkTap: onLinkTap);
  if (opener != null) {
    body = ChatFileChipScope(opener: opener, child: body);
  }
  await tester.pumpWidget(
    _app(
      body,
      mode: mode,
      width: width,
      textScale: textScale,
      reduceMotion: reduceMotion,
    ),
  );
  await tester.pump();
}

/// Collects what the app copies; the mock goes when the test ends.
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

List<String> _chipNames(WidgetTester tester) => [
  for (final chip in tester.widgetList<ChatFileChip>(find.byType(ChatFileChip)))
    chip.ref.name,
];

List<int> _pills(WidgetTester tester) => [
  for (final pill in tester.widgetList<ChatCitationPill>(
    find.byType(ChatCitationPill),
  ))
    pill.number,
];

void main() {
  group('file references (pure)', () {
    test('real references are recognised in code', () {
      expect(_ref('/home/ana/push-review.md')?.kind, ChatFileKind.markdown);
      expect(_ref('/home/ana/push-review.md')?.name, 'push-review.md');
      expect(_ref('~/algo/carpeta')?.kind, ChatFileKind.folder);
      expect(_ref('~/algo/carpeta')?.root, ChatPathRoot.home);
      expect(_ref('~/algo/carpeta/')?.path, '~/algo/carpeta');
      expect(_ref('./build/')?.kind, ChatFileKind.folder);
      expect(_ref('../notas.txt')?.root, ChatPathRoot.relative);
      expect(_ref('Console-Relay.zip')?.kind, ChatFileKind.archive);
      expect(_ref('lib/core/app.dart')?.kind, ChatFileKind.code);
      expect(_ref('pubspec.lock')?.kind, ChatFileKind.data);
      expect(_ref('captura.PNG')?.kind, ChatFileKind.image);
      expect(_ref('informe.pdf')?.kind, ChatFileKind.pdf);
      expect(_ref('README.md')?.kind, ChatFileKind.markdown);
      expect(_ref('/home/demo/proyecto')?.kind, ChatFileKind.folder);
      expect(_ref('lib/main.dart:42')?.name, 'main.dart:42');
      expect(_ref('lib/main.dart:42')?.path, 'lib/main.dart');
      expect(_ref('/srv/app/x.json:3-9')?.name, 'x.json:3-9');
    });

    test('look-alikes are not references', () {
      for (final text in [
        'foo.bar',
        '1.2.3',
        'v1.0.0',
        'flutter test',
        'https://example.com/a.md',
        'www.example.com/readme.md',
        'example.com',
        'Node.js',
        'next.js',
        '/compact',
        '/etc',
        '/api/v1/users',
        './gradlew',
        '.gitignore',
        'sync/state',
        'and/or',
        'a@b.md',
        '*.dart',
        'C:/Users/x',
        '//comment',
        '..',
        '/',
        '~',
        'lib/',
        '',
      ]) {
        expect(_ref(text), isNull, reason: text);
      }
    });

    test('plain text only takes files with a known extension', () {
      expect(_ref('/home/demo/.hermes/memory/', plain: true), isNull);
      expect(_ref('~/algo/carpeta', plain: true), isNull);
      expect(_ref('/home/demo/a.md', plain: true)?.name, 'a.md');
      expect(_ref('a.unknown', plain: true), isNull);
    });

    test('the plain-text pattern picks files, not URLs or prose', () {
      expect(_plainPaths('Mira /home/x/informe.md, ./notas.txt y README.md.'), [
        '/home/x/informe.md',
        './notas.txt',
        'README.md',
      ]);
      expect(_plainPaths('visita https://example.com/a/b.md hoy'), isEmpty);
      expect(_plainPaths('él y/o ella, versión 1.2.3 y foo.bar'), isEmpty);
      expect(_plainPaths('mira (lib/a.dart) o "b.py"'), ['lib/a.dart', 'b.py']);
      expect(_plainPaths('foo.mdx y foo.jsonl'), ['foo.mdx']);
    });
  });

  group('citation numbers (pure)', () {
    test('a citation follows text or punctuation', () {
      expect(_citations('Sale a las 8:30.[1][2] y más'), ['[1]', '[2]']);
      expect(_citations('Un dato [3], otro dato.[12]'), ['[3]', '[12]']);
      expect(_citations('Eso «dice»[4] y "esto"[5]'), ['[4]', '[5]']);
      expect(_citations('otro dato[12]'), isEmpty);
    });

    test('indexes, links and list labels are not citations', () {
      for (final text in [
        'array[0]',
        'a[1][2]',
        'f(x)[1]',
        'arr[1].x',
        'dato [1](https://example.com)',
        '[1] https://example.com/a',
        'texto\n[1] https://example.com/a',
        'x [0]',
        'x [1000]',
        'x [01]',
        'x [1]: https://example.com',
        'x [1]b',
        'x [a]',
        'x [1]= 2',
      ]) {
        expect(_citations(text), isEmpty, reason: text);
      }
    });

    test('sources come from labelled lines and a Sources section', () {
      final labelled = chatCitationSources(
        'Dato.[1][2]\n\n[1] https://example.com/a\n'
        '[2]: <https://example.com/b> título\n'
        '[3] sin enlace\n- [4] [Título](https://example.com/d).',
      );
      expect(labelled[1], 'https://example.com/a');
      expect(labelled[3], isNull);
      expect(labelled[4], 'https://example.com/d');
      final sectioned = chatCitationSources(
        'Dato.[1]\n\n## Fuentes\n\n1. Título https://example.com/x.\n'
        '2. [Otro](https://example.com/y)\n\n## Más\n\n3. https://nope.dev',
      );
      expect(sectioned[1], 'https://example.com/x');
      expect(sectioned[2], 'https://example.com/y');
      expect(sectioned[3], isNull);
      expect(chatCitationSources('Sin enlaces [1]').isEmpty, isTrue);
      expect(chatCitationSources('[1] javascript:alert(1)').isEmpty, isTrue);
    });

    test('the same text is parsed once', () {
      const text = '[1] https://example.com/a';
      expect(
        identical(chatCitationSources(text), chatCitationSources(text)),
        isTrue,
      );
    });
  });

  group('inline code', () {
    testWidgets('a path in code is a chip, other code stays code', (
      tester,
    ) async {
      await _pump(
        tester,
        'Abre `~/algo/carpeta` y `/home/x/push-review.md` o `lib/a.dart`; '
        'no `foo.bar`, ni `1.2.3`, ni `flutter test`, ni `/compact`.',
      );
      expect(_chipNames(tester), ['carpeta', 'push-review.md', 'a.dart']);
      for (final code in ['foo.bar', '1.2.3', 'flutter test', '/compact']) {
        expect(
          find.textContaining(code, findRichText: true),
          findsOneWidget,
          reason: code,
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('a fenced block with a path stays a code block', (
      tester,
    ) async {
      await _pump(tester, '```\n/home/x/a.md\n```');
      expect(find.byType(ChatFileChip), findsNothing);
      expect(
        find.textContaining('/home/x/a.md', findRichText: true),
        findsWidgets,
      );
    });

    testWidgets('code inside a link keeps the link', (tester) async {
      await _pump(tester, 'Mira [`README.md`](https://example.com/r).');
      expect(find.byType(ChatFileChip), findsNothing);
    });

    testWidgets('inline math is untouched', (tester) async {
      await _pump(tester, r'Vale $x^2$ y `a.md`.');
      expect(_chipNames(tester), ['a.md']);
      expect(tester.takeException(), isNull);
    });
  });

  group('file chips in text', () {
    testWidgets('paths and names become chips with the short name', (
      tester,
    ) async {
      await _pump(
        tester,
        'Lee /home/x/informe.md, ./notas.txt y Console-Relay.zip.',
      );
      expect(_chipNames(tester), [
        'informe.md',
        'notas.txt',
        'Console-Relay.zip',
      ]);
      expect(find.text('informe.md'), findsOneWidget);
      expect(find.textContaining('/home/x/informe.md'), findsNothing);
    });

    testWidgets('URLs, libraries, versions and links stay text', (
      tester,
    ) async {
      await _pump(
        tester,
        'Ve https://example.com/a/b.md con Node.js 1.2.3, foo.bar, y/o '
        '[notas.md](https://example.com/n) y /home/demo/.hermes/memory/.',
      );
      expect(find.byType(ChatFileChip), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a table keeps its own cells', (tester) async {
      await _pump(
        tester,
        '| a | b |\n|---|---|\n| `x/y.md` | /home/z/q.py |\n',
      );
      expect(find.byType(ChatFileChip), findsNothing);
      expect(find.textContaining('q.py', findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('tap on a file chip', () {
    testWidgets('opens through the conversation scope', (tester) async {
      final opener = _RecordingOpener();
      await _pump(tester, 'Mira `/home/x/a.md`.', opener: opener);
      await tester.tap(find.byType(ChatFileChip));
      await tester.pump();
      expect(opener.opened, ['/home/x/a.md']);
    });

    testWidgets('copies the path when nothing can open it', (tester) async {
      final copied = _mockClipboard(tester);
      await _pump(tester, 'Mira `~/algo/carpeta`.');
      await tester.tap(find.byType(ChatFileChip));
      await tester.pump();
      expect(copied, ['~/algo/carpeta']);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('the opener shows the file in the viewer', (tester) async {
      final files = _Files();
      final opener = ChatFileOpener(gateway: () => files, cwd: () => '/srv/p');
      await _pump(tester, 'Mira `docs/a.md` y `~/b.md`.', opener: opener);
      expect(opener.canOpen(chatFileRefFor('docs/a.md')!), isTrue);
      expect(opener.canOpen(chatFileRefFor('~/b.md')!), isFalse);
      // Folders open the explorer; archives and PDF are left to «copiar».
      expect(opener.canOpen(chatFileRefFor('/home/y/z')!), isTrue);
      expect(opener.canOpen(chatFileRefFor('/x/y.zip')!), isFalse);
      expect(opener.canOpen(chatFileRefFor('/x/y.pdf')!), isFalse);
      // A path that is no path is not asked.
      expect(opener.canOpen(chatFileRefFor('./a/b.md')!), isTrue);
      await tester.tap(find.byType(ChatFileChip).first);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(files.reads, ['/srv/p/docs/a.md']);
      expect(find.byType(ArtifactViewerScreen), findsOneWidget);
    });

    testWidgets('a failed read opens the viewer with the reason', (
      tester,
    ) async {
      final copied = _mockClipboard(tester);
      final files = _Files(fail: true);
      final opener = ChatFileOpener(gateway: () => files, cwd: () => null);
      await _pump(tester, 'Mira `/srv/a.md`.', opener: opener);
      await tester.tap(find.byType(ChatFileChip));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(files.reads, ['/srv/a.md']);
      // Not a silent copy: the page says what happened and offers a retry.
      expect(copied, isEmpty);
      expect(find.byKey(const ValueKey('chat-file-error')), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
      expect(find.text('Copiar ruta'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a line in the text reaches the viewer', (tester) async {
      final files = _Files();
      final opener = ChatFileOpener(gateway: () => files, cwd: () => '/srv/p');
      await _pump(tester, 'Mira `lib/a.dart:3-5`.', opener: opener);
      await tester.tap(find.byType(ChatFileChip));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(files.reads, ['/srv/p/lib/a.dart']);
      final page = tester.widget<ChatFileViewerScreen>(
        find.byType(ChatFileViewerScreen),
      );
      expect((page.line, page.endLine), (3, 5));
    });

    testWidgets('a folder opens the explorer there', (tester) async {
      final files = _Files();
      final opener = ChatFileOpener(
        gateway: () => files,
        cwd: () => '/srv/p',
        roots: () => const ['/srv/q'],
      );
      await _pump(tester, 'Mira `/srv/q/docs/`.', opener: opener);
      await tester.tap(find.byType(ChatFileChip));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ChatFolderScreen), findsOneWidget);
      expect(files.listed, ['/srv/q/docs']);
    });

    testWidgets('a server without the routes copies the path', (tester) async {
      final copied = _mockClipboard(tester);
      final opener = ChatFileOpener(gateway: () => null, cwd: () => '/srv/p');
      await _pump(tester, 'Mira `docs/a.md`.', opener: opener);
      await tester.tap(find.byType(ChatFileChip));
      await tester.pump();
      expect(copied, ['docs/a.md']);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a touch just outside the chip still opens it', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _app(
          Padding(
            padding: const EdgeInsets.all(60),
            child: SizedBox(
              width: 200,
              height: 140,
              child: Center(
                child: ChatTapTarget(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => taps++,
                    child: const SizedBox(width: 20, height: 20),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final box = tester.getRect(
        find.descendant(
          of: find.byType(ChatTapTarget),
          matching: find.byType(GestureDetector),
        ),
      );
      expect(box.size, const Size(20, 20), reason: 'the look does not change');
      for (final shift in [
        const Offset(0, 22),
        const Offset(0, -22),
        const Offset(22, 0),
        const Offset(-22, 0),
      ]) {
        await tester.tapAt(box.center + shift);
      }
      expect(taps, 4);
      await tester.tapAt(box.center + const Offset(0, 26));
      await tester.tapAt(box.center + const Offset(-26, 0));
      expect(taps, 4, reason: 'beyond 48 dp it is not the chip');
    });

    testWidgets('the chip keeps its size and has the target around it', (
      tester,
    ) async {
      await _pump(tester, 'Mira `/home/x/a.md`.');
      final chip = find.byType(ChatFileChip);
      expect(
        find.descendant(of: chip, matching: find.byType(ChatTapTarget)),
        findsOneWidget,
      );
      expect(tester.getSize(chip).height, lessThan(48));
    });

    test('relative paths resolve against the folder', () {
      final opener = ChatFileOpener(gateway: () => null, cwd: () => '/a/b');
      String? at(String p) => opener.resolve(chatFileRefFor(p)!);
      expect(at('./x.md'), '/a/b/x.md');
      expect(at('../x.md'), '/a/x.md');
      expect(at('lib/x.md'), '/a/b/lib/x.md');
      expect(at('/z/x.md'), '/z/x.md');
      expect(at('~/x.md'), isNull);
      expect(at('lib/x.dart:12'), '/a/b/lib/x.dart');
      expect(
        ChatFileOpener(
          gateway: () => null,
          cwd: () => null,
        ).resolve(chatFileRefFor('lib/x.md')!),
        isNull,
      );
    });
  });

  group('citation pills', () {
    const answer =
        'Sale a las 8:30.[1][2] Y luego [3].\n\n'
        '[1] https://example.com/a\n'
        '[2] https://example.com/b';

    testWidgets('are pills, not raw text', (tester) async {
      await _pump(tester, answer);
      expect(_pills(tester), [1, 2, 3]);
      expect(find.textContaining('.[1]', findRichText: true), findsNothing);
    });

    testWidgets('a pill with a source opens its link', (tester) async {
      final opened = <String?>[];
      await _pump(tester, answer, onLinkTap: opened.add);
      await tester.tap(find.byType(ChatCitationPill).at(1));
      await tester.pump();
      expect(opened, ['https://example.com/b']);
    });

    testWidgets('a pill without a source is only visual', (tester) async {
      final opened = <String?>[];
      await _pump(tester, answer, onLinkTap: opened.add);
      await tester.tap(find.byType(ChatCitationPill).at(2));
      await tester.pump();
      expect(opened, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a list of sources that arrives later reaches the pill', (
      tester,
    ) async {
      final opened = <String?>[];
      Widget block(String sources) => _app(
        ChatMarkdownBlock(
          data: 'Dato.[1]',
          sourcesFrom: sources,
          onLinkTap: opened.add,
        ),
      );
      await tester.pumpWidget(block('Dato.[1]'));
      await tester.tap(find.byType(ChatCitationPill));
      await tester.pump();
      expect(opened, isEmpty);
      await tester.pumpWidget(block('Dato.[1]\n\n[1] https://example.com/a'));
      await tester.tap(find.byType(ChatCitationPill));
      await tester.pump();
      expect(opened, ['https://example.com/a']);
    });

    testWidgets('indexes and Markdown links are left alone', (tester) async {
      final opened = <String?>[];
      await _pump(
        tester,
        'Usa array[0], a[1][2] y f(x)[1], mira [3](https://example.com/c).',
        onLinkTap: opened.add,
      );
      expect(find.byType(ChatCitationPill), findsNothing);
      await tester.tap(find.textContaining('mira', findRichText: true));
      expect(tester.takeException(), isNull);
    });

    testWidgets('are announced with their number', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester, answer);
      expect(find.bySemanticsLabel(RegExp('Fuente 1')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp('Cita 3')), findsWidgets);
      semantics.dispose();
    });
  });

  group('layout and themes', () {
    const mixed =
        'Mira /home/ana/un/camino/muy/largo/de/verdad/documento-con-un-'
        'nombre-larguisimo-que-no-cabe-en-la-columna.md y `~/algo/carpeta` '
        'más texto que sigue.[1][2]\n\n[1] https://example.com/a';

    for (final mode in [AppThemeMode.dark, AppThemeMode.light]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('${mode.name} at ×$scale does not overflow', (
          tester,
        ) async {
          await _pump(tester, mixed, mode: mode, width: 240, textScale: scale);
          expect(find.byType(ChatFileChip), findsNWidgets(2));
          expect(find.byType(ChatCitationPill), findsNWidgets(2));
          for (final element in find.byType(ChatFileChip).evaluate()) {
            expect(element.size!.width, lessThanOrEqualTo(240));
          }
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('with reduced motion everything still renders', (tester) async {
      await _pump(tester, mixed, reduceMotion: true, textScale: 2);
      expect(find.byType(ChatFileChip), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the text stays selectable around the chips', (tester) async {
      await _pump(tester, mixed);
      expect(find.byType(SelectionArea), findsOneWidget);
      final region = tester.state<SelectableRegionState>(
        find.byType(SelectableRegion),
      );
      region.selectAll();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
