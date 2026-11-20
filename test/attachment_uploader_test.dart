import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/services/attachment_uploader.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('hermes-attachments-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<File> sparseFile(String name, int sizeBytes) async {
    final file = File('${temp.path}/$name');
    final handle = await file.open(mode: FileMode.write);
    if (sizeBytes > 0) {
      await handle.setPosition(sizeBytes - 1);
      await handle.writeByte(0);
    }
    await handle.close();
    return file;
  }

  AttachmentDraft documentDraft(File file) => AttachmentDraft(
    type: AttachmentType.document,
    name: file.uri.pathSegments.last,
    mimeType: 'application/pdf',
    sizeBytes: file.lengthSync(),
    localPath: file.path,
  );

  test('validateBatch acepta una imagen con firma PNG real', () async {
    final file = File('${temp.path}/image.png');
    await file.writeAsBytes([
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
      1,
    ]);
    final draft = AttachmentDraft(
      type: AttachmentType.image,
      name: 'image.png',
      mimeType: 'image/png',
      sizeBytes: await file.length(),
      localPath: file.path,
    );

    expect(await AttachmentUploader.validateBatch([draft]), isTrue);
  });

  test('validateBatch acepta imágenes con firma GIF87a y GIF89a', () async {
    for (final signature in const ['GIF87a', 'GIF89a']) {
      final file = File('${temp.path}/$signature.gif');
      await file.writeAsBytes([...signature.codeUnits, 1]);
      final draft = AttachmentDraft(
        type: AttachmentType.image,
        name: '$signature.gif',
        mimeType: 'image/gif',
        sizeBytes: await file.length(),
        localPath: file.path,
      );

      expect(
        await AttachmentUploader.validateBatch([draft]),
        isTrue,
        reason: '$signature es una firma GIF admitida',
      );
    }
  });

  test('validateBatch rechaza contenido renombrado como imagen', () async {
    final file = File('${temp.path}/fake.png');
    await file.writeAsString('<html>not an image</html>');
    final draft = AttachmentDraft(
      type: AttachmentType.image,
      name: 'fake.png',
      mimeType: 'image/png',
      sizeBytes: await file.length(),
      localPath: file.path,
    );

    expect(await AttachmentUploader.validateBatch([draft]), isFalse);
  });

  test(
    'validateBatch usa el tamaño actual y rechaza un lote excesivo',
    () async {
      final drafts = <AttachmentDraft>[];
      for (var index = 0; index < 4; index++) {
        final file = File('${temp.path}/$index.pdf');
        final handle = await file.open(mode: FileMode.write);
        await handle.setPosition(7 * 1024 * 1024 - 1);
        await handle.writeByte(0);
        await handle.close();
        drafts.add(
          AttachmentDraft(
            type: AttachmentType.document,
            name: '$index.pdf',
            mimeType: 'application/pdf',
            sizeBytes: 1,
            localPath: file.path,
          ),
        );
      }

      expect(await AttachmentUploader.validateBatch(drafts), isFalse);
    },
  );

  test('an image goes up to the image limit, a file does not', () async {
    // tui_gateway/prompt_attachments.py _ATTACH_BYTES_MAX_BYTES (25 MiB)
    // bounds image.attach_bytes; file.attach keeps the 8 MiB limit.
    Future<File> tenMegabytes(String name) async {
      final file = File('${temp.path}/$name');
      final handle = await file.open(mode: FileMode.write);
      await handle.writeFrom(const [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
      ]);
      await handle.setPosition(10 * 1024 * 1024);
      await handle.writeByte(0);
      await handle.close();
      return file;
    }

    final image = await tenMegabytes('foto.png');
    final document = await tenMegabytes('foto.pdf');
    AttachmentDraft draft(File file, AttachmentType type, String mime) =>
        AttachmentDraft(
          type: type,
          name: file.uri.pathSegments.last,
          mimeType: mime,
          sizeBytes: file.lengthSync(),
          localPath: file.path,
        );

    expect(
      await AttachmentUploader.validateBatch([
        draft(image, AttachmentType.image, 'image/png'),
      ]),
      isTrue,
    );
    expect(
      await AttachmentUploader.validateBatch([
        draft(document, AttachmentType.document, 'application/pdf'),
      ]),
      isFalse,
    );
  });

  test(
    'validateBatch respeta las fronteras exactas de unidad y lote',
    () async {
      final exactFiles = <File>[
        for (var index = 0; index < 3; index++)
          await sparseFile('exact-$index.pdf', AttachmentUploader.maxBytes),
      ];
      final exactBatch = exactFiles.map(documentDraft).toList();

      expect(
        await AttachmentUploader.validateBatch([exactBatch.first]),
        isTrue,
        reason: '8 MiB exactos están permitidos',
      );
      expect(
        await AttachmentUploader.validateBatch(exactBatch),
        isTrue,
        reason: '3 × 8 MiB = 24 MiB exactos están permitidos',
      );

      final oversized = await sparseFile(
        'oversized.pdf',
        AttachmentUploader.maxBytes + 1,
      );
      expect(
        await AttachmentUploader.validateBatch([documentDraft(oversized)]),
        isFalse,
        reason: '8 MiB + 1 viola el límite individual',
      );

      final extra = await sparseFile('extra.pdf', 1);
      expect(
        await AttachmentUploader.validateBatch([
          ...exactBatch,
          documentDraft(extra),
        ]),
        isFalse,
        reason: '24 MiB + 1 viola el límite total',
      );
    },
  );

  test('validateBatch mantiene separado el límite de texto', () async {
    AttachmentDraft textDraft(File file) => AttachmentDraft(
      type: AttachmentType.document,
      name: file.uri.pathSegments.last,
      mimeType: 'text/plain',
      sizeBytes: file.lengthSync(),
      localPath: file.path,
    );
    final exact = await sparseFile(
      'exact.txt',
      AttachmentUploader.maxTextBytes,
    );
    final oversized = await sparseFile(
      'oversized.txt',
      AttachmentUploader.maxTextBytes + 1,
    );

    expect(await AttachmentUploader.validateBatch([textDraft(exact)]), isTrue);
    expect(
      await AttachmentUploader.validateBatch([textDraft(oversized)]),
      isFalse,
    );
  });

  test(
    'validateBatch falla cerrado con ruta ausente, imagen falsa y ejecutable',
    () async {
      final missing = AttachmentDraft(
        type: AttachmentType.document,
        name: 'ausente.pdf',
        mimeType: 'application/pdf',
        sizeBytes: 4,
        localPath: '${temp.path}/ausente.pdf',
      );
      final fakeImage = File('${temp.path}/falsa.png');
      await fakeImage.writeAsString('<html>no es una imagen</html>');
      final corrupt = AttachmentDraft(
        type: AttachmentType.image,
        name: 'falsa.png',
        mimeType: 'image/png',
        sizeBytes: await fakeImage.length(),
        localPath: fakeImage.path,
      );
      final executable = await sparseFile('payload.apk', 1);

      expect(await AttachmentUploader.validateBatch([missing]), isFalse);
      expect(await AttachmentUploader.validateBatch([corrupt]), isFalse);
      expect(
        await AttachmentUploader.validateBatch([documentDraft(executable)]),
        isFalse,
      );
    },
  );

  test(
    'persistImageLocally deduplica por hash y limpia parciales viejos',
    () async {
      final source = File('${temp.path}/source.png');
      await source.writeAsBytes([
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
        1,
        2,
        3,
      ]);
      final draft = AttachmentDraft(
        type: AttachmentType.image,
        name: 'source.png',
        mimeType: 'image/png',
        sizeBytes: await source.length(),
        localPath: source.path,
      );

      final first = await AttachmentUploader.persistImageLocally(
        draft,
        baseDir: temp,
      );
      final second = await AttachmentUploader.persistImageLocally(
        draft,
        baseDir: temp,
      );

      expect(second, first);
      final files = await Directory('${temp.path}/sent_images')
          .list()
          .where((entity) => entity is File && !entity.path.contains('.part.'))
          .toList();
      expect(files, hasLength(1));
    },
  );

  test('materializa imagen y documento de forma atómica por localId', () async {
    final image = File('${temp.path}/source.png');
    await image.writeAsBytes([
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
      1,
    ]);
    final document = File('${temp.path}/source.pdf');
    await document.writeAsBytes([0x25, 0x50, 0x44, 0x46, 1]);

    final persistedImage = await AttachmentUploader.materializeForDraft(
      AttachmentDraft(
        localId: 'image-a',
        type: AttachmentType.image,
        name: 'source.png',
        mimeType: 'image/png',
        sizeBytes: await image.length(),
        localPath: image.path,
      ),
      baseDir: temp,
    );
    final persistedDocument = await AttachmentUploader.materializeForDraft(
      AttachmentDraft(
        localId: 'document-a',
        type: AttachmentType.document,
        name: 'source.pdf',
        mimeType: 'application/pdf',
        sizeBytes: await document.length(),
        localPath: document.path,
      ),
      baseDir: temp,
    );

    expect(persistedImage, isNotNull);
    expect(persistedDocument, isNotNull);
    expect(persistedImage!.localId, 'image-a');
    expect(persistedDocument!.localId, 'document-a');
    expect(persistedImage.localPath, contains('/attachment_drafts/image-a_'));
    expect(
      persistedDocument.localPath,
      contains('/attachment_drafts/document-a_'),
    );
    expect(
      await File(persistedImage.localPath).readAsBytes(),
      await image.readAsBytes(),
    );
    expect(
      await File(persistedDocument.localPath).readAsBytes(),
      await document.readAsBytes(),
    );
    expect(
      await Directory(
        '${temp.path}/attachment_drafts',
      ).list().where((entity) => entity.path.contains('.part.')).toList(),
      isEmpty,
    );
  });

  test('la limpieza solo borra la copia privada propietaria', () async {
    final source = File('${temp.path}/source.txt');
    await source.writeAsString('contenido');
    final persisted = await AttachmentUploader.materializeForDraft(
      AttachmentDraft(
        localId: 'document-cleanup',
        type: AttachmentType.document,
        name: 'source.txt',
        mimeType: 'text/plain',
        sizeBytes: await source.length(),
        localPath: source.path,
      ),
      baseDir: temp,
    );

    expect(
      await AttachmentUploader.deletePrivateDraftCopy(
        persisted!,
        baseDir: temp,
      ),
      isTrue,
    );
    expect(await File(persisted.localPath).exists(), isFalse);
    expect(await source.exists(), isTrue);
    expect(
      await AttachmentUploader.deletePrivateDraftCopy(
        AttachmentDraft(
          localId: 'external',
          type: AttachmentType.document,
          name: 'source.txt',
          mimeType: 'text/plain',
          sizeBytes: await source.length(),
          localPath: source.path,
        ),
        baseDir: temp,
      ),
      isFalse,
    );
    expect(await source.exists(), isTrue);
  });

  test('reemplaza un destino envenenado del mismo localId', () async {
    final source = File('${temp.path}/source.txt');
    await source.writeAsString('contenido correcto');
    final drafts = Directory('${temp.path}/attachment_drafts');
    await drafts.create();
    final poisoned = File('${drafts.path}/stable-id_source.txt');
    await poisoned.writeAsString('x');

    final persisted = await AttachmentUploader.materializeForDraft(
      AttachmentDraft(
        localId: 'stable-id',
        type: AttachmentType.document,
        name: 'source.txt',
        mimeType: 'text/plain',
        sizeBytes: await source.length(),
        localPath: source.path,
      ),
      baseDir: temp,
    );

    expect(persisted, isNotNull);
    expect(
      await File(persisted!.localPath).readAsString(),
      'contenido correcto',
    );
  });

  test(
    'path traversal o symlink nunca borra fuera de la raíz privada',
    () async {
      final drafts = Directory('${temp.path}/attachment_drafts');
      await drafts.create();
      final external = File('${temp.path}/owner_external.txt');
      await external.writeAsString('conservar');
      final traversal = AttachmentDraft(
        localId: 'owner',
        type: AttachmentType.document,
        name: 'external.txt',
        mimeType: 'text/plain',
        sizeBytes: await external.length(),
        localPath: '${drafts.path}/../owner_external.txt',
      );

      expect(
        await AttachmentUploader.deletePrivateDraftCopy(
          traversal,
          baseDir: temp,
        ),
        isFalse,
      );
      expect(await external.exists(), isTrue);

      final link = Link('${drafts.path}/owner_link.txt');
      await link.create(external.path);
      expect(
        await AttachmentUploader.deletePrivateDraftCopy(
          traversal.copyWith(localPath: link.path),
          baseDir: temp,
        ),
        isFalse,
      );
      expect(await external.exists(), isTrue);
    },
  );

  test(
    'el ACK puede liberar el draft y la copia histórica conserva los bytes PDF',
    () async {
      final source = File('${temp.path}/informe-original.pdf');
      final pdfBytes = <int>[
        ...'%PDF-1.4\n'.codeUnits,
        0x25,
        0xe2,
        0xe3,
        0xcf,
        0xd3,
        ...'\n%%EOF'.codeUnits,
      ];
      await source.writeAsBytes(pdfBytes);
      final draft = await AttachmentUploader.materializeForDraft(
        AttachmentDraft(
          localId: 'pdf-history-owner',
          type: AttachmentType.document,
          name: 'informe privado.pdf',
          mimeType: 'application/pdf',
          sizeBytes: pdfBytes.length,
          localPath: source.path,
        ),
        baseDir: temp,
      );
      expect(draft, isNotNull);

      final reference = await AttachmentUploader.persistForHistory(
        draft!,
        index: 0,
        baseDir: temp,
      );
      expect(reference, isNotNull);
      final marker = reference!.toMarker();
      expect(marker, startsWith(AttachmentHistoryReference.markerPrefix));
      expect(marker, isNot(contains(temp.path)));
      expect(marker, isNot(contains(draft.localPath)));
      expect(marker, isNot(contains('informe privado.pdf')));
      expect(
        AttachmentHistoryReference.tryParseMarker(marker)?.storageKey,
        reference.storageKey,
      );

      expect(
        await AttachmentUploader.deletePrivateDraftCopy(draft, baseDir: temp),
        isTrue,
      );
      expect(await File(draft.localPath).exists(), isFalse);
      final historical = await AttachmentUploader.resolveHistoryReference(
        reference,
        baseDir: temp,
      );
      expect(historical, isNotNull);
      expect(await historical!.readAsBytes(), pdfBytes);
    },
  );

  test(
    'marcadores multiadjunto son versionados y no ambiguos por índice',
    () async {
      final first = File('${temp.path}/primero.pdf')
        ..writeAsBytesSync([...'%PDF-1.4\nprimero'.codeUnits]);
      final second = File('${temp.path}/segundo.pdf')
        ..writeAsBytesSync([...'%PDF-1.4\nsegundo'.codeUnits]);
      AttachmentDraft draft(File file) => AttachmentDraft(
        localId: file.uri.pathSegments.last,
        type: AttachmentType.document,
        name: file.uri.pathSegments.last,
        mimeType: 'application/pdf',
        sizeBytes: file.lengthSync(),
        localPath: file.path,
      );

      final refs = <AttachmentHistoryReference>[
        (await AttachmentUploader.persistForHistory(
          draft(first),
          index: 0,
          baseDir: temp,
        ))!,
        (await AttachmentUploader.persistForHistory(
          draft(second),
          index: 1,
          baseDir: temp,
        ))!,
      ];
      final parsed = refs
          .map((reference) => reference.toMarker())
          .map(AttachmentHistoryReference.tryParseMarker)
          .whereType<AttachmentHistoryReference>()
          .toList();

      expect(parsed.map((reference) => reference.index), [0, 1]);
      expect(
        parsed.map((reference) => reference.storageKey).toSet(),
        hasLength(2),
      );
      expect(
        AttachmentHistoryReference.tryParseMarker(
          refs.first.toMarker().replaceFirst('hatt:v1:', 'hatt:v2:'),
        ),
        isNull,
      );
    },
  );

  test('un marcador sobredimensionado falla cerrado antes de decodificar', () {
    final oversized =
        '${AttachmentHistoryReference.markerPrefix}'
        '${List.filled(2048, 'A').join()}'
        '${AttachmentHistoryReference.markerSuffix}';

    expect(AttachmentHistoryReference.tryParseMarker(oversized), isNull);
  });

  test(
    'reusar una copia envejecida refresca su retención para el siguiente envío',
    () async {
      final first = File('${temp.path}/primero.pdf')
        ..writeAsBytesSync([...'%PDF-1.4\nprimero'.codeUnits]);
      final second = File('${temp.path}/segundo.pdf')
        ..writeAsBytesSync([...'%PDF-1.4\nsegundo'.codeUnits]);
      AttachmentDraft draft(File file) => AttachmentDraft(
        localId: file.uri.pathSegments.last,
        type: AttachmentType.document,
        name: file.uri.pathSegments.last,
        mimeType: 'application/pdf',
        sizeBytes: file.lengthSync(),
        localPath: file.path,
      );

      final original = (await AttachmentUploader.persistForHistory(
        draft(first),
        index: 0,
        baseDir: temp,
      ))!;
      final stored = File(
        '${temp.path}/${AttachmentUploader.sentAttachmentDirectoryName}/'
        '${original.storageKey}',
      );
      await stored.setLastModified(
        DateTime.now().subtract(
          AttachmentUploader.maxSentAttachmentCacheAge +
              const Duration(days: 1),
        ),
      );

      final reused = await AttachmentUploader.persistForHistory(
        draft(first),
        index: 0,
        baseDir: temp,
      );
      expect(reused?.storageKey, original.storageKey);

      await AttachmentUploader.persistForHistory(
        draft(second),
        index: 1,
        baseDir: temp,
      );

      expect(await stored.exists(), isTrue);
    },
  );

  test(
    'resolver histórico rechaza traversal, symlink y bytes manipulados',
    () async {
      final external = File('${temp.path}/fuera.pdf');
      final originalBytes = <int>[...'%PDF-1.4\nfuera'.codeUnits];
      await external.writeAsBytes(originalBytes);
      final digest = sha256.convert(originalBytes).toString();
      final directory = Directory(
        '${temp.path}/${AttachmentUploader.sentAttachmentDirectoryName}',
      );
      await directory.create();
      final link = Link('${directory.path}/$digest');
      await link.create(external.path);
      final linkedReference = AttachmentHistoryReference(
        index: 0,
        storageKey: digest,
        type: AttachmentType.document,
        mimeType: 'application/pdf',
        sizeBytes: originalBytes.length,
        sha256Hex: digest,
      );

      expect(
        await AttachmentUploader.resolveHistoryReference(
          linkedReference,
          baseDir: temp,
        ),
        isNull,
      );
      expect(
        await AttachmentUploader.resolveHistoryReference(
          AttachmentHistoryReference(
            index: 0,
            storageKey: '../$digest',
            type: AttachmentType.document,
            mimeType: 'application/pdf',
            sizeBytes: originalBytes.length,
            sha256Hex: '../$digest',
          ),
          baseDir: temp,
        ),
        isNull,
      );

      await link.delete();
      await directory.delete();
      final redirectedDirectory = Directory('${temp.path}/almacen-externo');
      await redirectedDirectory.create();
      await external.copy('${redirectedDirectory.path}/$digest');
      final directoryLink = Link(directory.path);
      await directoryLink.create(redirectedDirectory.path);
      expect(
        await AttachmentUploader.resolveHistoryReference(
          linkedReference,
          baseDir: temp,
        ),
        isNull,
        reason: 'la propia raíz del almacén tampoco puede ser un symlink',
      );
      await directoryLink.delete();
      await directory.create();

      final source = File('${temp.path}/mutable.pdf')
        ..writeAsBytesSync([...'%PDF-1.4\nmutable'.codeUnits]);
      final reference = (await AttachmentUploader.persistForHistory(
        AttachmentDraft(
          type: AttachmentType.document,
          name: 'mutable.pdf',
          mimeType: 'application/pdf',
          sizeBytes: source.lengthSync(),
          localPath: source.path,
        ),
        index: 0,
        baseDir: temp,
      ))!;
      final stored = File('${directory.path}/${reference.storageKey}');
      final bytes = await stored.readAsBytes();
      bytes[bytes.length - 1] ^= 0xff;
      await stored.writeAsBytes(bytes);
      expect(
        await AttachmentUploader.resolveHistoryReference(
          reference,
          baseDir: temp,
        ),
        isNull,
      );
    },
  );

  test('una referencia cuyo archivo fue limpiado falla cerrado', () async {
    final source = File('${temp.path}/ausente.txt')
      ..writeAsStringSync('bytes exactos que desaparecerán');
    final reference = (await AttachmentUploader.persistForHistory(
      AttachmentDraft(
        type: AttachmentType.document,
        name: 'ausente.txt',
        mimeType: 'text/plain',
        sizeBytes: source.lengthSync(),
        localPath: source.path,
      ),
      index: 0,
      baseDir: temp,
    ))!;
    final stored = await AttachmentUploader.resolveHistoryReference(
      reference,
      baseDir: temp,
    );
    expect(stored, isNotNull);
    await stored!.delete();
    expect(
      await AttachmentUploader.resolveHistoryReference(
        reference,
        baseDir: temp,
      ),
      isNull,
    );
  });
}
