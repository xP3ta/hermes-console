import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'bridge_client.dart';
import 'bridge_release_channel.dart';
import 'bridge_version.dart';
import 'connection_manager.dart';
import 'server_setup_generator.dart';

/// Instala el Mobile Bridge en una instancia REMOTA usando la conexión que ya
/// existe (el token del gateway), sin SSH ni copia-pega: lanza una ejecución
/// (`/v1/runs`) que pide al AGENTE del servidor ejecutar un comando
/// autocontenido. En Linux con systemd el comando lleva el bridge embebido
/// (gzip+base64), crea el servicio y lo arranca con el MISMO token del gateway
/// (`BRIDGE_TOKEN=$API_SERVER_KEY`). En Windows, macOS o Unix sin systemd el
/// prompt deriva al instalador público nativo. La acción se APRUEBA UNA VEZ
/// (consentimiento explícito); al terminar se verifica sondeando el bridge.
///
/// No depende del Dashboard ni de su login. Para servidores muy restringidos
/// (agente sin shell o gestor persistente) la instalación fallará de forma
/// limpia y la UI ofrece los comandos nativos para pegar a mano.
class RemoteBridgeInstaller {
  final ApiClient _api;
  final SavedConnection _conn;

  RemoteBridgeInstaller(this._api, this._conn);

  /// Marca de éxito que el script imprime al final (la buscamos en la salida del
  /// run para confirmar sin depender del texto del modelo).
  static const okMarker = '@@HERMES_BRIDGE_OK@@';
  static const failMarker = '@@HERMES_BRIDGE_FAIL@@';

