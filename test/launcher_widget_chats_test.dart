import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/launcher_widget_chats.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/launcher_widget_chats.dart';
import 'package:hermes_android/core/services/launcher_widget_cron.dart'
    show LauncherWidgetSectionStore;

class _Store implements LauncherWidgetSectionStore {
  final values = <String, String>{};
  final redraws = <String>[];
  bool failWrites = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('launcher unavailable');
    values[key] = value;
  }

  @override
  Future<void> redraw(String qualifiedAndroidName) async {
    redraws.add(qualifiedAndroidName);
  }
}

const _t0 = 1760000000000;

Session _session(
  String id, {
  String title = 'Saludo amistoso',
  String source = 'mobile',
  String preview = '',
  String? answer,
  double? updatedAt,
  String? profile,
}) => Session(
  id: id,
  title: title,
  model: '',
  source: source,
  messageCount: 2,
  isActive: false,
  preview: preview,
  lastAssistantPreview: answer,
  startedAt: _t0 / 1000 - 3600,
  updatedAt: updatedAt,
  profile: profile,
);

void main() {
  group('a conversation as the widget lists it', () {
    test('title, one plain line of the last answer, last activity', () {
      final chat = launcherWidgetChat(
        _session(
          'sess-1',
          answer: '\n**¡Buenos días!** ¿Qué hacemos hoy?\nSegunda línea',
          updatedAt: _t0 / 1000,
          profile: 'forja',
        ),
      )!;
      expect(chat.id, 'sess-1');
      expect(chat.title, 'Saludo amistoso');
      expect(chat.line, '¡Buenos días! ¿Qué hacemos hoy?');
      expect(chat.atMs, _t0);
      expect(chat.profile, 'forja');
      // The default profile needs no name.
      expect(launcherWidgetChat(_session('s'))!.profile, isNull);
      // Without an answer yet, the first message is the line.
      expect(
        launcherWidgetChat(
          _session('s', preview: 'Hola, necesito ayuda'),
        )!.line,
        'Hola, necesito ayuda',
      );
      expect(launcherWidgetChat(_session('s'))!.line, isNull);
    });

    test('"hide sensitive content" keeps answers off the home screen', () {
      final chat = launcherWidgetChat(
        _session('sess-1', answer: 'La clave es 1234'),
        hideSensitive: true,
      )!;
      expect(chat.title, 'Saludo amistoso');
      expect(chat.line, isNull);
    });

    test('a draft that is not on the server yet is not listed', () {
      // The widget could not open it.
      expect(
        launcherWidgetChat(_session('mob-1', source: 'mobile-draft')),
        isNull,
      );
      expect(launcherWidgetChat(_session('not an id')), isNull);
    });

    test('a long line is cut on a home screen\'s scale', () {
      final line = launcherWidgetChatLine('palabra ' * 40)!;
      expect(line.length, lessThanOrEqualTo(101));
      expect(line, endsWith('…'));
      expect(launcherWidgetChatLine('\n \n'), isNull);
      expect(launcherWidgetChatLine(null), isNull);
      expect(launcherWidgetChatLine('# Título\ntexto'), 'Título');
    });
  });

  group('the stored section', () {
    test('it survives a round trip and is versioned', () {
      const snapshot = LauncherWidgetChatsSnapshot(
        connectionId: 'conn-1',
        updatedAtMs: _t0,
        chats: [
          LauncherWidgetChat(
            id: 'sess-1',
            title: 'Saludo amistoso',
            line: '¡Buenos días!',
            atMs: _t0 - 1000,
            profile: 'forja',
          ),
          LauncherWidgetChat(id: 'sess-2', title: 'Sin respuesta aún'),
        ],
      );
      final decoded = LauncherWidgetChatsSnapshot.tryDecode(snapshot.encode())!;
      expect(decoded.content, snapshot.content);
      expect(decoded.updatedAtMs, _t0);
      expect(decoded.chats.first.atMs, _t0 - 1000);
      expect(decoded.chats.last.line, isNull);
      expect(jsonDecode(snapshot.encode())['schema_version'], 1);
      expect(LauncherWidgetChatsSnapshot.storageKey, 'hermes_widget_chats_v1');
    });

    test('anything that is not this schema reads as nothing, never throws', () {
      for (final raw in <Object?>[
        null,
        '',
        'not json',
        '{"schema_version":2,"conn_id":"c","chats":[]}',
        '{"schema_version":1,"chats":[]}',
        3,
      ]) {
        expect(
          LauncherWidgetChatsSnapshot.tryDecode(raw),
          isNull,
          reason: '$raw',
        );
      }
      final tolerant = LauncherWidgetChatsSnapshot.tryDecode(
        jsonEncode({
          'schema_version': 1,
          'conn_id': 'c',
          'later_field': 1,
          'chats': [
            {'id': 'ok', 'title': 'Bien', 'at_ms': 'soon'},
            {'id': '../etc', 'title': 'No'},
            {'id': 'no-title'},
            'nonsense',
          ],
        }),
      )!;
      expect(tolerant.chats.map((c) => c.id), ['ok']);
      expect(tolerant.chats.single.atMs, isNull);
    });
  });

  group('publishing', () {
    late _Store store;
    late int now;
    String? preferred;
    var hide = false;

    LauncherWidgetChatsPublisher publisher() => LauncherWidgetChatsPublisher(
      store: store,
      nowMs: () => now,
      preferredConnection: () async => preferred,
      hideSensitive: () async => hide,
    );

    LauncherWidgetChatsSnapshot? stored() =>
        LauncherWidgetChatsSnapshot.tryDecode(
          store.values[LauncherWidgetChatsSnapshot.storageKey],
        );

    setUp(() {
      store = _Store();
      now = _t0;
      preferred = null;
      hide = false;
    });

    test('the list just read is written once, most recent first', () async {
      final p = publisher();
      await p.offer(
        connectionId: 'conn-1',
        sessions: [
          _session('a', title: 'El más reciente', answer: 'Hecho'),
          _session('mob-draft', source: 'mobile-draft'),
          for (var i = 0; i < 20; i++) _session('s$i', title: 'Chat $i'),
        ],
      );
      final chats = stored()!.chats;
      expect(chats, hasLength(LauncherWidgetChatsSnapshot.maxChats));
      expect(chats.first.id, 'a');
      expect(chats.map((c) => c.id), isNot(contains('mob-draft')));
      expect(store.redraws, [launcherWidgetChatsProvider]);
      expect(
        launcherWidgetChatsProvider,
        'com.hermesagent.hermes_android.HermesChatsWidgetProvider',
      );
    });

    test(
      'the same list is not rewritten, only re-stamped every 5 min',
      () async {
        final p = publisher();
        final list = [_session('a', answer: 'Hecho')];
        await p.offer(connectionId: 'conn-1', sessions: list);
        now = _t0 + 60000;
        await p.offer(connectionId: 'conn-1', sessions: list);
        expect(store.redraws, hasLength(1));
        now = _t0 + 5 * 60000;
        await p.offer(connectionId: 'conn-1', sessions: list);
        expect(store.redraws, hasLength(2));
        expect(stored()!.updatedAtMs, now);
      },
    );

    test(
      'the owner\'s choice to hide content is read at each publication',
      () async {
        final p = publisher();
        final list = [_session('a', answer: 'La clave es 1234')];
        await p.offer(connectionId: 'conn-1', sessions: list);
        expect(stored()!.chats.single.line, 'La clave es 1234');
        hide = true;
        now += 1000;
        await p.offer(connectionId: 'conn-1', sessions: list);
        expect(stored()!.chats.single.line, isNull);
        expect(store.values.values.single, isNot(contains('1234')));
      },
    );

    test(
      'it stays on the connection in use and never breaks its caller',
      () async {
        final p = publisher();
        preferred = 'conn-1';
        await p.offer(connectionId: 'conn-1', sessions: [_session('mine')]);
        await p.offer(connectionId: 'conn-2', sessions: [_session('other')]);
        expect(stored()!.connectionId, 'conn-1');
        store.failWrites = true;
        now += 1000;
        await p.offer(connectionId: 'conn-1', sessions: [_session('newer')]);
        expect(stored()!.chats.single.id, 'mine');
      },
    );
  });

  test('it rides the Chats list read and adds no request of its own', () {
    final service = File(
      'lib/core/services/launcher_widget_chats.dart',
    ).readAsStringSync();
    for (final forbidden in [
      'Timer(',
      'Timer.periodic',
      'package:http',
      'getSessions',
      '.refresh(',
      'FlutterForegroundTask',
    ]) {
      expect(service, isNot(contains(forbidden)), reason: forbidden);
    }
    final screen = File(
      'lib/core/screens/session_list_screen.dart',
    ).readAsStringSync();
    // Only the ordinary Chats list (not the archive, not automation) is
    // what the widget shows.
    expect(
      screen,
      contains(
        '      if (!_showArchived && _activeCategory == SessionCategory.chats) {',
      ),
    );
    expect('LauncherWidgetChatsPublisher'.allMatches(screen), hasLength(1));
    // Nothing in the background feeds it.
    final listener = File(
      'lib/core/services/notifications/background_listener.dart',
    ).readAsStringSync();
    expect(listener, isNot(contains('LauncherWidgetChats')));
  });
}
