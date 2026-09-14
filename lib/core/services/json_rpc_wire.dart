import 'dart:convert';
import 'dart:typed_data';

const int maxSafeJsonInteger = 9007199254740991;

final class JsonRpcWireFormatException implements FormatException {
  @override
  final String message;

  const JsonRpcWireFormatException(this.message);

  @override
  int? get offset => null;

  @override
  Object? get source => null;

  @override
  String toString() => 'JsonRpcWireFormatException: $message';
}

abstract final class SafeJsonInt {
  static int require(
    Object? value, {
    bool positive = false,
    bool nonNegative = false,
  }) {
    if (value is! int ||
        value < -maxSafeJsonInteger ||
        value > maxSafeJsonInteger) {
      throw const JsonRpcWireFormatException('invalid safe JSON integer');
    }
    if (positive && value <= 0) {
      throw const JsonRpcWireFormatException('expected positive JSON integer');
    }
    if (nonNegative && value < 0) {
      throw const JsonRpcWireFormatException(
        'expected non-negative JSON integer',
      );
    }
    return value;
  }
}

sealed class JsonRpcWireFrame {
  const JsonRpcWireFrame();
}

final class JsonRpcResponseFrame extends JsonRpcWireFrame {
  final int id;
  final bool hasResult;
  final Object? result;
  final Map<String, dynamic>? error;

  const JsonRpcResponseFrame.result(this.id, this.result)
    : hasResult = true,
      error = null;

  const JsonRpcResponseFrame.error(this.id, this.error)
    : hasResult = false,
      result = null;
}

sealed class ParsedGatewayEvent {
  final String type;
  final int? sequence;
  final Map<String, dynamic> payload;

  const ParsedGatewayEvent(this.type, this.sequence, this.payload);

  String? get sessionId;
}

final class GlobalGatewayEvent extends ParsedGatewayEvent {
  const GlobalGatewayEvent(String type, Map<String, dynamic> payload)
    : super(type, null, payload);

  @override
  String? get sessionId => null;
}

final class SessionGatewayEvent extends ParsedGatewayEvent {
  @override
  final String sessionId;

  const SessionGatewayEvent(
    super.type,
    this.sessionId,
    super.sequence,
    super.payload,
  );
}

final class JsonRpcEventFrame extends JsonRpcWireFrame {
  final ParsedGatewayEvent event;

  const JsonRpcEventFrame(this.event);
}

final class JsonRpcNotificationFrame extends JsonRpcWireFrame {
  final String method;
  final Object? params;
  final bool hasParams;

  const JsonRpcNotificationFrame(this.method, this.params, this.hasParams);
}

/// A server→client JSON-RPC request (`tui_gateway/server_requests.py`): the
/// backend asks the client a question (`approval`, `clarify`, `sudo`, …) and
/// waits for a response frame carrying the same string `id`.
final class JsonRpcServerRequestFrame extends JsonRpcWireFrame {
  final String id;
  final String method;
  final Map<String, dynamic> params;

  const JsonRpcServerRequestFrame(this.id, this.method, this.params);
}

abstract final class EventEnvelopeParser {
  static ParsedGatewayEvent parse(
    Map<String, dynamic> fields, {
    required bool replayCapable,
    String? requiredReplaySessionId,
  }) {
    final rawType = fields['type'];
    if (rawType is! String || rawType.isEmpty || rawType != rawType.trim()) {
      throw const JsonRpcWireFormatException('invalid event type');
    }

    final hasPayload = fields.containsKey('payload');
    final rawPayload = fields['payload'];
    if (hasPayload && rawPayload is! Map<String, dynamic>) {
      throw const JsonRpcWireFormatException('invalid event payload');
    }
    final payload = hasPayload
        ? Map<String, dynamic>.unmodifiable(rawPayload! as Map<String, dynamic>)
        : const <String, dynamic>{};

    final hasSession = fields.containsKey('session_id');
    final rawSession = fields['session_id'];
    if (hasSession &&
        (rawSession is! String || rawSession != rawSession.trim())) {
      throw const JsonRpcWireFormatException('invalid event session identity');
    }
    final hasSequence = fields.containsKey('seq');
    final sequence = hasSequence
        ? SafeJsonInt.require(fields['seq'], positive: true)
        : null;

    // Hermes Agent's canonical `_event_frame` always includes `session_id`;
    // global events carry the exact empty string. Treat only that exact shape
    // like an omitted identity. Whitespace, null/non-string identities, replay
    // rows and sequenced "global" frames remain malformed/fail-closed.
    final emptyGlobalSession = hasSession && rawSession == '';
    if (!hasSession || emptyGlobalSession) {
      if (hasSequence || requiredReplaySessionId != null) {
        throw const JsonRpcWireFormatException(
          'global event cannot carry sequence',
        );
      }
      return GlobalGatewayEvent(rawType, payload);
    }

    final sessionId = rawSession! as String;
    if (requiredReplaySessionId != null &&
        sessionId != requiredReplaySessionId) {
      throw const JsonRpcWireFormatException(
        'replay runtime identity mismatch',
      );
    }
    if ((replayCapable || requiredReplaySessionId != null) && !hasSequence) {
      throw const JsonRpcWireFormatException(
        'sequenced session event required',
      );
    }
    return SessionGatewayEvent(rawType, sessionId, sequence, payload);
  }
}

