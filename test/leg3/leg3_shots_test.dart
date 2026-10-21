// SPDX-License-Identifier: GPL-3.0-only
// LEG3: screenshots of the guided page and of the «updates your connection»
// confirmation (build/leg3_shots/).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/onboarding/manual_setup_page.dart';
import 'package:hermes_android/core/screens/onboarding_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

import '../onb2q/hermes_shaped_server.dart';
import '../support/design_shots.dart';
import '../support/onboarding_fakes.dart';

const _root = ValueKey('leg3-shot-root');

Future<void> _shot(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull);
  final boundary =
      tester.renderObject(find.byKey(_root)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final dir = Directory('build/leg3_shots')..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void _phone(WidgetTester tester, [Size size = const Size(390, 844)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _host(
  Widget child, {
  String language = 'es',
  String theme = 'dark',
  double scale = 1,
}) => RepaintBoundary(
  key: _root,
  child: onboardingHost(child, language: language, theme: theme, scale: scale),
);

void main() {
  for (final (language, theme, scale, size) in [
    ('es', 'dark', 1.0, const Size(390, 1000)),
    ('es', 'light', 1.0, const Size(390, 1000)),
    ('en', 'dark', 1.0, const Size(390, 1000)),
    ('es', 'dark', 2.0, const Size(320, 1400)),
  ]) {
    testWidgets('guided page $language $theme x$scale', (tester) async {
      await loadDesignFonts();
      _phone(tester, size);
      final manager = await onboardingManager();
      await tester.pumpWidget(
        _host(
          ManualSetupPage(connManager: manager),
          language: language,
          theme: theme,
          scale: scale,
        ),
      );
      await tester.pumpAndSettle();
      await _shot(tester, 'page-$language-$theme-x${scale.toInt()}');
    });
  }

  testWidgets('confirmation says it updates the connection', (tester) async {
    HttpOverrides.global = null;
    final server = (await tester.runAsync(HermesShapedServer.start))!;
    addTearDown(server.close);
    await loadDesignFonts();
    _phone(tester);
    final manager = await onboardingManager();
    addTearDown(manager.dispose);
    await tester.runAsync(
      () => manager.upsertConnection(
        SavedConnection(
          id: 'era1',
          label: 'Casa',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'k',
        ),
      ),
    );
    late ValueChanged<String> detect;
    await tester.pumpWidget(
      _host(
        OnboardingScreen(
          guided: true,
          playOpening: false,
          connManager: manager,
          cameraBuilder: (d, _) {
            detect = d;
            return const SizedBox();
          },
          onDone: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('onboarding-help-scan')));
    await tester.pump(const Duration(seconds: 1));
    detect(
      'hermes://pair?v=2&url=${Uri.encodeQueryComponent(server.url)}'
      '&user=admin&pass=x',
    );
    await tester.pump(const Duration(seconds: 3));
    await _shot(tester, 'confirm-updates-es-dark');
  });
}
