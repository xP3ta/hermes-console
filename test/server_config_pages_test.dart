// Which Advanced page owns a server config field: the Desktop table
// (`config-subpages.ts`), its prefixes, and what is never shown.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/settings/server_config_pages.dart';

Map<String, dynamic> _schema(Map<String, Map<String, Object?>> fields) => {
  'fields': fields,
  'category_order': const ['general'],
};

void main() {
  group('page of a path', () {
    const expected = <String, Set<ServerConfigPage>>{
      'model_context_length': {ServerConfigPage.main},
      'agent.reasoning_effort': {ServerConfigPage.main},
      'agent.service_tier': {ServerConfigPage.main},
      'model.context_length': {ServerConfigPage.main},
      'display.personality': {ServerConfigPage.behavior},
      'timezone': {ServerConfigPage.behavior},
      'display.show_reasoning': {ServerConfigPage.behavior},
      'terminal.cwd': {ServerConfigPage.projects},
      'desktop.repo_scan_depth': {ServerConfigPage.projects},
      'terminal.persistent_shell': {ServerConfigPage.shell},
      'terminal.env_passthrough': {ServerConfigPage.shell},
      'code_execution.mode': {ServerConfigPage.files},
      'file_read_max_chars': {ServerConfigPage.files},
      'browser.allow_private_urls': {ServerConfigPage.network},
      'browser.auto_local_for_private_urls': {ServerConfigPage.network},
      'context.engine': {ServerConfigPage.context},
      'compression.enabled': {ServerConfigPage.context},
      'auxiliary.compression.model': {ServerConfigPage.context},
      'voice.voice_chat_mode': {ServerConfigPage.conversation},
      'voice.max_recording_seconds': {ServerConfigPage.conversation},
      'voice.client_direct': {ServerConfigPage.conversation},
      'voice.gpt_live.voice': {ServerConfigPage.conversation},
      'agent.max_turns': {ServerConfigPage.runtime},
      'agent.api_max_retries': {ServerConfigPage.runtime},
    };
    for (final entry in expected.entries) {
      test(entry.key, () {
        expect(serverConfigPagesOf(entry.key), entry.value);
      });
    }

    test('a field in two table rows belongs to the first page only', () {
      final schema = _schema({
        'agent.service_tier': {'type': 'string'},
        'agent.max_turns': {'type': 'number'},
      });
      expect(
        serverConfigFieldsOf(ServerConfigPage.main, schema).map((f) => f.path),
        ['agent.service_tier'],
      );
      expect(
        serverConfigFieldsOf(
          ServerConfigPage.runtime,
          schema,
        ).map((f) => f.path),
        ['agent.max_turns'],
      );
    });

    test('a path that is in no table row belongs to no page', () {
      for (final path in const [
        'logging.level',
        'terminal.backend',
        'display.skin',
        'agent.max_turns_extra',
        'memory.provider',
        'voice',
        'compressionx',
      ]) {
        expect(serverConfigPagesOf(path), isEmpty, reason: path);
      }
    });
  });

  group('never shown', () {
    test('the model itself is changed by the picker', () {
      expect(serverConfigPagesOf('model'), isEmpty);
      expect(
        serverConfigFieldsOf(
          ServerConfigPage.main,
          _schema({
            'model': {'type': 'string'},
            'model_context_length': {'type': 'number'},
          }),
        ).map((field) => field.path),
        ['model_context_length'],
      );
    });

    test('an object field is not editable here', () {
      final fields = serverConfigFieldsOf(
        ServerConfigPage.main,
        _schema({
          'model.extra': {'type': 'object'},
          'model.context_length': {'type': 'number'},
        }),
      );
      expect(fields.map((field) => field.path), ['model.context_length']);
    });

    test('a path that names a secret is dropped', () {
      for (final path in const [
        'model.api_key',
        'model.base_url_token',
        'voice.gpt_live.secret',
        'voice.gpt_live.password',
        'voice.gpt_live.API_KEY_ENV',
        'compression.api_url',
      ]) {
        expect(
          serverConfigFieldsOf(
            path.startsWith('model')
                ? ServerConfigPage.main
                : path.startsWith('voice')
                ? ServerConfigPage.conversation
                : ServerConfigPage.context,
            _schema({
              path: {'type': 'string'},
            }),
          ),
          isEmpty,
          reason: path,
        );
      }
    });

    test('a table field is kept even when its name has api_', () {
      expect(
        serverConfigFieldsOf(
          ServerConfigPage.runtime,
          _schema({
            'agent.api_max_retries': {'type': 'number'},
          }),
        ).map((field) => field.path),
        ['agent.api_max_retries'],
      );
    });

    test('a type the editor cannot render is dropped', () {
      expect(
        serverConfigFieldsOf(
          ServerConfigPage.shell,
          _schema({
            'terminal.persistent_shell': {'type': 'mystery'},
            'terminal.env_passthrough': {'type': 'list'},
          }),
        ).map((field) => field.path),
        ['terminal.env_passthrough'],
      );
    });
  });

  group('field types', () {
    test('only boolean, number, string, list and select are editable', () {
      for (final type in <Object?>[
        'mystery',
        'object',
        'integer',
        'Boolean',
        '',
        null,
        7,
        ['boolean'],
      ]) {
        expect(
          serverConfigFieldsOf(
            ServerConfigPage.projects,
            _schema({
              'terminal.cwd': {'type': type},
            }),
          ),
          isEmpty,
          reason: 'type $type',
        );
      }
      for (final type in const [
        'boolean',
        'number',
        'string',
        'list',
        'select',
      ]) {
        expect(
          serverConfigFieldsOf(
            ServerConfigPage.projects,
            _schema({
              'terminal.cwd': {
                'type': type,
                'options': ['a'],
              },
            }),
          ).map((f) => f.path),
          ['terminal.cwd'],
          reason: 'type $type',
        );
      }
    });
  });

  group('fields of a page', () {
    test('exactly the ones the schema brings, in schema order', () {
      final fields = serverConfigFieldsOf(
        ServerConfigPage.main,
        _schema({
          'agent.service_tier': {
            'type': 'select',
            'options': ['fast', 'auto'],
          },
          'display.personality': {'type': 'string'},
          'agent.reasoning_effort': {
            'type': 'select',
            'description': 'Reasoning effort',
            'options': ['low', 'high'],
          },
        }),
      );
      expect(fields.map((field) => field.path), [
        'agent.service_tier',
        'agent.reasoning_effort',
      ]);
      final effort = fields.last;
      expect(effort.type, ServerConfigFieldType.select);
      expect(effort.description, 'Reasoning effort');
      expect(effort.options, ['low', 'high']);
    });

    test('null and wrong-typed optional parts are absent, not errors', () {
      final fields = serverConfigFieldsOf(
        ServerConfigPage.behavior,
        _schema({
          'timezone': {
            'type': 'string',
            'description': null,
            'options': null,
            'category': 7,
          },
        }),
      );
      expect(fields.single.description, isNull);
      expect(fields.single.options, isEmpty);
    });

    test('a select without options is a plain string', () {
      final field = serverConfigFieldsOf(
        ServerConfigPage.behavior,
        _schema({
          'display.personality': {'type': 'select', 'options': <Object?>[]},
        }),
      ).single;
      expect(field.type, ServerConfigFieldType.string);
    });

    test('a schema without fields yields none', () {
      expect(serverConfigFieldsOf(ServerConfigPage.main, const {}), isEmpty);
      expect(
        serverConfigFieldsOf(ServerConfigPage.main, {'fields': 'oops'}),
        isEmpty,
      );
    });

    test('pagesWithFields lists only pages that have a field', () {
      final pages = serverConfigPagesWithFields(
        _schema({
          'timezone': {'type': 'string'},
          'agent.max_turns': {'type': 'number'},
          'logging.level': {'type': 'string'},
        }),
      );
      expect(pages, [ServerConfigPage.behavior, ServerConfigPage.runtime]);
    });
  });
}
