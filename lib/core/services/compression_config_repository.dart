import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/compression_config.dart';
import 'connection_manager.dart';

/// Repositorio autenticado y fijado a un unico perfil para los ajustes nativos
/// de autocompresion de Hermes.
///
/// La instancia creada con el constructor normal toma prestado [dashboard] y
/// no lo cierra. [CompressionConfigRepository.forConnection] crea y posee su
/// propio DashboardClient, y por tanto debe cerrarse al terminar.
final class CompressionConfigRepository {
  final DashboardClient _dashboard;
  final bool _ownsDashboard;
  final bool _writable;
  final String? _profile;

  bool _closed = false;
  bool _ownedDashboardClosed = false;
  int _activeOperations = 0;

  factory CompressionConfigRepository(
    DashboardClient dashboard, {
    String? profile,
    bool writable = true,
  }) => CompressionConfigRepository._(
    dashboard,
    _normalizeProfile(profile),
    false,
    writable,
  );

  CompressionConfigRepository._(
    this._dashboard,
    this._profile,
    this._ownsDashboard,
    this._writable,
  );

  /// Construye el cliente desde una instancia guardada y respeta su auth,
  /// Dashboard URL, perfil activo y modo solo lectura.
  factory CompressionConfigRepository.forConnection(
    SavedConnection connection, {
    String? profile,
    bool writable = true,
    DashboardClientFactory? dashboardFactory,
  }) {
    // Validar el scope antes de construir un cliente o cargar secretos.
    final normalizedProfile = _normalizeProfile(profile);
    final factory =
        dashboardFactory ??
        (SavedConnection value) => DashboardClient.lazy(value);
    return CompressionConfigRepository._(
      factory(connection),
      normalizedProfile,
      true,
      writable && !connection.readOnly,
    );
  }

  String? get profile => _profile;

  bool get isClosed => _closed;

  bool get isWritable => _writable;

  /// Lee config y schema en el mismo scope. Un Dashboard antiguo que no
  /// publica la ruta o los campos base produce un snapshot `unsupported`, no
  /// un falso estado desactivado.
  Future<CompressionConfigSnapshot> load() async {
    _beginOperation();
    try {
      final config = await _dashboard.getServerConfig(profile: _profile);
      final schema = await _dashboard.getServerConfigSchema(profile: _profile);
      return CompressionConfigSnapshot.fromDashboard(
        profile: _profile,
        config: config,
        schema: schema,
        fetchedAt: DateTime.now().toUtc(),
      );
    } catch (error) {
      final failure = _sanitizeFailure(error);
      if (failure.code == CompressionConfigFailureCode.unsupported) {
        return CompressionConfigSnapshot.unsupported(
          profile: _profile,
          fetchedAt: DateTime.now().toUtc(),
        );
      }
      throw failure;
    } finally {
      _endOperation();
    }
  }

  /// Valida y guarda una copia editada de un snapshot cargado por este mismo
  /// repositorio.
  ///
  /// Como Hermes Desktop, el body contiene el registro redactado completo que
  /// se leyó. Dentro de `compression` solo se sustituyen los cuatro campos
  /// publicados; todos los hermanos se conservan.
  Future<CompressionConfigSnapshot> save(
    CompressionConfigSnapshot base,
    CompressionConfig configuration,
  ) async {
    _beginOperation();
    try {
      if (!_writable) {
        throw const CompressionConfigException(
          CompressionConfigFailureCode.readOnly,
        );
      }
      if (base.profile != _profile) {
        throw const CompressionConfigException(
          CompressionConfigFailureCode.invalidProfile,
        );
      }
      final limits = base.limits;
      final recordHandle = base.recordHandle;
      if (!base.isSupported || limits == null || recordHandle == null) {
        throw const CompressionConfigException(
          CompressionConfigFailureCode.unsupported,
        );
      }
      limits.requireValid(configuration);
      base.optionalFields.requireCompatible(configuration);
      final updatedRecord = recordHandle.buildRecordWith(configuration);
      final response = await _dashboard.putServerConfigRecord(
        updatedRecord,
        profile: _profile,
      );
      if (response['ok'] == false) {
        throw const CompressionConfigException(
          CompressionConfigFailureCode.rejected,
        );
      }
      return CompressionConfigSnapshot.supported(
        profile: _profile,
        configuration: configuration,
        limits: limits,
        optionalFields: base.optionalFields,
        recordHandle: CompressionConfigRecordHandle.fromRedactedRecord(
          updatedRecord,
        ),
        fetchedAt: DateTime.now().toUtc(),
      );
    } catch (error) {
      throw _sanitizeFailure(error);
    } finally {
      _endOperation();
    }
  }

  /// Idempotente. Solo cierra el DashboardClient cuando fue creado por
  /// [forConnection]; los clientes inyectados siguen siendo propiedad del
  /// llamante.
  /// Cierra el repositorio. La ruta normal deja terminar una operacion ya
  /// iniciada para no truncar un guardado durante el desmontaje de la vista.
  ///
  /// [abortActiveOperations] se reserva para los fences de identidad o de
  /// acceso a config: cuando cambian credenciales, perfil o configRead/
  /// configWrite, ningun trabajo autenticado del scope anterior puede
  /// conservar su cliente.
  void close({bool abortActiveOperations = false}) {
    if (_closed) return;
    _closed = true;
    if (abortActiveOperations) {
      _closeOwnedDashboard();
    } else {
      _closeOwnedDashboardIfReady();
    }
  }

  void _beginOperation() {
    _requireOpen();
    _activeOperations += 1;
  }

  void _endOperation() {
    _activeOperations -= 1;
    _closeOwnedDashboardIfReady();
  }

  void _closeOwnedDashboardIfReady() {
    if (_closed && _activeOperations == 0) _closeOwnedDashboard();
  }

  void _closeOwnedDashboard() {
    if (!_ownsDashboard || _ownedDashboardClosed) return;
    _ownedDashboardClosed = true;
    _dashboard.close();
  }

  void _requireOpen() {
    if (_closed) {
      throw const CompressionConfigException(
        CompressionConfigFailureCode.closed,
      );
    }
  }
}

String? _normalizeProfile(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty || value == 'default') return null;
  if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(value)) {
    throw const CompressionConfigException(
      CompressionConfigFailureCode.invalidProfile,
    );
  }
  return value;
}

CompressionConfigException _sanitizeFailure(Object error) {
  if (error is CompressionConfigException) return error;
  if (error is DashboardAuthException) {
    return CompressionConfigException(
      CompressionConfigFailureCode.authentication,
      statusCode: error.statusCode,
    );
  }
  if (error is DashboardHttpException) {
    final code = switch (error.statusCode) {
      401 => CompressionConfigFailureCode.authentication,
      403 => CompressionConfigFailureCode.permissionDenied,
      404 || 405 => CompressionConfigFailureCode.unsupported,
      400 || 409 || 422 => CompressionConfigFailureCode.rejected,
      _ => CompressionConfigFailureCode.remote,
    };
    return CompressionConfigException(code, statusCode: error.statusCode);
  }
  if (error is TimeoutException ||
      error is SocketException ||
      error is http.ClientException) {
    return const CompressionConfigException(
      CompressionConfigFailureCode.transport,
    );
  }
  if (error is FormatException || error is TypeError) {
    return const CompressionConfigException(
      CompressionConfigFailureCode.invalidResponse,
    );
  }
  return const CompressionConfigException(CompressionConfigFailureCode.remote);
}
