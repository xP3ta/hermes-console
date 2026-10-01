// sa1215: per-chat «Archivos y enlaces» screen.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_content_screen.dart';
import 'package:hermes_android/core/services/chat_content_extractor.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

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

class _Harness {
  List<Map<String, dynamic>> transcript;
  bool hasOlder;
  int loadOlderCalls = 0;
  final opened = <ChatContentItem>[];
  final launched = <Uri>[];
  Object? openError;

  _Harness({required this.transcript, this.hasOlder = false});

  Widget app() => MaterialApp(
    theme: AppTheme.hermesRedDark,
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: ChatContentScreen(
      transcript: () => transcript,
      hasOlder: () => hasOlder,
      loadOlder: () async {
        loadOlderCalls++;
        transcript = [...transcript, ..._older()];
        hasOlder = false;
      },
      onOpenFile: (item) async {
        if (openError != null) throw openError!;
        opened.add(item);
      },
      launchExternal: (uri) async {
        launched.add(uri);
        return true;
      },
    ),
  );
}

Finder _row(String label) => find.byKey(ValueKey('sa1215-item-$label'));

final Finder _listScrollable = find
    .descendant(
      of: find.byKey(const ValueKey('sa1215-list')),
      matching: find.byType(Scrollable),
    )
    .first;

void main() {
  testWidgets('lista todo lo compartido, de lo más nuevo a lo más antiguo', (
    tester,
  ) async {
    await tester.pumpWidget(_Harness(transcript: _recent()).app());
    await tester.pumpAndSettle();

    expect(find.text('Archivos y enlaces'), findsOneWidget);
    final labels = ['informe.pdf', 'grafico.png', 'guia'];
    for (final label in labels) {
      expect(_row(label), findsOneWidget);
    }
    final ys = [for (final label in labels) tester.getTopLeft(_row(label)).dy];
    expect(ys, orderedEquals([...ys]..sort()));
    // The server path is never painted; only the name is.
    expect(find.textContaining('/srv/out'), findsNothing);
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

  testWidgets('un enlace se abre fuera; archivos e imágenes dentro', (
    tester,
  ) async {
    final harness = _Harness(transcript: _recent());
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await tester.tap(_row('guia'));
    await tester.pumpAndSettle();
    expect(harness.launched, [Uri.parse('https://example.com/docs/guia')]);
    expect(harness.opened, isEmpty);

    await tester.tap(_row('grafico.png'));
    await tester.pumpAndSettle();
    await tester.tap(_row('informe.pdf'));
    await tester.pumpAndSettle();
    expect(harness.opened.map((item) => item.value), [
      '/srv/out/grafico.png',
      '/srv/out/informe.pdf',
    ]);
    expect(harness.launched, hasLength(1));
  });

  testWidgets('si no se puede abrir lo dice', (tester) async {
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

  testWidgets('mantener pulsado copia el enlace', (tester) async {
    String? copied;
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
    await tester.pumpWidget(_Harness(transcript: _recent()).app());
    await tester.pumpAndSettle();

    await tester.longPress(_row('guia'));
    await tester.pumpAndSettle();
    expect(copied, 'https://example.com/docs/guia');
    expect(find.text('Copiado'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
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
}
