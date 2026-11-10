// Client-direct voice: the phone calls the profile's own STT/TTS provider
// instead of relaying audio through the Hermes server.
//
// Copied from Hermes Desktop `apps/desktop/src/lib/voice-client-direct.ts`
// (identical in v0.22.0 and v0.22.4). The server stays the single source of
// truth for WHICH provider and WHICH credentials to use:
// `GET /api/audio/voice-config` (hermes_cli/web_routers/audio.py) answers with
// the same resolution its relay endpoints apply
// (tools/voice_client_config.py). Providers that can only run on the server
// host, and `voice.client_direct: false`, answer `{"mode": "relay"}` and the
// caller keeps using `/api/audio/*`.
//
// Keys live in memory only: never persisted, never logged, and dropped from
// the cache once its 60 s are over. This library imports nothing that can
// write to disk or to the log on purpose.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../utils/transport_privacy.dart';
import 'stt_user_error.dart';

/// STT wire shapes Desktop speaks (`DirectSttConfig.wire`).
enum DirectSttWire { openAiMultipart, xaiStt, elevenLabsStt }

/// TTS wire shapes Desktop speaks (`DirectTtsConfig.wire`).
enum DirectTtsWire { openAiSpeech, elevenLabsTts }

const Map<String, DirectSttWire> _sttWires = {
  'openai-multipart': DirectSttWire.openAiMultipart,
  'xai-stt': DirectSttWire.xaiStt,
  'elevenlabs-stt': DirectSttWire.elevenLabsStt,
};

const Map<String, DirectTtsWire> _ttsWires = {
  'openai-speech': DirectTtsWire.openAiSpeech,
  'elevenlabs-tts': DirectTtsWire.elevenLabsTts,
};

/// Same budget the server's own transcription client uses
/// (`stt.openai.timeout`, default 60 s).
const Duration _defaultSttTimeout = Duration(seconds: 60);

String? _nonEmptyString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// The provider URL, if the key may be sent there: TLS, or plain HTTP only
/// inside a private network, the same boundary [TransportPrivacy] draws for
/// the server's own URLs. Plain HTTP to a public host keeps that direction on
/// the relay.
String? _allowedBaseUrl(Object? value) {
  final url = _nonEmptyString(value);
  if (url == null ||
      TransportPrivacy.classify(url) == TransportPrivacyClass.publicCleartext) {
    return null;
  }
  return url;
}

/// The relay path's Whisper-silence contract, shipped by the server so a
/// direct transcript agrees with a relayed one.
@immutable
final class VoiceHallucinationFilter {
  const VoiceHallucinationFilter({
    required this.phrases,
    required this.repeatRegex,
  });

  final List<String> phrases;
  final String repeatRegex;

  static VoiceHallucinationFilter? _parse(Object? raw) {
    if (raw is! Map) return null;
    final phrases = raw['phrases'];
    final regex = raw['repeat_regex'];
    if (phrases is! List || regex is! String) return null;
    return VoiceHallucinationFilter(
      phrases: [
        for (final phrase in phrases)
          if (phrase is String) phrase,
      ],
      repeatRegex: regex,
    );
  }

  @override
  String toString() => 'VoiceHallucinationFilter(${phrases.length} phrases)';
}

/// The profile's STT provider, callable from the phone.
final class DirectSttConfig {
  const DirectSttConfig._({
    required this.wire,
    required this.provider,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.language,
    required this.timeout,
    required this.hallucinationFilter,
  });

  final DirectSttWire wire;
  final String provider;
  final String baseUrl;

  /// Held in memory for the request only; never shown by [toString].
  final String apiKey;
  final String? model;
  final String? language;
  final Duration timeout;
  final VoiceHallucinationFilter? hallucinationFilter;

  static DirectSttConfig? _parse(Map<dynamic, dynamic> raw) {
    if (raw['mode'] != 'direct') return null;
    final wire = _sttWires[raw['wire']];
    final baseUrl = _allowedBaseUrl(raw['base_url']);
    final apiKey = _nonEmptyString(raw['api_key']);
    if (wire == null || baseUrl == null || apiKey == null) return null;
    final seconds = raw['timeout_s'];
    return DirectSttConfig._(
      wire: wire,
      provider: _nonEmptyString(raw['provider']) ?? '',
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: _nonEmptyString(raw['model']),
      language: _nonEmptyString(raw['language']),
      timeout: seconds is num && seconds.isFinite && seconds > 0
          ? Duration(microseconds: (seconds * 1000000).round())
          : _defaultSttTimeout,
      hallucinationFilter: VoiceHallucinationFilter._parse(
        raw['hallucination_filter'],
      ),
    );
  }

