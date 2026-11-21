// «Compose» for the SSH terminal (1.4.3): the way to write into the shell
// from a phone, after herdr's mobile app. A card over the dock with a
// native text box (the phone keyboard's suggestions, swipe typing and
// dictation; the terminal itself keeps a keyboard without them, see
// U-03), Paste, attachments (a photo or a file goes up to the server over
// this SSH connection and its path is written into the text), the
// microphone of the chat composer, and send: one paste, then Enter. The
// draft lives in memory only (SshComposeDraft): it outlives the card, a
// rotation or a fold, and is kept, with a notice, when the text could not
// be sent.
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hermes_android/core/design/hicons.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import '../../l10n/app_localizations.dart';
import '../bots/ui/room/room_dictation.dart';
import '../feedback/haptics.dart';
import '../services/ssh_compose_uploads.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import '../utils/ssh_error.dart';
import 'attachment_source_sheet.dart';
import 'chat/composer_clipboard_menu.dart';
import 'chat/composer_pasted_image.dart';
import 'hermes_premium_ui.dart'
    show HermesComposerSurface, HermesTactileAction, HermesTactileActionVisual;

/// Where Compose's attachments come from (the platform's pickers by
/// default; tests give their own).
typedef SshComposePicker = Future<List<SshComposePick>> Function(
  AttachmentSourceChoice source,
);

/// Sends [text] to the shell as one paste, Enter after it when [enter].
/// False when it could not be written (the connection is gone).
typedef SshComposeSend = bool Function(String text, {required bool enter});

/// The camera, the photo library (the system's photo picker) or the files,
/// with the chat composer's sizes for photos.
Future<List<SshComposePick>> sshComposePlatformPick(
  AttachmentSourceChoice source,
) async {
  SshComposePick fromFile(String name, String path, int size, bool image) =>
      SshComposePick(
        name: name,
        size: size,
        image: image,
        open: () => File(path).openRead(),
      );
  switch (source) {
    case AttachmentSourceChoice.camera:
    case AttachmentSourceChoice.photos:
      // The system's photo picker, as the chat composer asks for it.
      final implementation = ImagePickerPlatform.instance;
      if (implementation is ImagePickerAndroid) {
        implementation.useAndroidPhotoPicker = true;
      }
      final picker = ImagePicker();
      final files = source == AttachmentSourceChoice.camera
          ? [
              ?await picker.pickImage(
                source: ImageSource.camera,
                imageQuality: 82,
                maxWidth: 2048,
                maxHeight: 2048,
              ),
            ]
          : await picker.pickMultiImage(
              imageQuality: 82,
              maxWidth: 2048,
              maxHeight: 2048,
            );
      return [
        for (final file in files)
          fromFile(file.name, file.path, await file.length(), true),
      ];
    case AttachmentSourceChoice.files:
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      return [
        for (final file in result?.files ?? const <PlatformFile>[])
          if (file.path != null)
            fromFile(file.name, file.path!, file.size, false),
      ];
  }
}

/// The Compose card: the chat's input surface floating
/// just above the dock, the terminal visible behind it. A text box
/// («Message or command») with the phone keyboard's suggestions, swipe
/// typing and dictation; under it Paste, Attach (and what was sent this
/// session) on the left, the microphone and the round send button on the
/// right. Send writes the text to the shell as one paste followed by Enter
/// and clears the box; a long press on it writes it without Enter.
class SshComposeCard extends StatefulWidget {
  const SshComposeCard({
    required this.draft,
    required this.send,
    this.history = const [],
    this.attachUnavailable,
    this.pick,
    this.dictation,
    this.maxHeight = double.infinity,
    super.key,
  });

  final SshComposeDraft draft;
  final SshComposeSend send;

  /// What was sent this session, newest first.
  final List<String> history;

  /// Why files cannot be attached now (read-only, not connected); null
  /// when they can.
  final String? attachUnavailable;

  /// Where attachments come from; the platform's pickers when null.
  final SshComposePicker? pick;

  /// The chat composer's dictation (the same engine); no microphone when
  /// null.
  final RoomDictation? dictation;

