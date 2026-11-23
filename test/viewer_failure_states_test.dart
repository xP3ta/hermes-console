// A viewer never stays blank or spinning: it shows the content, or says why
// it cannot, with what still works (try again, open with another app, share,
// save). Each test drives one way a file or a page can fail and reads what
// the user sees.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/generated_media_service.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_html_policy.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_viewer_screen.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/web_preview.dart';
import 'package:hermes_android/core/widgets/attachment_card.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/core/widgets/chat/embeds/document_previews.dart';
import 'package:hermes_android/core/widgets/generated_video_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'support/fake_video_player_platform.dart';
import 'support/fake_webview_platform.dart';

// A 1×1 PNG, as the model page hands its picture over.
const String _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

/// Every WebView answers its page's questions through [answer].
class _PagePlatform extends FakeWebViewPlatform {
  Object Function(String script) answer = _drawing;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller =
        super.createPlatformWebViewController(params) as FakeWebViewController;
    controller.javaScriptResponder = (script) => answer(script);
    return controller;
  }
}

/// A page still drawing: it never says it has drawn or failed.
Object _drawing(String script) => 0;

/// A page whose error channel caught what the library said (quoted and
/// URI-encoded, as the Android WebView hands a string back).
Object _failed(String script) {
  if (script.contains('===2')) return 1;
  if (script.contains('.m||')) {
    return '"THREE.GLTFLoader%3A%20setMeshoptDecoder%20must%20be%20called"';
  }
  return 0;
}

/// A model page that has drawn and hands its picture over.
Object _drawn(String script) {
  if (script.contains('===1')) return 1;
  if (script.contains('toDataURL')) {
    return '"data:image/png;base64,$_pngBase64"';
  }
  return 0;
}

/// A GLB holding [json] and no binary chunk.
Uint8List _glb(Map<String, Object?> json) {
  final text = utf8.encode(jsonEncode(json));
  final padded = (text.length + 3) & ~3;
  List<int> word(int value) => [
    for (var shift = 0; shift < 32; shift += 8) (value >> shift) & 0xFF,
  ];
  return Uint8List.fromList([
    ...word(0x46546C67),
    ...word(2),
    ...word(20 + padded),
    ...word(padded),
    ...word(0x4E4F534A),
    ...text,
    for (var i = text.length; i < padded; i++) 0x20,
  ]);
}

class _NoSettings implements ArtifactWebViewPlatformSettings {
  @override
  Future<void> setAllowFileAccess(bool allow) async {}
  @override
  Future<void> setAllowContentAccess(bool allow) async {}
  @override
  Future<void> setGeolocationEnabled(bool enabled) async {}
  @override
  Future<void> denyGeolocationPrompts() async {}
  @override
  Future<void> setMixedContentNeverAllow() async {}
  @override
  Future<void> setMediaPlaybackRequiresUserGesture(bool require) async {}
  @override
  Future<void> refuseFileChooser() async {}
}

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.fromMode(AppThemeMode.dark),
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(body: child),
);

