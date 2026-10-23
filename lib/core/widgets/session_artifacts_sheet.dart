import 'package:flutter/material.dart';

import '../utils/artifact_name_copy.dart';
import '../../l10n/app_localizations.dart';
import '../models/generated_artifact.dart';
import '../models/session_artifact.dart';
import '../services/generated_artifact_registry.dart';
import '../services/session_artifact_download_service.dart';
import '../theme/app_theme.dart';
import 'hermes_ui.dart';

class SessionArtifactsSheet extends StatelessWidget {
  final List<SessionArtifact> artifacts;
  final GeneratedArtifactRegistry? generatedArtifactRegistry;
  final String? generatedArtifactSessionId;
  final ValueChanged<String>? onOpenGeneratedArtifact;
  final bool Function(SessionArtifact artifact)? canDownloadArtifact;
  final Future<void> Function(SessionArtifact artifact)? onDownloadArtifact;
  final ValueChanged<SessionArtifactSource>? onJumpToSource;
  final bool showDragHandle;

  const SessionArtifactsSheet({
    required this.artifacts,
    this.generatedArtifactRegistry,
    this.generatedArtifactSessionId,
    this.onOpenGeneratedArtifact,
    this.canDownloadArtifact,
    this.onDownloadArtifact,
    this.onJumpToSource,
    this.showDragHandle = true,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final registry = generatedArtifactRegistry;
    final sessionId = generatedArtifactSessionId;
    if (registry == null || sessionId == null || sessionId.trim().isEmpty) {
      return _buildContent(context, const []);
    }
    return AnimatedBuilder(
      animation: registry,
      builder: (context, _) =>
          _buildContent(context, registry.artifactsForSession(sessionId)),
    );
  }

  Widget _buildContent(
    BuildContext context,
    List<GeneratedArtifactRecord> generatedArtifacts,
  ) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final groups = _groupArtifacts(artifacts);
    final entries = _artifactListEntries(groups, generatedArtifacts);
    final screenHeight = MediaQuery.sizeOf(context).height;
    final totalCount = artifacts.length + generatedArtifacts.length;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: screenHeight * 0.82),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showDragHandle) ...[
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.textDisabled.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 13),
              child: Row(
                children: [
                  HermesIconTile(
                    Icons.inventory_2_outlined,
                    size: 38,
                    color: colors.accent,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          strings.artifactTitle,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          strings.artifactCount(totalCount),
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.divider.withValues(alpha: 0.7)),
            if (entries.isEmpty)
              const _EmptyArtifactsState()
            else
              Flexible(
                child: ListView.builder(
                  key: const ValueKey('session-artifacts-list'),
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 20),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    return switch (entries[index]) {
                      _GeneratedArtifactHeaderEntry(:final itemCount) =>
                        HermesSectionHeader(
                          '${strings.generatedArtifactSection} · $itemCount',
                        ),
                      _GeneratedArtifactRowEntry(:final artifact) =>
                        _GeneratedArtifactRow(
                          artifact: artifact,
                          onOpen: onOpenGeneratedArtifact,
                        ),
                      _ArtifactHeaderEntry(:final kind, :final itemCount) =>
                        HermesSectionHeader(
                          '${_kindGroupLabel(kind, strings)} · $itemCount',
                        ),
                      _ArtifactRowEntry(
                        :final artifact,
                        :final isFirst,
                        :final isLast,
                      ) =>
                        _ArtifactGroupRow(
                          isFirst: isFirst,
                          isLast: isLast,
                          child: _ArtifactRow(
                            artifact: artifact,
                            canDownload: canDownloadArtifact,
                            onDownload: onDownloadArtifact,
                            onJumpToSource: onJumpToSource,
                            strings: strings,
                          ),
                        ),
                    };
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ArtifactGroup {
  final SessionArtifactKind kind;
  final List<SessionArtifact> items;

  const _ArtifactGroup({required this.kind, required this.items});
}

List<_ArtifactGroup> _groupArtifacts(List<SessionArtifact> artifacts) {
  final groups = <_ArtifactGroup>[];
  for (final kind in SessionArtifactKind.values) {
    final items = [
      for (final artifact in artifacts)
        if (artifact.kind == kind) artifact,
    ];
    if (items.isNotEmpty) {
      groups.add(_ArtifactGroup(kind: kind, items: items));
    }
  }
  return groups;
}

sealed class _ArtifactListEntry {
  const _ArtifactListEntry();
}

final class _ArtifactHeaderEntry extends _ArtifactListEntry {
  final SessionArtifactKind kind;
  final int itemCount;

  const _ArtifactHeaderEntry({required this.kind, required this.itemCount});
}

final class _GeneratedArtifactHeaderEntry extends _ArtifactListEntry {
  final int itemCount;

  const _GeneratedArtifactHeaderEntry({required this.itemCount});
}

final class _GeneratedArtifactRowEntry extends _ArtifactListEntry {
  final GeneratedArtifactRecord artifact;

  const _GeneratedArtifactRowEntry({required this.artifact});
}

final class _ArtifactRowEntry extends _ArtifactListEntry {
  final SessionArtifact artifact;
  final bool isFirst;
  final bool isLast;

  const _ArtifactRowEntry({
    required this.artifact,
    required this.isFirst,
    required this.isLast,
  });
}

List<_ArtifactListEntry> _artifactListEntries(
  List<_ArtifactGroup> groups,
  List<GeneratedArtifactRecord> generatedArtifacts,
) {
  final entries = <_ArtifactListEntry>[];
  if (generatedArtifacts.isNotEmpty) {
    entries.add(
      _GeneratedArtifactHeaderEntry(itemCount: generatedArtifacts.length),
    );
    for (final artifact in generatedArtifacts) {
      entries.add(_GeneratedArtifactRowEntry(artifact: artifact));
    }
  }
  for (final group in groups) {
    entries.add(
      _ArtifactHeaderEntry(kind: group.kind, itemCount: group.items.length),
    );
    for (var index = 0; index < group.items.length; index++) {
      entries.add(
        _ArtifactRowEntry(
          artifact: group.items[index],
          isFirst: index == 0,
          isLast: index == group.items.length - 1,
        ),
      );
    }
  }
  return entries;
}

class _GeneratedArtifactRow extends StatelessWidget {
  final GeneratedArtifactRecord artifact;
  final ValueChanged<String>? onOpen;

  const _GeneratedArtifactRow({required this.artifact, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final latest = artifact.versions.last;
    final kind = switch (artifact.kind) {
      GeneratedArtifactKind.code => strings.generatedArtifactKindCode,
      GeneratedArtifactKind.html => strings.generatedArtifactKindHtml,
      GeneratedArtifactKind.svg => strings.generatedArtifactKindSvg,
    };
    final enabled = onOpen != null;
    return Semantics(
      button: enabled,
      enabled: enabled,
      label: strings.generatedArtifactOpenSemantics(artifact.title),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: colors.surfaceVariant.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(HermesRadii.group),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('generated-artifact-${artifact.id}'),
            onTap: enabled ? () => onOpen!(artifact.id) : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 68),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(13, 11, 11, 11),
                child: Row(
                  children: [
                    HermesIconTile(
                      switch (artifact.kind) {
                        GeneratedArtifactKind.code => Icons.code_rounded,
                        GeneratedArtifactKind.html => Icons.html_rounded,
                        GeneratedArtifactKind.svg => Icons.polyline_rounded,
                      },
                      size: 34,
                      color: colors.accent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            artifact.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Wrap(
                            spacing: 7,
                            runSpacing: 4,
                            children: [
                              HermesBadge(kind, color: colors.accent),
                              if (artifact.language.isNotEmpty)
                                HermesBadge(
                                  artifact.language,
                                  color: colors.textSecondary,
                                  dot: false,
                                ),
                              HermesBadge(
                                strings.generatedArtifactVersionCount(
                                  artifact.versions.length,
                                ),
                                color: colors.textSecondary,
                                dot: false,
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '${strings.generatedArtifactCharacterCount(latest.content.length)} · '
                            'sha256:${latest.sha256.substring(0, 10)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontFamily: 'monospace',
                              fontSize: 9.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (enabled)
                      Icon(
                        Icons.chevron_right_rounded,
                        color: colors.textDisabled,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ArtifactGroupRow extends StatelessWidget {
  final bool isFirst;
  final bool isLast;
  final Widget child;

  const _ArtifactGroupRow({
    required this.isFirst,
    required this.isLast,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    const radius = Radius.circular(HermesRadii.group);
    final borderRadius = BorderRadius.only(
      topLeft: isFirst ? radius : Radius.zero,
      topRight: isFirst ? radius : Radius.zero,
      bottomLeft: isLast ? radius : Radius.zero,
      bottomRight: isLast ? radius : Radius.zero,
    );
    return ClipRRect(
      borderRadius: borderRadius,
      child: ColoredBox(
        color: colors.surfaceVariant.withValues(alpha: 0.3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            child,
            if (!isLast)
              Divider(
                height: 1,
                thickness: 1,
                indent: 16,
                endIndent: 16,
                color: colors.divider.withValues(alpha: 0.35),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyArtifactsState extends StatelessWidget {
  const _EmptyArtifactsState();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 38, 28, 42),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 36,
            color: colors.textDisabled,
          ),
          const SizedBox(height: 13),
          Text(
            strings.artifactEmptyTitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            strings.artifactEmptyBody,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtifactRow extends StatelessWidget {
  final SessionArtifact artifact;
  final bool Function(SessionArtifact artifact)? canDownload;
  final Future<void> Function(SessionArtifact artifact)? onDownload;
  final ValueChanged<SessionArtifactSource>? onJumpToSource;
  final Strings strings;

  const _ArtifactRow({
    required this.artifact,
    required this.strings,
    this.canDownload,
    this.onDownload,
    this.onJumpToSource,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final source = artifact.sources.isEmpty ? null : artifact.primarySource;
    final canJump = source != null && onJumpToSource != null;
    final canSave =
        onDownload != null && (canDownload?.call(artifact) ?? false);
    final availabilityColor = _availabilityColor(colors, artifact.availability);

    return Semantics(
      button: canJump,
      label: canJump
          ? strings.artifactJumpSemantics(artifactNameCopy(strings, artifact))
          : artifactNameCopy(strings, artifact),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('session-artifact-${artifact.id}'),
          onTap: canJump ? () => onJumpToSource!(source) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(13, 12, 11, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                HermesIconTile(
                  _kindIcon(artifact.kind),
                  size: 34,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        artifactNameCopy(strings, artifact),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Wrap(
                        spacing: 7,
                        runSpacing: 5,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          HermesBadge(
                            _availabilityLabel(artifact.availability, strings),
                            color: availabilityColor,
                          ),
                          if (artifact.mimeType case final mimeType?)
                            _MetadataLabel(mimeType),
                          if (artifact.sizeBytes case final sizeBytes?)
                            _MetadataLabel(_formatBytes(sizeBytes)),
                        ],
                      ),
                      if (source != null) ...[
                        const SizedBox(height: 7),
                        Text(
                          _sourceLabel(
                            source,
                            artifact.sources.length,
                            strings,
                          ),
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (canSave)
                  _ArtifactDownloadButton(
                    artifact: artifact,
                    onDownload: onDownload!,
                  ),
                if (canJump) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: strings.artifactJumpSource,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Icon(
                        Icons.arrow_upward_rounded,
                        size: 19,
                        color: colors.accent,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ArtifactDownloadButton extends StatefulWidget {
  final SessionArtifact artifact;
  final Future<void> Function(SessionArtifact artifact) onDownload;

  const _ArtifactDownloadButton({
    required this.artifact,
    required this.onDownload,
  });

  @override
  State<_ArtifactDownloadButton> createState() =>
      _ArtifactDownloadButtonState();
}

class _ArtifactDownloadButtonState extends State<_ArtifactDownloadButton> {
  bool _busy = false;

  Future<void> _download() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onDownload(widget.artifact);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return IconButton(
      tooltip: Strings.of(context).commonDownload,
      onPressed: _busy ? null : _download,
      icon: _busy
          ? SizedBox.square(
              dimension: 17,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.accent,
              ),
            )
          : Icon(Icons.download_outlined, size: 19, color: colors.accent),
    );
  }
}

class _MetadataLabel extends StatelessWidget {
  final String label;

  const _MetadataLabel(this.label);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: colors.textSecondary,
        fontFamily: 'monospace',
        fontSize: 10.5,
      ),
    );
  }
}

String _kindGroupLabel(SessionArtifactKind kind, Strings strings) =>
    switch (kind) {
      SessionArtifactKind.image => strings.artifactImages,
      SessionArtifactKind.file => strings.artifactFiles,
      SessionArtifactKind.document => strings.artifactDocuments,
      SessionArtifactKind.generated => strings.artifactGenerated,
      SessionArtifactKind.toolResult => strings.artifactToolResults,
      SessionArtifactKind.unknown => strings.artifactOther,
    };

IconData _kindIcon(SessionArtifactKind kind) => switch (kind) {
  SessionArtifactKind.image => Icons.image_outlined,
  SessionArtifactKind.file => Icons.insert_drive_file_outlined,
  SessionArtifactKind.document => Icons.description_outlined,
  SessionArtifactKind.generated => Icons.auto_awesome_outlined,
  SessionArtifactKind.toolResult => Icons.build_circle_outlined,
  SessionArtifactKind.unknown => Icons.inventory_2_outlined,
};

String _availabilityLabel(
  SessionArtifactAvailability availability,
  Strings strings,
) => switch (availability) {
  SessionArtifactAvailability.ready => strings.artifactAvailable,
  SessionArtifactAvailability.missing => strings.artifactMissing,
  SessionArtifactAvailability.expired => strings.artifactExpired,
  SessionArtifactAvailability.unknown => strings.artifactUnknown,
};

Color _availabilityColor(
  HermesThemeColors colors,
  SessionArtifactAvailability availability,
) => switch (availability) {
  SessionArtifactAvailability.ready => colors.success,
  SessionArtifactAvailability.missing => colors.error,
  SessionArtifactAvailability.expired => colors.warning,
  SessionArtifactAvailability.unknown => colors.textSecondary,
};

String _sourceLabel(
  SessionArtifactSource source,
  int sourceCount,
  Strings strings,
) {
  final messageNumber = source.messageOrdinal + 1;
  if (sourceCount == 1) return strings.artifactSourceOne(messageNumber);
  return strings.artifactSourceMany(messageNumber, sourceCount);
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  final decimals = value >= 10 || value == value.roundToDouble() ? 0 : 1;
  return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
}

String sessionArtifactDownloadMessage(
  Strings strings,
  SessionArtifactDownloadFailure failure,
) => switch (failure) {
  SessionArtifactDownloadFailure.unavailable ||
  SessionArtifactDownloadFailure.notFound =>
    strings.artifactDownloadUnavailable,
  SessionArtifactDownloadFailure.expired => strings.artifactDownloadExpired,
  SessionArtifactDownloadFailure.unsupportedReference =>
    strings.artifactDownloadUnsupported,
  SessionArtifactDownloadFailure.accessDenied =>
    strings.artifactDownloadAccessDenied,
  SessionArtifactDownloadFailure.tooLarge => strings.artifactDownloadTooLarge,
  SessionArtifactDownloadFailure.server => strings.artifactDownloadFailed,
};
