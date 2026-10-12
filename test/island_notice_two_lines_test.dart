// A notice that stays until it is answered carries a title, one action and
// its own way out. On a phone the three do not always fit on the island's
// one line: then the island grows a second line (the title above, the
// action and the ✕ below). The title and the action's label are never cut,
// and the ✕ is always within reach. Seen on a Pixel (QA 9534): "Ya no ne…",
// "Ver cómo quita…" and no visible way to dismiss it.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/floating_chat_header.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _title = 'Ya no necesitas el bridge';
const _body = 'Console habla ahora directamente con Hermes.';
const _action = 'Ver cómo quitarlo';
const _later = 'Ahora no';

final _navigator = GlobalKey<NavigatorState>();

Widget _app(Widget home, {required double textScale}) => MaterialApp(
  navigatorKey: _navigator,
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: true,
      textScaler: TextScaler.linear(textScale),
    ),
    child: child!,
  ),
  home: home,
);

/// A screen without an island: the notice floats in the top lane.
class _Plain extends StatelessWidget {
  const _Plain();

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.expand());
}

/// A chat reduced to its floating header: the notice shows in its island,
/// between the two round buttons.
class _Chat extends StatelessWidget {
  const _Chat();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: FloatingChatHeader(
            leading: FloatingHeaderButton(
              icon: Icons.menu_rounded,
              tooltip: 'Menú',
              onPressed: () {},
            ),
            trailing: FloatingHeaderButton(
              icon: Icons.add_rounded,
              tooltip: 'Nuevo chat',
              onPressed: () {},
            ),
            faces: const SizedBox.shrink(),
            pill: Builder(
              builder: (context) => ChatIsland(
                name: 'Hermes',
                status: IslandStatus.idle,
                events: const [],
                notices: HermesNotice.feedOf(context),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

void _phone(WidgetTester tester, double width) {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = Size(width, 800)
    ..padding = const FakeViewPadding(top: 38)
    ..viewPadding = const FakeViewPadding(top: 38);
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

var _acted = 0;
var _closed = 0;

HermesNoticeHandle? _say({
  String title = _title,
  String action = _action,
  bool showDismiss = true,
}) => HermesNotice.ofNavigator(_navigator.currentState)!.show(
  id: 'stays-until-answered',
  icon: Icons.check_circle_outline_rounded,
  title: title,
  message: _body,
  priority: HermesNoticePriority.high,
  sticky: true,
  showDismiss: showDismiss,
  dismissLabel: _later,
  action: HermesNoticeAction(label: action, onPressed: () => _acted++),
  onClosed: () => _closed++,
);

Finder _key(String key) => find.byKey(ValueKey(key));
Finder get _dismiss => _key('island-event-dismiss');
Finder get _twoLines => _key('island-event-two-lines');

/// The drawn text is all of [text]: no line was dropped, nothing ellipsised.
void _expectWhole(WidgetTester tester, Finder text, String reason) {
  final paragraph = tester.renderObject<RenderParagraph>(text);
  expect(paragraph.didExceedMaxLines, isFalse, reason: reason);
}

/// Title and action whole, the ✕ on screen and answering a tap.
void _expectReadable(WidgetTester tester, double width, String where) {
  expect(tester.takeException(), isNull, reason: where);
  _expectWhole(tester, _key('island-event-line'), '$where: title');
  _expectWhole(tester, find.text(_action), '$where: action');
  final screen = Rect.fromLTWH(0, 0, width, 800);
  for (final finder in [
    _key('island-event-line'),
    _key('hermes-notice-action'),
    _dismiss,
  ]) {
    expect(finder.hitTestable(), findsOneWidget, reason: where);
    final rect = tester.getRect(finder);
    expect(
      screen.contains(rect.topLeft) && screen.contains(rect.bottomRight),
      isTrue,
      reason: '$where: $rect leaves the screen',
    );
  }
  // A 48 dp target with its words for a screen reader.
  expect(tester.getSize(_dismiss), const Size(48, 48), reason: where);
  final spoken = tester.widget<Semantics>(
    find.ancestor(of: _dismiss, matching: find.byType(Semantics)).first,
  );
  expect(spoken.properties.label, _later, reason: where);
  expect(spoken.properties.button, isTrue, reason: where);
}

void main() {
  setUp(() {
    _acted = 0;
    _closed = 0;
  });

  for (final width in [360.0, 412.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('top lane, $width dp wide at ${scale}x: title and action '
          'whole, the dismiss within reach', (tester) async {
        _phone(tester, width);
        await tester.pumpWidget(_app(const _Plain(), textScale: scale));
        _say();
        await _settle(tester);

        _expectReadable(tester, width, 'lane $width@$scale');
        // The three did not fit on one line: the island took a second.
        expect(_twoLines, findsOneWidget);
        final title = tester.getRect(_key('island-event-line'));
        expect(
          tester.getRect(_key('hermes-notice-action')).top,
          greaterThanOrEqualTo(title.bottom),
        );

        await tester.tap(_dismiss);
        await _settle(tester);
        expect(find.text(_title), findsNothing);
        expect(_closed, 1);
        expect(_acted, 0);
      });

      testWidgets('a chat\'s island, $width dp wide at ${scale}x: title and '
          'action whole, the dismiss within reach', (tester) async {
        _phone(tester, width);
        await tester.pumpWidget(_app(const _Chat(), textScale: scale));
        _say();
        await _settle(tester);

        _expectReadable(tester, width, 'island $width@$scale');
        expect(_twoLines, findsOneWidget);

        await tester.tap(_key('hermes-notice-action'));
        await _settle(tester);
        expect(_acted, 1);
      });
    }
  }

  testWidgets('what the notice is about is one tap away, with the action '
      'and the dismiss still there', (tester) async {
    _phone(tester, 360);
    await tester.pumpWidget(_app(const _Plain(), textScale: 2));
    _say();
    await _settle(tester);
    expect(find.text(_body), findsNothing);

    await tester.tap(_key('island-event-line'));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text(_body), findsOneWidget);
    expect(find.text(_action).hitTestable(), findsOneWidget);
    expect(_dismiss.hitTestable(), findsOneWidget);

    await tester.tap(_dismiss);
    await _settle(tester);
    expect(find.text(_title), findsNothing);
    expect(_closed, 1);
  });

  testWidgets('a title and an action that fit keep the island\'s one line, '
      'with the dismiss at its end', (tester) async {
    _phone(tester, 412);
    await tester.pumpWidget(_app(const _Plain(), textScale: 1));
    _say(title: 'Un paso', action: 'Entrar');
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(_twoLines, findsNothing);
    expect(_dismiss.hitTestable(), findsOneWidget);
    final title = tester.getRect(find.text('Entrar'));
    final dismiss = tester.getRect(_dismiss);
    expect(dismiss.left, greaterThanOrEqualTo(title.right));
    expect(dismiss.center.dy, closeTo(title.center.dy, 1));

    await tester.tap(_dismiss);
    await _settle(tester);
    expect(_closed, 1);
  });

  testWidgets('a notice that did not ask for a dismiss stays as it was: one '
      'line, no ✕', (tester) async {
    _phone(tester, 360);
    await tester.pumpWidget(_app(const _Plain(), textScale: 1));
    _say(showDismiss: false);
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(_twoLines, findsNothing);
    expect(_dismiss, findsNothing);
    expect(
      tester.getSize(_key('island-event')).height,
      IslandMetrics.eventHeight,
    );
  });
}
