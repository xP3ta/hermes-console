// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
//
// H8: en release, `debugPrint` acaba en logcat, que cualquier app con
// READ_LOGS (o un informe de errores) puede leer. Muchas líneas citan el
// texto de una excepción, y ese texto lleva URLs con credenciales, IPs de la
// red del usuario o direcciones de correo. En release cada línea pasa por
// [redactLogLine] antes de imprimirse; en debug no se toca nada.
import 'package:flutter/foundation.dart';

final RegExp _url = RegExp(r'\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s<>"]+');
final RegExp _mail = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');
final RegExp _ipv4 = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b');
final RegExp _ipv6 = RegExp(r'\b(?:[0-9a-fA-F]{1,4}:){3,7}[0-9a-fA-F]{1,4}\b');
// Tokens y claves: una racha larga de caracteres de token con al menos un
// dígito y una letra (no tapa palabras ni nombres de excepción).
final RegExp _token = RegExp(r'[A-Za-z0-9_\-]{20,}');
final RegExp _hasDigit = RegExp(r'\d');
final RegExp _hasLetter = RegExp(r'[A-Za-z]');

/// Longitud máxima de una línea de log en release.
const int kReleaseLogMaxChars = 320;

/// Quita de [line] URLs, correos, IPs y tokens largos y la acorta.
String redactLogLine(String line) {
  var out = line
      .replaceAll(_url, '<url>')
      .replaceAll(_mail, '<email>')
      .replaceAll(_ipv6, '<ip>')
      .replaceAll(_ipv4, '<ip>')
      .replaceAllMapped(_token, (m) {
        final t = m[0]!;
        return _hasDigit.hasMatch(t) && _hasLetter.hasMatch(t) ? '<token>' : t;
      });
  if (out.length > kReleaseLogMaxChars) {
    out = '${out.substring(0, kReleaseLogMaxChars - 1)}…';
  }
  return out;
}

DebugPrintCallback? _original;

/// En release, envuelve `debugPrint` para que toda línea pase por
/// [redactLogLine]. Idempotente; con `release: false` restaura el original.
void installReleaseLogRedaction({bool release = kReleaseMode}) {
  final original = _original ??= debugPrint;
  if (!release) {
    debugPrint = original;
    return;
  }
  debugPrint = (String? message, {int? wrapWidth}) {
    original(
      message == null ? null : redactLogLine(message),
      wrapWidth: wrapWidth,
    );
  };
}
