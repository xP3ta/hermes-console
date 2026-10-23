import '../../l10n/app_localizations.dart';

/// Only the image marker synthesized by the Desktop projection is app copy.
/// A user/assistant-authored phrase with the same spelling stays untouched.
String projectedContentCopy(
  Strings strings,
  Map<String, dynamic> message,
  String content,
) {
  const marker = '*(imagen adjunta)*';
  if (message['_structuredImageCount'] is! int ||
      (message['_structuredImageCount'] as int) <= 0 ||
      !content.endsWith(marker)) {
    return content;
  }
  return '${content.substring(0, content.length - marker.length)}'
      '*(${strings.sa1215KindImage})*';
}
