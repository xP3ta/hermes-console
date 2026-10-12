import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/state/companion_controller.dart';

void main() {
  group('QA 9493: the header wears only the chat\'s own companion', () {
    test('same connection and profile: yes; default is "" or "default"', () {
      expect(
        companionScopeMatchesChat(
          const CompanionScope('c1', 'vozlive'),
          connectionId: 'c1',
          profileName: 'vozlive',
          botSurface: true,
        ),
        isTrue,
      );
      expect(
        companionScopeMatchesChat(
          const CompanionScope('c1', ''),
          connectionId: 'c1',
          profileName: null,
          botSurface: false,
        ),
        isTrue,
      );
      expect(
        companionScopeMatchesChat(
          const CompanionScope('c1', 'default'),
          connectionId: 'c1',
          profileName: null,
          botSurface: false,
        ),
        isTrue,
      );
    });

    test('another profile or connection: never', () {
      expect(
        companionScopeMatchesChat(
          const CompanionScope('c1', 'vozlive'),
          connectionId: 'c1',
          profileName: 'radar',
          botSurface: true,
        ),
        isFalse,
      );
      expect(
        companionScopeMatchesChat(
          const CompanionScope('c1', ''),
          connectionId: 'c1',
          profileName: 'radar',
          botSurface: true,
        ),
        isFalse,
      );
      expect(
        companionScopeMatchesChat(
          const CompanionScope('c2', 'vozlive'),
          connectionId: 'c1',
          profileName: 'vozlive',
          botSurface: true,
        ),
        isFalse,
      );
    });

    test('no scope (legacy global companion): only the default chat', () {
      expect(
        companionScopeMatchesChat(
          null,
          connectionId: 'c1',
          profileName: null,
          botSurface: false,
        ),
        isTrue,
      );
      expect(
        companionScopeMatchesChat(
          null,
          connectionId: 'c1',
          profileName: 'radar',
          botSurface: true,
        ),
        isFalse,
      );
      expect(
        companionScopeMatchesChat(
          null,
          connectionId: 'c1',
          profileName: 'forja',
          botSurface: false,
        ),
        isFalse,
      );
    });
  });
}
