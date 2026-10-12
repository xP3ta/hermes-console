import 'package:hermes_android/core/models/bot_visual_identity.dart';
import 'package:hermes_android/core/services/bot_profile_client.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'profile_model_fakes.dart';

SavedConnection capabilityConnection() => SavedConnection(
  id: 'profile-capabilities-test',
  label: 'Hermes',
  host: '127.0.0.1',
  port: 8642,
  apiKey: '',
);

Map<String, dynamic> capabilitySnapshot({
  int skillCount = 3,
  bool emptyMcp = false,
}) => {
  'skills': [
    for (var i = 0; i < skillCount; i++)
      {
        'name': 'skill-$i',
        'description': 'Descripción de la skill $i',
        'group': i < 2 ? 'Trabajo' : 'Personal',
        'enabled': i != 1,
      },
  ],
  'toolsets_pinned': true,
  'toolsets': [
    {
      'name': 'web',
      'label': 'Web',
      'description': 'Buscar páginas y leer su contenido',
      'enabled': true,
    },
    {
      'name': 'terminal',
      'label': 'Terminal',
      'description': 'Ejecutar comandos',
      'enabled': false,
    },
    {
      'name': 'memory',
      'label': 'Memoria',
      'description': 'Recordar información',
      'enabled': true,
    },
  ],
  'mcp_servers': [
    if (!emptyMcp) ...[
      {
        'name': 'calendar',
        'label': 'Calendario',
        'enabled': true,
        'status': 'connected',
      },
      {'name': 'notes', 'label': 'Notas', 'enabled': false},
    ],
  ],
};

final class FakeProfileCapabilityGateway extends FakeIdentityGateway
    implements BotProfileGateway {
  Map<String, dynamic> snapshot;
  int skillReads = 0;
  int capabilityReads = 0;
  final configures = <(String, Map<String, dynamic>)>[];
  final disabledSkillWrites = <(String, List<String>)>[];
  final identities = <BotVisualIdentity>[];

  FakeProfileCapabilityGateway({Map<String, dynamic>? snapshot})
    : snapshot = snapshot ?? capabilitySnapshot();

  @override
  Future<List<DesktopProfileSkill>?> describeProfileSkills(
    String profile,
  ) async {
    skillReads++;
    return [
      for (final entry in snapshot['skills'] as List<Map<String, dynamic>>)
        DesktopProfileSkill(
          name: entry['name'] as String,
          enabled: entry['enabled'] != false,
          description: entry['description'] as String?,
          group: entry['group'] as String?,
        ),
    ];
  }

  @override
  Future<Map<String, dynamic>> describeBotProfile(String profile) async {
    capabilityReads++;
    return snapshot;
  }

  @override
  Future<Map<String, dynamic>> configureBotProfile(
    String profile,
    Map<String, dynamic> changes,
  ) async {
    configures.add((profile, Map<String, dynamic>.from(changes)));
    return {
      'applied': {'toolsets': true, 'mcp_servers': true, 'skills': true},
    };
  }

  @override
  Future<void> setProfileDisabledSkills({
    required String profile,
    required List<String> disabledSkills,
  }) async {
    disabledSkillWrites.add((profile, List.of(disabledSkills)));
  }

  @override
  Future<void> saveProfileBotMeta({
    required String profile,
    String? title,
    String? shape,
    String? colorHex,
    bool? hidden,
    bool? pinned,
    int? createdAtMs,
    BotVisualIdentity? identity,
  }) async {
    if (identity != null) identities.add(identity);
  }

  @override
  Future<void> patchBotMetadata(
    String profile,
    Map<String, dynamic> patch, {
    Set<String> remove = const {},
  }) async {}

  @override
  Future<String> duplicateBotProfile(String profile) async => '$profile-2';
}
