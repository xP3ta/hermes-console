// F5 of the fluidity plan (REPORT-AUDITORIA-FLUIDEZ §3, A4/A5, P1): a
// generated PDF or video holds its final box from the first frame, so it
// takes its place without moving the chat; what changes eases
// (HermesMotion), and with reduced motion it is instant.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/attachment_card.dart';
import 'package:hermes_android/core/widgets/generated_video_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/fake_video_player_platform.dart';

Widget _host(Widget child, {bool reduceMotion = false}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
    child: home!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  ),
);

void main() {
  group('A4: a generated PDF', () {
    late Directory directory;
    late File file;
    const channel = MethodChannel('hermes/document_preview');
    // Called when a test runs: the group's body runs before the binding
    // exists (gint56: the file did not load; gint57: a local getter is not
    // Dart, it is a function).
    TestDefaultBinaryMessenger messenger() =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('f5-pdf-');
      final cache = Directory(
        '${directory.path}/generated_media/${'a' * 64}',
      )..createSync(recursive: true);
      file = File('${cache.path}/${'b' * 64}.pdf')
        ..writeAsBytesSync(utf8.encode('%PDF-1.4\n'));
    });
    tearDown(() {
      messenger().setMockMethodCallHandler(channel, null);
      directory.deleteSync(recursive: true);
    });

    Widget card({bool reduceMotion = false, bool animateSize = true}) =>
        _host(
          GeneratedPdfPreviewCard(
            file: file,
            name: 'informe.pdf',
            sizeBytes: file.lengthSync(),
            onOpen: () {},
            onShare: () {},
            onSave: () {},
            animateSize: animateSize,
          ),
          reduceMotion: reduceMotion,
        );

    testWidgets('while its page renders it is already an A4 card with its '
        'caption and its actions', (tester) async {
      // The first page never comes back: the card stays loading.
      final never = Completer<Object?>();
      messenger().setMockMethodCallHandler(channel, (_) => never.future);
      await tester.pumpWidget(card());
      await tester.pump();
      final loading = find.byKey(const ValueKey('generated-pdf-loading'));
      expect(loading, findsOneWidget);
      final caption = find.byKey(const ValueKey('generated-pdf-caption'));
      final width = tester.getSize(loading).width;
      expect(width, closeTo(320 / math.sqrt2, 0.5));
      expect(
        tester.getSize(loading).height,
        closeTo(width * math.sqrt2 + tester.getSize(caption).height, 0.5),
        reason: 'an A4 page and its caption, before the page is there',
      );
      // Its actions hold their place, not active yet.
      final actions = find.byKey(const ValueKey('generated-pdf-actions'));
      expect(actions, findsOneWidget);
      // TextButton.icon is a subclass: matched by `is`, not by its type.
      final buttons = tester.widgetList<TextButton>(
        find.descendant(
          of: actions,
          matching: find.byWidgetPredicate((widget) => widget is TextButton),
        ),
      );
      expect(buttons, hasLength(3));
      for (final button in buttons) {
        expect(button.onPressed, isNull);
      }
      expect(find.byType(AnimatedSize), findsWidgets);
    });

    testWidgets('TalkBack hears the page loading; inside a card that eases '
        'its size it does not ease twice', (tester) async {
      final semantics = tester.ensureSemantics();
      final never = Completer<Object?>();
      messenger().setMockMethodCallHandler(channel, (_) => never.future);
      await tester.pumpWidget(card(animateSize: false));
      await tester.pump();
      final strings = lookupStrings(const Locale('es'));
      expect(find.bySemanticsLabel(strings.genMediaLoading), findsOneWidget);
      expect(find.byType(AnimatedSize), findsNothing);
      semantics.dispose();
    });

    testWidgets('reduced motion: no animation', (tester) async {
      final never = Completer<Object?>();
      messenger().setMockMethodCallHandler(channel, (_) => never.future);
      await tester.pumpWidget(card(reduceMotion: true));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('generated-pdf-loading')),
        findsOneWidget,
      );
      expect(find.byType(AnimatedSize), findsNothing);
    });
  });

  group('A5: a generated video', () {
    late Directory directory;
    late File file;

    setUp(() {
      // A 16:9 clip (320×180), the usual shape.
      FakeVideoPlayerPlatform.install(duration: const Duration(seconds: 5));
      directory = Directory.systemTemp.createTempSync('f5-video-');
      file = File('${directory.path}/clip.mp4')
        ..writeAsBytesSync(<int>[0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]);
      GeneratedVideoCard.clearPlaybackMemoryForTesting();
    });
    tearDown(() => directory.deleteSync(recursive: true));

    testWidgets('TalkBack hears the controls from the fade\'s first frame, and '
        'not the placeholder going out (gint58)', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      final strings = lookupStrings(const Locale('es'));
      await tester.pumpWidget(_host(GeneratedVideoCard(file: file)));
      // No time passes: the player comes in at opacity 0.
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
      expect(
        find.bySemanticsLabel(strings.videoPlayerSeekBack),
        findsWidgets,
        reason: 'the incoming controls are read at once',
      );
      expect(
        find.bySemanticsLabel(strings.genMediaLoading),
        findsNothing,
        reason: 'the placeholder going out is not said twice',
      );
      semantics.dispose();
    });

    testWidgets('the placeholder is the player\'s box: a 16:9 clip takes its '
        'place without moving anything', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final videoCard = find.byType(GeneratedVideoCard);
      await tester.pumpWidget(_host(GeneratedVideoCard(file: file)));
      expect(
        find.byKey(const ValueKey('generated-video-placeholder')),
        findsOneWidget,
      );
      final before = tester.getSize(videoCard).height;
      // The width inside the padding is 358: 358 × 9 / 16 ≈ 201.
      expect(before, closeTo(math.max(200, 358 * 9 / 16), 0.5));
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('generated-video-placeholder')),
        findsNothing,
        reason: 'the player is in',
      );
      expect(tester.getSize(videoCard).height, closeTo(before, 0.5));
    });
  });
}
