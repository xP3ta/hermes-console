import '../../l10n/app_localizations.dart';
import 'memory_context.dart';

/// Only the image marker synthesized by the Desktop projection is app copy.
/// A user/assistant-authored phrase with the same spelling stays untouched.
/// User/assistant text is shown through Hermes' memory-context lens
/// ([memoryContextDisplayText]); the stored row is not changed.
String projectedContentCopy(
  Strings strings,
  Map<String, dynamic> message,
  String text,
) {
  final content = memoryContextDisplayText(message['role'], text);
  const marker = '*(imagen adjunta)*';
  if (message['_structuredImageCount'] is! int ||
      (message['_structuredImageCount'] as int) <= 0 ||
      !content.endsWith(marker)) {
    return content;
  }
  return '${content.substring(0, content.length - marker.length)}'
      '*(${strings.sa1215KindImage})*';
}
