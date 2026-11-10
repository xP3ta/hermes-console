import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/media_viewer/media_viewer.dart';

/// Opens one image of the chat (a Markdown image, already on screen) in
/// the media viewer, over the chat.
Future<void> showChatImage(
  BuildContext context, {
  required String imageUrl,
  Uint8List? imageBytes,
  Object? heroTag,
}) {
  final image = _chatImage(imageUrl, imageBytes, heroTag ?? imageUrl);
  return showMediaViewer(context, [image]);
}

/// [showChatImage] as a page of its own.
class ImageViewerScreen extends StatelessWidget {
  final String imageUrl;
  final Uint8List? imageBytes;
  final Object? heroTag;

  const ImageViewerScreen({
    super.key,
    required this.imageUrl,
    this.imageBytes,
    this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    return MediaViewerScreen(
      items: [_chatImage(imageUrl, imageBytes, heroTag ?? imageUrl)],
    );
  }
}

/// Its bytes when the chat holds them, its address otherwise; named after
/// the last segment of the address.
MediaViewerItem _chatImage(String url, Uint8List? bytes, Object heroTag) {
  final uri = Uri.tryParse(url);
  final web = uri != null && (uri.scheme == 'https' || uri.scheme == 'http');
  final segments = uri?.pathSegments.where((s) => s.isNotEmpty);
  final name = segments == null || segments.isEmpty ? uri?.host : segments.last;
  return MediaViewerItem(
    kind: MediaViewerKind.image,
    name: name == null || name.isEmpty ? null : name,
    bytes: bytes,
    imageUrl: bytes == null ? url : null,
    location: web ? url : null,
    locationIsUrl: web,
    heroTag: heroTag,
  );
}
