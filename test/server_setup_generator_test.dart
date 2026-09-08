import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/server_setup_generator.dart';
import 'package:hermes_android/core/services/pairing_link.dart';

class _ProbeResponse {
  final int status;
  final Object body;

  const _ProbeResponse(this.body, {this.status = HttpStatus.ok});
}

String _extractInstalledProbe(String setupScript) {
  const opener = r'''cat > "$PROBE" <<'PY'
''';
  const closer = r'''
PY
chmod 700 "$PROBE"''';
  final start = setupScript.indexOf(opener);
  if (start < 0) throw StateError('embedded service probe opener not found');
  final bodyStart = start + opener.length;
  final end = setupScript.indexOf(closer, bodyStart);
  if (end < 0) throw StateError('embedded service probe closer not found');
  return setupScript.substring(bodyStart, end);
}

Future<HttpServer> _startProbeServer(
  FutureOr<_ProbeResponse> Function(HttpRequest request) responder,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final response = await responder(request);
    request.response
      ..statusCode = response.status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(response.body));
    await request.response.close();
  });
  return server;
}

Future<ProcessResult> _runInstalledProbe(
  File probe,
  String kind,
  String base,
  String token, {
  String expectedVersion = '',
  bool phoneFacing = false,
}) {
  return Process.run('python3', [
    probe.path,
    kind,
    base,
    token,
    expectedVersion,
    if (phoneFacing) 'phone',
  ]);
}