  /// The most the card may grow (the text box scrolls inside it), so the
  /// prompt line of the terminal stays in sight above it.
  final double maxHeight;

  @override
  State<SshComposeCard> createState() => _SshComposeCardState();
}

class _SshComposeCardState extends State<SshComposeCard> {
  /// Why the last action did not go through (not sent, too large, cannot
  /// attach); cleared by the next one.
  String? _notice;

  /// The three sources of an attachment are showing.
  bool _sources = false;

  /// What was sent this session is showing.
  bool _history = false;

  /// Invalidates in-flight dictation callbacks on send, restart, or dispose.
  int _dictationEpoch = 0;

  final FocusNode _fieldFocus = FocusNode();

  SshComposeDraft get _draft => widget.draft;

  void _cancelDictation() {
    _dictationEpoch++;
    final dictation = widget.dictation;
    if (dictation != null && (dictation.recording || dictation.transcribing)) {
      unawaited(dictation.cancel());
    }
  }

  static String _mergeDictation(String start, String current, String result) {
    if (current == start) return result;
    final base = start.trimRight();
    final spoken = base.isNotEmpty && result.startsWith(base)
        ? result.substring(base.length).trim()
        : result.trim();
    if (spoken.isEmpty) return current;
    if (current.trim().isEmpty) return spoken;
    return RegExp(r'\s$').hasMatch(current)
        ? '$current$spoken'
        : '$current $spoken';
  }

  @override
  void dispose() {
    _cancelDictation();
    _fieldFocus.dispose();
    super.dispose();
  }

  void _say(String? notice) {
    if (mounted) setState(() => _notice = notice);
  }

  void _send({required bool enter}) {
    final text = _draft.text.text;
    if (text.isEmpty || _draft.uploading) return;
    _draft.clearDeliveryUncertain();
    if (!widget.send(text, enter: enter)) {
      // Nothing was written: the text stays for another try.
      _say(Strings.of(context).termUxComposeNotSent);
      return;
    }
    HermesHaptics.selection();
    _cancelDictation();
    _draft.clear();
    setState(() {
      _notice = null;
      _history = false;
    });
  }

