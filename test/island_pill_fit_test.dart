// The island's line at rest in narrow headers (1.4.0, REPORT-PILL). On a
// Fold chat panel of ~330 dp the pill read «0:08 · 2 en marcha»: the count
// touched the pill's right edge after a wide gap behind the dot, the timer
// was big and grey and the count small and amber, the transcript showed
// through the pill and the face stood over its edge.
//
// Measured with the app's own font (Inter), on a phone of 360 dp and on a
// 330 dp panel with «Vistas», at text ×1 and ×2, in both themes, with a
// count of one and of three digits and timers of 0:08, 12:34 and 1:02:03.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _statusBar = 24.0;

Finder _key(String key) => find.byKey(ValueKey(key));

void _view(WidgetTester tester, double width) {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = Size(width, 800)
    ..padding = const FakeViewPadding(top: _statusBar)
    ..viewPadding = const FakeViewPadding(top: _statusBar);
  addTearDown(tester.view.reset);
}

Widget _app({
  required ThemeData theme,
  required double textScale,
  required bool views,
  required String mark,
  required String elapsed,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: theme,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: true,
      textScaler: TextScaler.linear(textScale),
    ),
    child: child!,
  ),
  home: Scaffold(
    body: Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: FloatingChatHeader(
            leading: FloatingHeaderButton(
              key: const ValueKey('list'),
              icon: Icons.view_sidebar_outlined,
              tooltip: 'Lista',
              onPressed: () {},
            ),
            trailing: FloatingHeaderButton(
              key: const ValueKey('new'),
              icon: Icons.add_rounded,
              tooltip: 'Nuevo chat',
              onPressed: () {},
            ),
            trailingSecondary: views
                ? FloatingHeaderButton(
                    key: const ValueKey('views'),
                    icon: Icons.view_column_outlined,
                    tooltip: 'Vistas',
                    onPressed: () {},
                  )
                : null,
            faces: const SizedBox.square(
              key: ValueKey('face'),
              dimension: FloatingChatHeader.faceSize,
            ),
            pill: ChatIsland(
              name: 'Hermes',
              status: IslandStatus.working,
              mark: mark,
              elapsed: elapsed,
              hint: 'Ver',
              onTap: () {},
            ),
          ),
        ),
      ],
    ),
  ),
);

/// How much smaller than its size [text] is drawn (1: not at all).
double _drawnScale(WidgetTester tester, Finder text) =>
    tester.getRect(text).height /
    tester.renderObject<RenderBox>(text).size.height;

/// [text] is laid out whole: as wide as it asks to be.
void _expectWhole(WidgetTester tester, Finder text) {
  final paragraph = tester.renderObject<RenderParagraph>(text);
  expect(
    paragraph.size.width,
    greaterThanOrEqualTo(paragraph.getMaxIntrinsicWidth(double.infinity) - 0.5),
    reason: paragraph.text.toPlainText(),
  );
}

