// «Artefactos» across conversations (Desktop's /artifacts): incremental
// reading with progress, partial failures, cancel on leave, the «Chat»
// button of each item, links in the in-app browser, the drawer entry.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/artifacts_screen.dart';
import 'package:hermes_android/core/services/app_error_log.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/global_artifacts.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_global_artifacts_source.dart';
import 'support/malformed_artifact_rows.dart';

final _connection = SavedConnection(
  id: 'artifacts-test',
  label: 'Artifacts QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-only',
);

class _Harness {
  _Harness(this.source);

  final FakeGlobalArtifactsSource source;
  final chats = <String>[];
  final inApp = <Uri>[];
  ThemeData theme = AppTheme.hermesRedDark;
  double textScale = 1;

  Widget screen() => ArtifactsScreen(
    connection: _connection,
    source: source,
    openChat: (_, session) => chats.add(session.id),
    openInApp: (_, uri) => inApp.add(uri),
    download: (session, reference) async =>
        throw const FileSystemException('offline'),
  );

  Widget app({Widget? home}) => MaterialApp(
    theme: theme,
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: home ?? screen(),
  );
}

/// Twelve conversations, one PDF each, newest first.
FakeGlobalArtifactsSource _twelve() => FakeGlobalArtifactsSource(
  [for (var i = 0; i < 12; i++) fakeArtifactSession('s$i', at: 2000.0 - i)],
  {
    for (var i = 0; i < 12; i++)
      's$i': [fakeMediaRow('/out/informe-$i.pdf', ts: 2000 - i)],
  },
);

void _phone(WidgetTester tester, [Size size = const Size(412, 915)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Finder _row(String sessionId, String label) =>
    find.byKey(ValueKey('sa1215-item-$sessionId:/out/$label'));

final Finder _list = find
    .descendant(
      of: find.byKey(const ValueKey('artifacts-list')),
      matching: find.byType(Scrollable),
    )
    .first;

/// Lets every pending page and its rebuild through.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump();
  }
}

