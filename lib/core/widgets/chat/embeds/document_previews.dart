import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:hermes_android/core/design/hicons.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../theme/app_theme.dart';
import '../../artifact_viewer/artifact_html_policy.dart';
import '../../artifact_viewer/web_preview.dart';
import '../chat_markdown_body.dart';

/// What the chat shows straight away for a document: the drawn diagram, the
/// rendered page, the model, the formatted note, as a still picture. Each one
/// opens live and full screen on a tap. All of them are drawn on the device, without the network.

/// Largest HTML, SVG or diagram source previewed inside the chat.
const int kInlineDocumentMaxBytes = 2 * 1024 * 1024;

/// A ```mermaid fence drawn in place; [fallback] (the code block) is shown
/// where the diagram cannot be made.
class MermaidFencePreview extends StatelessWidget {
  const MermaidFencePreview({
    super.key,
    required this.source,
    required this.fallback,
  });

  final String source;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final label = Strings.of(context).vwDiagramLabel;
    Future<String> document() => buildMermaidDocument(
      source,
      dark: dark,
      background: colors.surfaceVariant,
      ink: colors.textPrimary,
    );
    return InlineWebPreview(
      key: ValueKey('mermaid-$dark-${source.hashCode}'),
      document: document,
      label: label,
      icon: HIcons.account_tree_outlined,
      aspectRatio: 16 / 9,
      fitContent: true,
      snapshotKey: 'mermaid:$dark:${sha256.convert(utf8.encode(source))}',
      readyScript: kMermaidReadyScript,
      fallback: fallback,
      onOpen: () => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => WebDocumentScreen(
            title: label,
            document: document,
            readyScript: kMermaidReadyScript,
          ),
        ),
      ),
    );
  }
}

/// The live preview of a document file the app already holds: an HTML page,
/// an SVG, a Mermaid source or a 3D model.
class DocumentFilePreview extends StatelessWidget {
  const DocumentFilePreview.html({
    super.key,
    required this.file,
    required this.onOpen,
    this.name,
  }) : _kind = _Kind.html;

  const DocumentFilePreview.svg({
    super.key,
    required this.file,
    required this.onOpen,
    this.name,
  }) : _kind = _Kind.svg;

  const DocumentFilePreview.mermaid({
    super.key,
    required this.file,
    required this.onOpen,
    this.name,
  }) : _kind = _Kind.mermaid;

  const DocumentFilePreview.model({
    super.key,
    required this.file,
    required this.onOpen,
    this.name,
  }) : _kind = _Kind.model;

  final File file;

  /// The file's own name when the stored copy carries another.
  final String? name;
  final VoidCallback onOpen;
  final _Kind _kind;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final Future<String> Function() document;
    final String label;
    final IconData icon;
    var aspect = 4 / 3;
    var fit = false;
    String? ready;
    String? capture;
    var auto = true;
    var deadline = kWebPageDeadline;
    if (_kind == _Kind.model) {
      try {
        auto = file.lengthSync() <= kModelInlineMaxBytes;
      } catch (_) {
        // Unreadable: the preview reports it when it loads.
      }
    }
    // The picture belongs to these very bytes, wherever the copy is stored.
    final path = file.path;
    final kind = _kind.name;
    Future<String?> pictureKey() async {
      try {
        final digest = await compute(_fileDigest, path);
        return 'file:$kind:$dark:$digest';
      } catch (_) {
        return null;
      }
    }
    // Read as the full viewer reads it: a stray byte that is not UTF-8 does
    // not keep the page from being drawn.
    Future<String> text() async =>
        utf8.decode(await file.readAsBytes(), allowMalformed: true);
    switch (_kind) {
      case _Kind.html:
        document = () async =>
            buildGuardedArtifactHtml(await text(), scriptsEnabled: true);
        label = 'HTML';
        icon = HIcons.language_rounded;
      case _Kind.svg:
        document = () async => buildGuardedSvgHtml(await text());
        label = strings.embedSvgLabel;
        icon = HIcons.image_outlined;
        aspect = 16 / 10;
      case _Kind.mermaid:
        document = () async => buildMermaidDocument(
          await text(),
          dark: dark,
          background: colors.surfaceVariant,
          ink: colors.textPrimary,
        );
        label = strings.vwDiagramLabel;
        icon = HIcons.account_tree_outlined;
        aspect = 16 / 9;
        fit = true;
        ready = kMermaidReadyScript;
      case _Kind.model:
        document = () async => buildModelDocument(
          await file.readAsBytes(),
          mimeType: modelMimeFor(name ?? file.path) ?? 'model/gltf-binary',
          background: colors.surfaceVariant,
        );
        label = strings.vwModelLabel;
        icon = HIcons.view_in_ar_outlined;
        aspect = 1.2;
        ready = kModelReadyScript;
        capture = kModelCaptureScript;
        deadline = kModelPageDeadline;
    }
    return InlineWebPreview(
      key: ValueKey('document-preview-${file.path}-$dark'),
      document: document,
      label: label,
      icon: icon,
      aspectRatio: aspect,
      fitContent: fit,
      resolveSnapshotKey: pictureKey,
      autoLoad: auto,
      readyScript: ready,
      captureScript: capture,
      deadline: deadline,
      model: _kind == _Kind.model,
      onOpen: onOpen,
    );
  }
}

enum _Kind { html, svg, mermaid, model }

/// SHA-256 of the file at [path]. Top level: it runs in another isolate.
String _fileDigest(String path) =>
    sha256.convert(File(path).readAsBytesSync()).toString();

/// The head of a Markdown file as it reads, cut to a few lines' height with
/// a fade; a tap opens the whole note.
class MarkdownFilePreview extends StatelessWidget {
  const MarkdownFilePreview({
    super.key,
    required this.text,
    required this.onOpen,
  });

  final String text;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 300),
        child: Material(
          key: const ValueKey('markdown-file-preview'),
          color: colors.surfaceVariant,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: colors.divider),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onOpen,
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black, Colors.black, Colors.transparent],
                stops: [0, 0.82, 1],
              ).createShader(rect),
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                child: IgnorePointer(
                  child: ChatMarkdownBody(data: text, selectable: false),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