/// Lets real file reads and isolates finish between frames, while the
/// page's watch runs on the test clock.
Future<void> _drive(WidgetTester tester, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// [_drive] until [done] holds (the digest of the file is read in another
/// isolate, which takes a moment of real time before a page is made).
///
/// The bound is only a ceiling: the wait ends as soon as [done] holds, and on
/// a loaded host that moment can be seconds away.
Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late _PagePlatform web;
  late Directory directory;

  setUp(() {
    web = _PagePlatform();
    WebViewPlatform.instance = web;
    directory = Directory.systemTemp.createTempSync('viewer-failure-');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  File model(String name, Map<String, Object?> json) =>
      File('${directory.path}/$name')..writeAsBytesSync(_glb(json));

  Widget inlineModel(File file) => Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: 360,
      child: DocumentFilePreview.model(
        file: file,
        name: file.path.split('/').last,
        onOpen: () {},
      ),
    ),
  );

  group('3D model inside the chat', () {
    testWidgets('a model whose page fails says why, and Retry draws it '
        'again', (tester) async {
      final file = model('casco_web.glb', {
        'asset': {'version': '2.0', 'generator': 'retry'},
        'extensionsUsed': ['EXT_meshopt_compression'],
      });
      web.answer = _failed;
      await tester.pumpWidget(_host(inlineModel(file)));
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('web-page-failure'))
            .evaluate()
            .isNotEmpty,
      );

      expect(find.text('This 3D model could not be drawn.'), findsOneWidget);
      expect(
        find.text('THREE.GLTFLoader: setMeshoptDecoder must be called'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('web-page-retry')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('fake-platform-webview')),
        findsNothing,
        reason: 'no grey page is left behind',
      );
      expect(web.controllers, hasLength(1));

      web.answer = _drawn;
      await tester.tap(find.byKey(const ValueKey('web-page-retry')));
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('inline-web-preview-picture'))
            .evaluate()
            .isNotEmpty,
      );

      expect(web.controllers, hasLength(2), reason: 'a new page was made');
      expect(
        find.byKey(const ValueKey('inline-web-preview-picture')),
        findsOneWidget,
      );
      expect(find.text('This 3D model could not be drawn.'), findsNothing);
    });

    testWidgets('a model that never draws is given up at its deadline', (
      tester,
    ) async {
      final file = model('slow.glb', {
        'asset': {'version': '2.0', 'generator': 'deadline'},
      });
      web.answer = _drawing;
      await tester.pumpWidget(_host(inlineModel(file)));
      await _until(
        tester,
        () => web.controllers.expand((c) => c.loadedHtml).isNotEmpty,
      );
      expect(web.controllers, hasLength(1));
      expect(find.text('This 3D model could not be drawn.'), findsNothing);

      await tester.pump(const Duration(seconds: 46));
      await tester.pump();

      expect(find.text('This 3D model could not be drawn.'), findsOneWidget);
      expect(find.text('It took too long to draw.'), findsOneWidget);
      expect(find.byKey(const ValueKey('web-page-retry')), findsOneWidget);
    });

    testWidgets('an empty file and a glTF that points to files it did not '
        'bring say so without making a page', (tester) async {
      final empty = File('${directory.path}/empty.glb')..writeAsBytesSync([]);
      final external = File('${directory.path}/box.gltf')
        ..writeAsStringSync(
          jsonEncode({
            'asset': {'version': '2.0'},
            'buffers': [
              {'uri': 'Box0.bin', 'byteLength': 648},
            ],
          }),
        );
      bool failed() =>
          find.byKey(const ValueKey('web-page-failure')).evaluate().isNotEmpty;
      await tester.pumpWidget(_host(inlineModel(empty)));
      await _until(tester, failed);
      expect(find.text('The file is empty.'), findsOneWidget);

      await tester.pumpWidget(_host(inlineModel(external)));
      await _until(tester, failed);
      expect(
        find.text(
          'This model needs files that did not come with it: Box0.bin.',
        ),
        findsOneWidget,
      );
      expect(web.controllers.expand((c) => c.loadedHtml), isEmpty);
    });
  });

  group('3D model full screen', () {
    Widget viewer(
      Uint8List bytes, {
      VoidCallback? onOpenExternal,
      VoidCallback? onShare,
      VoidCallback? onSave,
    }) => ArtifactViewerScreen(
      name: 'casco_web.glb',
      mimeType: 'model/gltf-binary',
      loadBytes: () async => bytes,
      sizeBytes: bytes.length,
      onOpenExternal: onOpenExternal,
      onShare: onShare,
      onSave: onSave,
      webViewSettingsFor: (_) => _NoSettings(),
    );

    testWidgets('a model that fails shows why with Retry, Open with, Share '
        'and Save', (tester) async {
      var opened = 0;
      var shared = 0;
      var saved = 0;
      web.answer = _failed;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.fromMode(AppThemeMode.dark),
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: viewer(
            _glb({
              'asset': {'version': '2.0', 'generator': 'full'},
            }),
            onOpenExternal: () => opened++,
            onShare: () => shared++,
            onSave: () => saved++,
          ),
        ),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('artifact-viewer-fallback'))
            .evaluate()
            .isNotEmpty,
      );

      expect(
        find.byKey(const ValueKey('artifact-viewer-fallback')),
        findsOneWidget,
      );
      expect(find.text('This 3D model could not be drawn.'), findsOneWidget);
      expect(
        find.text('THREE.GLTFLoader: setMeshoptDecoder must be called'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('artifact-viewer-open-with')));
      await tester.tap(find.text('Share'));
      await tester.tap(find.text('Save'));
      expect((opened, shared, saved), (1, 1, 1));

      web.answer = _drawn;
      await tester.tap(find.byKey(const ValueKey('artifact-viewer-retry')));
      await _until(tester, () => web.controllers.length == 2);
      // The second page answers «drawn» a moment later: wait for the view
      // itself, not for a fixed number of frames.
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('fake-platform-webview'))
            .evaluate()
            .isNotEmpty,
      );
      await _drive(tester, rounds: 2);
      expect(web.controllers, hasLength(2));
      expect(
        find.byKey(const ValueKey('artifact-viewer-fallback')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('fake-platform-webview')), findsOne);
    });

    testWidgets('a model over the limit names the limit, not an unknown '
        'type', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: viewer(Uint8List(kModelMaxBytes + 1), onShare: () {}),
        ),
      );
      await _drive(tester, rounds: 2);
      expect(
        find.text(
          'This model is larger than 24 MB, too large to draw here. You can '
          'open it with another app or share it.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining("can't be viewed"), findsNothing);
      expect(web.controllers, isEmpty);
    });
  });

  testWidgets('a full screen diagram whose page fails says so and can try '
      'again', (tester) async {
    web.answer = _failed;
    var made = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: WebDocumentScreen(
          title: 'Diagram',
          document: () async {
            made++;
            return '<!doctype html><p>page</p>';
          },
        ),
      ),
    );
    await _drive(tester);
    expect(find.text('This preview could not be drawn.'), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-platform-webview')), findsNothing);

    web.answer = (script) => script.contains('readyState') ? 1 : 0;
    await tester.tap(find.byKey(const ValueKey('web-page-retry')));
    await _drive(tester);
    expect(made, 2);
    expect(find.text('This preview could not be drawn.'), findsNothing);
    expect(find.byKey(const ValueKey('fake-platform-webview')), findsOne);
  });

  group('images', () {
    testWidgets('an image the decoder cannot read says so and keeps the '
        "file's actions", (tester) async {
      var shared = 0;
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: Strings.localizationsDelegates,
            supportedLocales: Strings.supportedLocales,
            home: ArtifactViewerScreen(
              name: 'broken.png',
              mimeType: 'image/png',
              loadBytes: () async => Uint8List.fromList([1, 2, 3]),
              onOpenExternal: () {},
              onShare: () => shared++,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        // Waits for the codec's own failure (real I/O), as the image
        // card test does.
        final image = tester.widget<Image>(find.byType(Image));
        final failed = Completer<void>();
        final stream = image.image.resolve(
          createLocalImageConfiguration(tester.element(find.byType(Image))),
        );
        final listener = ImageStreamListener(
          (_, _) => failed.completeError(StateError('decoded garbage')),
          onError: (_, _) => failed.complete(),
        );
        stream.addListener(listener);
        try {
          await failed.future;
        } finally {
          stream.removeListener(listener);
        }
      });
      await tester.pump();
      await tester.pump();
      tester.takeException();

      expect(
        find.byKey(const ValueKey('artifact-viewer-fallback')),
        findsOneWidget,
      );
      expect(find.text('The image could not be opened'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('artifact-viewer-open-with')),
        findsOneWidget,
      );
      await tester.tap(find.text('Share'));
      expect(shared, 1);
    });

    Future<void> loadRemote(
      WidgetTester tester,
      http.Client client,
      String url,
    ) async {
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => ChatGatedImage(
              uri: Uri.parse(url),
              colors: Theme.of(context).hermes,
            ),
          ),
        ),
      );
      final open = tester
          .widget<GestureDetector>(
            find
                .descendant(
                  of: find.byType(ChatGatedImage),
                  matching: find.byType(GestureDetector),
                )
                .first,
          )
          .onTap!;
      await tester.runAsync(
        () => http.runWithClient(() async {
          open();
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }, () => client),
      );
      await tester.pump();
    }

    testWidgets('a remote image that cannot be shown says why under its '
        'retry', (tester) async {
      // GIF89a: a picture, but not one the chat decodes.
      await loadRemote(
        tester,
        _Serve(utf8.encode('GIF89a\u0001\u0000\u0001\u0000'), 'image/gif'),
        'https://images.example/a.gif',
      );
      expect(find.text('The image could not be opened'), findsOneWidget);

      await loadRemote(
        tester,
        _Serve(utf8.encode('<html></html>'), 'text/html'),
        'https://images.example/b.png',
      );
      expect(find.text('The file is not an image'), findsOneWidget);
    });
  });

  testWidgets('a viewer with nothing else to offer does not promise another '
      'app or a share', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: ArtifactViewerScreen(
          name: 'archive.zip',
          mimeType: 'application/zip',
          loadBytes: () async => Uint8List.fromList([1, 2, 3]),
        ),
      ),
    );
    await _drive(tester, rounds: 2);
    expect(
      find.text("This file type can't be viewed inside the app."),
      findsOneWidget,
    );
    expect(find.textContaining('share it'), findsNothing);
  });

  group('playback', () {
    testWidgets('audio the player refuses says so; a new tap starts it '
        'again', (tester) async {
      final file = File('${directory.path}/voice.opus')..writeAsBytesSync([1]);
      final playback = _RefusingPlayback();
      await tester.pumpWidget(
        _host(
          GeneratedAudioPlayerCard(
            file: file,
            name: 'voice.opus',
            mimeType: 'audio/ogg',
            sizeBytes: 1,
            playback: playback,
            onShare: () {},
            onSave: () {},
          ),
        ),
      );
      await tester.tap(find.byTooltip('Play audio'));
      await tester.pump();

      expect(
        find.text(
          'This could not be played here. You can open it with another app '
          'or share it.',
        ),
        findsOneWidget,
      );
      expect(find.text('Share'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);

      await tester.tap(find.byTooltip('Play audio'));
      await tester.pump();
      expect(playback.plays, 2, reason: 'started again, not resumed');
      expect(playback.resumes, 0);
    });

    testWidgets('a video that cannot be opened says so, with Retry, Share '
        'and Save', (tester) async {
      final platform = FakeVideoPlayerPlatform.install();
      platform.failNextInit = true;
      final file = File('${directory.path}/clip.mp4')
        ..writeAsBytesSync(<int>[0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]);
      await tester.pumpWidget(
        _host(SingleChildScrollView(child: GeneratedVideoCard(file: file))),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
      if (find.text('Play').evaluate().isNotEmpty) {
        await tester.tap(find.text('Play'));
        for (var i = 0; i < 6; i++) {
          await tester.pump();
        }
      }

      expect(
        find.byKey(const ValueKey('generated-video-failed')),
        findsOneWidget,
      );
      expect(
        find.text(
          'This could not be played here. You can open it with another app '
          'or share it.',
        ),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
    });
  });

  testWidgets("selecting a reply leaves a file card's name, size and buttons "
      'out', (tester) async {
    final file = File('${directory.path}/notes.txt')
      ..writeAsStringSync('first line of the file');
    String? selected;
    await tester.pumpWidget(
      _host(
        SelectionArea(
          onSelectionChanged: (content) => selected = content?.plainText,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Here is the light version.'),
              GeneratedMediaAttachmentCard(
                reference: const GeneratedMediaReference(
                  source: '/workspace/notes.txt',
                  kind: GeneratedMediaKind.file,
                  sourceKind: GeneratedMediaSourceKind.serverPath,
                  displayName: 'notes.txt',
                  mimeType: 'text/plain',
                  sizeBytes: 22,
                ),
                autoLoad: true,
                load: (onProgress, isCancelled) async => file,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.text('notes.txt'), findsOneWidget, reason: 'the card is in');

    tester
        .state<SelectableRegionState>(find.byType(SelectableRegion))
        .selectAll(SelectionChangedCause.toolbar);
    await tester.pump();

    expect(selected, contains('Here is the light version.'));
    for (final chrome in ['notes.txt', 'Share', 'Save']) {
      expect(selected, isNot(contains(chrome)), reason: chrome);
    }
  });
}

/// Serves [body] as [type] to every request.
class _Serve extends http.BaseClient {
  _Serve(this.body, this.type);

  final List<int> body;
  final String type;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream.value(body),
        200,
        contentLength: body.length,
        headers: {'content-type': type},
      );
}

/// A player that refuses every file.
class _RefusingPlayback implements GeneratedAudioPlayback {
  int plays = 0;
  int resumes = 0;

  @override
  Stream<Duration> get durationChanges => const Stream.empty();

  @override
  Stream<Duration> get positionChanges => const Stream.empty();

  @override
  Stream<bool> get playingChanges => const Stream.empty();

  @override
  Future<void> play(File file) async {
    plays++;
    throw PlatformException(code: 'AndroidAudioError', message: 'codec');
  }

  @override
  Future<void> resume() async => resumes++;

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> dispose() async {}
}