void main() {
  group('ServerSetupGenerator.agentPrompt', () {
    final p = ServerSetupGenerator.agentPrompt;

    test('la ayuda al agente es solo lectura y no cruza secretos al LLM', () {
      for (final platform in ServerHostPlatform.values) {
        final prompt = ServerSetupGenerator.agentPromptFor(platform);
        final low = prompt.toLowerCase();

        expect(low, contains('read-only'));
        expect(low, contains('trusted terminal'));
        expect(low, contains('do not run'));
        expect(low, contains('do not retrieve'));
        expect(prompt, isNot(contains(ServerSetupGenerator.setupScriptUrl)));
        expect(
          prompt,
          isNot(contains(ServerSetupGenerator.windowsSetupScriptUrl)),
        );
        expect(prompt, isNot(contains('curl ')));
        expect(prompt, isNot(contains('powershell.exe')));
        expect(prompt, isNot(contains(' | sh')));
        expect(prompt, isNot(contains('| iex')));
        expect(prompt, isNot(contains(ServerSetupGenerator.pairScriptUrl)));
        expect(
          prompt,
          isNot(contains(ServerSetupGenerator.windowsPairScriptUrl)),
        );
        expect(low, isNot(contains('reply only')));
        expect(low, isNot(contains('hermes://pair')));
        expect(low, isNot(contains('idempotent')));
        expect(low, isNot(contains('safe on')));
      }
    });

    test('limita la ayuda a contexto general sin autorizar cambios', () {
      final low = p.toLowerCase();
      expect(low, contains('high level'));
      expect(low, contains('do not install'));
      expect(low, contains('do not treat this request as authorization'));
      expect(low, contains('run all setup commands themselves'));
    });

    test('cabe en un mensaje de Telegram (límite ~4096 chars)', () {
      // El prompt viejo llevaba el bridge embebido (~60KB) y no cabía en
      // ningún canal de chat; el nuevo debe seguir siendo corto.
      expect(p.length, lessThan(2000));
    });

    test('prohíbe leer datos del servidor o pedirlos por chat', () {
      final low = p.toLowerCase();
      expect(low, contains('token'));
      expect(low, contains('environment variables'));
      expect(low, contains('configuration files'));
      expect(low, contains('never ask the owner to paste'));
      expect(low, contains('do not construct or return pairing data'));
    });

    test('mantiene la salida de emparejado fuera del chat', () {
      final low = p.toLowerCase();
      expect(low, contains('between that terminal and hermes console'));
      expect(low, isNot(contains('reply with')));
      expect(low, isNot(contains('plain text')));
    });

    test('no contiene secretos del repo', () {
      expect(p, isNot(contains('API_SERVER_KEY=')));
      expect(p.toLowerCase(), isNot(contains('-----begin')));
    });
  });

  group('ServerSetupGenerator.curlCommand', () {
    test('una línea corta y auditable que apunta al script público', () {
      const c = ServerSetupGenerator.curlCommand;
      expect(c, 'curl -fsSL ${ServerSetupGenerator.setupScriptUrl} | sh');
      expect(c.contains('\n'), isFalse);
      // MAX_CANON (~4096) truncaba el blob de 60KB al pegarlo (U-23); el curl
      // corto no se acerca ni de lejos.
      expect(c.length, lessThan(200));
      expect(
        ServerSetupGenerator.setupScriptUrl,
        startsWith('https://raw.githubusercontent.com/'),
      );
    });

    test('ofrece comandos nativos separados por plataforma', () {
      expect(
        ServerSetupGenerator.setupCommandFor(ServerHostPlatform.linux),
        ServerSetupGenerator.curlCommand,
      );
      expect(
        ServerSetupGenerator.setupCommandFor(ServerHostPlatform.macos),
        ServerSetupGenerator.curlCommand,
      );
      expect(
        ServerSetupGenerator.setupCommandFor(ServerHostPlatform.windows),
        ServerSetupGenerator.powershellCommand,
      );
      expect(
        ServerSetupGenerator.powershellCommand,
        startsWith('irm https://'),
      );
      expect(ServerSetupGenerator.powershellCommand, endsWith('| iex'));
      expect(
        ServerSetupGenerator.powershellCommand,
        contains('hermes-mobile-setup.ps1'),
      );
      expect(
        ServerSetupGenerator.pairCommandFor(ServerHostPlatform.windows),
        contains('hermes-pair.ps1'),
      );
      final windowsPrompt = ServerSetupGenerator.agentPromptFor(
        ServerHostPlatform.windows,
      );
      expect(windowsPrompt, contains('Windows'));
      expect(
        windowsPrompt,
        isNot(contains(ServerSetupGenerator.powershellShellCommand)),
      );
    });
  });

  // El comando curl ejecuta scripts/hermes-mobile-setup.sh (la copia publicada
  // en el repo hermes-setup). Estas garantías vivían en el manualCommand
  // embebido (U-12..U-20) y ahora se auditan sobre la fuente del script.
  group('hermes-mobile-setup.sh (script alojado)', () {
    final c = File('scripts/hermes-mobile-setup.sh').readAsStringSync();

    test('genera token si falta (no aborta)', () {
      expect(c, contains('API_SERVER_KEY'));
      // Debe haber una rama que crea la clave si está vacía.
      expect(c, contains('secrets.token_hex'));
    });

    test(
      'todo-en-uno: instala Hermes si falta y arranca el gateway (U-12/U-14)',
      () {
        // Servidor virgen: el comando instala el agente y levanta el gateway
        // 8642, no solo el bridge. Sin esto, un recién llegado sin Hermes
        // no tenía por dónde empezar.
        expect(c, contains('install.sh'));
        expect(
          c,
          contains('from hermes_cli.gateway import generate_systemd_unit'),
        );
        expect(c, isNot(contains('gateway install --force')));
        expect(c, isNot(contains('install_systemd_unit gateway')));
        expect(c, contains('gateway run'));
        expect(c, contains('8642'));
        // U-17 (spec 028): también el dashboard (9119), sin el la app se queda
        // muy limitada (gestión de proveedores/keys/sesiones).
        expect(c, contains('install_systemd_unit dashboard'));
        expect(c, contains(r'dashboard --host "$BIND_HOST"'));
        expect(c, contains('9119'));
      },
    );

    test(
      'activa linger sin PolicyKit antes de usar systemctl --user (U-19)',
      () {
        final linger = c.indexOf('sudo -n loginctl enable-linger');
        final firstSystemctl = c.indexOf('systemctl --user daemon-reload');
        expect(c, contains('loginctl show-user'));
        expect(linger, greaterThanOrEqualTo(0));
        expect(firstSystemctl, greaterThanOrEqualTo(0));
        expect(
          linger,
          lessThan(firstSystemctl),
          reason: 'enable-linger debe preceder al primer systemctl --user',
        );
        expect(
          c,
          isNot(contains(r'&& loginctl enable-linger "$(id -un)"')),
          reason: 'no debe disparar una elevacion PolicyKit interactiva',
        );
        expect(c, contains('services may stop after logout'));
      },
    );

    test('conserva el bind aunque Hermes regenere su unidad systemd', () {
      expect(
        c,
        contains(
          r'SYSTEMD_GATEWAY_DROPIN_DIR="$SYSTEMD_USER_DIR/hermes-gateway.service.d"',
        ),
      );
      expect(c, contains('10-hermes-console-network.conf'));
      expect(c, contains(r'Environment="API_SERVER_HOST=$BIND_HOST"'));
      expect(c, contains(r'Environment="API_SERVER_PORT=8642"'));
      expect(c, contains('SYSTEMD_GATEWAY_PENDING=1'));
      expect(c, contains('rollback_pending_systemd_gateway'));
      final canonical = c.indexOf(
        'from hermes_cli.gateway import generate_systemd_unit',
      );
      final dropIn = c.indexOf('10-hermes-console-network.conf', canonical);
      final verify = c.indexOf('systemd-analyze --user verify');
      expect(canonical, greaterThanOrEqualTo(0));
      expect(dropIn, greaterThan(canonical));
      expect(verify, greaterThan(dropIn));
    });

    test('valida las tres unidades systemd antes de arrancarlas', () {
      expect(c, contains(r'ExecStart=$runner'));
      expect(c, contains(r'WorkingDirectory=$HH'));
      expect(c, isNot(contains(r'ExecStart="$runner"')));
      expect(c, isNot(contains(r'WorkingDirectory="$HH"')));
      expect(c, contains('systemd-analyze --user verify'));
      expect(c, contains('existing units were not replaced'));
      final verify = c.indexOf('systemd-analyze --user verify');
      final reload = c.lastIndexOf('systemctl --user daemon-reload');
      expect(verify, greaterThanOrEqualTo(0));
      expect(reload, greaterThan(verify));
    });

    test('pinta un QR del enlace, no solo texto (U-20)', () {
      expect(c, contains('qrencode'));
      expect(c.toLowerCase(), contains('qrcode'));
      expect(c, contains('SCAN THIS QR'));
      expect(c, contains('QR_RENDERED'));
      expect(c, contains('QR renderer could not be prepared'));
    });

    test('muestra progreso real por etapas y un resumen final', () {
      expect(c, contains('SETUP_TOTAL=7'));
      expect(c, contains('setup_step "Checking Hermes Agent"'));
      expect(c, contains('setup_step "Verifying private phone access"'));
      expect(c, contains('setup_step "Generating pairing QR and summary"'));
      expect(c, contains('Setup summary:'));
      expect(c, contains(r'Service manager: $SERVICE_MANAGER'));
    });

    test('elige una IP privada alcanzable y bloquea loopback', () {
      final low = c.toLowerCase();
      expect(low, contains('tailscale'));
      // Los rangos van escapados para grep -E (192\.168\. etc.).
      expect(
        c,
        anyOf(contains(r'192\.168'), contains(r'10\.'), contains(r'172\.')),
      );
      expect(low, contains('loopback is not reachable from a phone'));
    });

    test('cubre mesh CGNAT y nunca genera un QR HTTP público', () {
      // Rango CGNAT 100.64.0.0/10, donde viven las IPs de las redes mesh.
      expect(c, contains(r'100\.(6[4-9]'));
      expect(c, contains('public HTTP is blocked'));
      expect(c, contains('HERMES_PAIR_SCHEME=https'));
      expect(c, isNot(contains('public internet is unsafe')));
    });

    test('emite un enlace hermes://pair', () {
      expect(c, contains('"hermes://pair?"'));
      expect(c, contains('"host": host'));
    });

    test('incluye el script del bridge reutilizado', () {
      expect(c, contains('hermes-bridge'));
    });

    test('verifica y sustituye el bridge de forma atómica', () {
      expect(c, contains('bridge-release.json'));
      expect(c, contains('sha256'));
      expect(c, contains('py_compile'));
      expect(c, contains(r'NEW="$TARGET.new"'));
      expect(c, contains(r'BACKUP="$TARGET.rollback"'));
      expect(c, contains(r'mv "$BACKUP" "$TARGET"'));
    });

    test('el QR incluye Dashboard, Bridge y su token explícito', () {
      expect(c, contains(':9119'));
      expect(c, contains('"dashboard": dashboard'));
      expect(c, contains('"bridge": bridge'));
      expect(c, contains('"bridge_token": token'));
    });

    test('instalación fresca fija layout estable incluso como root', () {
      expect(c, contains(r'--hermes-home "$HH" --dir "$HH/hermes-agent"'));
      expect(c, contains(r'realpath "$HB"'));
      expect(c, contains('PYTHON_BIN=%s'));
    });

    test('verifica identidad, auth y self-update antes de mostrar el QR', () {
      for (final endpoint in [
        '/health',
        '/api/sessions',
        '/bridge/health',
        '/bridge/capabilities',
        '/api/status',
      ]) {
        expect(c, contains(endpoint));
      }
      expect(c, contains('operations.get("self_update") is not True'));
      expect(c, contains('PAIRING_SCHEMA=1'));
      final phoneGate = c.lastIndexOf('wait_probe dashboard');
      final qr = c.indexOf('SCAN THIS QR');
      expect(phoneGate, greaterThanOrEqualTo(0));
      expect(qr, greaterThan(phoneGate));
    });

    test('redirige WSL normal a PowerShell y no mata procesos ajenos', () {
      expect(c, contains('WSL detected'));
      expect(c, contains('HERMES_PAIR_HOST'));
      expect(c, contains('gateway run --replace'));
      expect(c, contains('Refusing to stop PID'));
      expect(c, isNot(contains('\npkill ')));
    });

    test('soporta systemd, launchd y fallback Unix sin mutar Windows', () {
      expect(c, contains('SERVICE_MANAGER="systemd"'));
      expect(c, contains('SERVICE_MANAGER="launchd"'));
      expect(c, contains('SERVICE_MANAGER="portable"'));
      expect(c, contains('launchctl bootstrap'));
      expect(c, contains('Windows native detected'));
      expect(c, contains('hermes-mobile-setup.ps1'));
    });

    test('sudo interactivo funciona aunque el setup llegue por un pipe', () {
      expect(c, contains('sudo -v </dev/tty'));
      expect(c, contains('SUDO_READY=1'));
      expect(c, contains('private firewall rule'));
    });
  });

  group('verificador funcional instalado por hermes-mobile-setup.sh', () {
    late Directory temp;
    late File probe;

    setUpAll(() {
      temp = Directory.systemTemp.createTempSync('hermes-service-probe-test-');
      final setup = File('scripts/hermes-mobile-setup.sh').readAsStringSync();
      probe = File('${temp.path}/hermes-service-probe.py')
        ..writeAsStringSync(_extractInstalledProbe(setup));
    });

    tearDownAll(() => temp.deleteSync(recursive: true));

    test(
      'acepta Gateway, Bridge y Dashboard con sus contratos reales',
      () async {
        const token = 'verified-test-token';
        final server = await _startProbeServer((request) {
          final authorized =
              request.headers.value(HttpHeaders.authorizationHeader) ==
              'Bearer $token';
          switch (request.uri.path) {
            case '/health':
              return const _ProbeResponse({
                'status': 'ok',
                'platform': 'hermes-agent',
              });
            case '/api/sessions':
              return authorized
                  ? const _ProbeResponse({'object': 'list', 'data': []})
                  : const _ProbeResponse({
                      'error': 'unauthorized',
                    }, status: HttpStatus.unauthorized);
            case '/bridge/health':
              return const _ProbeResponse({
                'status': 'ok',
                'version': '1.18.0',
              });
            case '/bridge/capabilities':
              return authorized
                  ? const _ProbeResponse({
                      'object': 'hermes.bridge.capabilities',
                      'scopes': ['read', 'config'],
                      'operations': {'self_update': true},
                    })
                  : const _ProbeResponse({
                      'error': 'unauthorized',
                    }, status: HttpStatus.unauthorized);
            case '/api/status':
              return const _ProbeResponse({
                'version': '0.8.0',
                'gateway_running': true,
              });
            default:
              return const _ProbeResponse({
                'error': 'not_found',
              }, status: HttpStatus.notFound);
          }
        });
        addTearDown(() => server.close(force: true));
        final base = 'http://127.0.0.1:${server.port}';

        final gateway = await _runInstalledProbe(probe, 'gateway', base, token);
        final bridge = await _runInstalledProbe(
          probe,
          'bridge',
          base,
          token,
          expectedVersion: '1.18.0',
        );
        final dashboard = await _runInstalledProbe(
          probe,
          'dashboard',
          base,
          token,
        );

        expect(gateway.exitCode, 0, reason: gateway.stderr.toString());
        expect(bridge.exitCode, 0, reason: bridge.stderr.toString());
        expect(dashboard.exitCode, 0, reason: dashboard.stderr.toString());
      },
    );

    test(
      'rechaza un puerto ocupado por un servicio que no es Hermes',
      () async {
        final server = await _startProbeServer(
          (_) => const _ProbeResponse({'status': 'ok'}),
        );
        addTearDown(() => server.close(force: true));

        final result = await _runInstalledProbe(
          probe,
          'gateway',
          'http://127.0.0.1:${server.port}',
          'token',
        );

        expect(result.exitCode, isNot(0));
        expect(result.stderr.toString(), contains('not Hermes Gateway'));
      },
    );

    test('rechaza autenticación Gateway inválida', () async {
      final server = await _startProbeServer((request) {
        if (request.uri.path == '/health') {
          return const _ProbeResponse({
            'status': 'ok',
            'platform': 'hermes-agent',
          });
        }
        return const _ProbeResponse({
          'error': 'unauthorized',
        }, status: HttpStatus.unauthorized);
      });
      addTearDown(() => server.close(force: true));

      final result = await _runInstalledProbe(
        probe,
        'gateway',
        'http://127.0.0.1:${server.port}',
        'wrong-token',
      );

      expect(result.exitCode, isNot(0));
      expect(result.stderr.toString(), contains('HTTP 401'));
    });

    test('rechaza un Bridge sin self-update/config', () async {
      final server = await _startProbeServer((request) {
        if (request.uri.path == '/bridge/health') {
          return const _ProbeResponse({'status': 'ok', 'version': '1.18.0'});
        }
        return const _ProbeResponse({
          'object': 'hermes.bridge.capabilities',
          'scopes': ['read'],
          'operations': {'self_update': false},
        });
      });
      addTearDown(() => server.close(force: true));

      final result = await _runInstalledProbe(
        probe,
        'bridge',
        'http://127.0.0.1:${server.port}',
        'token',
        expectedVersion: '1.18.0',
      );

      expect(result.exitCode, isNot(0));
      expect(result.stderr.toString(), contains('self-update capability'));
    });

    test('rechaza Dashboard que informa Gateway detenido', () async {
      final server = await _startProbeServer(
        (_) => const _ProbeResponse({
          'version': '0.8.0',
          'gateway_running': false,
        }),
      );
      addTearDown(() => server.close(force: true));

      final result = await _runInstalledProbe(
        probe,
        'dashboard',
        'http://127.0.0.1:${server.port}',
        'token',
      );

      expect(result.exitCode, isNot(0));
      expect(result.stderr.toString(), contains('Gateway is stopped'));
    });

    test('bloquea HTTP público antes de transmitir el token', () async {
      final result = await _runInstalledProbe(
        probe,
        'gateway',
        'http://203.0.113.10:8642',
        'must-not-leave-host',
        phoneFacing: true,
      );

      expect(result.exitCode, isNot(0));
      expect(result.stderr.toString(), contains('public HTTP is blocked'));
    });
  });

  group('hermes-mobile-setup.ps1 (Windows nativo)', () {
    final c = File('scripts/hermes-mobile-setup.ps1').readAsStringSync();

    test('usa el instalador oficial y el layout nativo de Hermes', () {
      expect(c, contains('hermes-agent.nousresearch.com/install.ps1'));
      expect(c, contains(r'$env:LOCALAPPDATA'));
      expect(c, contains(r'venv\Scripts\python.exe'));
      expect(c, contains(r'venv\Scripts\hermes.exe'));
    });

    test('permite una instalación oficial limpia sin cortarla a los 180s', () {
      expect(c, contains(r'$script:HermesInstallTimeoutSeconds = 900'));
      expect(c, contains(r'$script:HermesInstallTimeoutSeconds `'));
      expect(c, contains('can take several minutes on a clean Windows host'));
      expect(
        c,
        isNot(
          contains(
            'Invoke-HiddenProcess (Get-PowerShellExecutable) '
            r'$arguments 180',
          ),
        ),
      );
    });

    test('reutiliza el dist real y tolera el primer build del Dashboard', () {
      expect(c, contains(r'hermes-agent\hermes_cli\web_dist\index.html'));
      expect(c, isNot(contains(r'hermes-agent\web\dist\index.html')));
      expect(
        c,
        contains(
          'Wait-HermesService "dashboard" '
          '"http://127.0.0.1:9119" \$ApiKey 240',
        ),
      );
      expect(c, contains('command = command & " --skip-build"'));
      expect(c, contains('Test-HermesTaskRunning'));
      expect(
        c,
        contains('Existing Dashboard startup/build is still running; waiting'),
      );
      expect(c, isNot(contains(r'$dashboardMustRestart')));
    });

    test('verifica manifest, tamano, SHA-256, version y compilacion', () {
      expect(c, contains('bridge-release.json'));
      expect(c, contains('Get-FileHash'));
      expect(c, contains('Bridge release integrity check failed'));
      expect(c, contains('VERSION\\s*='));
      expect(c, contains('-m py_compile'));
      expect(c, contains('[IO.File]::Replace'));
    });

    test(
      'persiste procesos por usuario sin exponer el token en argumentos',
      () {
        expect(c, contains('Register-ScheduledTask'));
        expect(c, contains('HermesConsole-Gateway'));
        expect(c, contains('HermesConsole-Dashboard'));
        expect(c, contains('HermesConsole-MobileBridge'));
        expect(c, contains('HermesConsole-Restart-Dashboard'));
        expect(c, contains('HermesConsole-Restart-MobileBridge'));
        expect(c, contains('Get-ApiKey'));
        expect(c, isNot(contains(r'BRIDGE_TOKEN=$ApiKey')));
      },
    );

    test('el firewall solo abre TCP en perfiles privados', () {
      expect(c, contains('New-NetFirewallRule'));
      expect(c, contains('-Profile Private'));
      expect(c, contains('8642, 9119, 9131'));
      expect(c, contains('-RemoteAddress LocalSubnet'));
      expect(c, contains('100.64.0.0/10'));
      expect(c, contains('Test-RestrictedFirewallRule'));
    });

    test(
      'eleva solo la regla de Firewall y conserva la cuenta del usuario',
      () {
        expect(c, contains('Install-RestrictedFirewallRuleElevated'));
        expect(c, contains('-Verb RunAs'));
        expect(c, contains('original user'));
        expect(c, contains('LOCALAPPDATA'));
      },
    );

    test('comprueba servicios reales y URL del teléfono antes del QR', () {
      for (final endpoint in [
        '/health',
        '/api/sessions',
        '/bridge/health',
        '/bridge/capabilities',
        '/api/status',
      ]) {
        expect(c, contains(endpoint));
      }
      expect(c, contains('operations.self_update'));
      expect(c, contains('-PhoneFacing'));
      expect(c, contains('schema = 1'));
      expect(c, contains('gateway run --replace'));
      expect(c, isNot(contains('function Test-Port')));
      final phoneGate = c.lastIndexOf('Wait-HermesService "dashboard"');
      final qr = c.lastIndexOf(r'Write-PairingQr $PythonExe $link');
      expect(phoneGate, greaterThanOrEqualTo(0));
      expect(qr, greaterThan(phoneGate));
      expect(c, isNot(contains(r'Write-Host "Link: $link"')));
      expect(c, isNot(contains('SCAN THIS QR')));
    });

    test('integra el lifecycle seguro e idempotente del tester', () {
      expect(c, contains(r'[switch]$AuditOnly'));
      expect(c, contains('Invoke-SetupInventory'));
      expect(c, contains('safe-setup-audit.jsonl'));
      expect(c, contains('Protect-AuditText'));
      expect(c, contains('Get-PortOwner'));
      expect(c, contains('TaskDefinitionsChanged'));
      expect(c, contains('Already healthy and authenticated'));
      expect(c, contains(r'Version $($manifest.version), size, SHA-256'));
    });

    test('publica progreso por fases y resumen sin revelar el enlace', () {
      expect(c, contains(r'$script:SetupPhaseTotal = 7'));
      expect(
        c,
        contains('Write-SetupPhase "Checking Hermes Agent and Python"'),
      );
      expect(c, contains('Write-SetupPhase "Verifying private phone access"'));
      expect(c, contains('Write-Audit "Setup summary" "OK"'));
      expect(c, contains('Private phone access verified'));
      expect(c, isNot(contains(r'Write-Host "Link: $link"')));
    });

    test('la auditoría valida contratos exactos sin registrar comandos', () {
      expect(c, contains('Test-RunnerContract'));
      expect(c, contains(r'$action.Arguments -eq $expectedArguments'));
      expect(c, contains('Verified current pairing record'));
      expect(c, contains('Remove legacy duplicate'));
      expect(c, isNot(contains(r'$owner.Command')));
      expect(c, isNot(contains(r'$process.CommandLine')));
    });

    test('clasifica MagicDNS de Tailscale como red mesh', () {
      expect(c, contains('.EndsWith(".ts.net"'));
      expect(c, contains(r'Where-Object { Test-Cgnat $_.IPAddressToString }'));
    });

    test('los servicios persistentes son VBS ocultos y conservan Node', () {
      expect(c, contains('System32\\wscript.exe'));
      expect(c, contains('//B //NoLogo'));
      expect(c, contains('sh.Run(command, 0, True)'));
      expect(c, contains('%ProgramFiles%\\nodejs'));
      expect(c, contains('--skip-build'));
      expect(
        c,
        isNot(
          contains(
            r'$ErrorActionPreference = "Stop"\n$HermesHome = Split-Path',
          ),
        ),
      );
    });

    test('genera PNG por stdin sin imprimir credenciales', () {
      expect(c, contains('pairing-qr.png'));
      expect(c, contains(r'RedirectStandardInput = $true'));
      expect(c, contains(r'StandardInput.Write($Link)'));
      expect(c, isNot(contains('print_ascii')));
      expect(c, isNot(contains('Write-Host "Link:')));
    });

    test('mantiene overrides HTTPS y los restart tasks allowlisted', () {
      expect(c, contains('HERMES_PAIR_SCHEME'));
      expect(c, contains('HERMES_DASHBOARD_URL'));
      expect(c, contains('HERMES_BRIDGE_URL'));
      expect(c, contains('HermesConsole-Restart-Dashboard'));
      expect(c, contains('HermesConsole-Restart-MobileBridge'));
      expect(c, contains('100.64.0.0/255.192.0.0'));
    });
  });

  group('hermes-mobile-setup.vbs (lanzador Windows)', () {
    final c = File('scripts/hermes-mobile-setup.vbs').readAsStringSync();

    test('oculta PowerShell y solo abre el PNG al terminar', () {
      expect(c, contains('hermes-mobile-setup.ps1'));
      expect(c, contains('-WindowStyle Hidden'));
      expect(c, contains('shell.Run(command, 0, True)'));
      expect(c, contains('pairing-qr.png'));
      expect(c, contains('explorer.exe'));
      expect(c, contains('Resumen verificado:'));
      expect(c, contains('Acceso desde el movil comprobado'));
    });
  });

  // Script hermano del instalador: re-emite el QR/enlace en un servidor YA
  // configurado (U-34), sin instalar ni reiniciar nada.
  group('hermes-pair.sh (QR bajo demanda)', () {
    final c = File('scripts/hermes-pair.sh').readAsStringSync();

    test('no crea token: exige el del instalador y deriva al installer', () {
      expect(c, contains('API_SERVER_KEY'));
      expect(c.toLowerCase(), isNot(contains('urandom')));
      expect(c, isNot(contains('openssl rand')));
      expect(c, contains('hermes-mobile-setup.sh'));
    });

    test('solo reutiliza un pairing verificado y coherente', () {
      expect(c, contains('PAIRING_SCHEMA'));
      expect(c, contains('PYTHON_BIN'));
      expect(c, contains('pairing record is inconsistent'));
      expect(c, contains('phone'));
    });

    test('aborta si cualquiera de los tres servicios no es Hermes sano', () {
      expect(c, contains('verify gateway'));
      expect(c, contains('verify bridge'));
      expect(c, contains('verify dashboard'));
      expect(c, contains('hermes-service-probe.py'));
      expect(c, isNot(contains('port_listening')));
      final dashboardGate = c.indexOf('verify dashboard');
      final qr = c.indexOf('SCAN THIS QR');
      expect(qr, greaterThan(dashboardGate));
    });

    test('QR con fallback: qrencode > uv > venv pip > enlace verificado', () {
      expect(c, contains('qrencode'));
      expect(c, contains('--with qrcode'));
      expect(c, contains('pip install -q qrcode'));
      expect(c, contains('QR_RENDERED'));
      expect(c, contains('QR renderer could not be prepared'));
      expect(c, contains('Paste the verified link'));
      expect(c, contains('"hermes://pair?"'));
    });
  });

  group('hermes-pair.ps1 (Windows nativo)', () {
    final c = File('scripts/hermes-pair.ps1').readAsStringSync();

    test('lee pairing verificado, comprueba servicios y emite QR/enlace', () {
      expect(c, contains('API_SERVER_KEY'));
      expect(c, isNot(contains('RandomNumberGenerator')));
      expect(c, contains('pairing.schema'));
      expect(c, contains('Assert-AllowedServiceUrl'));
      expect(c, contains('Test-HermesService'));
      expect(c, contains('/api/sessions'));
      expect(c, contains('/bridge/capabilities'));
      expect(c, contains('/api/status'));
      expect(c, contains('operations.self_update'));
      expect(c, isNot(contains('Test-Port')));
      expect(c, contains('"hermes://pair?"'));
      expect(c, contains('bridge_token='));
      expect(c, contains('qrcode'));
    });
  });

  group('ServerSetupGenerator.buildPairingLink (formato)', () {
    test('el enlace generado parsea con PairingLink.tryParse', () {
      final link = ServerSetupGenerator.buildPairingLink(
        host: '100.100.1.2',
        port: 8642,
        token: 'abc123token',
        dashboardUrl: 'http://100.100.1.2:9119',
        bridgeUrl: 'http://100.100.1.2:9131',
        bridgeToken: 'bridge-token',
      );
      final parsed = PairingLink.tryParse(link);
      expect(parsed, isNotNull);
      expect(parsed!.host, '100.100.1.2');
      expect(parsed.port, 8642);
      expect(parsed.token, 'abc123token');
      expect(parsed.dashboardUrl, 'http://100.100.1.2:9119');
      expect(parsed.bridgeUrl, 'http://100.100.1.2:9131');
      expect(parsed.bridgeToken, 'bridge-token');
    });
  });
}
