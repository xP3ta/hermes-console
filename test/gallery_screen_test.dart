// «Galería»: the images of the recent conversations in a grid grouped by
// day, read a few conversations at a time, filtered by conversation,
// opened in the viewer, and reached from «Artefactos».
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/artifacts_screen.dart';
import 'package:hermes_android/core/screens/gallery_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/global_artifacts.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_content_thumbnail.dart';
import 'package:hermes_android/core/widgets/media_viewer/media_viewer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/fake_global_artifacts_source.dart';

final _connection = SavedConnection(
  id: 'gallery-test',
  label: 'Gallery QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-only',
);

Widget _app(Widget home, {double textScale = 1}) => MaterialApp(
  theme: AppTheme.hermesRedDark,
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: home,
);

Widget _gallery(FakeGlobalArtifactsSource source, {List<String>? chats}) =>
    GalleryScreen(
      connection: _connection,
      source: source,
      openChat: (_, session) => chats?.add(session.id),
      download: (session, reference) async =>
          throw const FileSystemException('offline'),
    );

void _phone(WidgetTester tester, [Size size = const Size(412, 915)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump();
  }
}

/// Epoch seconds of noon, [daysAgo] days back.
double _noon(int daysAgo) {
  final now = DateTime.now();
  return DateTime(
        now.year,
        now.month,
        now.day - daysAgo,
        12,
      ).millisecondsSinceEpoch /
      1000;
}

Finder _tile(String session, String name) =>
    find.byKey(ValueKey('gallery-tile-$session:/out/$name'));

FakeGlobalArtifactsSource _two() => FakeGlobalArtifactsSource(
  [fakeArtifactSession('a', at: 2000), fakeArtifactSession('b', at: 1000)],
  {
    'a': [
      fakeMediaRow('/out/hoy.png', ts: _noon(0)),
      fakeMediaRow('/out/informe.pdf', ts: _noon(0)),
    ],
    'b': [fakeMediaRow('/out/ayer.png', ts: _noon(1))],
  },
);

