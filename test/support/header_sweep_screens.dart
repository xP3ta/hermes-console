// The screens of the overlap sweep (see header_sweep.dart). To cover another
// screen add a [SweepScreen] to [sweepScreens]: an id and how to build it with
// fake data. The runner (test/header_overlap_sweep_test.dart) mounts it at
// 360, 600 and 840 dp, at 1x and 2x text, and fails with one table of what
// overlaps, touches or overflows.
//
// A screen that needs a server is given a fake: the control gateways answer
// what the screen asks and fail what it does not; a dashboard client answers
// from memory.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/profile/profile_hub_screen.dart';
import 'package:hermes_android/core/bots/ui/profile/profile_model_picker.dart'
    show ProfileModelCatalogs;
import 'package:hermes_android/core/capabilities/capabilities_screen.dart'
    show CapabilitiesSnapshotCache;
import 'package:hermes_android/core/models/admin_integrations.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/desktop_control_center.dart';
import 'package:hermes_android/core/screens/activity_screen.dart';
import 'package:hermes_android/core/screens/admin_integrations_screen.dart';
import 'package:hermes_android/core/screens/app_settings_screen.dart';
import 'package:hermes_android/core/screens/cron_screen.dart';
import 'package:hermes_android/core/screens/env_keys_screen.dart';
import 'package:hermes_android/core/screens/extensions_center_screen.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/screens/look_feel_screen.dart';
import 'package:hermes_android/core/screens/memory_screen.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/screens/notification_settings_screen.dart';
import 'package:hermes_android/core/screens/profile_editor_screen.dart';
import 'package:hermes_android/core/screens/profiles_screen.dart';
import 'package:hermes_android/core/screens/security_info_screen.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/screens/themes_screen.dart';
import 'package:hermes_android/core/screens/usage_analytics_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/services/profile_pet_service.dart';
import 'package:hermes_android/core/settings/settings_sections.dart';
import 'package:hermes_android/core/theme/look_feel.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'a11y_main_screen_harness.dart';
import 'header_sweep.dart';
import 'nav_harness.dart';
import 'profile_model_fakes.dart';