  @override
  String toString() =>
      'DirectSttConfig(${wire.name}, $provider, model: $model, '
      'language: $language)';
}

/// The profile's TTS provider, callable from the phone.
final class DirectTtsConfig {
  const DirectTtsConfig._({
    required this.wire,
    required this.provider,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.voice,
    required this.speed,
    required this.extraBody,
  });

  final DirectTtsWire wire;
  final String provider;
  final String baseUrl;

  /// Held in memory for the request only; never shown by [toString].
  final String apiKey;
  final String? model;
  final String? voice;
  final double? speed;

  /// Optional `tts.openai` fields the server forwards verbatim.
  final Map<String, dynamic> extraBody;

  static DirectTtsConfig? _parse(Map<dynamic, dynamic> raw) {
    if (raw['mode'] != 'direct') return null;
    final wire = _ttsWires[raw['wire']];
    final baseUrl = _allowedBaseUrl(raw['base_url']);
    final apiKey = _nonEmptyString(raw['api_key']);
    if (wire == null || baseUrl == null || apiKey == null) return null;
    final speed = raw['speed'];
    final extra = raw['extra_body'];
    return DirectTtsConfig._(
      wire: wire,
      provider: _nonEmptyString(raw['provider']) ?? '',
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: _nonEmptyString(raw['model']),
      voice: _nonEmptyString(raw['voice']),
      speed: speed is num && speed.isFinite ? speed.toDouble() : null,
      extraBody: extra is Map ? Map<String, dynamic>.from(extra) : const {},
    );
  }

  @override
  String toString() =>
      'DirectTtsConfig(${wire.name}, $provider, model: $model, '
      'voice: $voice)';
}

/// One `GET /api/audio/voice-config` answer. A null direction stays on the
/// relay.
final class VoiceClientConfig {
  const VoiceClientConfig._({
    required this.stt,
    required this.sttRelayReason,
    required this.sttStreaming,
    required this.tts,
    required this.ttsRelayReason,
  });

  final DirectSttConfig? stt;
  final String? sttRelayReason;

  /// The server serves live dictation over `/api/audio/transcribe-stream`.
  final bool sttStreaming;
  final DirectTtsConfig? tts;
  final String? ttsRelayReason;

  /// Null when the answer is not a usable config (older server, error page):
  /// the caller relays, exactly like Desktop's `loadVoiceClientConfig`.
  static VoiceClientConfig? fromResponse(Object? json) {
    if (json is! Map || json['ok'] != true) return null;
    final stt = json['stt'];
    final tts = json['tts'];
    if (stt is! Map || tts is! Map) return null;
    return VoiceClientConfig._(
      stt: DirectSttConfig._parse(stt),
      sttRelayReason: stt['mode'] == 'direct'
          ? null
          : _nonEmptyString(stt['reason']),
      sttStreaming: stt['streaming'] == true,
      tts: DirectTtsConfig._parse(tts),
      ttsRelayReason: tts['mode'] == 'direct'
          ? null
          : _nonEmptyString(tts['reason']),
    );
  }

  @override
  String toString() =>
      'VoiceClientConfig(stt: ${stt ?? 'relay'}, tts: ${tts ?? 'relay'}, '
      'streaming: $sttStreaming)';
}

/// The last resolved config, keyed by (Dashboard, profile) so a switch never
/// reuses another scope's credentials. Desktop keeps one entry and re-reads
/// it after 60 s; here the entry is also dropped at 60 s, so the keys do not
/// outlive the cache window in memory.
final class VoiceClientConfigCache {
  VoiceClientConfigCache({this.ttl = defaultTtl});

  static const Duration defaultTtl = Duration(seconds: 60);

  /// The process-wide cache the voice routes share.
  static final VoiceClientConfigCache shared = VoiceClientConfigCache();

  final Duration ttl;

  String? _key;
  VoiceClientConfig? _config;
  Timer? _eviction;
  String? _inflightKey;
  Future<VoiceClientConfig?>? _inflight;
  int _generation = 0;

  static String scopeKey(String dashboardBaseUrl, String? profile) {
    final base = dashboardBaseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final name = profile?.trim() ?? '';
    return '$base::${name.isEmpty ? 'default' : name}';
  }

  @visibleForTesting
  bool get debugHoldsConfig => _config != null;

