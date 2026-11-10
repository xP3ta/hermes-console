import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/new_session_launch_action.dart';

NewSessionLaunchAction action({String? requested}) => NewSessionLaunchAction(
  source: NewSessionLaunchSource.widget,
  nativeEventId: 'event-1',
  requestedInstanceId: requested,
  receivedElapsedMs: 42,
);

void main() {
  group('NewSessionLaunchAction', () {
    test('accepts the allowlisted v1 payload and ignores unknown fields', () {
      final parsed = NewSessionLaunchAction.tryParse(<String, Object?>{
        'contract_version': 1,
        'kind': 'new_session',
        'source': 'widget',
        'native_event_id': 'evt_123',
        'received_elapsed_ms': 987,
        'requested_instance_id': 'instance-1',
        'api_key': 'must-not-be-read',
        'prompt': 'must-not-be-read',
      });

      expect(parsed, isNotNull);
      expect(parsed!.source, NewSessionLaunchSource.widget);
      expect(parsed.target, NewSessionLaunchTarget.composer);
      expect(parsed.requestedInstanceId, 'instance-1');
      expect(parsed.nativeEventId, 'evt_123');
    });

    test('assistant source only opens a new chat with the voice ready', () {
      Map<String, Object?> payload(String kind, String? target) =>
          <String, Object?>{
            'contract_version': 1,
            'kind': kind,
            'source': 'assistant',
            'native_event_id': 'evt-assistant',
            'target': ?target,
            if (kind == 'open_session') 'session_id': 'abc',
            'received_elapsed_ms': 5,
          };

      final ok = NewSessionLaunchAction.tryParse(
        payload('new_session', 'voice'),
      );
      expect(ok, isNotNull);
      expect(ok!.source, NewSessionLaunchSource.assistant);
      expect(ok.target, NewSessionLaunchTarget.voice);

      expect(
        NewSessionLaunchAction.tryParse(payload('new_session', 'camera')),
        isNull,
      );
      expect(
        NewSessionLaunchAction.tryParse(payload('new_session', null)),
        isNull,
      );
      for (final kind in ['open_app', 'open_session', 'open_setup']) {
        expect(
          NewSessionLaunchAction.tryParse(payload(kind, 'voice')),
          isNull,
          reason: kind,
        );
      }
    });

    test('accepts only the four allowlisted widget destinations', () {
      for (final target in NewSessionLaunchTarget.values) {
        final parsed = NewSessionLaunchAction.tryParse(<String, Object?>{
          'contract_version': 1,
          'kind': 'new_session',
          'source': 'widget',
          'native_event_id': 'evt-${target.name}',
          'target': target.name,
          'received_elapsed_ms': 987,
        });
        expect(parsed?.target, target);
      }
    });

    test('accepts widget routes and requires a safe id for open session', () {
      Map<String, Object?> payload(String kind) => <String, Object?>{
        'contract_version': 1,
        'kind': kind,
        'source': 'widget',
        'native_event_id': 'evt-$kind',
        'received_elapsed_ms': 987,
      };

      expect(
        NewSessionLaunchAction.tryParse(payload('open_app'))?.kind,
        NewSessionLaunchKind.openApp,
      );
      expect(
        NewSessionLaunchAction.tryParse(payload('open_setup'))?.kind,
        NewSessionLaunchKind.openSetup,
      );
      expect(NewSessionLaunchAction.tryParse(payload('open_session')), isNull);
      expect(
        NewSessionLaunchAction.tryParse({
          ...payload('open_session'),
          'session_id': 'session-1',
        })?.kind,
        NewSessionLaunchKind.openSession,
      );
    });

    test('fails closed for unsupported versions, source and unsafe ids', () {
      Map<String, Object?> payload() => <String, Object?>{
        'contract_version': 1,
        'kind': 'new_session',
        'source': 'shortcut',
        'native_event_id': 'evt-1',
        'received_elapsed_ms': 1,
      };

      expect(
        NewSessionLaunchAction.tryParse({...payload(), 'contract_version': 2}),
        isNull,
      );
      expect(
        NewSessionLaunchAction.tryParse({...payload(), 'source': 'external'}),
        isNull,
      );
      expect(
        NewSessionLaunchAction.tryParse({
          ...payload(),
          'requested_instance_id': '../secret',
        }),
        isNull,
      );
      expect(
        NewSessionLaunchAction.tryParse({...payload(), 'native_event_id': ''}),
        isNull,
      );
      expect(
        NewSessionLaunchAction.tryParse({...payload(), 'target': 'settings'}),
        isNull,
      );
    });
  });

  group('resolveNewSessionInstance', () {
    test('uses requested, active, default and only connection in order', () {
      expect(
        resolveNewSessionInstance(
          action: action(requested: 'b'),
          connectionIds: const ['a', 'b'],
          activeConnectionId: 'a',
          defaultConnectionId: 'a',
        ).reason,
        InstanceResolutionReason.requested,
      );
      expect(
        resolveNewSessionInstance(
          action: action(requested: 'missing'),
          connectionIds: const ['a', 'b'],
          activeConnectionId: 'b',
          defaultConnectionId: 'a',
        ).reason,
        InstanceResolutionReason.active,
      );
      expect(
        resolveNewSessionInstance(
          action: action(),
          connectionIds: const ['a', 'b'],
          activeConnectionId: 'missing',
          defaultConnectionId: 'b',
        ).reason,
        InstanceResolutionReason.defaultConnection,
      );
      expect(
        resolveNewSessionInstance(
          action: action(),
          connectionIds: const ['only'],
        ).reason,
        InstanceResolutionReason.onlyConnection,
      );
    });

    test('asks for selection with multiple unresolved connections', () {
      final result = resolveNewSessionInstance(
        action: action(),
        connectionIds: const ['a', 'b'],
      );
      expect(result.kind, InstanceResolutionKind.needsSelection);
      expect(result.candidateIds, const ['a', 'b']);
    });

    test('requires onboarding when no connection exists', () {
      expect(
        resolveNewSessionInstance(
          action: action(),
          connectionIds: const [],
        ).kind,
        InstanceResolutionKind.needsOnboarding,
      );
    });
  });
}
