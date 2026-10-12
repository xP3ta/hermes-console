import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/shell/mascot_bridge.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_attention.dart';
import 'package:hermes_android/core/widgets/mascot/float/mascot_sources.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';

/// What the floating mascot says for each thing the app knows, and where
/// its one action goes.

const _here = MascotPlace(connId: 'c1', connLabel: 'Oficina');
const _forja = MascotPlace(
  connId: 'c1',
  connLabel: 'Oficina',
  profile: 'forja',
  profileLabel: 'Forja',
);
const _casa = MascotPlace(connId: 'c2', connLabel: 'Casa');

final Strings _es = StringsEs();

MascotAttention _attention() =>
    MascotAttention()..setScope(connId: 'c1', profile: '');

void main() {
  group('permissions and questions (read live from the chats)', () {
    test('here: the chat\'s own title; answered through its chat', () async {
      final answers = <bool>[];
      var opened = 0;
      final a = _attention()
        ..setWaiting([
          MascotWaiting(
            key: 'c1:s1:r1',
            place: _here,
            title: 'Login tests',
            command: 'git push',
            resolve: (allow) async => answers.add(allow),
            open: () => opened++,
          ),
        ]);
      final permission = a.permissions.value.single;
      expect(permission.title, 'Login tests');
      expect(permission.command, 'git push');
      await permission.resolve(true);
      permission.openChat!();
      expect(answers, [true]);
      expect(opened, 1);
      expect(a.notices.value, isEmpty);
    });

    test('another profile or instance: named with the place', () {
      final a = _attention()
        ..setWaiting([
          MascotWaiting(
            key: 'c1:s2:r1',
            place: _forja,
            title: 'Deploy',
            resolve: (_) async {},
            open: () {},
          ),
          MascotWaiting(
            key: 'c2:s3:r1',
            place: _casa,
            title: '',
            resolve: (_) async {},
            open: () {},
          ),
        ]);
      expect(
        [for (final p in a.permissions.value) p.title],
        ['Forja · Deploy', 'Casa'],
      );
    });

    test('a question: one line and "Ver el chat"', () {
      var opened = 0;
      final a = _attention()
        ..setWaiting([
          MascotWaiting(
            key: 'c1:s4:q1',
            place: _forja,
            title: 'Plan de viaje',
            open: () => opened++,
          ),
          MascotWaiting(key: 'c1:s5:q1', place: _here, title: '', open: () {}),
        ]);
      expect(a.permissions.value, isEmpty);
      final notice = a.notices.value.first;
      expect(notice.waiting, isTrue);
      expect(notice.kind, MascotNoticeKind.profile);
      expect(notice.text(_es), 'Forja · Plan de viaje te pregunta');
      expect(notice.action!(_es), 'Ver el chat');
      notice.onAction!();
      expect(opened, 1);
      expect(a.notices.value.last.text(_es), 'Un chat te pregunta');
    });

    test('the same state published again notifies nobody', () {
      final a = _attention();
      var notified = 0;
      a.permissions.addListener(() => notified++);
      MascotWaiting item() => MascotWaiting(
        key: 'c1:s1:r1',
        place: _here,
        title: 'Login tests',
        resolve: (_) async {},
        open: () {},
      );
      a.setWaiting([item()]);
      a.setWaiting([item()]);
      a.setWaiting([item()]);
      expect(notified, 1);
    });
  });

  group('news from where the user is not looking', () {
    MascotEvent event(
      String id,
      MascotPlace place, {
      String text = 'Hermes respondió en Login',
      bool failed = false,
      void Function()? open,
    }) => MascotEvent(
      id: id,
      place: place,
      text: text,
      failed: failed,
      open: open ?? () {},
    );

    test('another profile: its name, what happened, "Ver"', () {
      var went = <String>[];
      final a = _attention()
        ..report(event('s1', _forja, open: () => went.add('s1')));
      var notice = a.notices.value.single;
      expect(notice.kind, MascotNoticeKind.profile);
      expect(notice.text(_es), 'Forja: Hermes respondió en Login');
      expect(notice.action!(_es), 'Ver');
      // More of them: one line with how many, and it goes to the latest.
      a.report(event('s2', _forja, open: () => went.add('s2')));
      a.report(event('s3', _forja, open: () => went.add('s3')));
      notice = a.notices.value.single;
      expect(notice.text(_es), 'Forja tiene 3 novedades');
      notice.onAction!();
      expect(went, ['s3']);
    });

    test('another instance: its name and "Ir", before the profiles', () {
      final a = _attention()
        ..report(event('s1', _forja))
        ..report(event('j1', _casa, text: 'Falló una tarea programada'));
      expect(
        [for (final n in a.notices.value) n.kind],
        [MascotNoticeKind.instance, MascotNoticeKind.profile],
      );
      final instance = a.notices.value.first;
      expect(instance.text(_es), 'Casa: Falló una tarea programada');
      expect(instance.action!(_es), 'Ir');
    });

    test('here: a finished task and a failed cron, one each', () {
      final a = _attention()
        ..report(event('s1', _here, text: 'Terminó: Informe'))
        ..report(
          event('j1', _here, text: 'Falló una tarea programada', failed: true),
        );
      expect(
        [for (final n in a.notices.value) n.kind],
        [MascotNoticeKind.failed, MascotNoticeKind.finished],
      );
      expect(a.notices.value.first.text(_es), 'Falló una tarea programada');
      expect(a.notices.value.last.action!(_es), 'Ver');
    });

    test('the same thing reported twice counts once', () {
      final a = _attention()
        ..report(event('s1', _forja))
        ..report(event('s1', _forja, text: 'Hermes respondió en Login (2)'));
      expect(
        a.notices.value.single.text(_es),
        'Forja: Hermes respondió en Login (2)',
      );
    });

    test('seen: it leaves; what comes later speaks up again', () {
      final a = _attention()..report(event('s1', _forja));
      final first = a.notices.value.single;
      first.onSeen!();
      expect(a.notices.value, isEmpty);
      a.report(event('s2', _forja));
      expect(a.notices.value.single.key, isNot(first.key));
      // While it has not been seen, the key holds as news pile up.
      final key = a.notices.value.single.key;
      a.report(event('s3', _forja));
      expect(a.notices.value.single.key, key);
    });

    test('going there makes it no longer "elsewhere"', () {
      final a = _attention()
        ..report(event('s1', _forja))
        ..report(event('j1', _casa));
      a.setScope(connId: 'c1', profile: 'forja');
      expect(
        [for (final n in a.notices.value) n.kind],
        [MascotNoticeKind.instance],
      );
      a.setScope(connId: 'c2', profile: '');
      expect(a.notices.value, isEmpty);
    });

    test('opening the chat forgets its news; suggestions come last', () {
      final suggestion = MascotNotice(
        key: 'notifications-off',
        kind: MascotNoticeKind.suggestion,
        text: (s) => s.mascotSuggestNotifications,
        action: (s) => s.mascotSuggestTurnOn,
        onAction: () {},
      );
      final a = _attention()
        ..setSuggestions([suggestion])
        ..report(event('s1', _here, text: 'Terminó: Informe'));
      expect(a.notices.value.last.isSuggestion, isTrue);
      expect(
        a.notices.value.last.text(_es),
        'Tienes las notificaciones apagadas',
      );
      a.forget('c1', 's1');
      expect(a.notices.value.single.isSuggestion, isTrue);
      // Whatever instance it belongs to (the chat on screen has no other
      // name than its session).
      a
        ..report(event('s7', _casa))
        ..forget('c1', 's7');
      expect(a.notices.value, hasLength(2));
      a.forget(null, 's7');
      expect(a.notices.value.single.isSuggestion, isTrue);
    });

    test('it keeps at most the newest events', () {
      final a = MascotAttention(maxEvents: 3)
        ..setScope(connId: 'c1', profile: '');
      for (var i = 0; i < 10; i++) {
        a.report(event('s$i', _here, text: 'Terminó $i'));
      }
      expect(
        [for (final n in a.notices.value) n.text(_es)],
        ['Terminó 9', 'Terminó 8', 'Terminó 7'],
      );
    });
  });

  group('the app\'s banners as the mascot says them', () {
    const es = NotifL10n(true);
    InAppNotice notice(
      String title, {
      String body = '',
      String? chat,
      NotificationKind kind = NotificationKind.run,
    }) => InAppNotice(
      kind: kind,
      title: title,
      body: body,
      open: NotificationOpen(connId: 'c1', sessionId: 's1', title: chat),
    );

    test('the banner\'s title, with what it is about', () {
      expect(
        MascotBridge.noticeLine(notice(es.runCompleted, chat: 'Informe'), es),
        'Terminó: Informe',
      );
      // The title already names the chat.
      expect(
        MascotBridge.noticeLine(
          notice(
            es.replyTitle('Login'),
            body: es.replyReadyBody,
            chat: 'Login',
          ),
          es,
        ),
        'Hermes respondió en Login',
      );
      // A "tap to see" hint is not what it is about.
      expect(
        MascotBridge.noticeLine(
          notice(es.backgroundTaskFinishedTitle, body: es.backgroundTaskBody),
          es,
        ),
        'Terminó una tarea en segundo plano',
      );
      // A job's name comes in the body.
      expect(
        MascotBridge.noticeLine(
          notice(es.cronFailed, body: 'Copia de seguridad'),
          es,
        ),
        'Falló una tarea programada: Copia de seguridad',
      );
    });

    test('which ones are failures', () {
      for (final title in [
        es.runFailed,
        es.cronFailed,
        es.sessionActivityFailedTitle,
        es.backgroundTaskFailedTitle,
        es.kanbanCrashed,
        es.kanbanTimedOut,
        es.kanbanGaveUp,
        es.replyFailedTitle(null),
      ]) {
        expect(MascotBridge.noticeFailed(notice(title), es), isTrue);
      }
      expect(
        MascotBridge.noticeFailed(
          notice(es.replyFailedTitle('Login'), chat: 'Login'),
          es,
        ),
        isTrue,
      );
      for (final title in [
        es.runCompleted,
        es.cronCompleted,
        es.replyTitle('Login'),
        es.goalDone,
      ]) {
        expect(MascotBridge.noticeFailed(notice(title), es), isFalse);
      }
    });
  });
}
