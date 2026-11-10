import 'dart:io';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../feedback/feedback_policy.dart';
import '../../screens/chat_content_screen.dart' show ChatContentUnreachable;
import '../../services/artifact_media.dart';
import '../../services/chat_content_extractor.dart';
import '../../services/chat_content_presentation.dart';
import '../../services/generated_media_service.dart';
import '../chat_content_thumbnail.dart' show artifactFetchReason;
import '../media_viewer/media_viewer.dart';
import 'artifact_sections.dart' show ArtifactOrigin;

/// The images and files of [items] in the order «Artefactos» shows them:
/// the image grid, then the files by type. Links stay out: they open in
/// the browser.
List<ChatContentItem> artifactViewerOrder(List<ChatContentItem> items) {
  final files = [
    for (final item in items)
      if (item.kind == ChatContentKind.file) item,
  ];
  return [
    for (final item in items)
      if (item.kind == ChatContentKind.image) item,
    for (final (_, group) in groupChatContentFiles(files)) ...group,
  ];
}

/// Opens [initial] in the media viewer, paging through [group] (the
/// images and files on screen, see [artifactViewerOrder]). Nothing is
/// fetched until its page needs it; [download] brings it into the
/// app-private media cache for the conversation it came from
/// ([fetchArtifactMedia]). [originOf] names that conversation and opens
/// it; within one chat, [conversation] is its title.
Future<void> openArtifactsInViewer(
  BuildContext context, {
  required ChatContentItem initial,
  required List<ChatContentItem> group,
  required Future<File> Function(
    ChatContentItem item,
    GeneratedMediaReference reference,
  )
  download,
  ArtifactOrigin? Function(ChatContentItem item)? originOf,
  String? conversation,
}) {
  final items = group.contains(initial) ? group : [initial];
  final pages = [
    for (final item in items)
      artifactViewerItem(
        item,
        download: (reference) => download(item, reference),
        origin: originOf?.call(item),
        conversation: conversation,
      ),
  ];
  return showMediaViewer(context, pages, initialIndex: items.indexOf(initial));
}

/// [item] as an element of the media viewer: its kind, Desktop's kind
/// tag, its path or URL, its conversation, and how to fetch it.
MediaViewerItem artifactViewerItem(
  ChatContentItem item, {
  required Future<File> Function(GeneratedMediaReference reference) download,
  ArtifactOrigin? origin,
  String? conversation,
}) {
  final from = origin?.title ?? conversation;
  final value = item.value;
  if (value.startsWith('data:')) {
    final data = Uri.tryParse(value)?.data;
    final bytes = item.kind == ChatContentKind.image
        ? data?.contentAsBytes()
        : null;
    return MediaViewerItem(
      kind: bytes != null ? MediaViewerKind.image : MediaViewerKind.document,
      name: item.label,
      mimeType: data?.mimeType ?? 'application/octet-stream',
      bytes: bytes,
      problem: bytes != null ? null : ArtifactFetchProblem.unsupported,
      conversation: from,
      onOpenChat: origin?.onOpenChat,
      timestamp: item.timestamp,
    );
  }
  final (reference, problem) = _referenceOf(value);
  final extension = chatContentExtension(item);
  final fallback = item.kind == ChatContentKind.image
      ? MediaViewerKind.image
      : MediaViewerKind.document;
  final kind = switch (reference?.kind) {
    GeneratedMediaKind.image => MediaViewerKind.image,
    GeneratedMediaKind.video => MediaViewerKind.video,
    GeneratedMediaKind.audio => MediaViewerKind.audio,
    GeneratedMediaKind.file => MediaViewerKind.document,
    null => fallback,
  };
  final https = reference?.sourceKind == GeneratedMediaSourceKind.https;
  final url = https || value.toLowerCase().startsWith('http:');
  return MediaViewerItem(
    kind: kind,
    name: item.label,
    typeLabel: extension.isEmpty ? null : extension.toUpperCase(),
    mimeType: reference?.mimeType ?? 'application/octet-stream',
    sizeBytes: reference?.sizeBytes,
    location: value,
    locationIsUrl: url,
    conversation: from,
    onOpenChat: origin?.onOpenChat,
    timestamp: item.timestamp,
    load: reference == null ? null : () => download(reference),
    problem: problem,
  );
}

(GeneratedMediaReference?, ArtifactFetchProblem?) _referenceOf(String value) {
  try {
    return (artifactReferenceOrThrow(value), null);
  } on ArtifactFetchFailure catch (failure) {
    return (null, failure.problem);
  }
}

/// The image behind a thumbnail of «Artefactos»: only images are fetched.
/// Fails with [ArtifactFetchFailure] and its reason.
Future<File> artifactImageFile(
  ChatContentItem item, {
  required Future<File> Function(GeneratedMediaReference reference) download,
}) async {
  final reference = artifactReferenceOrThrow(item.value);
  if (reference.kind != GeneratedMediaKind.image) {
    throw const ArtifactFetchFailure(ArtifactFetchProblem.unsupported);
  }
  return download(reference);
}

/// Tells why [item] did not open: Desktop-like reasons («No está en el
/// servidor», «Ruta sin carpeta»…) when known, the «no se puede abrir desde
/// el móvil» notice for what the app does not fetch at all, and a plain
/// «No se pudo abrir» otherwise.
void notifyArtifactOpenFailure(
  FeedbackSink notice,
  Strings strings,
  ChatContentItem item,
  Object error,
) {
  final problem = error is ArtifactFetchFailure ? error.problem : null;
  if (error is ChatContentUnreachable ||
      problem == ArtifactFetchProblem.unsupported) {
    notice.notify(
      FeedbackKind.error,
      strings.sa1215NotReachable,
      warning: true,
    );
    return;
  }
  if (problem != null && problem != ArtifactFetchProblem.failed) {
    notice.notify(
      FeedbackKind.error,
      strings.artOpenFailedBecause(
        item.label,
        artifactFetchReason(strings, problem),
      ),
    );
    return;
  }
  notice.notify(FeedbackKind.error, strings.sa1215OpenFailed(item.label));
}
