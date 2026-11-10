import 'package:flutter/foundation.dart';

import 'chat_content_extractor.dart';
import 'connection_manager.dart';
import 'global_artifacts.dart';

/// The images of what the recent conversations produced, in the order they
/// came (newest first). Links and files stay out: the gallery is pictures.
List<GlobalArtifact> galleryImages(Iterable<GlobalArtifact> artifacts) => [
  for (final artifact in artifacts)
    if (artifact.item.kind == ChatContentKind.image) artifact,
];

/// When an image belongs to the timeline: its message's time, else its
/// conversation's (the same fallback the artifacts list sorts by).
DateTime galleryTimeOf(GlobalArtifact artifact) {
  final when = artifact.item.timestamp;
  if (when != null) return when.toLocal();
  final seconds = artifact.session.updatedAt ?? artifact.session.startedAt;
  return DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
}

/// The calendar day (local, no time) of [time].
DateTime galleryDayOf(DateTime time) =>
    DateTime(time.year, time.month, time.day);

/// The images of one calendar day, in the order given.
@immutable
class GalleryDay {
  const GalleryDay(this.day, this.items);

  final DateTime day;
  final List<GlobalArtifact> items;
}

/// Groups [images] (newest first) by calendar day, keeping their order:
/// consecutive images of one day share a group.
List<GalleryDay> groupGalleryByDay(Iterable<GlobalArtifact> images) {
  final groups = <GalleryDay>[];
  DateTime? current;
  var items = <GlobalArtifact>[];
  for (final image in images) {
    final day = galleryDayOf(galleryTimeOf(image));
    if (current != null && day != current) {
      groups.add(GalleryDay(current, items));
      items = <GlobalArtifact>[];
    }
    current = day;
    items.add(image);
  }
  if (current != null) groups.add(GalleryDay(current, items));
  return groups;
}

/// A conversation that has images and how many.
@immutable
class GalleryConversation {
  const GalleryConversation(this.session, this.count);

  final Session session;
  final int count;
}

/// The conversations of [images], in the order they first appear (the most
/// recent first), with their image counts.
List<GalleryConversation> galleryConversations(
  Iterable<GlobalArtifact> images,
) {
  final counts = <String, int>{};
  final sessions = <String, Session>{};
  for (final image in images) {
    final id = image.session.id;
    sessions.putIfAbsent(id, () => image.session);
    counts[id] = (counts[id] ?? 0) + 1;
  }
  return [
    for (final entry in sessions.entries)
      GalleryConversation(entry.value, counts[entry.key]!),
  ];
}

/// [images] of the conversation [sessionId]; all of them when it is null.
List<GlobalArtifact> galleryInConversation(
  List<GlobalArtifact> images,
  String? sessionId,
) => sessionId == null
    ? images
    : [
        for (final image in images)
          if (image.session.id == sessionId) image,
      ];
