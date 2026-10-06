import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_models.dart';
import 'package:hermes_android/core/bots/ui/room/room_widgets.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/services/artifact_export_service.dart';
import 'package:hermes_android/core/services/attachment_uploader.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/attachment_card.dart';
import 'package:hermes_android/core/widgets/attachment_history_preview.dart';
import 'package:hermes_android/core/widgets/attachment_preview.dart';
import 'package:hermes_android/core/widgets/cover_resize_image.dart';
import 'package:hermes_android/core/widgets/generated_video_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/fake_video_player_platform.dart';

final class _Actions implements RoomAttachmentActions {
  _Actions(this.files);
  final Map<String, File> files;
  final List<String> fetched = [];

  @override
  bool canFetch(RoomAttachmentRef ref) => true;
  @override
  Future<File> fetch(RoomAttachmentRef ref) async {
    fetched.add(ref.name);
    return files[ref.name] ?? File('/nonexistent/${ref.name}');
  }

  @override
  Future<void> open(RoomAttachmentRef ref, File file) async {}
  @override
  Future<void> share(RoomAttachmentRef ref, File file) async {}
  @override
  Future<ArtifactSaveResult> save(RoomAttachmentRef ref, File file) async =>
      ArtifactSaveResult.saved;
}

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump();
  }
}

