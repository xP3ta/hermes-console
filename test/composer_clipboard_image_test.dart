import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/clipboard_image_source.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/clipboard_image_fake.dart';

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  locale: const Locale('es'),
  theme: AppTheme.hermesRedDark,
  home: Scaffold(
    body: Align(alignment: Alignment.bottomCenter, child: child),
  ),
);

/// Text side of the system clipboard (Flutter's own Paste reads it).
void _mockTextClipboard(String? text) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        switch (call.method) {
          case 'Clipboard.hasStrings':
            return {'value': text != null && text.isNotEmpty};
          case 'Clipboard.getData':
            return text == null ? null : {'text': text};
        }
        return null;
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );
}

final _png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4]);

void main() {
  late TextEditingController controller;
  late FocusNode focusNode;

  setUp(() {
    controller = TextEditingController();
    focusNode = FocusNode();
  });

  tearDown(() {
    controller.dispose();
    focusNode.dispose();
    ClipboardImageSource.appLocked = null;
  });

  Future<List<KeyboardInsertedContent>> pumpComposer(
    WidgetTester tester, {
    bool withInsertion = true,
  }) async {
    final inserted = <KeyboardInsertedContent>[];
    await tester.pumpWidget(
      _host(
        ConsoleComposer(
          controller: controller,
          focusNode: focusNode,
          onSend: (_, _) {},
          sendEnabled: true,
          onContentInserted: withInsertion ? inserted.add : null,
        ),
      ),
    );
    return inserted;
  }

  Future<void> openMenu(WidgetTester tester) =>
      openComposerTextMenu(tester, find.byType(TextField));

  testWidgets('the menu offers "Pegar imagen" when the clipboard has one', (
    tester,
  ) async {
    _mockTextClipboard(null);
    final clipboard = FakeNativeClipboard()..install();
    await pumpComposer(tester);
    await openMenu(tester);

    expect(clipboard.calls, contains('hasImage'));
    expect(find.text('Pegar imagen'), findsOneWidget);
  });

  testWidgets('no "Pegar imagen" when the clipboard holds no image', (
    tester,
  ) async {
    _mockTextClipboard('hola');
    final clipboard = FakeNativeClipboard(hasImage: false)..install();
    await pumpComposer(tester);
    await openMenu(tester);

    expect(clipboard.calls, ['hasImage']);
    expect(find.text('Pegar'), findsOneWidget);
    expect(find.text('Pegar imagen'), findsNothing);
  });

  testWidgets('a missing native channel hides the item without crashing', (
    tester,
  ) async {
    _mockTextClipboard('hola');
    await pumpComposer(tester);
    await openMenu(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Pegar'), findsOneWidget);
    expect(find.text('Pegar imagen'), findsNothing);
    // iOS and other hosts have no channel: both calls degrade quietly.
    final hasImage = await tester.runAsync(ClipboardImageSource.hasImage);
    final read = await tester.runAsync(ClipboardImageSource.readImage);
    expect(hasImage, isFalse);
    expect(read, isNull);
  });

  testWidgets('composers without image insertion never probe the clipboard', (
    tester,
  ) async {
    _mockTextClipboard('hola');
    final clipboard = FakeNativeClipboard()..install();
    await pumpComposer(tester, withInsertion: false);
    await openMenu(tester);

    expect(clipboard.calls, isEmpty);
    expect(find.text('Pegar imagen'), findsNothing);
  });

  testWidgets('App Lock locked: the clipboard is neither probed nor read', (
    tester,
  ) async {
    _mockTextClipboard(null);
    final clipboard = FakeNativeClipboard(
      read: {'mimeType': 'image/png', 'name': 'shot.png', 'bytes': _png},
    )..install();
    final locked = ValueNotifier<bool>(true);
    addTearDown(locked.dispose);
    ClipboardImageSource.appLocked = locked;
    await pumpComposer(tester);
    await openMenu(tester);

    expect(find.text('Pegar imagen'), findsNothing);
    expect(await ClipboardImageSource.readImage(), isNull);
    expect(clipboard.calls, isEmpty);
  });

  testWidgets(
    'tapping "Pegar imagen" hands the clipboard bytes to the composer',
    (tester) async {
      _mockTextClipboard(null);
      final clipboard = FakeNativeClipboard(
        read: {'mimeType': 'image/png', 'name': 'chart.png', 'bytes': _png},
      )..install();
      final inserted = await pumpComposer(tester);
      await openMenu(tester);
      await tester.tap(find.text('Pegar imagen'));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }

      expect(clipboard.calls, ['hasImage', 'readImage']);
      expect(inserted, hasLength(1));
      expect(inserted.single.mimeType, 'image/png');
      expect(inserted.single.data, _png);
      expect(find.text('Pegar imagen'), findsNothing, reason: 'menu closes');
    },
  );

  testWidgets('a clip refused natively (too large) arrives without bytes', (
    tester,
  ) async {
    _mockTextClipboard(null);
    FakeNativeClipboard(
      read: {'mimeType': 'image/png', 'name': 'huge.png', 'tooLarge': true},
    ).install();
    final inserted = await pumpComposer(tester);
    await openMenu(tester);
    await tester.tap(find.text('Pegar imagen'));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    // The composer's shared helper refuses a payload without bytes with the
    // usual notice; nothing is read in full on the Dart side.
    expect(inserted, hasLength(1));
    expect(inserted.single.data, isNull);
  });

  testWidgets(
    'text and image on the clipboard: both items; text paste unchanged',
    (tester) async {
      _mockTextClipboard('hola mundo');
      final clipboard = FakeNativeClipboard(
        read: {'mimeType': 'image/png', 'name': 'shot.png', 'bytes': _png},
      )..install();
      final inserted = await pumpComposer(tester);
      await openMenu(tester);

      expect(find.text('Pegar'), findsOneWidget);
      expect(find.text('Pegar imagen'), findsOneWidget);
      await tester.tap(find.text('Pegar'));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }

      expect(controller.text, 'hola mundo');
      expect(inserted, isEmpty);
      expect(clipboard.calls, isNot(contains('readImage')));
    },
  );
}
