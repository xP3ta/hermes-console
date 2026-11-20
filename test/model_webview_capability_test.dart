// A compressed model on a WebView that cannot run WebAssembly is said at
// once and in words, not after the model's deadline.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_viewer_screen.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'support/fake_webview_platform.dart';

void main() {
  testWidgets('a compressed model on a WebView that cannot run WebAssembly '
      'says so at once, in words', (tester) async {
    final web = FakeWebViewPlatform();
    WebViewPlatform.instance = web;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: ArtifactViewerScreen(
          name: 'light.glb',
          mimeType: 'model/gltf-binary',
          loadBytes: () async => Uint8List.fromList(utf8.encode('glTF')),
          onShare: () {},
        ),
      ),
    );
    for (var i = 0; i < 40 && web.controllers.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(web.controllers, hasLength(1));
    for (final controller in web.controllers) {
      controller.javaScriptResponder = (script) {
        if (script.contains('===2')) return 1;
        if (script.contains('.m||')) return '"hc%3Awasm"';
        return 0;
      };
    }
    const words =
        "This model is compressed, and this phone's WebView cannot run its "
        'decoder. Updating Android System WebView fixes it.';
    for (var i = 0; i < 60 && find.text(words).evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.text(words), findsOneWidget);
    expect(find.text('hc:wasm'), findsNothing);
  });
}
