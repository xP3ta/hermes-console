// sa1215: per-chat «Artefactos» screen, presented like Hermes Desktop's
// Artifacts view: filters with counts, an image grid of real thumbnails,
// files grouped by type and links with their site's mark.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/browser/in_app_browser_screen.dart';
import 'package:hermes_android/core/screens/chat_content_screen.dart';
import 'package:hermes_android/core/services/artifact_media.dart';
import 'package:hermes_android/core/services/chat_content_extractor.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_content_thumbnail.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'support/fake_webview_platform.dart';
import 'support/quiet_feedback.dart';

/// Newest first, as ActiveChat stores it.
List<Map<String, dynamic>> _recent() => [
  {
    'role': 'assistant',
    'content': 'Informe listo.\nMEDIA:/srv/out/informe.pdf',
    'timestamp': 1781774300,
  },
  {
    'role': 'assistant',
    'content': 'Gráfico: MEDIA:/srv/out/grafico.png',
    'timestamp': 1781774200,
  },
  {
    'role': 'user',
    'content': 'Mira https://example.com/docs/guia',
    'timestamp': 1781774100,
  },
];

List<Map<String, dynamic>> _older() => [
  {
    'role': 'assistant',
    'content': 'Antiguo: https://old.example.org/nota',
    'timestamp': 1781770000,
  },
];

/// One assistant message delivering [paths] with `MEDIA:` lines.
List<Map<String, dynamic>> _delivered(List<String> paths) => [
  {
    'role': 'assistant',
    'content': [for (final path in paths) 'MEDIA:$path'].join('\n'),
    'timestamp': 1781774300,
  },
];

class _Harness {
  List<Map<String, dynamic>> transcript;
  bool hasOlder;
  int loadOlderCalls = 0;
  final opened = <ChatContentItem>[];
  final launched = <Uri>[];
  final inApp = <Uri>[];
  bool injectInApp = true;
  Object? openError;
  Future<File> Function(ChatContentItem item)? loadImageFile;
  String? Function(String url)? knownLinkTitle;
  ThemeData theme = AppTheme.hermesRedDark;
  double textScale = 1;

  _Harness({
    required this.transcript,
    this.hasOlder = false,
    this.loadImageFile,
    this.knownLinkTitle,
  });

  Widget app() => MaterialApp(
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
    home: ChatContentScreen(
      transcript: () => transcript,
      hasOlder: () => hasOlder,
      loadOlder: () async {
        loadOlderCalls++;
        transcript = [...transcript, ..._older()];
        hasOlder = false;
      },
      onOpenFile: (item, _) async {
        if (openError != null) throw openError!;
        opened.add(item);
      },
      launchExternal: (uri) async {
        launched.add(uri);
        return true;
      },
      loadImageFile: loadImageFile,
      knownLinkTitle: knownLinkTitle,
      openInApp: injectInApp ? (_, uri) => inApp.add(uri) : null,
    ),
  );
}

Finder _row(String label) => find.byKey(ValueKey('sa1215-item-$label'));

Finder _section(String key) => find.byKey(ValueKey('sa1215-section-$key'));

final Finder _listScrollable = find
    .descendant(
      of: find.byKey(const ValueKey('sa1215-list')),
      matching: find.byType(Scrollable),
    )
    .first;

