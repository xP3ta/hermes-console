import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Android `MainActivity` channel that exposes clipboard images.
const clipboardImageChannel = MethodChannel('hermes/clipboard');

/// Answers like `MainActivity`'s clipboard channel and records every call.
/// [read] is the `readImage` reply (`null` when the clip has no image).
class FakeNativeClipboard {
  FakeNativeClipboard({this.hasImage = true, this.read});

  bool hasImage;
  Map<String, Object?>? read;
  final List<String> calls = [];

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(clipboardImageChannel, (call) async {
          calls.add(call.method);
          return switch (call.method) {
            'hasImage' => hasImage,
            'readImage' => read,
            _ => null,
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(clipboardImageChannel, null),
    );
  }
}

/// Opens the long-press text menu (Copy/Paste…) of [field] the way a
/// long-press does, and lets the async clipboard probes settle.
Future<void> openComposerTextMenu(WidgetTester tester, Finder field) async {
  await tester.tap(field);
  await tester.pump();
  tester
      .state<EditableTextState>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      )
      .showToolbar();
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}
