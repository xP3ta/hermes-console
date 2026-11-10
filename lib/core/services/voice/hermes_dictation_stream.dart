// Live dictation STT, copied from Hermes Desktop `lib/voice-stream.ts`.
//
// Microphone PCM streams to the host's `/api/audio/transcribe-stream`
// WebSocket while the user speaks; partial text arrives as it is recognized
// and the transcript lands right at end of recording (server contract:
// `hermes_cli/web_routers/audio.py:516-590`). Provider keys never leave the
// host, and the host resamples, so the client sends its own capture rate.
//
//   client → {"sample_rate": N}, then binary s16le mono PCM frames,
//            {"eos": true}
//   server → {"type":"partial","text"}, {"type":"final","transcript"},
//            {"type":"error","message"}
//
// Any failure (older backend, provider without a live wire, socket drop)
// resolves [HermesDictationStreamClient.open] to null or rejects
// [HermesDictationStreamSession.stop]; the caller then transcribes its
// recorded take exactly as before.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../connection_manager.dart';

/// Opens the live session of one dictation take, or resolves to null when
/// the host cannot serve one.
typedef HermesLiveDictationOpener =
    Future<HermesDictationStreamSession?> Function({
      required int sampleRate,
      required void Function(String text) onPartial,
    });

abstract interface class HermesDictationSocket {
  Future<void> get ready;
  Stream<dynamic> get frames;

  /// A JSON text frame or a binary PCM chunk.
  void send(Object frame);
  Future<void> close();
}

class _WebSocketHermesDictationSocket implements HermesDictationSocket {
  _WebSocketHermesDictationSocket(this.channel);

  final WebSocketChannel channel;

  @override
  Future<void> get ready => channel.ready;

  @override
  Stream<dynamic> get frames => channel.stream;

  @override
  void send(Object frame) => channel.sink.add(frame);

  @override
  Future<void> close() => channel.sink.close(1000, 'client_done');
}

typedef HermesDictationSocketConnector =
    HermesDictationSocket Function(Uri uri, Map<String, dynamic> headers);

/// The live session failed or the host has no live STT. The message is the
/// host's (Desktop shows it nowhere either): it is never logged or shown.
final class HermesDictationStreamException implements Exception {
  const HermesDictationStreamException(this.message);

  final String message;

  @override
  String toString() => 'HermesDictationStreamException';
}

/// Authenticated client of `/api/audio/transcribe-stream` for one
/// Dashboard and profile, with the same auth as `speak-stream`.
class HermesDictationStreamClient {
  HermesDictationStreamClient({
    required this.dashboardBaseUrl,
    required this.auth,
    this.profile,
    HermesDictationSocketConnector? connector,
    this.openTimeout = defaultOpenTimeout,
    this.finalTimeout = defaultFinalTimeout,
  }) : _connector =
           connector ??
           ((uri, headers) => _WebSocketHermesDictationSocket(
             IOWebSocketChannel.connect(
               uri,
               headers: headers,
               pingInterval: const Duration(seconds: 20),
               connectTimeout: openTimeout,
             ),
           ));

  /// Desktop `voice-stream.ts:26` (`OPEN_TIMEOUT_MS`).
  static const Duration defaultOpenTimeout = Duration(seconds: 5);

  /// The host gives the provider 20 s to finalize
  /// (`tools/transcription_streaming.py:46`) and then answers `error`.
  /// Desktop waits without a bound; here a silent host falls back after
  /// that window plus a margin.
  static const Duration defaultFinalTimeout = Duration(seconds: 25);

  final String dashboardBaseUrl;
  final Future<DashboardWebSocketAuth> Function() auth;
  final String? profile;
  final Duration openTimeout;
  final Duration finalTimeout;
  final HermesDictationSocketConnector _connector;

  Uri buildUri(DashboardWebSocketAuth credentials) {
    final base = Uri.parse(dashboardBaseUrl);
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final normalizedProfile = profile?.trim() ?? '';
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '$basePath/api/audio/transcribe-stream',
      queryParameters: {
        ...base.queryParameters,
        credentials.queryName: credentials.credential,
        if (normalizedProfile.isNotEmpty && normalizedProfile != 'default')
          'profile': normalizedProfile,
      },
    );
  }

  /// Desktop `openDictationStream` (`voice-stream.ts:28-137`): null when the
  /// socket does not open in [openTimeout] or the host refuses at once.
  Future<HermesDictationStreamSession?> open({
    required int sampleRate,
    void Function(String text)? onPartial,
  }) async {
    final HermesDictationSocket socket;
    try {
      final credentials = await auth().timeout(openTimeout);
      socket = _connector(buildUri(credentials), credentials.headers);
    } catch (_) {
      return null;
    }
    final session = HermesDictationStreamSession._(
      socket,
      onPartial,
      finalTimeout,
    ).._listen();
    try {
      await socket.ready.timeout(openTimeout);
    } catch (_) {
      session.cancel();
      return null;
    }
    if (session.settled) {
      session.cancel();
      return null;
    }
    try {
      socket.send(jsonEncode({'sample_rate': sampleRate}));
    } catch (_) {
      session.cancel();
      return null;
    }
    return session;
  }
}

