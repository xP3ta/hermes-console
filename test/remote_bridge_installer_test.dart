import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/bridge_release_channel.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/remote_bridge_installer.dart';
import 'package:hermes_android/core/services/server_setup_generator.dart';

SavedConnection _conn() => SavedConnection(
  id: 'c1',
  label: 'Remoto',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'GW_KEY_123',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RemoteBridgeInstaller.installCommand', () {
    test('es el curl corto al script público (una línea, siempre pegable)', () {
      final cmd = RemoteBridgeInstaller.installCommand();

      expect(cmd, ServerSetupGenerator.curlCommand);
      expect(cmd, startsWith('curl -fsSL https://raw.githubusercontent.com/'));
      expect(cmd, endsWith('| sh'));
      // Una sola línea corta: sin riesgo de truncado al pegar (MAX_CANON,
      // ver U-23) y legible de un vistazo, URL de GitHub incluida.
      expect(cmd.contains('\n'), isFalse);
      expect(cmd.length, lessThan(200));
    });

    test('devuelve el instalador PowerShell cuando se solicita Windows', () {
      final cmd = RemoteBridgeInstaller.installCommand(
        platform: ServerHostPlatform.windows,
      );

      expect(cmd, ServerSetupGenerator.powershellCommand);
      expect(cmd, contains('hermes-mobile-setup.ps1'));
      expect(cmd, endsWith('| iex'));
    });

    test('el prompt remoto bifurca Windows y Unix antes de ejecutar', () {
      final prompt = RemoteBridgeInstaller.agentPrompt('echo unix');

      expect(prompt, contains('native Windows'));
      expect(prompt, contains('powershell.exe'));
      expect(prompt, contains('DO NOT run the POSIX block'));
      expect(prompt, contains('Unix host without a working `systemd --user`'));
      expect(prompt, contains(ServerSetupGenerator.curlCommand));
      expect(prompt, contains('echo unix'));
    });
  });

  group('RemoteBridgeInstaller.installScript', () {
    test(
      'script legible que reconstruye el bridge y arma el servicio',
      () async {
        final api = ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'GW_KEY_123',
        );
        final script = await RemoteBridgeInstaller(
          api,
          _conn(),
        ).installScript();

        expect(script, contains('UNIT_DIR="\$CONFIG_HOME/systemd/user"'));
        expect(
          script,
          contains('UNIT_FILE="\$UNIT_DIR/hermes-bridge.service"'),
        );
        expect(script, contains('BRIDGE_PORT=9131'));
        expect(script, contains('BRIDGE_TOKEN=\$KEY'));
        expect(script, isNot(contains('GW_KEY_123')));
        expect(script, contains('API_SERVER_KEY is not available'));
        expect(script, contains('NEW="\$TARGET.new"'));
        expect(script, contains('BACKUP="\$TARGET.rollback"'));
        expect(script, contains('ENV_BACKUP="\$HH/bridge.env.rollback"'));
        expect(
          script,
          contains('UNIT_BACKUP="\$HH/hermes-bridge.service.rollback"'),
        );
        expect(script, contains('EXISTING_BIND='));
        expect(script, contains('BRIDGE_HOST=\$BIND'));
        expect(script, contains('trap rollback_on_exit 0 1 2 15'));
        expect(script, contains('-m py_compile'));
        expect(script, contains('mv "\$NEW" "\$TARGET"'));
        expect(script, contains('mv "\$BACKUP" "\$TARGET"'));
        // restart (no `enable --now`): --now no reinicia un servicio ya activo
        // y este script es también el camino de ACTUALIZACIÓN del bridge.
        expect(script, contains('systemctl --user restart hermes-bridge'));
        expect(script, isNot(contains('enable --now hermes-bridge')));
        expect(script, contains(RemoteBridgeInstaller.okMarker));

        // U-15 (spec 028): con bind no-loopback, el ExecStart DEBE pasar
        // --i-know-what-im-doing o el bridge aborta el arranque (guard de
        // seguridad que solo mira sys.argv) y el servicio crash-loopea.
        expect(
          script,
          contains('ExecStart=\$VP \$TARGET --i-know-what-im-doing'),
          reason:
              'el servicio debe arrancar el bridge con el flag de bind público',
        );

        // El bridge embebido se reconstruye: extrae el base64 del printf y
        // descomprime (gzip) → debe coincidir con el asset original.
        final asset = await rootBundle.loadString(
          'assets/bridge/hermes_bridge.py',
        );
        final m = RegExp(r"printf %s '([A-Za-z0-9+/=]+)'").firstMatch(script);
        expect(
          m,
          isNotNull,
          reason: 'el script debe llevar el bridge en base64',
        );
        final restored = utf8.decode(gzip.decode(base64.decode(m!.group(1)!)));
        expect(restored, asset);

        api.close();
      },
    );

    test('puede instalar exactamente el source remoto ya verificado', () async {
      const remote = 'VERSION = "9.8.7"\nprint("verified")\n';
      final api = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'GW_KEY_123',
      );

      final script = await RemoteBridgeInstaller(
        api,
        _conn(),
      ).installScript(bridgeSource: remote);

      final match = RegExp(r"printf %s '([A-Za-z0-9+/=]+)'").firstMatch(script);
      final restored = utf8.decode(
        gzip.decode(base64.decode(match!.group(1)!)),
      );
      expect(restored, remote);
      api.close();
    });

    test(
      'release remota usa descarga fijada y no incrusta 146 KiB en el run',
      () async {
        const remote = 'VERSION = "1.17.0"\nprint("verified")\n';
        final bytes = utf8.encode(remote);
        final release = BridgeRelease(
          version: '1.17.0',
          source: remote,
          sha256: sha256.convert(bytes).toString(),
          size: bytes.length,
          minAppBuild: 903,
          remote: true,
        );
        final api = ApiClient(
          baseUrl: 'http://hermes.local:8642',
          apiKey: 'GW_KEY_123',
        );

        final script = await RemoteBridgeInstaller(
          api,
          _conn(),
        ).installScript(release: release);

        expect(script, contains(BridgeReleaseChannel.payloadUri.toString()));
        expect(script, contains(release.sha256));
        expect(script, contains('${release.size}'));
        expect(script, contains(release.version));
        expect(script, isNot(contains(base64.encode(gzip.encode(bytes)))));
        expect(script.length, lessThan(10000));
        api.close();
      },
    );

    test('restaura programa, env y unidad si el servicio no arranca', () async {
      if (Platform.isWindows) return;
      final root = Directory.systemTemp.createTempSync('bridge-rollback-');
      final hermesHome = Directory('${root.path}/hermes')..createSync();
      final configHome = Directory('${root.path}/config')..createSync();
      final unitDir = Directory('${configHome.path}/systemd/user')
        ..createSync(recursive: true);
      const oldSource = 'VERSION = "1.16.0"\n';
      const oldEnv =
          'BRIDGE_HOST=0.0.0.0\nBRIDGE_TOKEN=old\nBRIDGE_PORT=9131\n';
      const oldUnit = '[Unit]\nDescription=old bridge\n';
      final target = File('${hermesHome.path}/hermes_bridge.py')
        ..writeAsStringSync(oldSource);
      final envFile = File('${hermesHome.path}/bridge.env')
        ..writeAsStringSync(oldEnv);
      final unitFile = File('${unitDir.path}/hermes-bridge.service')
        ..writeAsStringSync(oldUnit);
      File(
        '${hermesHome.path}/.env',
      ).writeAsStringSync('API_SERVER_KEY=test-key\n');

      final api = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'GW_KEY_123',
      );
      try {
        final script = await RemoteBridgeInstaller(
          api,
          _conn(),
        ).installScript(bridgeSource: 'VERSION = "1.17.0"\n');
        final result = await Process.run(
          'sh',
          [
            '-c',
            '''systemctl() {
  case "\$*" in
    *"restart hermes-bridge"*) return 1 ;;
    *) return 0 ;;
  esac
}
$script''',
          ],
          environment: {
            'HERMES_HOME': hermesHome.path,
            'XDG_CONFIG_HOME': configHome.path,
          },
        );

        expect(result.exitCode, isNonZero);
        expect(
          '${result.stdout}${result.stderr}',
          contains(RemoteBridgeInstaller.failMarker),
        );
        expect(target.readAsStringSync(), oldSource);
        expect(envFile.readAsStringSync(), oldEnv);
        expect(unitFile.readAsStringSync(), oldUnit);
      } finally {
        api.close();
        root.deleteSync(recursive: true);
      }
    });
  });
}
