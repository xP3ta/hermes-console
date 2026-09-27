import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/admin_integrations.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/screens/admin_integrations_screen.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/core/widgets/mcp_provisioning_surface.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

class _AdminGateway
    implements
        HermesDesktopControlGateway,
        HermesMcpProvisioningGateway,
        HermesWebhookManagementGateway,
        HermesServerPlatformCapabilitiesGateway {
  final List<McpServerDraft> mcpDrafts = [];
  final List<String> oauthStarts = [];
  int oauthFlowCalls = 0;
  McpOAuthFlow startedFlow = McpOAuthFlow.fromJson({
    'flow_id': 'flow-1',
    'server_name': 'reports',
    'status': 'authorization_required',
    'authorization_url': 'https://idp.example/authorize',
  });
  McpOAuthFlow polledFlow = McpOAuthFlow.fromJson({
    'flow_id': 'flow-1',
    'server_name': 'reports',
    'status': 'approved',
    'tools': ['search'],
  });
  WebhookSnapshot snapshot = WebhookSnapshot.fromJson({
    'enabled': true,
    'base_url': 'https://agent.example',
    'subscriptions': <Object>[],
  });
  int enableCalls = 0;
  final List<WebhookDraft> webhookDrafts = [];
  final List<(String, bool)> webhookToggles = [];
  final List<String> webhookDeletes = [];
  A2aServerCapability? a2a = const A2aServerCapability(
    enabled: true,
    configured: true,
    gatewayRunning: true,
    state: 'connected',
  );

  @override
  Future<DesktopMcpServerEntry> addMcpServer(McpServerDraft draft) async {
    mcpDrafts.add(draft);
    return DesktopMcpServerEntry(
      name: draft.name,
      transport: draft.transport.name,
      endpointLabel: draft.url?.toString() ?? draft.command,
      auth: draft.auth.name,
      enabled: true,
      toolCount: null,
    );
  }

  @override
  Future<McpOAuthFlow> startMcpOAuth(String name) async {
    oauthStarts.add(name);
    return startedFlow;
  }

  @override
  Future<McpOAuthFlow> mcpOAuthFlow(String flowId) async {
    oauthFlowCalls++;
    return polledFlow;
  }

  @override
  Future<WebhookSnapshot> webhookSnapshot() async => snapshot;

  @override
  Future<WebhookEnableResult> enableWebhooks() async {
    enableCalls++;
    snapshot = WebhookSnapshot.fromJson({
      'enabled': true,
      'base_url': 'https://agent.example',
      'subscriptions': <Object>[],
    });
    return const WebhookEnableResult(
      ok: true,
      enabled: true,
      restartStarted: true,
      needsRestart: false,
    );
  }

  @override
  Future<WebhookCreateReceipt> createWebhook(WebhookDraft draft) async {
    webhookDrafts.add(draft);
    return WebhookCreateReceipt.fromJson({
      'name': draft.name,
      'events': draft.events,
      'deliver': draft.deliver,
      'url': 'https://agent.example/webhooks/${draft.name}',
      'secret_set': true,
      'enabled': true,
      'secret': 'one-shot-test-secret',
    });
  }

  @override
  Future<void> setWebhookEnabled(String name, bool enabled) async {
    webhookToggles.add((name, enabled));
  }

  @override
  Future<void> removeWebhook(String name) async {
    webhookDeletes.add(name);
  }

  @override
  Future<A2aServerCapability?> a2aServerCapability() async => a2a;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LegacyGateway implements HermesDesktopControlGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(Widget home, {Locale locale = const Locale('es')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: home,
);

class _OAuthHarness extends StatelessWidget {
  final HermesMcpProvisioningGateway gateway;

  const _OAuthHarness({required this.gateway});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: FilledButton(
        key: const ValueKey('open-oauth-harness'),
        onPressed: () => showMcpOAuthFlowSurface(
          context: context,
          gateway: gateway,
          initialFlow: McpOAuthFlow.fromJson({
            'flow_id': 'flow-1',
            'server_name': 'reports',
            'status': 'authorization_required',
            'authorization_url': 'https://idp.example/authorize',
          }),
          pollDelays: const [
            Duration(seconds: 1),
            Duration(seconds: 1),
            Duration(seconds: 1),
          ],
        ),
        child: const Text('OAuth'),
      ),
    ),
  );
}