  Future<VoiceClientConfig?> load(
    String key,
    Future<Object?> Function() fetch,
  ) {
    final cached = _config;
    if (cached != null && _key == key) return Future.value(cached);
    final inflight = _inflight;
    if (inflight != null && _inflightKey == key) return inflight;

    final generation = _generation;
    final result = Completer<VoiceClientConfig?>();
    _inflight = result.future;
    _inflightKey = key;
    unawaited(() async {
      VoiceClientConfig? config;
      try {
        config = VoiceClientConfig.fromResponse(await fetch());
        if (config != null && generation == _generation) _store(key, config);
      } catch (_) {
        // Older server without the endpoint, or a transient failure: relay.
        config = null;
      } finally {
        if (identical(_inflight, result.future)) {
          _inflight = null;
          _inflightKey = null;
        }
        result.complete(config);
      }
    }());
    return result.future;
  }

  void _store(String key, VoiceClientConfig config) {
    _eviction?.cancel();
    _key = key;
    _config = config;
    _eviction = Timer(ttl, () {
      if (identical(_config, config)) _drop();
    });
  }

  void _drop() {
    _eviction?.cancel();
    _eviction = null;
    _key = null;
    _config = null;
  }

  /// Forget the held keys now (a scope ends, the route changes).
  void clear() {
    _generation += 1;
    _inflight = null;
    _inflightKey = null;
    _drop();
  }
}

/// The configured provider refused the request, or did not answer in time.
/// The message follows Desktop's wording and never carries the key.
final class VoiceDirectProviderException implements SttUserFacingError {
  const VoiceDirectProviderException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Desktop's `isSttSilenceHallucination`: empty, an exact known
/// hallucination (trailing `.!` stripped), or repetitive filler. No filter
/// (older server) lets the transcript through.
bool isSttSilenceHallucination(
  String transcript,
  VoiceHallucinationFilter? filter,
) {
  if (filter == null) return false;
  final cleaned = transcript.trim().toLowerCase();
  if (cleaned.isEmpty) return true;
  if (filter.phrases.contains(cleaned.replaceFirst(RegExp(r'[.!]+$'), ''))) {
    return true;
  }
  try {
    return RegExp(filter.repeatRegex, caseSensitive: false).hasMatch(cleaned);
  } on FormatException {
    return false;
  }
}

/// Desktop's `transcriptFromOpenAiMultipartBody`: Groq and OpenAI answer a
/// bare string; Mistral Voxtral ignores `response_format=text` and answers
/// JSON with `text`.
String transcriptFromOpenAiMultipartBody(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.startsWith('{')) {
    try {
      final parsed = jsonDecode(trimmed);
      if (parsed is Map && parsed['text'] is String) {
        return (parsed['text'] as String).trim();
      }
    } on FormatException {
      // Not JSON: the body is the transcript.
    }
  }
  return trimmed;
}

