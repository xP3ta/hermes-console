// "Review what was shared": what another app sent through the Android share
// sheet, shown before anything leaves the device. The user can drop the text
// or any attachment and picks the instance it goes to; only then does it
// become a chat draft. Backing out discards the share.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/tokens.dart' show HermesRadius, HermesSpace;
import '../models/attachment_draft.dart';
import '../models/connection.dart';
import '../services/android_share_inbox.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';

/// What the user decided: the content that is left and where it goes.
class SharedReviewResult {
  const SharedReviewResult({required this.content, required this.connection});

  final AndroidSharedContent content;
  final SavedConnection connection;
}

class SharedReviewScreen extends StatefulWidget {
  const SharedReviewScreen({
    required this.content,
    required this.connections,
    required this.initialConnectionId,
    super.key,
  });

  final AndroidSharedContent content;
  final List<SavedConnection> connections;
  final String? initialConnectionId;

  @override
  State<SharedReviewScreen> createState() => _SharedReviewScreenState();
}

class _SharedReviewScreenState extends State<SharedReviewScreen> {
  late bool _keepText = widget.content.text.trim().isNotEmpty;
  late final List<AttachmentDraft> _attachments = [
    ...widget.content.attachments,
  ];
  late SavedConnection _target = widget.connections.firstWhere(
    (item) => item.id == widget.initialConnectionId,
    orElse: () => widget.connections.first,
  );

  bool get _hasText => widget.content.text.trim().isNotEmpty;
  bool get _anythingLeft => (_hasText && _keepText) || _attachments.isNotEmpty;

  void _send() {
    if (!_anythingLeft) return;
    Navigator.of(context).pop(
      SharedReviewResult(
        content: AndroidSharedContent(
          id: widget.content.id,
          text: _keepText ? widget.content.text : '',
          attachments: List.of(_attachments),
          rejectedAttachments: widget.content.rejectedAttachments,
        ),
        connection: _target,
      ),
    );
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Widget _item({
    required Key removeKey,
    required String title,
    required String subtitle,
    required VoidCallback onRemove,
  }) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Container(
      margin: const EdgeInsets.only(bottom: HermesSpace.x2),
      padding: const EdgeInsets.all(HermesSpace.x3),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(HermesRadius.card),
        border: Border.all(color: colors.divider),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          TextButton(
            key: removeKey,
            onPressed: onRemove,
            child: Text(s.memShareRemove),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: HermesAppBar(title: Text(s.memShareTitle)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(HermesSpace.x4),
                children: [
                  Text(s.memShareIntro, style: textTheme.bodyMedium),
                  const SizedBox(height: HermesSpace.x4),
                  if (_hasText && _keepText)
                    _item(
                      removeKey: const ValueKey('share-remove-text'),
                      title: widget.content.text.trim(),
                      subtitle: s.memShareTextChars(
                        widget.content.text.trim().length,
                      ),
                      onRemove: () => setState(() => _keepText = false),
                    ),
                  for (var i = 0; i < _attachments.length; i++)
                    _item(
                      removeKey: ValueKey('share-remove-attachment-$i'),
                      title: _attachments[i].name,
                      subtitle: _size(_attachments[i].sizeBytes),
                      onRemove: () => setState(() => _attachments.removeAt(i)),
                    ),
                  if (!_anythingLeft)
                    Padding(
                      key: const ValueKey('share-nothing-left'),
                      padding: const EdgeInsets.symmetric(
                        vertical: HermesSpace.x4,
                      ),
                      child: Text(
                        s.memShareNothingLeft,
                        style: textTheme.bodyMedium?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  if (widget.connections.length > 1) ...[
                    const SizedBox(height: HermesSpace.x4),
                    Text(s.memShareDestination, style: textTheme.titleSmall),
                    const SizedBox(height: HermesSpace.x2),
                    Wrap(
                      spacing: HermesSpace.x2,
                      runSpacing: HermesSpace.x2,
                      children: [
                        for (final connection in widget.connections)
                          ChoiceChip(
                            key: ValueKey('share-target-${connection.id}'),
                            label: Text(connection.label),
                            selected: connection.id == _target.id,
                            onSelected: (_) =>
                                setState(() => _target = connection),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(HermesSpace.x4),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('share-discard'),
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(s.memShareDiscard),
                    ),
                  ),
                  const SizedBox(width: HermesSpace.x3),
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey('share-send'),
                      onPressed: _anythingLeft ? _send : null,
                      child: Text(s.memShareContinue),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