  /// Script de shell POSIX autocontenido que instala y arranca el bridge.
  /// [bridgeB64] = gzip+base64 del asset `hermes_bridge.py`. La credencial se
  /// lee exclusivamente en el servidor: nunca se incrusta en el prompt que ve
  /// el modelo.
  static String buildInstallScript(
    String bridgeB64,
    String bindHost, {
    Uri? remoteUri,
    String? expectedSha256,
    int? expectedSize,
    String? expectedVersion,
  }) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9.:[\]_-]{0,252}$').hasMatch(bindHost)) {
      throw ArgumentError.value(bindHost, 'bindHost');
    }
    final downloadsRemote = remoteUri != null;
    if (downloadsRemote &&
        (remoteUri != BridgeReleaseChannel.payloadUri ||
            expectedSha256 == null ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedSha256) ||
            expectedSize == null ||
            expectedSize <= 0 ||
            expectedSize > BridgeReleaseChannel.maxPayloadBytes ||
            expectedVersion == null ||
            !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(expectedVersion))) {
      throw ArgumentError('Invalid remote Mobile Bridge metadata.');
    }
    // El bridge se niega a escuchar en 0.0.0.0 sin el flag explícito
    // `--i-know-what-im-doing` (guard de seguridad en hermes_bridge.py, que
    // solo mira sys.argv — no hay variable de entorno equivalente). Como el
    // bind es siempre público (para que el móvil lo alcance por LAN/Tailscale),
    // el ExecStart DEBE incluir el flag o el servicio systemd crash-loopea y el
    // bridge no arranca nunca. Bug detectado en la prueba real de onboarding
    // (spec 028). Solo se añade para binds no-loopback.
    final isLoopback = bindHost == '127.0.0.1' || bindHost == 'localhost';
    final execArgs = isLoopback ? '' : ' --i-know-what-im-doing';
    final stagePayload = downloadsRemote
        ? '''
if ! curl -fsS --proto '=https' --tlsv1.2 --max-time 30 --output "\$NEW" '${remoteUri.toString()}'; then
  rm -f "\$NEW"
  echo "$failMarker"
  exit 1
fi
SIZE="\$(wc -c < "\$NEW" | tr -d '[:space:]')"
if [ "\$SIZE" != "$expectedSize" ]; then
  rm -f "\$NEW"
  echo "$failMarker"
  exit 1
fi
HASH="\$(sha256sum "\$NEW" | cut -d' ' -f1)"
if [ "\$HASH" != "$expectedSha256" ]; then
  rm -f "\$NEW"
  echo "$failMarker"
  exit 1
fi
if [ "\$(grep -Fxc 'VERSION = "$expectedVersion"' "\$NEW")" -ne 1 ]; then
  rm -f "\$NEW"
  echo "$failMarker"
  exit 1
fi
'''
        : '''
printf %s '$bridgeB64' | base64 -d | gunzip > "\$NEW"
''';
    return '''
set -e
export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
HH="\${HERMES_HOME:-\$HOME/.hermes}"
CONFIG_HOME="\${XDG_CONFIG_HOME:-\$HOME/.config}"
UNIT_DIR="\$CONFIG_HOME/systemd/user"
mkdir -p "\$HH" "\$UNIT_DIR"
VP="\$HH/hermes-agent/venv/bin/python3"
[ -x "\$VP" ] || VP="\$(command -v python3)"
KEY="\$(grep -E '^API_SERVER_KEY=' "\$HH/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')"
if [ -z "\$KEY" ]; then
  echo "API_SERVER_KEY is not available in ~/.hermes/.env"
  echo "$failMarker"
  exit 1
fi
TARGET="\$HH/hermes_bridge.py"
NEW="\$TARGET.new"
BACKUP="\$TARGET.rollback"
ENV_FILE="\$HH/bridge.env"
ENV_BACKUP="\$HH/bridge.env.rollback"
UNIT_FILE="\$UNIT_DIR/hermes-bridge.service"
UNIT_BACKUP="\$HH/hermes-bridge.service.rollback"
$stagePayload
chmod 600 "\$NEW"
if ! "\$VP" -m py_compile "\$NEW"; then
  rm -f "\$NEW"
  echo "$failMarker"
  exit 1
fi
HAD_TARGET=0
if [ -f "\$TARGET" ]; then
  HAD_TARGET=1
  cp -p "\$TARGET" "\$BACKUP"
else
  rm -f "\$BACKUP"
fi
BIND="$bindHost"
HAD_ENV=0
if [ -f "\$ENV_FILE" ]; then
  HAD_ENV=1
  cp -p "\$ENV_FILE" "\$ENV_BACKUP"
  EXISTING_BIND="\$(grep -E '^BRIDGE_HOST=' "\$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')"
  [ -z "\$EXISTING_BIND" ] || BIND="\$EXISTING_BIND"
else
  rm -f "\$ENV_BACKUP"
fi
HAD_UNIT=0
if [ -f "\$UNIT_FILE" ]; then
  HAD_UNIT=1
  cp -p "\$UNIT_FILE" "\$UNIT_BACKUP"
else
  rm -f "\$UNIT_BACKUP"
fi
restore_previous() {
  if [ "\$HAD_TARGET" = 1 ] && [ -f "\$BACKUP" ]; then
    mv "\$BACKUP" "\$TARGET"
  elif [ "\$HAD_TARGET" = 0 ]; then
    rm -f "\$TARGET"
  fi
  if [ "\$HAD_ENV" = 1 ] && [ -f "\$ENV_BACKUP" ]; then
    mv "\$ENV_BACKUP" "\$ENV_FILE"
  elif [ "\$HAD_ENV" = 0 ]; then
    rm -f "\$ENV_FILE"
  fi
  if [ "\$HAD_UNIT" = 1 ] && [ -f "\$UNIT_BACKUP" ]; then
    mv "\$UNIT_BACKUP" "\$UNIT_FILE"
  elif [ "\$HAD_UNIT" = 0 ]; then
    rm -f "\$UNIT_FILE"
  fi
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  if [ -f "\$UNIT_FILE" ]; then
    systemctl --user restart hermes-bridge >/dev/null 2>&1 || true
  else
    systemctl --user stop hermes-bridge >/dev/null 2>&1 || true
  fi
}
ROLLBACK_NEEDED=1
rollback_on_exit() {
  RC=\$?
  trap - 0 1 2 15
  if [ "\$ROLLBACK_NEEDED" = 1 ]; then restore_previous; fi
  if [ "\$RC" -ne 0 ]; then echo "$failMarker"; fi
  exit "\$RC"
}
trap rollback_on_exit 0 1 2 15
mv "\$NEW" "\$TARGET"
cat > "\$ENV_FILE" <<EOF
BRIDGE_HOST=\$BIND
BRIDGE_PORT=9131
BRIDGE_SCOPES=read,memory,soul,skills,cron,config,command
BRIDGE_READ_ONLY=false
BRIDGE_TOKEN=\$KEY
EOF
chmod 600 "\$ENV_FILE"
cat > "\$UNIT_FILE" <<EOF
[Unit]
Description=Hermes Mobile Bridge
After=network.target
[Service]
EnvironmentFile=\$ENV_FILE
ExecStart=\$VP \$TARGET$execArgs
WorkingDirectory=\$HH
Restart=on-failure
[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable hermes-bridge >/dev/null 2>&1
systemctl --user restart hermes-bridge
loginctl enable-linger "\$(id -un)" >/dev/null 2>&1 || true
sleep 3
if systemctl --user is-active hermes-bridge >/dev/null 2>&1; then
  ROLLBACK_NEEDED=0
  trap - 0 1 2 15
  rm -f "\$ENV_BACKUP" "\$UNIT_BACKUP"
  echo "$okMarker"
else
  journalctl --user -u hermes-bridge -n 20 --no-pager 2>/dev/null || true
  echo "$failMarker"
  exit 1
fi
''';
  }

  /// Script de instalación LEGIBLE (cada línea auditable). Es el que recibe el
  /// agente: un comando opaco `base64 | sh` haría que un agente capaz lo
  /// rechace por seguridad. El único dato no legible es el propio programa del
  /// bridge (base64+gzip), claramente etiquetado como tal.
  Future<String> installScript({
    String? bridgeSource,
    BridgeRelease? release,
  }) async {
    if (release?.remote == true) {
      return buildInstallScript(
        '',
        _conn.host.trim(),
        remoteUri: BridgeReleaseChannel.payloadUri,
        expectedSha256: release!.sha256,
        expectedSize: release.size,
        expectedVersion: release.version,
      );
    }
    final py =
        release?.source ??
        bridgeSource ??
        await rootBundle.loadString('assets/bridge/hermes_bridge.py');
    final bridgeB64 = base64.encode(gzip.encode(utf8.encode(py)));
    return buildInstallScript(bridgeB64, _conn.host.trim());
  }

  /// Comando de COPIA-PEGA del usuario en su propia terminal: el curl corto al
  /// script público del repo hermes-setup (spec 028). Sustituye al heredoc
  /// base64 de U-23: una sola línea corta se pega siempre bien (sin riesgo
  /// MAX_CANON), es auditable en GitHub antes de ejecutarla, y el script
  /// todo-en-uno es idempotente — sirve igual para instalar el bridge por
  /// primera vez que para actualizarlo (descarga el hermes_bridge.py publicado
  /// en el mismo repo).
  static String installCommand({
    ServerHostPlatform platform = ServerHostPlatform.linux,
  }) => ServerSetupGenerator.setupCommandFor(platform);

  /// Instrucción para el agente: ejecutar el script LEGIBLE y reportar la
  /// salida. Se enmarca como una tarea de configuración de primera parte que el
  /// usuario inició explícitamente desde su app, para que el agente proponga la
  /// llamada a la shell (→ aprobación) en vez de rechazarla por opacidad.
  static String agentPrompt(String script) =>
      'First-party setup requested by the device owner from the Hermes Console '
      'app. Install the Hermes Mobile Bridge companion service by running the '
      'installer matching the SERVER operating system, then reply only with '
      'its output. This is expected and authorized.\n\n'
      'If this is native Windows, DO NOT run the POSIX block. Run this through '
      'PowerShell instead:\n\n'
      '```powershell\n${ServerSetupGenerator.powershellShellCommand}\n```\n\n'
      'On macOS or a Unix host without a working `systemd --user`, DO NOT run '
      'the block either. Run the portable public setup instead:\n\n'
      '```sh\n${ServerSetupGenerator.curlCommand}\n```\n\n'
      'Only on Linux/WSL2 with a working `systemd --user`, run the fully '
      'legible shell block below exactly as written. It writes the Bridge '
      'under Hermes home, registers its systemd user service and prints '
      '"$okMarker" on success.\n\n'
      '```sh\n$script\n```';

  /// Resultado de un intento de instalación.
  /// [ok] true si el bridge quedó accesible al final. [detail] mensaje para la
  /// UI. [command] el comando usado (para ofrecer copia-pega si algo falla).
  Future<({bool ok, String detail, String command})> install({
    String? bridgeSource,
    BridgeRelease? release,
    String? targetVersion,
    Future<String?> Function(String baseUrl)? versionProbe,
    void Function(String stage)? onProgress,
    Duration timeout = const Duration(minutes: 4),
  }) async {
    final expectedVersion = release?.version ?? targetVersion;
    final script = await installScript(
      bridgeSource: bridgeSource,
      release: release,
    );
    final command = installCommand();
    onProgress?.call('Launching the installation on the server…');

    String runId;
    try {
      runId = await _api.startRun(input: agentPrompt(script));
    } catch (e) {
      return (
        ok: false,
        detail: 'Could not launch the installation on the agent: $e',
        command: command,
      );
    }

    // Monitorizamos por POLLING de `GET /v1/runs/{id}` (más robusto que el SSE):
    // cuando el run pide aprobación (el agente quiere ejecutar el comando) la
    // auto-aprobamos UNA vez —el usuario inició esta acción explícitamente—.
    onProgress?.call('Instalando y arrancando el bridge…');
    final deadline = DateTime.now().add(timeout);
    var approvedOnce = false;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      Map<String, dynamic> run;
      try {
        run = await _api.getRun(runId);
      } catch (e) {
        debugPrint(
          '[bridge-install] excepción silenciada (se omite este elemento): $e',
        );
        continue; // 404 transitorio / red: reintenta hasta el deadline.
      }
      final status = (run['status'] ?? '').toString();
      if (status.contains('approval') || status.contains('await')) {
        if (!approvedOnce) {
          approvedOnce = true;
          onProgress?.call('Approving the installation action…');
          try {
            await _api.resolveRunApproval(runId, 'once');
          } catch (_) {
            /* la verificación real del bridge lo cubre igual */
          }
        }
        continue;
      }
      if (status == 'completed' ||
          status == 'failed' ||
          status == 'cancelled') {
        break;
      }
    }

    // Verificación REAL e independiente del texto del modelo: ¿responde el
    // bridge ahora? Reintentamos unos segundos por si tarda en levantar.
    onProgress?.call('Verificando el bridge…');
    final url = _conn.derivedBridgeUrl;
    for (var i = 0; i < 6; i++) {
      final token = await _safeProvision(url);
      if (token != null && token.isNotEmpty) {
        final client = BridgeClient(baseUrl: url, token: token);
        try {
          final h = await client.healthDiagnose();
          if (h.ok) {
            if (expectedVersion != null) {
              final running = await (versionProbe ?? BridgeClient.probeVersion)(
                url,
              );
              if (running == null ||
                  BridgeVersion.compare(running, expectedVersion) < 0) {
                onProgress?.call(
                  'The bridge is back, waiting for version $expectedVersion…',
                );
                continue;
              }
            }
            return (
              ok: true,
              detail: expectedVersion == null
                  ? 'Mobile Bridge instalado y conectado.'
                  : 'Mobile Bridge $expectedVersion instalado y conectado.',
              command: command,
            );
          }
        } catch (e) {
          debugPrint(
            '[bridge-install] excepción silenciada (se ignora sin más): $e',
          );
        } finally {
          client.close();
        }
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }

    return (
      ok: false,
      detail:
          'Could not confirm the bridge after installation (the server '
          'may have no service manager available, or the agent did not '
          'run the command). Open "Prepare Hermes", pick the server system '
          'and run its native command.',
      command: command,
    );
  }

  Future<String?> _safeProvision(String url) async {
    try {
      return await BridgeClient.provision(url, _conn.apiKey.trim());
    } catch (e) {
      debugPrint(
        '[bridge-install] excepción silenciada (se devuelve null): $e',
      );
      return null;
    }
  }
}
