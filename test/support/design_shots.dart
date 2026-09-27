import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// Spec 080 visual evidence. Pumps [home] at 390×844 dark ES with the app's
/// real text font and Material icons, and — when `DESIGN_SHOTS_DIR` is set —
/// writes a PNG there. Without the variable it is a plain layout test.
bool _fontsLoaded = false;

Future<void> loadDesignFonts() async {
  if (_fontsLoaded) return;
  // Null families resolve to the test default ('FlutterTest'/'Roboto');
  // 'monospace' to the shipped mono font, as on device.
  for (final (family, asset) in const [
    ('Inter', 'Inter.ttf'),
    ('Roboto', 'Inter.ttf'),
    ('FlutterTest', 'Inter.ttf'),
    ('Montserrat', 'Montserrat.ttf'),
    ('Nunito', 'Nunito.ttf'),
    ('JetBrainsMono', 'JetBrainsMono.ttf'),
    ('monospace', 'JetBrainsMono.ttf'),
  ]) {
    final loader = FontLoader(family)
      ..addFont(rootBundle.load('assets/fonts/$asset'));
    await loader.load();
  }
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final iconPath = flutterRoot == null
      ? null
      : '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
  if (iconPath != null && File(iconPath).existsSync()) {
    final bytes = File(iconPath).readAsBytesSync();
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
  _fontsLoaded = true;
}

const designShotKey = ValueKey('design-shot-root');

Future<void> pumpDesignScreen(
  WidgetTester tester,
  Widget home, {
  Size size = const Size(390, 844),
  Locale locale = const Locale('es'),
  List<NavigatorObserver> observers = const [],
}) async {
  await loadDesignFonts();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: designShotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: locale,
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        navigatorObservers: observers,
        home: home,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

/// Saves the current frame as `<name>.png` when `DESIGN_SHOTS_DIR` is set.
Future<void> saveDesignShot(WidgetTester tester, String name) async {
  final dir = Platform.environment['DESIGN_SHOTS_DIR'];
  if (dir == null || dir.isEmpty) return;
  await tester.pump(const Duration(milliseconds: 400));
  final boundary =
      tester.renderObject(find.byKey(designShotKey)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}
