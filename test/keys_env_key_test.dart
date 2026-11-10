// Keys: what is read from `GET /api/env`, what may be sent, how it filters.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/keys/env_key.dart';

void main() {
  final fixture = <String, dynamic>{
    'OPENAI_API_KEY': {
      'is_set': true,
      'redacted_value': 'sk-S3CR3T…abcd',
      'description': 'OpenAI key',
      'category': 'provider',
      'is_password': true,
      'channel_managed': false,
      'custom': false,
    },
    'BROWSER_SESSION_TIMEOUT': {
      'is_set': false,
      'redacted_value': null,
      'description': 'Seconds before a browser session ends',
      'category': 'tool',
    },
    'TELEGRAM_BOT_TOKEN': {
      'is_set': true,
      'redacted_value': 'tg-S3CR3T',
      'category': 'messaging',
      'channel_managed': true,
    },
    'MY_OWN_TOKEN': {
      'is_set': true,
      'redacted_value': 'own-S3CR3T',
      'category': 'custom',
      'custom': true,
    },
    'not a name': {'is_set': true},
    'LOWER_case': {'is_set': true},
    'BROKEN_ROW': 'nope',
  };

  group('parseEnvKeys', () {
    test('keeps names, state and metadata; sorted by name', () {
      final keys = parseEnvKeys(fixture);
      expect(keys.map((e) => e.name), [
        'BROWSER_SESSION_TIMEOUT',
        'MY_OWN_TOKEN',
        'OPENAI_API_KEY',
      ]);
      final openai = keys.last;
      expect(openai.isSet, isTrue);
      expect(openai.category, 'provider');
      expect(openai.description, 'OpenAI key');
      expect(keys.first.isSet, isFalse);
      expect(keys[1].custom, isTrue);
      expect(keys[1].category, 'custom');
    });

    test('channel-managed variables belong to Messaging and are left out', () {
      expect(
        parseEnvKeys(fixture).map((e) => e.name),
        isNot(contains('TELEGRAM_BOT_TOKEN')),
      );
    });

    test('no entry carries any part of the redacted value', () {
      final everything = parseEnvKeys(fixture)
          .map((e) => '${e.name}|${e.category}|${e.description}|${e.isSet}')
          .join('\n');
      expect(everything, isNot(contains('S3CR3T')));
      expect(everything, isNot(contains('abcd')));
    });
  });

  group('hidden but set', () {
    test('only the names of set messaging variables are kept', () {
      expect(setChannelManagedNames(fixture), {'TELEGRAM_BOT_TOKEN'});
      expect(
        setChannelManagedNames({
          'DISCORD_BOT_TOKEN': {'is_set': false, 'channel_managed': true},
          'OPENAI_API_KEY': {'is_set': true, 'channel_managed': false},
          'bad name': {'is_set': true, 'channel_managed': true},
        }),
        isEmpty,
      );
    });
  });

  group('names', () {
    test('accept the server shape only', () {
      expect(isValidEnvKeyName('A'), isTrue);
      expect(isValidEnvKeyName('MY_KEY_2'), isTrue);
      expect(isValidEnvKeyName('A' * 128), isTrue);
      expect(isValidEnvKeyName('A' * 129), isFalse);
      expect(isValidEnvKeyName(''), isFalse);
      expect(isValidEnvKeyName('1KEY'), isFalse);
      expect(isValidEnvKeyName('_KEY'), isFalse);
      expect(isValidEnvKeyName('my_key'), isFalse);
      expect(isValidEnvKeyName('KEY-1'), isFalse);
      expect(isValidEnvKeyName('KEY\n'), isFalse);
      expect(isValidEnvKeyName('KEY =1'), isFalse);
    });
  });

  group('values', () {
    test('a plain value is fine', () {
      expect(validateEnvKeyValue('abc123-_.~/+='), isNull);
      expect(validateEnvKeyValue('x' * kEnvKeyValueMaxLength), isNull);
    });

    test('empty, too long, control characters and edge spaces are refused', () {
      expect(validateEnvKeyValue(''), EnvKeyValueProblem.empty);
      expect(
        validateEnvKeyValue('x' * (kEnvKeyValueMaxLength + 1)),
        EnvKeyValueProblem.tooLong,
      );
      expect(validateEnvKeyValue('a\nb'), EnvKeyValueProblem.control);
      expect(validateEnvKeyValue('a\r\nb'), EnvKeyValueProblem.control);
      expect(validateEnvKeyValue('abc\n'), EnvKeyValueProblem.control);
      expect(validateEnvKeyValue('a\u0000b'), EnvKeyValueProblem.control);
      expect(validateEnvKeyValue('a\tb'), EnvKeyValueProblem.control);
      expect(validateEnvKeyValue('a\u007fb'), EnvKeyValueProblem.control);
      expect(validateEnvKeyValue('a b'), EnvKeyValueProblem.control);
      expect(validateEnvKeyValue(' abc'), EnvKeyValueProblem.edgeSpace);
      expect(validateEnvKeyValue('abc '), EnvKeyValueProblem.edgeSpace);
      expect(validateEnvKeyValue('   '), EnvKeyValueProblem.edgeSpace);
    });

    test('spaces inside are allowed', () {
      expect(validateEnvKeyValue('a b'), isNull);
    });
  });

  group('filter', () {
    final keys = parseEnvKeys(fixture);

    test('search matches the name or the description, any case', () {
      expect(filterEnvKeys(keys, query: 'openai').map((e) => e.name), [
        'OPENAI_API_KEY',
      ]);
      expect(filterEnvKeys(keys, query: 'seconds').map((e) => e.name), [
        'BROWSER_SESSION_TIMEOUT',
      ]);
      expect(filterEnvKeys(keys, query: 'zzz'), isEmpty);
    });

    test('status and category narrow the list', () {
      expect(filterEnvKeys(keys, isSet: true), hasLength(2));
      expect(filterEnvKeys(keys, isSet: false).single.name, startsWith('BRO'));
      expect(
        filterEnvKeys(keys, category: 'custom').single.name,
        'MY_OWN_TOKEN',
      );
      expect(filterEnvKeys(keys, isSet: false, category: 'custom'), isEmpty);
    });
  });
}
