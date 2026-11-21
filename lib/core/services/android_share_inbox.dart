import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/attachment_draft.dart';
import 'sealed_local_files.dart';

/// Contenido recibido mediante ACTION_SEND/ACTION_SEND_MULTIPLE de Android.
///
/// El texto se conserva cifrado hasta que pueda convertirse en un borrador de
/// chat. Las imágenes ya vienen copiadas por MainActivity al caché privado de
/// la aplicación, por lo que Dart nunca necesita permisos de almacenamiento.
class AndroidSharedContent {
  const AndroidSharedContent({
    required this.id,
    required this.text,
    required this.attachments,
    this.rejectedAttachments = 0,
  });

  static const int maxTextCharacters = 65536;

  final String id;
  final String text;
  final List<AttachmentDraft> attachments;
  final int rejectedAttachments;

  bool get isEmpty => text.trim().isEmpty && attachments.isEmpty;

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'attachments': attachments.map((item) => item.toJson()).toList(),
    'rejected_attachments': rejectedAttachments,
  };

  static AndroidSharedContent? fromMap(Map<Object?, Object?> raw) {
    final id = (raw['id'] ?? '').toString().trim();
    if (id.isEmpty || id.length > 160) return null;
    final rawText = (raw['text'] ?? '').toString();
    final text = rawText.length <= maxTextCharacters
        ? rawText
        : rawText.substring(0, maxTextCharacters);
    final attachments = <AttachmentDraft>[];
    final rawAttachments = raw['attachments'];
    if (rawAttachments is List) {
      for (final item in rawAttachments.take(10)) {
        if (item is! Map) continue;
        final normalized = <String, dynamic>{
          for (final entry in item.entries) entry.key.toString(): entry.value,
        };
        final draft = AttachmentDraft.fromJson(normalized);
        if (draft.localPath.isEmpty) continue;
        final file = File(draft.localPath);
        if (!file.existsSync()) continue;
        attachments.add(draft);
      }
    }
    final rejected =
        int.tryParse((raw['rejected_attachments'] ?? '0').toString()) ?? 0;
    final content = AndroidSharedContent(
      id: id,
      text: text,
      attachments: attachments,
      rejectedAttachments: rejected.clamp(0, 100).toInt(),
    );
    return content.isEmpty && content.rejectedAttachments == 0 ? null : content;
  }

  static AndroidSharedContent? fromJson(Map<String, dynamic> raw) =>
      fromMap(raw);
}

/// Bandeja pequeña y cifrada entre Android y el árbol Flutter: un archivo
/// sellado ([SealedLocalFiles]; la entrada del Keystore de una versión anterior
/// se mueve a él al leerla).
///
/// Se guarda antes de avisar a la UI. Si la app aún no tiene instancia, está
/// bloqueada o Android mata el proceso, el share sigue disponible al volver.
class AndroidShareInbox {
  factory AndroidShareInbox({
    MethodChannel channel = const MethodChannel('hermes/share'),
    FlutterSecureStorage secureStorage = const FlutterSecureStorage(),
  }) => AndroidShareInbox._(
    channel,
    SealedLocalFiles(SealedLocalFiles.shareInbox, secureStorage: secureStorage),
  );

  AndroidShareInbox._(this._channel, this._files);

  static const String _storageKey = 'android_share_inbox_v1';
  static const _name = SealedName(_storageKey);
  static const int _maxPending = 8;

  final MethodChannel _channel;
  final SealedLocalFiles _files;
  final StreamController<AndroidSharedContent> _events =
      StreamController<AndroidSharedContent>.broadcast();

  Stream<AndroidSharedContent> get events => _events.stream;

  Future<AndroidSharedContent?> initialize() async {
    _channel.setMethodCallHandler(_onNativeCall);
    try {
      final raw = await _channel.invokeMethod<Object?>('takePendingShare');
      final content = _decodeNative(raw);
      if (content != null) await _enqueue(content);
    } on MissingPluginException {
      // Host tests / plataformas no Android: la bandeja cifrada sigue usable.
    } on PlatformException {
      // Compartir es una integración auxiliar; nunca bloquea el arranque.
    }
    return peek();
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method != 'shareReceived') return;
    final content = _decodeNative(call.arguments);
    if (content == null) return;
    await _enqueue(content);
    if (!_events.isClosed) _events.add(content);
  }

  AndroidSharedContent? _decodeNative(Object? raw) {
    if (raw is! Map) return null;
    return AndroidSharedContent.fromMap(raw);
  }

  Future<List<AndroidSharedContent>> _readAll() async {
    final String? raw;
    try {
      raw = await _files.read(_name, movable: SealedLocalFiles.isJson);
    } on SealedFileUnreadable {
      // Like a value that does not parse.
      return [];
    }
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final item in decoded)
          if (item is Map)
            ...[
              AndroidSharedContent.fromJson(Map<String, dynamic>.from(item)),
            ].whereType<AndroidSharedContent>(),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeAll(List<AndroidSharedContent> items) async {
    if (items.isEmpty) {
      await _files.delete(_name);
      return;
    }
    await _files.write(
      _name,
      jsonEncode(items.map((item) => item.toJson()).toList()),
    );
  }

  Future<void> _enqueue(AndroidSharedContent content) async {
    final items = await _readAll();
    if (items.any((item) => item.id == content.id)) return;
    items.add(content);
    if (items.length > _maxPending) {
      items.removeRange(0, items.length - _maxPending);
    }
    await _writeAll(items);
  }

  Future<AndroidSharedContent?> peek() async {
    final items = await _readAll();
    return items.isEmpty ? null : items.first;
  }

  /// Confirma que el contenido ya se convirtió en un borrador recuperable.
  Future<void> acknowledge(String id) async {
    final items = await _readAll();
    items.removeWhere((item) => item.id == id);
    await _writeAll(items);
  }

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _events.close();
  }
}
