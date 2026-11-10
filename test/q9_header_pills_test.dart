// QA 9709 (the owner, captures 2301 and 2303): the header's pills are whole.
//  * 2301: the chat's pair of right buttons was 4 dp taller than a side
//    button, so it reached past the island and the pinned prompt's band,
//    joined under the island, cut its lower edge flat.
//  * 2303: on the open Fold's list column the title gave way down to
//    nothing and the pill was left empty around the connection dot.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _app(Widget home, {double textScale = 1}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('classic-dark'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: true,
      textScaler: TextScaler.linear(textScale),
    ),
    child: child!,
  ),
  home: home,
);

void _size(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.padding = const FakeViewPadding(top: 24);
  tester.view.viewPadding = const FakeViewPadding(top: 24);
  addTearDown(tester.view.reset);
}

Widget _chatHeader() => Scaffold(
  body: Stack(
    children: [
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: FloatingChatHeader(
          faces: const SizedBox.square(dimension: FloatingChatHeader.faceSize),
          leading: FloatingHeaderButton(
            icon: Icons.menu_rounded,
            tooltip: 'Menú',
            onPressed: () {},
          ),
          trailingSecondary: FloatingHeaderButton(
            key: const ValueKey('test-views'),
            icon: Icons.view_column_outlined,
            tooltip: 'Vistas',
            onPressed: () {},
          ),
          trailing: FloatingHeaderButton(
            key: const ValueKey('test-new'),
            icon: Icons.add_rounded,
            tooltip: 'Nuevo chat',
            onPressed: () {},
          ),
          pill: const ChatIsland(
            name: 'Hermes · 2 en marcha',
            status: IslandStatus.working,
          ),
        ),
      ),
    ],
  ),
);

Widget _listHeader() => Scaffold(
  appBar: HermesAppBar(
    titleInPill: true,
    title: const Text('Conversaciones'),
    titleBadge: const SizedBox.square(key: ValueKey('test-dot'), dimension: 8),
    actions: [
      for (final (icon, label) in const [
        (Icons.edit_outlined, 'Nuevo'),
        (Icons.inventory_2_outlined, 'Archivo'),
        (Icons.more_vert, 'Más'),
      ])
        IconButton(icon: Icon(icon), tooltip: label, onPressed: () {}),
    ],
  ),
  drawer: const Drawer(),
);

void main() {
  for (final size in const [Size(390, 844), Size(773, 1024), Size(884, 1000)]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('chat header ${size.width.toInt()} dp, text ${scale}x: the '
          'two right buttons are whole circles, apart, no taller than a side '
          'button', (tester) async {
        _size(tester, size);
        await tester.pumpWidget(_app(_chatHeader(), textScale: scale));
        expect(tester.takeException(), isNull);
        final island = tester.getRect(find.byKey(const ValueKey('island')));
        final views = tester.getRect(find.byKey(const ValueKey('test-views')));
        final add = tester.getRect(find.byKey(const ValueKey('test-new')));
        Rect face(String key) => tester.getRect(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byKey(const ValueKey('floating-header-button-face')),
          ),
        );
        // Vistas v3: two round buttons apart, each as tall as a side
        // button, centred on its 48 dp target.
        for (final (key, target) in [
          ('test-views', views),
          ('test-new', add),
        ]) {
          final circle = face(key);
          expect(circle.height, FloatingChatHeader.buttonSize);
          expect(circle.center.dy, moreOrLessEquals(target.center.dy));
          expect(target.height, greaterThanOrEqualTo(48));
          // Never past where the pinned prompt's band starts, under the
          // island: nothing of the circle can be painted over.
          expect(
            circle.bottom,
            lessThanOrEqualTo(island.bottom + HermesSpace.x1),
            reason: '$key $circle, island $island',
          );
        }
        expect(
          face('test-new').left - face('test-views').right,
          greaterThanOrEqualTo(FloatingChatHeader.pairGap),
        );
      });
    }
  }

  for (final width in [300.0, 320.0, 360.0, 773.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('list header $width dp, text ${scale}x: the title pill '
          'always says what it is; its pieces fit the bar', (tester) async {
        _size(tester, Size(width, 800));
        await tester.pumpWidget(_app(_listHeader(), textScale: scale));
        expect(tester.takeException(), isNull);
        final bar = tester.getRect(find.byType(AppBar));
        final pill = find.byKey(const ValueKey('hermes-app-bar-title'));
        expect(pill, findsOneWidget);
        final title = tester.getRect(find.text('Conversaciones'));
        // Never an empty pill: the title keeps at least a word and its
        // ellipsis (48 dp), or all there is inside the pill.
        final inner = tester.getRect(pill).width - 32;
        expect(
          title.width,
          greaterThanOrEqualTo(inner < 48 ? inner - 1 : 40),
          reason: 'title $title in a pill ${tester.getRect(pill)}',
        );
        final dot = find.byKey(const ValueKey('test-dot'));
        if (dot.evaluate().isNotEmpty) {
          expect(
            tester.getRect(dot).right,
            lessThanOrEqualTo(tester.getRect(pill).right),
          );
        }
        // The surfaces are whole inside the bar: as tall as a piece, never
        // taller than the bar nor cut by it.
        for (final key in ['hermes-app-bar-title', 'hermes-app-bar-actions']) {
          final rect = tester.getRect(find.byKey(ValueKey(key)));
          expect(rect.height, greaterThanOrEqualTo(HermesAppBar.pieceSize));
          expect(rect.top, greaterThanOrEqualTo(bar.top), reason: key);
          expect(rect.bottom, lessThanOrEqualTo(bar.bottom), reason: key);
        }
        expect(
          tester.getRect(find.byKey(const ValueKey('hermes-app-bar-actions'))),
          isA<Rect>().having((r) => r.height, 'height', HermesAppBar.pieceSize),
        );
      });
    }
  }
}