Future<void> _chooseHttp(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('mcp-transport-http')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('mcp-draft-name')),
    'reports',
  );
  await tester.enterText(
    find.byKey(const ValueKey('mcp-draft-url')),
    'https://mcp.example/mcp',
  );
}

Future<void> _chooseAuth(WidgetTester tester, String label) async {
  await tester.tap(find.byType(DropdownButtonFormField<McpAuthMode>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('manual MCP sends header secret once and removes its form', (
    tester,
  ) async {
    final gateway = _AdminGateway();
    await tester.pumpWidget(_app(AdminIntegrationsScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('admin-add-mcp')));
    await tester.pumpAndSettle();
    await _chooseHttp(tester);
    await _chooseAuth(tester, 'Cabecera Bearer');
    await tester.enterText(
      find.byKey(const ValueKey('mcp-draft-bearer')),
      'ephemeral-header-secret',
    );
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const ValueKey('mcp-draft-bearer')),
              matching: find.byType(EditableText),
            ),
          )
          .obscureText,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('mcp-draft-submit')));
    await tester.pumpAndSettle();

    expect(gateway.mcpDrafts, hasLength(1));
    expect(gateway.mcpDrafts.single.auth, McpAuthMode.header);
    expect(gateway.mcpDrafts.single.bearerToken, 'ephemeral-header-secret');
    expect(find.byKey(const ValueKey('mcp-draft-bearer')), findsNothing);
    expect(find.text('ephemeral-header-secret'), findsNothing);
  });

  testWidgets('OAuth opens browser and polls only the bounded visible flow', (
    tester,
  ) async {
    final gateway = _AdminGateway();
    Uri? launched;
    await tester.pumpWidget(
      _app(
        AdminIntegrationsScreen(
          gateway: gateway,
          oauthLauncher: (uri) async {
            launched = uri;
            return true;
          },
          oauthPollDelays: const [Duration(hours: 1)],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('admin-add-mcp')));
    await tester.pumpAndSettle();
    await _chooseHttp(tester);
    await _chooseAuth(tester, 'OAuth en navegador');
    await tester.tap(find.byKey(const ValueKey('mcp-draft-submit')));
    await tester.pumpAndSettle();

    expect(gateway.oauthStarts, ['reports']);
    expect(
      find.byKey(const ValueKey('mcp-oauth-flow-surface')),
      findsOneWidget,
    );
    expect(gateway.oauthFlowCalls, 0);
    await tester.tap(find.byKey(const ValueKey('mcp-oauth-open-browser')));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();

    expect(launched, Uri.parse('https://idp.example/authorize'));
    expect(gateway.oauthFlowCalls, 1);
    expect(find.text('Autorización completada.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mcp-oauth-done')));
    await tester.pumpAndSettle();
  });

  testWidgets('OAuth polling pauses in background and cancels on close', (
    tester,
  ) async {
    final gateway = _AdminGateway();
    gateway.polledFlow = gateway.startedFlow;
    await tester.pumpWidget(_app(_OAuthHarness(gateway: gateway)));
    await tester.tap(find.byKey(const ValueKey('open-oauth-harness')));
    await tester.pumpAndSettle();

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(gateway.oauthFlowCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 8));
    expect(gateway.oauthFlowCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(gateway.oauthFlowCalls, 2);

    await tester.tap(find.byKey(const ValueKey('mcp-oauth-close')));
    await tester.pumpAndSettle();
    final callsAfterClose = gateway.oauthFlowCalls;
    await tester.pump(const Duration(seconds: 8));
    expect(gateway.oauthFlowCalls, callsAfterClose);
  });

  testWidgets('webhook receipt is one-shot and disappears after closing', (
    tester,
  ) async {
    final gateway = _AdminGateway();
    await tester.pumpWidget(
      _app(
        AdminIntegrationsScreen(
          gateway: gateway,
          initialSection: AdminIntegrationsSection.webhooks,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('admin-add-webhook')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('webhook-draft-name')),
      'deploy-hook',
    );
    await tester.tap(find.byKey(const ValueKey('webhook-draft-submit')));
    await tester.pumpAndSettle();

    expect(gateway.webhookDrafts, hasLength(1));
    expect(find.text('one-shot-test-secret'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('webhook-one-shot-secret')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('webhook-receipt-done')));
    await tester.pumpAndSettle();

    expect(find.text('one-shot-test-secret'), findsNothing);
    expect(find.byKey(const ValueKey('webhook-one-shot-secret')), findsNothing);
  });

  testWidgets('enabling webhooks warns about Gateway restart', (tester) async {
    final gateway = _AdminGateway()
      ..snapshot = WebhookSnapshot.fromJson({
        'enabled': false,
        'subscriptions': <Object>[],
      });
    await tester.pumpWidget(
      _app(
        AdminIntegrationsScreen(
          gateway: gateway,
          initialSection: AdminIntegrationsSection.webhooks,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Activar webhooks'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('hermes-dialog')),
        matching: find.textContaining('reiniciar el Gateway'),
      ),
      findsOneWidget,
    );
    expect(gateway.enableCalls, 0);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('hermes-dialog')),
        matching: find.text('Activar'),
      ),
    );
    await tester.pumpAndSettle();

    expect(gateway.enableCalls, 1);
  });

  testWidgets('read-only webhook controls issue no mutation', (tester) async {
    final gateway = _AdminGateway()
      ..snapshot = WebhookSnapshot.fromJson({
        'enabled': true,
        'subscriptions': [
          {
            'name': 'deploy',
            'events': ['push'],
            'deliver': 'log',
            'enabled': true,
          },
        ],
      });
    await tester.pumpWidget(
      _app(
        AdminIntegrationsScreen(
          gateway: gateway,
          readOnly: true,
          initialSection: AdminIntegrationsSection.webhooks,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final add = tester.widget<HermesListRow>(
      find.byKey(const ValueKey('admin-add-webhook')),
    );
    final toggle = tester.widget<Switch>(
      find.byKey(const ValueKey('webhook-toggle-deploy')),
    );
    expect(add.onTap, isNull);
    expect(toggle.onChanged, isNull);
    expect(gateway.webhookDrafts, isEmpty);
    expect(gateway.webhookToggles, isEmpty);
    expect(gateway.webhookDeletes, isEmpty);
  });

  testWidgets('guided MCP layout fits 320 px with 200 percent text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    await tester.pumpWidget(
      _app(AdminIntegrationsScreen(gateway: _AdminGateway())),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('admin-add-mcp')),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const ValueKey('admin-add-mcp')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mcp-manual-create-surface')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'A2A is an English server-side status, never a transport action',
    (tester) async {
      final gateway = _AdminGateway()
        ..a2a = const A2aServerCapability(
          enabled: true,
          configured: true,
          gatewayRunning: true,
          state: 'retrying',
        );
      await tester.pumpWidget(
        _app(
          AdminIntegrationsScreen(
            gateway: gateway,
            initialSection: AdminIntegrationsSection.server,
          ),
          locale: const Locale('en'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Server integrations'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('admin-a2a-capability')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Enabled · Configured · Gateway running'),
        findsOneWidget,
      );
      expect(find.textContaining('Retrying'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
    },
  );

  testWidgets('legacy gateway degrades honestly without fake empty data', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AdminIntegrationsScreen(
          gateway: _LegacyGateway(),
          initialSection: AdminIntegrationsSection.webhooks,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Esta versión de Hermes no publica la administración de webhooks.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('admin-add-webhook')), findsNothing);
  });
}
