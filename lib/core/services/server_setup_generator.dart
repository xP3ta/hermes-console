// Generador de artefactos de "setup todo en uno" para el onboarding (paso 1).
//
// Produce textos (NO ejecuta nada en el móvil) para dos fronteras distintas:
//   1) agentPrompt → explicación general de solo lectura, sin comandos ni datos
//      de emparejado.
//   2) curlCommand/powershellCommand → instalación manual en una terminal de
//      confianza controlada por el propietario.
//
// Solo el camino manual usa los instaladores publicados en hermes-setup. Los
// comandos cortos sustituyen a los blobs autocontenidos de ~60KB (spec 028
// U-23/U-26) y mantienen una única fuente de verdad del setup.
//
// Lógica PURA y testeable sin dispositivo: textos constantes, sin assets ni
// red. Reutiliza el formato de enlace de PairingLink SIN modificarlo.
// Ver docs/INSTALLATION.md.
import 'pairing_link.dart';

/// Sistema operativo del equipo que ejecuta Hermes Agent (no del movil).
enum ServerHostPlatform { linux, macos, windows }

class ServerSetupGenerator {
  const ServerSetupGenerator();

  /// Puerto por defecto del gateway API de Hermes.
  static const int gatewayPort = 8642;

  /// Puerto por defecto del Dashboard.
  static const int dashboardPort = 9119;

  /// Puerto por defecto del Mobile Bridge (lo levanta el script de instalación).
  static const int bridgePort = 9131;

  /// URL pública del script de setup todo-en-uno. El repo hermes-setup aloja la
  /// copia publicada de `scripts/hermes-mobile-setup.sh` (y del bridge que ese
  /// script descarga): al cambiar cualquiera de los dos aquí, actualizar el
  /// repo público en el mismo release.
  static const String setupScriptUrl =
      'https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.sh';

  /// Instalador nativo para Windows PowerShell. No se enruta por Git Bash:
  /// Hermes nativo usa rutas, procesos y persistencia propios de Windows.
  static const String windowsSetupScriptUrl =
      'https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.ps1';

  /// Comando corto de copia-pega para una terminal de confianza del servidor:
  /// descarga el script público (auditable en GitHub) y lo ejecuta.
  static const String curlCommand = 'curl -fsSL $setupScriptUrl | sh';

  static const String powershellCommand = 'irm $windowsSetupScriptUrl | iex';

  /// Variante invocable desde el shell de herramientas de Hermes en Windows,
  /// que normalmente es Git Bash incluso cuando el host es Windows nativo.
  static const String powershellShellCommand =
      'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '
      '"irm \'$windowsSetupScriptUrl\' | iex"';

  /// URL pública del script de emparejado bajo demanda (U-34): reimprime el
  /// QR/enlace en un servidor ya instalado, sin reinstalar nada. Misma regla
  /// de publicación que [setupScriptUrl]: vive en el repo hermes-setup.
  static const String pairScriptUrl =
      'https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-pair.sh';

  static const String windowsPairScriptUrl =
      'https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-pair.ps1';

  /// One-liner corto que la app ofrece cuando el usuario ya tiene servidor y
  /// solo necesita volver a ver el QR (p. ej. desde el escáner).
  static const String pairCommand = 'curl -fsSL $pairScriptUrl | sh';

  static const String powershellPairCommand = 'irm $windowsPairScriptUrl | iex';

  static String setupCommandFor(ServerHostPlatform platform) =>
      platform == ServerHostPlatform.windows ? powershellCommand : curlCommand;

  static String pairCommandFor(ServerHostPlatform platform) =>
      platform == ServerHostPlatform.windows
      ? powershellPairCommand
      : pairCommand;

  /// Construye el enlace canónico de emparejado reutilizando [PairingLink]
  /// (misma "moneda" que la app ya consume). Útil para validar el formato y
  /// como referencia del que emiten los artefactos.
  static String buildPairingLink({
    required String host,
    required int port,
    required String token,
    bool useHttps = false,
    String? dashboardUrl,
    String? bridgeUrl,
    String? bridgeToken,
    String? label,
  }) {
    return PairingLink(
      host: host,
      port: port,
      token: token,
      label: label,
      useHttps: useHttps,
      dashboardUrl: dashboardUrl,
      bridgeUrl: bridgeUrl,
      bridgeToken: bridgeToken,
    ).build();
  }

  /// Guía compatible con consumidores que todavía ofrecen ayuda mediante un
  /// agente. Es deliberadamente de solo lectura: el setup y su salida sensible
  /// permanecen entre el propietario, su terminal de confianza y la app.
  static String agentPromptFor(ServerHostPlatform platform) {
    final platformName = switch (platform) {
      ServerHostPlatform.windows => 'Windows',
      ServerHostPlatform.macos => 'macOS',
      ServerHostPlatform.linux => 'Linux',
    };
    return 'Read-only setup guidance for Hermes Console on $platformName. '
        'Explain at a high level how the device owner can prepare their Hermes '
        'server for a mobile connection using the command displayed inside '
        'Hermes Console in a trusted terminal.\n\n'
        'Do not run commands or use tools. Do not install, repair, configure, '
        'restart or expose services, and do not treat this request as '
        'authorization to make changes. Do not access server data. Do not '
        'retrieve links, QR codes, tokens, keys, passwords, environment '
        'variables, configuration files, logs or other server data. Never ask '
        'the owner to paste any of '
        'those items into chat. Do not construct or return pairing data.\n\n'
        'Provide read-only explanations only. Tell the owner to review and run '
        'all setup commands themselves in a trusted terminal, and to keep all '
        'pairing output between that terminal and Hermes Console.';
  }

  /// Compatibilidad con consumidores anteriores; Linux sigue siendo el valor
  /// por defecto solo para llamadas de codigo que aun no ofrecen selector.
  static final String agentPrompt = agentPromptFor(ServerHostPlatform.linux);
}
