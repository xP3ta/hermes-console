import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_models.dart';
import 'package:hermes_android/core/bots/ui/room/room_widgets.dart';
import 'package:hermes_android/core/services/artifact_export_service.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/cover_resize_image.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

final class _Actions implements RoomAttachmentActions {
  _Actions(this.file);
  final File file;
  @override
  bool canFetch(RoomAttachmentRef ref) => true;
  @override
  Future<File> fetch(RoomAttachmentRef ref) async => file;
  @override
  Future<void> open(RoomAttachmentRef ref, File file) async {}
  @override
  Future<void> share(RoomAttachmentRef ref, File file) async {}
  @override
  Future<ArtifactSaveResult> save(RoomAttachmentRef ref, File file) async =>
      ArtifactSaveResult.saved;
}

/// The size [provider] asks the decoder for, for a [width]×[height] source.
Future<ui.TargetImageSize> _requestedSize(
  CoverResizeImage provider,
  int width,
  int height,
) async {
  final key = await provider.obtainKey(ImageConfiguration.empty);
  final requested = Completer<ui.TargetImageSize>();
  final completer = provider.loadImage(key, (buffer, {getTargetSize}) {
    requested.complete(getTargetSize!(width, height));
    return Completer<ui.Codec>().future;
  });
  completer.addListener(ImageStreamListener((_, _) {}, onError: (_, _) {}));
  return requested.future;
}

void main() {
  test('cover size keeps the short side at the target, never upscales', () {
    expect(CoverResizeImage.coverSize(4000, 3000, 144), (
      width: 192,
      height: 144,
    ));
    expect(CoverResizeImage.coverSize(3000, 4000, 144), (
      width: 144,
      height: 192,
    ));
    expect(CoverResizeImage.coverSize(1000, 1000, 144), (
      width: 144,
      height: 144,
    ));
    expect(CoverResizeImage.coverSize(100, 80, 144), (width: 100, height: 80));
  });

  test('the decoder is asked for the cover size', () async {
    final provider = CoverResizeImage(
      MemoryImage(Uint8List.fromList(const [1, 2, 3])),
      target: 144,
    );
    final size = await _requestedSize(provider, 4000, 3000);
    expect(size.width, 192);
    expect(size.height, 144);
  });

  // A 48×48 thumbnail decoded the attached photo at full resolution: a
  // 12 MP camera shot became ~48 MB of RGBA on the raster path.
  testWidgets('a room image thumbnail decodes near its box size', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetDevicePixelRatio);
    final file = File('/nonexistent/room-thumb/photo.png');
    const ref = RoomAttachmentRef(name: 'photo.png', path: '/srv/photo.png');

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        locale: const Locale('en'),
        theme: AppTheme.hermesRedDark,
        home: Scaffold(
          body: RoomAttachmentCard(attachment: ref, actions: _Actions(file)),
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('room-attachment-download-/srv/photo.png')),
    );
    await tester.pump();
    await tester.pump();

    final thumb = tester.widget<Image>(find.byType(Image));
    // 48 logical px × 3 = 144 physical px for the short side.
    expect(thumb.image, CoverResizeImage(FileImage(file), target: 144));
    final box = tester.getSize(find.byType(Image));
    expect(box, const Size(48, 48));
  });
}
