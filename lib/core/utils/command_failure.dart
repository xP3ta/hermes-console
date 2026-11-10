// Lo que lee el usuario cuando un comando de barra falla (orden COMANDOS,
// punto d): el motivo por el código de Hermes, traducido, y debajo el texto
// del propio servidor, saneado. Nunca un «no se pudo» a secas: Desktop
// (`use-prompt-actions/slash.ts`) enseña `error: /goal failed: <motivo>`.
import 'dart:async';
import 'dart:io';

import '../../l10n/app_localizations.dart';
import '../services/tui_gateway_client.dart'
    show TuiGatewayRpcError, TuiGatewayRpcFailureKind;

/// Longest server text shown under the reason.
const int commandFailureDetailMaxLength = 300;

final RegExp _controlChars = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]');

/// The server's [text] as it may be shown: no control characters, runs of
/// spaces and blank lines collapsed, at most
/// [commandFailureDetailMaxLength] characters.
String sanitizeCommandFailureDetail(String text) {
  final lines = text
      .replaceAll(_controlChars, '')
      .split(RegExp(r'\r?\n'))
      .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
      .where((line) => line.isNotEmpty);
  final joined = lines.join('\n');
  if (joined.length <= commandFailureDetailMaxLength) return joined;
  return '${joined.substring(0, commandFailureDetailMaxLength - 1)}…';
}

/// The reason why `/[command]` failed with [error], for the user: a line by
/// the code Hermes answered with (4001, 4004, 4007, 4018, 403, -32601), or
/// by the kind of failure (no connection, no answer in time), then Hermes'
/// own text when it has one.
String commandFailureText(Strings strings, String command, Object error) {
  final name = '/${command.replaceFirst(RegExp(r'^/+'), '')}';
  if (error is TuiGatewayRpcError) {
    final reason = switch (error.failureKind) {
      TuiGatewayRpcFailureKind.timeout => strings.cmdErrTimeout(name),
      TuiGatewayRpcFailureKind.connectionLost => strings.cmdErrOffline(name),
      null => switch (error.code) {
        4001 => strings.cmdErrNoSession(name),
        4004 => strings.cmdErrBadArgument(name),
        4007 => strings.cmdErrNoRuntime(name),
        4018 => strings.cmdErrServerRefused(name),
        403 => strings.cmdErrReadOnly(name),
        -32601 => strings.cmdErrUnsupported(name),
        _ => strings.cmdErrFailed(name),
      },
    };
    return _withDetail(reason, error.message);
  }
  if (error is TimeoutException) return strings.cmdErrTimeout(name);
  if (error is SocketException || error is HttpException) {
    return strings.cmdErrOffline(name);
  }
  // Anything else still says what it was, never a bare «failed».
  return _withDetail(strings.cmdErrFailed(name), '${error.runtimeType}');
}

/// A command Hermes answered but did not accept (`accepted: false`,
/// `status: rejected`, `type: error`): its own words when it gave any.
String commandRejectedText(Strings strings, String command, String? detail) =>
    _withDetail(
      strings.cmdErrServerRefused(
        '/${command.replaceFirst(RegExp(r'^/+'), '')}',
      ),
      detail ?? '',
    );

String _withDetail(String reason, String detail) {
  final safe = sanitizeCommandFailureDetail(detail);
  return safe.isEmpty ? reason : '$reason\n$safe';
}
