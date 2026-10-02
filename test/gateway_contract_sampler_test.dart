// Self-test of the contract sample generator: every branch of a union must
// reach the parsers, not only the first one.
import 'package:flutter_test/flutter_test.dart';

import 'support/contract/gateway_contract.dart';

GatewayContract _contract(Map<String, dynamic> schemas) =>
    GatewayContract.fromDocument({
      'components': {'schemas': schemas},
    });

void main() {
  test('every oneOf branch of a property produces its own sample', () {
    final contract = _contract({
      'SessionOwner': {
        'type': 'object',
        'properties': {
          'kind': {'const': 'session'},
          'session_id': {'type': 'string'},
        },
        'required': ['kind', 'session_id'],
      },
      'AccountOwner': {
        'type': 'object',
        'properties': {
          'kind': {'const': 'account'},
          'account_id': {'type': 'string'},
        },
        'required': ['kind', 'account_id'],
      },
    });
    final samples = ContractSampler(contract).samples({
      'type': 'object',
      'properties': {
        'owner': {
          'oneOf': [
            {r'$ref': '#/components/schemas/SessionOwner'},
            {r'$ref': '#/components/schemas/AccountOwner'},
          ],
        },
      },
      'required': ['owner'],
    });
    final kinds = {
      for (final sample in samples)
        if (sample.value['owner'] is Map)
          (sample.value['owner'] as Map)['kind'],
    };
    expect(kinds, {'session', 'account'});
  });

  test('a union nested in a nullable anyOf and in arrays is expanded', () {
    final contract = _contract({});
    final samples = ContractSampler(contract).samples({
      'type': 'object',
      'properties': {
        'barrier': {
          'anyOf': [
            {
              'oneOf': [
                {
                  'type': 'object',
                  'properties': {
                    'until': {'type': 'number'},
                  },
                  'required': ['until'],
                },
                {
                  'type': 'object',
                  'properties': {
                    'target': {'type': 'string'},
                  },
                  'required': ['target'],
                },
              ],
            },
            {'type': 'null'},
          ],
        },
        'values': {
          'type': 'array',
          'items': {
            'anyOf': [
              {'type': 'integer'},
              {'type': 'string'},
            ],
          },
        },
      },
    });
    final barriers = {
      for (final sample in samples)
        if (sample.value['barrier'] is Map)
          ...(sample.value['barrier'] as Map).keys,
    };
    expect(barriers, containsAll(['until', 'target']));
    final itemTypes = {
      for (final sample in samples)
        if (sample.value['values'] is List)
          for (final item in sample.value['values'] as List) item.runtimeType,
    };
    expect(itemTypes, containsAll([int, String]));
  });

  test('every union in the vendored contract is sampled per branch', () {
    final contract = GatewayContract.load();
    final samples = ContractSampler(
      contract,
    ).samples(contract.methodResultSchema('connectors.policy.get'));
    final effective = {
      for (final sample in samples)
        if (sample.value['effective'] is Map)
          (sample.value['effective'] as Map)['mode'],
    };
    expect(effective.length, greaterThanOrEqualTo(4), reason: '$effective');
  });
}