/// One take on the live socket. Single use.
class HermesDictationStreamSession {
  HermesDictationStreamSession._(
    this._socket,
    this._onPartial,
    this._finalTimeout,
  );

  final HermesDictationSocket _socket;
  final void Function(String text)? _onPartial;
  final Duration _finalTimeout;

  StreamSubscription<dynamic>? _subscription;
  bool _settled = false;
  bool _closed = false;
  Object? _failure;
  Completer<String>? _pending;

  /// The take already ended: a final, an error, a drop or a cancel.
  bool get settled => _settled;

  void _listen() {
    _subscription = _socket.frames.listen(
      _onFrame,
      onError: (Object _) => _settle(
        const HermesDictationStreamException(
          'live transcription connection failed',
        ),
      ),
      onDone: () => _settle(
        const HermesDictationStreamException(
          'live transcription connection closed',
        ),
      ),
      cancelOnError: true,
    );
  }

  void _onFrame(dynamic frame) {
    if (frame is! String) return;
    Object? message;
    try {
      message = jsonDecode(frame);
    } catch (_) {
      return;
    }
    if (message is! Map) return;
    switch (message['type']) {
      case 'partial':
        final text = message['text'];
        if (text is String && !_settled) _onPartial?.call(text);
      case 'final':
        final transcript = message['transcript'];
        _settle(transcript is String ? transcript.trim() : '');
        _close();
      case 'error':
        final detail = message['message'];
        _settle(
          HermesDictationStreamException(
            detail is String && detail.isNotEmpty
                ? detail
                : 'live transcription failed',
          ),
        );
        _close();
    }
  }

  void _settle(Object outcome) {
    if (_settled) return;
    _settled = true;
    final pending = _pending;
    _pending = null;
    if (outcome is String) {
      pending?.complete(outcome);
    } else {
      _failure = outcome;
      pending?.completeError(outcome);
    }
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
    unawaited(_socket.close().catchError((Object _) {}));
  }

  /// Feed one PCM chunk (s16le mono at the announced rate). No-op once
  /// settled.
  void pushAudio(Uint8List chunk) {
    if (_settled || chunk.isEmpty) return;
    try {
      _socket.send(chunk);
    } catch (_) {
      _settle(
        const HermesDictationStreamException(
          'live transcription connection failed',
        ),
      );
      _close();
    }
  }

  /// End the recording; resolves with the final transcript (`''` = heard
  /// nothing) and rejects on any failure.
  Future<String> stop() {
    if (_settled) {
      return Future<String>.error(
        _failure ??
            const HermesDictationStreamException(
              'live transcription already ended',
            ),
      );
    }
    final pending = Completer<String>();
    _pending = pending;
    try {
      _socket.send(jsonEncode({'eos': true}));
    } catch (_) {
      _settle(
        const HermesDictationStreamException(
          'live transcription connection failed',
        ),
      );
      _close();
    }
    return pending.future.timeout(
      _finalTimeout,
      onTimeout: () {
        cancel();
        throw TimeoutException('live transcription final', _finalTimeout);
      },
    );
  }

  /// Abort without a transcript (cancel, dispose, discarded take).
  void cancel() {
    _settled = true;
    _pending = null;
    _close();
  }
}

/// Whether `/api/config` turns live dictation on for the profile:
/// `stt.streaming` read like the host's `is_truthy_value`
/// (`tools/transcription_streaming.py:450-451`, `utils.py:23-32`). Only that
/// key is read; the rest of the payload is ignored.
bool hermesLiveDictationEnabledInConfig(Object? config) {
  if (config is! Map) return false;
  final stt = config['stt'];
  if (stt is! Map) return false;
  final value = stt['streaming'];
  if (value == null) return false;
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    return const {'1', 'true', 'yes', 'on'}.contains(
      value.trim().toLowerCase(),
    );
  }
  // Python's bool() of a non-empty list or map is true.
  if (value is Iterable) return value.isNotEmpty;
  if (value is Map) return value.isNotEmpty;
  return true;
}

/// The live-dictation verdict per (Dashboard, profile, source), held for
/// [maxAge] like Desktop's voice-config cache (`voice-client-direct.ts`,
/// 60 s), so a dictation tap does not pay a config read before the
/// microphone opens every time. A failed read is never stored.
class HermesLiveDictationGateCache {
  HermesLiveDictationGateCache._();

  static const Duration maxAge = Duration(seconds: 60);
  static final Map<String, (bool, DateTime)> _verdicts = {};
  static DateTime Function() _now = DateTime.now;

  static bool? read(String key) {
    final entry = _verdicts[key];
    if (entry == null) return null;
    if (_now().difference(entry.$2) < maxAge) return entry.$1;
    _verdicts.remove(key);
    return null;
  }

  static void store(String key, bool offered) =>
      _verdicts[key] = (offered, _now());

  static void clear() => _verdicts.clear();

  @visibleForTesting
  static void resetForTesting({DateTime Function()? now}) {
    _verdicts.clear();
    _now = now ?? DateTime.now;
  }
}
