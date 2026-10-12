import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Images on the system clipboard, read through `MainActivity`'s
/// `hermes/clipboard` channel. Flutter's own Paste only reads text, so a
/// screenshot or chart copied in another app needs this native path.
///
/// Platforms without the channel (iOS, desktop, tests) report no image, so
/// the composer simply does not offer "Paste image". Nothing is probed or
/// read while App Lock is locked.
class ClipboardImageSource {
  ClipboardImageSource._();

  static const MethodChannel channel = MethodChannel('hermes/clipboard');

  /// App Lock state, wired once at startup. `true` blocks every clipboard
  /// call (the clip may hold private content and the app is locked).
  static ValueListenable<bool>? appLocked;

  static bool get _locked => appLocked?.value ?? false;

  /// Whether the primary clip's first item is an image. Reads only the clip
  /// description natively, never the content.
  static Future<bool> hasImage() async {
    if (_locked) return false;
    try {
      return await channel.invokeMethod<bool>('hasImage') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// The clip's image as a keyboard-style payload for the composer's shared
  /// paste helper, which applies the usual type and size limits. A clip the
  /// native side refused for size comes back without bytes, so the helper
  /// rejects it with the usual notice. `null` when locked, when the channel
  /// is missing or when the clip no longer holds an image.
  static Future<KeyboardInsertedContent?> readImage() async {
    if (_locked) return null;
    final Map<Object?, Object?>? reply;
    try {
      reply = await channel.invokeMapMethod<Object?, Object?>('readImage');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return const KeyboardInsertedContent(mimeType: '', uri: 'clipboard:');
    }
    if (reply == null) return null;
    final mimeType = reply['mimeType'] is String
        ? reply['mimeType']! as String
        : '';
    final name = reply['name'] is String ? reply['name']! as String : '';
    final bytes = reply['tooLarge'] == true || reply['bytes'] is! Uint8List
        ? null
        : reply['bytes']! as Uint8List;
    return KeyboardInsertedContent(
      mimeType: mimeType,
      uri: 'clipboard:$name',
      data: bytes,
    );
  }
}
