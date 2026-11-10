import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/screens/cache_settings_screen.dart';
import 'package:hermes_android/core/services/cache_settings.dart';
import 'package:hermes_android/core/services/cold_start_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cs1215_cold_start_store_test.dart' show MemoryColdStartStorage;

Session _row(String id, {String source = 'cli', String title = 'Chat'}) =>
    Session(
      id: id,
      title: title,
      model: 'm',
      source: source,
      messageCount: 3,
      isActive: false,
      preview: 'vista $id',
      startedAt: 1790000000,
      updatedAt: 1790000100,
    );

List<Map<String, dynamic>> _rows(String tag, int count) => [
  for (var i = count; i >= 1; i--)
    {'id': i, 'role': i.isOdd ? 'user' : 'assistant', 'content': '$tag-$i'},
];

Future<void> _saveTail(ColdStartStore store, String id) => store.saveTail(
  connectionId: 'c',
  profile: 'default',
  storedSessionId: id,
  routeSessionId: id,
  aliases: {id},
  newestFirst: _rows(id, 5),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryColdStartStorage storage;
  late CacheSettings settings;
  late ColdStartStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = MemoryColdStartStorage();
    settings = CacheSettings(await SharedPreferences.getInstance());
    store = ColdStartStore(storage: storage, settings: settings);
  });

  group('CacheSettings', () {
    test('everything is on and 20 chats are kept until the user says '
        'otherwise', () {
      expect(settings.chatList, isTrue);
      expect(settings.messages, isTrue);
      expect(settings.maxChats, 20);
    });

    test('an unknown stored limit reads as the default', () async {
      SharedPreferences.setMockInitialValues({CacheSettings.maxChatsKey: 7});
      final odd = CacheSettings(await SharedPreferences.getInstance());
      expect(odd.maxChats, CacheSettings.defaultLimit);
      await odd.setMaxChats(7);
      expect(odd.maxChats, CacheSettings.defaultLimit);
    });

    test('a change tells its listeners', () async {
      var calls = 0;
      settings.addListener(() => calls++);
      await settings.setMessages(false);
      await settings.setMaxChats(50);
      expect(calls, 2);
      expect(settings.messages, isFalse);
      expect(settings.maxChats, 50);
    });
  });

  group('ColdStartStore follows the settings', () {
    test('the limit decides how many chats keep their messages', () async {
      await settings.setMaxChats(10);
      for (var i = 0; i < 12; i++) {
        await _saveTail(store, 's$i');
      }
      final tails = await store.loadTails(limit: store.tailLimit);
      expect(tails, hasLength(10));
      expect(tails.first.storedSessionId, 's11');
    });

    test(
      'with Messages off nothing is saved and nothing is restored',
      () async {
        await _saveTail(store, 'kept');
        await settings.setMessages(false);
        await _saveTail(store, 'new');
        expect(await store.loadTails(), isEmpty);
        await settings.setMessages(true);
        expect((await store.loadTails()).map((t) => t.storedSessionId), [
          'kept',
        ], reason: 'turning it off alone deletes nothing: the screen does');
      },
    );

    test('with Chat list off the list and the recents are neither saved nor '
        'read', () async {
      await store.saveList(
        connectionId: 'c',
        profile: '',
        sessions: [_row('a')],
      );
      await store.saveRecents(
        connectionId: 'c',
        profile: '',
        sessions: [_row('a')],
      );
      await settings.setChatList(false);
      expect(store.peekList(connectionId: 'c', profile: ''), isNull);
      expect(await store.loadList(connectionId: 'c', profile: ''), isNull);
      expect(await store.loadRecents(connectionId: 'c', profile: ''), isNull);
      final writes = storage.writes;
      await store.saveList(
        connectionId: 'c',
        profile: '',
        sessions: [_row('b')],
      );
      expect(storage.writes, writes);
    });

    test('clearMessages and clearLists delete what each one kept', () async {
      await _saveTail(store, 's1');
      await store.saveList(
        connectionId: 'c',
        profile: '',
        sessions: [_row('a')],
      );
      await store.saveRecents(
        connectionId: 'c',
        profile: '',
        sessions: [_row('a')],
      );
      expect(await store.usedBytes(), greaterThan(0));

      await store.clearLists();
      expect(await store.loadList(connectionId: 'c', profile: ''), isNull);
      expect(await store.loadRecents(connectionId: 'c', profile: ''), isNull);
      expect(await store.loadTails(), hasLength(1));

      await store.clearMessages();
      expect(await store.loadTails(), isEmpty);
      expect(
        storage.values.keys.where((k) => k.startsWith('cold_start_tail_v1.')),
        isEmpty,
      );
      expect(await store.usedBytes(), 0);
    });
  });

  group('the Chats list snapshot', () {
    test('round-trips per connection and profile', () async {
      await store.saveList(
        connectionId: 'c1',
        profile: '',
        sessions: [
          _row('a', title: 'Uno'),
          _row('b'),
        ],
      );
      await store.saveList(
        connectionId: 'c1',
        profile: 'work',
        sessions: [_row('w')],
      );
      final main = await store.loadList(connectionId: 'c1', profile: '');
      expect(main!.map((s) => s.id), ['a', 'b']);
      expect(main.first.title, 'Uno');
      expect(
        (await store.loadList(
          connectionId: 'c1',
          profile: 'work',
        ))!.map((s) => s.id),
        ['w'],
      );
      expect(await store.loadList(connectionId: 'c2', profile: ''), isNull);
      // Home's recents are another snapshot.
      expect(await store.loadRecents(connectionId: 'c1', profile: ''), isNull);
    });

    test('keeps up to 100 rows where Home keeps 24', () async {
      final many = [for (var i = 0; i < 130; i++) _row('s$i')];
      await store.saveList(connectionId: 'c', profile: '', sessions: many);
      await store.saveRecents(connectionId: 'c', profile: '', sessions: many);
      expect(
        await store.loadList(connectionId: 'c', profile: ''),
        hasLength(ColdStartStore.maxListRows),
      );
      expect(
        await store.loadRecents(connectionId: 'c', profile: ''),
        hasLength(ColdStartStore.maxRecentRows),
      );
    });

    test('a deleted chat leaves the list and the recents', () async {
      await store.saveList(
        connectionId: 'c',
        profile: '',
        sessions: [_row('a'), _row('b')],
      );
      await store.saveRecents(
        connectionId: 'c',
        profile: '',
        sessions: [_row('a'), _row('b')],
      );
      await store.forgetSession(connectionId: 'c', sessionId: 'a');
      expect(
        (await store.loadList(
          connectionId: 'c',
          profile: '',
        ))!.map((s) => s.id),
        ['b'],
      );
      expect(
        (await store.loadRecents(
          connectionId: 'c',
          profile: '',
        ))!.map((s) => s.id),
        ['b'],
      );
    });

    test('forgetting a connection or everything reaches the list', () async {
      await store.saveList(
        connectionId: 'c',
        profile: '',
        sessions: [_row('a')],
      );
      await store.saveList(
        connectionId: 'other',
        profile: '',
        sessions: [_row('o')],
      );
      await store.forgetScope('c');
      expect(await store.loadList(connectionId: 'c', profile: ''), isNull);
      expect(
        await store.loadList(connectionId: 'other', profile: ''),
        isNotNull,
      );
      await store.clearAll();
      expect(await store.loadList(connectionId: 'other', profile: ''), isNull);
      expect(
        storage.values.keys.where((k) => k.startsWith('cold_start_list_v1.')),
        isEmpty,
      );
    });

    test('a snapshot over its byte budget is dropped, not read', () async {
      final key = ColdStartStore.listKey('c', '');
      storage.values[key] =
          '{"v":1,"c":"c","p":"default","rows":[${'1,' * ColdStartStore.maxListBytes}1]}';
      expect(await store.loadList(connectionId: 'c', profile: ''), isNull);
      expect(storage.values.containsKey(key), isFalse);
    });
  });

  group('Settings → Data → Cache screen', () {
    Future<void> pumpScreen(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: CacheSettingsScreen(store: store, settings: settings),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows the switches, the limit and what is used', (
      tester,
    ) async {
      await tester.runAsync(() => _saveTail(store, 's1'));
      await pumpScreen(tester);
      expect(find.text('Cache'), findsOneWidget);
      expect(find.text('Chat list'), findsOneWidget);
      expect(find.text('Messages'), findsOneWidget);
      expect(find.text('Keep up to: 20 chats'), findsOneWidget);
      for (final n in CacheSettings.limits) {
        expect(find.byKey(ValueKey('cache-limit-$n')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('cache-usage')), findsOneWidget);
    });

    testWidgets('picking a limit changes it', (tester) async {
      await pumpScreen(tester);
      await tester.tap(find.byKey(const ValueKey('cache-limit-50')));
      await tester.pumpAndSettle();
      expect(settings.maxChats, 50);
      expect(find.text('Keep up to: 50 chats'), findsOneWidget);
    });

    testWidgets('turning Messages off deletes the kept messages', (
      tester,
    ) async {
      await tester.runAsync(() => _saveTail(store, 's1'));
      await pumpScreen(tester);
      await tester.tap(find.byKey(const ValueKey('cache-messages')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(settings.messages, isFalse);
      expect(
        storage.values.keys.where((k) => k.startsWith('cold_start_tail_v1.')),
        isEmpty,
      );
      // The limit cannot be picked while nothing is kept.
      final chip = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('cache-limit-10')),
      );
      expect(chip.onSelected, isNull);
    });

    testWidgets('turning Chat list off deletes the kept list', (tester) async {
      await tester.runAsync(
        () => store.saveList(
          connectionId: 'c',
          profile: '',
          sessions: [_row('a')],
        ),
      );
      await pumpScreen(tester);
      await tester.tap(find.byKey(const ValueKey('cache-chat-list')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(settings.chatList, isFalse);
      expect(
        storage.values.keys.where((k) => k.startsWith('cold_start_list_v1.')),
        isEmpty,
      );
    });

    testWidgets('Clear cache empties both', (tester) async {
      await tester.runAsync(() async {
        await _saveTail(store, 's1');
        await store.saveList(
          connectionId: 'c',
          profile: '',
          sessions: [_row('a')],
        );
      });
      await pumpScreen(tester);
      await tester.tap(find.byKey(const ValueKey('cache-clear')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.text('Cache cleared'), findsOneWidget);
      expect(
        storage.values.keys.where((k) => k.startsWith('cold_start_')),
        everyElement(equals(ColdStartStore.indexKey)),
      );
    });
  });
}
