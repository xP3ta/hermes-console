import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart';
import 'package:hermes_android/core/design/floating.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/feedback/screen_help.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _scaffold(String themeId) => MaterialApp(
  theme: AppTheme.fromId(themeId),
  home: const Scaffold(appBar: HermesAppBar(title: Text('Sesiones'))),
);

void main() {
  testWidgets('tema terminal (Dracula) pone el título en MAYÚSCULAS', (
    tester,
  ) async {
    await tester.pumpWidget(_scaffold('dracula'));
    expect(find.text('SESIONES'), findsOneWidget);
    expect(find.text('Sesiones'), findsNothing);
  });

  testWidgets('tema no terminal (Steel) deja el título tal cual', (
    tester,
  ) async {
    await tester.pumpWidget(_scaffold('steel'));
    expect(find.text('Sesiones'), findsOneWidget);
    expect(find.text('SESIONES'), findsNothing);
  });

  testWidgets('título compuesto: solo el primer Text va en MAYÚSCULAS', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('dracula'),
        home: const Scaffold(
          appBar: HermesAppBar(
            title: Column(
              children: [Text('skills'), Text('69 activas · /api/skills')],
            ),
          ),
        ),
      ),
    );
    // El título (primer Text) se transforma; el subtítulo queda intacto.
    expect(find.text('SKILLS'), findsOneWidget);
    expect(find.text('skills'), findsNothing);
    expect(find.text('69 activas · /api/skills'), findsOneWidget);
  });

  group('floating pieces', () {
    const titleKey = ValueKey('hermes-app-bar-title');
    const actionsKey = ValueKey('hermes-app-bar-actions');
    const leadingKey = ValueKey('hermes-app-bar-leading');
    const scrimKey = ValueKey('hermes-app-bar-scrim');
    const moreKey = ValueKey('hermes-app-bar-more');

    Widget app(
      PreferredSizeWidget bar, {
      String themeId = 'classic-dark',
      Widget? body,
      Widget? drawer,
    }) => MaterialApp(
      theme: AppTheme.fromId(themeId),
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: Scaffold(appBar: bar, drawer: drawer, body: body),
    );

    IconButton icon(IconData data, String tip, {VoidCallback? onTap}) =>
        IconButton(icon: Icon(data), tooltip: tip, onPressed: onTap ?? () {});

    bool inside(WidgetTester tester, Finder piece, Finder holder) {
      final outer = tester.getRect(holder).inflate(2);
      final inner = tester.getRect(piece);
      return inner.left >= outer.left &&
          inner.top >= outer.top &&
          inner.right <= outer.right &&
          inner.bottom <= outer.bottom;
    }

    Finder button(String tip) => find.ancestor(
      of: find.byTooltip(tip),
      matching: find.byType(IconButton),
    );

    for (final id in const ['classic-dark', 'classic']) {
      testWidgets('$id: a bar with no band, its pieces in the chrome', (
        tester,
      ) async {
        await tester.pumpWidget(
          app(
            themeId: id,
            HermesAppBar(
              title: const Text('Conversaciones'),
              actions: [
                icon(Icons.edit_square, 'Nueva'),
                icon(Icons.more_vert, 'Más'),
              ],
            ),
            drawer: const Drawer(),
          ),
        );
        final theme = AppTheme.fromId(id);
        final chrome = HermesChrome.of(theme.hermes);
        final bar = tester.widget<AppBar>(find.byType(AppBar));
        expect(bar.backgroundColor, Colors.transparent);
        expect(bar.forceMaterialTransparency, isTrue);
        expect(bar.elevation, 0);
        expect(bar.scrolledUnderElevation, 0);
        expect(find.byType(BackdropFilter), findsNothing);
        expect(
          find.ancestor(
            of: find.byType(AppBar),
            matching: find.byType(RepaintBoundary),
          ),
          findsWidgets,
        );

        // Leading: the implied menu button, round and floating.
        final leading = tester.widget<IconButtonTheme>(find.byKey(leadingKey));
        expect(leading.data.style?.backgroundColor?.resolve({}), chrome.fill);
        final menu = find.descendant(
          of: find.byKey(leadingKey),
          matching: find.byType(DrawerButton),
        );
        expect(menu, findsOneWidget);
        expect(tester.getSize(menu), const Size.square(48));

        // Title and actions, each in a floating piece.
        expect(
          find.descendant(
            of: find.byKey(titleKey),
            matching: find.text('Conversaciones'),
          ),
          findsOneWidget,
        );
        expect(
          tester.widget(find.byKey(titleKey)),
          isA<HermesFloatingSurface>(),
        );
        expect(tester.getSize(find.byKey(actionsKey)).height, 44);
        for (final tip in const ['Nueva', 'Más']) {
          expect(
            inside(tester, button(tip), find.byKey(actionsKey)),
            isTrue,
            reason: tip,
          );
          expect(tester.getSize(button(tip)), const Size.square(48));
        }
        final title = tester.getRect(find.byKey(titleKey));
        expect(title.center.dx, moreOrLessEquals(400, epsilon: 1));

        // The scrim is the page colour and runs below the header.
        final scrim = tester.widget<DecoratedBox>(find.byKey(scrimKey));
        final gradient =
            (scrim.decoration as BoxDecoration).gradient! as LinearGradient;
        expect(
          gradient.colors.first.withValues(alpha: 1),
          theme.hermes.background,
        );
        expect(gradient.colors.last.a, 0);
        expect(
          tester.getRect(find.byKey(scrimKey)).bottom,
          tester.getRect(find.byType(AppBar)).bottom + HermesAppBar.scrimTail,
        );
      });
    }

    testWidgets('the title pill is one line: the name, and a state beside it '
        'as a badge', (tester) async {
      await tester.pumpWidget(
        app(
          const HermesAppBar(
            title: Text('Conversaciones'),
            titleBadge: HermesTitleBadge('ana', semanticsLabel: 'Perfil: ana'),
          ),
        ),
      );
      final name = find.descendant(
        of: find.byKey(titleKey),
        matching: find.text('Conversaciones'),
      );
      final badge = find.descendant(
        of: find.byKey(titleKey),
        matching: find.byKey(const ValueKey('hermes-app-bar-title-badge')),
      );
      expect(name, findsOneWidget);
      expect(badge, findsOneWidget);
      // Beside the name, not under it.
      expect(
        tester.getRect(badge).left,
        greaterThanOrEqualTo(tester.getRect(name).right),
      );
      expect(
        tester.getRect(badge).center.dy,
        closeTo(tester.getRect(name).center.dy, 1.5),
      );
      expect(
        tester.getSize(find.byKey(titleKey)).height,
        HermesAppBar.pieceSize,
      );
      // Said after the page's name, in words.
      expect(
        tester.getSemantics(find.text('ana')).label,
        'Conversaciones\nPerfil: ana',
      );
    });

    testWidgets('the header is one row: the button, the title and the '
        'actions are the same height on the same line', (tester) async {
      await tester.pumpWidget(
        app(
          HermesAppBar(
            title: const Text('Kanban'),
            actions: [
              icon(Icons.add, 'Nueva'),
              icon(Icons.refresh, 'Recargar'),
            ],
          ),
          drawer: const Drawer(),
        ),
      );
      final title = tester.getRect(find.byKey(titleKey));
      final actions = tester.getRect(find.byKey(actionsKey));
      final leading = tester.getRect(
        find.descendant(
          of: find.byKey(leadingKey),
          matching: find.byType(IconButton),
        ),
      );
      expect(title.height, HermesAppBar.pieceSize);
      expect(actions.height, HermesAppBar.pieceSize);
      expect(title.center.dy, closeTo(actions.center.dy, 0.5));
      expect(title.center.dy, closeTo(leading.center.dy, 0.5));
    });

    testWidgets('a long name is cut in its one line, at 2× text too', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final scale in const [1.0, 2.0]) {
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: const Size(320, 700),
              textScaler: TextScaler.linear(scale),
            ),
            child: app(
              HermesAppBar(
                title: const Text(
                  'Un nombre de página larguísimo que no cabe en la cabecera',
                ),
                titleBadge: const HermesTitleBadge('organización-muy-larga'),
                actions: [icon(Icons.add, 'Nuevo')],
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: 'scale $scale');
        final title = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byKey(titleKey),
            matching: find.textContaining('Un nombre'),
          ),
        );
        expect(title.didExceedMaxLines, isTrue, reason: 'scale $scale');
        expect(
          title.size.height,
          lessThan(title.text.style!.fontSize! * scale * 1.6),
          reason: 'one line at scale $scale',
        );
        final pill = tester.getRect(find.byKey(titleKey));
        expect(pill.left, greaterThanOrEqualTo(0));
        expect(pill.right, lessThanOrEqualTo(320));
      }
    });

    test('no page gives the header a second line', () {
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync();
        for (final match in RegExp(r'HermesAppBar\(').allMatches(source)) {
          final title = _argument(source, match.end, 'title');
          if (title == null) continue;
          // Home's header is plain text by design, with its status line.
          if (entity.path.endsWith('home_dashboard_screen.dart')) continue;
          final oneText =
              RegExp(r'^(const )?Text\(').hasMatch(title) &&
              'Text('.allMatches(title).length == 1;
          if (!oneText) {
            final line = '\n'.allMatches(source.substring(0, match.start));
            offenders.add('${entity.path}:${line.length + 1}');
          }
        }
        if (source.contains('ProfileScopedTitle')) offenders.add(entity.path);
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'A page title is one Text: the page\'s name. A state that '
            'matters goes in titleBadge, beside it.',
      );
    });

    testWidgets('no title, no pill; a filled button stays out of the pill', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          HermesAppBar(
            title: const Text(''),
            actions: [
              icon(Icons.refresh, 'Actualizar'),
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: FilledButton(
                  onPressed: () {},
                  child: const Text('Guardar'),
                ),
              ),
            ],
          ),
        ),
      );
      expect(find.byKey(titleKey), findsNothing);
      expect(
        inside(tester, button('Actualizar'), find.byKey(actionsKey)),
        isTrue,
      );
      expect(
        tester.getRect(find.byType(FilledButton)).left,
        greaterThanOrEqualTo(tester.getRect(find.byKey(actionsKey)).right),
      );
    });

    testWidgets('past three actions the rest go behind "more", help first', (
      tester,
    ) async {
      final log = <String>[];
      await tester.pumpWidget(
        app(
          HermesAppBar(
            title: const Text('SOUL'),
            actions: [
              const ScreenHelpButton(paragraphs: ['Ayuda de la pantalla']),
              icon(
                Icons.save_outlined,
                'Guardar',
                onTap: () => log.add('save'),
              ),
              icon(
                Icons.auto_fix_high,
                'Plantillas',
                onTap: () => log.add('tpl'),
              ),
              icon(Icons.copy_outlined, 'Copiar', onTap: () => log.add('copy')),
            ],
          ),
        ),
      );
      expect(find.byTooltip('Guardar'), findsOneWidget);
      expect(find.byTooltip('Plantillas'), findsOneWidget);
      expect(find.byTooltip('Copiar'), findsNothing);
      expect(find.byType(ScreenHelpButton), findsNothing);
      expect(
        inside(tester, find.byKey(moreKey), find.byKey(actionsKey)),
        isTrue,
      );

      await tester.tap(find.byKey(moreKey));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('hermes-app-bar-more-menu')),
        findsOneWidget,
      );
      await tester.tap(find.text('Copiar'));
      await tester.pumpAndSettle();
      expect(log, ['copy']);

      await tester.tap(find.byKey(moreKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.help_outline_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Ayuda de la pantalla'), findsOneWidget);
    });

    testWidgets('three actions all stay; maxPillActions raises the limit', (
      tester,
    ) async {
      List<Widget> four() => [
        for (final (i, data) in const [
          Icons.search,
          Icons.code,
          Icons.edit_outlined,
          Icons.more_vert,
        ].indexed)
          icon(data, 'Acción $i'),
      ];
      await tester.pumpWidget(app(HermesAppBar(actions: four().sublist(0, 3))));
      expect(find.byKey(moreKey), findsNothing);
      expect(find.byType(IconButton), findsNWidgets(3));
      await tester.pumpWidget(
        app(HermesAppBar(actions: four(), maxPillActions: 4)),
      );
      expect(find.byKey(moreKey), findsNothing);
      expect(find.byType(IconButton), findsNWidgets(4));
    });

    testWidgets('a pushed page gets a floating back button that pops', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: AppTheme.fromId('classic-dark'),
          home: const Scaffold(appBar: HermesAppBar(title: Text('Ajustes'))),
        ),
      );
      expect(find.byKey(leadingKey), findsNothing);
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              const Scaffold(appBar: HermesAppBar(title: Text('Voz'))),
        ),
      );
      await tester.pumpAndSettle();
      final back = find.descendant(
        of: find.byKey(leadingKey),
        matching: find.byType(BackButton),
      );
      expect(back, findsOneWidget);
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(find.text('Voz'), findsNothing);
      expect(find.text('Ajustes'), findsOneWidget);
    });

    testWidgets('a list that asks for it keeps painting under the header', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          const HermesAppBar(title: Text('Voz')),
          body: ListView(
            clipBehavior: hermesUnderHeader,
            children: [
              for (var i = 0; i < 40; i++)
                SizedBox(height: 56, child: Text('Fila $i')),
            ],
          ),
        ),
      );
      final barBottom = tester.getRect(find.byType(AppBar)).bottom;
      // At rest nothing is hidden: the first row starts where the bar ends.
      expect(tester.getRect(find.text('Fila 0')).top, barBottom);
      final viewport = tester.renderObject<RenderViewport>(
        find.byType(Viewport),
      );
      expect(viewport.clipBehavior, Clip.none);

      await tester.drag(find.byType(ListView), const Offset(0, -60));
      await tester.pump();
      // Scrolled past the list's edge and still on screen, under the header
      // and its scrim. (Finders skip what lies outside a list's own edges
      // unless asked.)
      final row = tester.getRect(find.text('Fila 0', skipOffstage: false));
      expect(row.bottom, lessThanOrEqualTo(barBottom));
      expect(row.bottom, greaterThan(0));
      expect(
        tester
            .getRect(find.byKey(scrimKey))
            .contains(Offset(row.left, row.bottom - 1)),
        isTrue,
      );
      // The last row is reachable and rests inside the list.
      await tester.drag(find.byType(ListView), const Offset(0, -4000));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.text('Fila 39')).bottom,
        lessThanOrEqualTo(600),
      );
    });

    testWidgets(
      'a page that never scrolls under its header can keep it plain',
      (tester) async {
        await tester.pumpWidget(
          app(
            HermesAppBar(
              centerTitle: false,
              titleSpacing: 0,
              floatingLeading: false,
              titleInPill: false,
              actionsInPill: false,
              scrim: false,
              title: const Text('CONSOLE'),
              actions: [icon(Icons.person, 'Perfil')],
            ),
            drawer: const Drawer(),
          ),
        );
        expect(find.byKey(titleKey), findsNothing);
        expect(find.byKey(actionsKey), findsNothing);
        expect(find.byKey(leadingKey), findsNothing);
        expect(find.byKey(scrimKey), findsNothing);
        // Still the same transparent bar, with its menu, title and action.
        expect(
          tester.widget<AppBar>(find.byType(AppBar)).backgroundColor,
          Colors.transparent,
        );
        expect(find.byType(DrawerButton), findsOneWidget);
        expect(find.byTooltip('Perfil'), findsOneWidget);
        // The title starts right after the menu, not centred.
        expect(tester.getRect(find.text('CONSOLE')).left, kToolbarHeight);
      },
    );
  });
}

/// The expression passed as the named argument [name] of the call whose
/// opening parenthesis ends at [start], or null.
String? _argument(String source, int start, String name) {
  var depth = 0;
  var from = start;
  String? quote;
  String? read(int end) {
    final match = RegExp(
      r'^\s*(?://[^\n]*\n\s*)*(\w+):',
    ).firstMatch(source.substring(from, end));
    if (match == null || match.group(1) != name) return null;
    return source.substring(from + match.end, end).trim();
  }

  for (var i = start; i < source.length; i++) {
    final char = source[i];
    if (quote != null) {
      if (char == r'\') {
        i++;
      } else if (char == quote) {
        quote = null;
      }
    } else if (char == "'" || char == '"') {
      quote = char;
    } else if ('([{'.contains(char)) {
      depth++;
    } else if (')]}'.contains(char)) {
      if (depth == 0) return read(i);
      depth--;
    } else if (char == ',' && depth == 0) {
      final found = read(i);
      if (found != null) return found;
      from = i + 1;
    }
  }
  return null;
}
