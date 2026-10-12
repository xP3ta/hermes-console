// Adaptador de plataforma para apps externas.
//
// La UI y los providers pasan por esta interfaz; la implementación real usa
// el MethodChannel "hermes/android_apps" para detectar/abrir paquetes y consultar
// el dispositivo, y `url_launcher` para los enlaces de F-Droid.
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Contrato de operaciones sobre apps externas (mockeable en tests).
abstract class AppBridge {
  /// ¿Está instalado el paquete? (PackageManager).
  Future<bool> isInstalled(String package);

  /// Abre la app por su paquete. Devuelve false si no se pudo.
  Future<bool> launch(String package);

  /// Abre la ficha de F-Droid del paquete: intenta `market://` y cae a la web.
  Future<bool> installFromFDroid(String package);

  /// Características del dispositivo (RAM, ABIs) para filtrar modelos.
  Future<DeviceInfo> deviceInfo();
}

/// Características del dispositivo relevantes para la inferencia local.
class DeviceInfo {
  final int totalRamBytes;
  final int availRamBytes;
  final List<String> abis;
  final int freeDiskBytes;

  const DeviceInfo({
    required this.totalRamBytes,
    required this.availRamBytes,
    required this.abis,
    this.freeDiskBytes = 0,
  });

  double get totalRamGb => totalRamBytes / (1024 * 1024 * 1024);
  double get freeDiskGb => freeDiskBytes / (1024 * 1024 * 1024);
  bool get isArm64 => abis.contains('arm64-v8a');

  /// 64 bits (arm64 o x86_64): requisito mínimo para el agente local.
  bool get is64bit =>
      abis.any((a) => a == 'arm64-v8a' || a == 'x86_64' || a == 'arm64');
  bool get known => totalRamBytes > 0;

  static const DeviceInfo unknown = DeviceInfo(
    totalRamBytes: 0,
    availRamBytes: 0,
    abis: [],
  );
}

/// Implementación real sobre el MethodChannel nativo + url_launcher.
class AndroidApps implements AppBridge {
  static const MethodChannel _channel = MethodChannel('hermes/android_apps');

  const AndroidApps();

  @override
  Future<bool> isInstalled(String package) async {
    try {
      final ok = await _channel.invokeMethod<bool>('isInstalled', {
        'package': package,
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> launch(String package) async {
    try {
      final ok = await _channel.invokeMethod<bool>('launch', {
        'package': package,
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> installFromFDroid(String package) async {
    final market = Uri.parse('market://details?id=$package');
    if (await canLaunchUrl(market)) {
      if (await launchUrl(market, mode: LaunchMode.externalApplication)) {
        return true;
      }
    }
    return launchUrl(
      fdroidWebUrl(package),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Future<DeviceInfo> deviceInfo() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('deviceInfo');
      if (m == null) return DeviceInfo.unknown;
      return DeviceInfo(
        totalRamBytes: (m['totalRamBytes'] as num?)?.toInt() ?? 0,
        availRamBytes: (m['availRamBytes'] as num?)?.toInt() ?? 0,
        abis:
            (m['abis'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        freeDiskBytes: (m['freeDiskBytes'] as num?)?.toInt() ?? 0,
      );
    } on PlatformException {
      return DeviceInfo.unknown;
    } on MissingPluginException {
      return DeviceInfo.unknown;
    }
  }

  /// URL web de la ficha de F-Droid (fallback cuando no hay cliente F-Droid).
  static Uri fdroidWebUrl(String package) =>
      Uri.parse('https://f-droid.org/en/packages/$package/');
}