void main() {
  late FakeVideoPlayerPlatform platform;
  late Directory directory;
  late File photo;
  late File clip;

  setUp(() {
    platform = FakeVideoPlayerPlatform.install();
    GeneratedVideoCard.clearPlaybackMemoryForTesting();
    AttachmentHistoryCard.clearVerifiedCacheForTesting();
    directory = Directory.systemTemp.createTempSync('attachment-preview-');
    photo = File('${directory.path}/photo.png')
      ..writeAsBytesSync(<int>[0x89, 0x50, 0x4e, 0x47]);
    clip = File('${directory.path}/clip.mp4')
      ..writeAsBytesSync(<int>[0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]);
  });

  tearDown(() => directory.deleteSync(recursive: true));

  test('kinds and middle ellipsis', () {
    expect(
      attachmentPreviewKindFor('clip.MOV', ''),
      AttachmentPreviewKind.video,
    );
    expect(
      attachmentPreviewKindFor('x.bin', 'video/mp4'),
      AttachmentPreviewKind.video,
    );
    expect(attachmentPreviewKindFor('a.png', ''), AttachmentPreviewKind.image);
    expect(attachmentPreviewKindFor('a.pdf', ''), AttachmentPreviewKind.pdf);
    expect(
      attachmentPreviewKindFor('a.docx', ''),
      AttachmentPreviewKind.document,
    );
    expect(middleEllipsis('report.pdf'), 'report.pdf');
    final short = middleEllipsis(
      'quarterly-financial-report-final-version-signed.pdf',
    );
    expect(short.length, lessThanOrEqualTo(30));
    expect(short, startsWith('quarterly'));
    expect(short, contains('…'));
    expect(short, endsWith('signed.pdf'));
  });

  testWidgets('a sent video in the chat history is a playable preview, not a '
      'bare file card', (tester) async {
    const reference = AttachmentHistoryReference(
      index: 0,
      storageKey: 'k',
      type: AttachmentType.document,
      mimeType: 'video/mp4',
      sizeBytes: 8,
      sha256Hex: 'abc',
    );
    await tester.pumpWidget(
      _host(
        AttachmentHistoryCard(
          name: 'clip.mp4',
          sizeLabel: '8 B',
          reference: reference,
          resolver: (_) async => clip,
        ),
      ),
    );
    await _settle(tester);

    expect(find.byType(GeneratedVideoCard), findsOneWidget);
    expect(platform.live, [1]);
    expect(platform.sources.single, contains('clip.mp4'));
    expect(find.text('0:05'), findsOneWidget);
  });

  testWidgets('a sent image in the main chat keeps its thumbnail card', (
    tester,
  ) async {
    const reference = AttachmentHistoryReference(
      index: 0,
      storageKey: 'img',
      type: AttachmentType.image,
      mimeType: 'image/png',
      sizeBytes: 4,
      sha256Hex: 'def',
    );
    await tester.pumpWidget(
      _host(
        AttachmentHistoryCard(
          name: 'photo.png',
          sizeLabel: '4 B',
          reference: reference,
          resolver: (_) async => photo,
        ),
      ),
    );
    await _settle(tester);

    expect(find.byType(AttachmentCard), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<ResizeImage>());
    expect((image.image as ResizeImage).width, 360);
  });

  testWidgets('room attachments show thumbnails and a video player without '
      'a tap; documents get a type card, never a bare name', (tester) async {
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetDevicePixelRatio);
    const refs = [
      RoomAttachmentRef(name: 'photo.png', path: '/srv/up/photo.png'),
      RoomAttachmentRef(name: 'clip.mp4', path: '/srv/up/clip.mp4'),
      RoomAttachmentRef(name: 'report.pdf', path: '/srv/up/report.pdf'),
      RoomAttachmentRef(
        name: 'quarterly-financial-report-final-version-signed.docx',
        path: '/srv/up/q.docx',
      ),
    ];
    final actions = _Actions({'photo.png': photo, 'clip.mp4': clip});
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            for (final ref in refs)
              RoomAttachmentCard(
                key: ValueKey(ref.path),
                attachment: ref,
                actions: actions,
              ),
          ],
        ),
      ),
    );
    await _settle(tester);

    // Media is fetched on its own; documents wait for a tap.
    expect(actions.fetched, unorderedEquals(['photo.png', 'clip.mp4']));

    final image = tester.widget<Image>(
      find.descendant(
        of: find.byKey(const ValueKey('/srv/up/photo.png')),
        matching: find.byType(Image),
      ),
    );
    // Bounded decode: 160 logical px × 3.
    expect(image.image, CoverResizeImage(FileImage(photo), target: 480));

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('/srv/up/clip.mp4')),
        matching: find.byType(GeneratedVideoCard),
      ),
      findsOneWidget,
    );
    expect(platform.live, [1]);

    expect(find.text('PDF · '), findsNothing);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('PDF'), findsWidgets);
    expect(find.text('DOCX'), findsWidgets);
    expect(
      find.text('quarterly-financial-report-final-version-signed.docx'),
      findsNothing,
    );
    expect(find.textContaining('…'), findsOneWidget);
  });

  test('MEDIA lines become room attachments only when exact', () {
    final body = parseRoomMessageText(
      'Here you go\n  MEDIA:/srv/out/cat.jpg  \nbye',
    );
    expect(body.text, 'Here you go\nbye');
    expect(body.attachments, const [
      RoomAttachmentRef(name: 'cat.jpg', path: '/srv/out/cat.jpg'),
    ]);
    for (final text in const [
      'see MEDIA:/srv/out/cat.jpg now',
      'MEDIA:relative/cat.jpg',
      'MEDIA:/srv/../etc/passwd',
      '```\nMEDIA:/srv/out/cat.jpg\n```',
      'xMEDIA:/srv/out/cat.jpg',
    ]) {
      final untouched = parseRoomMessageText(text);
      expect(untouched.text, text, reason: text);
      expect(untouched.attachments, isEmpty, reason: text);
    }
  });

  testWidgets('a room media fetch the server refuses shows a not-available '
      'card with the name, never the path', (tester) async {
    const ref = RoomAttachmentRef(name: 'cat.jpg', path: '/srv/out/cat.jpg');
    await tester.pumpWidget(
      _host(RoomAttachmentCard(attachment: ref, actions: _FailingActions())),
    );
    await _settle(tester);
    expect(find.text('cat.jpg'), findsOneWidget);
    expect(find.text('Not available'), findsOneWidget);
    expect(find.textContaining('/srv/out'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}

final class _FailingActions extends _Actions {
  _FailingActions() : super(const {});
  @override
  Future<File> fetch(RoomAttachmentRef ref) async =>
      throw const HttpException('403');
}
