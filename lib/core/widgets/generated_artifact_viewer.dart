import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/generated_artifact.dart';
import '../services/artifact_export_service.dart';
import '../services/generated_artifact_registry.dart';
import '../theme/app_theme.dart';
import '../utils/generated_artifact_detector.dart';
import 'hermes_notice.dart';
import 'hermes_premium_ui.dart';
import 'hermes_ui.dart';

const int generatedArtifactPreviewCharacterLimit = 120000;

Future<void> showGeneratedArtifactViewer({
  required BuildContext context,
  required GeneratedArtifactRegistry registry,
  required String artifactId,
  ArtifactExportActions exporter = const PlatformArtifactExportActions(),
}) => showHermesFloatingSurface<void>(
  context: context,
  surfaceKey: const ValueKey('generated-artifact-viewer'),
  maxWidth: 760,
  maxHeightFactor: 0.9,
  builder: (viewerContext) => GeneratedArtifactViewer(
    registry: registry,
    artifactId: artifactId,
    exporter: exporter,
    onClose: () => Navigator.of(viewerContext).pop(),
  ),
);

class GeneratedArtifactViewer extends StatefulWidget {
  final GeneratedArtifactRegistry registry;
  final String artifactId;
  final ArtifactExportActions exporter;
  final VoidCallback? onClose;

  const GeneratedArtifactViewer({
    required this.registry,
    required this.artifactId,
    this.exporter = const PlatformArtifactExportActions(),
    this.onClose,
    super.key,
  });

  @override
  State<GeneratedArtifactViewer> createState() =>
      _GeneratedArtifactViewerState();
}

class _GeneratedArtifactViewerState extends State<GeneratedArtifactViewer> {
  final ScrollController _sourceScroll = ScrollController();
  _ArtifactExportAction? _busyAction;

  @override
  void dispose() {
    _sourceScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.registry,
    builder: (context, _) {
      final record = widget.registry.getArtifact(widget.artifactId);
      if (record == null || record.versions.isEmpty) {
        return _MissingArtifact(onClose: widget.onClose);
      }
      final selected = widget.registry
          .selectedVersion(record.id)
          .clamp(0, record.versions.length - 1);
      return _buildRecord(context, record, selected);
    },
  );

