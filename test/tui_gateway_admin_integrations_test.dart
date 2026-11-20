import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/admin_integrations.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

SavedConnection _connection({bool readOnly = false}) => SavedConnection(
  id: 'admin-integrations',
  label: 'QA',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'gateway-test-key',
  dashboardUrl: 'http://127.0.0.1:9119',
  readOnly: readOnly,
);

DashboardClient _dashboard(http.Client client) => DashboardClient(
  host: '127.0.0.1',
  port: 9119,
  manualToken: 'dashboard-test-token',
  httpClientOverride: client,
);

Map<String, dynamic> _body(http.Request request) => request.body.isEmpty
    ? const {}
    : Map<String, dynamic>.from(jsonDecode(request.body) as Map);

void main() {
  test('MCP create y OAuth usan contratos 0.20', () async {
    final requests = <http.Request>[];
    final client = TuiGatewayClient(
      _connection(),
      dashboard: _dashboard(
        MockClient((request) async {
          requests.add(request);
          final payload = switch ((request.method, request.url.path)) {
            ('POST', '/api/mcp/servers') => {
              'name': 'reports',
              'transport': 'http',
              'url': 'https://mcp.example/mcp',
              'auth': 'oauth',
              'enabled': true,
            },
            ('POST', '/api/mcp/servers/reports/auth') => {
              'flow_id': 'flow-1',
              'server_name': 'reports',
              'status': 'authorization_required',
              'authorization_url': 'https://idp.example/authorize',
            },
            ('GET', '/api/mcp/oauth/flows/flow-1') => {
              'flow_id': 'flow-1',
              'server_name': 'reports',
              'status': 'approved',
              'tools': ['search'],
            },
            _ => <String, dynamic>{},
          };
          return http.Response(jsonEncode(payload), 200);
        }),
      ),
    );
    addTearDown(client.close);

    final server = await client.addMcpServer(
      McpServerDraft.http(
        name: 'reports',
        url: 'https://mcp.example/mcp',
        auth: McpAuthMode.oauth,
      ),
    );
    final started = await client.startMcpOAuth('reports');
    final completed = await client.mcpOAuthFlow('flow-1');

    expect(server.name, 'reports');
    expect(started.status, McpOAuthStatus.authorizationRequired);
    expect(completed.status, McpOAuthStatus.approved);
    expect(_body(requests.first), {
      'name': 'reports',
      'url': 'https://mcp.example/mcp',
      'auth': 'oauth',
    });
  });

  test('webhooks CRUD conserva secreto solo en receipt', () async {
    final requests = <http.Request>[];
    final client = TuiGatewayClient(
      _connection(),
      dashboard: _dashboard(
        MockClient((request) async {
          requests.add(request);
          final payload = switch ((request.method, request.url.path)) {
            ('GET', '/api/webhooks') => {
              'enabled': false,
              'base_url': 'http://127.0.0.1:8642',
              'subscriptions': <dynamic>[],
            },
            ('POST', '/api/webhooks/enable') => {
              'ok': true,
              'enabled': true,
              'restart_started': true,
              'needs_restart': false,
            },
            ('POST', '/api/webhooks') => {
              'name': 'deploy-hook',
              'events': ['push'],
              'deliver': 'log',
              'url': 'http://127.0.0.1:8642/webhooks/deploy-hook',
              'secret_set': true,
              'enabled': true,
              'secret': 'one-shot-secret',
            },
            ('PUT', '/api/webhooks/deploy-hook/enabled') => {
              'ok': true,
              'name': 'deploy-hook',
              'enabled': false,
            },
            ('DELETE', '/api/webhooks/deploy-hook') => {'ok': true},
            _ => <String, dynamic>{},
          };
          return http.Response(jsonEncode(payload), 200);
        }),
      ),
    );
    addTearDown(client.close);

    expect((await client.webhookSnapshot()).enabled, isFalse);
    final enable = await client.enableWebhooks();
    final receipt = await client.createWebhook(
      WebhookDraft(name: 'Deploy Hook', events: const ['push']),
    );
    await client.setWebhookEnabled('deploy-hook', false);
    await client.removeWebhook('deploy-hook');

    expect(enable.restartStarted, isTrue);
    expect(receipt.secret, 'one-shot-secret');
    expect('$receipt', isNot(contains('one-shot-secret')));
    expect(_body(requests[2]), {
      'name': 'deploy-hook',
      'events': ['push'],
      'skills': <dynamic>[],
      'deliver': 'log',
      'deliver_only': false,
    });
  });

  test('MCP servers added for a profile name it on the create and the '
      'sign-in; the unscoped surface names none', () async {
    final requests = <http.Request>[];
    final client = TuiGatewayClient(
      _connection(),
      dashboard: _dashboard(
        MockClient((request) async {
          requests.add(request);
          final payload = switch ((request.method, request.url.path)) {
            ('POST', '/api/mcp/servers') => {
              'name': 'reports',
              'transport': 'http',
              'url': 'https://mcp.example/mcp',
              'auth': 'oauth',
              'enabled': true,
            },
            ('POST', '/api/mcp/servers/reports/auth') => {
              'flow_id': 'flow-1',
              'server_name': 'reports',
              'status': 'authorization_required',
              'authorization_url': 'https://idp.example/authorize',
            },
            ('GET', '/api/mcp/oauth/flows/flow-1') => {
              'flow_id': 'flow-1',
              'server_name': 'reports',
              'status': 'approved',
            },
            _ => <String, dynamic>{},
          };
          return http.Response(jsonEncode(payload), 200);
        }),
      ),
    );
    addTearDown(client.close);
    List<String> calls() => [
      for (final request in requests)
        '${request.method} ${request.url.path}'
            '${request.url.hasQuery ? '?${request.url.query}' : ''}',
    ];
    final draft = McpServerDraft.http(
      name: 'reports',
      url: 'https://mcp.example/mcp',
      auth: McpAuthMode.oauth,
    );

    final writer = client.mcpProvisioningOf('writer bot');
    expect((await writer.addMcpServer(draft)).name, 'reports');
    final started = await writer.startMcpOAuth('reports');
    expect(started.status, McpOAuthStatus.authorizationRequired);
    // The server keys a sign-in by its flow id alone.
    final done = await writer.mcpOAuthFlow('flow-1');
    expect(done.status, McpOAuthStatus.approved);
    expect(calls(), [
      'POST /api/mcp/servers?profile=writer+bot',
      'POST /api/mcp/servers/reports/auth?profile=writer+bot',
      'GET /api/mcp/oauth/flows/flow-1',
    ]);
    // The body is the draft, as before: the profile travels in the query.
    expect(_body(requests.first), {
      'name': 'reports',
      'url': 'https://mcp.example/mcp',
      'auth': 'oauth',
    });

    // No profile chosen is the default profile, by name, not whichever
    // profile the server was started as.
    requests.clear();
    final unnamed = client.mcpProvisioningOf('  ');
    await unnamed.addMcpServer(draft);
    await unnamed.startMcpOAuth('reports');
    expect(calls(), [
      'POST /api/mcp/servers?profile=default',
      'POST /api/mcp/servers/reports/auth?profile=default',
    ]);

    requests.clear();
    await client.addMcpServer(draft);
    await client.startMcpOAuth('reports');
    expect(calls(), [
      'POST /api/mcp/servers',
      'POST /api/mcp/servers/reports/auth',
    ]);
  });

  test('a read-only connection adds no MCP server to any profile', () async {
    var calls = 0;
    final client = TuiGatewayClient(
      _connection(readOnly: true),
      dashboard: _dashboard(
        MockClient((request) async {
          calls++;
          return http.Response('{}', 200);
        }),
      ),
    );
    addTearDown(client.close);
    final scoped = client.mcpProvisioningOf('writer bot');
    final forbidden = throwsA(
      isA<DesktopControlFailure>().having(
        (failure) => failure.kind,
        'kind',
        DesktopControlFailureKind.forbidden,
      ),
    );
    expect(
      () => scoped.addMcpServer(
        McpServerDraft.http(name: 'reports', url: 'https://mcp.example/mcp'),
      ),
      forbidden,
    );
    expect(() => scoped.startMcpOAuth('reports'), forbidden);
    expect(calls, 0);
  });

  test('the webhooks of a profile name it on every call, the delete '
      'included; the unscoped surface names none', () async {
    final requests = <http.Request>[];
    final client = TuiGatewayClient(
      _connection(),
      dashboard: _dashboard(
        MockClient((request) async {
          requests.add(request);
          final payload = switch ((request.method, request.url.path)) {
            ('GET', '/api/webhooks') => {
              'enabled': true,
              'base_url': 'http://127.0.0.1:8642',
              'subscriptions': <dynamic>[],
            },
            ('POST', '/api/webhooks/enable') => {
              'ok': true,
              'enabled': true,
              'restart_started': false,
              'needs_restart': false,
            },
            ('POST', '/api/webhooks') => {
              'name': 'deploy-hook',
              'events': ['push'],
              'deliver': 'log',
              'url': 'http://127.0.0.1:8642/webhooks/deploy-hook',
              'secret_set': true,
              'enabled': true,
              'secret': 'one-shot-secret',
            },
            ('PUT', '/api/webhooks/deploy-hook/enabled') => {
              'ok': true,
              'name': 'deploy-hook',
              'enabled': false,
            },
            _ => <String, dynamic>{'ok': true},
          };
          return http.Response(jsonEncode(payload), 200);
        }),
      ),
    );
    addTearDown(client.close);
    List<String> calls() => [
      for (final request in requests)
        '${request.method} ${request.url.path}'
            '${request.url.hasQuery ? '?${request.url.query}' : ''}',
    ];

    final writer = client.webhooksOf('writer bot');
    await writer.webhookSnapshot();
    await writer.enableWebhooks();
    await writer.createWebhook(
      WebhookDraft(name: 'Deploy Hook', events: const ['push']),
    );
    await writer.setWebhookEnabled('deploy-hook', false);
    await writer.removeWebhook('deploy-hook');
    expect(calls(), [
      'GET /api/webhooks?profile=writer+bot',
      'POST /api/webhooks/enable?profile=writer+bot',
      'POST /api/webhooks?profile=writer+bot',
      'PUT /api/webhooks/deploy-hook/enabled?profile=writer+bot',
      'DELETE /api/webhooks/deploy-hook?profile=writer+bot',
    ]);

    // No profile chosen is the default profile, by name: a backend that
    // serves several refuses a delete that names none.
    requests.clear();
    await client.webhooksOf('  ').removeWebhook('deploy-hook');
    expect(calls(), ['DELETE /api/webhooks/deploy-hook?profile=default']);

    requests.clear();
    await client.webhookSnapshot();
    await client.removeWebhook('deploy-hook');
    expect(calls(), ['GET /api/webhooks', 'DELETE /api/webhooks/deploy-hook']);
  });

  test('read-only bloquea mutaciones antes de la red', () async {
    var calls = 0;
    final client = TuiGatewayClient(
      _connection(readOnly: true),
      dashboard: _dashboard(
        MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      ),
    );
    addTearDown(client.close);

    expect(
      () => client.addMcpServer(
        McpServerDraft.stdio(name: 'local', command: 'npx'),
      ),
      throwsA(
        isA<DesktopControlFailure>().having(
          (failure) => failure.kind,
          'kind',
          DesktopControlFailureKind.forbidden,
        ),
      ),
    );
    expect(
      () => client.createWebhook(WebhookDraft(name: 'blocked')),
      throwsA(isA<DesktopControlFailure>()),
    );
    expect(calls, 0);
  });
}
