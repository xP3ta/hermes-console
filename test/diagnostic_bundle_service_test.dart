import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/capability_matrix.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/connection_diagnostics.dart';
import 'package:hermes_android/core/services/diagnostic_bundle_service.dart';

void main() {
  late Directory cache;
  final now = DateTime.utc(2026, 7, 14, 20);

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('hermes-diag-test-');
  });

  tearDown(() async {
    if (await cache.exists()) await cache.delete(recursive: true);
  });

  DiagnosticBundleService service() => DiagnosticBundleService(
    cacheDirectory: () async => cache,
    now: () => now,
    randomToken: () => 'fixed-random-token',
  );

  test('allowlist excluye secretos, hosts, contenido, rutas e IDs', () {
    const forbidden = <String>[
      'Bearer super-secret-api-key',
      'ticket=dashboard-ticket',
      'session_cookie=private-cookie',
      'password=hunter2',
      'hermes.internal.example',
      '192.168.1.20',
      '2001:db8::dead:beef',
      'https://hermes.internal.example:8642/api?token=secret',
      'Server producción',
      'admin-private-user',
      'prompt ultra secreto',
      'respuesta privada del agente',
      'tool output confidencial',
      '/data/user/0/dev.xpetalab.hermesconsole.qa/cache/private.png',
      '/home/demo/.hermes/cache/images/private.png',
      r'C:\Users\Server\private.png',
      'private-attachment.png',
      'session-id-private',
      'run-id-private',
      'client-turn-id-private',
      'server-turn-id-private',
      'hermes://pair?token=qr-private',
      '#0 PrivateStack.method (private.dart:42)',
    ];
    final poisoned = forbidden.join(' | ');
    final connection = SavedConnection(
      id: 'session-id-private',
      label: poisoned,
      host: 'hermes.internal.example',
      port: 8642,
      apiKey: 'Bearer super-secret-api-key',
      notes: poisoned,
      dashboardUrl: 'https://hermes.internal.example:9119/api?token=secret',
    );
    final turn = PreparedTurn(
      connectionId: 'session-id-private',
      sessionId: 'run-id-private',
      clientTurnId: 'client-turn-id-private',
      createdAtMs: now
          .subtract(const Duration(hours: 2))
          .millisecondsSinceEpoch,
      updatedAtMs: now
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch,
      text: poisoned,
      attachments: const [
        AttachmentDraft(
          localPath:
              '/data/user/0/dev.xpetalab.hermesconsole.qa/cache/private.png',
          name: 'private-attachment.png',
          mimeType: 'image/png',
          sizeBytes: 123,
          type: AttachmentType.image,
        ),
      ],
      model: poisoned,
      profile: poisoned,
      state: PreparedTurnState.ambiguous,
    );

    final bundle = service().build(
      DiagnosticBundleInput(
        appVersion: poisoned,
        buildNumber: 900,
        flavor: DiagnosticFlavor.qa,
        androidApi: 36,
        formFactor: DiagnosticFormFactor.phone,
        connections: [
          DiagnosticConnectionSnapshot.fromConnection(
            ordinal: 1,
            connection: connection,
            matrix: const CapabilityMatrix(
              gatewayOnline: CapState.yes,
              chatSupported: CapState.yes,
              turnIdempotency: CapState.no,
            ),
            health: const [
              DiagnosticHealthSample(
                component: DiagnosticComponent.gateway,
                code: DiagnosticCode.ok,
                latencyMs: 125,
              ),
            ],
          ),
        ],
        turns: DiagnosticTurnsSnapshot.fromPreparedTurns([turn], now: now),
        caches: const {
          DiagnosticCacheKind.sentImages: DiagnosticCacheSnapshot(
            entries: 1,
            sizeBytes: 123,
          ),
        },
        recentErrors: [
          DiagnosticErrorEvent(
            component: DiagnosticComponent.websocket,
            code: DiagnosticCode.timeout,
            occurredAt: now.subtract(const Duration(minutes: 5)),
          ),
        ],
      ),
    );

    final encoded = bundle.preview;
    expect(jsonDecode(encoded), isA<Map<String, dynamic>>());
    for (final secret in forbidden) {
      expect(encoded, isNot(contains(secret)), reason: secret);
    }
    expect(encoded, isNot(contains('detail')));
    expect(encoded, isNot(contains('message')));
    expect(encoded, isNot(contains('stack')));
    expect(encoded, isNot(contains('exception')));
    expect(encoded, contains('"version":"unknown"'));
  });

  test('reduce eventos antiguos y nunca supera 256 KiB ni trunca JSON', () {
    final errors = List.generate(
      30000,
      (index) => DiagnosticErrorEvent(
        component: DiagnosticComponent.websocket,
        code: DiagnosticCode.timeout,
        occurredAt: now.subtract(Duration(seconds: index)),
      ),
    );

    final bundle = service().build(
      DiagnosticBundleInput(
        appVersion: '1.1.3',
        buildNumber: 900,
        flavor: DiagnosticFlavor.qa,
        androidApi: 36,
        formFactor: DiagnosticFormFactor.phone,
        recentErrors: errors,
      ),
    );

    expect(utf8.encode(bundle.preview).length, lessThanOrEqualTo(256 * 1024));
    final decoded = jsonDecode(bundle.preview) as Map<String, dynamic>;
    expect(decoded['recentErrors'], isA<List<dynamic>>());
    expect((decoded['recentErrors'] as List).length, lessThan(errors.length));
  });

  test('no crea archivo hasta write y usa solo la caché privada', () async {
    final bundle = service().build(
      const DiagnosticBundleInput(
        appVersion: '1.1.3',
        buildNumber: 900,
        flavor: DiagnosticFlavor.qa,
        androidApi: 36,
        formFactor: DiagnosticFormFactor.phone,
      ),
    );

    expect(await cache.list().toList(), isEmpty);
    final file = await service().write(bundle);

    expect(file.parent.path, cache.path);
    expect(file.path, endsWith('hermes-diagnostic-fixed-random-token.json'));
    expect(await file.length(), lessThanOrEqualTo(256 * 1024));
    expect(jsonDecode(await file.readAsString()), isA<Map<String, dynamic>>());
  });

  test('limpia únicamente bundles propios de más de 24 horas', () async {
    final expired = File('${cache.path}/hermes-diagnostic-expired.json');
    final recent = File('${cache.path}/hermes-diagnostic-recent.json');
    final unrelated = File('${cache.path}/private-attachment.png');
    await expired.writeAsString('{}');
    await recent.writeAsString('{}');
    await unrelated.writeAsString('private');
    await expired.setLastModified(now.subtract(const Duration(hours: 25)));
    await recent.setLastModified(now.subtract(const Duration(hours: 23)));
    await unrelated.setLastModified(now.subtract(const Duration(days: 7)));

    final removed = await service().cleanupExpired();

    expect(removed, 1);
    expect(await expired.exists(), isFalse);
    expect(await recent.exists(), isTrue);
    expect(await unrelated.exists(), isTrue);
  });

  test(
    'buckets no exponen valores precisos ni nombres de caché arbitrarios',
    () {
      final turns = DiagnosticTurnsSnapshot.fromPreparedTurns([
        PreparedTurn(
          connectionId: 'private-connection',
          sessionId: 'private-session',
          clientTurnId: 'private-turn',
          createdAtMs: now
              .subtract(const Duration(days: 2))
              .millisecondsSinceEpoch,
          updatedAtMs: now
              .subtract(const Duration(hours: 30))
              .millisecondsSinceEpoch,
          text: 'private prompt',
          attachments: const [],
          model: 'private-model',
          profile: 'private-profile',
        ),
      ], now: now);
      final bundle = service().build(
        DiagnosticBundleInput(
          appVersion: '1.1.3',
          buildNumber: 900,
          flavor: DiagnosticFlavor.qa,
          androidApi: 36,
          formFactor: DiagnosticFormFactor.tablet,
          turns: turns,
          caches: const {
            DiagnosticCacheKind.sentImages: DiagnosticCacheSnapshot(
              entries: 3,
              sizeBytes: 9 * 1024 * 1024,
            ),
          },
        ),
      );

      expect(bundle.preview, contains('"oldestPendingAge":"lt7d"'));
      expect(bundle.preview, contains('"sizeBucket":"lt10mb"'));
      expect(bundle.preview, isNot(contains('private-')));
      expect(bundle.preview, isNot(contains('${9 * 1024 * 1024}')));
    },
  );

  test('adaptadores tipados ignoran detail y nombres de archivo', () async {
    const secret = 'Bearer secret desde detail y private-file-name.txt';
    final health = DiagnosticHealthSample.fromProbe(
      component: DiagnosticComponent.gateway,
      result: const ProbeResult(
        name: 'health-private-id',
        status: ProbeStatus.timeout,
        latencyMs: 1700,
        detail: secret,
      ),
    );
    final privateFile = File('${cache.path}/private-file-name.txt');
    await privateFile.writeAsBytes(List.filled(2048, 1));
    final cacheSnapshot = await DiagnosticCacheSnapshot.fromDirectory(cache);

    final bundle = service().build(
      DiagnosticBundleInput(
        appVersion: '1.1.3',
        buildNumber: 900,
        flavor: DiagnosticFlavor.qa,
        androidApi: 36,
        formFactor: DiagnosticFormFactor.phone,
        connections: [
          DiagnosticConnectionSnapshot(
            ordinal: 1,
            transportClass: DiagnosticTransportClass.https,
            desktopWs: true,
            turnIdempotencyV1: false,
            health: [health],
          ),
        ],
        caches: {DiagnosticCacheKind.attachments: cacheSnapshot},
      ),
    );

    expect(bundle.preview, contains('"code":"timeout"'));
    expect(bundle.preview, contains('"latencyBucket":"lt5s"'));
    expect(bundle.preview, contains('"entries":1'));
    expect(bundle.preview, isNot(contains(secret)));
    expect(bundle.preview, isNot(contains('health-private-id')));
    expect(bundle.preview, isNot(contains('private-file-name.txt')));
  });

  test('transport class follows the Dashboard origin, as Desktop does', () {
    final proxied = SavedConnection(
      id: 'u5',
      label: 'Proxy',
      host: 'hermes.example.test',
      port: 8642,
      apiKey: '',
      dashboardUrl: 'https://hermes.example.test',
    );
    expect(
      DiagnosticConnectionSnapshot.fromConnection(
        ordinal: 1,
        connection: proxied,
        matrix: const CapabilityMatrix(),
      ).transportClass,
      DiagnosticTransportClass.https,
    );
  });
}
