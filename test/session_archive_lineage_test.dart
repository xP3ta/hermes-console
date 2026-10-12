import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/session_archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

Session _session(String id, {String? root, String? parent}) => Session(
  id: id,
  lineageRootId: root,
  parentSessionId: parent,
  title: 'Conversation',
  model: 'model-a',
  source: 'mobile',
  messageCount: 1,
  isActive: false,
  preview: '',
  startedAt: 1,
);

Session _remoteSession(
  String id, {
  String? root,
  String? profile,
  bool? pinned,
}) => Session(
  id: id,
  lineageRootId: root,
  title: 'Conversation',
  model: 'model-a',
  source: 'mobile',
  messageCount: 1,
  isActive: false,
  preview: '',
  startedAt: 1,
  profile: profile,
  pinned: pinned,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('pin y título usan lineage root tras una compactación', () async {
    final prefs = await SharedPreferences.getInstance();
    final archive = await SessionArchive.load(prefs, 'conn-a');
    final firstTip = _session('tip-1', root: 'root-1');
    final nextTip = _session('tip-2', root: 'root-1', parent: 'tip-1');

    await archive.pinSession(firstTip);
    await archive.setSessionTitle(firstTip, 'Título local');

    expect(archive.isSessionPinned(nextTip), isTrue);
    expect(archive.titleForSession(nextTip), 'Título local');
  });

  test(
    'migración legacy es idempotente y conserva las claves físicas',
    () async {
      SharedPreferences.setMockInitialValues({
        'archived_sessions_conn-a': ['tip-1'],
        'pinned_sessions_conn-a': ['tip-2'],
        'hidden_sessions_conn-a': ['tip-1'],
        'session_titles_conn-a': ['tip-1\tTítulo antiguo'],
      });
      final prefs = await SharedPreferences.getInstance();
      final archive = await SessionArchive.load(prefs, 'conn-a');
      final current = _session('tip-2', root: 'root-1', parent: 'tip-1');

      await archive.migrateLogicalIdentity(
        current,
        knownPhysicalIds: const ['tip-1', 'tip-2'],
      );
      await archive.migrateLogicalIdentity(
        current,
        knownPhysicalIds: const ['tip-1', 'tip-2'],
      );

      expect(archive.isSessionArchived(current), isTrue);
      expect(archive.isSessionPinned(current), isTrue);
      expect(archive.isSessionHidden(current), isTrue);
      expect(archive.titleForSession(current), 'Título antiguo');
      expect(
        prefs.getStringList('archived_sessions_conn-a'),
        contains('tip-1'),
      );
      expect(
        prefs.getStringList('archived_sessions_conn-a'),
        contains('root-1'),
      );
    },
  );

  test('pin remoto adopta true/false y ausencia legacy no opina', () async {
    final prefs = await SharedPreferences.getInstance();
    final archive = await SessionArchive.load(prefs, 'conn-a');
    final writes = <(String, bool, String?)>[];
    final sync = SessionPinSync(
      archive,
      writeRemote: (id, pinned, profile) async {
        writes.add((id, pinned, profile));
      },
    );

    await sync.updateSessions([
      _remoteSession('tip-1', root: 'root-1', pinned: true),
    ]);
    expect(archive.isPinned('root-1'), isTrue);
    expect(writes, isEmpty);

    await sync.updateSessions([
      _remoteSession('tip-1', root: 'root-1', pinned: false),
    ]);
    expect(archive.isPinned('root-1'), isFalse);

    await archive.pin('legacy');
    await sync.updateSessions([_remoteSession('legacy')]);
    expect(archive.isPinned('legacy'), isTrue);
  });

  test('pin local parchea la raíz de lineage con su perfil', () async {
    final prefs = await SharedPreferences.getInstance();
    final archive = await SessionArchive.load(prefs, 'conn-a');
    final writes = <(String, bool, String?)>[];
    final row = _remoteSession(
      'tip/2',
      root: 'root/1',
      profile: 'coding',
      pinned: false,
    );
    final sync = SessionPinSync(
      archive,
      writeRemote: (id, pinned, profile) async {
        writes.add((id, pinned, profile));
      },
    );
    await sync.updateSessions([row]);

    await sync.setLocalPinned(row, true);
    await Future<void>.delayed(Duration.zero);

    expect(archive.isSessionPinned(row), isTrue);
    expect(writes, [('root/1', true, 'coding')]);
  });

  test(
    'una página stale no revierte el pin mientras PATCH sigue en vuelo',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final archive = await SessionArchive.load(prefs, 'conn-a');
      final patch = Completer<void>();
      final row = _remoteSession('tip', root: 'root', pinned: false);
      final sync = SessionPinSync(
        archive,
        writeRemote: (_, _, _) => patch.future,
      );
      await sync.updateSessions([row]);

      await sync.setLocalPinned(row, true);
      await sync.updateSessions([row]);
      expect(archive.isSessionPinned(row), isTrue);

      patch.complete();
      await Future<void>.delayed(Duration.zero);
      await sync.updateSessions([row]);
      expect(archive.isSessionPinned(row), isFalse);
    },
  );

  test(
    'una página iniciada antes del PATCH no revierte el pin tras su ACK',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final archive = await SessionArchive.load(prefs, 'conn-a');
      final patch = Completer<void>();
      final row = _remoteSession('tip', root: 'root', pinned: false);
      final sync = SessionPinSync(
        archive,
        writeRemote: (_, _, _) => patch.future,
      );
      await sync.updateSessions([row]);

      final staleRead = sync.beginRemoteRead();
      await sync.setLocalPinned(row, true);
      patch.complete();
      await Future<void>.delayed(Duration.zero);

      await sync.updateSessions([row], readFence: staleRead);
      expect(archive.isSessionPinned(row), isTrue);

      // loadNext puede reutilizar en su snapshot la misma fila stale aunque su
      // propia petición empiece después del ACK. Hasta observar el eco true,
      // esa fila heredada tampoco puede vencer la intención confirmada.
      final carriedStaleRead = sync.beginRemoteRead();
      await sync.updateSessions([row], readFence: carriedStaleRead);
      expect(archive.isSessionPinned(row), isTrue);

      final confirmedRead = sync.beginRemoteRead();
      await sync.updateSessions([
        _remoteSession('tip', root: 'root', pinned: true),
      ], readFence: confirmedRead);
      expect(archive.isSessionPinned(row), isTrue);

      final laterRead = sync.beginRemoteRead();
      await sync.updateSessions([row], readFence: laterRead);
      expect(archive.isSessionPinned(row), isFalse);
    },
  );

  test(
    'un PATCH fallido conserva intención local y reintenta al refrescar',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final archive = await SessionArchive.load(prefs, 'conn-a');
      var attempts = 0;
      final row = _remoteSession('tip', root: 'root', pinned: false);
      final sync = SessionPinSync(
        archive,
        writeRemote: (_, _, _) async {
          attempts += 1;
          throw StateError('offline');
        },
      );
      await sync.updateSessions([row]);

      await sync.setLocalPinned(row, true);
      await Future<void>.delayed(Duration.zero);
      await sync.updateSessions([row]);
      await Future<void>.delayed(Duration.zero);

      expect(archive.isSessionPinned(row), isTrue);
      expect(attempts, 2);
    },
  );

  test('every local mutation advances the archive revision', () async {
    final prefs = await SharedPreferences.getInstance();
    final archive = await SessionArchive.load(prefs, 'conn-a');
    final row = _session('tip', root: 'root');
    var last = archive.revision;
    void expectAdvanced(String step) {
      expect(archive.revision, greaterThan(last), reason: step);
      last = archive.revision;
    }

    // The bump must be visible synchronously, before the write completes.
    final pinning = archive.pinSession(row);
    expectAdvanced('pin (synchronous)');
    await pinning;
    await archive.unpinSession(row);
    expectAdvanced('unpin');
    await archive.archiveSession(row);
    expectAdvanced('archive');
    await archive.unarchiveSession(row);
    expectAdvanced('unarchive');
    await archive.hideSession(row);
    expectAdvanced('hide');
    await archive.unhideSession(row);
    expectAdvanced('unhide');
    await archive.hideAll(['a', 'b']);
    expectAdvanced('hideAll');
    await archive.clearHidden();
    expectAdvanced('clearHidden');
    await archive.setSessionTitle(row, 'Local');
    expectAdvanced('title');
    expect(
      await archive.autoTitleIfPlaceholder(
        sessionId: 'other',
        currentTitle: 'Untitled',
        prompt: 'Plan the release',
      ),
      isTrue,
    );
    expectAdvanced('auto title');
    await archive.migrateLogicalIdentity(
      _session('tip-2', root: 'root-2', parent: 'tip-1'),
      knownPhysicalIds: const ['other'],
    );
    expectAdvanced('lineage migration');

    // No-op reads leave it unchanged.
    archive.isSessionPinned(row);
    archive.titleForSession(row);
    expect(archive.revision, last);
  });

  test('remote pin reconciliation advances the archive revision', () async {
    final prefs = await SharedPreferences.getInstance();
    final archive = await SessionArchive.load(prefs, 'conn-a');
    final sync = SessionPinSync(archive, writeRemote: (_, _, _) async {});
    final before = archive.revision;

    await sync.updateSessions([
      _remoteSession('tip-1', root: 'root-1', pinned: true),
    ]);
    expect(archive.isPinned('root-1'), isTrue);
    expect(archive.revision, greaterThan(before));

    final afterAdopt = archive.revision;
    await sync.setLocalPinned(
      _remoteSession('tip-1', root: 'root-1', pinned: true),
      false,
    );
    expect(archive.isPinned('root-1'), isFalse);
    expect(archive.revision, greaterThan(afterAdopt));
  });
}