/// Calls the provider directly with a resolved config.
final class VoiceClientDirect {
  VoiceClientDirect({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;

  /// Transcribes [audio] with the profile's provider. Returns the transcript
  /// ('' = silence). A provider rejection throws
  /// [VoiceDirectProviderException]: running the same request through the
  /// relay would fail the same way, only slower (Desktop does not retry).
  Future<String> transcribe(
    DirectSttConfig stt,
    Uint8List audio, {
    required String mimeType,
  }) async {
    final base = _trimSlashes(stt.baseUrl);
    final (path, label, headers, fields) = switch (stt.wire) {
      DirectSttWire.openAiMultipart => (
        '/audio/transcriptions',
        stt.provider,
        {'Authorization': 'Bearer ${stt.apiKey}'},
        {
          'model': ?stt.model,
          'response_format': 'text',
          'language': ?stt.language,
        },
      ),
      // xAI rejects format=true without a language (HTTP 400), so
      // auto-detect drops the flag.
      DirectSttWire.xaiStt => (
        '/stt',
        'xAI',
        {'Authorization': 'Bearer ${stt.apiKey}'},
        {
          'model': ?stt.model,
          if (stt.language case final language?) ...{
            'language': language,
            'format': 'true',
          },
        },
      ),
      DirectSttWire.elevenLabsStt => (
        '/speech-to-text',
        'ElevenLabs',
        {'xi-api-key': stt.apiKey},
        {'model_id': ?stt.model, 'language_code': ?stt.language},
      ),
    };
    final request = http.MultipartRequest('POST', Uri.parse('$base$path'))
      ..headers.addAll(headers)
      ..fields.addAll(fields)
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          audio,
          filename: _sttFileName(mimeType),
        ),
      );

    final client = _clientFactory();
    final http.Response response;
    try {
      response = await () async {
        return http.Response.fromStream(await client.send(request));
      }().timeout(stt.timeout);
    } on TimeoutException {
      throw VoiceDirectProviderException(
        'Transcription timed out after ${_seconds(stt.timeout)}s '
        '(${stt.provider} did not answer)',
      );
    } finally {
      client.close();
    }

    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _rejection(
        '$label STT error',
        response.statusCode,
        body,
        stt.apiKey,
      );
    }
    final transcript = switch (stt.wire) {
      DirectSttWire.openAiMultipart => transcriptFromOpenAiMultipartBody(body),
      DirectSttWire.xaiStt ||
      DirectSttWire.elevenLabsStt => _jsonText(jsonDecode(body)),
    };
    // Silence hallucination: same contract as the relay endpoint.
    return isSttSilenceHallucination(transcript, stt.hallucinationFilter)
        ? ''
        : transcript;
  }

  /// Synthesizes one text segment to mp3 bytes. A provider rejection throws
  /// [VoiceDirectProviderException]; the caller decides the fallback.
  Future<Uint8List> synthesize(
    DirectTtsConfig tts,
    String text, {
    Duration? timeout,
  }) async {
    final base = _trimSlashes(tts.baseUrl);
    final http.Request request;
    final String label;
    switch (tts.wire) {
      case DirectTtsWire.openAiSpeech:
        label = tts.provider;
        final speed = tts.speed;
        request = http.Request('POST', Uri.parse('$base/audio/speech'))
          ..headers.addAll({
            'Authorization': 'Bearer ${tts.apiKey}',
            'Content-Type': 'application/json',
          })
          ..body = jsonEncode({
            ...tts.extraBody,
            'model': tts.model,
            'voice': tts.voice,
            'input': text,
            'response_format': 'mp3',
            if (speed != null && speed != 0 && speed != 1) 'speed': speed,
          });
      case DirectTtsWire.elevenLabsTts:
        label = 'ElevenLabs';
        final voice = Uri.encodeComponent(tts.voice ?? '');
        request =
            http.Request('POST', Uri.parse('$base/text-to-speech/$voice'))
              ..headers.addAll({
                'xi-api-key': tts.apiKey,
                'Content-Type': 'application/json',
                'Accept': 'audio/mpeg',
              })
              ..body = jsonEncode({'text': text, 'model_id': tts.model});
    }

    final client = _clientFactory();
    final http.Response response;
    try {
      final pending = () async {
        return http.Response.fromStream(await client.send(request));
      }();
      response = timeout == null
          ? await pending
          : await pending.timeout(timeout);
    } finally {
      client.close();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _rejection(
        '$label TTS error',
        response.statusCode,
        utf8.decode(response.bodyBytes, allowMalformed: true),
        tts.apiKey,
      );
    }
    return response.bodyBytes;
  }

  static String _trimSlashes(String url) =>
      url.replaceFirst(RegExp(r'/+$'), '');

  static String _sttFileName(String mimeType) {
    final parts = mimeType.split(';').first.split('/');
    final raw = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : 'webm';
    final subtype = raw.toLowerCase();
    return 'recording.${subtype == 'mpeg' ? 'mp3' : subtype}';
  }

  static String _seconds(Duration duration) {
    final millis = duration.inMilliseconds;
    return millis % 1000 == 0 ? '${millis ~/ 1000}' : '${millis / 1000}';
  }

  static String _jsonText(Object? parsed) {
    final text = parsed is Map ? parsed['text'] : null;
    return text is String ? text.trim() : '';
  }

  static VoiceDirectProviderException _rejection(
    String prefix,
    int status,
    String body,
    String apiKey,
  ) => VoiceDirectProviderException(
    _redact('$prefix (HTTP $status): ${_providerErrorText(body)}', apiKey),
    statusCode: status,
  );

  /// Desktop's `providerErrorText`: the provider's own message when it gives
  /// one, else the first 300 characters of the body.
  static String _providerErrorText(String body) {
    try {
      final parsed = jsonDecode(body);
      if (parsed is Map) {
        final error = parsed['error'];
        final detail =
            (error is Map ? error['message'] : null) ??
            parsed['detail'] ??
            error;
        if (detail is String && detail.isNotEmpty) return detail;
      }
    } on FormatException {
      // Not JSON: the raw body below.
    }
    return body.length > 300 ? body.substring(0, 300) : body;
  }

  /// A provider may echo the key back in its error; it never leaves here.
  static String _redact(String text, String apiKey) {
    var safe = apiKey.isEmpty ? text : text.replaceAll(apiKey, '[redacted]');
    safe = safe.replaceAll(
      RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]{6,}', caseSensitive: false),
      'Bearer [redacted]',
    );
    return safe.replaceAll(RegExp(r'\bsk-[A-Za-z0-9_-]{6,}'), '[redacted]');
  }
}