/// A control gateway that answers what a screen needs to show its page and
/// fails everything else: the page then shows its own error state, which is
/// also a page.
class SweepControlGateway
    implements
        HermesDesktopControlGateway,
        HermesMcpProvisioningGateway,
        HermesWebhookManagementGateway,
        HermesServerPlatformCapabilitiesGateway,
        HermesExtensionManagementGateway {
  @override
  Future<ExtensionsInventory> extensionsInventory({
    String runtimeSessionId = '',
  }) async => const ExtensionsInventory(
    plugins: [
      DesktopPluginEntry(
        name: 'memory-tools',
        version: '1.2.0',
        description: 'Memoria local con una descripción algo larga',
        source: 'hermes-catalog',
        status: 'enabled',
      ),
      DesktopPluginEntry(
        name: 'browser-helper',
        version: '0.4.1',
        description: 'Navegación asistida',
        source: 'hermes-catalog',
        status: 'disabled',
      ),
    ],
    toolsets: [
      DesktopToolsetEntry(
        name: 'web',
        description: 'Herramientas web seguras',
        toolCount: 2,
        enabled: false,
        tools: ['search', 'fetch'],
      ),
      DesktopToolsetEntry(
        name: 'terminal',
        description: 'Terminal del servidor',
        toolCount: 1,
        enabled: true,
        tools: ['run'],
      ),
    ],
  );

  @override
  Future<List<DesktopMcpServerEntry>> mcpServers() async => const [
    DesktopMcpServerEntry(
      name: 'filesystem-safe',
      transport: 'stdio',
      endpointLabel: 'npx -y server-filesystem',
      auth: 'env',
      enabled: true,
      toolCount: 4,
    ),
    DesktopMcpServerEntry(
      name: 'reports',
      transport: 'http',
      endpointLabel: 'https://reports.example.test/mcp',
      auth: 'oauth',
      enabled: false,
      toolCount: null,
    ),
  ];

  @override
  Future<List<DesktopMcpCatalogEntry>> mcpCatalog() async => const [];

  @override
  Future<List<DesktopPluginManagementEntry>> managedPlugins() async => const [];

  @override
  Future<WebhookSnapshot> webhookSnapshot() async => WebhookSnapshot.fromJson({
    'enabled': true,
    'base_url': 'https://agent.example',
    'subscriptions': <Object>[],
  });

  @override
  Future<A2aServerCapability> a2aServerCapability() async =>
      const A2aServerCapability(
        enabled: true,
        configured: true,
        gatewayRunning: true,
        state: 'connected',
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future<Never>.error(UnsupportedError('${invocation.memberName}'));
}

/// A dashboard client with a little data in memory: the usage analytics and a
/// `.env`; everything else is a plain failure the page shows as such.
class SweepDashboard extends DashboardClient {
  SweepDashboard()
    : super(
        host: 'sweep.example.test',
        manualToken: 'token',
        httpClientOverride: MockClient((_) async => http.Response('{}', 404)),
      );

  @override
  Future<Map<String, dynamic>> apiGet(
    String endpoint, {
    bool retried = false,
  }) async {
    if (!endpoint.contains('usage')) {
      throw http.ClientException('sin datos: $endpoint');
    }
    return {
      'period_days': 30,
      'daily': [
        {'day': '2026-10-30', 'input_tokens': 1000, 'output_tokens': 500},
        {'day': '2026-10-31', 'input_tokens': 3000, 'output_tokens': 1500},
      ],
      'by_model': [
        {
          'model': 'alpha-1',
          'input_tokens': 3000,
          'output_tokens': 1000,
          'estimated_cost': 0.1,
          'sessions': 4,
        },
      ],
      'totals': {
        'total_input': 4000,
        'total_output': 2000,
        'total_sessions': 7,
        'total_api_calls': 12,
        'total_estimated_cost': 0.1234,
        'total_actual_cost': 0.0,
      },
    };
  }

  @override
  Future<Map<String, dynamic>> getEnvVars({String? profile}) async => {
    'OPENAI_API_KEY': {
      'is_set': true,
      'redacted_value': 'sk-…4455',
      'description': 'Credencial de OpenAI',
      'category': 'provider',
      'is_password': true,
      'channel_managed': false,
      'custom': false,
    },
    'BROWSER_SESSION_TIMEOUT': {
      'is_set': false,
      'redacted_value': null,
      'description': 'Segundos antes de que termine una sesión del navegador',
      'category': 'tool',
      'is_password': false,
      'channel_managed': false,
      'custom': false,
    },
  };
}

Future<ConnectionManager> _manager() async {
  installA11yPlatformMocks();
  return createA11yManager();
}

Session _session(int i, String title, String preview) => Session(
  id: 'sweep-$i',
  title: title,
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 4 + i,
  isActive: i == 0,
  preview: preview,
  startedAt: 1.0 + i,
);

SweepScreen _section(SettingsSection section) => SweepScreen(
  'ajustes/${section.name}',
  (tester) async => SettingsSectionScreen(
    section: section,
    connection: a11yConnection,
    connManager: await _manager(),
  ),
);

SweepScreen _integrations(AdminIntegrationsSection section) => SweepScreen(
  'integraciones/${section.name}',
  (tester) async => AdminIntegrationsScreen(
    gateway: SweepControlGateway(),
    initialSection: section,
  ),
  settle: (tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  },
);

/// Every screen of the sweep. Add yours here.
final List<SweepScreen> sweepScreens = [
  SweepScreen(
    'inicio',
    (tester) async => HomeDashboardScreen(connManager: await _manager()),
    note: 'sin conexión (estado vacío)',
  ),
  SweepScreen(
    'conversaciones',
    (tester) async => SessionListScreen(
      connection: a11yConnection,
      connManager: await _manager(),
      clientOverride: A11yApiClient(
        sessions: [
          _session(0, 'Revisión de la versión', 'Revisa la versión 1.4.0'),
          _session(
            1,
            'Una conversación con un título bastante largo que no cabe',
            'Un resumen igual de largo para ver cómo se recorta en dos líneas',
          ),
          _session(2, 'Notas', 'Hecho'),
        ],
      ),
      eventStreamOverride: const Stream.empty(),
    ),
  ),
  SweepScreen(
    'ajustes',
    (tester) async => SettingsScreen(
      connection: a11yConnection,
      connManager: await _manager(),
    ),
  ),
  SweepScreen(
    'ajustes-de-la-app',
    (tester) async => AppSettingsScreen(
      connection: a11yConnection,
      connManager: await _manager(),
    ),
  ),
  for (final section in SettingsSection.values) _section(section),
  SweepScreen('look-and-feel', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    return LookFeelScreen(
      prefsForTesting: LookFeelPrefs(await SharedPreferences.getInstance()),
      fontIdForTesting: ValueNotifier<String>('system'),
      onFontForTesting: (id) async {},
    );
  }, note: 'preferencias vacías'),
  SweepScreen('temas', (tester) async => const ThemesScreen()),
  SweepScreen(
    'perfiles',
    (tester) async => ProfilesScreen(
      connection: a11yConnection,
      connManager: await _manager(),
      clientOverride: SweepDashboard(),
      gatewayProfilesOverride: () async => const [
        AgentProfile(
          name: 'default',
          isDefault: true,
          description: 'Perfil principal',
          skillCount: 2,
        ),
        AgentProfile(
          name: 'release',
          description: 'Verificación de versiones con un texto largo',
          skillCount: 4,
        ),
      ],
    ),
  ),
  SweepScreen('perfil-hub', (tester) async {
    final gateway = FakeModelGateway();
    final registry = navRoster(navConnection());
    return ProfileHubScreen(
      connection: navConnection(),
      connManager: await navManager(),
      profile: navSecondary,
      rosterRegistry: registry,
      modelGateway: gateway,
      profileGateway: gateway,
      capabilitiesCache: CapabilitiesSnapshotCache(),
    );
  }),
  SweepScreen('editar-perfil', (tester) async {
    final gateway = FakeIdentityGateway();
    return ProfileEditorScreen(
      connection: a11yConnection,
      profile: modelBot,
      gateway: gateway,
      petService: ProfilePetService(gateway),
      modelCatalogs: ProfileModelCatalogs(),
    );
  }),
  _integrations(AdminIntegrationsSection.mcp),
  _integrations(AdminIntegrationsSection.webhooks),
  _integrations(AdminIntegrationsSection.server),
  SweepScreen(
    'extensiones',
    (tester) async => ExtensionsCenterScreen(gateway: SweepControlGateway()),
    note: 'la reorganiza extensions-unified: se añaden aquí sus pestañas',
  ),
  SweepScreen(
    'uso',
    (tester) async => UsageAnalyticsScreen(
      connection: a11yConnection,
      profile: '',
      clientOverride: SweepDashboard(),
    ),
  ),
  SweepScreen(
    'keys',
    (tester) async => EnvKeysScreen(
      connection: a11yConnection,
      profile: '',
      clientOverride: SweepDashboard(),
      secureScope: () async => () async {},
      appLocked: ValueNotifier(false),
    ),
  ),
  SweepScreen(
    'memoria',
    (tester) async => MemoryScreen(
      connection: a11yConnection,
      dashboardClientForTesting: SweepDashboard(),
      appLockedForTesting: ValueNotifier(false),
    ),
    note: 'sin datos de memoria (estado de error)',
  ),
  SweepScreen(
    'logs',
    (tester) async => ActivityScreen(
      connection: a11yConnection,
      clientOverride: SweepDashboard(),
    ),
    note: 'sin datos de registro (estado de error)',
  ),
  SweepScreen(
    'cron',
    (tester) async => CronScreen(
      connection: a11yConnection,
      clientOverride: SweepDashboard(),
    ),
    note: 'sin datos (estado de error)',
  ),
  SweepScreen(
    'modelos',
    (tester) async => ModelsScreen(
      connection: a11yConnection,
      dashboardClientForTesting: SweepDashboard(),
    ),
    note: 'sin datos (estado de error)',
  ),
  SweepScreen('notificaciones', (tester) async {
    await _manager();
    // The foreground service answers yes/no questions with a no.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_foreground_task/methods'),
          (call) async => RegExp(r'^(is|can|check|has)').hasMatch(call.method)
              ? false
              : null,
        );
    return const NotificationSettingsScreen();
  }),
  SweepScreen(
    'seguridad',
    (tester) async => SecurityInfoScreen(connManager: await _manager()),
  ),
];
