import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardClient;
import 'package:hermes_android/core/services/notifications/notification_action_ops.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _ClosingClient extends MockClient {
  _ClosingClient(super.fn);

  int closeCalls = 0;
  final paths = <String>[];

  @override
  void close() {
    closeCalls++;
    super.close();
  }
}

final _connection = SavedConnection(
  id: 'c-cron',
  label: 'Cron',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'unused',
  dashboardUrl: 'http://127.0.0.1:9119',
);

const _payload = NotificationActionPayload(
  route: NotificationActionRoute.cron,
  connId: 'c-cron',
  profile: 'default',
  taskId: 'job-1',
);

void main() {
  late _ClosingClient client;

  GatewayNotificationActionOps ops(int status) {
    client = _ClosingClient((request) async {
      client.paths.add(request.url.path);
      return _json(status);
    });
    return GatewayNotificationActionOps(
      resolveConnection: (_) => _connection,
      dashboardFactory: (c) => DashboardClient(
        host: c.dashboardHost,
        port: c.dashboardPort,
        manualToken: 'token',
        httpClientOverride: client,
      ),
    );
  }

  test('cron retry closes the dashboard client it created', () async {
    await ops(200).cronTrigger(_payload);

    expect(client.paths, ['/api/cron/jobs/job-1/trigger']);
    expect(client.closeCalls, 1);
  });

  test('a failed cron retry still closes its dashboard client', () async {
    await expectLater(ops(500).cronTrigger(_payload), throwsA(anything));

    expect(client.paths, ['/api/cron/jobs/job-1/trigger']);
    expect(client.closeCalls, 1);
  });
}

http.Response _json(int status) =>
    http.Response('{}', status, headers: {'content-type': 'application/json'});