void main() {
  setUp(GlobalArtifactsController.clearMemory);

  testWidgets('lee las diez primeras con progreso y las siguientes a mano', (
    tester,
  ) async {
    _phone(tester);
    final source = _twelve();
    final gate = source.gate = Completer<void>();
    await tester.pumpWidget(_Harness(source).app());
    await tester.pump();
    await tester.pump();

    expect(find.text('Explora salidas generadas'), findsOneWidget);
    expect(find.byKey(const ValueKey('artifacts-progress')), findsOneWidget);
    expect(find.text('Leyendo conversación 1 de 12'), findsOneWidget);
    // R5C C-V16: TalkBack hears the progress as it advances.
    final progress = tester.widget<Semantics>(
      find.byKey(const ValueKey('artifacts-progress-text')),
    );
    expect(progress.properties.liveRegion, isTrue);
    // Never more than one page in flight.
    expect(source.pages, ['s0@0']);

    source.gate = null;
    gate.complete();
    await _settle(tester);
    expect(find.byKey(const ValueKey('artifacts-progress')), findsNothing);
    expect(source.pages, hasLength(10));
    expect(_row('s0', 'informe-0.pdf'), findsOneWidget);
    expect(find.text('PDF · /out\nChat s0'), findsOneWidget);
    expect(source.listCalls, 1);

    final more = find.byKey(const ValueKey('artifacts-load-more'));
    await tester.scrollUntilVisible(more, 300, scrollable: _list);
    expect(find.text('Leer 2 conversaciones más'), findsOneWidget);
    expect(
      find.textContaining('De 10 de las 12 conversaciones más recientes'),
      findsOneWidget,
    );
    await tester.tap(more);
    await _settle(tester);
    expect(source.pages, hasLength(12));
    expect(more, findsNothing);
    expect(
      find.textContaining('De 12 de las 12', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('un fallo parcial se avisa y el resto se ve', (tester) async {
    _phone(tester);
    final source = FakeGlobalArtifactsSource(
      [
        fakeArtifactSession('ok'),
        fakeArtifactSession('bad'),
        fakeArtifactSession('big'),
      ],
      {
        'ok': [fakeMediaRow('/out/informe.pdf')],
      },
    );
    source.failing.add('bad');
    source.tooLarge.add('big');
    await tester.pumpWidget(_Harness(source).app());
    await _settle(tester);

    expect(find.byKey(const ValueKey('artifacts-partial')), findsOneWidget);
    expect(
      find.textContaining('Se omitieron 2 de 3 conversaciones recientes'),
      findsOneWidget,
    );
    expect(
      find.textContaining('1 superaba el límite de carga segura.'),
      findsOneWidget,
    );
    expect(_row('ok', 'informe.pdf'), findsOneWidget);
  });

  // ARTCAUSA: escapes that are not UTF-8 (the Fold's FormatException) do
  // not stop the reading: the good items are listed beside them and no
  // conversation is left out.
  testWidgets('escapes que no son UTF-8: salen los buenos', (tester) async {
    _phone(tester);
    final source = FakeGlobalArtifactsSource(
      [fakeArtifactSession('fold'), fakeArtifactSession('ok')],
      {
        'fold': malformedArtifactRows(),
        'ok': [fakeMediaRow('/out/otro.pdf')],
      },
    );
    await tester.pumpWidget(_Harness(source).app());
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('artifacts-progress')), findsNothing);
    expect(find.byKey(const ValueKey('artifacts-partial')), findsNothing);
    expect(find.byKey(const ValueKey('artifacts-empty')), findsNothing);
    for (final value in [...malformedRowsGoodValues, '/out/otro.pdf']) {
      final session = value == '/out/otro.pdf' ? 'ok' : 'fold';
      final item = find.byKey(ValueKey('sa1215-item-$session:$value'));
      await tester.scrollUntilVisible(item, 200, scrollable: _list);
      expect(item, findsOneWidget, reason: value);
    }
    expect(tester.takeException(), isNull);
  });

  // ARTCAUSA: a conversation whose page cannot be read is left out and
  // counted as omitted (Desktop's `failures`), and its error type logged;
  // the reading goes on with the others.
  testWidgets('una conversación ilegible se omite y el resto se ve', (
    tester,
  ) async {
    AppErrorLog.resetForTesting();
    addTearDown(AppErrorLog.resetForTesting);
    _phone(tester);
    final source = FakeGlobalArtifactsSource(
      [fakeArtifactSession('roto'), fakeArtifactSession('ok')],
      {
        'roto': [fakeMediaRow('/out/perdido.pdf'), UnreadableRow()],
        'ok': [fakeMediaRow('/out/informe.pdf')],
      },
    );
    await tester.pumpWidget(_Harness(source).app());
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('artifacts-progress')), findsNothing);
    expect(
      find.textContaining('Se omitieron 1 de 2 conversaciones recientes'),
      findsOneWidget,
    );
    expect(_row('ok', 'informe.pdf'), findsOneWidget);
    expect(_row('roto', 'perdido.pdf'), findsNothing);
    expect(AppErrorLog.recent.map((r) => r.source), contains('artifacts'));
  });

  testWidgets('si la lista falla se puede reintentar', (tester) async {
    _phone(tester);
    final source = FakeGlobalArtifactsSource(
      [fakeArtifactSession('s0')],
      {
        's0': [fakeMediaRow('/out/a.pdf')],
      },
    );
    source.listFails = true;
    await tester.pumpWidget(_Harness(source).app());
    await _settle(tester);
    expect(find.byKey(const ValueKey('artifacts-failed')), findsOneWidget);
    expect(find.text('No se pudieron cargar los artefactos'), findsOneWidget);

    source.listFails = false;
    await tester.tap(find.text('Reintentar'));
    await _settle(tester);
    expect(_row('s0', 'a.pdf'), findsOneWidget);
  });

  testWidgets('la búsqueda sigue escrita al volver a la cabecera y al '
      'actualizar', (tester) async {
    // R5C C-V7: the box emptied while the list stayed filtered.
    _phone(tester, const Size(412, 600));
    await tester.pumpWidget(_Harness(_twelve()).app());
    await _settle(tester);
    final box = find.descendant(
      of: find.byKey(const ValueKey('artifacts-search')),
      matching: find.byType(EditableText),
    );
    String typed() => tester.widget<EditableText>(box).controller.text;

    await tester.enterText(box, 'informe');
    await tester.pump();
    // The header leaves the lazy list and comes back.
    await tester.drag(_list, const Offset(0, -1500));
    await tester.pumpAndSettle();
    await tester.drag(_list, const Offset(0, 3000));
    await tester.pumpAndSettle();
    expect(typed(), 'informe');

    await tester.enterText(box, 'informe-1');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('artifacts-refresh')));
    await _settle(tester);
    expect(typed(), 'informe-1');
    expect(_row('s1', 'informe-1.pdf'), findsOneWidget);
    expect(_row('s2', 'informe-2.pdf'), findsNothing);
  });

  testWidgets('sin artefactos lo dice', (tester) async {
    _phone(tester);
    final source = FakeGlobalArtifactsSource(
      [fakeArtifactSession('s0')],
      {
        's0': [
          {'role': 'user', 'content': 'hola'},
        ],
      },
    );
    await tester.pumpWidget(_Harness(source).app());
    await _settle(tester);
    expect(find.byKey(const ValueKey('artifacts-empty')), findsOneWidget);
    expect(find.text('No se encontraron artefactos'), findsOneWidget);
  });

  testWidgets('salir cancela la lectura tras la página en curso', (
    tester,
  ) async {
    _phone(tester);
    final source = _twelve();
    final gate = source.gate = Completer<void>();
    final harness = _Harness(source);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: const Scaffold(body: Text('home')),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => harness.screen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(source.pages, ['s0@0']);

    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    gate.complete();
    await _settle(tester);
    expect(source.pages, ['s0@0']);
    expect(find.text('home'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('volver a abrir enseña lo leído sin volver a leer', (
    tester,
  ) async {
    _phone(tester);
    final source = _twelve();
    final harness = _Harness(source);
    await tester.pumpWidget(harness.app());
    await _settle(tester);
    final pages = source.pages.length;

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(harness.app());
    await _settle(tester);
    expect(_row('s0', 'informe-0.pdf'), findsOneWidget);
    expect(source.pages, hasLength(pages));
    expect(source.listCalls, 1);
  });

  testWidgets('el botón Chat abre esa conversación; un enlace se abre en la '
      'app', (tester) async {
    _phone(tester);
    final semantics = tester.ensureSemantics();
    final source = FakeGlobalArtifactsSource(
      [fakeArtifactSession('a', at: 2000), fakeArtifactSession('b', at: 1000)],
      {
        'a': [fakeMediaRow('/out/plano.png', ts: 2000)],
        'b': [
          {
            'role': 'assistant',
            'content': 'Mira https://example.com/docs/guia',
            'timestamp': 1000,
          },
        ],
      },
    );
    final harness = _Harness(source);
    await tester.pumpWidget(harness.app());
    await _settle(tester);

    // The image card names its conversation and opens it.
    expect(find.textContaining('Chat a · '), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('sa1215-chat-a:/out/plano.png')),
    );
    await tester.pump();
    expect(harness.chats, ['a']);
    // TalkBack: the button says which conversation and a double tap opens
    // it (REVIEW-R4 P1-B1: excludeSemantics had dropped the tap).
    final chatButton = tester.getSemantics(
      find.bySemanticsLabel('Abrir la conversación Chat a'),
    );
    expect(chatButton, isSemantics(isButton: true, hasTapAction: true));
    chatButton.owner!.performAction(chatButton.id, SemanticsAction.tap);
    await tester.pump();
    expect(harness.chats, ['a', 'a']);

    final link = find.byKey(
      const ValueKey('sa1215-item-b:https://example.com/docs/guia'),
    );
    await tester.scrollUntilVisible(link, 300, scrollable: _list);
    await tester.tap(link);
    await tester.pump();
    expect(harness.inApp, [Uri.parse('https://example.com/docs/guia')]);

    await tester.tap(
      find.byKey(const ValueKey('sa1215-chat-b:https://example.com/docs/guia')),
    );
    await tester.pump();
    expect(harness.chats, ['a', 'a', 'b']);
    semantics.dispose();
  });

  for (final (name, theme) in [
    ('oscuro', AppTheme.hermesRedDark),
    ('claro', AppTheme.hermesRedLight),
  ]) {
    testWidgets('tema $name con texto grande: sin desbordes', (tester) async {
      _phone(tester, const Size(360, 780));
      final source = FakeGlobalArtifactsSource(
        [
          fakeArtifactSession('a'),
          fakeArtifactSession('bad'),
          fakeArtifactSession('c'),
        ],
        {
          'a': [
            fakeMediaRow('/out/una-presentacion-con-nombre-muy-largo.pptx'),
            fakeMediaRow('/out/foto.jpg'),
          ],
          'c': [
            {'role': 'assistant', 'content': 'https://github.com/a/b'},
          ],
        },
      );
      source.failing.add('bad');
      final harness = _Harness(source);
      harness.theme = theme;
      harness.textScale = 2;
      await tester.pumpWidget(harness.app());
      await _settle(tester);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('artifacts-scope')),
        300,
        scrollable: _list,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('la entrada Artefactos del drawer abre la vista', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    final semantics = tester.ensureSemantics();
    final scaffold = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Scaffold(
          key: scaffold,
          drawer: HermesDrawer(
            connection: _connection,
            connManager: manager,
            current: DrawerSection.home,
          ),
        ),
      ),
    );
    scaffold.currentState!.openDrawer();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final entry = find.byKey(const ValueKey('drawer-artifacts'));
    await tester.scrollUntilVisible(
      entry,
      80,
      scrollable: find
          .descendant(
            of: find.byType(Drawer),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      find.descendant(of: entry, matching: find.text('Artefactos')),
      findsOneWidget,
    );
    // Desktop's detail, read by TalkBack after the label.
    expect(
      find.descendant(
        of: entry,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.button == true &&
              widget.properties.hint == 'Explora salidas generadas',
        ),
      ),
      findsOneWidget,
    );
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(ArtifactsScreen), findsOneWidget);
    semantics.dispose();
  });
}
