// Gestión de actualización del Mobile Bridge: detecta la versión instalada en
// una instancia, decide si está desactualizada respecto a la release instalable
// validada (remota o empaquetada), y la actualiza reutilizando el instalador.
//
// El ajuste de auto-actualización es OPT-IN (por defecto off): si está activo, la
// app actualiza el bridge al detectar una versión nueva; si no, avisa para que el
// usuario lo haga con un toque. La detección usa `/bridge/health` (sin auth).
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_runtime/agent_runtime.dart';
import 'active_chat_service.dart';
import 'bridge_client.dart';
import 'bridge_endpoint_resolver.dart';
import 'bridge_release_channel.dart';
import 'bridge_version.dart';
import 'connection_manager.dart';
import 'hermes_update_monitor.dart';
import 'remote_bridge_installer.dart';
import 'secure_storage.dart';

/// Resultado de comprobar la versión del bridge de una instancia.
class BridgeUpdateCheck {
  /// Versión instalada (null si el bridge no es alcanzable).
  final String? installed;

  /// ¿El bridge respondió a `/bridge/health`?
  final bool reachable;

  /// Release validada disponible para instalar (null si no se comprobó).
  final String? available;

  /// ¿La release disponible procede del canal remoto?
  final bool remote;

  /// Metadata inmutable usada para descargar exactamente lo comprobado.
  final BridgeReleaseTarget? target;

  /// ¿La versión instalada es ANTERIOR a la release disponible?
  final bool outdated;

  const BridgeUpdateCheck({
    this.installed,
    this.available,
    this.remote = false,
    this.target,
    required this.reachable,
    required this.outdated,
  });

  static const none = BridgeUpdateCheck(
    installed: null,
    available: null,
    reachable: false,
    outdated: false,
  );
}

class BridgeUpdateResult {
  final bool ok;
  final String detail;
  final BridgeUpdateFailure? failure;
  final bool manualAction;

  const BridgeUpdateResult.success(this.detail)
    : ok = true,
      failure = null,
      manualAction = false;

  const BridgeUpdateResult.failure(
    this.failure,
    this.detail, {
    this.manualAction = false,
  }) : ok = false;
}

enum BridgeUpdateFailure {
  readOnly,
  releaseUnavailable,
  downloadFailed,
  repairUnsupported,
  repairFailed,
  verificationFailed,
}

class BridgeMaintenanceResult {
  final bool checked;
  final bool updated;
  final String detail;

  const BridgeMaintenanceResult({
    required this.checked,
    required this.updated,
    required this.detail,
  });

  static const skipped = BridgeMaintenanceResult(
    checked: false,
    updated: false,
    detail: '',
  );
}

typedef BridgeUpdateChecker =
    Future<BridgeUpdateCheck> Function(SavedConnection connection);
typedef BridgeUpdater =
    Future<({bool ok, String detail})> Function(SavedConnection connection);
typedef BridgeReleaseInstaller =
    Future<({bool ok, String detail})> Function(
      BridgeRelease release,
      void Function(String message)? onProgress,
    );
typedef BridgeSelfUpdater =
    Future<({bool supported, bool ok, String detail})> Function(
      SavedConnection connection,
      BridgeRelease release,
      void Function(String message)? onProgress,
    );
typedef BridgeVersionProbe = Future<String?> Function(String baseUrl);

class BridgeUpdateService {
  static const _autoKey = 'bridge_auto_update';
  static const _componentsAutoKey = 'components_auto_update';
  static const Duration maintenanceInterval = Duration(hours: 6);
  static final Map<String, Future<BridgeMaintenanceResult>>
  _maintenanceFlights = {};
  static final Map<String, DateTime> _lastMaintenanceChecks = {};

  /// Versión del bridge que la app trae empaquetada (la que instalaría).
  static String get packagedVersion => AgentRuntimeConsts.expectedBridgeVersion;

