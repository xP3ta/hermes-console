// The still pictures of chat previews survive an update only when they can
// be trusted: earlier builds captured a page whatever it showed after ten
// seconds (a grey 3D model, a blank diagram), so their pictures are not
// shown again and are removed; the pictures of this build are used.
//
// One test in its own file: the picture cache is kept for the whole run.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/web_preview.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'support/fake_webview_platform.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAY'
  'AAjCB0C8AAAAASUVORK5CYII=',
);

String _fileOf(String key) => '${sha256.convert(utf8.encode(key))}.png';

void main() {
  testWidgets('a picture an earlier build kept is neither shown nor kept; '
      'one of this build is shown', (tester) async {
    final web = FakeWebViewPlatform();
    WebViewPlatform.instance = web;
    final root = Directory.systemTemp.createTempSync('preview-cache-');
    addTearDown(() => root.deleteSync(recursive: true));
    debugPreviewSnapshotDirectory = root;
    addTearDown(() => debugPreviewSnapshotDirectory = null);

    const oldKey = 'mermaid:true:kept-by-an-earlier-build';
    const newKey = 'mermaid:true:kept-by-this-build';
    // Earlier builds kept their pictures in `preview_snapshots/` of the app
    // cache, and directly in the folder a test named.
    final retired = Directory('${root.path}/preview_snapshots')..createSync();
    File('${retired.path}/${_fileOf(oldKey)}').writeAsBytesSync(_png);
    File('${root.path}/${_fileOf(oldKey)}').writeAsBytesSync(_png);
    final current = Directory('${root.path}/preview_snapshots_v2')
      ..createSync();
    File('${current.path}/${_fileOf(newKey)}').writeAsBytesSync(_png);

    Widget preview(String key) => SizedBox(
      key: ValueKey(key),
      width: 200,
      child: InlineWebPreview(
        document: () async => '<!doctype html><p>page</p>',
        label: 'Diagram',
        icon: Icons.image,
        snapshotKey: key,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromMode(AppThemeMode.dark),
        home: Scaffold(
          body: Column(children: [preview(oldKey), preview(newKey)]),
        ),
      ),
    );
    Finder pictureOf(String key) => find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byKey(const ValueKey('inline-web-preview-picture')),
    );
    // Both have looked in the cache: one drew a page, one shows a picture
    // (or, when this build's picture is not found, the rounds run out).
    bool settled() =>
        web.controllers.isNotEmpty && pictureOf(newKey).evaluate().isNotEmpty;
    for (var i = 0; i < 60 && !settled(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(pictureOf(newKey), findsOneWidget, reason: 'this build');
    expect(pictureOf(oldKey), findsNothing, reason: 'an earlier build');
    expect(
      web.controllers,
      hasLength(1),
      reason: 'the page of the old picture is drawn again',
    );
    expect(retired.existsSync(), isFalse, reason: 'the old pictures go');
    expect(File('${current.path}/${_fileOf(newKey)}').existsSync(), isTrue);
  });
}
