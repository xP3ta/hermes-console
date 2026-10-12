// mc1215: comfortable code reading on phones — wrap, font size, find in
// file, one-tap copy/share, thumb-reachable action bar, chat code block
// header and readable diffs.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_viewer_screen.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/code_view_prefs.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/core/widgets/chat/tool_output_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size _phone = Size(390, 844);
const Size _tablet = Size(800, 1280);

void main() {
  final theme = AppTheme.fromMode(AppThemeMode.dark);
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    await CodeViewPrefs.load(prefs);
  });
  tearDown(() => CodeViewPrefs.debugUse(null));

  void useSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget host(String name, String body, {VoidCallback? onShare}) => MaterialApp(
    theme: theme,
    locale: const Locale('en'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: ArtifactViewerScreen(
      name: name,
      mimeType: 'text/plain',
      loadBytes: () async => Uint8List.fromList(utf8.encode(body)),
      onShare: onShare,
    ),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Finder gutter(int i) => find.byKey(ValueKey('artifact-viewer-gutter-$i'));
  Finder line(int i, [int chunk = 0]) => find.byKey(
    ValueKey(
      chunk == 0 ? 'artifact-viewer-line-$i' : 'artifact-viewer-line-$i-$chunk',
    ),
  );
  final horizontal = find.byWidgetPredicate(
    (w) => w is Scrollable && w.axisDirection == AxisDirection.right,
  );

  String plain(WidgetTester tester, Finder f) =>
      tester.widget<Text>(f).textSpan?.toPlainText() ??
      tester.widget<Text>(f).data!;

  /// Plain text of every rendered row of logical line [i], in order.
  String rowsOf(WidgetTester tester, int i) {
    final buffer = StringBuffer(plain(tester, line(i)));
    for (var k = 1; line(i, k).evaluate().isNotEmpty; k++) {
      buffer.write(plain(tester, line(i, k)));
    }
    return buffer.toString();
  }

  void mockClipboard(WidgetTester tester, void Function(String?) onCopy) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          onCopy((call.arguments as Map)['text'] as String?);
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
  }

  group('preferences', () {
    test(
      'wrap defaults on for phones, off for tablets, and persists',
      () async {
        final store = CodeViewPrefs.shared;
        expect(store.wrapFor(390), isTrue);
        expect(store.wrapFor(599), isTrue);
        expect(store.wrapFor(600), isFalse);
        await store.setWrap(false);
        expect(prefs.getBool(CodeViewPrefs.wrapKey), isFalse);
        final reloaded = await CodeViewPrefs.load(prefs);
        expect(reloaded.wrapFor(390), isFalse);
      },
    );

    test('font scale stays within 0.8x–1.6x and persists', () async {
      final store = CodeViewPrefs.shared;
      expect(store.fontScale, 1.0);
      await store.setFontScale(5);
      expect(store.fontScale, CodeViewPrefs.maxFontScale);
      await store.stepFont(1);
      expect(store.fontScale, 1.6);
      await store.setFontScale(0.1);
      expect(store.fontScale, 0.8);
      await store.stepFont(-1);
      expect(store.fontScale, 0.8);
      await store.stepFont(1);
      expect(store.fontScale, closeTo(0.9, 1e-9));
      final reloaded = await CodeViewPrefs.load(prefs);
      expect(reloaded.fontScale, closeTo(0.9, 1e-9));
    });

    test('the system scale multiplies the viewer scale within limits', () {
      expect(CodeViewPrefs.effectiveScale(system: 1.0, user: 1.2), 1.2);
      expect(CodeViewPrefs.effectiveScale(system: 1.5, user: 1.2), 1.8);
      expect(
        CodeViewPrefs.effectiveScale(system: 3.0, user: 1.6),
        CodeViewPrefs.maxEffectiveScale,
      );
      expect(CodeViewPrefs.effectiveScale(system: 0.85, user: 0.8), 0.8);
    });
  });

  group('wrap', () {
    testWidgets('phones wrap long lines; only the first row is numbered', (
      tester,
    ) async {
      useSize(tester, _phone);
      final long = List.generate(30, (i) => 'word$i').join(' ');
      await tester.pumpWidget(
        host('a.txt', ['short', long, 'tail'].join('\n')),
      );
      await settle(tester);

      expect(horizontal, findsNothing, reason: 'no sideways scroll when wrap');
      expect(line(1, 1), findsOneWidget, reason: 'line 1 wraps');
      expect(rowsOf(tester, 1), long, reason: 'rows rebuild the exact line');
      for (final i in [0, 1, 2]) {
        expect(tester.widget<Text>(gutter(i)).data, '${i + 1}');
        expect(tester.getTopLeft(gutter(i)).dy, tester.getTopLeft(line(i)).dy);
      }
      // Continuation rows carry no number: the next number is line 3's.
      final lastChunk = find.byWidgetPredicate((w) {
        final k = w.key;
        return k is ValueKey<String> &&
            k.value.startsWith('artifact-viewer-line-1-');
      });
      final bottomOfLine1 = tester.getRect(lastChunk.last).bottom;
      expect(tester.getTopLeft(gutter(2)).dy, closeTo(bottomOfLine1, 0.5));
      final gutters = find.byWidgetPredicate((w) {
        final k = w.key;
        return k is ValueKey<String> &&
            k.value.startsWith('artifact-viewer-gutter-');
      });
      expect(gutters.evaluate().length, 3);
      // Every row stays inside the screen width and paints whole: nothing
      // is clipped at the right edge.
      for (var k = 0; line(1, k).evaluate().isNotEmpty; k++) {
        expect(tester.getRect(line(1, k)).right, lessThanOrEqualTo(390));
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: line(1, k), matching: find.byType(RichText)),
        );
        expect(
          paragraph.getMaxIntrinsicWidth(double.infinity),
          lessThanOrEqualTo(paragraph.size.width + 0.5),
          reason: 'row $k of line 1 is not clipped',
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('tablets keep one row per line with sideways scroll', (
      tester,
    ) async {
      useSize(tester, _tablet);
      final long = 'x' * 400;
      await tester.pumpWidget(host('a.txt', ['short', long].join('\n')));
      await settle(tester);
      expect(horizontal, findsOneWidget);
      expect(line(1, 1), findsNothing);
      expect(plain(tester, line(1)), long);
    });

    testWidgets('the wrap toggle switches modes and persists the choice', (
      tester,
    ) async {
      useSize(tester, _phone);
      final long = 'y' * 400;
      await tester.pumpWidget(host('a.txt', ['short', long].join('\n')));
      await settle(tester);
      expect(horizontal, findsNothing);

      await tester.tap(find.byKey(const ValueKey('artifact-viewer-wrap')));
      await settle(tester);
      expect(horizontal, findsOneWidget);
      expect(line(1, 1), findsNothing);
      expect(prefs.getBool(CodeViewPrefs.wrapKey), isFalse);

      await tester.tap(find.byKey(const ValueKey('artifact-viewer-wrap')));
      await settle(tester);
      expect(horizontal, findsNothing);
      expect(prefs.getBool(CodeViewPrefs.wrapKey), isTrue);
    });

    testWidgets('a 100k-line file builds only the visible wrapped rows', (
      tester,
    ) async {
      useSize(tester, _phone);
      final big = List.filled(100000, 'z' * 90).join('\n');
      await tester.pumpWidget(host('huge.txt', big));
      await settle(tester);
      final built = find.byWidgetPredicate((w) {
        final k = w.key;
        return k is ValueKey<String> &&
            k.value.startsWith('artifact-viewer-line-');
      });
      expect(built.evaluate().length, inInclusiveRange(1, 300));
      expect(line(1, 1), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('artifact-viewer-wrap')));
      await settle(tester);
      expect(built.evaluate().length, inInclusiveRange(1, 300));
      expect(tester.takeException(), isNull);
    });
  });

  group('font size', () {
    double scaleOf(WidgetTester tester) {
      final p = tester.renderObject<RenderParagraph>(
        find.descendant(of: line(0), matching: find.byType(RichText)),
      );
      return p.textScaler.scale(10) / 10;
    }

    testWidgets('A+/A− change the code size within bounds and persist', (
      tester,
    ) async {
      useSize(tester, _phone);
      await tester.pumpWidget(host('a.txt', 'alpha\nbeta'));
      await settle(tester);
      expect(scaleOf(tester), closeTo(1.0, 1e-6));

      final up = find.byKey(const ValueKey('artifact-viewer-font-up'));
      final down = find.byKey(const ValueKey('artifact-viewer-font-down'));
      await tester.tap(up);
      await settle(tester);
      expect(scaleOf(tester), closeTo(1.1, 1e-6));
      for (var i = 0; i < 10; i++) {
        await tester.tap(up);
        await settle(tester);
      }
      expect(scaleOf(tester), closeTo(1.6, 1e-6));
      expect(prefs.getDouble(CodeViewPrefs.fontScaleKey), closeTo(1.6, 1e-9));
      // The number gutter grows with the code.
      expect(
        tester
                .renderObject<RenderParagraph>(
                  find.descendant(
                    of: gutter(0),
                    matching: find.byType(RichText),
                  ),
                )
                .textScaler
                .scale(10) /
            10,
        closeTo(1.6, 1e-6),
      );
      for (var i = 0; i < 12; i++) {
        await tester.tap(down);
        await settle(tester);
      }
      expect(scaleOf(tester), closeTo(0.8, 1e-6));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the system text scale multiplies the viewer scale', (
      tester,
    ) async {
      useSize(tester, _phone);
      await CodeViewPrefs.shared.setFontScale(1.2);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: _phone,
            textScaler: TextScaler.linear(1.5),
          ),
          child: host('a.txt', 'alpha'),
        ),
      );
      await settle(tester);
      expect(scaleOf(tester), closeTo(1.8, 1e-6));
    });
  });

  group('find in file', () {
    testWidgets('count, next/prev and scroll-into-view with wrapped rows', (
      tester,
    ) async {
      useSize(tester, _phone);
      // Every line wraps into several rows; matches sit late in their line.
      final lines = [
        for (var i = 0; i < 300; i++)
          i == 40 || i == 150 || i == 290
              ? '${'a' * 170} NEEDLE$i tail'
              : 'b' * 190,
      ];
      await tester.pumpWidget(host('w.txt', lines.join('\n')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('artifact-viewer-search')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('artifact-viewer-search-field')),
        'needle',
      );
      await settle(tester);
      final count = find.byKey(const ValueKey('artifact-viewer-search-count'));
      expect(tester.widget<Text>(count).data, '1 of 3');

      final viewport = tester.getRect(
        find.byKey(const ValueKey('artifact-viewer-text')),
      );
      void expectVisible(int n) {
        final hit = find.byWidgetPredicate(
          (w) =>
              w is Text &&
              (w.textSpan?.toPlainText() ?? w.data ?? '').contains('NEEDLE$n'),
        );
        expect(hit, findsOneWidget, reason: 'row with match $n is built');
        final rect = tester.getRect(hit);
        expect(rect.top, greaterThanOrEqualTo(viewport.top - 0.5));
        expect(rect.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
      }

      expectVisible(40);
      await tester.tap(
        find.byKey(const ValueKey('artifact-viewer-search-next')),
      );
      await settle(tester);
      expect(tester.widget<Text>(count).data, '2 of 3');
      expectVisible(150);
      await tester.tap(
        find.byKey(const ValueKey('artifact-viewer-search-next')),
      );
      await settle(tester);
      expect(tester.widget<Text>(count).data, '3 of 3');
      expectVisible(290);
      await tester.tap(
        find.byKey(const ValueKey('artifact-viewer-search-next')),
      );
      await settle(tester);
      expect(tester.widget<Text>(count).data, '1 of 3');
      await tester.tap(
        find.byKey(const ValueKey('artifact-viewer-search-prev')),
      );
      await settle(tester);
      expect(tester.widget<Text>(count).data, '3 of 3');
      expectVisible(290);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a match split across two wrapped rows stays highlighted', (
      tester,
    ) async {
      useSize(tester, _phone);
      // Long unbroken run: the row break falls inside the word.
      final body = '${'c' * 20}NEEDLE${'c' * 200}';
      await tester.pumpWidget(host('w.txt', body));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('artifact-viewer-search')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('artifact-viewer-search-field')),
        'needle',
      );
      await settle(tester);
      final highlighted = StringBuffer();
      for (var k = 0; line(0, k).evaluate().isNotEmpty; k++) {
        tester.widget<Text>(line(0, k)).textSpan!.visitChildren((span) {
          if (span is TextSpan &&
              span.style?.backgroundColor != null &&
              span.text != null) {
            highlighted.write(span.text);
          }
          return true;
        });
      }
      expect(highlighted.toString(), 'NEEDLE');
      expect(rowsOf(tester, 0), body);
    });
  });

  group('actions', () {
    testWidgets('phones get a bottom action bar; tablets keep the app bar', (
      tester,
    ) async {
      useSize(tester, _phone);
      await tester.pumpWidget(host('a.txt', 'alpha', onShare: () {}));
      await settle(tester);
      final bar = find.byKey(const ValueKey('artifact-viewer-actions'));
      expect(bar, findsOneWidget);
      for (final key in [
        'artifact-viewer-search',
        'artifact-viewer-wrap',
        'artifact-viewer-font-down',
        'artifact-viewer-font-up',
        'artifact-viewer-copy',
        'artifact-viewer-share',
      ]) {
        final f = find.byKey(ValueKey(key));
        expect(f, findsOneWidget, reason: key);
        expect(find.descendant(of: bar, matching: f), findsOneWidget);
        final size = tester.getSize(f);
        expect(size.width, greaterThanOrEqualTo(48), reason: key);
        expect(size.height, greaterThanOrEqualTo(48), reason: key);
      }
      expect(tester.getRect(bar).bottom, closeTo(_phone.height, 0.5));

      useSize(tester, _tablet);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(host('a.txt', 'alpha', onShare: () {}));
      await settle(tester);
      expect(bar, findsNothing);
      expect(
        find.byKey(const ValueKey('artifact-viewer-search')),
        findsOneWidget,
      );
      expect(
        tester
            .getRect(find.byKey(const ValueKey('artifact-viewer-search')))
            .top,
        lessThan(100),
      );
    });

    testWidgets('the bar respects the safe area and the keyboard', (
      tester,
    ) async {
      useSize(tester, _phone);
      tester.view.padding = const FakeViewPadding(bottom: 24);
      await tester.pumpWidget(host('a.txt', 'alpha'));
      await settle(tester);
      final bar = find.byKey(const ValueKey('artifact-viewer-actions'));
      expect(
        tester
            .getRect(find.byKey(const ValueKey('artifact-viewer-copy')))
            .bottom,
        lessThanOrEqualTo(_phone.height - 24 + 0.5),
      );
      expect(bar, findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('artifact-viewer-search')));
      await settle(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await settle(tester);
      final field = find.byKey(const ValueKey('artifact-viewer-search-field'));
      expect(field, findsOneWidget);
      expect(
        tester.getRect(field).bottom,
        lessThanOrEqualTo(_phone.height - 300 + 0.5),
        reason: 'the search field sits above the keyboard',
      );
      expect(
        tester.getRect(field).top,
        greaterThan(_phone.height / 2 - 300),
        reason: 'the search field stays near the thumb',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('copy puts the exact file bytes in the clipboard', (
      tester,
    ) async {
      useSize(tester, _phone);
      String? copied;
      mockClipboard(tester, (t) => copied = t);
      const body = 'line one\r\n  indented 42\r\n\tlast\n';
      await tester.pumpWidget(host('a.txt', body));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('artifact-viewer-copy')));
      await settle(tester);
      expect(copied, body);
    });

    testWidgets('share uses the caller when it can share the file', (
      tester,
    ) async {
      useSize(tester, _phone);
      var shared = 0;
      await tester.pumpWidget(host('a.txt', 'alpha', onShare: () => shared++));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('artifact-viewer-share')));
      await settle(tester);
      expect(shared, 1);
    });
  });

  group('chat code blocks', () {
    Widget chat(String md) => MaterialApp(
      theme: AppTheme.hermesRedDark,
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(child: ChatMarkdownBody(data: md)),
      ),
    );

    testWidgets('the header shows language, copy and open in viewer', (
      tester,
    ) async {
      useSize(tester, _phone);
      String? copied;
      mockClipboard(tester, (t) => copied = t);
      await tester.pumpWidget(chat('```python\nalpha()\nbeta()\n```'));
      await settle(tester);
      expect(find.text('python'), findsOneWidget);
      final open = find.byKey(const ValueKey('chat-code-open-viewer'));
      expect(open, findsOneWidget);
      expect(tester.getSize(open).height, greaterThanOrEqualTo(48));
      // Header is compact: one row above the code.
      expect(
        tester.getRect(open).center.dy,
        lessThan(tester.getRect(find.textContaining('alpha()')).top),
      );

      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(find.byType(ArtifactViewerScreen), findsOneWidget);
      expect(
        find.byKey(const ValueKey('artifact-viewer-wrap')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('artifact-viewer-copy')));
      await settle(tester);
      expect(copied, 'alpha()\nbeta()');
    });

    testWidgets('diff fences also open in the full-screen viewer', (
      tester,
    ) async {
      useSize(tester, _phone);
      await tester.pumpWidget(chat('```diff\n@@ -1 +1 @@\n-a\n+b\n```'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('chat-code-open-viewer')));
      await tester.pumpAndSettle();
      expect(find.byType(ArtifactViewerScreen), findsOneWidget);
    });
  });

  group('diffs', () {
    Widget diffHost(Widget child) => MaterialApp(
      theme: AppTheme.hermesRedDark,
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );
    final longAdd = '+${List.generate(40, (i) => 'tok$i').join(' ')}';
    final diff = '@@ -1,2 +1,2 @@\n keep\n-old\n$longAdd';

    Finder stripe(int i) => find.byKey(ValueKey('file-diff-gutter-$i'));

    testWidgets('phones wrap diff lines with a +/- gutter per line', (
      tester,
    ) async {
      useSize(tester, _phone);
      await tester.pumpWidget(diffHost(FileDiffBody(diff: diff)));
      await settle(tester);
      expect(horizontal, findsNothing);
      final text = find.text(longAdd);
      expect(text, findsOneWidget);
      expect(tester.getRect(text).right, lessThanOrEqualTo(390));
      final lineHeight = tester.getSize(find.text(' keep')).height;
      expect(tester.getSize(text).height, greaterThan(lineHeight * 1.5));
      // The add gutter spans every wrapped row of its line.
      expect(
        tester.getSize(stripe(3)).height,
        closeTo(tester.getSize(text).height, 1),
      );
      final colors = AppTheme.hermesRedDark.hermes;
      Color? colorOf(int i) =>
          (tester.widget<Container>(stripe(i)).decoration as BoxDecoration?)
              ?.color;
      expect(colorOf(3), colors.success);
      expect(colorOf(2), colors.error);
      expect(colorOf(1), isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('without wrap the +/- gutter stays put while scrolling', (
      tester,
    ) async {
      useSize(tester, _phone);
      await tester.pumpWidget(diffHost(FileDiffBody(diff: diff, wrap: false)));
      await settle(tester);
      expect(horizontal, findsOneWidget);
      final before = tester.getRect(stripe(3));
      final textBefore = tester.getRect(find.text(longAdd));
      final position = tester.state<ScrollableState>(horizontal).position;
      position.jumpTo(position.maxScrollExtent);
      await settle(tester);
      expect(tester.getRect(stripe(3)), before);
      expect(
        tester.getRect(find.text(longAdd)).left,
        lessThan(textBefore.left),
      );
      expect(
        tester.getRect(stripe(3)).top,
        closeTo(tester.getRect(find.text(longAdd)).top, 0.5),
      );
    });

    testWidgets('tablets keep the unwrapped diff by default', (tester) async {
      useSize(tester, _tablet);
      await tester.pumpWidget(diffHost(FileDiffBody(diff: diff)));
      await settle(tester);
      expect(horizontal, findsOneWidget);
    });

    testWidgets('the diff follows the saved wrap preference', (tester) async {
      useSize(tester, _phone);
      await CodeViewPrefs.shared.setWrap(false);
      await tester.pumpWidget(diffHost(FileDiffBody(diff: diff)));
      await settle(tester);
      expect(horizontal, findsOneWidget);
    });
  });
}
