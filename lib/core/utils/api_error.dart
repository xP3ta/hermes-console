import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../../l10n/app_localizations.dart';
import '../models/cron_job.dart';
import '../services/bridge_client.dart';
import '../services/connection_manager.dart';

/// Causa que una pantalla puede presentar como dependencia del Dashboard.
enum DashboardDependencyFailure { credentials, serverVersion, other }

/// Clasifica únicamente señales estructurales; nunca inspecciona copy visible.
DashboardDependencyFailure classifyDashboardDependencyFailure(
  Object error, {
  bool notFoundMeansOldServer = false,
}) {
  if (error is DashboardAuthException) {
    return switch (error.code) {
      DashboardAuthFailureCode.loginRequired ||
      DashboardAuthFailureCode.invalidCredentials =>
        DashboardDependencyFailure.credentials,
      _ => DashboardDependencyFailure.other,
    };
  }
  if (error is DashboardHttpException) {
    if (error.statusCode == 401 || error.statusCode == 403) {
      return DashboardDependencyFailure.credentials;
    }
    if (notFoundMeansOldServer && error.statusCode == 404) {
      return DashboardDependencyFailure.serverVersion;
    }
  }
  return DashboardDependencyFailure.other;
}

/// Presenta errores tipados que necesitan copy localizado y delega el resto al
/// limpiador genérico. Las decisiones de autenticación viven en códigos
/// estructurales; ningún flujo depende del texto que ve el usuario.
String localizedApiError(Strings strings, Object error) {
  if (error is CronDeleteRejectedException) {
    return strings.crnDeleteRejected;
  }
  if (error is CronJobNotFoundException) {
    return strings.crnJobNotFoundInProfile(error.profile);
  }
  if (error is CronJobOwnerUnknownException) {
    return strings.crnJobOwnerUnknown;
  }
  if (error is BridgeException) {
    final specific = switch (error.code) {
      'cron_remove_unconfirmed' => strings.bridgeErrorCronDeleteUnconfirmed,
      'attachment_too_large' => strings.bridgeErrorAttachmentTooLarge,
      'attachment_invalid_path' => strings.bridgeErrorAttachmentInvalidPath,
      'image_invalid_type' => strings.bridgeErrorImageInvalidType,
      'image_too_large' => strings.bridgeErrorImageTooLarge,
      _ => null,
    };
    if (specific != null) return specific;
    return switch (error.kind) {
      BridgeErrorKind.network => strings.bridgeErrorNetwork,
      BridgeErrorKind.timeout => strings.bridgeErrorTimeout,
      BridgeErrorKind.badRequest => strings.bridgeErrorBadRequest,
      BridgeErrorKind.auth => strings.bridgeErrorAuth,
      BridgeErrorKind.notFound => strings.bridgeErrorNotFound,
      BridgeErrorKind.server => strings.bridgeErrorServer,
      BridgeErrorKind.unknown => strings.bridgeErrorUnknown,
    };
  }
  if (error is DashboardAuthException) {
    return switch (error.code) {
      DashboardAuthFailureCode.loginRequired =>
        strings.dashboardAuthLoginRequired,
      DashboardAuthFailureCode.invalidCredentials =>
        strings.dashboardAuthInvalidCredentials,
      DashboardAuthFailureCode.rateLimited => strings.dashboardAuthRateLimited,
      DashboardAuthFailureCode.loginFailed => strings.dashboardAuthLoginFailed(
        '${error.statusCode ?? 0}',
      ),
      DashboardAuthFailureCode.sessionCookieMissing =>
        strings.dashboardAuthSessionCookieMissing,
    };
  }
  if (error is ArgumentError && error.name == 'jobId') {
    return strings.cronJobIdInvalid;
  }
  if (error is ArgumentError && error.name == 'profile') {
    return strings.cronProfileInvalid;
  }
  return humanizeApiError(error);
}

/// Convierte una excepción de API en un mensaje legible para el usuario.
///
/// Las llamadas HTTP lanzan `Exception: HTTP 400: {"detail":"…"}` (el body se
/// incluye para diagnóstico). Aquí extraemos el `detail` (o `message`/`error`)
/// del JSON y quitamos el ruido (`Exception:`, `HTTP NNN:`), para no mostrar
/// JSON crudo en un SnackBar. Si no hay JSON reconocible, se limpia lo posible.
String humanizeApiError(Object error) {
  if (error is StateError) return error.message.toString();
  if (error is FormatException) return error.message.toString();
  if (error is ArgumentError && error.message != null) {
    return error.message.toString();
  }
  var s = error.toString();

  // Quita el prefijo "Exception: " que añade Dart.
  s = s.replaceFirst(RegExp(r'^Exception:\s*'), '');
  s = s.replaceFirst(RegExp(r'^Bad state:\s*'), '');
  s = s.replaceFirst(RegExp(r'^FormatException:\s*'), '');

  // Intenta extraer el cuerpo JSON tras "HTTP NNN: ".
  final httpMatch = RegExp(
    r'HTTP\s+(\d{3}):\s*(.*)$',
    dotAll: true,
  ).firstMatch(s);
  if (httpMatch != null) {
    final body = httpMatch.group(2)!.trim();
    final detail = _extractDetail(body);
    if (detail != null && detail.isNotEmpty) return detail;
    // Sin JSON útil: devuelve el código con un texto genérico.
    final code = httpMatch.group(1);
    if (body.isEmpty || body.startsWith('{')) {
      return 'The server responded with error $code.';
    }
    return body;
  }

  final detail = _extractDetail(s);
  if (detail != null && detail.isNotEmpty) return detail;
  return s;
}

/// Extrae el campo de mensaje de un cuerpo JSON de error (`detail`, `message`
/// o `error`). Devuelve null si no se puede parsear o no hay campo conocido.
String? _extractDetail(String body) {
  if (!body.trimLeft().startsWith('{')) return null;
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      for (final key in const ['detail', 'message', 'error']) {
        final v = decoded[key];
        if (v is String && v.trim().isNotEmpty) return v.trim();
        // FastAPI a veces devuelve detail como lista de errores de validación.
        if (v is List && v.isNotEmpty) {
          final first = v.first;
          if (first is Map && first['msg'] is String) {
            return (first['msg'] as String).trim();
          }
        }
      }
    }
  } catch (e) {
    debugPrint('[api-error] excepción silenciada (se devuelve null): $e');
    return null;
  }
  return null;
}