  Widget _buildRecord(
    BuildContext context,
    GeneratedArtifactRecord record,
    int selected,
  ) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final version = record.versions[selected];
    final sourceOnly = record.kind != GeneratedArtifactKind.code;
    final truncated =
        version.content.length > generatedArtifactPreviewCharacterLimit;
    final visibleContent = truncated
        ? version.content.substring(0, generatedArtifactPreviewCharacterLimit)
        : version.content;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 520;
        final availableHeight = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : 720.0;
        final scrollWhole =
            MediaQuery.textScalerOf(context).scale(1) > 1.3 ||
            availableHeight < 560;
        final sourceHeight = (availableHeight * 0.45)
            .clamp(240.0, 360.0)
            .toDouble();
        final content = Column(
          mainAxisSize: scrollWhole ? MainAxisSize.min : MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 16 : 20,
                compact ? 14 : 18,
                8,
                12,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  HermesIconTile(
                    _kindIcon(record.kind),
                    size: 38,
                    color: colors.accent,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          record.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: compact ? 15 : 17,
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 7,
                          runSpacing: 6,
                          children: [
                            HermesBadge(
                              _kindLabel(record.kind, strings),
                              color: colors.accent,
                            ),
                            if (record.language.isNotEmpty)
                              HermesBadge(
                                record.language,
                                color: colors.textSecondary,
                                dot: false,
                              ),
                            HermesBadge(
                              strings.generatedArtifactVersionCount(
                                record.versions.length,
                              ),
                              color: colors.textSecondary,
                              dot: false,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (widget.onClose != null)
                    IconButton(
                      tooltip: strings.commonClose,
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.close_rounded),
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.divider),
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 12 : 18,
                9,
                compact ? 12 : 18,
                9,
              ),
              child: _VersionSelector(
                current: selected,
                total: record.versions.length,
                onSelect: (index) {
                  if (_sourceScroll.hasClients) {
                    _sourceScroll.jumpTo(
                      _sourceScroll.position.minScrollExtent,
                    );
                  }
                  widget.registry.selectVersion(record.id, index);
                },
              ),
            ),
            if (sourceOnly)
              Container(
                margin: EdgeInsets.fromLTRB(
                  compact ? 12 : 18,
                  0,
                  compact ? 12 : 18,
                  9,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceVariant.withValues(alpha: 0.38),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: colors.divider.withValues(alpha: 0.55),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 17,
                      color: colors.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        strings.generatedArtifactSourceOnly,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 11.5,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (scrollWhole)
              SizedBox(
                height: sourceHeight,
                child: _buildSourcePanel(
                  colors: colors,
                  strings: strings,
                  record: record,
                  selected: selected,
                  compact: compact,
                  visibleContent: visibleContent,
                ),
              )
            else
              Expanded(
                child: _buildSourcePanel(
                  colors: colors,
                  strings: strings,
                  record: record,
                  selected: selected,
                  compact: compact,
                  visibleContent: visibleContent,
                ),
              ),
            if (truncated)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 14 : 20,
                  7,
                  compact ? 14 : 20,
                  0,
                ),
                child: Text(
                  strings.generatedArtifactPreviewTruncated(
                    generatedArtifactPreviewCharacterLimit,
                  ),
                  style: TextStyle(color: colors.warning, fontSize: 10.5),
                ),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 12 : 18,
                10,
                compact ? 12 : 18,
                compact ? 12 : 16,
              ),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  _ActionButton(
                    icon: Icons.content_copy_outlined,
                    label: strings.commonCopy,
                    busy: _busyAction == _ArtifactExportAction.copy,
                    onPressed: _busyAction == null
                        ? () => _export(
                            _ArtifactExportAction.copy,
                            record,
                            version,
                          )
                        : null,
                  ),
                  _ActionButton(
                    icon: Icons.share_outlined,
                    label: strings.commonShare,
                    busy: _busyAction == _ArtifactExportAction.share,
                    onPressed: _busyAction == null
                        ? () => _export(
                            _ArtifactExportAction.share,
                            record,
                            version,
                          )
                        : null,
                  ),
                  _ActionButton(
                    icon: Icons.download_outlined,
                    label: strings.commonSave,
                    busy: _busyAction == _ArtifactExportAction.save,
                    onPressed: _busyAction == null
                        ? () => _export(
                            _ArtifactExportAction.save,
                            record,
                            version,
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ],
        );
        if (scrollWhole) {
          return SingleChildScrollView(primary: false, child: content);
        }
        return ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 320),
          child: content,
        );
      },
    );
  }

  Widget _buildSourcePanel({
    required HermesThemeColors colors,
    required Strings strings,
    required GeneratedArtifactRecord record,
    required int selected,
    required bool compact,
    required String visibleContent,
  }) => Container(
    margin: EdgeInsets.symmetric(horizontal: compact ? 12 : 18),
    decoration: BoxDecoration(
      color: colors.background.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: colors.divider.withValues(alpha: 0.65)),
    ),
    clipBehavior: Clip.antiAlias,
    child: Scrollbar(
      controller: _sourceScroll,
      thumbVisibility: true,
      child: SingleChildScrollView(
        key: ValueKey('generated-artifact-source-$selected'),
        controller: _sourceScroll,
        padding: const EdgeInsets.all(14),
        child: Semantics(
          label: strings.generatedArtifactSourceSemantics(record.title),
          child: SelectionArea(
            child: Text(
              visibleContent,
              style: TextStyle(
                color: colors.textPrimary,
                fontFamily: 'monospace',
                fontSize: compact ? 11.5 : 12.5,
                height: 1.5,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> _export(
    _ArtifactExportAction action,
    GeneratedArtifactRecord record,
    GeneratedArtifactVersion version,
  ) async {
    if (_busyAction != null) return;
    setState(() => _busyAction = action);
    final strings = Strings.of(context);
    final detection = GeneratedArtifactDetection(
      kind: record.kind,
      language: record.language,
      title: record.title,
    );
    final fileName = GeneratedArtifactDetector.downloadName(detection);
    try {
      switch (action) {
        case _ArtifactExportAction.copy:
          await widget.exporter.copyText(version.content);
          if (mounted) _message(strings.generatedArtifactCopied);
          break;
        case _ArtifactExportAction.share:
          await widget.exporter.shareText(
            fileName: fileName,
            mimeType: _mimeType(record.kind),
            content: version.content,
          );
          break;
        case _ArtifactExportAction.save:
          final result = await widget.exporter.saveText(
            fileName: fileName,
            content: version.content,
          );
          if (mounted && result == ArtifactSaveResult.saved) {
            _message(strings.generatedArtifactSaved(fileName));
          }
          break;
      }
    } on ArtifactExportTooLarge catch (error) {
      if (mounted) {
        _message(
          strings.generatedArtifactExportTooLarge(
            error.maximumBytes ~/ (1024 * 1024),
          ),
        );
      }
    } on Object {
      if (mounted) _message(strings.generatedArtifactExportFailed);
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  void _message(String message) {
    HermesNotice.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _VersionSelector extends StatelessWidget {
  final int current;
  final int total;
  final ValueChanged<int> onSelect;

  const _VersionSelector({
    required this.current,
    required this.total,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Semantics(
      container: true,
      label: strings.generatedArtifactVersionOf(current + 1, total),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('generated-artifact-previous-version'),
            tooltip: strings.generatedArtifactPreviousVersion,
            onPressed: current > 0 ? () => onSelect(current - 1) : null,
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          Expanded(
            child: Text(
              strings.generatedArtifactVersionOf(current + 1, total),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (current < total - 1)
            TextButton(
              onPressed: () => onSelect(total - 1),
              child: Text(strings.generatedArtifactLatest),
            ),
          IconButton(
            key: const ValueKey('generated-artifact-next-version'),
            tooltip: strings.generatedArtifactNextVersion,
            onPressed: current < total - 1 ? () => onSelect(current + 1) : null,
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool busy;
  final VoidCallback? onPressed;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onPressed,
    icon: busy
        ? const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(icon, size: 17),
    label: Text(label),
  );
}

class _MissingArtifact extends StatelessWidget {
  final VoidCallback? onClose;

  const _MissingArtifact({this.onClose});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 38,
            color: colors.textDisabled,
          ),
          const SizedBox(height: 12),
          Text(
            strings.generatedArtifactMissing,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textPrimary, fontSize: 14),
          ),
          if (onClose != null) ...[
            const SizedBox(height: 16),
            TextButton(onPressed: onClose, child: Text(strings.commonClose)),
          ],
        ],
      ),
    );
  }
}

enum _ArtifactExportAction { copy, share, save }

String _kindLabel(GeneratedArtifactKind kind, Strings strings) =>
    switch (kind) {
      GeneratedArtifactKind.code => strings.generatedArtifactKindCode,
      GeneratedArtifactKind.html => strings.generatedArtifactKindHtml,
      GeneratedArtifactKind.svg => strings.generatedArtifactKindSvg,
    };

IconData _kindIcon(GeneratedArtifactKind kind) => switch (kind) {
  GeneratedArtifactKind.code => Icons.code_rounded,
  GeneratedArtifactKind.html => Icons.html_rounded,
  GeneratedArtifactKind.svg => Icons.polyline_rounded,
};

String _mimeType(GeneratedArtifactKind kind) => switch (kind) {
  GeneratedArtifactKind.code => 'text/plain',
  GeneratedArtifactKind.html => 'text/html',
  GeneratedArtifactKind.svg => 'image/svg+xml',
};
