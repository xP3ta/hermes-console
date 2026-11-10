// ORDEN-SLASH-RUTA part B: media in the chat as the L2 design
// (`hermes-132/maquetas/L2-chat-antes-despues.png`, `v2-cadu-console.html`).
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/attachment_card.dart';
import 'package:hermes_android/core/widgets/chat/chat_link_card.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/core/widgets/generated_image_card.dart';
import 'package:hermes_android/core/widgets/stacked_image_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _app(
  Widget child, {
  double textScale = 1,
  AppThemeMode mode = AppThemeMode.dark,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromMode(mode),
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: true,
      textScaler: TextScaler.linear(textScale),
    ),
    child: home!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 60, 16, 16),
      child: child,
    ),
  ),
);

void _phone(WidgetTester tester, {Size size = const Size(390, 844)}) {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Future<File> _png(WidgetTester tester, Directory dir, String name) async {
  final bytes = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 40, 30),
      Paint()..color = const Color(0xff2255aa),
    );
    final image = await recorder.endRecording().toImage(40, 30);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  });
  final f = File('${dir.path}/$name');
  f.writeAsBytesSync(bytes!);
  return f;
}

void main() {
  group('image deck (L2 «mazo»)', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('l2-deck-'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<List<File>> files(WidgetTester tester, int n) async => [
      for (var i = 0; i < n; i++) await _png(tester, dir, 'img-$i.png'),
    ];

    Widget deck(
      List<Widget> cards, {
      void Function(List<File>, int)? onOpen,
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [StackedImageCards(onOpenGallery: onOpen, children: cards)],
    );

    List<Widget> ready(List<File> images) => [
      for (final f in images)
        GeneratedImageCard(
          status: GeneratedImageStatus.ready,
          file: f,
          intrinsicSize: const Size(40, 30),
        ),
    ];

    for (final n in [2, 5, 12]) {
      testWidgets('$n images: count, caption and TalkBack say $n', (
        tester,
      ) async {
        _phone(tester);
        final handle = tester.ensureSemantics();
        try {
          final images = await files(tester, n);
          final opened = <int>[];
          await tester.pumpWidget(
            _app(deck(ready(images), onOpen: (_, i) => opened.add(i))),
          );
          await tester.pump();
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('image-stack-count')),
              matching: find.text('$n'),
            ),
            findsOneWidget,
          );
          expect(find.text('$n imágenes · toca para abrir'), findsOneWidget);
          // TalkBack: where the deck is, then «N imágenes, toca para abrir»,
          // and a double tap opens the viewer.
          expect(
            find.bySemanticsLabel(RegExp('^Imagen 1 de $n\\.')),
            findsOneWidget,
          );
          final hinted = find.semantics.byHint('$n imágenes, toca para abrir');
          expect(hinted, findsOne);
          tester.semantics.tap(hinted);
          expect(opened, [0]);
          // Never more than two cards behind, however many images.
          expect(
            find.byKey(const ValueKey('image-stack-behind-1')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('image-stack-behind-2')),
            n == 2 ? findsNothing : findsOneWidget,
          );
          // The caption opens the viewer at the image on top.
          await tester.tap(find.byKey(const ValueKey('image-stack-caption')));
          expect(opened, [0, 0]);
          expect(tester.takeException(), isNull);
        } finally {
          handle.dispose();
        }
      });
    }

    testWidgets('a failed thumbnail keeps the deck; the viewer gets the rest', (
      tester,
    ) async {
      _phone(tester);
      final images = await files(tester, 3);
      final opened = <(List<File>, int)>[];
      await tester.pumpWidget(
        _app(
          deck([
            GeneratedImageCard(
              status: GeneratedImageStatus.error,
              onRetry: () {},
            ),
            ...ready(images.sublist(1)),
          ], onOpen: (f, i) => opened.add((f, i))),
        ),
      );
      await tester.pump();
      expect(find.text('3 imágenes · toca para abrir'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('image-stack-caption')));
      // The failed one on top: the viewer opens on the images that loaded.
      expect(opened, hasLength(1));
      expect(
        opened.single.$1.map((f) => f.path),
        images.sublist(1).map((f) => f.path),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('on a 320 dp phone the cards behind stay on screen (#18)', (
      tester,
    ) async {
      _phone(tester, size: const Size(320, 640));
      final images = await files(tester, 5);
      await tester.pumpWidget(_app(deck(ready(images))));
      await tester.pump();
      final top = tester.getRect(find.byKey(const ValueKey('image-stack-top')));
      // Room inside the 16 dp margins, and how far the furthest card (shifted
      // 14 dp, turned 4°) reaches past the top card's end.
      const room = 320 - 16.0;
      final reach = 14 + top.height / 2 * math.sin(4 * math.pi / 180);
      expect(top.right + reach, lessThanOrEqualTo(room + 0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('text at 200 % on a small phone: no overflow', (tester) async {
      _phone(tester, size: const Size(320, 640));
      final images = await files(tester, 5);
      await tester.pumpWidget(_app(deck(ready(images)), textScale: 2));
      await tester.pump();
      expect(find.text('5 imágenes · toca para abrir'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final mode in [AppThemeMode.light, AppThemeMode.dark]) {
      testWidgets('${mode.name}: caption in the theme\'s secondary text', (
        tester,
      ) async {
        _phone(tester);
        final images = await files(tester, 2);
        await tester.pumpWidget(_app(deck(ready(images)), mode: mode));
        await tester.pump();
        final caption = tester.widget<Text>(
          find.byKey(const ValueKey('image-stack-caption')),
        );
        expect(
          caption.style?.color,
          AppTheme.fromMode(mode).hermes.textSecondary,
        );
      });
    }
  });

  group('file card (L2)', () {
    testWidgets('type, name and «PDF · size», a chevron when it opens', (
      tester,
    ) async {
      var opened = 0;
      await tester.pumpWidget(
        _app(
          AttachmentCard(
            name: 'aurora-brief.pdf',
            mimeType: 'application/pdf',
            sizeLabel: '2,4 MB',
            onTap: () => opened++,
          ),
        ),
      );
      expect(find.text('aurora-brief.pdf'), findsOneWidget);
      // Only what is known: no page count is invented.
      expect(find.text('PDF · 2,4 MB'), findsOneWidget);
      expect(find.textContaining('página'), findsNothing);
      expect(
        find.byKey(const ValueKey('attachment-file-card-open')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('attachment-file-card')));
      expect(opened, 1);
    });

    testWidgets('a file that opens is a button for TalkBack (#19)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _app(
            AttachmentCard(
              name: 'aurora-brief.pdf',
              mimeType: 'application/pdf',
              sizeLabel: '2,4 MB',
              onTap: () {},
            ),
          ),
        );
        expect(
          tester.getSemantics(
            find.byKey(const ValueKey('attachment-file-card')),
          ),
          isSemantics(isButton: true, hasTapAction: true),
        );
      } finally {
        handle.dispose();
      }
    });

    testWidgets('a narrow card shrinks its name, never overflows (gint26)', (
      tester,
    ) async {
      // A room's file row: the card beside three 48 dp actions.
      for (final width in [104.0, 90.0, 84.0]) {
        await tester.pumpWidget(
          _app(
            Row(
              children: [
                SizedBox(
                  width: width,
                  child: AttachmentCard(
                    name: 'informe-trimestral-de-lanzamiento.pdf',
                    mimeType: 'application/pdf',
                    sizeLabel: '2,4 MB',
                    onTap: () {},
                  ),
                ),
              ],
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: 'at $width dp');
        expect(
          find.byKey(const ValueKey('attachment-file-card-open')),
          findsOneWidget,
        );
      }
    });

    testWidgets('a file that cannot open has no chevron', (tester) async {
      await tester.pumpWidget(
        _app(
          const AttachmentCard(
            name: 'notas.txt',
            mimeType: 'text/plain',
            sizeLabel: '3 KB',
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('attachment-file-card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('attachment-file-card-open')),
        findsNothing,
      );
    });
  });

  group('link card (L2)', () {
    testWidgets('a paragraph that is only a link becomes its card', (
      tester,
    ) async {
      final taps = <String?>[];
      await tester.pumpWidget(
        _app(
          ChatMarkdownBlock(
            data:
                'Aquí está:\n\n'
                '[Lista de lanzamiento · Aurora](https://www.docs.aurora.app/x)'
                '\n\nfin',
            embeds: true,
            onLinkTap: taps.add,
          ),
        ),
      );
      expect(find.byType(ChatLinkCard), findsOneWidget);
      expect(find.text('Lista de lanzamiento · Aurora'), findsOneWidget);
      // The domain, never an invented reading time.
      expect(find.text('docs.aurora.app'), findsOneWidget);
      expect(find.textContaining('min'), findsNothing);
      expect(find.textContaining('Aquí está'), findsOneWidget);
      expect(find.textContaining('fin'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chat-link-card')));
      expect(taps, ['https://www.docs.aurora.app/x']);
    });

    testWidgets('screen readers hear a link with its title and domain', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _app(
            const ChatMarkdownBlock(
              data: 'https://example.com/a',
              embeds: true,
            ),
          ),
        );
        expect(
          tester.getSemantics(find.byType(ChatLinkCard)),
          isSemantics(
            label: 'https://example.com/a',
            value: 'example.com',
            isLink: true,
            hasTapAction: true,
          ),
        );
      } finally {
        handle.dispose();
      }
    });

    test('inline links, code, players and unsafe schemes stay text', () {
      expect(splitStandaloneLinks('Mira [esto](https://a.example) ya'), isNull);
      expect(
        splitStandaloneLinks('```\nhttps://a.example\n```'),
        isNull,
      );
      expect(
        splitStandaloneLinks('Mira:\n\nhttps://youtu.be/dQw4w9WgXcQ'),
        isNull,
      );
      expect(splitStandaloneLinks('[x](javascript:alert(1))'), isNull);
      expect(splitStandaloneLinks('- [x](https://a.example)'), isNull);
      final parts = splitStandaloneLinks(
        'uno\n\nhttps://a.example/p\n\n[dos](https://b.example)',
      )!;
      expect(parts, hasLength(3));
      expect((parts[0] as ChatLinkTextPart).markdown, 'uno');
      expect((parts[1] as ChatLinkCardPart).url.host, 'a.example');
      expect((parts[2] as ChatLinkCardPart).title, 'dos');
    });

    test('the title reads as text, without Markdown marks (#20)', () {
      expect(plainLinkTitle('**Docs**'), 'Docs');
      expect(
        plainLinkTitle('Guía de *Aurora* y `cli`'),
        'Guía de Aurora y cli',
      );
      expect(plainLinkTitle('~~viejo~~ _nuevo_'), 'viejo nuevo');
      expect(plainLinkTitle(r'precio \*5\*'), 'precio *5*');
      expect(plainLinkTitle('snake_case_name'), 'snake_case_name');
      final parts = splitStandaloneLinks('[**Docs**](https://a.example)')!;
      expect((parts.single as ChatLinkCardPart).title, 'Docs');
    });

    test('lists, references and indented code are never cut', () {
      // REVIEW-R5-B #7: the URL belongs to item 1 of a loose list.
      expect(
        splitStandaloneLinks('1. Docs\n\n   https://a.example\n\n2. API'),
        isNull,
      );
      // Reference links would stop resolving across parts.
      expect(
        splitStandaloneLinks(
          'Ver [guía][1].\n\nhttps://a.example\n\n[1]: https://b.example',
        ),
        isNull,
      );
      // An indented code block that starts a part keeps its indentation.
      final parts = splitStandaloneLinks(
        'https://a.example\n\n    codigo sangrado\n    otra linea',
      )!;
      expect(parts, hasLength(2));
      expect(
        (parts[1] as ChatLinkTextPart).markdown,
        '    codigo sangrado\n    otra linea',
      );
    });

    testWidgets('a streaming reply keeps the link as text', (tester) async {
      await tester.pumpWidget(
        _app(const ChatMarkdownBlock(data: 'https://example.com/a')),
      );
      expect(find.byType(ChatLinkCard), findsNothing);
    });
  });
}
