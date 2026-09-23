import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/render/companion_status_indicator.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_spark_mascot.dart';
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
          mood: HermesSparkMood.thinking,
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

  testWidgets(
    'sin presencia: la inicial en acento, sin círculo y misma geometría',
    (tester) async {
      await tester.pumpWidget(_app(_header()));
      await tester.pump();
      final withMascot = tester.getRect(find.byType(MessageAvatarHeader));
      final nameWith = tester.getTopLeft(
        find.byKey(const ValueKey('assistant-header-name')),
      );
      await tester.pumpWidget(_app(_header(mascot: false)));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('assistant-header-companion')),
        findsNothing,
      );
      final initial = tester.widget<Text>(
        find.byKey(const ValueKey('assistant-avatar-initial')),
      );
      expect(initial.data, 'H');
      expect(initial.style!.color, AppTheme.hermesRedDark.hermes.accent);
      expect(tester.getRect(find.byType(MessageAvatarHeader)), withMascot);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('assistant-header-name'))),
        nameWith,
      );
      expect(find.byKey(const ValueKey('assistant-avatar-ring')), findsNothing);
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
}
