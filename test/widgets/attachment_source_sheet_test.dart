import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/attachment_source_sheet.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host({
  required ValueChanged<AttachmentSourceChoice> onSelected,
  VoidCallback? onScanDocument,
  double textScale = 1,
  bool reduceMotion = false,
}) {
  return MaterialApp(
    locale: const Locale('es'),
    theme: AppTheme.fromId('dark'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: reduceMotion,
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomLeft,
        child: AttachmentSourceMenuButton(
          key: const ValueKey('attachment-anchor'),
          semanticLabel: 'Adjuntar',
          onSelected: onSelected,
          onScanDocument: onScanDocument,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'el + abre un popover anclado con exactamente Cámara, Galería y Archivos',
    (tester) async {
      final selected = <AttachmentSourceChoice>[];
      await tester.pumpWidget(_host(onSelected: selected.add));

      final anchor = find.byKey(const ValueKey('attachment-anchor'));
      expect(tester.getSize(anchor), const Size(48, 48));

      await tester.tap(anchor);
      await tester.pumpAndSettle();

      expect(
        tester.widget<MenuAnchor>(find.byType(MenuAnchor)).animated,
        isTrue,
      );
      expect(find.byType(MenuItemButton), findsNWidgets(3));
      expect(find.text('Cámara'), findsOneWidget);
      expect(find.text('Galería'), findsOneWidget);
      expect(find.text('Archivos'), findsOneWidget);
      expect(find.text('Extensiones'), findsNothing);
      expect(find.text('Inteligencia'), findsNothing);

      await tester.tap(find.text('Galería'));
      await tester.pumpAndSettle();

      expect(selected, [AttachmentSourceChoice.photos]);
      expect(find.byType(MenuItemButton), findsNothing);
    },
  );

  testWidgets(
    'con escáner el menú añade Escanear documento como cuarta entrada',
    (tester) async {
      final selected = <AttachmentSourceChoice>[];
      var scans = 0;
      await tester.pumpWidget(
        _host(onSelected: selected.add, onScanDocument: () => scans++),
      );
      await tester.tap(find.byKey(const ValueKey('attachment-anchor')));
      await tester.pumpAndSettle();

      expect(find.byType(MenuItemButton), findsNWidgets(4));
      expect(find.text('Escanear documento'), findsOneWidget);

      await tester.tap(find.text('Escanear documento'));
      await tester.pumpAndSettle();

      expect(scans, 1);
      expect(selected, isEmpty);
      expect(find.byType(MenuItemButton), findsNothing);
    },
  );

  testWidgets(
    'toque exterior cierra sin callback y una selección llama una vez',
    (tester) async {
      final selected = <AttachmentSourceChoice>[];
      await tester.pumpWidget(_host(onSelected: selected.add));
      final anchor = find.byKey(const ValueKey('attachment-anchor'));

      await tester.tap(anchor);
      await tester.pumpAndSettle();
      await tester.tap(anchor);
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      expect(selected, isEmpty);

      await tester.tap(anchor);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(700, 100));
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      expect(selected, isEmpty);

      await tester.tap(anchor);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Archivos'));
      await tester.pumpAndSettle();
      expect(selected, [AttachmentSourceChoice.files]);
    },
  );

  testWidgets('se reubica dentro de un viewport estrecho con texto ampliado', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(280, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _host(onSelected: (_) {}, textScale: 2, reduceMotion: true),
    );
    await tester.tap(find.byKey(const ValueKey('attachment-anchor')));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      tester.widget<MenuAnchor>(find.byType(MenuAnchor)).animated,
      isFalse,
    );
    for (final item in find.byType(MenuItemButton).evaluate()) {
      final rect = tester.getRect(find.byWidget(item.widget));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(280));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(640));
    }
  });
}
