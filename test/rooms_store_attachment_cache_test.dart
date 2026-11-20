// A file of a room's own store, once read with `groups.attachment.download`,
// is kept in the private cache of generated media at exactly the size its
// manifest states, and opened, saved and shared like any other room file
// (`StoreRoomAttachmentActions`). Real files under a temporary cache root.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_models.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/services/artifact_export_service.dart';
import 'package:hermes_android/core/services/generated_media_service.dart';

import 'bots/room/room_fixtures.dart';

const _attId = 'att_0123456789abcdef0123456789abcdef';
const _eventId = 'user:7';
final Uint8List _pdf = Uint8List.fromList(
  utf8.encode('%PDF-1.4\n% a room file\n%%EOF\n'),
);

HostedGroupAttachment _attachment() => HostedGroupAttachment.fromJson({
  'attachment_id': _attId,
  'kind': 'pdf',
  'name': 'plan.pdf',
  'size': _pdf.length,
  'mime': 'application/pdf',
});

final class _Exporter implements ArtifactExportActions {
  final List<String> saved = [];

  @override
  Future<ArtifactSaveResult> saveFile({
    required String fileName,
    required File file,
  }) async {
    saved.add('$fileName:${file.readAsBytesSync().length}');
    return ArtifactSaveResult.saved;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const preview = MethodChannel('hermes/document_preview');
  late Directory root;
  late _Exporter exporter;
  late List<String> reads;
  late List<MethodCall> opened;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('room-store-files');
    exporter = _Exporter();
    reads = [];
    opened = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(preview, (call) async {
          opened.add(call);
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(preview, null);
    await root.delete(recursive: true);
  });

  StoreRoomAttachmentActions actions(List<Uint8List> answers) =>
      StoreRoomAttachmentActions(
        files: null,
        scope: 'room-files\u0000default',
        roomId: roomId,
        cacheRoot: root,
        exporter: exporter,
        download: (eventId, attachment) async {
          reads.add('$eventId/${attachment.attachmentId}');
          return answers.removeAt(0);
        },
      );

  test('the file is read once by its ids, cached privately and opens, saves '
      'through the guarded paths', () async {
    final store = actions([_pdf]);
    final ref = RoomAttachmentRef.stored(_eventId, _attachment());

    final file = await store.fetch(ref);

    expect(reads, ['$_eventId/$_attId']);
    expect(await file.readAsBytes(), _pdf);
    expect(file.path, startsWith('${root.path}/generated_media/'));
    // Read again from the cache, without asking the server.
    expect((await store.fetch(ref)).path, file.path);
    expect(store.cachedFile(ref)?.path, file.path);
    expect(reads, hasLength(1));

    await store.open(ref, file);
    final call = opened.single;
    expect(call.method, 'openGeneratedFile');
    final args = Map<String, Object?>.from(call.arguments as Map);
    expect(args['expectedSize'], _pdf.length);
    expect(args['expectedSha256'], sha256.convert(_pdf).toString());
    expect(args['mimeType'], 'application/pdf');

    await store.save(ref, file);
    expect(exporter.saved, ['plan.pdf:${_pdf.length}']);
  });

  test('the media cache itself refuses a room file of another size than '
      'its manifest and keeps nothing', () async {
    const reference = GeneratedMediaReference(
      source: '$roomId/$_eventId/$_attId',
      kind: GeneratedMediaKind.file,
      sourceKind: GeneratedMediaSourceKind.roomAttachment,
      displayName: 'plan.pdf',
      mimeType: 'application/pdf',
      sizeBytes: 12,
    );

    await expectLater(
      GeneratedMediaService.ensureDownloaded(
        'room-files\u0000default',
        reference,
        fetchRoomAttachment: (_) async => _pdf,
        baseDir: root,
      ),
      throwsFormatException,
    );
    final cache = Directory('${root.path}/generated_media');
    expect(
      cache.existsSync()
          ? cache.listSync(recursive: true).whereType<File>()
          : const <File>[],
      isEmpty,
    );
  });

  test('bytes of another size than the manifest are refused and never '
      'cached; a retry reads the file again', () async {
    final store = actions([
      Uint8List.fromList([..._pdf, 0x0a]),
      _pdf,
    ]);
    final ref = RoomAttachmentRef.stored(_eventId, _attachment());

    await expectLater(store.fetch(ref), throwsFormatException);
    expect(store.cachedFile(ref), isNull);

    final file = await store.fetch(ref);
    expect(await file.readAsBytes(), _pdf);
    expect(reads, ['$_eventId/$_attId', '$_eventId/$_attId']);
  });
}