abstract final class JsonRpcWireDecoder {
  static JsonRpcWireFrame? decodeTransportFrame(
    Object? raw, {
    required bool replayCapable,
  }) {
    final String text;
    if (raw is String) {
      text = raw;
    } else {
      final Uint8List? bytes = switch (raw) {
        ByteData value => value.buffer.asUint8List(
          value.offsetInBytes,
          value.lengthInBytes,
        ),
        ByteBuffer value => value.asUint8List(),
        List<int> value => Uint8List.fromList(value),
        _ => null,
      };
      if (bytes == null) return null;
      try {
        text = utf8.decode(bytes, allowMalformed: false);
      } on FormatException {
        return null;
      }
    }
    final value = _DuplicateAwareJsonParser(text).parse();
    if (value is! Map<String, dynamic>) return null;
    return _parseFrame(value, replayCapable: replayCapable);
  }

  static JsonRpcWireFrame decodeText(
    String text, {
    required bool replayCapable,
  }) {
    final value = _DuplicateAwareJsonParser(text).parse();
    if (value is! Map<String, dynamic>) {
      throw const JsonRpcWireFormatException(
        'JSON-RPC frame must be an object',
      );
    }
    return _parseFrame(value, replayCapable: replayCapable);
  }

  static JsonRpcWireFrame _parseFrame(
    Map<String, dynamic> frame, {
    required bool replayCapable,
  }) {
    if (frame['jsonrpc'] != '2.0') {
      throw const JsonRpcWireFormatException('invalid JSON-RPC version');
    }
    final hasId = frame.containsKey('id');
    final hasResult = frame.containsKey('result');
    final hasError = frame.containsKey('error');
    final rawId = frame['id'];
    // Server requests carry a string id (`srq-…`) and a method that is never
    // `event`; an event envelope with an id stays a grammar violation.
    if (hasId &&
        rawId is String &&
        frame.containsKey('method') &&
        frame['method'] != 'event') {
      if (frame.keys.any(
            (key) => !const {'jsonrpc', 'id', 'method', 'params'}.contains(key),
          ) ||
          rawId.isEmpty ||
          rawId != rawId.trim()) {
        throw const JsonRpcWireFormatException('invalid server request');
      }
      final method = frame['method'];
      if (method is! String || method.isEmpty || method != method.trim()) {
        throw const JsonRpcWireFormatException('invalid server request method');
      }
      final params = frame['params'];
      if (frame.containsKey('params') && params is! Map<String, dynamic>) {
        throw const JsonRpcWireFormatException(
          'server request params must be an object',
        );
      }
      return JsonRpcServerRequestFrame(
        rawId,
        method,
        params is Map<String, dynamic>
            ? Map<String, dynamic>.unmodifiable(params)
            : const <String, dynamic>{},
      );
    }
    if (hasId || hasResult || hasError) {
      if (frame.keys.any(
            (key) => !const {'jsonrpc', 'id', 'result', 'error'}.contains(key),
          ) ||
          !hasId ||
          hasResult == hasError) {
        throw const JsonRpcWireFormatException('ambiguous JSON-RPC response');
      }
      final id = SafeJsonInt.require(frame['id']);
      if (hasError) {
        final rawError = frame['error'];
        if (rawError is! Map<String, dynamic>) {
          throw const JsonRpcWireFormatException('invalid JSON-RPC error');
        }
        SafeJsonInt.require(rawError['code']);
        if (rawError['message'] is! String) {
          throw const JsonRpcWireFormatException(
            'invalid JSON-RPC error message',
          );
        }
        return JsonRpcResponseFrame.error(
          id,
          Map<String, dynamic>.unmodifiable(rawError),
        );
      }
      return JsonRpcResponseFrame.result(id, frame['result']);
    }

    if (frame.keys.any(
      (key) => !const {'jsonrpc', 'method', 'params'}.contains(key),
    )) {
      throw const JsonRpcWireFormatException('invalid notification fields');
    }
    final method = frame['method'];
    if (method is! String || method.isEmpty || method != method.trim()) {
      throw const JsonRpcWireFormatException('invalid notification method');
    }
    final hasParams = frame.containsKey('params');
    final params = frame['params'];
    if (hasParams &&
        params is! Map<String, dynamic> &&
        params is! List<dynamic>) {
      throw const JsonRpcWireFormatException('invalid notification params');
    }
    if (method == 'event') {
      if (params is! Map<String, dynamic>) {
        throw const JsonRpcWireFormatException(
          'event params must be an object',
        );
      }
      return JsonRpcEventFrame(
        EventEnvelopeParser.parse(params, replayCapable: replayCapable),
      );
    }
    return JsonRpcNotificationFrame(method, params, hasParams);
  }
}