void _phone(WidgetTester tester, [Size size = const Size(412, 915)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// The count shown on a filter tab.
Finder _tabCount(String filter, String count) => find.descendant(
  of: find.byKey(ValueKey('sa1215-filter-$filter')),
  matching: find.text(count),
);

void main() {
  testWidgets('Todo: imágenes arriba, luego archivos por tipo y enlaces', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_Harness(transcript: _recent()).app());
    await tester.pumpAndSettle();

    expect(find.text('Artefactos'), findsOneWidget);
    // Each group says what it holds, and in this order.
    expect(find.text('IMÁGENES · 1'), findsOneWidget);
    expect(find.text('PDF · 1'), findsOneWidget);
    expect(find.text('ENLACES · 1'), findsOneWidget);
    final tops = [
      for (final key in ['image', 'pdf', 'link'])
        tester.getTopLeft(_section(key)).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()));
    expect(
      tester.getTopLeft(_row('grafico.png')).dy,
      lessThan(tester.getTopLeft(_section('pdf')).dy),
    );
    expect(
      tester.getTopLeft(_row('informe.pdf')).dy,
      lessThan(tester.getTopLeft(_section('link')).dy),
    );
    // The image is a card with its thumbnail, not a row.
    expect(
      find.descendant(
        of: _row('grafico.png'),
        matching: find.byType(ChatContentThumbnail),
      ),
      findsOneWidget,
    );
    // A file: its type icon, the kind tag and its folder in grey.
    expect(
      find.descendant(
        of: _row('informe.pdf'),
        matching: find.byIcon(Icons.picture_as_pdf_outlined),
      ),
      findsOneWidget,
    );
    final location = tester.widget<Text>(find.text('PDF · /srv/out'));
    expect(location.style?.color, AppTheme.hermesRedDark.hermes.textSecondary);
    // A link: a readable title from its URL, its host and path.
    expect(
      find.descendant(of: _row('guia'), matching: find.text('Guia')),
      findsOneWidget,
    );
    expect(find.text('Enlace · example.com/docs/guia'), findsOneWidget);
  });

  testWidgets('los filtros llevan su recuento, como Desktop', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_Harness(transcript: _recent()).app());
    await tester.pumpAndSettle();

    expect(_tabCount('all', '3'), findsOneWidget);
    expect(_tabCount('image', '1'), findsOneWidget);
    expect(_tabCount('file', '1'), findsOneWidget);
    expect(_tabCount('link', '1'), findsOneWidget);
    // The counts are the conversation's, not the search results'.
    await tester.enterText(find.byType(TextField), 'informe');
    await tester.pumpAndSettle();
    expect(_tabCount('all', '3'), findsOneWidget);
    expect(_tabCount('image', '1'), findsOneWidget);
  });

  testWidgets('filtra por tipo y busca por nombre', (tester) async {
    await tester.pumpWidget(_Harness(transcript: _recent()).app());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('sa1215-filter-image')));
    await tester.pumpAndSettle();
    expect(_row('grafico.png'), findsOneWidget);
    expect(_row('informe.pdf'), findsNothing);
    expect(_row('guia'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('sa1215-filter-link')));
    await tester.pumpAndSettle();
    expect(_row('guia'), findsOneWidget);
    expect(_row('grafico.png'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('sa1215-filter-all')));
    await tester.enterText(find.byType(TextField), 'INFORME');
    await tester.pumpAndSettle();
    expect(_row('informe.pdf'), findsOneWidget);
    expect(_row('grafico.png'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('Sin resultados'), findsOneWidget);
  });

  testWidgets('un enlace se abre en el navegador de la app; archivos e '
      'imágenes en sus visores', (tester) async {
    _phone(tester);
    final harness = _Harness(transcript: _recent());
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    // the owner's decision: http/https inside the app, never handed outside.
    await tester.tap(_row('guia'));
    await tester.pumpAndSettle();
    expect(harness.inApp, [Uri.parse('https://example.com/docs/guia')]);
    expect(harness.launched, isEmpty);
    expect(harness.opened, isEmpty);

    await tester.tap(_row('grafico.png'));
    await tester.pumpAndSettle();
    await tester.tap(_row('informe.pdf'));
    await tester.pumpAndSettle();
    expect(harness.opened.map((item) => item.value), [
      '/srv/out/grafico.png',
      '/srv/out/informe.pdf',
    ]);
    expect(harness.inApp, hasLength(1));
    expect(harness.launched, isEmpty);
  });

  testWidgets('el navegador de la app se abre de verdad y su notch vuelve a '
      'Artefactos', (tester) async {
    _phone(tester);
    WebViewPlatform.instance = FakeWebViewPlatform();
    final semantics = tester.ensureSemantics();
    final harness = _Harness(transcript: _recent())..injectInApp = false;
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await tester.tap(_row('guia'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final browser = tester.widget<InAppBrowserScreen>(
      find.byType(InAppBrowserScreen),
    );
    expect(browser.initialUrl, Uri.parse('https://example.com/docs/guia'));
    expect(find.bySemanticsLabel('Volver a Artefactos'), findsOneWidget);
    expect(harness.launched, isEmpty);

    await tester.tap(find.byKey(const ValueKey('in-app-browser-notch')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(InAppBrowserScreen), findsNothing);
    expect(find.byType(ChatContentScreen), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('si no se puede abrir lo dice', (tester) async {
    _phone(tester);
    final harness = _Harness(transcript: _recent())
      ..openError = StateError('404');
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await tester.tap(_row('informe.pdf'));
    await tester.pumpAndSettle();
    expect(find.text('No se pudo abrir informe.pdf'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('si no se puede abrir dice por qué, como Desktop', (
    tester,
  ) async {
    _phone(tester);
    for (final (error, text) in [
      (
        const ArtifactFetchFailure(ArtifactFetchProblem.notFound),
        'No se pudo abrir informe.pdf. No está en el servidor',
      ),
      (
        const ArtifactFetchFailure(ArtifactFetchProblem.noFolder),
        'No se pudo abrir informe.pdf. Ruta sin carpeta',
      ),
      (
        const ArtifactFetchFailure(ArtifactFetchProblem.unsupported),
        'Este archivo no se puede abrir desde el móvil. Mantén pulsado para '
            'copiar su ruta.',
      ),
    ]) {
      final harness = _Harness(transcript: _recent())..openError = error;
      await tester.pumpWidget(harness.app());
      await tester.pumpAndSettle();
      await tester.tap(_row('informe.pdf'));
      await tester.pumpAndSettle();
      expect(find.text(text), findsOneWidget, reason: '$error');
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('una miniatura que falla dice por qué y se puede reintentar', (
    tester,
  ) async {
    _phone(tester);
    var asks = 0;
    final harness = _Harness(
      transcript: _delivered(['/srv/img/plano.png']),
      loadImageFile: (_) async {
        asks++;
        throw const ArtifactFetchFailure(ArtifactFetchProblem.notFound);
      },
    );
    await tester.pumpWidget(harness.app());
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(asks, 1);
    expect(find.text('No está en el servidor'), findsOneWidget);
    final retry = find.byKey(const ValueKey('sa1215-thumb-retry'));
    expect(retry, findsOneWidget);

    await tester.tap(retry);
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(asks, 2);

    // Reopening the view asks again by itself.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(harness.app());
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(asks, 3);
  });

  group('copiar', () {
    String? copied;
    setUp(() => copied = null);

    Future<void> mockClipboard(WidgetTester tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
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

    testWidgets('mantener pulsado copia el enlace', (tester) async {
      _phone(tester);
      await mockClipboard(tester);
      await tester.pumpWidget(_Harness(transcript: _recent()).app());
      await tester.pumpAndSettle();

      await tester.longPress(_row('guia'));
      await tester.pumpAndSettle();
      expect(copied, 'https://example.com/docs/guia');
      // Android shows its own clipboard confirmation: no app toast.
      expectRoutineFeedback(tester, 'Copiado');
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('el botón copia la ruta del archivo o la URL', (tester) async {
      _phone(tester);
      await mockClipboard(tester);
      await tester.pumpWidget(_Harness(transcript: _recent()).app());
      await tester.pumpAndSettle();

      final file = find.byKey(const ValueKey('sa1215-copy-informe.pdf'));
      expect(tester.widget<IconButton>(file).tooltip, 'Copiar ruta');
      await tester.tap(file);
      await tester.pumpAndSettle();
      expect(copied, '/srv/out/informe.pdf');

      final link = find.byKey(const ValueKey('sa1215-copy-guia'));
      expect(tester.widget<IconButton>(link).tooltip, 'Copiar URL');
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(copied, 'https://example.com/docs/guia');
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  testWidgets('carga mensajes antiguos solo cuando se pide', (tester) async {
    final harness = _Harness(transcript: _recent(), hasOlder: true);
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(harness.loadOlderCalls, 0);
    expect(_row('nota'), findsNothing);
    final button = find.byKey(const ValueKey('sa1215-load-older'));
    await tester.scrollUntilVisible(button, 200, scrollable: _listScrollable);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(harness.loadOlderCalls, 1);
    await tester.scrollUntilVisible(
      _row('nota'),
      200,
      scrollable: _listScrollable,
    );
    expect(_row('nota'), findsOneWidget);
    expect(button, findsNothing);
  });

  testWidgets('estado vacío honesto', (tester) async {
    await tester.pumpWidget(_Harness(transcript: const []).app());
    await tester.pumpAndSettle();

    expect(find.text('Aún no hay nada compartido'), findsOneWidget);
    expect(find.byKey(const ValueKey('sa1215-load-older')), findsNothing);
  });

  testWidgets('estado vacío con historial antiguo ofrece cargarlo', (
    tester,
  ) async {
    final harness = _Harness(transcript: const [], hasOlder: true);
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(find.text('Aún no hay nada compartido'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sa1215-load-older')));
    await tester.pumpAndSettle();
    expect(_row('nota'), findsOneWidget);
  });

  group('imágenes', () {
    testWidgets('miniaturas reales en dos columnas en un móvil', (
      tester,
    ) async {
      for (final width in [360.0, 412.0]) {
        _phone(tester, Size(width, 915));
        final pending = Completer<File>();
        final harness = _Harness(
          transcript: _delivered([
            '/srv/img/a.png',
            '/srv/img/b.png',
            '/srv/img/c.png',
          ]),
          loadImageFile: (_) => pending.future,
        );
        await tester.pumpWidget(harness.app());
        await tester.pump();

        final a = tester.getRect(_row('a.png'));
        final b = tester.getRect(_row('b.png'));
        final c = tester.getRect(_row('c.png'));
        expect(a.top, b.top, reason: '$width');
        expect(b.left, greaterThan(a.right), reason: '$width');
        expect(c.top, greaterThan(a.bottom), reason: '$width');
        expect(c.left, a.left, reason: '$width');
        // Each card shows its own loading state while its image comes.
        expect(
          find.descendant(
            of: _row('a.png'),
            matching: find.byKey(const ValueKey('sa1215-thumb-loading')),
          ),
          findsOneWidget,
        );
        // Tapping a thumbnail opens the viewer.
        await tester.tap(_row('b.png'));
        await tester.pump();
        expect(harness.opened.single.value, '/srv/img/b.png');
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('solo se descargan las visibles, tres a la vez', (
      tester,
    ) async {
      _phone(tester);
      final requested = <String>[];
      final pending = <Completer<File>>[];
      final harness = _Harness(
        transcript: _delivered([
          for (var i = 0; i < 60; i++) '/srv/img/i$i.png',
        ]),
        loadImageFile: (item) {
          requested.add(item.value);
          final fetch = Completer<File>();
          pending.add(fetch);
          return fetch.future;
        },
      );
      await tester.pumpWidget(harness.app());
      await tester.pump();
      expect(requested, hasLength(3));

      // Each answer frees a slot for the next card that is on screen.
      for (var round = 0; round < 20; round++) {
        for (final fetch in pending.where((f) => !f.isCompleted).toList()) {
          fetch.completeError(const FileSystemException('offline'));
        }
        await tester.pump();
      }
      // Built = on screen plus the list's cache extent (250 dp), which a
      // plain finder skips as offstage. Exactly those were asked for.
      final thumbnails = tester.widgetList<ChatContentThumbnail>(
        find.byType(ChatContentThumbnail, skipOffstage: false),
      );
      final built = {for (final thumbnail in thumbnails) thumbnail.item.value};
      expect(requested.toSet(), built);
      expect(requested, hasLength(built.length));
      expect(requested.length, lessThan(30));
      expect(requested, isNot(contains('/srv/img/i59.png')));
      // As in Desktop, one message's images keep the order it names them.
      expect(requested.first, '/srv/img/i0.png');
      // A failed fetch says so on its own card.
      expect(
        find.descendant(
          of: _row('i0.png'),
          matching: find.byKey(const ValueKey('sa1215-thumb-error')),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('un archivo dice qué es: grupo, icono y etiqueta', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(
      _Harness(
        transcript: _delivered([
          '/srv/out/datos.json',
          '/srv/out/voz.mp3',
          '/srv/out/app-release.apk',
          '/srv/out/fuentes.zip',
        ]),
      ).app(),
    );
    await tester.pumpAndSettle();

    final groups = [
      ('archive', 'COMPRIMIDOS · 1', 'fuentes.zip', Icons.folder_zip_outlined),
      ('app', 'APPS ANDROID · 1', 'app-release.apk', Icons.android_rounded),
      ('audio', 'AUDIO · 1', 'voz.mp3', Icons.audiotrack_outlined),
      ('data', 'DATOS · 1', 'datos.json', Icons.data_object_rounded),
    ];
    var previous = -1.0;
    for (final (key, header, name, icon) in groups) {
      expect(find.text(header), findsOneWidget, reason: header);
      final top = tester.getTopLeft(_section(key)).dy;
      expect(top, greaterThan(previous), reason: header);
      previous = top;
      expect(
        find.descendant(of: _row(name), matching: find.byIcon(icon)),
        findsOneWidget,
        reason: name,
      );
    }
    expect(find.text('APK · /srv/out'), findsOneWidget);
    expect(find.text('ZIP · /srv/out'), findsOneWidget);
  });

  testWidgets('los enlaces llevan la marca de su sitio y un título legible', (
    tester,
  ) async {
    _phone(tester);
    const release = 'https://github.com/hermes/console/releases/tag/v1.4.0';
    const guide = 'https://example.com/blog/some-guide';
    const known = 'https://example.org/x/y';
    await tester.pumpWidget(
      _Harness(
        transcript: [
          {
            'role': 'assistant',
            'content': 'Mira $release, $guide y $known',
            'timestamp': 1781774300,
          },
        ],
        knownLinkTitle: (url) => url == known ? 'Guía oficial' : null,
      ).app(),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: _row('v1.4.0'),
        matching: find.byKey(const ValueKey('link-brand-github')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _row('v1.4.0'), matching: find.text('v1.4.0')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _row('some-guide'),
        matching: find.byIcon(Icons.link_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _row('some-guide'),
        matching: find.text('Some Guide'),
      ),
      findsOneWidget,
    );
    // A title the chat already loaded is used; nothing is fetched for it.
    expect(
      find.descendant(of: _row('y'), matching: find.text('Guía oficial')),
      findsOneWidget,
    );
  });

  testWidgets('TalkBack dice el tipo y el nombre de cada elemento', (
    tester,
  ) async {
    _phone(tester);
    final semantics = tester.ensureSemantics();
    final harness = _Harness(transcript: _recent());
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel('PDF: informe.pdf, en /srv/out'),
      findsOneWidget,
    );
    // A labelled row keeps its tap for TalkBack (REVIEW-R4 P1-B1's
    // pattern): a double tap opens the file, the link opens in the app.
    for (final label in [
      'PDF: informe.pdf, en /srv/out',
      'Enlace: Guia, en example.com/docs/guia',
    ]) {
      final node = tester.getSemantics(find.bySemanticsLabel(label));
      expect(node, isSemantics(isButton: true, hasTapAction: true));
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
    }
    expect(harness.opened.single.value, '/srv/out/informe.pdf');
    expect(harness.inApp, [Uri.parse('https://example.com/docs/guia')]);
    expect(
      find.bySemanticsLabel(RegExp(r'^Imagen: grafico\.png, en /srv/out')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Enlace: Guia, en example.com/docs/guia'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(RegExp(r'Imágenes\s+1')), findsOneWidget);
    expect(find.byTooltip('Copiar ruta'), findsOneWidget);
    semantics.dispose();
  });

  for (final (name, theme) in [
    ('oscuro', AppTheme.hermesRedDark),
    ('claro', AppTheme.hermesRedLight),
  ]) {
    testWidgets('tema $name con texto grande: sin desbordes', (tester) async {
      _phone(tester, const Size(360, 780));
      final harness = _Harness(
        transcript: [
          ..._recent(),
          ..._delivered([
            '/srv/out/una-presentacion-con-un-nombre-muy-largo.pptx',
            '/srv/img/foto.jpg',
          ]),
        ],
        loadImageFile: (_) async => throw const FileSystemException('x'),
      );
      harness.theme = theme;
      harness.textScale = 2;
      await tester.pumpWidget(harness.app());
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      // The filter tabs scroll sideways instead of cutting their counts.
      // They sit at the top of the list, so drag them before scrolling down.
      final tabs = find.byKey(const ValueKey('sa1215-filters'));
      final linkTab = find.byKey(const ValueKey('sa1215-filter-link'));
      final before = tester.getTopLeft(linkTab).dx;
      await tester.drag(tabs, const Offset(-300, 0));
      await tester.pump();
      expect(tester.getTopLeft(linkTab).dx, lessThan(before));
      expect(_tabCount('link', '1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        _row('guia'),
        200,
        scrollable: _listScrollable,
      );
      expect(tester.takeException(), isNull);
      final location = tester.widget<Text>(
        find.text('Enlace · example.com/docs/guia'),
      );
      expect(location.style?.color, theme.hermes.textSecondary);
    });
  }
}