void main() {
  setUpAll(() async {
    final inter = FontLoader('Inter')
      ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await inter.load();
  });

  final themes = {
    'oscuro': AppTheme.hermesRedDark,
    'claro': AppTheme.hermesRedLight,
  };
  const surfaces = [
    ('móvil 360', 360.0, false),
    ('panel 330 con «Vistas»', 330.0, true),
  ];
  for (final (surface, width, views) in surfaces) {
    for (final textScale in const [1.0, 2.0]) {
      for (final MapEntry(key: themeName, value: theme) in themes.entries) {
        for (final mark in const ['1 en marcha', '123 en marcha']) {
          for (final elapsed in const ['0:08', '12:34', '1:02:03']) {
            testWidgets(
              '$surface, texto ×$textScale, tema $themeName, «$mark · '
              '$elapsed»: una frase en un tamaño, entera, sin desbordar y con '
              'el mismo margen (≥ 12 dp) a los dos lados',
              (tester) async {
                _view(tester, width);
                await tester.pumpWidget(
                  _app(
                    theme: theme,
                    textScale: textScale,
                    views: views,
                    mark: mark,
                    elapsed: elapsed,
                  ),
                );
                await tester.pump();
                expect(tester.takeException(), isNull);

                final island = tester.getRect(_key('island'));
                final count = _key('island-mark');
                final timer = _key('activity-pill-elapsed');
                final name = _key('island-name');
                final chevron = tester.getRect(_key('island-chevron'));
                // the owner (gint72): no state dot; the line opens with the name,
                // or with the count when the name has left.
                expect(
                  find.descendant(
                    of: _key('island'),
                    matching: _key('island-dot-working'),
                  ),
                  findsNothing,
                );
                final first = tester.getRect(
                  name.evaluate().isNotEmpty ? name : count,
                );

                // Between its buttons, never under them.
                expect(
                  island.left,
                  greaterThanOrEqualTo(tester.getRect(_key('list')).right),
                );
                expect(
                  island.right,
                  lessThanOrEqualTo(
                    tester.getRect(_key(views ? 'views' : 'new')).left,
                  ),
                );

                // The content does not touch the edge: the same room on both
                // sides, at least 12 dp.
                final before = first.left - island.left;
                final after = island.right - chevron.right;
                expect(after, greaterThanOrEqualTo(12));
                expect(before, greaterThanOrEqualTo(12));
                expect((before - after).abs(), lessThan(1));

                // The count is whole, after the name (when it stays) and
                // before the chevron.
                _expectWhole(tester, count);
                final countRect = tester.getRect(count);
                if (name.evaluate().isNotEmpty) {
                  expect(
                    countRect.left,
                    greaterThan(tester.getRect(name).right),
                  );
                }
                expect(countRect.right, lessThanOrEqualTo(chevron.left));
                final countText = tester.widget<Text>(count);
                final size = countText.style!.fontSize!;

                // One size: the name, when it stays, is that size too; when
                // it does not, the count opens the line with no gap before it.
                if (name.evaluate().isNotEmpty) {
                  expect(tester.widget<Text>(name).style!.fontSize, size);
                } else {
                  expect(countRect.left - island.left, closeTo(after, 1));
                }

                // The timer, when it is said, is the last words of the same
                // phrase: whole, the count's size and weight, tabular
                // figures, told apart only by its colour.
                if (timer.evaluate().isNotEmpty) {
                  _expectWhole(tester, timer);
                  final timerRect = tester.getRect(timer);
                  expect(timerRect.left, greaterThan(countRect.right));
                  expect(timerRect.right, lessThanOrEqualTo(chevron.left));
                  final timerText = tester.widget<Text>(timer);
                  expect(timerText.style!.fontSize, size);
                  expect(timerText.style!.fontWeight, countText.style!.fontWeight);
                  expect(
                    timerText.style!.fontFeatures,
                    contains(const FontFeature.tabularFigures()),
                  );
                  expect(timerText.style!.color, isNot(countText.style!.color));
                  expect(
                    _drawnScale(tester, timer),
                    closeTo(_drawnScale(tester, count), 0.001),
                  );
                } else {
                  // It gives way only after the name.
                  expect(name, findsNothing);
                }

                // Readable: never drawn under 11 dp.
                final drawn =
                    size *
                    math.min(textScale, FloatingChatHeader.maxTextScale) *
                    _drawnScale(tester, count);
                expect(drawn, greaterThanOrEqualTo(11));

                // Solid: nothing of the chat shows through.
                final surfaceMaterial = tester.widget<Material>(
                  find
                      .descendant(
                        of: _key('island'),
                        matching: find.byType(Material),
                      )
                      .first,
                );
                final chrome = HermesChrome.of(theme.hermes);
                expect(surfaceMaterial.color, chrome.opaque);
                expect(surfaceMaterial.color!.a, 1.0);

                // The face is perched on the island's edge: it reaches the
                // pill's own top padding (FloatingChatHeader.faceOverlap) and
                // never the line.
                final faceBottom = tester.getRect(_key('face')).bottom;
                expect(
                  faceBottom,
                  lessThanOrEqualTo(
                    island.top + FloatingChatHeader.faceOverlap + 0.01,
                  ),
                );
                expect(
                  faceBottom,
                  lessThanOrEqualTo(first.top + 0.01),
                  reason: 'the face never covers the line',
                );
              },
            );
          }
        }
      }
    }
  }

  for (final (width, named) in const [(360.0, false), (412.0, true)]) {
    testWidgets('a phone of ${width.round()} dp says «${named ? 'Hermes · ' : ''}'
        '1 en marcha · 0:08» at its size, in that order', (
      tester,
    ) async {
      _view(tester, width);
      await tester.pumpWidget(
        _app(
          theme: AppTheme.hermesRedDark,
          textScale: 1,
          views: false,
          mark: '1 en marcha',
          elapsed: '0:08',
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      // At 360 dp the name gives way (whole, or to its first letter); at
      // 412 dp it is said whole.
      final name = _key('island-name');
      if (named) {
        expect(name, findsOneWidget);
        expect(
          tester.renderObject<RenderParagraph>(name).didExceedMaxLines,
          isFalse,
        );
      }
      expect(_key('activity-pill-elapsed'), findsOneWidget);
      expect(_drawnScale(tester, _key('island-mark')), 1);
      expect(_key('island-dot-working'), findsNothing);
      final xs = [
        if (name.evaluate().isNotEmpty) tester.getCenter(name).dx,
        tester.getCenter(_key('island-mark')).dx,
        tester.getCenter(_key('activity-pill-elapsed')).dx,
        tester.getCenter(_key('island-chevron')).dx,
      ];
      expect(xs, [...xs]..sort());
      expect(tester.getRect(_key('island')).center.dx, closeTo(width / 2, 0.5));
    });
  }

  testWidgets('a 330 dp panel with «Vistas»: the island centres between its '
      'buttons and keeps the count at its size', (tester) async {
    _view(tester, 330);
    await tester.pumpWidget(
      _app(
        theme: AppTheme.hermesRedDark,
        textScale: 1,
        views: true,
        mark: '2 en marcha',
        elapsed: '0:08',
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    final island = tester.getRect(_key('island'));
    final left = tester.getRect(_key('list')).right;
    final right = tester.getRect(_key('views')).left;
    // Centred on the room between the buttons, not on the panel: the room
    // of three buttons on both sides would leave it under 102 dp. Vistas
    // v3: the two right buttons stand apart (pairWidth, 104 dp).
    const rightRoom = 8 + FloatingChatHeader.pairWidth + 6;
    expect(island.center.dx, closeTo((8 + 48 + 6 + (330 - rightRoom)) / 2, 1));
    expect(island.left, greaterThanOrEqualTo(left));
    expect(island.right, lessThanOrEqualTo(right));
    expect(island.width, greaterThan(102));
    expect(_drawnScale(tester, _key('island-mark')), 1);
  });
}
