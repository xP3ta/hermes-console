import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/render/companion_status_indicator.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/companion/models/companion_mood.dart';
import 'package:hermes_android/core/widgets/message_avatar_header.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _app(
  Widget child, {
  ThemeData? theme,
  double textScale = 1,
  bool reduceMotion = true,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: const [
    Strings.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: Strings.supportedLocales,
  theme: theme ?? AppTheme.hermesRedDark,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduceMotion,
      textScaler: TextScaler.linear(textScale),
    ),
    child: home!,
  ),
  home: Scaffold(
    body: Padding(padding: const EdgeInsets.all(12), child: child),
  ),
);

Widget _subtitle() => Builder(
  builder: (context) => Text(
    'Pensó durante 1:12',
    key: const ValueKey('fake-summary'),
    style: TextStyle(
      fontSize: 11.5,
      color: Theme.of(context).hermes.textSecondary,
    ),
  ),
);

Widget _header({
  bool mascot = true,
  bool subtitle = true,
  List<Widget> actions = const [],
}) => MessageAvatarHeader(
  name: 'HERMES CONSOLE',
  mascot: mascot
      ? const CompanionStatusIndicator(
          key: ValueKey('assistant-header-companion'),
          companion: null,
          mood: CompanionMood.thinking,
          size: kAvatarMascotSize,
          animate: false,
        )
      : null,
  subtitle: subtitle ? _subtitle() : null,
  actions: actions,
);

