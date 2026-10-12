// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// The chain rules of Desktop's `fallback-models-field.tsx`
// (`normalizeEntries`, `completeEntries`, and its row edits).
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/fallback_chain.dart';

void main() {
  const routed = <String, dynamic>{
    'provider': 'custom',
    'model': 'glm-5.08',
    'base_url': 'http://gw:8080/v1',
    'api_key': r'${GW_KEY}',
  };

  test('reads objects, legacy strings and odd data without throwing', () {
    expect(fallbackChainFromConfig(null), isEmpty);
    expect(fallbackChainFromConfig({'provider': 'a'}), isEmpty);
    expect(
      fallbackChainFromConfig([
        routed,
        'copilot/gpt-5-mini',
        'bare-model',
        7,
        {'provider': 'nous'},
      ]),
      [
        routed,
        {'provider': 'copilot', 'model': 'gpt-5-mini'},
        {'provider': '', 'model': 'bare-model'},
        {'provider': '', 'model': ''},
        {'provider': 'nous', 'model': ''},
      ],
    );
  });

  test('only complete pairs are rows and are persisted', () {
    final chain = fallbackChainFromConfig([
      routed,
      'bare-model',
      {'provider': 'nous'},
    ]);
    expect(completeFallbacks(chain), [routed]);
    expect(fallbackAdded(chain, 'nous', 'hermes-4'), [
      routed,
      {'provider': 'nous', 'model': 'hermes-4'},
    ]);
  });

  test('removing a row keeps the routing keys of the others', () {
    final chain = fallbackChainFromConfig([
      {'provider': 'copilot', 'model': 'gpt-5-mini'},
      {'provider': 'openai-codex', 'model': 'gpt-5.4-mini'},
      routed,
    ]);
    expect(fallbackRemoved(chain, 0), [
      {'provider': 'openai-codex', 'model': 'gpt-5.4-mini'},
      routed,
    ]);
    expect(fallbackRemoved(chain, 9), hasLength(3));
  });

  test('a row keeps its route only while it stays on its provider', () {
    final chain = fallbackChainFromConfig([routed]);
    expect(fallbackReplaced(chain, 0, 'custom', 'glm-6'), [
      {...routed, 'model': 'glm-6'},
    ]);
    expect(fallbackReplaced(chain, 0, 'nous', 'hermes-4'), [
      {'provider': 'nous', 'model': 'hermes-4'},
    ]);
  });

  test('chains compare by value, whatever the key order', () {
    expect(
      sameFallbackChain(
        [
          {
            'provider': 'a',
            'model': 'b',
            'routing': {
              'x': [1, 2],
            },
          },
        ],
        [
          {
            'routing': {
              'x': [1, 2],
            },
            'model': 'b',
            'provider': 'a',
          },
        ],
      ),
      isTrue,
    );
    expect(
      sameFallbackChain(
        [
          {'provider': 'a', 'model': 'b'},
        ],
        [
          {'provider': 'a', 'model': 'c'},
        ],
      ),
      isFalse,
    );
  });
}