  /// Política única para Hermes + Mobile Bridge. Migra las dos preferencias
  /// históricas usando OR: si el usuario había autorizado cualquiera de las
  /// dos, no se pierde su elección al unificarlas.
  static Future<bool> automaticUpdatesEnabled() async {
    final p = await SharedPreferences.getInstance();
    if (p.containsKey(_componentsAutoKey)) {
      return p.getBool(_componentsAutoKey) ?? false;
    }
    final migrated =
        (p.getBool(_autoKey) ?? false) || (p.getBool(_hermesAutoKey) ?? false);
    if (p.containsKey(_autoKey) || p.containsKey(_hermesAutoKey)) {
      await p.setBool(_componentsAutoKey, migrated);
    }
    return migrated;
  }

  static Future<void> setAutomaticUpdates(bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_componentsAutoKey, value);
    // Se conservan durante una versión para que builds anteriores que compartan
    // datos no muestren un estado distinto al volver atrás.
    await p.setBool(_autoKey, value);
    await p.setBool(_hermesAutoKey, value);
  }

  static Future<bool> autoUpdateEnabled() => automaticUpdatesEnabled();

  static Future<void> setAutoUpdate(bool value) => setAutomaticUpdates(value);

  // ── Auto-actualización de HERMES (el agente) ──────────────────────────────
  // Análogo al del bridge pero para el propio Hermes. Opt-in, por defecto off.
  static const _hermesAutoKey = 'hermes_auto_update';

  static Future<bool> hermesAutoUpdateEnabled() async {
    return automaticUpdatesEnabled();
  }

  static Future<void> setHermesAutoUpdate(bool value) async {
    await setAutomaticUpdates(value);
  }

  /// Mantenimiento automático independiente de la pantalla que esté abierta.
  /// Solo actualiza un bridge que YA responde y está por debajo de la versión
  /// empaquetada. La exclusión mutua evita reinstalaciones duplicadas si Home,
  /// Chat y Ajustes comprueban a la vez.
  static Future<BridgeMaintenanceResult> maintainIfEnabled(
    SavedConnection conn, {
    bool force = false,
    DateTime Function()? now,
    Future<bool> Function()? enabled,
    BridgeUpdateChecker? checker,
    BridgeUpdater? updater,
  }) async {
    if (conn.readOnly || conn.onDeviceLoopback) {
      return BridgeMaintenanceResult.skipped;
    }
    // Con una actualización de Hermes en curso no se reinicia ni sustituye el
    // bridge: `hermes update` está cambiando el entorno del que depende y
    // reiniciando servicios. Se comprobará en la siguiente pasada.
    if (HermesUpdateGuard.isActive(conn.id)) {
      return BridgeMaintenanceResult.skipped;
    }
    final isEnabled = await (enabled ?? automaticUpdatesEnabled)();
    if (!isEnabled) return BridgeMaintenanceResult.skipped;

    final currentTime = (now ?? DateTime.now)();
    final last = _lastMaintenanceChecks[conn.id];
    if (!force &&
        last != null &&
        currentTime.difference(last) < maintenanceInterval) {
      return BridgeMaintenanceResult.skipped;
    }
    final existing = _maintenanceFlights[conn.id];
    if (existing != null) return existing;

    final future = () async {
      final check = await (checker ?? _automaticCheck)(conn);
      _lastMaintenanceChecks[conn.id] = currentTime;
      if (!check.reachable) {
        // Ausente/inaccesible nunca equivale a permiso para instalarlo.
        return const BridgeMaintenanceResult(
          checked: true,
          updated: false,
          detail: 'Mobile Bridge no disponible; no se instaló automáticamente.',
        );
      }
      if (!check.outdated) {
        return BridgeMaintenanceResult(
          checked: true,
          updated: false,
          detail: 'Mobile Bridge ${check.installed ?? ''} al día.',
        );
      }
      if (updater != null) {
        final result = await updater(conn);
        return BridgeMaintenanceResult(
          checked: true,
          updated: result.ok,
          detail: result.detail,
        );
      }
      final result = await update(conn, target: check.target, automatic: true);
      return BridgeMaintenanceResult(
        checked: true,
        updated: result.ok,
        detail: result.detail,
      );
    }();
    _maintenanceFlights[conn.id] = future;
    try {
      return await future;
    } finally {
      if (identical(_maintenanceFlights[conn.id], future)) {
        _maintenanceFlights.remove(conn.id);
      }
    }
  }

  static Future<BridgeUpdateCheck> _automaticCheck(SavedConnection conn) {
    return check(conn, allowRemote: true);
  }

  @visibleForTesting
  static void debugResetMaintenanceState() {
    _maintenanceFlights.clear();
    _lastMaintenanceChecks.clear();
  }

  /// ¿`installed` es una versión anterior a `packaged`? Pura y testeable.
  static bool isOutdated(String? installed, String packaged) {
    if (installed == null || installed.isEmpty) return false;
    return BridgeVersion.compare(installed, packaged) < 0;
  }

  /// Respeta el override por instancia del editor y degrada a la URL derivada
  /// si el Keystore no está disponible. Nunca expone URL ni secretos en logs.
  static Future<String> _effectiveBridgeUrl(SavedConnection conn) async {
    try {
      final stored = await SecureStorage().readBridge(conn.id, 'url');
      if (stored != null && stored.trim().isNotEmpty) return stored.trim();
    } catch (error) {
      debugPrint(
        '[bridge-update] bridge config unavailable (${error.runtimeType})',
      );
    }
    return BridgeEndpointResolver.resolve(conn).url;
  }

  /// Comprueba la versión del bridge de [conn] vía `/bridge/health` (sin auth).
  /// Cualquier fallo → no alcanzable (no desactualizado), sin lanzar.
  static Future<BridgeUpdateCheck> check(
    SavedConnection conn, {
    bool allowRemote = false,
    BridgeReleaseTargetResolver? targetResolver,
    BridgeVersionProbe? versionProbe,
  }) async {
    final base = await _effectiveBridgeUrl(conn);
    if (base.isEmpty) return BridgeUpdateCheck.none;
    var available = packagedVersion;
    var remote = false;
    BridgeReleaseTarget? target;
    if (allowRemote) {
      try {
        target =
            await (targetResolver ??
                BridgeReleaseChannel.resolveLatestTarget)();
        available = target.version;
        remote = target.remote;
      } catch (e) {
        debugPrint('[bridge-update] canal remoto no disponible: $e');
      }
    }
    try {
      final v = await (versionProbe ?? BridgeClient.probeVersion)(base);
      if (v == null || v.isEmpty) return BridgeUpdateCheck.none;
      return BridgeUpdateCheck(
        installed: v,
        available: available,
        remote: remote,
        target: target,
        reachable: true,
        outdated: isOutdated(v, available),
      );
    } catch (e) {
      debugPrint(
        '[bridge-update] excepción silenciada (se continúa sin propagar): $e',
      );
      return BridgeUpdateCheck.none;
    }
  }

  /// Actualiza (reinstala) el bridge de [conn] a la mejor release validada.
  /// Invalida la caché de capacidad solo después de confirmar que la versión
  /// objetivo está realmente sirviéndose tras el reinicio.
  static Future<BridgeUpdateResult> update(
    SavedConnection conn, {
    void Function(String message)? onProgress,
    BridgeReleaseTarget? target,
    BridgeReleaseTargetResolver? targetResolver,
    BridgeReleaseDownloader? releaseDownloader,
    BridgeReleaseInstaller? installer,
    BridgeSelfUpdater? selfUpdater,
    BridgeReleaseInstaller? legacyInstaller,
    BridgeVersionProbe? versionProbe,
    bool automatic = false,
    bool forceRemoteRepair = false,
    Duration verificationTimeout = const Duration(seconds: 90),
    Duration verificationRetryDelay = const Duration(seconds: 2),
  }) async {
    if (conn.readOnly) {
      return const BridgeUpdateResult.failure(
        BridgeUpdateFailure.readOnly,
        'La instancia está en modo solo lectura.',
        manualAction: true,
      );
    }
    final bridgeUrl = await _effectiveBridgeUrl(conn);
    late final BridgeReleaseTarget resolvedTarget;
    try {
      resolvedTarget =
          target ??
          await (targetResolver ?? BridgeReleaseChannel.resolveLatestTarget)();
    } catch (e) {
      return BridgeUpdateResult.failure(
        BridgeUpdateFailure.releaseUnavailable,
        'No se pudo preparar una release válida del Mobile Bridge.',
        manualAction: true,
      );
    }

    final probe = versionProbe ?? BridgeClient.probeVersion;
    try {
      final installed = await probe(bridgeUrl);
      if (!forceRemoteRepair &&
          installed != null &&
          installed.isNotEmpty &&
          BridgeVersion.compare(installed, resolvedTarget.version) >= 0) {
        return BridgeUpdateResult.success(
          'Mobile Bridge $installed ya está al día.',
        );
      }
    } catch (_) {
      // La acción manual también sirve para reparar un bridge que no responde.
    }

    late final BridgeRelease release;
    try {
      release =
          await (releaseDownloader ??
              BridgeReleaseChannel.downloadLatestTarget)(resolvedTarget);
      if (release.version != resolvedTarget.version ||
          release.sha256 != resolvedTarget.sha256 ||
          release.remote != resolvedTarget.remote) {
        throw const FormatException('La release no coincide con el target.');
      }
    } catch (_) {
      return BridgeUpdateResult.failure(
        BridgeUpdateFailure.downloadFailed,
        'No se pudo descargar y validar Mobile Bridge '
        '${resolvedTarget.version}.',
        manualAction: true,
      );
    }

    late final ({bool ok, String detail}) result;
    if (installer != null) {
      result = await installer(release, onProgress);
    } else {
      final direct = forceRemoteRepair
          ? (supported: false, ok: false, detail: 'remote repair requested')
          : selfUpdater != null
          ? await selfUpdater(conn, release, onProgress)
          : await _trySelfUpdate(
              conn,
              release,
              onProgress,
              bridgeUrl: bridgeUrl,
            );
      if (direct.supported) {
        result = (ok: direct.ok, detail: direct.detail);
      } else if (automatic && !forceRemoteRepair) {
        return const BridgeUpdateResult.failure(
          BridgeUpdateFailure.repairUnsupported,
          'Este Mobile Bridge necesita una actualización manual inicial; '
          'después podrá actualizarse automáticamente.',
          manualAction: true,
        );
      } else if (legacyInstaller != null) {
        result = await legacyInstaller(release, onProgress);
      } else {
        final api = ApiClient(baseUrl: conn.gatewayUrl, apiKey: conn.apiKey);
        final remoteInstaller = RemoteBridgeInstaller(api, conn);
        try {
          final installed = await remoteInstaller.install(
            release: release,
            versionProbe: probe,
            onProgress: onProgress,
            verificationUrl: bridgeUrl,
          );
          result = (ok: installed.ok, detail: installed.detail);
        } finally {
          api.close();
        }
      }
    }
    if (!result.ok) {
      return BridgeUpdateResult.failure(
        BridgeUpdateFailure.repairFailed,
        result.detail,
        manualAction: true,
      );
    }

    final running = await _waitForBridgeVersion(
      conn,
      targetVersion: release.version,
      versionProbe: probe,
      bridgeUrl: bridgeUrl,
      onProgress: onProgress,
      timeout: verificationTimeout,
      retryDelay: verificationRetryDelay,
    );
    if (running == null) {
      return BridgeUpdateResult.failure(
        BridgeUpdateFailure.verificationFailed,
        'No se confirmó Mobile Bridge ${release.version} tras actualizar.',
        manualAction: true,
      );
    }
    ActiveChat.invalidateBridgeProfileCache(conn.id);
    return BridgeUpdateResult.success(result.detail);
  }

  static Future<({bool supported, bool ok, String detail})> _trySelfUpdate(
    SavedConnection conn,
    BridgeRelease release,
    void Function(String message)? onProgress, {
    required String bridgeUrl,
  }) async {
    if (bridgeUrl.isEmpty) {
      return (supported: false, ok: false, detail: 'Bridge no configurado.');
    }

    final secure = SecureStorage();
    var storedToken = '';
    try {
      storedToken = (await secure.readBridge(conn.id, 'token') ?? '').trim();
    } catch (error) {
      debugPrint(
        '[bridge-update] bridge token unavailable (${error.runtimeType})',
      );
    }

    // Un token configurado manualmente o guardado durante el QR tiene
    // prioridad. Esto permite actualizar aunque /bridge/provision se cierre
    // después del setup inicial.
    if (storedToken.isNotEmpty) {
      final storedAttempt = await _selfUpdateWithToken(
        bridgeUrl,
        storedToken,
        release,
        onProgress,
      );
      if (storedAttempt.authorized) {
        return (
          supported: storedAttempt.supported,
          ok: storedAttempt.ok,
          detail: storedAttempt.detail,
        );
      }
    }

    // Ausente, caducado o revocado: canjea la API key confiada del Gateway y
    // sustituye el secreto del Bridge en Keystore.
    String? provisioned;
    try {
      provisioned = await BridgeClient.provision(bridgeUrl, conn.apiKey.trim());
    } catch (_) {
      provisioned = null;
    }
    if (provisioned == null || provisioned.isEmpty) {
      return (supported: false, ok: false, detail: 'Bridge no autorizado.');
    }
    try {
      await secure.writeBridge(conn.id, 'token', provisioned);
    } catch (_) {
      return (
        supported: true,
        ok: false,
        detail: 'No se pudo guardar de forma segura el token del Bridge.',
      );
    }

    final freshAttempt = await _selfUpdateWithToken(
      bridgeUrl,
      provisioned,
      release,
      onProgress,
    );
    return (
      supported: freshAttempt.supported,
      ok: freshAttempt.ok,
      detail: freshAttempt.detail,
    );
  }

  static Future<({bool authorized, bool supported, bool ok, String detail})>
  _selfUpdateWithToken(
    String bridgeUrl,
    String token,
    BridgeRelease release,
    void Function(String message)? onProgress,
  ) async {
    final client = BridgeClient(baseUrl: bridgeUrl, token: token);
    var authorized = false;
    var supported = false;
    try {
      final capabilities = await client.detect();
      authorized = capabilities.online && capabilities.authValid;
      if (!authorized) {
        return (
          authorized: false,
          supported: false,
          ok: false,
          detail: 'Bridge no autorizado.',
        );
      }
      supported = capabilities.selfUpdate;
      if (!supported) {
        return (
          authorized: true,
          supported: false,
          ok: false,
          detail: 'El Bridge instalado todavía no admite self_update.',
        );
      }
      onProgress?.call('Enviando la release verificada al Mobile Bridge…');
      final response = await client.selfUpdate(
        source: release.source,
        version: release.version,
        sha256: release.sha256,
      );
      if (response['ok'] == true) {
        onProgress?.call('Mobile Bridge reiniciándose de forma segura…');
        return (
          authorized: true,
          supported: true,
          ok: true,
          detail: 'Mobile Bridge ${release.version} aceptado y reiniciándose.',
        );
      }
      return (
        authorized: true,
        supported: true,
        ok: false,
        detail: 'El Mobile Bridge rechazó la actualización.',
      );
    } on BridgeException catch (error) {
      if (error.kind == BridgeErrorKind.auth) {
        return (
          authorized: false,
          supported: false,
          ok: false,
          detail: 'Bridge no autorizado.',
        );
      }
      return (
        authorized: authorized,
        supported: supported,
        ok: false,
        detail: 'No se pudo aplicar self_update: $error',
      );
    } catch (e) {
      return (
        authorized: authorized,
        supported: supported,
        ok: false,
        detail: 'No se pudo aplicar self_update: $e',
      );
    } finally {
      client.close();
    }
  }

  /// Espera a que el bridge vuelva anunciando al menos [targetVersion].
  static Future<String?> _waitForBridgeVersion(
    SavedConnection conn, {
    required String targetVersion,
    required BridgeVersionProbe versionProbe,
    String? bridgeUrl,
    void Function(String message)? onProgress,
    Duration timeout = const Duration(seconds: 90),
    Duration retryDelay = const Duration(seconds: 2),
  }) async {
    final base = bridgeUrl ?? await _effectiveBridgeUrl(conn);
    if (base.isEmpty) return null;
    final deadline = DateTime.now().add(timeout);
    while (true) {
      try {
        final v = await versionProbe(base);
        if (v != null &&
            v.isNotEmpty &&
            BridgeVersion.compare(v, targetVersion) >= 0) {
          onProgress?.call('Bridge reiniciado (v$v).');
          return v;
        }
      } catch (_) {
        // aún reiniciando
      }
      if (!DateTime.now().isBefore(deadline)) return null;
      await Future<void>.delayed(retryDelay);
    }
  }
}
