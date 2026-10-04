// Which Settings › Advanced page a server config field belongs to: the table
// of Hermes Desktop's `config-subpages.ts` (a field is on a page if its path is
// listed or starts with one of the page's prefixes), minus everything Console
// never edits from these pages.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/settings/server_config_pages.dart';

void main() {
  group('serverConfigPageForField', () {
    const expected = <String, ServerConfigPage>{
      'model_context_length': ServerConfigPage.mainModel,
      'agent.reasoning_effort': ServerConfigPage.mainModel,
      'agent.service_tier': ServerConfigPage.mainModel,
      'model.provider': ServerConfigPage.mainModel,
      'display.personality': ServerConfigPage.behavior,
      'timezone': ServerConfigPage.behavior,
      'display.show_reasoning': ServerConfigPage.behavior,
      'terminal.cwd': ServerConfigPage.projects,
      'desktop.repo_scan_depth': ServerConfigPage.projects,
      'terminal.persistent_shell': ServerConfigPage.shell,
      'terminal.env_passthrough': ServerConfigPage.shell,
      'code_execution.mode': ServerConfigPage.files,
      'file_read_max_chars': ServerConfigPage.files,
      'browser.allow_private_urls': ServerConfigPage.network,
      'browser.auto_local_for_private_urls': ServerConfigPage.network,
      'context.engine': ServerConfigPage.context,
      'compression.enabled': ServerConfigPage.context,
      'auxiliary.compression.provider': ServerConfigPage.context,
      'voice.voice_chat_mode': ServerConfigPage.conversation,
      'voice.max_recording_seconds': ServerConfigPage.conversation,
      'voice.client_direct': ServerConfigPage.conversation,
      'voice.gpt_live.voice': ServerConfigPage.conversation,
      'agent.max_turns': ServerConfigPage.runtime,
      'agent.api_max_retries': ServerConfigPage.runtime,
    };

    for (final entry in expected.entries) {
      test('${entry.key} is on ${entry.value.name}', () {
        expect(serverConfigPageForField(entry.key), entry.value);
      });
    }

    test('a field Desktop lists on two pages belongs to the first', () {
      expect(
        serverConfigPageForField('agent.service_tier'),
        ServerConfigPage.mainModel,
      );
    });

    test('paths outside the table belong to no page', () {
      for (final path in const [
        'display.skin',
        'terminal.backend',
        'security.redact_secrets',
        'delegation.max_iterations',
        'voice',
        'desktop.other',
        'compressionx.enabled',
        'contextual.thing',
      ]) {
        expect(serverConfigPageForField(path), isNull, reason: path);
      }
    });
  });

  group('isEditableServerConfigField', () {
    test('model is never edited from these pages', () {
      expect(isEditableServerConfigField('model', 'string'), isFalse);
    });

    test('object fields are never edited', () {
      expect(isEditableServerConfigField('terminal.cwd', 'object'), isFalse);
    });

    test('paths that look like secrets are never edited', () {
      for (final path in const [
        'voice.gpt_live.api_key',
        'voice.gpt_live.token',
        'voice.gpt_live.client_secret',
        'context.password',
        'compression.some_KEY',
      ]) {
        expect(
          isEditableServerConfigField(path, 'string'),
          isFalse,
          reason: path,
        );
      }
    });

    test('agent.api_max_retries stays editable although it contains api_', () {
      expect(
        isEditableServerConfigField('agent.api_max_retries', 'number'),
        isTrue,
      );
    });

    test('a listed scalar field is editable', () {
      expect(isEditableServerConfigField('terminal.cwd', 'string'), isTrue);
      expect(isEditableServerConfigField('timezone', 'select'), isTrue);
    });

    test('a path outside the table is not editable', () {
      expect(isEditableServerConfigField('display.skin', 'string'), isFalse);
    });
  });
}
