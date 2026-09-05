// Capa de "runtime del agente": abstrae de DÓNDE corre el agente Hermes que
// controla la Consola (remoto, o local en el propio móvil), sin acoplar la UI
// a intents Android. La UI habla con providers; los providers usan el
// adaptador de plataforma `AppBridge`.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Estado de un runtime de agente desde el punto de vista de la Consola.
enum AgentRuntimeStatus {
  /// El runtime/app no está instalado en el dispositivo.
  notInstalled,

  /// Instalado pero aún no listo para controlar (falta setup/arranque).
  installed,

  /// Instalado y requiere un paso de configuración guiado.
  needsSetup,

  /// Listo: hay un endpoint del agente disponible para la Consola.
  ready,

  /// No aplicable en esta plataforma / no se puede determinar.
  unavailable,
}

/// Contrato común de un proveedor de runtime de agente.
abstract class AgentRuntimeProvider {
  /// Identificador estable (p.ej. 'local-nous-app', 'local-termux', 'remote').
  String get id;

  /// Nombre legible para la UI.
  String get displayName;

  /// Estado actual del runtime.
  Future<AgentRuntimeStatus> status();
}

/// Constantes compartidas de los runtimes locales (paquetes, comando, puertos).
class AgentRuntimeConsts {
  AgentRuntimeConsts._();

  /// Termux: host de runtime para el agente Hermes completo (controlable).
  static const String termuxPackage = 'com.termux';

  /// Cliente de F-Droid (para detección/atajos).
  static const String fdroidPackage = 'org.fdroid.fdroid';

  /// URL del instalador oficial (Nous). Punto de contacto con upstream: si
  /// cambia, actualizar aquí y en [installWrapperCommand]. Es la URL canónica
  /// (doc oficial: Linux/macOS/WSL2/Android Termux) — la única que aparece en la
  /// UI y en la documentación interna (ver ADR-006).
  static const String installerUrl =
      'https://hermes-agent.nousresearch.com/install.sh';

  /// Fallback SOLO para la ruta automática avanzada si [installerUrl] falla la
  /// descarga. Nunca se muestra como ruta principal; su uso queda en el log.
  static const String installerUrlFallback =
      'https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh';

  /// Instalador documentado del agente Hermes completo (Linux/Termux), siempre
  /// sin asistente interactivo. La app escribe `~/.hermes/config.yaml`.
  static const String installCommand =
      'curl -fsSL $installerUrl | bash -s -- --skip-setup';

  // ── Comandos heredados del wizard manual (deshabilitado) ──────────────────
  // Se conservan sólo para tests/documentación interna. La UI no debe
  // ofrecerlos: el usuario no interactúa con Termux.

  /// Paso 1 (opcional, `manual_required`): cambiar de mirror si la red de
  /// paquetes falla. Es un diálogo `whiptail` interactivo → NUNCA automatizar.
  static const String changeRepoCommand = 'termux-change-repo';

  /// Paso 2: actualizar el índice y los paquetes de Termux.
  static const String updateCommand = 'pkg update -y && pkg upgrade -y';

  /// Paso 3: dependencias base del agente (lista de la doc oficial + curl).
  /// `python-pillow` instala Pillow precompilado de Termux: evita el build de la
  /// wheel desde pip, que falla en Pillow ≥10.0.0,<10.1.0 por un bug de su
  /// MANIFEST.in ("no previously-included directories found matching
  /// 'Tests/errors'"). `libjpeg-turbo` es su dependencia nativa de imagen.
  static const String basePackagesCommand =
      'pkg install -y git python clang rust make pkg-config libffi '
      'openssl ca-certificates nodejs ripgrep ffmpeg curl libjpeg-turbo '
      'python-pillow';

  /// Paso 5: recargar el entorno para que `hermes` quede en el PATH.
  static const String reloadEnvCommand = 'source ~/.bashrc';

  /// Paso 6: verificar la instalación.
  static const String verifyCommand = 'hermes version && hermes doctor';

  /// Comando histórico interactivo deshabilitado. No contiene el comando real
  /// para evitar ejecución accidental o aparición en UI/logs.
  static const String setupCommand = '# interactive setup disabled';

  /// Endpoints por defecto del agente local en el propio dispositivo.
  ///
  /// Gateway API local para chat/sesiones. El Dashboard sigue en 9119 para
  /// pantallas de administración, igual que en instancias remotas.
  static const String localHost = '127.0.0.1';
  static const int localGatewayPort = 8642;
  static const int localDashboardPort = 9119;

  /// Mobile Bridge local (chat oneshot, config, skills…). En local suele ser el
  /// ÚNICO servicio que sube de forma fiable (el Dashboard puede no arrancar por
  /// OOM/permiso), así que también sirve como prueba de "agente en marcha".
  static const int localBridgePort = 9131;

  /// Versión del Mobile Bridge que trae ESTE APK (asset
  /// `assets/bridge/hermes_bridge.py`, constante `VERSION`). La app la compara
  /// con la versión que reporta `/bridge/health` del bridge EN EJECUCIÓN: si no
  /// coinciden, un bridge viejo de una instalación anterior sigue vivo y hay que
  /// redeplegar+reiniciar ([LocalTermuxAgentProvider.ensureFreshBridge]). Subir
  /// este valor cada vez que cambie `VERSION` en el script del bridge.
  static const String expectedBridgeVersion = '1.18.0';

  /// Token de sesión local FIJO y bien conocido para el agente local.
  ///
  /// Decisión de seguridad (2026-06-20, matizada 2026-07-03 en spec 028
  /// A-304): el agente local (dashboard :9119, gateway :8642, bridge :9131)
  /// escucha SOLO en loopback (127.0.0.1). OJO: loopback NO aísla entre apps —
  /// cualquier app co-instalada con permiso INTERNET puede conectar a esos
  /// puertos TCP, así que un token fijo y público es alcanzable por terceros
  /// en el dispositivo. Se mantiene fijo como compromiso consciente porque
  /// elimina la clase de bugs de desincronización (al reinstalar el APK o
  /// limpiar datos, un UUID en SecureStorage se regeneraba pero agente/bridge
  /// seguían con el viejo → 401 `invalid_gateway_key`). LÍMITES del riesgo:
  /// solo existe en el flavor `full` con agente local instalado en Termux
  /// (nunca en el build de Play, que es solo-remoto). PENDIENTE (deuda 028):
  /// token por dispositivo con re-provisión automática ante 401. Para
  /// instancias REMOTAS el token sigue siendo el real del gateway del usuario.
  static const String localDashboardToken = 'hermes-console-local';

  /// Devuelve el token de sesión local. Siempre el literal fijo
  /// [localDashboardToken]: es el mismo placeholder que [startAgentCommandWith]
  /// y [restartBridgeCommandWith] sustituyen en el comando de arranque, así que
  /// app, dashboard y bridge quedan consistentes sin posibilidad de desajuste.
  /// Async por compatibilidad con los llamadores existentes. Ver la nota de
  /// seguridad en [localDashboardToken].
  static Future<String> getOrGenerateLocalToken() async {
    // Limpia cualquier UUID heredado de versiones anteriores (best-effort) para
    // que no quede ruido en SecureStorage; el token efectivo es siempre el fijo.
    const storage = FlutterSecureStorage();
    const legacyKey = 'local_agent_session_token';
    try {
      final legacy = await storage.read(key: legacyKey);
      if (legacy != null && legacy != localDashboardToken) {
        await storage.delete(key: legacyKey);
      }
    } catch (_) {
      // SecureStorage puede fallar en algunos OEM; ignorar, el token es fijo.
    }
    return localDashboardToken;
  }

  /// Marca persistida «el agente local está instalado en este dispositivo».
  ///
  /// La app NO puede leer el sistema de archivos de Termux, así que no hay forma
  /// directa de distinguir «agente instalado pero parado» de «agente sin
  /// instalar» — sin esta marca ambos casos colapsaban en un mismo estado
  /// ambiguo que ofrecía a la vez «arrancar» e «instalar». La marca la fija la
  /// propia app cuando tiene EVIDENCIA de que el agente existe: (a) completó la
  /// instalación guiada (@@EXIT 0), o (b) vio al agente respondiendo en :9119 al
  /// menos una vez. Con eso la detección es binaria y honesta: con marca ⇒
  /// ofrecer SÓLO arrancar/conectar; sin marca ⇒ ofrecer SÓLO instalar. Se borra
  /// al desinstalar.
  static const String _agentInstalledKey = 'local_agent_installed';

  /// Sonda (bash puro, sin dependencias) que comprueba en el sistema de archivos
  /// de Termux si el agente Hermes está REALMENTE instalado y arrancable, aunque
  /// esté parado. Se ejecuta vía [AppBridge.probeTermux] y su stdout vuelve a la
  /// app por el PendingIntent de RUN_COMMAND. Marca el resultado con sentinelas
  /// inequívocos.
  ///
  /// CLAVE: comprueba el **python del venv ejecutable** (exactamente lo que el
  /// comando de arranque necesita, ver [startAgentCommand]/[restartBridgeCommand]),
  /// NO `~/.hermes` — esa carpeta es solo logs/datos: la crea `mkdir -p` y
  /// SOBREVIVE a la desinstalación, dando falsos «instalado» que mandaban a
  /// «Arrancar» un agente inexistente (que nunca respondía). Cubre los dos
  /// layouts: `~/.hermes/hermes-agent/venv` (principal) y `~/.hermes-agent/venv`
  /// (fallback).
  static const String detectInstalledCommand =
      'if [ -x "\$HOME/.hermes/hermes-agent/venv/bin/python3" ] || '
      '[ -x "\$HOME/.hermes-agent/venv/bin/python3" ]; '
      'then echo "@@HERMES_INSTALLED"; else echo "@@HERMES_ABSENT"; fi';

