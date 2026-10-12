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

  test('"Abrir fuera" abre la app predeterminada, sin selector forzado', () {
    final handler = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
      'HermesDocumentPreviewHandler.kt',
    ).readAsStringSync();
    final start = handler.indexOf('private fun launchExternalViewer(');
    expect(start, isNonNegative);
    final end = handler.indexOf('\n    private fun ', start + 1);
    final body = handler.substring(start, end);

    // The plain ACTION_VIEW is started first: Android resolves the user's
    // default app (or shows its own "Abrir con" when none is set).
    final direct = body.indexOf('applicationContext.startActivity(viewIntent)');
    final catchAt = body.indexOf('catch (_: ActivityNotFoundException)');
    final chooserAt = body.indexOf('Intent.createChooser(viewIntent');
    expect(direct, isNonNegative);
    expect(catchAt, greaterThan(direct));
    // The chooser survives only as the fallback inside the catch.
    expect(chooserAt, greaterThan(catchAt));
    expect(RegExp(r'Intent\.createChooser').allMatches(body), hasLength(1));
    // The read grant and the new-task flag ride on the direct intent too.
    final viewIntent = body.substring(
      body.indexOf('val viewIntent'),
      body.indexOf('try {'),
    );
    expect(viewIntent, contains('FLAG_GRANT_READ_URI_PERMISSION'));
    expect(viewIntent, contains('FLAG_ACTIVITY_NEW_TASK'));
    expect(
      handler,
      contains('import android.content.ActivityNotFoundException'),
    );
  });

  test(
    'los enlaces tocados en el visor HTML van al navegador predeterminado',
    () {
      final policy = File(
        'lib/core/widgets/artifact_viewer/artifact_html_policy.dart',
      ).readAsStringSync();
      expect(policy, contains('LaunchMode.externalApplication'));
      expect(policy, isNot(contains('externalNonBrowserApplication')));
      expect(policy, isNot(contains('inAppBrowserView')));
      expect(policy, isNot(contains('inAppWebView')));
    },
  );
}