final class _DuplicateAwareJsonParser {
  final String source;
  int _offset = 0;

  _DuplicateAwareJsonParser(this.source);

  Object? parse() {
    _skipWhitespace();
    if (_offset == source.length) {
      throw const JsonRpcWireFormatException('empty JSON document');
    }
    final value = _value();
    _skipWhitespace();
    if (_offset != source.length) {
      throw const JsonRpcWireFormatException('trailing JSON content');
    }
    return value;
  }

  Object? _value() {
    _skipWhitespace();
    if (_offset >= source.length) _fail();
    return switch (source.codeUnitAt(_offset)) {
      0x7b => _object(),
      0x5b => _array(),
      0x22 => _string(),
      0x74 => _literal('true', true),
      0x66 => _literal('false', false),
      0x6e => _literal('null', null),
      _ => _number(),
    };
  }

  Map<String, dynamic> _object() {
    _offset++;
    final result = <String, dynamic>{};
    final keys = <String>{};
    _skipWhitespace();
    if (_consume(0x7d)) return result;
    while (true) {
      _skipWhitespace();
      if (_offset >= source.length || source.codeUnitAt(_offset) != 0x22) {
        _fail();
      }
      final key = _string();
      if (!keys.add(key)) {
        throw const JsonRpcWireFormatException('duplicate JSON object key');
      }
      _skipWhitespace();
      if (!_consume(0x3a)) _fail();
      result[key] = _value();
      _skipWhitespace();
      if (_consume(0x7d)) return result;
      if (!_consume(0x2c)) _fail();
    }
  }

  List<dynamic> _array() {
    _offset++;
    final result = <dynamic>[];
    _skipWhitespace();
    if (_consume(0x5d)) return result;
    while (true) {
      result.add(_value());
      _skipWhitespace();
      if (_consume(0x5d)) return result;
      if (!_consume(0x2c)) _fail();
    }
  }

  String _string() {
    final start = _offset++;
    var escaped = false;
    while (_offset < source.length) {
      final unit = source.codeUnitAt(_offset++);
      if (unit < 0x20) _fail();
      if (escaped) {
        escaped = false;
        continue;
      }
      if (unit == 0x5c) {
        escaped = true;
      } else if (unit == 0x22) {
        try {
          return jsonDecode(source.substring(start, _offset)) as String;
        } catch (_) {
          _fail();
        }
      }
    }
    _fail();
  }

  Object? _literal(String token, Object? value) {
    if (!source.startsWith(token, _offset)) _fail();
    _offset += token.length;
    return value;
  }

  num _number() {
    final start = _offset;
    if (_consume(0x2d) && _offset >= source.length) _fail();

    if (_consume(0x30)) {
      if (_offset < source.length && _isDigit(source.codeUnitAt(_offset))) {
        _fail();
      }
    } else {
      if (_offset >= source.length ||
          !_isNonZeroDigit(source.codeUnitAt(_offset))) {
        _fail();
      }
      _offset++;
      while (_offset < source.length && _isDigit(source.codeUnitAt(_offset))) {
        _offset++;
      }
    }

    if (_consume(0x2e)) {
      if (_offset >= source.length || !_isDigit(source.codeUnitAt(_offset))) {
        _fail();
      }
      while (_offset < source.length && _isDigit(source.codeUnitAt(_offset))) {
        _offset++;
      }
    }

    if (_offset < source.length &&
        (source.codeUnitAt(_offset) == 0x65 ||
            source.codeUnitAt(_offset) == 0x45)) {
      _offset++;
      if (_offset < source.length &&
          (source.codeUnitAt(_offset) == 0x2b ||
              source.codeUnitAt(_offset) == 0x2d)) {
        _offset++;
      }
      if (_offset >= source.length || !_isDigit(source.codeUnitAt(_offset))) {
        _fail();
      }
      while (_offset < source.length && _isDigit(source.codeUnitAt(_offset))) {
        _offset++;
      }
    }

    final token = source.substring(start, _offset);
    try {
      final value = jsonDecode(token);
      if (value is num && value.isFinite) return value;
    } catch (_) {
      _fail();
    }
    _fail();
  }

  bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

  bool _isNonZeroDigit(int unit) => unit >= 0x31 && unit <= 0x39;

  void _skipWhitespace() {
    while (_offset < source.length &&
        const {0x20, 0x09, 0x0a, 0x0d}.contains(source.codeUnitAt(_offset))) {
      _offset++;
    }
  }

  bool _consume(int unit) {
    if (_offset < source.length && source.codeUnitAt(_offset) == unit) {
      _offset++;
      return true;
    }
    return false;
  }

  Never _fail() =>
      throw const JsonRpcWireFormatException('invalid JSON document');
}