  static Future<bool> isAgentInstalledMarked() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getBool(_agentInstalledKey) ?? false;
    } catch (e) {
      debugPrint('[agent-runtime] excepción silenciada (se asume false): $e');
      return false;
    }
  }

  static Future<void> setAgentInstalled(bool installed) async {
    try {
      final p = await SharedPreferences.getInstance();
      if (installed) {
        await p.setBool(_agentInstalledKey, true);
      } else {
        await p.remove(_agentInstalledKey);
      }
    } catch (_) {
      // best-effort: la detección cae a sondear :9119 si prefs falla.
    }
  }

  /// Versión de [startAgentCommand] con el token real inyectado.
  /// startAgentCommand es r''' (raw string) — se hace replaceAll sobre el String
  /// resultante; no se toca el raw string original.
  static String startAgentCommandWith(String token) =>
      startAgentCommand.replaceAll('hermes-console-local', token);

  /// Reinicia SOLO el Mobile Bridge (sin tocar dashboard/gateway/ollama). Mata
  /// cualquier bridge previo de forma ROBUSTA — por pidfile + cmdline + puerto en
  /// escucha (TERM y luego KILL) — y lo arranca fresco con el token ACTUAL.
  ///
  /// Por qué el matado robusto importa: un pidfile obsoleto NO basta. El bridge
  /// corre como `python3.X` (su `comm` no contiene "hermes") y un arranque
  /// anterior puede seguir vivo con OTRO pid reteniendo `:9131`; si solo se mata
  /// por pidfile, el viejo sobrevive, el nuevo `nohup ... --port 9131` no puede
  /// bindear y muere, y queda el VIEJO sirviendo código antiguo → endpoints
  /// nuevos dan 404 y `model/set` no persiste. Por eso se mata como en el stop
  /// completo (pidfile + `pgrep -f hermes_bridge.py` + puerto), excluyendo el pid
  /// propio.
  ///
  /// También resuelve el 401 `invalid_gateway_key`: un bridge de un arranque
  /// anterior tendría un API_SERVER_KEY (token) distinto del que envía la app al
  /// provisionar. `hermes-console-local` se sustituye por el token real en
  /// [restartBridgeCommandWith], igual que en [startAgentCommandWith].
  static const String restartBridgeCommand = r'''
export PREFIX=/data/data/com.termux/files/usr;
export HOME=/data/data/com.termux/files/home;
export PATH="$PREFIX/bin:$PATH";
LOGD="$HOME/.hermes"; mkdir -p "$LOGD" 2>/dev/null;
VENV="$HOME/.hermes/hermes-agent/venv";
kill_pidfile(){ pid=$(cat "$1" 2>/dev/null); if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then kill "-$2" "$pid" 2>/dev/null || true; fi; };
kill_pat(){ sig="$1"; pat="$2"; pgrep -f "$pat" 2>/dev/null | while read -r pid; do [ -z "$pid" ] && continue; [ "$pid" = "$$" ] && continue; [ "$pid" = "$PPID" ] && continue; kill "-$sig" "$pid" 2>/dev/null || true; done; };
kill_ports(){ sig="$1"; shift; for port in "$@"; do for SS in ss /system/bin/ss; do (command -v "$SS" >/dev/null 2>&1 || [ -x "$SS" ]) || continue; "$SS" -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ p {print}' | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p'; break; done | sort -u | while read -r pid; do [ -z "$pid" ] && continue; [ "$pid" = "$$" ] && continue; [ "$pid" = "$PPID" ] && continue; kill "-$sig" "$pid" 2>/dev/null || true; done; done; };
kill_pidfile "$LOGD/bridge.pid" TERM; kill_pat TERM "hermes_bridge.py"; kill_ports TERM 9131;
sleep 2;
kill_pidfile "$LOGD/bridge.pid" KILL; kill_pat KILL "hermes_bridge.py"; kill_ports KILL 9131;
rm -f "$LOGD/bridge.pid" 2>/dev/null || true;
sleep 1;
for BPATH in \
  "$HOME/.hermes/hermes_bridge.py" \
  "$HOME/.hermes/hermes-agent/hermes_bridge.py" \
  "$HOME/.hermes/bridge.py"; do
  if [ -f "$BPATH" ]; then
    BPYTHON="$VENV/bin/python3";
    [ -x "$BPYTHON" ] || BPYTHON="$HOME/.hermes-agent/venv/bin/python3";
    [ -x "$BPYTHON" ] || BPYTHON=python3;
    LPY="$(ls "$PREFIX"/lib/libpython3*.so 2>/dev/null | head -1)"; [ -n "$LPY" ] && export LD_PRELOAD="$LPY${LD_PRELOAD:+:$LD_PRELOAD}";
    "$BPYTHON" -c "import aiohttp" 2>/dev/null || { echo "[bridge] aiohttp ausente; instalando (pure-python, sin compilador)..." >> "$LOGD/bridge.out"; AIOHTTP_NO_EXTENSIONS=1 MULTIDICT_NO_EXTENSIONS=1 YARL_NO_EXTENSIONS=1 FROZENLIST_NO_EXTENSIONS=1 "$BPYTHON" -m pip install --no-input -q aiohttp >> "$LOGD/bridge.out" 2>&1; "$BPYTHON" -c "import aiohttp" 2>/dev/null && echo "[bridge] aiohttp OK" >> "$LOGD/bridge.out" || echo "[bridge] aiohttp FALLO al instalar (revisa errores arriba)" >> "$LOGD/bridge.out"; };
    BRIDGE_SCOPES="read,skills,memory,soul,config,command" \
    API_SERVER_KEY="hermes-console-local" \
    BRIDGE_TOKEN="hermes-console-local" \
    BRIDGE_HERMES_HOME="$HOME/.hermes" \
    BRIDGE_HOST="127.0.0.1" \
    BRIDGE_PORT="9131" \
    nohup "$BPYTHON" "$BPATH" --port 9131 --bind 127.0.0.1 >> "$LOGD/bridge.out" 2>&1 &
    echo $! > "$LOGD/bridge.pid";
    break;
  fi;
done;
echo BRIDGE_RESTARTED;
''';

  /// Versión de [restartBridgeCommand] con el token real inyectado.
  static String restartBridgeCommandWith(String token) =>
      restartBridgeCommand.replaceAll('hermes-console-local', token);

  /// Puerto local donde el wrapper de instalación sirve su log de progreso,
  /// para que la Consola lo lea en tiempo real (loopback compartido entre apps).
  static const int localInstallPort = 8643;

  /// URL del log de progreso servido por el wrapper durante la instalación.
  static const String installProgressUrl =
      'http://$localHost:$localInstallPort/progress.log';

  /// Puerto local donde el flujo OAuth sirve su log (la URL de autenticación y
  /// los marcadores @@OAUTH_*), para que la Consola lo lea sin abrir Termux.
  /// Distinto del puerto del instalador (:8643) para no colisionar.
  static const int localOAuthPort = 8644;

  /// URL del log del flujo OAuth servido por localhost. La app lo sondea para
  /// extraer la URL `https://…` de login y detectar el final del flujo.
  static const String oauthProgressUrl =
      'http://$localHost:$localOAuthPort/oauth.log';

  /// Puerto del servidor de diagnóstico temporal que [startAgentCommand] levanta
  /// (~60 s) sirviendo `~/.hermes`, para que la Consola pueda leer los logs del
  /// gateway cuando el arranque falla. Reutiliza :8645 (libre tras el arranque).
  static const int localDiagPort = 8645;

  /// URL del log del gateway expuesto por el servidor de diagnóstico.
  static const String gatewayLogUrl =
      'http://$localHost:$localDiagPort/gateway.out';

  /// Tiempo máximo de la instalación (ruta automática avanzada). Si se supera,
  /// la app aborta con un error claro y mata el proceso en Termux. El wrapper
  /// aplica timeouts internos por etapa (update + base packages + install.sh)
  /// que suman algo menos que esto; este es el tope duro del lado app. Subido a
  /// 60 min porque `install.sh` puede compilar wheels/Rust nativo en Android.
  static const Duration installTimeout = Duration(minutes: 60);

  /// Código de salida que el wrapper escribe cuando la instalación se cancela
  /// desde la app (ver [cancelInstallCommand]).
  static const int installCanceledCode = 130;

  /// Mata el proceso de instalación y su servidor de log en Termux, dejando el
  /// estado limpio. Best-effort vía RUN_COMMAND en segundo plano.
  static const String cancelInstallCommand = r'''
P="$HOME/.hermes-install";
if [ -f "$P/inst.pid" ]; then kill -- -"$(cat "$P/inst.pid")" 2>/dev/null || kill "$(cat "$P/inst.pid")" 2>/dev/null; fi
pkill -f "$P/inst.sh" 2>/dev/null; pkill -f "http.server 8643" 2>/dev/null;
pkill -f "pip install" 2>/dev/null; pkill -f "cargo build" 2>/dev/null;
pkill -f "maturin" 2>/dev/null; pkill -f "rustc" 2>/dev/null;
echo "@@EXIT 130" >> "$P/progress.log" 2>/dev/null; echo "@@DONE" >> "$P/progress.log" 2>/dev/null;
echo CANCELADO
''';

  /// Comando que activa `allow-external-apps` en Termux (una vez) para que la
  /// app pueda lanzar la instalación automáticamente vía RUN_COMMAND.
  static const String allowExternalAppsCommand =
      'mkdir -p ~/.termux && grep -q "^allow-external-apps=true" '
      '~/.termux/termux.properties 2>/dev/null || echo '
      '"allow-external-apps=true" >> ~/.termux/termux.properties; '
      'termux-reload-settings 2>/dev/null; echo LISTO';

  /// Bootstrap automático SIN intervención: activa `allow-external-apps` y
  /// vuelve a la Consola. Se ejecuta como sesión FOREGROUND de Termux
  /// (TermuxActivity), que acepta estos extras aunque la propiedad aún no esté
  /// activa — al contrario que el RunCommandService de [allowExternalAppsCommand],
  /// que la exige. Tras escribir la propiedad, `am start` trae la app al frente
  /// (lifecycle `resumed`) para reintentar el RUN_COMMAND real, y `exit` cierra
  /// la sesión. `grep -qxF` evita duplicar la propiedad.
  static const String bootstrapExternalAppsCommand =
      r'''mkdir -p ~/.termux; grep -qxF allow-external-apps=true ~/.termux/termux.properties 2>/dev/null || printf 'allow-external-apps=true\n' >> ~/.termux/termux.properties; am start -n dev.xpetalab.hermesconsole/com.hermesagent.hermes_android.MainActivity >/dev/null 2>&1; exit''';

  /// Para el agente Hermes en ejecución dentro de Termux. Envía TERM primero
  /// (graceful) y, si no muere en 2 s, KILL. Cubre gateway (:8642) y
  /// dashboard (:9119).
  static const String stopAgentCommand = r'''
export PREFIX=/data/data/com.termux/files/usr;
export HOME=/data/data/com.termux/files/home;
export PATH="$HOME/.hermes/hermes-agent/venv/bin:$HOME/.hermes-agent/venv/bin:$PREFIX/bin:$PATH";
LOGD="$HOME/.hermes";
# Parar el agente es DETERMINISTA y SELF-SAFE. El bug anterior usaba
# `pkill -KILL -f "hermes"`, que coincidía por CMDLINE con dos cosas que no debía:
#   1) el PROPIO script de parada — RUN_COMMAND lo lanza con `bash -c '<texto>'`,
#      y ese texto contiene "hermes", así que el script se autodisparaba SIGKILL y
#      ABORTABA a medias: nunca liberaba el wake-lock ni terminaba la limpieza, y
#      dejaba servicios medio-muertos. De ahí "no para / parece que se reinicia".
#   2) el Mobile Bridge — corre como `python3 ~/.hermes/hermes_bridge.py`, cuyo
#      cmdline contiene ".hermes/hermes_bridge", así que el chat local se caía con
#      "connection closed" si había un turno en vuelo.
# Además dependía de patrones por cmdline sin excluir su propio pid. Ahora se mata
# por pidfile + nombre EXACTO de proceso + puerto en escucha, excluyendo $$ y $PPID,
# igual que el desinstalador (patrón ya probado). Para el stack local completo:
# gateway/dashboard (binario `hermes`), Mobile Bridge (`hermes_bridge.py`) y Ollama.
kill_pidfile(){ pid=$(cat "$1" 2>/dev/null); if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; fi; };
# pkill -f puede autosignalizar el script (bash -c expone su texto en el cmdline);
# por eso se itera con pgrep excluyendo el pid propio ($$) y el del padre ($PPID).
kill_pat(){ sig="$1"; pat="$2"; pgrep -f "$pat" 2>/dev/null | while read -r pid; do [ -z "$pid" ] && continue; [ "$pid" = "$$" ] && continue; [ "$pid" = "$PPID" ] && continue; kill "-$sig" "$pid" 2>/dev/null || true; done; };
# Mata por PUERTO en escucha — lo más fiable cuando los pidfiles quedan obsoletos
# (visto en vivo: bridge.pid apuntaba a un pid muerto mientras el bridge real seguía
# vivo con otro pid). ss ve los sockets de los procesos del mismo uid (Termux).
kill_ports(){ sig="$1"; shift; for port in "$@"; do for SS in ss /system/bin/ss; do (command -v "$SS" >/dev/null 2>&1 || [ -x "$SS" ]) || continue; "$SS" -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ p {print}' | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p'; break; done | sort -u | while read -r pid; do [ -z "$pid" ] && continue; [ "$pid" = "$$" ] && continue; [ "$pid" = "$PPID" ] && continue; kill "-$sig" "$pid" 2>/dev/null || true; done; done; };
# OJO con los matchers (verificado en vivo en Termux):
#  - El bridge corre como `python3.13` (comm NO contiene "hermes") → solo se le
#    alcanza por cmdline: kill_pat "hermes_bridge.py".
#  - `pkill -x` (nombre exacto) es POCO FIABLE en el procps de Termux: no encontró
#    ni a ollama (comm="ollama") → no usar -x.
#  - `pkill hermes` por comm matchea TAMBIÉN el proceso de la app
#    (dev.xpetalab.hermesconsole); como el stop corre con otro uid no la mata,
#    pero es frágil → gateway/dashboard se matan por cmdline EXACTO (subcomando),
#    no por comm.
#  - Ollama sí se mata bien por comm con `pkill ollama` (sin -x), patrón ya usado
#    en stopOllamaCommand.
# 1) TERM (gracia)
kill_pidfile "$LOGD/dashboard.pid"; kill_pidfile "$LOGD/gateway.pid"; kill_pidfile "$LOGD/bridge.pid";
kill_pat TERM "hermes dashboard"; kill_pat TERM "hermes gateway"; kill_pat TERM "hermes_bridge.py";
pkill -TERM ollama 2>/dev/null || true;
kill_ports TERM 9119 8642 9131 11434;
sleep 2;
# 2) KILL (lo que siga vivo)
kill_pidfile "$LOGD/dashboard.pid"; kill_pidfile "$LOGD/gateway.pid"; kill_pidfile "$LOGD/bridge.pid";
kill_pat KILL "hermes dashboard"; kill_pat KILL "hermes gateway"; kill_pat KILL "hermes_bridge.py";
pkill -KILL ollama 2>/dev/null || true;
kill_ports KILL 9119 8642 9131 11434;
# Limpia pidfiles obsoletos: que el próximo arranque/parada no apunte a pids muertos.
rm -f "$LOGD/dashboard.pid" "$LOGD/gateway.pid" "$LOGD/bridge.pid" 2>/dev/null || true;
# Libera el wake-lock adquirido en startAgentCommand. Best-effort.
termux-wake-unlock 2>/dev/null || true;
echo STOPPED
''';

  /// Lee las últimas 30 líneas del log del gateway. RUN_COMMAND en background
  /// no devuelve stdout; este comando es referencia para uso manual / futuro.
  static const String readLogsCommand = r'''
export HOME=/data/data/com.termux/files/home;
tail -30 "$HOME/.hermes/gateway.out" 2>/dev/null || echo "(sin logs)";
''';

  /// Arranca el agente Hermes en segundo plano dentro de Termux después de
  /// instalarlo (el instalador corre con `--skip-setup`, que instala pero NO
  /// arranca nada). Levanta los dos servicios que la Consola necesita:
  ///   • Gateway / API server (:8642) — lo que [isAgentRunning] sondea y lo que
  ///     usa el chat de la Consola.
  ///   • Dashboard (:9119) — API local para pantallas de administración.
  ///
  /// Igual que [installWrapperCommand], fija el entorno de Termux a mano: un
  /// RUN_COMMAND lanza un shell NO interactivo y NO de login cuyo PATH puede no
  /// incluir el prefijo de Termux, así que `hermes` no se resolvería y el
  /// arranque fallaría en silencio. Se usa `nohup ... &` para que los procesos
  /// sobrevivan al cierre de la sesión RUN_COMMAND.
  ///
  /// TODO(upstream): verificar los subcomandos exactos contra `hermes --help`
  /// del agente instalado. Las CLI docs son algo inconsistentes; referencia:
  /// https://hermes-agent.nousresearch.com/docs/reference/cli-commands
  /// (dashboard → :9119, API/gateway → :8642). Si cambian, actualizar aquí.
  static const String startAgentCommand = r'''
set +e;
# PREFIX/HOME = carpeta de datos privada del paquete com.termux: Android la fija
# por nombre de paquete (el usuario NO puede moverla), así que hardcodearla es lo
# robusto — RUN_COMMAND no exporta HOME, y leerlo daría "/" o vacío. Lo que SÍ
# varía (venv/python/hermes/bridge) se busca dinámicamente más abajo.
export PREFIX=/data/data/com.termux/files/usr;
export HOME=/data/data/com.termux/files/home;
export PATH="$PREFIX/bin:$PATH";
LOGD="$HOME/.hermes"; mkdir -p "$LOGD" 2>/dev/null;
# Compilación Rust EN SERIE. En Termux/Android no hay wheels precompiladas para
# pydantic-core/cryptography/jiter/rpds-py, así que pip las compila con cargo. La
# compilación EN PARALELO (por defecto = nº de núcleos) dispara el pico de RAM y
# el kernel mata el proceso (OOM) a mitad → venv/instalación a medias = "está
# instalado pero el dashboard no levanta". CARGO_BUILD_JOBS=1 + MAKEFLAGS=-j1
# bajan el pico a ~1 núcleo y dejan que cualquier (re)instalación que el dashboard
# dispare al arrancar (recuperación de install interrumpido) TERMINE en vez de
# morir. Lo heredan los procesos hijos (dashboard→pip). VERIFICADO en emulador:
# pydantic-core compila a ~1.1 GB libres en vez de quedarse sin memoria.
export CARGO_BUILD_JOBS=1; export MAKEFLAGS=-j1; export CARGO_PROFILE_RELEASE_DEBUG=0;
# VELOCIDAD: el grueso del tiempo se va compilando Rust con optimización completa
# (release opt-level=3). Para un agente local el coste de runtime de opt-level=0 es
# despreciable, pero el tiempo de compilación cae ~3-4x (pydantic-core: ~3-4 min →
# ~1 min, MEDIDO en emulador) y además usa MENOS RAM (la optimización es lo que más
# memoria consume). codegen-units alto = paralelismo de codegen dentro del crate
# sin lanzar más jobs de cargo (mantiene el pico de RAM bajo control).
export CARGO_PROFILE_RELEASE_OPT_LEVEL=0; export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16;
# Wake-lock de Termux: sin él, Android congela (Doze/App Standby) o mata los
# procesos de Termux cuando la Consola está en primer plano → el dashboard/bridge
# "dejan de responder a cada rato". termux-wake-lock (paquete termux-tools, viene
# con Termux) mantiene la CPU despierta para que el agente siga sirviendo. Se
# libera en stopAgentCommand con termux-wake-unlock. Best-effort (|| true).
termux-wake-lock 2>/dev/null || true;
# Resolver el binario `hermes`. El wrapper de Termux (/usr/bin/hermes) usa
# #!/usr/bin/env bash, que falla en RunCommandService porque Android no tiene
# /usr/bin/env. Priorizar el script del venv (shebang con ruta absoluta al
# python del venv) y solo caer en command -v como último recurso.
HERMES="$HOME/.hermes/hermes-agent/venv/bin/hermes";
[ ! -x "$HERMES" ] && HERMES="$(command -v hermes 2>/dev/null)";
[ -z "$HERMES" ] && HERMES=hermes;
VENV="$HOME/.hermes/hermes-agent/venv";
# Bug 2: priorizar el python/hermes del venv. Sin esto, `python3` y `hermes`
# resuelven al binario del SISTEMA, que no tiene instalado `hermes_cli` → la
# resolución de web_dist (abajo) devuelve vacío y el dashboard arranca sin él
# ("no web dist found"). Se cubren las dos rutas de venv conocidas.
export PATH="$VENV/bin:$HOME/.hermes-agent/venv/bin:$PATH";
# python del venv para resolver el paquete instalado (no el python del sistema).
VPYTHON="$VENV/bin/python3"; [ -x "$VPYTHON" ] || VPYTHON=python3;
# FIX DE ENLAZADO (Termux/Android): la extensión nativa de cryptography
# (cryptography/hazmat/bindings/_rust.abi3.so) NO encuentra los símbolos de
# Python al cargarse — "dlopen failed: cannot locate symbol PyExc_Warning /
# PyObject_IsInstance" — porque libpython no está en el ámbito GLOBAL de símbolos
# del proceso. Como cryptography es dependencia central, el dashboard/gateway se
# caen al importarla y el agente "no arranca" (pasa con ABI heredado tras
# actualizar Python; reconstruir el venv NO lo arregla). Precargar libpython hace
# visibles sus símbolos para la extensión. VERIFICADO en emulador: sin esto el
# import falla, con LD_PRELOAD importa OK. Lo heredan todos los procesos hijos
# (dashboard/bridge). Best-effort: sólo si existe el .so; no pisa un LD_PRELOAD previo.
LPY="$(ls "$PREFIX"/lib/libpython3*.so 2>/dev/null | head -1)";
[ -n "$LPY" ] && export LD_PRELOAD="$LPY${LD_PRELOAD:+:$LD_PRELOAD}";
# Dashboard (:9119): La Consola lo usa como API gateway local. Requiere:
#   1. web_dist/assets/ (para --skip-build sin npm/tsc en Android)
#   2. web_dist/index.html con window.__HERMES_SESSION_TOKEN__ inyectado,
#      para que DashboardClient._getToken() extraiga el token del HTML.
# El token fijo permite a la Consola autenticarse sin intervención del usuario.
HERMES_PKG="$("$VPYTHON" -c 'import hermes_cli, os; print(os.path.dirname(hermes_cli.__file__))' 2>/dev/null)";
if [ -n "$HERMES_PKG" ]; then
  mkdir -p "$HERMES_PKG/web_dist/assets" 2>/dev/null;
  printf '<html><head><script>window.__HERMES_SESSION_TOKEN__="hermes-console-local";</script></head><body>Hermes API</body></html>' > "$HERMES_PKG/web_dist/index.html" 2>/dev/null;
fi;
export HERMES_DASHBOARD_SESSION_TOKEN=hermes-console-local;
# Desactivar las instalaciones LAZY del agente antes de arrancar el dashboard. Al
# iniciar, el dashboard refresca sus "features lazy" y pip-instala las
# dependencias de integraciones de mensajería (dingtalk/alibabacloud, etc.) que la
# Consola NO usa. En Android eso recompila crates de Rust pesados (maturin/cffi/
# cryptography), BLOQUEA el arranque (uvicorn liga el socket :9119 pero no
# responde hasta terminar) y arriesga OOM → la Consola "no conecta nunca". Con
# allow_lazy_installs:false el dashboard sirve /api/status al instante con las deps
# base. VERIFICADO en emulador: pasa de colgarse (HTTP 000) a responder 200 en 0 s.
# Idempotente: true→false si existe la clave; si no, se inserta en la sección
# security; si no hay sección, se añade al final.
CFG="$HOME/.hermes/config.yaml";
if [ -f "$CFG" ]; then
  if grep -q 'allow_lazy_installs:' "$CFG"; then
    sed -i 's/allow_lazy_installs: *true/allow_lazy_installs: false/' "$CFG";
  elif grep -q '^security:' "$CFG"; then
    sed -i 's/^security:/security:\n  allow_lazy_installs: false/' "$CFG";
  else
    printf '\nsecurity:\n  allow_lazy_installs: false\n' >> "$CFG";
  fi;
fi;
# Si el venv está sano, borrar cualquier marcador/lock de install interrumpido que
# haya quedado de un intento previo: con él presente, el dashboard se cuelga al
# arrancar reintentando instalar el perfil completo de extras aunque el entorno
# ya esté completo. Solo se borra si hermes_cli importa (entorno verificado).
VVPY="$HOME/.hermes/hermes-agent/venv/bin/python3";
[ -x "$VVPY" ] || VVPY="$HOME/.hermes-agent/venv/bin/python3";
if [ -x "$VVPY" ] && "$VVPY" -c 'import hermes_cli' >/dev/null 2>&1; then
  rm -f "$HOME/.hermes/hermes-agent/.update-incomplete" \
        "$HOME/.hermes/hermes-agent/.update-incomplete.lock" \
        "$HOME/.hermes-agent/.update-incomplete" \
        "$HOME/.hermes-agent/.update-incomplete.lock" 2>/dev/null;
fi;
nohup "$HERMES" dashboard --no-open --skip-build --port 9119 >> "$LOGD/dashboard.out" 2>&1 &
echo $! > "$LOGD/dashboard.pid";
# NOTA: NO se arranca `hermes gateway run`. Verificado en vivo contra el agente
# 0.16: `hermes gateway` es el gateway de MENSAJERÍA (Telegram/WhatsApp/Slack) y
# NO expone una API HTTP en :8642 — sólo emite avisos ("No messaging platforms
# enabled") y acumula instancias zombie. La API que usa la Consola (chat
# /v1/runs, /api/sessions, /api/status, /health) la sirve el DASHBOARD en :9119,
# ya arrancado arriba. Si en el futuro se quiere mensajería, sería un arranque
# aparte con su config — no es necesario para que la Consola funcione.
# Mobile Bridge (:9131): habilita escribir SOUL/memoria e instalar/activar
# skills desde la Consola (el dashboard es GET-only para eso). La app despliega
# el script en ~/.hermes/hermes_bridge.py (deployBridgeCommand) antes de este
# arranque; aquí se lanza con el python del venv (trae aiohttp) y los scopes de
# escritura. API_SERVER_KEY = token del dashboard local: permite que la Consola
# auto-provisione el token del bridge con su misma apiKey (/bridge/provision).
# Búsqueda dinámica de rutas para no romper en Termux modificados.
for BPATH in \
  "$HOME/.hermes/hermes_bridge.py" \
  "$HOME/.hermes/hermes-agent/hermes_bridge.py" \
  "$HOME/.hermes/bridge.py"; do
  if [ -f "$BPATH" ]; then
    # Reemplaza SIEMPRE cualquier bridge previo. Si quedó uno de un arranque
    # anterior, su API_SERVER_KEY sería un token distinto del actual y la app
    # daría 401 (invalid_gateway_key) al provisionar. Lo matamos por pidfile
    # (directo, sin depender de pkill) y por patrón, y arrancamos fresco con el
    # token de ESTE arranque (startAgentCommandWith sustituye la clave abajo).
    OLDB=$(cat "$LOGD/bridge.pid" 2>/dev/null);
    [ -n "$OLDB" ] && kill -9 "$OLDB" 2>/dev/null;
    sleep 1;
    BPYTHON="$VENV/bin/python3";
    [ -x "$BPYTHON" ] || BPYTHON="$HOME/.hermes-agent/venv/bin/python3";
    [ -x "$BPYTHON" ] || BPYTHON=python3;
    LPY="$(ls "$PREFIX"/lib/libpython3*.so 2>/dev/null | head -1)"; [ -n "$LPY" ] && export LD_PRELOAD="$LPY${LD_PRELOAD:+:$LD_PRELOAD}";
    "$BPYTHON" -c "import aiohttp" 2>/dev/null || { echo "[bridge] aiohttp ausente; instalando (pure-python, sin compilador)..." >> "$LOGD/bridge.out"; AIOHTTP_NO_EXTENSIONS=1 MULTIDICT_NO_EXTENSIONS=1 YARL_NO_EXTENSIONS=1 FROZENLIST_NO_EXTENSIONS=1 "$BPYTHON" -m pip install --no-input -q aiohttp >> "$LOGD/bridge.out" 2>&1; "$BPYTHON" -c "import aiohttp" 2>/dev/null && echo "[bridge] aiohttp OK" >> "$LOGD/bridge.out" || echo "[bridge] aiohttp FALLO al instalar (revisa errores arriba)" >> "$LOGD/bridge.out"; };
    BRIDGE_SCOPES="read,skills,memory,soul,config,command" \
    API_SERVER_KEY="hermes-console-local" \
    BRIDGE_TOKEN="hermes-console-local" \
    BRIDGE_HERMES_HOME="$HOME/.hermes" \
    BRIDGE_HOST="127.0.0.1" \
    BRIDGE_PORT="9131" \
    nohup "$BPYTHON" "$BPATH" --port 9131 --bind 127.0.0.1 >> "$LOGD/bridge.out" 2>&1 &
    echo $! > "$LOGD/bridge.pid";
    break;
  fi;
done;
# Ollama (:11434): runtime de los modelos LOCALES. El agente (hermes -z) lo
# consume por base_url 127.0.0.1:11434; sin él, un chat con modelo local falla
# con "API call failed: Connection error". Se arranca aquí (best-effort, sólo si
# está instalado y no responde ya) para que el modelo local quede listo al
# arrancar el agente. El wake-lock de arriba evita que Android lo congele.
if command -v ollama >/dev/null 2>&1 && ! curl -s --max-time 2 http://127.0.0.1:11434/ >/dev/null 2>&1; then
  export OLLAMA_MODELS="$HOME/.ollama/models";
  # Mantener el modelo residente entre turnos (chat oneshot): sin esto se recarga
  # en cada mensaje (30-45s en CPU de móvil). -1 = no descargar nunca.
  export OLLAMA_KEEP_ALIVE=-1;
  # Optimización CPU (fallback «por si acaso», sin GPU): flash-attention + KV en
  # q8_0 (mitad de memoria del caché, más rápido) y una sola secuencia en paralelo
  # (en un móvil no compensa repartir CPU). Hace el camino CPU usable cuando no
  # hay OlliteRT/GPU disponible.
  export OLLAMA_FLASH_ATTENTION=1;
  export OLLAMA_KV_CACHE_TYPE=q8_0;
  export OLLAMA_NUM_PARALLEL=1;
  # mkdir antes del redirect: si ~/.ollama no existe, `>>` falla y serve no corre.
  mkdir -p "$HOME/.ollama";
  nohup ollama serve >> "$HOME/.ollama/serve.log" 2>&1 &
fi;
# Servidor temporal de diagnóstico (:8645 = AgentRuntimeConsts.localDiagPort):
# sirve ~/.hermes durante 60 s para que la Consola pueda leer gateway.out y
# mostrar por qué falló el arranque. En subshell con `&` para no bloquear el
# RUN_COMMAND. Puerto literal: este es un raw string (sin interpolación Dart).
command -v python3 >/dev/null 2>&1 && {
  pkill -f "http.server 8645" 2>/dev/null;
  python3 -m http.server 8645 --bind 127.0.0.1 --directory "$HOME/.hermes" >/dev/null 2>&1 &
  DIAGPID=$!;
  sleep 60;
  kill $DIAGPID 2>/dev/null;
} &
echo STARTED
''';

  /// Wrapper de instalación de la RUTA AUTOMÁTICA AVANZADA (ADR-006): sirve su
  /// log por localhost (progreso en vivo) y ejecuta el procedimiento oficial
  /// como etapas separadas y observables. NO es la ruta principal (esa es el
  /// wizard manual); aquí asumimos un Termux ya operativo. Se lanza por
  /// RUN_COMMAND en background.
  ///
  /// Endurecimiento vs. versión previa: etapas reales (`pkg update`, paquetes
  /// base, descarga, install.sh, verificación) con `@@STAGE`; `timeout -k 10 -s
  /// TERM` (TERM y, si no muere en 10 s, KILL) en cada paso largo; fallback de
  /// URL del instalador registrado en el log. No ejecuta pasos interactivos
  /// (`termux-change-repo` y setup interactivo).
  static String get installWrapperCommand => r'''
set +e;
# Entorno Termux explícito. RUN_COMMAND lanza un shell NO interactivo y NO de
# login: su PATH puede no incluir el prefijo de Termux, así que `pkg`/`python3`/
# `curl` no se resuelven y la instalación falla en SILENCIO (a mano funciona
# porque el shell interactivo sí carga el entorno). Hardcode del prefijo del
# paquete base com.termux (ubicación fija del runtime de Termux).
export PREFIX=/data/data/com.termux/files/usr;
export HOME=/data/data/com.termux/files/home;
export PATH="$PREFIX/bin:$PATH";
export TMPDIR="$PREFIX/tmp"; mkdir -p "$TMPDIR" 2>/dev/null;
export TERMUX_PKG_NO_INTERNET_CHECK=1; export DEBIAN_FRONTEND=noninteractive;
# Compilación Rust EN SERIE durante la instalación/reparación. install.sh hace
# `pip install` de pydantic-core/cryptography/jiter (crates de Rust sin wheel para
# Android): en PARALELO agotan la RAM y el kernel mata el proceso (OOM) a mitad de
# pydantic-core → venv vacío + marcador ".update-incomplete" → en el siguiente
# arranque el dashboard reintenta el install y se vuelve a colgar. Forzar 1 job
# baja el pico de memoria y deja que la compilación termine. VERIFICADO en
# emulador (2.5 GB RAM): con esto pydantic-core compila; sin esto, OOM.
export CARGO_BUILD_JOBS=1; export MAKEFLAGS=-j1; export CARGO_PROFILE_RELEASE_DEBUG=0;
# VELOCIDAD: el grueso del tiempo se va compilando Rust con optimización completa
# (release opt-level=3). Para un agente local el coste de runtime de opt-level=0 es
# despreciable, pero el tiempo de compilación cae ~3-4x (pydantic-core: ~3-4 min →
# ~1 min, MEDIDO en emulador) y además usa MENOS RAM (la optimización es lo que más
# memoria consume). codegen-units alto = paralelismo de codegen dentro del crate
# sin lanzar más jobs de cargo (mantiene el pico de RAM bajo control).
export CARGO_PROFILE_RELEASE_OPT_LEVEL=0; export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16;
# Wake-lock durante la instalación (descarga de paquetes + pip, 10+ min): sin él
# Android congela Termux a mitad y la instalación se rompe en silencio. El
# arranque del agente re-adquiere el lock; se libera al parar el agente.
termux-wake-lock 2>/dev/null || true;
LOGD="$HOME/.hermes-install"; mkdir -p "$LOGD"; LOG="$LOGD/progress.log";
# Mata el servidor de progreso de una DESINSTALACIÓN reciente que aún ocupe el
# puerto 8643 (vive ~60 s tras desinstalar) y borra su log. Si no, el instalador
# no puede bindear 8643 y la app leería el log de la desinstalación —con su
# @@DONE— y "saltaría a listo" mostrando "eliminando binario". Por PID, NO con
# `pkill -f "http.server 8643"` (autokill: este script contiene esa cadena).
if [ -f "$HOME/.hermes-uninstall/srv.pid" ]; then
  kill -9 "$(cat "$HOME/.hermes-uninstall/srv.pid" 2>/dev/null)" 2>/dev/null;
fi;
rm -rf "$HOME/.hermes-uninstall" 2>/dev/null;
# Lock de instancia única: el retry de la app puede disparar un segundo
# RUN_COMMAND en paralelo y dos wrappers concurrentes se pelean por el lock de
# apt/dpkg (lo corrompen). Si ya hay una instancia VIVA (pid del lock responde a
# kill -0), salimos en silencio SIN truncar el log (no pisar su progreso).
LOCK="$LOGD/inst.pid";
if [ -f "$LOCK" ]; then
  OLD=$(cat "$LOCK" 2>/dev/null);
  if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
    exit 0;
  fi;
fi;
echo $$ > "$LOCK";
: > "$LOG";
log(){ echo "$@" >> "$LOG"; };
srv(){ python3 -m http.server 8643 --bind 127.0.0.1 --directory "$LOGD" >/dev/null 2>&1 & echo $! > "$LOGD/srv.pid"; };
# Timeout endurecido: TERM y, si no muere en 10 s, KILL al hijo directo. Evita
# dejar el paso colgado para siempre (la limpieza del árbol apt/dpkg restante la
# hace cancelInstallCommand con kill de grupo + pkill).
run(){ t="$1"; shift; timeout -k 10 -s TERM "$t" "$@"; };
# Espera (con tope) a que ningún gestor de paquetes esté ocupado: otro pkg/apt/
# dpkg corriendo deja el lock tomado y `pkg install` fallaría al instante.
pgrep_exact(){ pgrep -x "$1" >/dev/null 2>&1 || pgrep "^$1$" >/dev/null 2>&1; };
wait_pkg(){ i=0; while pgrep_exact pkg || pgrep_exact apt || pgrep_exact apt-get || pgrep_exact dpkg; do [ $i -eq 0 ] && log "Waiting for another package operation to finish..."; i=$((i+1)); [ $i -ge 60 ] && { log "@@NETSTALL otra operacion de paquetes sigue ocupada"; break; }; sleep 2; done; };
log "@@STAGE Preparando Termux";
# Diagnóstico de entorno: si el prefijo/PATH están mal, queda VISIBLE en el log
# en lugar de fallar mudo (la app pinta estas líneas en el mini-terminal).
log "PATH=$PATH";
command -v pkg >/dev/null 2>&1 && log "pkg found" || log "@@NETSTALL no encuentro pkg (entorno Termux incompleto)";
HERMES_BIN="$(command -v hermes 2>/dev/null)"; [ -z "$HERMES_BIN" ] && [ -x "$HOME/.hermes/hermes-agent/venv/bin/hermes" ] && HERMES_BIN="$HOME/.hermes/hermes-agent/venv/bin/hermes";
# REPARACIÓN (HERMES_REPAIR=1): el venv de Python quedó roto (p.ej. cryptography
# con ABI incompatible tras actualizar Python en Termux → "PyExc_Warning") y el
# instalador, al ver el binario, saldría con "ya instalado" sin arreglar nada.
# Borramos SÓLO el venv y olvidamos el binario para que el instalador RECONSTRUYA
# el entorno. Se conservan código del agente, config, SOUL, skills, perfiles y
# datos (todo vive FUERA de hermes-agent/venv).
if [ -n "$HERMES_REPAIR" ]; then
  log "@@STAGE Reparando entorno";
  log "Repair: rebuilding the Python environment (venv), keeping your data.";
  rm -rf "$HOME/.hermes/hermes-agent/venv" "$HOME/.hermes-agent/venv" 2>/dev/null;
  # Matar un dashboard/bridge vivo del intento anterior (por pidfile y por nombre
  # exacto; nunca pkill -f, que se autocorta en `bash -c`) ANTES de borrar nada,
  # para no reinstalar contra ficheros/puertos en uso.
  for pf in dashboard.pid bridge.pid gateway.pid; do
    [ -f "$HOME/.hermes/$pf" ] && kill "$(cat "$HOME/.hermes/$pf" 2>/dev/null)" 2>/dev/null;
  done;
  pkill -x hermes 2>/dev/null || true;
  # Limpiar la BASURA que, si queda, impide reparar/reinstalar bien:
  #  - .update-incomplete[.lock]: marcador de install interrumpido. Si persiste,
  #    el dashboard reintenta instalar el perfil completo de extras al arrancar y
  #    se vuelve a colgar/romper aunque el venv ya esté sano. El lock además
  #    bloquea cualquier recuperación durante 1 h.
  #  - *.pid obsoletos: pidfiles de un dashboard/bridge ya muerto que confunden el
  #    arranque y los reinicios.
  rm -f "$HOME/.hermes/hermes-agent/.update-incomplete" \
        "$HOME/.hermes/hermes-agent/.update-incomplete.lock" \
        "$HOME/.hermes-agent/.update-incomplete" \
        "$HOME/.hermes-agent/.update-incomplete.lock" \
        "$HOME/.hermes/dashboard.pid" "$HOME/.hermes/bridge.pid" \
        "$HOME/.hermes/gateway.pid" 2>/dev/null;
  HERMES_BIN="";
fi
# Inyecta instrucciones de formato de salida en el SOUL local (idempotente, por
# marcador) para que el agente local emita Markdown legible en el móvil. La capa
# de presentación de la app funciona igual sin esto; esto lleva de "bien" a
# "óptimo" sin que el usuario tenga que tocar el SOUL.
ensure_soul_fmt() {
  SF="$HOME/.hermes/SOUL.md";
  mkdir -p "$HOME/.hermes" 2>/dev/null;
  [ -f "$SF" ] || : > "$SF";
  if ! grep -q "hermes-console:format-v1" "$SF" 2>/dev/null; then
    cat >> "$SF" <<'SOULFMT'

<!-- hermes-console:format-v1 -->
## Output formatting (IMPORTANT - readability on mobile)

Always answer in clean, well-structured Markdown. A technical reader must grasp the structure in one second.

* Use `##` / `###` headings for every section, with a blank line before each.
* Use `-` bullet lists for ANY enumeration. Never write a list as plain consecutive lines.
* For key/value facts use bullets like `- **clave:** descripcion`.
* Put commands, file paths, env vars, services and code in backticks, or in fenced code blocks when multi-line.
* Use **bold** only for the single most important takeaway, not whole sentences.
* Separate ideas into short paragraphs with blank lines. Never produce a wall of text.
* Flag issues by starting the line with `Problema:`, `Advertencia:` or `Error:` so the client highlights them.
SOULFMT
    log "SOUL: formatting instructions added";
  fi
}
if [ -n "$HERMES_BIN" ]; then
  log "Hermes already installed: $($HERMES_BIN version 2>/dev/null || echo unknown-version)";
  ensure_soul_fmt;
  log "@@STAGE Verificando";
  log "@@EXIT 0"; log "@@DONE";
  command -v python3 >/dev/null 2>&1 && srv;
  sleep 30; exit 0;
fi
# Arranca el servidor de log cuanto antes (necesita python3) para que la app vea
# el progreso real, incluido cualquier error de red, sin ventanas ciegas.
if ! command -v python3 >/dev/null 2>&1; then
  log "Installing Python (for live progress)...";
  wait_pkg;
  run 150 pkg install -y python -o Dpkg::Options::="--force-confold" >> "$LOG" 2>&1 </dev/null || log "@@NETSTALL pkg install python";
fi;
command -v python3 >/dev/null 2>&1 && srv;
log "@@STAGE Actualizando Termux";
wait_pkg;
run 240 pkg update -y >> "$LOG" 2>&1 </dev/null; [ $? -eq 124 ] && log "@@NETSTALL pkg update supero el tiempo limite";
run 240 pkg upgrade -y -o Dpkg::Options::="--force-confold" >> "$LOG" 2>&1 </dev/null;
log "@@STAGE Instalando dependencias base";
# El skip exige también libjpeg y Pillow de Termux presentes: una instalación
# previa con un wrapper antiguo puede dejar git/rust/node pero NO esas piezas
# nativas; en ese caso re-ejecutamos pkg install (idempotente: los paquetes ya
# instalados se resuelven al instante) para colocarlas.
if command -v git >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1 && command -v node >/dev/null 2>&1 && ls "$PREFIX"/lib/libjpeg.so* >/dev/null 2>&1 && python3 - <<'PY' >/dev/null 2>&1
import PIL
PY
then
  log "Base dependencies already installed - skipping pkg install";
else
  wait_pkg;
  # python-pillow: Pillow precompilado de Termux. Evita que pip compile la wheel,
  # que falla en Pillow >=10.0.0,<10.1.0 por un bug de su MANIFEST.in ("no
  # previously-included directories found matching 'Tests/errors'"). Al estar ya
  # instalado como paquete del sistema, pip lo encuentra y no recompila.
  # libjpeg-turbo: su dependencia nativa de imagen.
  # -o Dpkg::Options::="--force-confold": en background NO hay terminal para
  # responder al prompt de "¿conservar/sobrescribir?" de dpkg ante archivos de
  # config modificados (openssl.cnf, sources.list); confold conserva el actual y
  # no bloquea la instalación.
  run 900 pkg install -y git python clang rust make pkg-config libffi openssl ca-certificates nodejs ripgrep ffmpeg curl libjpeg-turbo python-pillow python-cryptography -o Dpkg::Options::="--force-confold" >> "$LOG" 2>&1 </dev/null;
  [ $? -eq 124 ] && log "@@NETSTALL la instalacion de paquetes base supero el tiempo limite";
fi
log "@@STAGE Descargando instalador";
run 45 curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o "$LOGD/inst.sh" 2>>"$LOG";
if [ ! -s "$LOGD/inst.sh" ]; then
  log "Primary URL failed; trying raw.githubusercontent fallback (advanced)";
  run 45 curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh -o "$LOGD/inst.sh" 2>>"$LOG" || log "@@NETSTALL descarga del instalador";
fi;
log "@@STAGE Instalando agente";
wait_pkg;
if [ -d "$HOME/.hermes/hermes-agent/venv" ] && [ ! -x "$HOME/.hermes/hermes-agent/venv/bin/hermes" ]; then
  log "Cleaning up a partial venv from a previous failed install";
  rm -rf "$HOME/.hermes/hermes-agent/venv";
fi;
# Instalar SOLO el paquete base (`.`), no el perfil amplio `.[termux-all]`. El
# install.sh de upstream hace `pip install -e '.[termux-all]'`, que arrastra TODAS
# las integraciones de mensajería (telegram/dingtalk/slack/whatsapp…) que la
# Consola NO usa, cada una con sus crates de Rust → la instalación tardaba 20+ min
# y Android mataba el proceso a mitad ("tarda una barbaridad y se rompe"). La
# Consola solo necesita el core (dashboard + chat), que con `.` ya funciona
# (VERIFICADO: /api/status 200, chat OK). Reescribimos los perfiles del instalador
# a base para que compile lo mínimo (pydantic-core/cryptography/jiter) en ~minutos.
# Idempotente y best-effort: si upstream cambia el patrón, no rompe (el instalador
# seguiría con su perfil por defecto).
if [ -f "$LOGD/inst.sh" ]; then
  sed -i "s/'\.\[termux-all\]'/'.'/g; s/'\.\[termux\]'/'.'/g" "$LOGD/inst.sh" 2>/dev/null \
    && log "Installer trimmed to the base profile (no messaging integrations)";
fi;
run 1800 bash "$LOGD/inst.sh" --skip-setup >> "$LOG" 2>&1 </dev/null;
RC=$?;
[ $RC -eq 124 ] && log "@@NETSTALL la instalacion supero el tiempo limite";
if [ $RC -eq 0 ]; then
  mkdir -p "$HOME/.hermes" 2>/dev/null;
  if [ ! -f "$HOME/.hermes/config.yaml" ]; then
    cat > "$HOME/.hermes/config.yaml" <<'EOF'
model:
  provider: "custom"
  default: "qwen2.5:0.5b"
  base_url: "http://127.0.0.1:11434/v1"
  context_length: 65536
  ollama_num_ctx: 65536
security:
  allow_lazy_installs: false
EOF
    chmod 600 "$HOME/.hermes/config.yaml" 2>/dev/null;
    log "Minimal config created at ~/.hermes/config.yaml";
  fi;
  ensure_soul_fmt;
fi;
log "@@STAGE Verificando";
# Verificación REAL del entorno de Python, no del wrapper. `command -v hermes`
# acierta con el wrapper de Termux (/usr/bin/hermes) AUNQUE el venv esté vacío
# porque el pip se cortó por OOM: la app creería "instalado" y nunca levantaría el
# dashboard. Comprobamos lo que de verdad hace falta: que `hermes_cli` IMPORTE en
# el python del venv y que exista el ejecutable del venv. Si falla, degradamos RC
# y emitimos @@NETSTALL para que la app ofrezca reparar en vez de dar por buena
# una instalación a medias.
VVPY="$HOME/.hermes/hermes-agent/venv/bin/python3";
[ -x "$VVPY" ] || VVPY="$HOME/.hermes-agent/venv/bin/python3";
VHERMES="$HOME/.hermes/hermes-agent/venv/bin/hermes";
[ -x "$VHERMES" ] || VHERMES="$HOME/.hermes-agent/venv/bin/hermes";
if [ -x "$VVPY" ] && "$VVPY" -c 'import hermes_cli' >/dev/null 2>&1 && [ -x "$VHERMES" ]; then
  log "Verification OK: hermes_cli importable and venv executable present";
  # Instalación completa y sana: borrar cualquier marcador/lock de install
  # interrumpido para que el dashboard NO lance la recuperación pesada del perfil
  # completo de extras al arrancar (no hace falta: el entorno ya está bien).
  rm -f "$HOME/.hermes/hermes-agent/.update-incomplete" \
        "$HOME/.hermes/hermes-agent/.update-incomplete.lock" 2>/dev/null;
  ( "$VHERMES" version ) >> "$LOG" 2>&1 </dev/null || true;
else
  log "@@NETSTALL la instalacion quedo incompleta (hermes_cli no importa en el venv) — reintenta o usa Reparar";
  [ "$RC" = "0" ] && RC=1;
fi;
log "@@EXIT $RC"; log "@@DONE";
sleep 150;
[ -f "$LOGD/srv.pid" ] && kill "$(cat "$LOGD/srv.pid")" 2>/dev/null
''';

  /// Comando de REPARACIÓN del agente local. Reutiliza el instalador COMPLETO
  /// pero activando `HERMES_REPAIR=1`: borra el venv de Python roto (p.ej.
  /// `cryptography` con ABI incompatible tras actualizar Python → "PyExc_Warning")
  /// y lo RECONSTRUYE con el Python actual, CONSERVANDO código, config, SOUL,
  /// skills, perfiles y datos (todo vive fuera de `hermes-agent/venv`). Sirve su
  /// progreso por :8643 igual que el instalador, así la pantalla de instalación
  /// lo muestra en vivo. Es la alternativa a "comerse" una instalación nueva
  /// cuando el gateway falla por dependencias rotas.
  static String get repairWrapperCommand =>
      'export HERMES_REPAIR=1\n$installWrapperCommand';

  /// Despliega el script del Mobile Bridge en `~/.hermes/hermes_bridge.py` a
  /// partir de su contenido **gzip+base64** (el APK lo trae como asset
  /// `assets/bridge/hermes_bridge.py`). Se ejecuta como prefijo de
  /// [startAgentCommand] para que el arranque lo encuentre y lo levante.
  ///
  /// El payload va comprimido con gzip (lo descomprime `gzip -dc`, presente en
  /// el bootstrap base de Termux): sin comprimir, los ~121 KB de base64 dejaban
  /// el comando completo al borde del límite de `MAX_ARG_STRLEN` (128 KB por
  /// argumento de `execve`) y el RUN_COMMAND fallaba en silencio en el
  /// dispositivo real. Escribe a un `.tmp` y solo lo promueve si la
  /// descompresión produjo contenido (`-s`): si gzip falla, conserva el bridge
  /// previo en vez de dejar un archivo corrupto. Idempotente.
  static String deployBridgeCommand(String scriptB64) =>
      '''
export PREFIX=/data/data/com.termux/files/usr;
export HOME=/data/data/com.termux/files/home;
export PATH="\$PREFIX/bin:\$PATH";
mkdir -p "\$HOME/.hermes" 2>/dev/null;
printf '%s' '$scriptB64' | base64 -d | gzip -dc > "\$HOME/.hermes/hermes_bridge.py.tmp" 2>/dev/null;
[ -s "\$HOME/.hermes/hermes_bridge.py.tmp" ] && mv "\$HOME/.hermes/hermes_bridge.py.tmp" "\$HOME/.hermes/hermes_bridge.py" 2>/dev/null;
rm -f "\$HOME/.hermes/hermes_bridge.py.tmp" 2>/dev/null;
chmod 600 "\$HOME/.hermes/hermes_bridge.py" 2>/dev/null;
''';

  /// Comando de desinstalación del agente Hermes en Termux: para procesos,
  /// borra directorios conocidos, elimina el binario del PATH y verifica restos.
  /// Sirve su log por localhost (:8643) igual que el instalador, para que la
  /// pantalla de desinstalación muestre el progreso en vivo.
  /// @@EXIT 0 = limpio; @@EXIT 1 = quedan restos (se muestran con @@WARN).
  ///
  /// Fix del servidor HTTP: el instalador deja su python3 vivo con sleep 150 →
  /// Libera el puerto 8643 matando el servidor del instalador por PID (no por
  /// patrón): pkill -f puede bloquearse en procesos zombie del emulador.
  /// El servidor de progreso arranca ANTES de cualquier pkill para que Flutter
  /// vea el primer @@STAGE aunque los pasos de limpieza sean lentos.
  static String get uninstallCommand => r'''
set +e;
export PREFIX=/data/data/com.termux/files/usr;
export HOME=/data/data/com.termux/files/home;
export PATH="$PREFIX/bin:$PATH";
LOGD="$HOME/.hermes-uninstall"; mkdir -p "$LOGD";
LOG="$LOGD/progress.log"; : > "$LOG";
echo $$ > "$LOGD/inst.pid";
log(){ echo "$@" >> "$LOG"; };
# Liberar el puerto 8643 solo por PID guardado — pkill -f puede bloquearse
# porque el bash -c expone el script completo en su cmdline (contiene todos
# los patrones de pkill, causando que el script se autosignalice).
INSTSRV=$(cat "$HOME/.hermes-install/srv.pid" 2>/dev/null);
[ -n "$INSTSRV" ] && kill -9 "$INSTSRV" 2>/dev/null || true;
sleep 1;
# Servidor de progreso arranca ANTES del primer log para que Flutter lo vea.
command -v python3 >/dev/null 2>&1 && { python3 -m http.server 8643 --bind 127.0.0.1 --directory "$LOGD" >/dev/null 2>&1 & echo $! > "$LOGD/srv.pid"; };
log "@@STAGE parando";
kill_pidfile(){ f="$1"; name="$2"; pid=$(cat "$f" 2>/dev/null); if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; log "TERM $name pid=$pid"; fi; };
kill_pat(){ sig="$1"; pat="$2"; label="$3"; pgrep -f "$pat" 2>/dev/null | while read -r pid; do [ -z "$pid" ] && continue; [ "$pid" = "$$" ] && continue; [ "$pid" = "$PPID" ] && continue; [ -f "$LOGD/srv.pid" ] && [ "$pid" = "$(cat "$LOGD/srv.pid" 2>/dev/null)" ] && continue; kill "-$sig" "$pid" 2>/dev/null || true; log "$sig $label pid=$pid"; done; };
kill_ports(){ sig="$1"; shift; for port in "$@"; do for SS in ss /system/bin/ss; do command -v "$SS" >/dev/null 2>&1 || [ -x "$SS" ] || continue; "$SS" -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ p {print}' | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p'; break; done | sort -u | while read -r pid; do [ -z "$pid" ] && continue; [ "$pid" = "$$" ] && continue; [ "$pid" = "$PPID" ] && continue; [ -f "$LOGD/srv.pid" ] && [ "$pid" = "$(cat "$LOGD/srv.pid" 2>/dev/null)" ] && continue; kill "-$sig" "$pid" 2>/dev/null || true; log "$sig puerto $port pid=$pid"; done; done; };
kill_pidfile "$HOME/.hermes/dashboard.pid" dashboard;
kill_pidfile "$HOME/.hermes/gateway.pid" gateway;
kill_pidfile "$HOME/.hermes/bridge.pid" bridge;
kill_pat TERM "hermes dashboard" dashboard;
kill_pat TERM "dashboard --no-open" dashboard;
kill_pat TERM "hermes gateway" gateway;
kill_pat TERM "gateway run" gateway;
kill_pat TERM "hermes_bridge.py" bridge;
kill_pat TERM "$HOME/.hermes/hermes-agent" hermes-agent;
pkill -TERM -x hermes 2>/dev/null || true;
kill_ports TERM 9119 8642 9131 11434;
sleep 2;
kill_pidfile "$HOME/.hermes/dashboard.pid" dashboard;
kill_pidfile "$HOME/.hermes/gateway.pid" gateway;
kill_pidfile "$HOME/.hermes/bridge.pid" bridge;
kill_pat KILL "hermes dashboard" dashboard;
kill_pat KILL "dashboard --no-open" dashboard;
kill_pat KILL "hermes gateway" gateway;
kill_pat KILL "gateway run" gateway;
kill_pat KILL "hermes_bridge.py" bridge;
kill_pat KILL "$HOME/.hermes/hermes-agent" hermes-agent;
pkill -KILL -x hermes 2>/dev/null || true;
kill_ports KILL 9119 8642 9131 11434;
log "Hermes processes stopped";
log "@@STAGE borrando";
# Con los procesos ya muertos (no borrar archivos en uso). Orden requerido:
# binario/symlink del PATH, luego el directorio principal del agente, y por
# último el temporal de instalación (~/.hermes ANTES de ~/.hermes-install).
rm -f "$PREFIX/bin/hermes" 2>/dev/null; log "Removed binary: $PREFIX/bin/hermes";
rm -rf "$HOME/.hermes" 2>/dev/null; log "Removed: $HOME/.hermes";
rm -rf "$HOME/.hermes-install" 2>/dev/null; log "Removed: $HOME/.hermes-install";
log "@@STAGE verificando";
REMAIN=0;
[ -d "$HOME/.hermes" ] && { log "@@WARN ~/.hermes sigue presente (permiso denegado)"; REMAIN=1; };
[ -f "$PREFIX/bin/hermes" ] && { log "@@WARN $PREFIX/bin/hermes sigue presente"; REMAIN=1; };
command -v hermes >/dev/null 2>&1 && { log "@@WARN hermes aun en PATH (posible instalacion extra)"; REMAIN=1; };
pgrep -x hermes >/dev/null 2>&1 && { log "@@WARN proceso hermes aun activo"; REMAIN=1; };
for port in 9119 8642 9131 11434; do
  for SS in ss /system/bin/ss; do
    command -v "$SS" >/dev/null 2>&1 || [ -x "$SS" ] || continue;
    "$SS" -ltn 2>/dev/null | awk -v p=":$port" '$4 ~ p {found=1} END{exit found ? 0 : 1}' && { log "@@WARN puerto $port sigue ocupado"; REMAIN=1; };
    break;
  done;
done;
[ $REMAIN -eq 0 ] && log "Uninstall complete: nothing left behind." || log "Some items could not be removed.";
log "@@EXIT $REMAIN";
log "@@DONE";
sleep 60;
[ -f "$LOGD/srv.pid" ] && kill "$(cat "$LOGD/srv.pid")" 2>/dev/null;
rm -rf "$LOGD" 2>/dev/null
''';

  /// Cancela la desinstalación en curso. Best-effort vía RUN_COMMAND.
  static const String cancelUninstallCommand = r'''
P="$HOME/.hermes-uninstall";
if [ -f "$P/inst.pid" ]; then kill -- -"$(cat "$P/inst.pid")" 2>/dev/null || kill "$(cat "$P/inst.pid")" 2>/dev/null; fi
pkill -f "http.server 8643" 2>/dev/null;
echo "@@EXIT 130" >> "$P/progress.log" 2>/dev/null;
echo "@@DONE" >> "$P/progress.log" 2>/dev/null;
rm -rf "$P" 2>/dev/null;
echo CANCELADO
''';

  /// URL del log de desinstalación (mismo servidor y convención que el instalador).
  static const String uninstallProgressUrl =
      'http://$localHost:$localInstallPort/progress.log';

  /// Genera el comando bash para escribir `~/.hermes/config.yaml` directamente
  /// desde la app, evitando el setup interactivo. Los valores se
  /// codifican en base64 para que cualquier carácter especial en la API key sea
  /// transmitido de forma segura sin romper el shell.
  static String writeConfigCommand({
    required String provider,
    required String model,
    required String apiKey,
    String? baseUrl,
    bool isOAuth = false,
  }) {
    final b64m = model.isNotEmpty ? base64.encode(utf8.encode(model)) : '';
    // Providers OAuth: el token lo gestiona `hermes auth`, así que NO se escribe
    // ningún `.env`. La config sólo fija el `provider` (y el modelo si lo hay).
    final b64k = (isOAuth || apiKey.isEmpty)
        ? ''
        : base64.encode(utf8.encode(apiKey));
    final envName = isOAuth ? '' : envVarFor(provider);
    final configProvider = provider == 'ollama' ? 'custom' : provider;
    final normalizedBaseUrl = provider == 'ollama'
        ? ((baseUrl == null || baseUrl.isEmpty)
              ? 'http://127.0.0.1:11434/v1'
              : (baseUrl.endsWith('/v1') ? baseUrl : '$baseUrl/v1'))
        : baseUrl;
    final b64cp = base64.encode(utf8.encode(configProvider));
    final b64e = envName.isNotEmpty ? base64.encode(utf8.encode(envName)) : '';
    final b64nu = (normalizedBaseUrl != null && normalizedBaseUrl.isNotEmpty)
        ? base64.encode(utf8.encode(normalizedBaseUrl))
        : '';
    final parts = <String>[
      r'set +e;',
      r'export PREFIX=/data/data/com.termux/files/usr;',
      r'export HOME=/data/data/com.termux/files/home;',
      r'export PATH="$PREFIX/bin:$PATH";',
      r'mkdir -p "$HOME/.hermes";',
      r'CFG="$HOME/.hermes/config.yaml";',
      r'ENVF="$HOME/.hermes/.env";',
      "CPROV=\$(printf '%s' '$b64cp' | base64 -d);",
      if (b64m.isNotEmpty) "MODEL=\$(printf '%s' '$b64m' | base64 -d);",
      if (b64k.isNotEmpty) "KEY=\$(printf '%s' '$b64k' | base64 -d);",
      if (b64e.isNotEmpty) "ENVN=\$(printf '%s' '$b64e' | base64 -d);",
      if (b64nu.isNotEmpty) "BURL=\$(printf '%s' '$b64nu' | base64 -d);",
      r"""yq(){ printf "%s" "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/'; };""",
      r'{ printf "model:\n"; printf "  provider: %s\n" "$(yq "$CPROV")";',
      if (b64m.isNotEmpty) r'printf "  default: %s\n" "$(yq "$MODEL")";',
      if (b64nu.isNotEmpty) r'printf "  base_url: %s\n" "$(yq "$BURL")";',
      r'} > "$CFG";',
      if (b64k.isNotEmpty && b64e.isNotEmpty)
        r'touch "$ENVF"; grep -v "^${ENVN}=" "$ENVF" > "$ENVF.tmp" 2>/dev/null || true; mv "$ENVF.tmp" "$ENVF"; printf "%s=%s\n" "$ENVN" "$KEY" >> "$ENVF"; chmod 600 "$ENVF";',
      r'chmod 600 "$CFG";',
      r'echo CONFIG_DONE',
    ];
    return parts.join('\n');
  }

  /// Mapa provider (config.yaml `model.provider`) → variable de entorno donde
  /// el agente Hermes lee la API key (`~/.hermes/.env`). Fuente: docs oficiales
  /// `configuration`. Los casos cuyo nombre NO es `<PROVIDER>_API_KEY`
  /// (gemini→GOOGLE, huggingface→HF, kimi-coding→KIMI, azure-foundry→AZURE) son
  /// explícitos; el resto cae al patrón por defecto. Los providers OAuth no
  /// usan ninguna (token vía `hermes auth`).
  static String envVarFor(String provider) => switch (provider) {
    'anthropic' => 'ANTHROPIC_API_KEY',
    'openai' => 'OPENAI_API_KEY',
    'openrouter' => 'OPENROUTER_API_KEY',
    'gemini' => 'GOOGLE_API_KEY',
    'deepseek' => 'DEEPSEEK_API_KEY',
    'mistral' => 'MISTRAL_API_KEY',
    'minimax' => 'MINIMAX_API_KEY',
    'xai' => 'XAI_API_KEY',
    'kimi-coding' => 'KIMI_API_KEY',
    'huggingface' => 'HF_API_KEY',
    'azure-foundry' => 'AZURE_API_KEY',
    // Providers locales (Ollama→custom) no usan API key.
    'ollama' || 'custom' => '',
    _ =>
      '${provider.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]+'), '_')}_API_KEY',
  };

  /// Comando que lanza el flujo de autenticación OAuth de un provider dentro de
  /// Termux. Usa `hermes auth add <provider> --type oauth --no-browser`, que
  /// ejecuta el OAuth **device authorization flow** real e imprime la URL de
  /// verificación (con el código embebido) en stdout. Verificado en vivo contra
  /// el CLI instalado.
  ///
  /// IMPORTANTE: distinguir de `hermes auth` a secas (sin `add`), que abre un
  /// **menú interactivo** del pool de credenciales y se queda bloqueado en stdin
  /// sin emitir ninguna URL — era el bug. `hermes login` está RETIRADO en esta
  /// versión (imprime "command has been removed"). El id del catálogo se mapea al
  /// provider id del CLI (codex → openai-codex; nous, xai-oauth pasan igual).
  ///
  /// En lugar de abrir una terminal visible (poco fiable vía RUN_COMMAND), corre
  /// en segundo plano y **sirve su salida por localhost** (:8644) igual que el
  /// instalador con su log (:8643). La Consola sondea [oauthProgressUrl], extrae
  /// la URL `https://…` y la abre en el navegador del sistema, sin abrir Termux.
  /// Marca el inicio (@@OAUTH_START) y el final (@@OAUTH_DONE) para que la app
  /// detecte cuándo termina. El servidor de log se libera solo tras 30 s del
  /// final, o lo mata la siguiente invocación (kill por srv.pid).
  static String oauthCommand({required String provider}) {
    // Mapea el id del catálogo de la Consola al provider id del CLI.
    final authProvider = switch (provider) {
      'codex' => 'openai-codex',
      _ => provider, // nous, xai-oauth pasan tal cual
    };
    // --no-browser: imprime la URL en stdout en vez de intentar abrir un
    // navegador (que en Termux/RUN_COMMAND no existe). La capturamos del log.
    final cmd = 'hermes auth add $authProvider --type oauth --no-browser';
    return '''
export PREFIX=/data/data/com.termux/files/usr;
export HOME=/data/data/com.termux/files/home;
export PATH="\$HOME/.hermes-agent/venv/bin:\$HOME/.hermes/hermes-agent/venv/bin:\$PREFIX/bin:\$PATH";
# hermes es una CLI de Python: sin esto su stdout queda block-buffered al ir por
# un pipe (no-tty) y la URL de login no llega al log hasta que el buffer se
# llena (o nunca). PYTHONUNBUFFERED cubre el caso Python; stdbuf cubre libc.
export PYTHONUNBUFFERED=1;
cd "\$HOME/.hermes";
LOGD="\$HOME/.hermes-oauth";
mkdir -p "\$LOGD" "\$LOGD/bin";
LOGF="\$LOGD/oauth.log";
[ -f "\$LOGD/srv.pid" ] && kill "\$(cat "\$LOGD/srv.pid")" 2>/dev/null;
rm -f "\$LOGF";
echo "@@OAUTH_START" > "\$LOGF";
command -v python3 >/dev/null 2>&1 && { python3 -m http.server $localOAuthPort --bind 127.0.0.1 --directory "\$LOGD" >/dev/null 2>&1 & echo \$! > "\$LOGD/srv.pid"; };
# Wrappers de navegador: la CLI puede intentar ABRIR la URL (xdg-open /
# termux-open-url / …) en vez de imprimirla. Estos shims la interceptan y la
# escriben al log con el marcador @@OAUTH_URL, que la Consola captura aunque la
# URL nunca aparezca en stdout.
for BIN in xdg-open termux-open-url open sensible-browser www-browser x-www-browser; do
  printf '#!/data/data/com.termux/files/usr/bin/bash\\nURL="\${1:-}"\\n[ -n "\$URL" ] && echo "@@OAUTH_URL \$URL" >> "\$HOME/.hermes-oauth/oauth.log"\\n' > "\$LOGD/bin/\$BIN";
  chmod +x "\$LOGD/bin/\$BIN";
done;
export PATH="\$LOGD/bin:\$PATH";
# stdbuf -oL fuerza salida line-buffered como segunda capa (por si la CLI no es
# Python o ignora PYTHONUNBUFFERED).
( command -v stdbuf >/dev/null 2>&1 && stdbuf -oL $cmd 2>&1 || $cmd 2>&1 ) | while IFS= read -r line; do echo "\$line" >> "\$LOGF"; done;
echo "@@OAUTH_DONE" >> "\$LOGF";
sleep 30;
[ -f "\$LOGD/srv.pid" ] && kill "\$(cat "\$LOGD/srv.pid")" 2>/dev/null;
''';
  }

  /// Instala ollama en Termux con su **paquete nativo** (`pkg install ollama`),
  /// compilado para Termux/bionic y la arquitectura correcta (lo elige apt).
  ///
  /// NO se baja el binario suelto de GitHub: (1) Ollama ya no publica binario
  /// suelto, solo tarballs `.tar.zst` (la URL antigua daba 404 → un fichero de
  /// 9 bytes "Not Found"); (2) ese binario es glibc y NO corre en Termux
  /// (bionic). El paquete de Termux sí. Idempotente; limpia un stub roto previo.
  static String get installOllamaCommand => r'''
export PREFIX=/data/data/com.termux/files/usr;
export HOME=/data/data/com.termux/files/home;
export PATH="$PREFIX/bin:$PATH";
export TERMUX_PKG_NO_INTERNET_CHECK=1; export DEBIAN_FRONTEND=noninteractive;
DEST="$PREFIX/bin/ollama";
# Limpia un binario roto de instalaciones antiguas (el 404 "Not Found" pesaba
# 9 bytes); si no, "command -v ollama" daría un falso positivo.
if [ -f "$DEST" ] && [ "$(wc -c < "$DEST" 2>/dev/null || echo 0)" -lt 1000000 ]; then
  rm -f "$DEST";
fi;
LOG="$HOME/.hermes/ollama-install.out"; mkdir -p "$HOME/.hermes";
echo "[$(date)] instalando ollama..." > "$LOG";
if command -v ollama >/dev/null 2>&1; then echo "OLLAMA_YA_INSTALADO" | tee -a "$LOG"; exit 0; fi;
pkg install -y ollama -o Dpkg::Options::="--force-confold" >> "$LOG" 2>&1;
if command -v ollama >/dev/null 2>&1; then
  echo "OLLAMA_INSTALADO:$(ollama --version 2>/dev/null | head -1)" | tee -a "$LOG";
else
  echo "OLLAMA_ERROR" | tee -a "$LOG";
fi;
''';

  /// Inicia ollama serve en background (puerto 11434). Idempotente: comprueba
  /// si ya está activo antes de lanzar otro proceso.
  static const String startOllamaCommand = r'''
export PREFIX=/data/data/com.termux/files/usr;
export HOME=/data/data/com.termux/files/home;
export PATH="$PREFIX/bin:$PATH";
export OLLAMA_MODELS="$HOME/.ollama/models";
# El chat local es oneshot (`hermes -z` por mensaje). Sin esto, Ollama descarga
# el modelo de memoria entre turnos y lo RECARGA en cada mensaje (30-45s en CPU
# de móvil). -1 = mantenerlo residente indefinidamente → carga una vez, no por turno.
export OLLAMA_KEEP_ALIVE=-1;
# El directorio debe existir ANTES de redirigir la salida de serve a su log: en
# un dispositivo recién instalado ~/.ollama no existe todavía (ollama lo crea al
# correr, pero la redirección `>>` la hace la shell ANTES de ejecutar el binario;
# si el directorio falta, falla con "No such file or directory" y ollama NUNCA
# arranca). Era la causa de "ollama nunca llega a levantar" en dispositivos reales.
mkdir -p "$HOME/.ollama";
# Wake-lock: la inferencia es CPU-intensiva; sin él Android congela ollama y la
# respuesta nunca llega (timeout). Best-effort.
termux-wake-lock 2>/dev/null || true;
if curl -s --max-time 2 http://127.0.0.1:11434/ >/dev/null 2>&1; then
  echo "OLLAMA_YA_ACTIVO"; exit 0;
fi;
nohup ollama serve >> "$HOME/.ollama/serve.log" 2>&1 &
sleep 3;
curl -s --max-time 5 http://127.0.0.1:11434/ >/dev/null 2>&1 && echo "OLLAMA_INICIADO" || echo "OLLAMA_ERROR";
''';

  /// Para el proceso ollama serve en Termux. Envía TERM primero (graceful) y,
  /// si no muere en 2 s, KILL. Best-effort: nunca falla aunque no esté activo.
  static String get stopOllamaCommand =>
      'pkill -TERM ollama 2>/dev/null; sleep 2; pkill -KILL ollama 2>/dev/null || true';

  /// Wipe TOTAL de Ollama: para el daemon, borra los modelos (`~/.ollama`, que
  /// pueden ser varios GB) y desinstala el paquete. Opcional en la
  /// desinstalación (por defecto se conservan para no re-descargar). Best-effort.
  static String get removeOllamaModelsCommand => r'''
export PREFIX=/data/data/com.termux/files/usr;
export HOME=/data/data/com.termux/files/home;
export PATH="$PREFIX/bin:$PATH";
export DEBIAN_FRONTEND=noninteractive;
pkill -KILL ollama 2>/dev/null || true;
rm -rf "$HOME/.ollama" 2>/dev/null;
pkg uninstall -y ollama >/dev/null 2>&1 || true;
echo OLLAMA_WIPED
''';

  /// Acepta identificadores de modelo ollama: letras, números, `.`, `-`, `_`, `/`, `:`, `@`.
  /// Rechaza todo lo que pueda inyectar comandos en la shell.
  static final _modelNameRe = RegExp(r'^[A-Za-z0-9_./:@-]+$');
  static bool isValidModelName(String model) {
    final m = model.trim();
    return m.isNotEmpty && m.length <= 200 && _modelNameRe.hasMatch(m);
  }

  /// Descarga un modelo de ollama (ej: "phi3:mini", "qwen2.5:0.5b").
  /// Requiere que ollama serve ya esté activo en :11434.
  static String ollamaPullCommand(String model) =>
      '''
export PREFIX=/data/data/com.termux/files/usr;
export HOME=/data/data/com.termux/files/home;
export PATH="\$PREFIX/bin:\$PATH";
export OLLAMA_MODELS="\$HOME/.ollama/models";
ollama pull $model 2>&1;
''';
}