void main() {
  testWidgets('la mascota va suelta: sin disco, sin anillo y sin arco', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_header(), reduceMotion: false));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('assistant-header-companion')),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('assistant-header-companion'))),
      const Size(kAvatarMascotSize, kAvatarMascotSize),
    );
    // Nada circular alrededor de la mascota.
    expect(find.byKey(const ValueKey('assistant-avatar-chip')), findsNothing);
    expect(find.byKey(const ValueKey('assistant-avatar-ring')), findsNothing);
    expect(
      find.byKey(const ValueKey('assistant-avatar-live-arc')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(MessageAvatarHeader),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
    final circles = find.descendant(
      of: find.byType(MessageAvatarHeader),
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            (w.decoration is BoxDecoration) &&
            (w.decoration as BoxDecoration).shape == BoxShape.circle,
      ),
    );
    expect(circles, findsNothing);
  });

  testWidgets('el título conserva el color de acento del tema', (tester) async {
    for (final id in ['dark', 'claude-light', 'ember']) {
      final theme = AppTheme.fromId(id);
      await tester.pumpWidget(_app(_header(), theme: theme));
      // El cambio de tema se anima: se deja terminar antes de leer el color.
      await tester.pump(const Duration(seconds: 1));
      final title = tester.widget<Text>(
        find.byKey(const ValueKey('assistant-header-name')),
      );
      expect(title.data, 'Hermes Console');
      expect(title.style!.color, theme.hermes.accent, reason: id);
    }
  });

  // ct1215: a chat with one speaker gives the header no face; then there
  // is no slot and no letter in its place.
  testWidgets(
    'sin cara no hay hueco ni inicial: el nombre empieza en el borde',
    (tester) async {
      await tester.pumpWidget(_app(_header()));
      await tester.pump();
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('assistant-header-name')))
            .dx,
        tester.getRect(find.byType(MessageAvatarHeader)).left +
            kAvatarSlotWidth,
      );
      await tester.pumpWidget(_app(_header(mascot: false)));
      await tester.pump();
      for (final key in const [
        'assistant-header-companion',
        'assistant-avatar-slot',
        'assistant-avatar-initial',
        'assistant-avatar-ring',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      final edge = tester.getRect(find.byType(MessageAvatarHeader)).left;
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('assistant-header-name')))
            .dx,
        edge,
      );
      // The second line hangs from the same edge.
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('fake-summary'))).dx,
        edge,
      );
    },
  );

  testWidgets(
    'de derecha a izquierda: el nombre al inicio, las acciones al final',
    (tester) async {
      await tester.pumpWidget(
        _app(
          Directionality(
            textDirection: TextDirection.rtl,
            child: _header(
              mascot: false,
              actions: const [
                SizedBox(key: ValueKey('act-copy'), width: 48, height: 48),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final header = tester.getRect(find.byType(MessageAvatarHeader));
      expect(
        tester
            .getRect(find.byKey(const ValueKey('assistant-header-name')))
            .right,
        closeTo(header.right, 0.5),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('fake-summary'))).right,
        closeTo(header.right, 0.5),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('act-copy'))).left,
        closeTo(header.left, 0.5),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('la segunda línea es la que pasa el llamador, bajo el título', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_header()));
    await tester.pump();
    final name = tester.getRect(
      find.byKey(const ValueKey('assistant-header-name')),
    );
    final summary = tester.getRect(find.byKey(const ValueKey('fake-summary')));
    expect(summary.top, greaterThanOrEqualTo(name.bottom - 1));
    expect(summary.left, name.left);
    // Ya no hay «modelo · hora» ni el «>_» monoespaciado.
    expect(
      find.byKey(const ValueKey('assistant-header-subtitle')),
      findsNothing,
    );
    expect(find.textContaining('>_'), findsNothing);
    await tester.pumpWidget(_app(_header(subtitle: false)));
    await tester.pump();
    expect(find.byKey(const ValueKey('fake-summary')), findsNothing);
    expect(displayAgentName('Hermes Console'), 'Hermes Console');
    expect(displayAgentName('HERMES CONSOLE'), 'Hermes Console');
    expect(displayAgentName('MyBot'), 'MyBot');
    expect(displayAgentName('hermes'), 'Hermes');
    expect(displayAgentName('  '), 'Hermes');
  });

  testWidgets('las acciones quedan a la derecha', (tester) async {
    await tester.pumpWidget(
      _app(
        _header(
          actions: const [
            SizedBox(key: ValueKey('act-copy'), width: 48, height: 48),
          ],
        ),
      ),
    );
    await tester.pump();
    final name = tester.getRect(
      find.byKey(const ValueKey('assistant-header-name')),
    );
    final action = tester.getRect(find.byKey(const ValueKey('act-copy')));
    expect(action.left, greaterThan(name.right));
    expect(
      action.right,
      closeTo(tester.getRect(find.byType(MessageAvatarHeader)).right, 0.5),
    );
  });

  testWidgets('320 dp con escala 2 sin desbordes y en los 26 temas', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final preset in AppTheme.presets) {
      await tester.pumpWidget(
        _app(
          _header(actions: const [SizedBox(width: 48, height: 48)]),
          theme: AppTheme.fromId(preset.id),
          textScale: 2,
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: preset.id);
    }
  });

  testWidgets('a name in a colour as dark as the page is made legible', (
    tester,
  ) async {
    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
      return (hi + 0.05) / (lo + 0.05);
    }

    Finder named(String name) => find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').toLowerCase() == name,
    );

    for (final theme in [AppTheme.hermesRedDark, AppTheme.hermesRedLight]) {
      final background = theme.hermes.background;
      // A profile's own colour, nearly the page's.
      final own = Color.lerp(background, const Color(0xFF7A1F2B), 0.25)!;
      await tester.pumpWidget(
        _app(
          MessageAvatarHeader(name: 'social-writer', nameColor: own),
          theme: theme,
        ),
      );
      // A theme change animates: let it end before reading the colour.
      await tester.pump(const Duration(seconds: 1));
      final shown = tester.widget<Text>(named('social-writer')).style!.color!;
      expect(contrast(shown, background), greaterThanOrEqualTo(3.0));
    }
    // A colour that already reads is kept as chosen.
    const bright = Color(0xFFFFC14D);
    await tester.pumpWidget(
      _app(const MessageAvatarHeader(name: 'forja', nameColor: bright)),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<Text>(named('forja')).style!.color, bright);
  });
}
