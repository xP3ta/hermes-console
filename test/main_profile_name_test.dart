// The main profile («default» on the server) is named everywhere with the
// name it has in the Bots list: its title, else its display name, and
// «Hermes» only when it has no name at all. A secondary profile is not
// renamed by any of it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/services/bot_roster_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/agent_name_scope.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/widgets/profile_scope.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _titled = AgentProfile(
  name: 'default',
  isDefault: true,
  // The server calls the main profile «Hermes»; its owner named it.
  displayName: 'Hermes',
  botModeUiMeta: {'title': 'xPeta'},
);
const _display = AgentProfile(
  name: 'default',
  isDefault: true,
  displayName: 'Luffy',
);
const _nameless = AgentProfile(name: 'default', isDefault: true);
const _ana = AgentProfile(name: 'ana');
const _anaTitled = AgentProfile(
  name: 'ana',
  botModeUiMeta: {'title': 'Ana B.'},
);

BotRosterStore _store(List<AgentProfile> profiles) {
  final registry = BotRosterRegistry();
  registry.publish('conn', 'QA', profiles);
  return registry.store('conn');
}

void main() {
  test('visibleName: title, else display name, else «Hermes» for the main '
      'profile and its own name for any other', () {
    expect(_titled.visibleName, 'xPeta');
    expect(_display.visibleName, 'Luffy');
    expect(_nameless.visibleName, 'Hermes');
    expect(_ana.visibleName, 'ana');
    expect(_anaTitled.visibleName, 'Ana B.');
    // The raw `default` id is never a name.
    expect(const AgentProfile(name: 'default').visibleName, 'Hermes');
  });

  test('a secondary profile is not renamed by any of it', () {
    const forja = AgentProfile(
      name: 'forja',
      displayName: 'x',
      botModeUiMeta: {'title': 'Forja'},
    );
    final s = lookupStrings(const Locale('es'));
    // The switcher and the profile row keep reading its display name; the
    // Bots views keep reading its title, else its name.
    expect(profileDisplayLabel(s, forja), 'x');
    expect(forja.botListName, 'Forja');
    expect(
      const AgentProfile(name: 'bob', displayName: 'Roberto').botListName,
      'bob',
    );
    expect(
      profileDisplayLabel(
        s,
        const AgentProfile(name: 'bob', displayName: 'Roberto'),
      ),
      'Roberto',
    );
    // The main profile's list name is its visible name.
    expect(_titled.botListName, 'xPeta');
    expect(_nameless.botListName, 'Hermes');
  });

  test('agentNameFor: the profile\'s own name, null while the roster does '
      'not know it', () {
    final store = _store([
      _titled,
      const AgentProfile(
        name: 'forja',
        displayName: 'x',
        botModeUiMeta: {'title': 'Forja'},
      ),
    ]);
    expect(agentNameFor(store, null), 'xPeta');
    expect(agentNameFor(store, ''), 'xPeta');
    expect(agentNameFor(store, 'default'), 'xPeta');
    expect(agentNameFor(store, 'forja'), 'Forja');
    expect(agentNameFor(store, 'ghost'), isNull);
    expect(agentNameFor(null, null), isNull);
    expect(agentNameFor(null, 'forja'), isNull);
    expect(agentNameFor(_store([_ana]), null), isNull);
  });

  test('the roster resolvers name the main profile like the Bots list', () {
    final named = _store([_titled, _ana]);
    expect(mainProfileVisibleName(named), 'xPeta');
    expect(profileVisibleNameOf(named, null), 'xPeta');
    expect(profileVisibleNameOf(named, 'default'), 'xPeta');
    expect(profileVisibleNameOf(named, 'ana'), 'ana');
    expect(profileVisibleNameOf(named, 'ghost'), 'ghost');
    expect(mainProfileVisibleName(_store([_nameless])), 'Hermes');
    expect(mainProfileVisibleName(null), 'Hermes');
  });

  test('the profile row of Conversations, the drawer chip and the switcher '
      'read the same name', () {
    final s = lookupStrings(const Locale('es'));
    expect(profileDisplayLabel(s, _titled), 'xPeta');
    expect(profileDisplayLabel(s, _nameless), 'Hermes');
    expect(profileDisplayLabel(s, _ana), 'ana');
    expect(activeProfileDisplayLabel(s, '', [_titled, _ana]), 'xPeta');
    expect(activeProfileDisplayLabel(s, 'default', [_titled, _ana]), 'xPeta');
    expect(activeProfileDisplayLabel(s, 'ana', [_titled, _ana]), 'ana');
  });

  test('every text that speaks of the agent takes its name in 9 languages', () {
    for (final code in ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh']) {
      final s = lookupStrings(Locale(code));
      for (final text in [
        s.mpnComposerHint('xPeta'),
        s.mpnFirstChat('xPeta'),
        s.mpnSteerAdded('xPeta'),
        s.mpnSteerQueued('xPeta'),
        s.mpnRegenerateWarning('xPeta'),
        s.mpnEditHint('xPeta'),
        s.mpnPermissionHeadline('xPeta'),
        s.mpnClarifyTitle('xPeta'),
        s.mpnSudoTitle('xPeta'),
        s.mpnSecretTitle('xPeta'),
      ]) {
        expect(text, contains('xPeta'), reason: code);
        expect(text, isNot(contains('Hermes')), reason: code);
        expect(text, isNot(contains('{name}')), reason: code);
      }
    }
  });

  test('the generic agent titles of the notifications take the main '
      'profile\'s name, and leave a session named «Hermes» alone', () {
    const es = NotifL10n('es');
    expect(es.replyTitle('Backup'), 'Hermes respondió en Backup');
    expect(
      es.replyTitle('Backup', agent: 'xPeta'),
      'xPeta respondió en Backup',
    );
    expect(es.replyTitle(null, agent: 'xPeta'), 'xPeta respondió');
    expect(
      es.replyTitle('Hermes', agent: 'xPeta'),
      'xPeta respondió en Hermes',
    );
    expect(
      es.replyFailedTitle(null, agent: 'xPeta'),
      'xPeta encontró un problema',
    );
    expect(es.approvalTitleFor('xPeta'), 'xPeta necesita tu atención');
    expect(es.approvalTitleFor(null), 'Hermes necesita tu atención');
  });

  Widget host(Widget child) => MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    theme: AppTheme.fromMode(AppThemeMode.dark),
    home: Scaffold(body: child),
  );

  testWidgets('the permission card names the agent the chat talks to, and '
      '«Hermes» without one', (tester) async {
    Widget card() => ChatApprovalCard(
      approval: const {'command': 'ls', 'description': 'run_shell'},
      busy: false,
      onChoice: (_) {},
    );
    await tester.pumpWidget(host(AgentNameScope(name: 'xPeta', child: card())));
    await tester.pump();
    expect(find.text('xPeta pide tu permiso'), findsOneWidget);
    expect(find.text('Hermes pide tu permiso'), findsNothing);

    await tester.pumpWidget(host(card()));
    await tester.pump();
    expect(find.text('Hermes pide tu permiso'), findsOneWidget);
  });

  testWidgets('the scope falls back to «Hermes» outside a chat', (
    tester,
  ) async {
    late String inside;
    late String outside;
    await tester.pumpWidget(
      host(
        Column(
          children: [
            AgentNameScope(
              name: 'xPeta',
              child: Builder(
                builder: (context) {
                  inside = AgentNameScope.of(context);
                  return const SizedBox.shrink();
                },
              ),
            ),
            Builder(
              builder: (context) {
                outside = AgentNameScope.of(context);
                return const SizedBox.shrink();
              },
            ),
          ],
        ),
      ),
    );
    expect(inside, 'xPeta');
    expect(outside, 'Hermes');
  });
}
