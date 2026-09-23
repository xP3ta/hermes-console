import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('el contrato PDF usa PdfRenderer sobre la raíz privada verificada', () {
    final handler = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'HermesDocumentPreviewHandler.kt',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'MainActivity.kt',
    ).readAsStringSync();
    final dartPreview = File(
      'lib/core/widgets/attachment_history_preview.dart',
    ).readAsStringSync();
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final generatedPaths = File(
      'android/app/src/main/res/xml/generated_media_paths.xml',
    ).readAsStringSync();

    expect(handler, contains('android.graphics.pdf.PdfRenderer'));
    expect(handler, contains('ParcelFileDescriptor.MODE_READ_ONLY'));
    expect(handler, contains('PdfRenderer(descriptor).use'));
    expect(handler, contains('renderer.openPage(pageIndex).use'));
    expect(handler, contains('Executors.newSingleThreadExecutor()'));
    expect(handler, contains('MAX_RENDERED_PAGES = 40'));
    expect(
      handler,
      contains('minOf(renderer.pageCount, MAX_RENDERED_PAGES)'),
    );
    expect(handler, contains('SENT_ATTACHMENTS_DIRECTORY'));
    expect(handler, contains('canonicalFile'));
    expect(handler, contains('expectedSha256 == storageKey'));
    expect(handler, contains('file.sha256() == expectedSha256'));
    expect(handler, contains('Intent(Intent.ACTION_VIEW)'));
    expect(handler, contains('FileProvider.getUriForFile'));
    expect(handler, contains('generatedConnectionKey'));
    expect(handler, contains('generatedFileKey'));
    expect(handler, isNot(contains('requestPermissions')));
    expect(manifest, contains(r'${applicationId}.generated_file_provider'));
    expect(manifest, contains('android:exported="false"'));
    expect(generatedPaths, contains('path="generated_media/"'));
    expect(RegExp(r'<files-path\b').allMatches(generatedPaths), hasLength(1));
    expect(generatedPaths, isNot(contains('path="."')));
    expect(generatedPaths, isNot(contains('<root-path')));
    expect(generatedPaths, isNot(contains('<cache-path')));
    expect(generatedPaths, isNot(contains('<external-path')));
    expect(generatedPaths, isNot(contains('<external-files-path')));

    expect(activity, contains('"hermes/document_preview"'));
    expect(
      activity,
      contains('HermesDocumentPreviewHandler(applicationContext)'),
    );
    expect(dartPreview, contains("'hermes/document_preview'"));
    expect(dartPreview, contains("'renderPdfPage'"));
    expect(dartPreview, isNot(contains("'path': widget.file.path")));
  });
}