  /// The clipboard's text where the cursor is (in place of a selection).
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final clip = data?.text;
    if (clip == null || clip.isEmpty || !mounted) return;
    final value = _draft.text.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final text = value.text.replaceRange(selection.start, selection.end, clip);
    _draft.text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: selection.start + clip.length),
    );
  }

  void _recall(String entry) {
    _draft.text.value = TextEditingValue(
      text: entry,
      selection: TextSelection.collapsed(offset: entry.length),
    );
    setState(() => _history = false);
  }

  void _toggleSources() {
    final why = widget.attachUnavailable;
    if (why != null) {
      _say(why);
      return;
    }
    setState(() {
      _sources = !_sources;
      _history = false;
    });
  }

  Future<void> _attachFrom(AttachmentSourceChoice source) async {
    setState(() {
      _sources = false;
      _notice = null;
    });
    final List<SshComposePick> picks;
    try {
      picks = await (widget.pick ?? sshComposePlatformPick)(source);
    } on Object catch (error) {
      debugPrint('[compose] picker failed (${error.runtimeType})');
      if (mounted) _say(Strings.of(context).termUxUploadFailed);
      return;
    }
    if (!mounted) return;
    for (final pick in picks) {
      _attach(pick);
    }
  }

  /// [pick] is uploaded, unless it is over the chat composer's limit.
  void _attach(SshComposePick pick) {
    if (pick.tooLarge) {
      final mb = pick.limit ~/ (1024 * 1024);
      _say(Strings.of(context).chaFileTooBig('$mb MB'));
      return;
    }
    unawaited(_watch(_draft.attach(pick)));
  }

  void _retry(SshComposeAttachment attachment) {
    _say(null);
    unawaited(_watch(_draft.retry(attachment)));
  }

  /// When [upload] fails, the notice says why (no SFTP on the server, the
  /// connection gone…), next to its chip's retry.
  Future<void> _watch(Future<SshComposeAttachment> upload) async {
    final attachment = await upload;
    final error = attachment.error;
    if (!mounted || attachment.state != SshUploadState.failed) return;
    final strings = Strings.of(context);
    final failed = strings.termUxUploadFailed;
    _say(
      error == null ? failed : '$failed · ${localizedSshError(strings, error)}',
    );
  }

  /// An image from the keyboard or pasted from the clipboard.
  void _inserted(KeyboardInsertedContent content) {
    final data = content.data;
    if (data == null || data.isEmpty) return;
    if (widget.attachUnavailable != null) {
      _say(widget.attachUnavailable);
      return;
    }
    final type = content.mimeType.split('/').last;
    _attach(SshComposePick.bytes('image.$type', data));
  }

  /// The microphone: dictation into the box, as in the chat composer; a
  /// second tap stops it and the words join the text.
  void _dictate() {
    final dictation = widget.dictation;
    if (dictation == null) return;
    HermesHaptics.selection();
    if (dictation.recording) {
      unawaited(dictation.stop());
      return;
    }
    if (dictation.transcribing) return;
    _say(null);
    final epoch = ++_dictationEpoch;
    final startText = _draft.text.text;
    final unavailable = Strings.of(context).termUxDictationUnavailable;
    unawaited(
      dictation.start(
        currentText: startText,
        onText: (result) {
          if (!mounted || epoch != _dictationEpoch) return;
          final merged = _mergeDictation(startText, _draft.text.text, result);
          _draft.text.value = TextEditingValue(
            text: merged,
            selection: TextSelection.collapsed(offset: merged.length),
          );
        },
        onFailure: (_) {
          if (!mounted || epoch != _dictationEpoch) return;
          _say(unavailable);
        },
      ),
    );
  }

  static const double _compactHeight = 140;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final notice = _notice;
    final mono = HermesType.text.copyWith(
      fontFamily: HermesType.monoFamily,
      color: colors.textPrimary,
    );
    final canAttach = widget.attachUnavailable == null;
    final compact =
        widget.maxHeight.isFinite && widget.maxHeight <= _compactHeight;
    final contents = Material(
      type: MaterialType.transparency,
      borderRadius: BorderRadius.circular(HermesRadius.pane),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                HermesSpace.x5,
                compact ? HermesSpace.x2 : HermesSpace.x4,
                HermesSpace.x5,
                0,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const ValueKey('ssh-compose-field'),
                    controller: _draft.text,
                    focusNode: _fieldFocus,
                    autofocus: true,
                    minLines: 1,
                    maxLines: compact ? 3 : 6,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    // The phone keyboard as in any text box: suggestions,
                    // swipe typing and dictation. No autocorrect (a command
                    // is not prose) and no learning: the keyboard does not
                    // keep what was typed here, as for the app's secret
                    // fields.
                    autocorrect: false,
                    enableSuggestions: true,
                    enableIMEPersonalizedLearning: false,
                    style: mono,
                    // An image from the keyboard or the clipboard is
                    // attached, as in the chat composer.
                    contentInsertionConfiguration: canAttach
                        ? ContentInsertionConfiguration(
                            allowedMimeTypes: kComposerInsertableImageMimeTypes,
                            onContentInserted: _inserted,
                          )
                        : null,
                    contextMenuBuilder: canAttach
                        ? (context, editable) => ComposerClipboardMenu(
                            editableTextState: editable,
                            onContentInserted: _inserted,
                          )
                        : (context, editable) =>
                              AdaptiveTextSelectionToolbar.editableText(
                                editableTextState: editable,
                              ),
                    decoration: InputDecoration(
                      hintText: strings.termUxComposeHint,
                      hintStyle: HermesType.text.copyWith(
                        color: colors.textSecondary,
                      ),
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        vertical: compact ? HermesSpace.x1 : HermesSpace.x2,
                      ),
                    ),
                  ),
                  ValueListenableBuilder<List<SshComposeAttachment>>(
                    valueListenable: _draft.attachments,
                    builder: (context, attachments, _) => attachments.isEmpty
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.only(top: HermesSpace.x2),
                            child: Wrap(
                              spacing: HermesSpace.x2,
                              runSpacing: HermesSpace.x2,
                              children: [
                                for (final (i, attachment)
                                    in attachments.indexed)
                                  _AttachmentChip(
                                    key: ValueKey('ssh-compose-attachment-$i'),
                                    index: i,
                                    attachment: attachment,
                                    colors: colors,
                                    onRemove: () =>
                                        unawaited(_draft.remove(attachment)),
                                    onRetry: () => _retry(attachment),
                                  ),
                              ],
                            ),
                          ),
                  ),
                  if (_sources)
                    Padding(
                      padding: const EdgeInsets.only(top: HermesSpace.x2),
                      child: Wrap(
                        spacing: HermesSpace.x2,
                        runSpacing: HermesSpace.x2,
                        children: [
                          for (final (source, icon, label) in [
                            (
                              AttachmentSourceChoice.camera,
                              HIcons.photo_camera_outlined,
                              strings.chatAttachCamera,
                            ),
                            (
                              AttachmentSourceChoice.photos,
                              HIcons.photo_library_outlined,
                              strings.chatAttachPhotos,
                            ),
                            (
                              AttachmentSourceChoice.files,
                              HIcons.attach_file_rounded,
                              strings.chatAttachFiles,
                            ),
                          ])
                            ActionChip(
                              key: ValueKey(
                                'ssh-compose-attach-${source.name}',
                              ),
                              avatar: Icon(icon, size: HermesIcon.md),
                              label: Text(label),
                              onPressed: () => unawaited(_attachFrom(source)),
                            ),
                        ],
                      ),
                    ),
                  if (_history)
                    for (final (i, entry) in widget.history.indexed)
                      ListTile(
                        key: ValueKey('ssh-compose-history-$i'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(HIcons.history_rounded),
                        title: Text(
                          entry,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: mono,
                        ),
                        onTap: () => _recall(entry),
                      ),
                  ValueListenableBuilder<bool>(
                    valueListenable: _draft.deliveryUncertain,
                    builder: (context, uncertain, _) {
                      final message =
                          notice ??
                          (uncertain
                              ? strings.tg143ComposeDeliveryUncertain
                              : null);
                      if (message == null) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: HermesSpace.x2),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            message,
                            key: const ValueKey('ssh-compose-notice'),
                            style: HermesType.support.copyWith(
                              color: notice != null
                                  ? colors.error
                                  : colors.textSecondary,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              HermesSpace.x2,
              compact ? 0 : HermesSpace.x1,
              HermesSpace.x2,
              compact ? HermesSpace.x1 : HermesSpace.x2,
            ),
            child: ValueListenableBuilder<List<SshComposeAttachment>>(
              valueListenable: _draft.attachments,
              builder: (context, attachments, _) => ListenableBuilder(
                listenable: Listenable.merge([
                  _draft.text,
                  ...attachments,
                  ?widget.dictation,
                ]),
                builder: (context, _) => _actions(context, canAttach),
              ),
            ),
          ),
        ],
      ),
    );
    return ConstrainedBox(
      key: const ValueKey('ssh-compose-card'),
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: ListenableBuilder(
        listenable: _fieldFocus,
        child: contents,
        builder: (context, child) => HermesComposerSurface(
          focused: _fieldFocus.hasFocus,
          unfocusedHorizontalInset: 0,
          child: child!,
        ),
      ),
    );
  }

  /// Paste, Attach and what was sent on the left; the microphone and send
  /// on the right.
  Widget _actions(BuildContext context, bool canAttach) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final ready = _draft.text.text.isNotEmpty && !_draft.uploading;
    final dictation = widget.dictation;
    final recording = dictation?.recording ?? false;
    return Row(
      children: [
        IconButton(
          key: const ValueKey('ssh-compose-paste'),
          tooltip: MaterialLocalizations.of(context).pasteButtonLabel,
          icon: Icon(HIcons.content_paste, color: colors.textPrimary),
          onPressed: _paste,
        ),
        IconButton(
          key: const ValueKey('ssh-compose-attach'),
          tooltip: strings.termUxAttach,
          isSelected: _sources,
          icon: Icon(
            HIcons.attach_file_rounded,
            color: canAttach ? colors.textPrimary : colors.textDisabled,
          ),
          onPressed: _toggleSources,
        ),
        if (widget.history.isNotEmpty)
          IconButton(
            key: const ValueKey('ssh-compose-history'),
            tooltip: strings.termUxComposeHistory,
            isSelected: _history,
            icon: Icon(HIcons.history_rounded, color: colors.textSecondary),
            onPressed: () => setState(() {
              _history = !_history;
              _sources = false;
            }),
          ),
        const Spacer(),
        if (dictation != null)
          HermesTactileAction(
            key: const ValueKey('ssh-compose-mic'),
            icon: recording ? HIcons.stop_rounded : HIcons.mic_rounded,
            semanticLabel: recording
                ? strings.termUxDictateStop
                : strings.termUxDictate,
            visual: recording
                ? HermesTactileActionVisual.filled
                : HermesTactileActionVisual.quiet,
            foregroundColor: recording ? colors.onAccent : colors.textSecondary,
            onPressed: dictation.transcribing ? null : _dictate,
            size: 42,
          ),
        const SizedBox(width: HermesSpace.x1),
        Semantics(
          onLongPressHint: ready ? strings.termUxComposeInsertHint : null,
          child: HermesTactileAction(
            key: const ValueKey('ssh-compose-send'),
            icon: HIcons.arrow_upward_rounded,
            iconSize: 19,
            semanticLabel: strings.termUxComposeSend,
            enabled: ready,
            onPressed: ready ? () => _send(enter: true) : null,
            onLongPress: ready ? () => _send(enter: false) : null,
            size: 42,
          ),
        ),
      ],
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    required this.index,
    required this.attachment,
    required this.colors,
    required this.onRemove,
    required this.onRetry,
    super.key,
  });

  final int index;
  final SshComposeAttachment attachment;
  final HermesThemeColors colors;
  final VoidCallback onRemove;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return ListenableBuilder(
      listenable: attachment,
      builder: (context, _) {
        final state = attachment.state;
        final status = switch (state) {
          SshUploadState.uploading => strings.termUxUploading,
          SshUploadState.done => strings.termUxUploaded,
          SshUploadState.failed ||
          SshUploadState.cancelled => strings.termUxUploadFailed,
        };
        final Widget lead = switch (state) {
          SshUploadState.uploading => SizedBox.square(
            dimension: HermesIcon.md,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: attachment.fraction,
            ),
          ),
          SshUploadState.done => Icon(
            attachment.pick.image
                ? HIcons.photo_library_outlined
                : HIcons.attach_file_rounded,
            size: HermesIcon.md,
            color: colors.textSecondary,
          ),
          _ => Icon(
            HIcons.error_outline,
            size: HermesIcon.md,
            color: colors.error,
          ),
        };
        return Semantics(
          container: true,
          label: '${attachment.name}, $status',
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: colors.surfaceVariant,
              shape: const StadiumBorder(),
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.only(start: HermesSpace.x3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeSemantics(child: lead),
                  const SizedBox(width: HermesSpace.x2),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: ExcludeSemantics(
                      child: Text(
                        attachment.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HermesType.support.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                  if (state == SshUploadState.failed ||
                      state == SshUploadState.cancelled)
                    IconButton(
                      key: ValueKey('ssh-compose-attachment-retry-$index'),
                      tooltip: strings.commonRetry,
                      icon: const Icon(HIcons.refresh, size: HermesIcon.md),
                      onPressed: onRetry,
                    ),
                  IconButton(
                    key: ValueKey('ssh-compose-attachment-remove-$index'),
                    tooltip: state == SshUploadState.uploading
                        ? strings.commonCancel
                        : strings.termUxRemoveAttachment,
                    icon: const Icon(HIcons.close_rounded, size: HermesIcon.md),
                    onPressed: onRemove,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
