// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// The Models page at phone width (412 dp), Spanish, dark and light, with a
// fallback chain, a connected account, a set key, providers still to set up
// and one that was removed; then "Edit models" as it opens. Writes PNGs only
// when `DESIGN_SHOTS_DIR` is set; otherwise it is a layout smoke test
// (nothing overflows at phone width in either theme).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/design_shots.dart';
import 'support/models_server.dart';

const _size = Size(412, 1900);
const _shotKey = ValueKey('models-shot');

Future<void> _shot(WidgetTester tester, String name) async {
  final dir = Platform.environment['DESIGN_SHOTS_DIR'];
  if (dir == null || dir.isEmpty) return;
  await tester.pump(const Duration(milliseconds: 300));
  final boundary =
      tester.renderObject(find.byKey(_shotKey)) as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

ModelsServer _server() => ModelsServer()
  ..mainProvider = 'anthropic'
  ..mainModel = 'claude-sonnet-5'
  ..contextLength = 204800
  ..catalog = [
    {
      'slug': 'anthropic',
      'name': 'Anthropic',
      'authenticated': true,
      'is_current': true,
      'models': ['claude-sonnet-5', 'claude-opus-5'],
    },
    {
      'slug': 'openai-codex',
      'name': 'OpenAI Codex',
      'authenticated': true,
      'models': ['gpt-6.1', 'gpt-5.6'],
    },
  ]
  ..aux = [
    {'task': 'vision', 'provider': 'auto', 'model': ''},
    {'task': 'compression', 'provider': 'auto', 'model': ''},
  ]
  ..keys = {'ANTHROPIC_API_KEY': true, 'OPENROUTER_API_KEY': false}
  ..accounts = [
    {
      'id': 'openai-codex',
      'name': 'OpenAI Codex',
      'flow': 'device_code',
      'disconnectable': true,
      'status': {'logged_in': true},
    },
    {
      'id': 'nous',
      'name': 'Nous',
      'flow': 'device_code',
      'disconnectable': true,
      'status': {'logged_in': false},
    },
  ]
  ..config = {
    'fallback_providers': [
      {'provider': 'openai-codex', 'model': 'gpt-5.6'},
    ],
    'agent': {'reasoning_effort': 'medium', 'service_tier': 'normal'},
    // Removed from the page: offered back with the providers to set up.
    'model_catalog': {
      'excluded_providers': ['copilot'],
    },
  };

void main() {
  for (final (mode, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    testWidgets('models page · $mode', (tester) async {
      await loadDesignFonts();
      final scope = await modelsScope();
      tester.view.physicalSize = _size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RepaintBoundary(
          key: _shotKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            locale: const Locale('es'),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            theme: theme,
            home: ModelsScreen(
              connection: SavedConnection(
                id: modelsConnectionId,
                label: 'Servidor',
                host: 'hermes.example.test',
                port: 8642,
                apiKey: 'synthetic-connection-token',
                kind: InstanceKind.vps,
              ),
              dashboardClientForTesting: _server().client(),
              profileScope: scope,
              gatewayCatalogForTesting: () => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The group of the current provider, open: its models, its key and
      // "Quitar proveedor"; and what is not connected.
      await openProvider(tester, 'anthropic');
      await openUnconfigured(tester);
      expect(find.text('MODELO ACTIVO'), findsOneWidget);
      expect(find.text('GitHub Copilot'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _shot(tester, 'models_page_$mode');

      await tapOn(tester, modelsKey('models-edit-models'));
      expect(find.text('2 de 2 visibles'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await _shot(tester, 'models_edit_models_$mode');
      await tester.pumpWidget(const SizedBox());
    });
  }
}
