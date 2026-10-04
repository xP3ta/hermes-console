// The local index of Advanced and Settings: built from what is already
// loaded, filtered in memory, never touching the network.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/server_toolset.dart';
import 'package:hermes_android/core/settings/server_config_pages.dart';
import 'package:hermes_android/core/settings/settings_search.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Map<String, dynamic> _schema() => {
  'fields': {
    'agent.reasoning_effort': {
      'type': 'select',
      'description': 'Reasoning effort for the main model',
      'options': ['low', 'high'],
    },
    'timezone': {'type': 'string', 'description': 'IANA time zone'},
    'terminal.persistent_shell': {'type': 'boolean'},
    'model.api_key': {'type': 'string', 'description': 'Reasoning key'},
    'logging.level': {'type': 'string', 'description': 'Reasoning of logs'},
  },
};

List<SettingsSearchEntry> _index(String locale, {List<ServerToolset>? tools}) =>
    buildSettingsSearchIndex(
      s: lookupStrings(Locale(locale)),
      schema: _schema(),
      toolsets: tools ?? const [],
    );

void main() {
  group('what is indexed', () {
    test('a field row per field of a page, none for secrets or strangers', () {
      final fields = _index('es')
          .where((e) => e.kind == SettingsSearchKind.field)
          .map((e) => e.path)
          .toList();
      expect(fields, [
        'agent.reasoning_effort',
        'timezone',
        'terminal.persistent_shell',
      ]);
    });

    test('a page row only for pages that have fields', () {
      final pages = _index('es')
          .where((e) => e.kind == SettingsSearchKind.page)
          .map((e) => e.page)
          .toList();
      expect(pages, [
        ServerConfigPage.main,
        ServerConfigPage.behavior,
        ServerConfigPage.shell,
      ]);
    });

    test('a field on two pages is found on each', () {
      final index = buildSettingsSearchIndex(
        s: lookupStrings(const Locale('es')),
        schema: {
          'fields': {
            'agent.service_tier': {
              'type': 'select',
              'options': ['a', 'b'],
            },
          },
        },
      );
      expect(
        index
            .where((e) => e.kind == SettingsSearchKind.field)
            .map((e) => e.page),
        [ServerConfigPage.main, ServerConfigPage.runtime],
      );
    });

    test('the main Settings sections are there', () {
      final sections = _index('es')
          .where((e) => e.kind == SettingsSearchKind.settingsSection)
          .map((e) => e.settingsSection)
          .toSet();
      expect(sections, containsAll(SettingsSection.values));
    });

    test('toolsets are rows, with label and description', () {
      final index = _index(
        'es',
        tools: const [
          ServerToolset(
            name: 'web',
            label: 'Web search',
            description: 'Look things up',
          ),
        ],
      );
      expect(
        index.where((e) => e.kind == SettingsSearchKind.toolset).single.toolset,
        'web',
      );
      expect(searchSettings(index, 'look things').single.toolset, 'web');
    });
  });

  group('search', () {
    test('reasoning leads to the Main model page, in English', () {
      final hits = searchSettings(_index('en'), 'reasoning');
      final field = hits.firstWhere((e) => e.path == 'agent.reasoning_effort');
      expect(field.page, ServerConfigPage.main);
    });

    test('and its Spanish text leads there too', () {
      final hits = searchSettings(_index('es'), 'razonamiento');
      expect(hits.map((e) => e.path), contains('agent.reasoning_effort'));
    });

    test('accents and case do not matter', () {
      expect(
        searchSettings(_index('es'), 'ZONA HORARIA').map((e) => e.path),
        contains('timezone'),
      );
      expect(
        searchSettings(_index('es'), 'ejecucion').map((e) => e.page),
        contains(ServerConfigPage.runtime),
      );
    });

    test('every word has to match', () {
      expect(
        searchSettings(_index('en'), 'time zone').map((e) => e.path),
        contains('timezone'),
      );
      expect(searchSettings(_index('en'), 'time banana'), isEmpty);
    });

    test('the path words match', () {
      expect(
        searchSettings(_index('en'), 'persistent shell').map((e) => e.path),
        contains('terminal.persistent_shell'),
      );
    });

    test('an empty or blank query finds nothing', () {
      expect(searchSettings(_index('es'), ''), isEmpty);
      expect(searchSettings(_index('es'), '   '), isEmpty);
    });

    test('the excluded fields are never found', () {
      expect(
        searchSettings(_index('en'), 'key').where((e) => e.path != null),
        isEmpty,
      );
      expect(
        searchSettings(_index('en'), 'logs').where((e) => e.path != null),
        isEmpty,
      );
    });

    test('a title match comes before a description match', () {
      final hits = searchSettings(_index('en'), 'shell');
      expect(hits.first.title.toLowerCase(), contains('shell'));
    });
  });
}
