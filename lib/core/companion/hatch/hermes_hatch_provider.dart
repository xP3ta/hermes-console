
import 'hatch_provider.dart';
import 'package:flutter/foundation.dart';

/// Comprueba (probe) si la conexión Hermes actual expone generación de imágenes
/// (`/v1/images/generations`, OpenAI-compatible). Inyectable: en producción lee
/// la `CapabilityMatrix`/sondea el endpoint; en tests es un fake. Nunca lanza.
typedef ImageGenProbe = Future<bool> Function();

/// Llama al endpoint de generación **reutilizando la conexión/credencial ya
/// configurada** (sin OAuth/keys nuevas) y devuelve los bytes de la imagen.
/// Inyectable: en producción hace el POST; en tests es un fake. Puede lanzar.
typedef ImageGenCall = Future<Uint8List> Function(String prompt);

/// Proveedor de "Hatch" que usa la **conexión Hermes existente**, gated por un
/// probe y con consentimiento de privacidad (el prompt sale al gateway del
/// usuario). No introduce credenciales nuevas ni toca la configuración del
/// gateway: ambas operaciones se inyectan ([probe] y [call]).
class HermesHatchProvider implements HatchProvider {
  final ImageGenProbe probe;
  final ImageGenCall call;

  /// Nombre de fichero del sprite resultante (según el formato que devuelva el
  /// gateway; por defecto PNG).
  final String fileName;

  const HermesHatchProvider({
    required this.probe,
    required this.call,
    this.fileName = 'spritesheet.png',
  });

  @override
  Future<HatchAvailability> availability() async {
    bool ok;
    try {
      ok = await probe();
    } catch (e) {
      debugPrint('[hatch] excepción silenciada (fallback: ok = false): $e');
      ok = false;
    }
    if (!ok) {
      return const HatchAvailability.unavailable(
          'El gateway conectado no expone generación de imágenes.');
    }
    // Disponible, pero generar enviará el prompt al gateway → consentimiento.
    return const HatchAvailability(
      available: true,
      requiresPrivacyConsent: true,
    );
  }

  @override
  Future<HatchResult> generate(HatchRequest request) async {
    final Uint8List bytes;
    try {
      bytes = await call(request.prompt);
    } catch (e) {
      throw HatchException('gateway generation failed: $e');
    }
    if (bytes.isEmpty) {
      throw HatchException('the gateway returned an empty image');
    }
    return HatchResult(
      imageBytes: bytes,
      fileName: fileName,
      author: 'Hatch (gateway)',
      note: 'hermes',
    );
  }
}
