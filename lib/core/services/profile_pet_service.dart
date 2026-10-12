import 'package:flutter/foundation.dart';

import '../models/profile_pet.dart';
import 'tui_gateway_client.dart';

/// Capa pequeña sobre [HermesDesktopPetGateway] con la política de la app para
/// las mascotas nativas por perfil (`pet.*`):
///
/// - **Fail-closed** ante gateways antiguos sin `pet.*` (`-32601`, mismo
///   patrón que Bot Mode): se reporta "no disponible" (`null`/`false`) y el
///   llamador conserva la autoridad local.
/// - **Fail-soft** ante errores de red/servidor: la mascota es cosmética y
///   nunca debe romper una superficie; el sandbox local sigue siendo el
///   espejo/caché offline para render.
class ProfilePetService {
  ProfilePetService(this._gateway, {this.allowWrites = true});

  final HermesDesktopPetGateway _gateway;
  final bool allowWrites;

  /// `pet.thumb` se trata como capacidad ausente tras el primer fallo: en
  /// gateways antiguos (< 0.20.3) la llamada rompe por cada tile de la
  /// galería (28 avisos seguidos en el log). La miniatura es cosmética, así
  /// que se cachea el fallo por conexión (este servicio se crea por conexión
  /// o por pantalla) y no se reintenta ni se vuelve a registrar.
  bool _thumbUnavailable = false;

  /// Señal de re-lectura `pet.changed`. El broadcast del gateway es global y
  /// su payload refleja el perfil de arranque (no necesariamente el perfil
  /// activo en la app), así que solo debe usarse como disparador de un
  /// `pet.info` fresco, nunca como fuente de verdad del slug.
  Stream<void> get petChanged =>
      _gateway.events.where((event) => event.type == 'pet.changed').map((_) {});

  /// Mascota activa del [profile] según el servidor, o `null` si el gateway
  /// no soporta `pet.*` o la lectura falló (→ manda la selección local).
  Future<ProfilePetInfo?> activePet({
    String profile = '',
    String? knownRevision,
  }) async {
    try {
      return await _gateway.profilePetInfo(
        profile: profile,
        knownRevision: knownRevision,
      );
    } catch (error) {
      _logRead('pet.info', error);
      return null;
    }
  }

  /// Galería adoptable del perfil. `null` solo cuando el gateway no tiene
  /// `pet.*` (`-32601`); una lectura que falla se propaga, para que quien la
  /// pinta pueda decirlo y ofrecer el reintento.
  Future<ProfilePetGallery?> gallery({
    String profile = '',
    bool localOnly = false,
  }) async {
    try {
      return await _gateway.profilePetGallery(
        profile: profile,
        localOnly: localOnly,
      );
    } catch (error) {
      _logRead('pet.gallery', error);
      if (error is TuiGatewayRpcError && error.code == -32601) return null;
      rethrow;
    }
  }

  /// Miniatura (data URI) de una mascota, o `null` si no está disponible.
  Future<String?> thumbnail({
    String profile = '',
    required String slug,
    String url = '',
  }) async {
    if (_thumbUnavailable) return null;
    try {
      return await _gateway.profilePetThumb(
        profile: profile,
        slug: slug,
        url: url,
      );
    } catch (error) {
      _thumbUnavailable = true;
      _logRead('pet.thumb', error);
      return null;
    }
  }

  /// Selecciona la mascota en el servidor (autoridad del perfil). Devuelve
  /// `true` si el gateway la aplicó; `false` si no soporta `pet.*` o falló
  /// (el llamador conserva el espejo local en cualquier caso).
  Future<bool> selectPet({String profile = '', required String slug}) async {
    if (!allowWrites) return false;
    try {
      await _gateway.profilePetSelect(profile: profile, slug: slug);
      return true;
    } catch (error) {
      _logWrite('pet.select', error);
      return false;
    }
  }

  /// Apaga la mascota del perfil en el servidor ("sin mascota" → la app
  /// muestra la cara del perfil). Misma política que [selectPet].
  Future<bool> disablePet({String profile = ''}) async {
    if (!allowWrites) return false;
    try {
      return await _gateway.profilePetDisable(profile: profile);
    } catch (error) {
      _logWrite('pet.disable', error);
      return false;
    }
  }

  void _logRead(String method, Object error) {
    // -32601 (gateway antiguo sin pet.*) es el camino fail-closed esperado y
    // no se registra; el resto sí, sin datos sensibles.
    if (error is TuiGatewayRpcError && error.code == -32601) return;
    debugPrint(
      '[profile-pet] $method falló (se conserva lo local): ${_kind(error)}',
    );
  }

  void _logWrite(String method, Object error) {
    if (error is TuiGatewayRpcError && error.code == -32601) return;
    debugPrint(
      '[profile-pet] $method no aplicado en el servidor: ${_kind(error)}',
    );
  }

  String _kind(Object error) => error is TuiGatewayRpcError
      ? 'código ${error.code}'
      : error.runtimeType.toString();
}
