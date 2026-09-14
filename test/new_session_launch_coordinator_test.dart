import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/models/new_session_launch_action.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/new_session_factory.dart';
import 'package:hermes_android/core/services/new_session_launch_coordinator.dart';

SavedConnection connection(String id) => SavedConnection(
  id: id,
  label: id,
  host: '100.64.0.1',
  port: 8642,
  apiKey: 'fixture-only',
);

NewSessionLaunchAction action(
  String eventId, {
  NewSessionLaunchKind kind = NewSessionLaunchKind.newSession,
  NewSessionLaunchTarget target = NewSessionLaunchTarget.composer,
  String? sessionId,
}) => NewSessionLaunchAction(
  kind: kind,
  source: NewSessionLaunchSource.widget,
  nativeEventId: eventId,
  sessionId: sessionId,
  target: target,
  receivedElapsedMs: 1,
);

void main() {
  late List<SavedConnection> connections;
  late bool onboarded;
  late bool unlocked;
  late bool navigatorReady;
  late int elapsed;
  late List<Session> opened;
  late List<NewSessionLaunchTarget> openedTargets;

  NewSessionLaunchCoordinator coordinator({
    Future<SavedConnection?> Function(List<SavedConnection>)? selector,
    Future<NavigationDeliveryOutcome> Function(
      SavedConnection,
      Session,
      NewSessionLaunchTarget,
    )?
    navigator,
    Future<void> Function()? openApp,
    Future<void> Function()? openSetup,
    Future<NavigationDeliveryOutcome> Function(SavedConnection, String)?
    openSession,
  }) {
    return NewSessionLaunchCoordinator(
      connections: () => connections,
      activeConnectionId: () => null,
      defaultConnectionId: () => null,
      onboardingComplete: () => onboarded,
      unlocked: () => unlocked,
      navigatorReady: () => navigatorReady,
      newChatTitle: () => 'Nueva conversación',
      selectConnection: selector ?? (items) async => items.first,
      navigate:
          navigator ??
          (selected, draft, target) async {
            opened.add(draft);
            openedTargets.add(target);
            return NavigationDeliveryOutcome.delivered;
          },
      openApp: openApp,
      openSetup: openSetup,
      openSession: openSession,
      factory: NewSessionFactory(
        generateId: () => 'mob-${opened.length}',
        now: () => DateTime.fromMillisecondsSinceEpoch(1000),
      ),
      elapsedMs: () => elapsed,
    );
  }

  setUp(() {
    connections = [connection('only')];
    onboarded = true;
    unlocked = true;
    navigatorReady = true;
    elapsed = 1000;
    opened = [];
    openedTargets = [];
  });

  test('waits behind onboarding, unlock and navigator gates', () async {
    onboarded = false;
    final subject = coordinator();

    expect(
      await subject.enqueue(action('one')),
      NewSessionLaunchDisposition.queued,
    );
    expect(
      subject.state,
      NewSessionLaunchCoordinatorState.waitingForOnboarding,
    );
    expect(subject.hasPending, isTrue);

    onboarded = true;
    unlocked = false;
    expect(await subject.retry(), NewSessionLaunchDisposition.queued);
    expect(subject.state, NewSessionLaunchCoordinatorState.waitingForUnlock);

    unlocked = true;
    navigatorReady = false;
    expect(await subject.retry(), NewSessionLaunchDisposition.queued);
    expect(subject.state, NewSessionLaunchCoordinatorState.waitingForNavigator);

    navigatorReady = true;
    expect(await subject.retry(), NewSessionLaunchDisposition.delivered);
    expect(opened, hasLength(1));
    expect(subject.hasPending, isFalse);
  });

  test(
    'deduplicates an equivalent double tap while navigation is in flight',
    () async {
      final navigationStarted = Completer<void>();
      final finishNavigation = Completer<void>();
      final subject = coordinator(
        navigator: (_, draft, target) async {
          opened.add(draft);
          openedTargets.add(target);
          navigationStarted.complete();
          await finishNavigation.future;
          return NavigationDeliveryOutcome.delivered;
        },
      );

      final first = subject.enqueue(action('first'));
      await navigationStarted.future;
      expect(
        await subject.enqueue(action('second')),
        NewSessionLaunchDisposition.duplicate,
      );
      finishNavigation.complete();
      expect(await first, NewSessionLaunchDisposition.delivered);
      expect(opened, hasLength(1));
    },
  );

  test('allows a deliberate later action after the dedupe window', () async {
    final subject = coordinator();

    expect(
      await subject.enqueue(action('first')),
      NewSessionLaunchDisposition.delivered,
    );
    elapsed += 851;
    expect(
      await subject.enqueue(action('second')),
      NewSessionLaunchDisposition.delivered,
    );
    expect(opened, hasLength(2));
  });

  test(
    'forwards the destination and does not dedupe different actions',
    () async {
      final subject = coordinator();

      expect(
        await subject.enqueue(
          action('camera', target: NewSessionLaunchTarget.camera),
        ),
        NewSessionLaunchDisposition.delivered,
      );
      expect(
        await subject.enqueue(
          action('voice', target: NewSessionLaunchTarget.voice),
        ),
        NewSessionLaunchDisposition.delivered,
      );
      expect(openedTargets, const [
        NewSessionLaunchTarget.camera,
        NewSessionLaunchTarget.voice,
      ]);
    },
  );

  test(
    'uses selector for multiple instances and consumes cancellation',
    () async {
      connections = [connection('a'), connection('b')];
      final subject = coordinator(selector: (_) async => null);

      expect(
        await subject.enqueue(action('one')),
        NewSessionLaunchDisposition.cancelled,
      );
      expect(subject.state, NewSessionLaunchCoordinatorState.cancelled);
      expect(subject.hasPending, isFalse);
      expect(opened, isEmpty);
    },
  );

  test(
    'does not navigate when no instance exists and retries after setup',
    () async {
      connections = [];
      final subject = coordinator();

      expect(
        await subject.enqueue(action('one')),
        NewSessionLaunchDisposition.queued,
      );
      expect(subject.hasPending, isTrue);
      connections = [connection('created')];
      expect(await subject.retry(), NewSessionLaunchDisposition.delivered);
      expect(opened, hasLength(1));
    },
  );

  test(
    'open setup bypasses onboarding but still uses the route callback',
    () async {
      onboarded = false;
      var openedSetup = 0;
      final subject = coordinator(openSetup: () async => openedSetup++);

      expect(
        await subject.enqueue(
          action('setup', kind: NewSessionLaunchKind.openSetup),
        ),
        NewSessionLaunchDisposition.delivered,
      );
      expect(openedSetup, 1);
      expect(opened, isEmpty);
    },
  );

  test(
    'open session resolves the instance and forwards the session id',
    () async {
      final openedSessions = <String>[];
      final subject = coordinator(
        openSession: (selected, sessionId) async {
          expect(selected.id, 'only');
          openedSessions.add(sessionId);
          return NavigationDeliveryOutcome.delivered;
        },
      );

      expect(
        await subject.enqueue(
          action(
            'resume',
            kind: NewSessionLaunchKind.openSession,
            sessionId: 'session-1',
          ),
        ),
        NewSessionLaunchDisposition.delivered,
      );
      expect(openedSessions, ['session-1']);
      expect(opened, isEmpty);
    },
  );

  test(
    'retains a draft action when its navigation commit is deferred',
    () async {
      var attempts = 0;
      final subject = coordinator(
        navigator: (_, draft, target) async {
          attempts += 1;
          if (attempts == 1) {
            unlocked = false;
            return NavigationDeliveryOutcome.deferred;
          }
          opened.add(draft);
          return NavigationDeliveryOutcome.delivered;
        },
      );

      expect(
        await subject.enqueue(action('deferred-draft')),
        NewSessionLaunchDisposition.queued,
      );
      expect(subject.state, NewSessionLaunchCoordinatorState.waitingForUnlock);
      expect(subject.hasPending, isTrue);
      expect(opened, isEmpty);
      expect(attempts, 1);

      expect(await subject.retry(), NewSessionLaunchDisposition.queued);
      expect(attempts, 1);
      unlocked = true;
      expect(await subject.retry(), NewSessionLaunchDisposition.delivered);
      expect(subject.hasPending, isFalse);
      expect(opened, hasLength(1));
      expect(attempts, 2);
    },
  );

  test(
    'retains a widget session when its navigation commit is deferred',
    () async {
      var attempts = 0;
      final openedSessions = <String>[];
      final subject = coordinator(
        openSession: (_, sessionId) async {
          attempts += 1;
          if (attempts == 1) return NavigationDeliveryOutcome.deferred;
          openedSessions.add(sessionId);
          return NavigationDeliveryOutcome.delivered;
        },
      );

      final resume = action(
        'deferred-session',
        kind: NewSessionLaunchKind.openSession,
        sessionId: 'session-locked',
      );
      expect(await subject.enqueue(resume), NewSessionLaunchDisposition.queued);
      expect(subject.hasPending, isTrue);
      expect(openedSessions, isEmpty);

      expect(await subject.retry(), NewSessionLaunchDisposition.delivered);
      expect(subject.hasPending, isFalse);
      expect(openedSessions, ['session-locked']);
      expect(attempts, 2);
    },
  );
}
