import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/generated_artifact.dart';
import 'package:hermes_android/core/services/artifact_export_service.dart';
import 'package:hermes_android/core/services/generated_artifact_registry.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/generated_artifact_viewer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

String _repeat(String value, int count) => List.filled(count, value).join();

final class _RecordingExporter implements ArtifactExportActions {
  String? copied;
  ({String fileName, String mimeType, String content})? shared;
  ({String fileName, String content})? saved;

  @override
  Future<void> copyText(String content) async => copied = content;

  @override
  Future<ArtifactSaveResult> saveBytes({
    required String fileName,
    required Uint8List bytes,
  }) async => ArtifactSaveResult.saved;

  @override
  Future<ArtifactSaveResult> saveText({
    required String fileName,
    required String content,
  }) async {
    saved = (fileName: fileName, content: content);
    return ArtifactSaveResult.saved;
  }

  @override
  Future<void> shareText({
    required String fileName,
    required String mimeType,
    required String content,
  }) async =>
      shared = (fileName: fileName, mimeType: mimeType, content: content);
}

Widget _app({
  required GeneratedArtifactRegistry registry,
  required String artifactId,
  ArtifactExportActions exporter = const PlatformArtifactExportActions(),
  ThemeData? theme,
  TextScaler textScaler = TextScaler.noScaling,
}) => MaterialApp(
  theme: theme ?? AppTheme.fromMode(AppThemeMode.dark),
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: textScaler),
    child: child!,
  ),
  home: Scaffold(
    body: GeneratedArtifactViewer(
      registry: registry,
      artifactId: artifactId,
      exporter: exporter,
    ),
  ),
);

GeneratedArtifactUpsertResult _add(
  GeneratedArtifactRegistry registry, {
  required GeneratedArtifactKind kind,
  required String title,
  required String language,
  required String content,
}) => registry.upsert(
  'connection:session',
  GeneratedArtifactDetection(kind: kind, language: language, title: title),
  content,
)!;

void main() {
  testWidgets('navega versiones y exporta el contenido seleccionado completo', (
    tester,
  ) async {
    final registry = GeneratedArtifactRegistry();
    final exporter = _RecordingExporter();
    final first = _add(
      registry,
      kind: GeneratedArtifactKind.code,
      title: 'lib/panel.dart',
      language: 'dart',
      content: 'void main() => print("v1");',
    );
    _add(
      registry,
      kind: GeneratedArtifactKind.code,
      title: 'lib/panel.dart',
      language: 'dart',
      content: 'void main() => print("v2");',
    );

    await tester.pumpWidget(
      _app(
        registry: registry,
        artifactId: first.artifactId,
        exporter: exporter,
      ),
    );

    expect(find.text('Versión 2 de 2'), findsOneWidget);
    expect(find.text('void main() => print("v2");'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('generated-artifact-previous-version')),
    );
    await tester.pump();

    expect(find.text('Versión 1 de 2'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Copiar'));
    await tester.pump();
    expect(exporter.copied, 'void main() => print("v1");');
  });

  testWidgets('HTML y SVG se presentan como fuente sin render ejecutable', (
    tester,
  ) async {
    for (final sample in const [
      (
        kind: GeneratedArtifactKind.html,
        language: 'html',
        title: 'panel.html',
        content: '<script>window.alert("no")</script>',
      ),
      (
        kind: GeneratedArtifactKind.svg,
        language: 'svg',
        title: 'chart.svg',
        content: '<svg onload="window.alert(1)"></svg>',
      ),
    ]) {
      final registry = GeneratedArtifactRegistry();
      final artifact = _add(
        registry,
        kind: sample.kind,
        title: sample.title,
        language: sample.language,
        content: sample.content,
      );

      await tester.pumpWidget(
        _app(registry: registry, artifactId: artifact.artifactId),
      );

      expect(find.text(sample.content), findsOneWidget);
      expect(find.textContaining('Nunca los ejecuta'), findsOneWidget);
      // La fuente se muestra como texto plano seleccionable (SelectionArea +
      // Text): nunca como widget renderizado del lenguaje del artefacto.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('generated-artifact-source-0')),
          matching: find.byType(SelectionArea),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('generated-artifact-source-0')),
          matching: find.text(sample.content),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull, reason: sample.kind.name);
    }
  });

  testWidgets('no desborda a 320 px, texto 2x ni en ningún tema', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final registry = GeneratedArtifactRegistry();
    final artifact = _add(
      registry,
      kind: GeneratedArtifactKind.html,
      title: 'Panel responsive con un título deliberadamente largo',
      language: 'html',
      content: '<main>${_repeat('contenido ', 80)}</main>',
    );

    for (final mode in AppThemeMode.values) {
      await tester.pumpWidget(
        _app(
          registry: registry,
          artifactId: artifact.artifactId,
          theme: AppTheme.fromMode(mode),
          textScaler: const TextScaler.linear(2),
        ),
      );
      await tester.pump();

      expect(find.textContaining('Panel responsive'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: mode.name);
    }
  });
}
