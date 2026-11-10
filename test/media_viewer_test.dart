// The single media viewer of «Artefactos» and the chat, with the look of
// the owner's mockup (L3-visor) and Desktop's behaviour: paging with «n of N»,
// Desktop's zoom bar, fetching only what is opened or seen as a thumbnail,
// the reason a page failed, the details card, the actions, the strip and
// the ways out.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/tokens.dart' show HermesChrome;
import 'package:hermes_android/core/services/artifact_media.dart';
import 'package:hermes_android/core/services/chat_content_extractor.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/motion.dart' show HermesMotion;
import 'package:hermes_android/core/widgets/artifacts/open_artifact.dart';
import 'package:hermes_android/core/widgets/generated_video_card.dart';
import 'package:hermes_android/core/widgets/media_viewer/media_viewer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/fake_video_player_platform.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

void main() {
  late Directory directory;
  late List<String> fetched;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('media-viewer-');
    fetched = [];
    GeneratedVideoCard.clearPlaybackMemoryForTesting();
  });
  tearDown(() => directory.deleteSync(recursive: true));

  File fileNamed(String name) =>
      File('${directory.path}/$name')..writeAsBytesSync(_png);

  /// An element fetched on demand; [fetched] records each fetch.
  MediaViewerItem item(
    String name, {
    MediaViewerKind kind = MediaViewerKind.image,
    String mimeType = 'image/png',
    String? conversation,
    VoidCallback? onOpenChat,
  }) => MediaViewerItem(
    kind: kind,
    name: name,
    mimeType: mimeType,
    location: '/srv/out/$name',
    conversation: conversation,
    onOpenChat: onOpenChat,
    load: () async {
      fetched.add(name);
      return fileNamed(name);
    },
  );

  Widget app(
    List<MediaViewerItem> items, {
    int initial = 0,
    ThemeData? theme,
    Future<void> Function(MediaViewerItem, File)? launch,
    GlobalKey<NavigatorState>? navigatorKey,
    bool reduceMotion = false,
  }) => MaterialApp(
    navigatorKey: navigatorKey,
    locale: const Locale('en'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    theme: theme ?? AppTheme.hermesRedDark,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MediaViewerScreen(
                  items: items,
                  initialIndex: initial,
                  launchExternal: launch,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );

  void phone(WidgetTester tester) {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
  }

  Future<void> open(WidgetTester tester, Widget host) async {
    await tester.pumpWidget(host);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  final position = find.byKey(const ValueKey('image-gallery-position'));
  final pages = find.byKey(const ValueKey('image-gallery-pages'));

  final strip = find.byKey(const ValueKey('media-viewer-strip'));

  ScrollPhysics? physics(WidgetTester tester) =>
      tester.widget<PageView>(pages).physics;

  /// Index of a strip tile, from its key; null for anything else.
  int? tileIndex(Widget widget) {
    const prefix = 'media-viewer-strip-';
    final key = widget.key;
    if (key is! ValueKey<String> || !key.value.startsWith(prefix)) return null;
    return int.tryParse(key.value.substring(prefix.length));
  }

  /// The strip tiles built, by index.
  List<int> tilesBuilt(WidgetTester tester) {
    final tiles = find.descendant(
      of: strip,
      matching: find.byWidgetPredicate((widget) => tileIndex(widget) != null),
    );
    final widgets = tester.widgetList(tiles);
    return [for (final widget in widgets) tileIndex(widget)!];
  }

  /// Whether the strip tile [i] is highlighted as the one on screen.
  bool highlighted(WidgetTester tester, int i) {
    final tile = tester.widget<Container>(
      find.descendant(
        of: find.byKey(ValueKey('media-viewer-strip-$i')),
        matching: find.byType(Container),
      ),
    );
    return (tile.foregroundDecoration! as BoxDecoration).border != null;
  }

  testWidgets('opens at the element tapped, says where it is and swipes', (
    tester,
  ) async {
    phone(tester);
    final handle = tester.ensureSemantics();
    await open(
      tester,
      app([item('a.png'), item('b.png'), item('c.png')], initial: 1),
    );

    expect(tester.widget<Text>(position).data, '2 of 3');
    expect(find.bySemanticsLabel('2 of 3'), findsOneWidget);
    expect(find.text('b.png'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(highlighted(tester, 1), isTrue);
    expect(highlighted(tester, 0), isFalse);
    // R5C C-V5: a tile decodes its picture bounded in both directions.
    final tile = tester.widget<Image>(
      find.descendant(
        of: find.byKey(const ValueKey('media-viewer-strip-0')),
        matching: find.byType(Image),
      ),
    );
    final resized = tile.image as ResizeImage;
    expect(resized.width, 160);
    expect(resized.height, 160);
    expect(resized.policy, ResizeImagePolicy.fit);
    // The page on screen and the thumbnails seen, each fetched once.
    expect(fetched.toSet(), {'a.png', 'b.png', 'c.png'});

    await tester.fling(pages, const Offset(-300, 0), 1500);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(position).data, '3 of 3');
    expect(highlighted(tester, 2), isTrue);
    expect(fetched, hasLength(3));
    handle.dispose();
  });

  testWidgets('Desktop\'s zoom bar: −, the scale and +, paging paused', (
    tester,
  ) async {
    phone(tester);
    await open(tester, app([item('a.png'), item('b.png')]));

    expect(find.text('100%'), findsOneWidget);
    expect(physics(tester), isA<PageScrollPhysics>());

    await tester.tap(find.byKey(const ValueKey('media-viewer-zoom-in')));
    await tester.pump();
    expect(find.text('125%'), findsOneWidget);
    expect(physics(tester), isA<NeverScrollableScrollPhysics>());

    await tester.tap(find.byKey(const ValueKey('media-viewer-zoom-reset')));
    await tester.pump();
    expect(find.text('100%'), findsOneWidget);
    expect(physics(tester), isA<PageScrollPhysics>());

    // R5C C-V4: decoded bounded until zoomed past 2×, then in full.
    final pageImage = find.descendant(of: pages, matching: find.byType(Image));
    ImageProvider shown() => tester.widget<Image>(pageImage).image;
    final bounded = shown() as ResizeImage;
    expect(bounded.width, lessThanOrEqualTo(4096));
    // A power of two: a small change of the stage does not decode again.
    expect(bounded.width! & (bounded.width! - 1), 0);
    expect(bounded.height, lessThanOrEqualTo(4096));
    expect(bounded.policy, ResizeImagePolicy.fit);
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byKey(const ValueKey('media-viewer-zoom-in')));
      await tester.pump();
    }
    expect(shown(), isA<FileImage>());

    // Desktop's range ends at 800 %.
    for (var i = 0; i < 12; i++) {
      await tester.tap(find.byKey(const ValueKey('media-viewer-zoom-in')));
      await tester.pump();
    }
    expect(find.text('800%'), findsOneWidget);
    final zoomIn = tester.widget<IconButton>(
      find.byKey(const ValueKey('media-viewer-zoom-in')),
    );
    expect(zoomIn.onPressed, isNull);
  });

  testWidgets('a video is fetched only on Play, then plays', (tester) async {
    phone(tester);
    final platform = FakeVideoPlayerPlatform.install();
    await open(
      tester,
      app([
        item('clip.mp4', kind: MediaViewerKind.video, mimeType: 'video/mp4'),
      ]),
    );

    expect(find.byKey(const ValueKey('media-viewer-poster')), findsOneWidget);
    expect(find.text('clip.mp4'), findsWidgets);
    expect(fetched, isEmpty);
    expect(platform.created, isEmpty);

    await tester.tap(find.byKey(const ValueKey('media-viewer-play')));
    for (var i = 0; i < 12; i++) {
      await tester.pump();
    }
    expect(fetched, ['clip.mp4']);
    expect(find.byType(GeneratedVideoCard), findsOneWidget);
    expect(platform.calls, contains('play:1'));
  });

  testWidgets('a failure says why, as its thumbnail; retry fetches again', (
    tester,
  ) async {
    phone(tester);
    var attempts = 0;
    final flaky = MediaViewerItem(
      kind: MediaViewerKind.image,
      name: 'plot.png',
      load: () async {
        attempts++;
        if (attempts == 1) {
          throw const ArtifactFetchFailure(ArtifactFetchProblem.notFound);
        }
        return fileNamed('plot.png');
      },
    );
    const insecure = MediaViewerItem(
      kind: MediaViewerKind.image,
      name: 'old.png',
      problem: ArtifactFetchProblem.insecure,
    );
    await open(tester, app([flaky, insecure]));

    expect(find.text('Not on the server'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsNothing);
    await tester.tap(find.byKey(const ValueKey('media-viewer-retry')));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.byType(InteractiveViewer), findsOneWidget);

    // What the app never fetches has its reason and no retry.
    await tester.fling(pages, const Offset(-300, 0), 1500);
    await tester.pumpAndSettle();
    expect(find.text('Unencrypted http image'), findsOneWidget);
    expect(find.byKey(const ValueKey('media-viewer-retry')), findsNothing);
  });

  testWidgets('content that is not a picture offers no retry', (tester) async {
    phone(tester);
    final text = MediaViewerItem(
      kind: MediaViewerKind.image,
      name: 'chart.png',
      load: () async =>
          throw const ArtifactFetchFailure(ArtifactFetchProblem.notImage),
    );
    await open(tester, app([text]));

    expect(find.text('The file is not an image'), findsOneWidget);
    expect(find.byKey(const ValueKey('media-viewer-retry')), findsNothing);
  });

  testWidgets('one element: no position and nothing to page', (tester) async {
    phone(tester);
    await open(tester, app([item('solo.png')]));

    expect(position, findsNothing);
    expect(physics(tester), isA<NeverScrollableScrollPhysics>());
    expect(find.byKey(const ValueKey('media-viewer-strip')), findsNothing);
    expect(fetched, ['solo.png']);
  });

  testWidgets('50 elements: only the page and the thumbnails on screen are '
      'fetched; a tile jumps to its page', (tester) async {
    phone(tester);
    final items = [for (var i = 0; i < 50; i++) item('img$i.png')];
    await open(tester, app(items));

    expect(tester.widget<Text>(position).data, '1 of 50');
    expect(strip, findsOneWidget);
    // R5C C-V8: on a 360 dp phone a tile still reaches 48 dp.
    final tileSize = tester.getSize(
      find.byKey(const ValueKey('media-viewer-strip-0')),
    );
    expect(tileSize.height, greaterThanOrEqualTo(48));
    expect(tileSize.width, greaterThanOrEqualTo(48));
    final built = tilesBuilt(tester);
    expect(built.length, lessThan(10));
    expect(fetched.toSet(), {for (final i in built) 'img$i.png'});

    await tester.tap(find.byKey(const ValueKey('media-viewer-strip-3')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(position).data, '4 of 50');
    expect(highlighted(tester, 3), isTrue);
    // The strip followed: still only what has been on screen, each once.
    final seen = {...built, ...tilesBuilt(tester)};
    expect(fetched.toSet(), {for (final i in seen) 'img$i.png'});
    expect(fetched, hasLength(fetched.toSet().length));
  });

  testWidgets('the strip fetches its pictures three at a time, only those '
      'on screen', (tester) async {
    // R5C C-V6: a fast scroll through 50 pictures must not start 50
    // downloads at once.
    phone(tester);
    final waits = <String, Completer<File>>{};
    MediaViewerItem slow(String name) => MediaViewerItem(
      kind: MediaViewerKind.image,
      name: name,
      mimeType: 'image/png',
      load: () => (waits[name] = Completer<File>()).future,
    );
    int stripRunning() {
      final running = waits.entries.where(
        (e) => e.key != 'img0.png' && !e.value.isCompleted,
      );
      return running.length;
    }

    await tester.pumpWidget(
      app([for (var i = 0; i < 50; i++) slow('img$i.png')]),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The page on screen, and three tiles of the strip.
    expect(waits.keys, contains('img0.png'));
    expect(stripRunning(), 3);
    expect(waits, hasLength(4));

    // One ends: the next tile on screen takes its turn.
    waits['img1.png']!.complete(fileNamed('img1.png'));
    await tester.pump();
    await tester.pump();
    expect(stripRunning(), 3);
    expect(waits, hasLength(5));

    // A fast scroll: still at most three running.
    await tester.drag(strip, const Offset(-800, 0));
    await tester.pump();
    expect(stripRunning(), 3);
    expect(waits, hasLength(5));
  });

  testWidgets('the sheet: handle, «n of N», the capsule and the details '
      'card «PNG  1 × 1 px  70 B»', (tester) async {
    phone(tester);
    await open(tester, app([item('a.png'), item('b.png')]));

    expect(find.byKey(const ValueKey('media-viewer-handle')), findsOneWidget);
    expect(find.byKey(const ValueKey('media-viewer-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('media-viewer-share')), findsOneWidget);
    expect(find.byKey(const ValueKey('media-viewer-save')), findsOneWidget);
    // No close button: Desktop's lightbox has none either.
    expect(find.byIcon(Icons.close), findsNothing);
    final meta = tester.widget<Text>(
      find.byKey(const ValueKey('media-viewer-meta')),
    );
    expect(meta.data, 'PNG  1 × 1 px  ${_png.length} B');
  });

  testWidgets('a picture without a name is «Image 1»', (tester) async {
    phone(tester);
    await open(
      tester,
      app([
        MediaViewerItem(kind: MediaViewerKind.image, file: fileNamed('x.png')),
      ]),
    );
    expect(find.text('Image 1'), findsOneWidget);
  });

  testWidgets('the details card opens path, conversation and «Chat»; the '
      'chat opens with the viewer gone', (tester) async {
    phone(tester);
    final navigator = GlobalKey<NavigatorState>();
    final plot = item(
      'plot.png',
      conversation: 'Ventas Q3',
      onOpenChat: () => navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('chat')),
      ),
    );
    await open(tester, app([plot], navigatorKey: navigator));

    final details = find.byKey(const ValueKey('media-viewer-details'));
    expect(details, findsNothing);
    await tester.tap(find.byKey(const ValueKey('media-viewer-title')));
    await tester.pumpAndSettle();
    expect(details, findsOneWidget);
    Finder inDetails(String text) =>
        find.descendant(of: details, matching: find.text(text));
    expect(inDetails('/srv/out/plot.png'), findsOneWidget);
    expect(inDetails('Ventas Q3'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('media-viewer-open-chat')));
    await tester.pumpAndSettle();
    expect(find.text('chat'), findsOneWidget);
    // Back from the chat lands where the viewer was opened, not on it.
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(MediaViewerScreen), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('the capsule copies the path as it was written', (tester) async {
    phone(tester);
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
    await open(tester, app([item('a.png')]));

    await tester.tap(find.byTooltip('Copy path'));
    await tester.pumpAndSettle();
    expect(copied, '/srv/out/a.png');
  });

  testWidgets('a document is fetched only when asked, then opens outside', (
    tester,
  ) async {
    phone(tester);
    final launched = <String>[];
    final pdf = item(
      'informe.pdf',
      kind: MediaViewerKind.document,
      mimeType: 'application/pdf',
    );
    Future<void> launch(MediaViewerItem element, File file) async =>
        launched.add(element.name!);
    await open(tester, app([pdf], launch: launch));

    expect(find.byKey(const ValueKey('media-viewer-document')), findsOneWidget);
    expect(fetched, isEmpty);
    // A PDF is not drawn in the app: no «View in the app».
    expect(find.byKey(const ValueKey('media-viewer-view')), findsNothing);
    expect(
      find.byKey(const ValueKey('media-viewer-save-file')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('media-viewer-open-outside')));
    await tester.pumpAndSettle();
    expect(fetched, ['informe.pdf']);
    expect(launched, ['informe.pdf']);
  });

  testWidgets('«Guardar» copies the file by blocks, never loading it', (
    tester,
  ) async {
    // R5C C-V9 refused a file past 20 MB because «Guardar» loaded it whole
    // into memory. DESCARGAS-DIRECTAS: Android copies it by blocks from its
    // path, so no file is too large and no byte crosses the channel.
    phone(tester);
    const channel = MethodChannel('hermes/save_to_device');
    const doc = 'content://com.android.externalstorage.documents/document/3';
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'pick' ? doc : 1;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final pdf = item(
      'informe.pdf',
      kind: MediaViewerKind.document,
      mimeType: 'application/pdf',
    );
    await open(tester, app([pdf]));

    await tester.tap(find.byKey(const ValueKey('media-viewer-save-file')));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(fetched, ['informe.pdf']);
    expect(calls.map((c) => c.method), ['pick', 'copy']);
    expect((calls.first.arguments as Map)['name'], 'informe.pdf');
    final copy = calls.last.arguments as Map;
    expect(copy['path'], '${directory.path}/informe.pdf');
    expect(copy['uri'], doc);
    expect(copy.containsKey('bytes'), isFalse);
    expect(find.text('Too large to save from here. Use Share.'), findsNothing);
    expect(find.text('Saved: informe.pdf'), findsOne);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('dragging the sheet down closes; so does its handle', (
    tester,
  ) async {
    phone(tester);
    await open(tester, app([item('a.png')]));

    final gesture = await tester.startGesture(const Offset(180, 400));
    // Past the drag's slop (18) and short of a pan's (36), as a finger.
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(MediaViewerScreen), findsNothing);

    // Zoomed, the same drag pans the picture and the viewer stays.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('media-viewer-zoom-in')));
    await tester.pump();
    final pan = await tester.startGesture(const Offset(180, 400));
    await pan.moveBy(const Offset(0, 20));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await pan.moveBy(const Offset(0, 40));
      await tester.pump();
    }
    await pan.up();
    await tester.pumpAndSettle();
    expect(find.byType(MediaViewerScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(MediaViewerScreen), findsNothing);
  });

  final sheet = find.byKey(
    const ValueKey<String>('generated-image-viewer-safe-area'),
  );

  /// Let go of a drag of the sheet [dy] dp down, slowly (no fling).
  Future<void> dragSheet(WidgetTester tester, double dy) async {
    final gesture = await tester.startGesture(const Offset(180, 400));
    var at = Duration.zero;
    Future<void> move(double by) async {
      at += HermesMotion.base;
      await gesture.moveBy(Offset(0, by), timeStamp: at);
      await tester.pump();
    }

    // Past the drag's slop (18) and short of a pan's (36), as a finger.
    await move(20);
    for (var left = dy - 20; left > 0; left -= 40) {
      await move(left < 40 ? left : 40);
    }
    await gesture.up(timeStamp: at + HermesMotion.base);
  }

  // Audit FLUIDEZ B1: let go far enough, the sheet went back up before
  // fading; now it leaves from where the finger left it. Short of that it
  // goes back to its place in HermesMotion.base, at once with «reduce
  // motion».
  for (final reduce in [false, true]) {
    final how = reduce ? 'at once' : 'in HermesMotion.base';
    testWidgets('a drag let go short comes back $how; far enough, it goes '
        'on down', (tester) async {
      phone(tester);
      await open(tester, app([item('a.png')], reduceMotion: reduce));
      final rest = tester.getRect(sheet);

      await dragSheet(tester, 80);
      await tester.pump();
      if (reduce) {
        expect(tester.getRect(sheet), rest);
      } else {
        expect(tester.getRect(sheet).top, greaterThan(rest.top + 30));
        await tester.pump(HermesMotion.base);
        expect(tester.getRect(sheet), rest);
      }
      expect(find.byType(MediaViewerScreen), findsOneWidget);

      await dragSheet(tester, 340);
      final dragged = tester.getRect(sheet).top;
      expect(dragged, greaterThan(rest.top + 200));
      await tester.pump();
      expect(tester.getRect(sheet).top, greaterThanOrEqualTo(dragged));
      await tester.pumpAndSettle();
      expect(find.byType(MediaViewerScreen), findsNothing);
    });
  }

  // Ola 7 (AUDITORIA-PULIDO §4.2, v25 `.sheet`): the sheet of
  // showMediaViewer rises over the dimmed chat and goes back down; with
  // «reduce motion» it is there, and gone, at once.
  Widget shown(List<MediaViewerItem> items, {bool reduceMotion = false}) {
    return MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => unawaited(showMediaViewer(context, items)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('the sheet rises from below and goes back down', (tester) async {
    phone(tester);
    await tester.pumpWidget(shown([item('a.png')]));
    await tester.tap(find.text('open'));
    // The route's first frame is offstage (the hero controller measures
    // it at 0): the sheet is seen from the next one, a tenth of the way.
    await tester.pump();
    await tester.pump(HermesMotion.sheetOpen ~/ 10);
    final first = tester.getRect(sheet);
    await tester.pump(HermesMotion.sheetOpen);
    final rest = tester.getRect(sheet);
    expect(first.top, greaterThan(rest.top + 100), reason: 'from below');
    expect(first.size, rest.size);
    await tester.pump(HermesMotion.sheetOpen);
    expect(tester.getRect(sheet), rest);

    await tester.tap(find.byTooltip('Close'));
    await tester.pump();
    await tester.pump(HermesMotion.sheetClose ~/ 2);
    expect(tester.getRect(sheet).top, greaterThan(rest.top));
    await tester.pump(HermesMotion.sheetClose);
    expect(find.byType(MediaViewerScreen), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('reduce motion: the sheet is there, and gone, at once', (
    tester,
  ) async {
    phone(tester);
    await tester.pumpWidget(shown([item('a.png')], reduceMotion: true));
    await tester.tap(find.text('open'));
    await tester.pump();
    final first = tester.getRect(sheet);
    await tester.pump(HermesMotion.sheetOpen);
    expect(tester.getRect(sheet), first);

    await tester.tap(find.byTooltip('Close'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(MediaViewerScreen), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('light theme: the sheet and its capsules take the theme', (
    tester,
  ) async {
    phone(tester);
    final theme = AppTheme.hermesRedLight;
    final colors = theme.hermes;
    await open(tester, app([item('a.png')], theme: theme));

    BoxDecoration decoration(String key) =>
        tester.widget<DecoratedBox>(find.byKey(ValueKey(key))).decoration
            as BoxDecoration;
    // Ola 3: the sheet is the solid chrome of what floats, from the theme.
    expect(
      decoration('generated-image-viewer-safe-area').color,
      HermesChrome.of(colors).opaque,
    );
    expect(
      decoration('media-viewer-zoom').color,
      Color.alphaBlend(
        colors.textPrimary.withValues(alpha: .08),
        colors.surface,
      ),
    );
  });

  group('from «Artefactos»', () {
    ChatContentItem content(ChatContentKind kind, String value) =>
        ChatContentItem(
          kind: kind,
          value: value,
          href: value,
          label: value.split('/').last,
        );

    test('the viewer pages through images, then files; links stay out', () {
      final link = content(ChatContentKind.link, 'https://example.com/a');
      final pdf = content(ChatContentKind.file, '/srv/out/informe.pdf');
      final a = content(ChatContentKind.image, '/srv/out/a.png');
      final b = content(ChatContentKind.image, '/srv/out/b.png');
      expect(artifactViewerOrder([link, pdf, a, b]), [a, b, pdf]);
    });

    testWidgets('opens at the item tapped and fetches it with its '
        'conversation\'s download', (tester) async {
      phone(tester);
      final a = content(ChatContentKind.image, '/srv/out/a.png');
      final clip = content(ChatContentKind.file, '/srv/out/clip.mp4');
      final old = content(ChatContentKind.image, 'http://example.com/old.png');
      final group = [a, clip, old];
      final asked = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.hermesRedDark,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => openArtifactsInViewer(
                context,
                initial: clip,
                group: group,
                download: (each, reference) async {
                  asked.add(reference.source);
                  return fileNamed(each.label);
                },
                conversation: 'Ventas Q3',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(tester.widget<Text>(position).data, '2 of 3');
      // A clip waits for «Play»; only the thumbnail of a.png was fetched.
      expect(find.byKey(const ValueKey('media-viewer-poster')), findsOneWidget);
      expect(asked, ['/srv/out/a.png']);

      await tester.fling(pages, const Offset(300, 0), 1500);
      await tester.pumpAndSettle();
      expect(asked, ['/srv/out/a.png']);

      await tester.fling(pages, const Offset(-300, 0), 1500);
      await tester.pumpAndSettle();
      await tester.fling(pages, const Offset(-300, 0), 1500);
      await tester.pumpAndSettle();
      expect(find.text('Unencrypted http image'), findsOneWidget);
      expect(asked, ['/srv/out/a.png']);
    });
  });
}
