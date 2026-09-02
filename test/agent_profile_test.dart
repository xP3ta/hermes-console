import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';

void main() {
  group('AgentProfile.fromJson', () {
    test('parsea el perfil por defecto real del Dashboard', () {
      final p = AgentProfile.fromJson({
        'name': 'default',
        'path': '/home/demo/.hermes',
        'is_default': true,
        'model': 'gpt-5.5',
        'provider': 'openai-codex',
        'has_env': true,
        'skill_count': 86,
        'gateway_running': true,
        'description': '',
        'distribution_name': null,
        'distribution_version': null,
        'distribution_source': null,
        'has_alias': false,
      });
      expect(p.name, 'default');
      expect(p.isDefault, isTrue);
      expect(p.model, 'gpt-5.5');
      expect(p.provider, 'openai-codex');
      expect(p.skillCount, 86);
      expect(p.gatewayRunning, isTrue);
      expect(p.isDistribution, isFalse);
    });

    test('reconoce un perfil de distribución', () {
      final p = AgentProfile.fromJson({
        'name': 'research-bot',
        'is_default': false,
        'distribution_name': 'research-bot',
        'distribution_version': '1.2.0',
        'distribution_source': 'github.com/you/research-bot',
        'has_alias': true,
      });
      expect(p.isDistribution, isTrue);
      expect(p.distributionVersion, '1.2.0');
      expect(p.hasAlias, isTrue);
    });

    test('tolera campos ausentes con valores por defecto', () {
      final p = AgentProfile.fromJson({'name': 'minimal'});
      expect(p.name, 'minimal');
      expect(p.skillCount, 0);
      expect(p.gatewayRunning, isFalse);
      expect(p.isDefault, isFalse);
      expect(p.distributionName, isNull);
      expect(p.botChatSessionId, isNull);
      expect(p.lastSession, isNull);
      expect(p.preferredSession, isNull);
      expect(p.workerSession, isNull);
    });

    test(
      'proyecta sesiones de roster oficiales sin conservar payload crudo',
      () {
        final profile = AgentProfile.fromJson({
          'name': 'research',
          'last_session': {
            'id': 'stored-last',
            'title': 'Scratchpad',
            'preview': 'Última respuesta útil',
            'started_at': 100,
            'last_active': 120.5,
            'message_count': 7,
            'secret': 'must-not-survive',
          },
          'preferred_session': {
            'id': 'stored-bot-chat',
            'resolved_id': 'stored-bot-chat--compact-2',
            'root_title': 'Bot Chat',
            'title': 'Bot Chat 2',
            'preview': 'Resultado del bot',
            'started_at': 90,
            'last_active': 130,
            'message_count': 42,
          },
          'worker_session': {
            'id': 'worker-private-id',
            'source': 'kanban',
            'title': 'work kanban T-18: revisar release',
            'last_active': 140,
            'token': 'must-not-survive',
          },
        });

        expect(profile.lastSession?.id, 'stored-last');
        expect(profile.lastSession?.preview, 'Última respuesta útil');
        expect(profile.lastSession?.lastActive, 120.5);
        expect(profile.preferredSession?.id, 'stored-bot-chat');
        expect(
          profile.preferredSession?.resolvedId,
          'stored-bot-chat--compact-2',
        );
        expect(profile.preferredSession?.rootTitle, 'Bot Chat');
        expect(profile.preferredSession?.messageCount, 42);
        expect(profile.workerSession?.source, 'kanban');
        expect(
          profile.workerSession?.title,
          'work kanban T-18: revisar release',
        );
        expect(profile.workerSession?.lastActive, 140);
      },
    );

    test('sesiones ausentes o malformadas degradan sin romper el roster', () {
      final profile = AgentProfile.fromJson({
        'name': 'legacy',
        'last_session': {'id': '', 'preview': 'orphan'},
        'preferred_session': 'unsupported-on-old-gateway',
        'worker_session': {
          'id': 'worker-id',
          'source': 'telegram',
          'title': 'not a worker source',
          'last_active': -1,
        },
      });

      expect(profile.lastSession, isNull);
      expect(profile.preferredSession, isNull);
      expect(profile.workerSession, isNull);
    });

    test('lee el pin Bot Chat oficial sin adoptar otro ui_meta', () {
      final p = AgentProfile.fromJson({
        'name': 'infra',
        'ui_meta': {
          'hermes-bots': {'chat': 'stored-bot-chat', 'color': '#ffaa00'},
          'foreign-plugin': {'chat': 'do-not-use'},
        },
      });

      expect(p.botChatSessionId, 'stored-bot-chat');
      expect(p.botModeUiMeta['color'], '#ffaa00');
      expect(p.botModeMetadataPublished, isTrue);
    });

    test('expone sólo identidad visual Bot Mode validada', () {
      final profile = AgentProfile.fromJson({
        'name': 'infra',
        'ui_meta': {
          'hermes-bots': {
            'title': 'Infra Lead',
            'group': 'Homelab',
            'shape': 'Cloud',
            'color': '#38BDF8',
          },
        },
      });
      final malformed = AgentProfile.fromJson({
        'name': 'bad',
        'ui_meta': {
          'hermes-bots': {'shape': '../triangle', 'color': 'blue'},
        },
      });

      expect(profile.botTitle, 'Infra Lead');
      expect(profile.botGroup, 'Homelab');
      expect(profile.botShape, 'cloud');
      expect(profile.botColorHex, '#38bdf8');
      expect(malformed.botShape, isNull);
      expect(malformed.botColorHex, isNull);
    });

    test('expone hidden y pinned sólo desde bool literal de hermes-bots', () {
      final enabled = AgentProfile.fromJson({
        'name': 'hidden',
        'ui_meta': {
          'hermes-bots': {'hidden': true, 'pinned': true},
        },
      });
      final disabled = AgentProfile.fromJson({
        'name': 'visible',
        'ui_meta': {
          'hermes-bots': {'hidden': false, 'pinned': false},
        },
      });
      final malformed = AgentProfile.fromJson({
        'name': 'legacy',
        'ui_meta': {
          'hermes-bots': {'hidden': 'true', 'pinned': 1},
        },
      });

      expect((enabled.botHidden, enabled.botPinned), (true, true));
      expect((disabled.botHidden, disabled.botPinned), (false, false));
      expect((malformed.botHidden, malformed.botPinned), (false, false));
      expect(
        (
          const AgentProfile(name: 'plain').botHidden,
          const AgentProfile(name: 'plain').botPinned,
        ),
        (false, false),
      );
    });

    test('conserva el wire Blobatar oficial máximo para validación tipada', () {
      final seed = 'a' * 64;
      final profile = AgentProfile.fromJson({
        'name': 'blob',
        'ui_meta': {
          'hermes-bots': {
            'shape': 'blobatar:$seed:triangle',
            'imageKind': 'shape',
            'custom': true,
          },
        },
      });

      expect(profile.botShape, 'blobatar:$seed:triangle');
      expect(profile.botImageKind, 'shape');
      expect(profile.hasCustomBotAppearance, isTrue);
    });

    test('detecta el avatar server-side del profile', () {
      final profile = AgentProfile.fromJson(const {
        'name': 'manager',
        'has_avatar': true,
      });

      expect(profile.hasAvatar, isTrue);
    });

    test('decodifica sólo avatares raster acotados', () {
      final avatar = AgentProfileAvatar.fromDataUri(
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      );

      expect(avatar.mimeType, 'image/png');
      expect(avatar.bytes, isNotEmpty);
      expect((avatar.width, avatar.height), (1, 1));
      expect(
        () => AgentProfileAvatar.fromDataUri(
          'data:image/svg+xml;base64,PHN2Zy8+',
        ),
        throwsFormatException,
      );
      expect(
        () => AgentProfileAvatar.fromDataUri('data:image/png;base64,YXZhdGFy'),
        throwsFormatException,
      );
    });

    test('aplica el límite upstream exacto de 2 MB', () {
      final accepted = _pngBytes(AgentProfileAvatar.maxBytes);
      final rejected = _pngBytes(AgentProfileAvatar.maxBytes + 1);

      expect(
        AgentProfileAvatar.fromDataUri(_pngDataUri(accepted)).bytes.length,
        AgentProfileAvatar.maxBytes,
      );
      expect(
        () => AgentProfileAvatar.fromDataUri(_pngDataUri(rejected)),
        throwsFormatException,
      );
    });

    test('rechaza base64 no canónico y dimensiones desproporcionadas', () {
      final valid = _pngDataUri(_pngBytes(24));
      final split = valid.indexOf(',') + 5;
      final withWhitespace =
          '${valid.substring(0, split)}\n'
          '${valid.substring(split)}';

      expect(
        () => AgentProfileAvatar.fromDataUri(withWhitespace),
        throwsFormatException,
      );
      expect(
        () => AgentProfileAvatar.fromDataUri(
          _pngDataUri(_pngBytes(24, width: AgentProfileAvatar.maxEdge + 1)),
        ),
        throwsFormatException,
      );
    });

    test('acepta el encabezado mínimo lossless de WebP', () {
      final bytes = List<int>.filled(25, 0)
        ..setRange(0, 4, ascii.encode('RIFF'))
        ..setRange(8, 12, ascii.encode('WEBP'))
        ..setRange(12, 16, ascii.encode('VP8L'))
        ..[20] = 0x2f;

      final avatar = AgentProfileAvatar.fromDataUri(
        'data:image/webp;base64,${base64Encode(bytes)}',
      );

      expect((avatar.width, avatar.height), (1, 1));
    });

    test('ignora un pin Bot Chat malformado', () {
      final p = AgentProfile.fromJson({
        'name': 'infra',
        'ui_meta': {
          'hermes-bots': {'chat': 'bad\nchat'},
        },
      });

      expect(p.botChatSessionId, isNull);
      expect(p.hasInvalidBotChatPin, isTrue);
      expect(p.botModeMetadataPublished, isTrue);
    });

    test('no confunde un id móvil provisional con un pin durable', () {
      final profile = AgentProfile.fromJson({
        'name': 'manager',
        'ui_meta': {
          'hermes-bots': {'chat': 'mob-bot-manager'},
        },
      });

      expect(profile.botChatSessionId, isNull);
      expect(profile.hasInvalidBotChatPin, isTrue);
    });

    test('distingue namespace Bot ausente, vacío y malformado', () {
      final absent = AgentProfile.fromJson({'name': 'infra'});
      final empty = AgentProfile.fromJson({
        'name': 'infra',
        'ui_meta': {'hermes-bots': <String, dynamic>{}},
      });
      final malformed = AgentProfile.fromJson({
        'name': 'infra',
        'ui_meta': {'hermes-bots': 'corrupt'},
      });

      expect(absent.botModeMetadataPublished, isFalse);
      expect(absent.hasInvalidBotChatPin, isFalse);
      expect(empty.botModeMetadataPublished, isTrue);
      expect(empty.botChatSessionId, isNull);
      expect(empty.hasInvalidBotChatPin, isFalse);
      expect(malformed.botModeMetadataPublished, isFalse);
      expect(malformed.hasInvalidBotModeMetadata, isTrue);
      expect(malformed.hasInvalidBotChatPin, isTrue);
    });

    test('un chat null explícito es un slot vacío, no un pin corrupto', () {
      // Desktop señala "sin Bot Chat canónico" escribiendo `chat: null` en el
      // namespace (hermes-bots resetea el pin así antes de recrearlo) y el
      // gateway lo devuelve verbatim en profiles.list.
      final profile = AgentProfile.fromJson({
        'name': 'codex-qa',
        'ui_meta': {
          'hermes-bots': {'chat': null, 'title': 'QA'},
        },
      });

      expect(profile.botModeMetadataPublished, isTrue);
      expect(profile.botModeUiMeta.containsKey('chat'), isTrue);
      expect(profile.botChatSessionId, isNull);
      expect(profile.hasInvalidBotChatPin, isFalse);
      expect(profile.desktopClearedBotChatPin, isTrue);
      expect(profile.gatewayBotChatSessionId, isNull);
    });

    test('appearance-only hermes-bots is not a Desktop pin reset', () {
      final profile = AgentProfile.fromJson({
        'name': 'infra',
        'ui_meta': {
          'hermes-bots': {'title': 'Infra', 'shape': 'blobatar'},
        },
        'preferred_session': {
          'id': '20260824_131642_e57b4c',
          'resolved_id': '20260824_131642_e57b4c--c1',
          'root_title': 'Bot Chat',
          'title': 'Bot Chat 2',
        },
      });

      expect(profile.botModeMetadataPublished, isTrue);
      expect(profile.desktopClearedBotChatPin, isFalse);
      expect(profile.botChatSessionId, isNull);
      expect(profile.gatewayBotChatSessionId, '20260824_131642_e57b4c--c1');
    });

    test('preferred_session that is not Bot Chat is not a canonical pin', () {
      final profile = AgentProfile.fromJson({
        'name': 'infra',
        'preferred_session': {'id': 'scratch', 'title': 'Scratch work'},
      });

      expect(profile.gatewayBotChatSessionId, isNull);
    });

    test('ui_meta top-level no-null debe ser un objeto', () {
      final explicitNull = AgentProfile.fromJson({
        'name': 'infra',
        'ui_meta': null,
      });
      final malformed = AgentProfile.fromJson({
        'name': 'infra',
        'ui_meta': 'corrupt',
      });

      expect(explicitNull.hasInvalidBotModeMetadata, isFalse);
      expect(malformed.botModeMetadataPublished, isFalse);
      expect(malformed.hasInvalidBotModeMetadata, isTrue);
      expect(malformed.hasInvalidBotChatPin, isTrue);
    });
  });
}

List<int> _pngBytes(int length, {int width = 1, int height = 1}) {
  assert(length >= 24);
  final bytes = List<int>.filled(length, 0)
    ..setRange(0, 8, const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    ..setRange(12, 16, ascii.encode('IHDR'));
  void putU32(int offset, int value) {
    bytes[offset] = (value >> 24) & 0xff;
    bytes[offset + 1] = (value >> 16) & 0xff;
    bytes[offset + 2] = (value >> 8) & 0xff;
    bytes[offset + 3] = value & 0xff;
  }

  putU32(16, width);
  putU32(20, height);
  return bytes;
}

String _pngDataUri(List<int> bytes) =>
    'data:image/png;base64,${base64Encode(bytes)}';