void main() {
  setUp(GlobalArtifactsController.clearMemory);

  testWidgets('muestra solo imágenes, agrupadas por día', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(_gallery(_two())));
    await _settle(tester);

    expect(find.text('Galería'), findsOneWidget);
    expect(find.text('Hoy'), findsOneWidget);
    expect(find.text('Ayer'), findsOneWidget);
    expect(_tile('a', 'hoy.png'), findsOneWidget);
    expect(_tile('b', 'ayer.png'), findsOneWidget);
    // The PDF is not a picture.
    expect(_tile('a', 'informe.pdf'), findsNothing);
    expect(find.byKey(const ValueKey('gallery-progress')), findsNothing);
  });

  testWidgets('filtra por conversación y vuelve a todas', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(_gallery(_two())));
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('gallery-filter')));
    await tester.pumpAndSettle();
    expect(find.text('1 imagen'), findsNWidgets(2));
    await tester.tap(find.text('Chat b'));
    await tester.pumpAndSettle();
    expect(_tile('b', 'ayer.png'), findsOneWidget);
    expect(_tile('a', 'hoy.png'), findsNothing);
    expect(find.text('Hoy'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('gallery-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Todas las conversaciones').last);
    await tester.pumpAndSettle();
    expect(_tile('a', 'hoy.png'), findsOneWidget);
    expect(_tile('b', 'ayer.png'), findsOneWidget);
  });

  testWidgets('tocar una imagen abre el visor', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(_gallery(_two())));
    await _settle(tester);

    await tester.tap(_tile('a', 'hoy.png'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(MediaViewerScreen), findsOneWidget);
  });

  testWidgets('sin imágenes lo dice', (tester) async {
    _phone(tester);
    final source = FakeGlobalArtifactsSource(
      [fakeArtifactSession('a')],
      {
        'a': [fakeMediaRow('/out/informe.pdf')],
      },
    );
    await tester.pumpWidget(_app(_gallery(source)));
    await _settle(tester);

    expect(find.byKey(const ValueKey('gallery-empty')), findsOneWidget);
    expect(find.text('Aún no hay imágenes'), findsOneWidget);
  });

  testWidgets('un fallo de lectura ofrece reintentar', (tester) async {
    _phone(tester);
    final source = FakeGlobalArtifactsSource(const [], const {})
      ..listFails = true;
    await tester.pumpWidget(_app(_gallery(source)));
    await _settle(tester);

    expect(find.byKey(const ValueKey('gallery-failed')), findsOneWidget);
    source.listFails = false;
    await tester.tap(find.byKey(const ValueKey('gallery-retry')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('gallery-failed')), findsNothing);
    expect(source.listCalls, 2);
  });

  testWidgets('lee de diez en diez conversaciones', (tester) async {
    _phone(tester);
    final source = FakeGlobalArtifactsSource(
      [for (var i = 0; i < 12; i++) fakeArtifactSession('s$i', at: 2000.0 - i)],
      {
        for (var i = 0; i < 12; i++)
          's$i': [fakeMediaRow('/out/img-$i.png', ts: _noon(0) - i)],
      },
    );
    await tester.pumpWidget(_app(_gallery(source)));
    await _settle(tester);
    expect(source.pages, hasLength(10));

    final more = find.byKey(const ValueKey('gallery-load-more'));
    await tester.scrollUntilVisible(more, 300);
    await tester.tap(more);
    await _settle(tester);
    expect(source.pages, hasLength(12));
    expect(more, findsNothing);
  });

  testWidgets('la rejilla es perezosa: solo construye lo visible', (
    tester,
  ) async {
    _phone(tester);
    final source = FakeGlobalArtifactsSource(
      [fakeArtifactSession('a')],
      {
        'a': [
          for (var i = 0; i < 90; i++)
            fakeMediaRow('/out/f$i.png', ts: _noon(0) - i),
        ],
      },
    );
    await tester.pumpWidget(_app(_gallery(source)));
    await _settle(tester);

    final built = tester.widgetList(find.byType(ChatContentThumbnail)).length;
    expect(built, greaterThan(0));
    expect(built, lessThan(60));
  });

  testWidgets('con el Fold abierto caben más columnas', (tester) async {
    final source = FakeGlobalArtifactsSource(
      [fakeArtifactSession('a')],
      {
        'a': [
          for (var i = 0; i < 8; i++)
            fakeMediaRow('/out/f$i.png', ts: _noon(0) - i),
        ],
      },
    );
    Future<int> columns(Size size) async {
      _phone(tester, size);
      await tester.pumpWidget(_app(_gallery(source)));
      await _settle(tester);
      final top = tester.getTopLeft(_tile('a', 'f0.png')).dy;
      var inRow = 0;
      for (var i = 0; i < 8; i++) {
        final tile = _tile('a', 'f$i.png');
        if (tile.evaluate().isNotEmpty && tester.getTopLeft(tile).dy == top) {
          inRow++;
        }
      }
      return inRow;
    }

    final phone = await columns(const Size(412, 915));
    GlobalArtifactsController.clearMemory();
    final fold = await columns(const Size(840, 900));
    expect(phone, greaterThanOrEqualTo(3));
    expect(fold, greaterThan(phone));
  });

  testWidgets('con letra grande no desborda', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(_gallery(_two()), textScale: 2));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(_tile('a', 'hoy.png'), findsOneWidget);
  });

  testWidgets('se llega desde Artefactos', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        ArtifactsScreen(
          connection: _connection,
          source: _two(),
          download: (session, reference) async =>
              throw const FileSystemException('offline'),
        ),
      ),
    );
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('artifacts-gallery')));
    await tester.pumpAndSettle();
    expect(find.byType(GalleryScreen), findsOneWidget);
    expect(_tile('a', 'hoy.png'), findsOneWidget);
  });
}
