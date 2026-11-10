// The paged transcript read Artefactos uses across conversations: Desktop's
// `getSessionMessages(id, profile, {limit, offset, order: 'oldest',
// includeCompacted: true})`, with inline images off and a byte bound.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

final class _Recording extends DashboardClient {
  _Recording() : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  final endpoints = <String>[];
  final budgets = <int?>[];

  Map<String, dynamic> _page() => {
    'messages': [
      {'role': 'assistant', 'content': 'MEDIA:/tmp/a.png'},
    ],
    'pagination': {'limit': 100, 'offset': 0, 'returned': 1},
  };

  @override
  Future<Map<String, dynamic>> apiGet(
    String endpoint, {
    bool retried = false,
  }) async {
    endpoints.add(endpoint);
    budgets.add(null);
    return _page();
  }

  @override
  Future<Map<String, dynamic>> apiGetBounded(
    String endpoint, {
    required int maxBytes,
    bool retried = false,
  }) async {
    endpoints.add(endpoint);
    budgets.add(maxBytes);
    return _page();
  }
}

void main() {
  test('default read is unchanged: latest page, inline images', () async {
    final client = _Recording();
    await client.getSessionMessagesPage('s 1', limit: 120);
    final query = Uri.parse(client.endpoints.single).queryParameters;
    expect(Uri.parse(client.endpoints.single).path, 'sessions/s%201/messages');
    expect(query['order'], 'latest');
    expect(query['include_compacted'], 'true');
    expect(query.containsKey('inline_images'), isFalse);
    expect(client.budgets.single, isNull);
  });

  test('oldest first, no inline images, bounded, for a profile', () async {
    final client = _Recording();
    final page = await client.getSessionMessagesPage(
      's1',
      profile: 'work',
      limit: 100,
      offset: 200,
      oldestFirst: true,
      inlineImages: false,
      maxBodyBytes: 4096,
    );
    final query = Uri.parse(client.endpoints.single).queryParameters;
    expect(query, {
      'limit': '100',
      'order': 'oldest',
      'offset': '200',
      'include_compacted': 'true',
      'inline_images': 'false',
      'profile': 'work',
    });
    expect(client.budgets.single, 4096);
    expect(page.messages, hasLength(1));
  });
}
