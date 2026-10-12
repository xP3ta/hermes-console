import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late ConnectionManager manager;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    await manager.setActiveProfile('c1', 'ana');
  });

  test('one shared scope per connection, seeded from the saved value', () {
    final a = ActiveProfileScope.of(manager, 'c1');
    expect(identical(a, ActiveProfileScope.of(manager, 'c1')), isTrue);
    expect(a.name, 'ana');
    expect(a.owner, 'ana');
    expect(ActiveProfileScope.of(manager, 'c2').owner, 'default');
    expect(ActiveProfileScope.of(manager, 'c2').isDefault, isTrue);
  });

  test('a switch persists, notifies once and bumps the epoch', () async {
    final scope = ActiveProfileScope.of(manager, 'c1');
    var notified = 0;
    scope.addListener(() => notified++);
    final before = scope.epoch;
    await scope.switchTo('bob');
    expect(manager.activeProfileFor('c1'), 'bob');
    expect(scope.owner, 'bob');
    expect(scope.epoch, before + 1);
    expect(notified, 1);
    // Re-selecting the same profile is not a switch.
    await scope.switchTo('bob');
    expect(notified, 1);
    // `default` is the empty name, like ConnectionManager stores it.
    await scope.switchTo('default');
    expect(manager.activeProfileFor('c1'), '');
    expect(scope.owner, 'default');
    expect(notified, 2);
  });

  test('switches on one connection never touch another', () async {
    final c1 = ActiveProfileScope.of(manager, 'c1');
    final c2 = ActiveProfileScope.of(manager, 'c2');
    var c2Notified = 0;
    c2.addListener(() => c2Notified++);
    final ticket = c2.capture();
    await c1.switchTo('bob');
    expect(c2Notified, 0);
    expect(ticket.isCurrent, isTrue);
  });

  test('a read captured before a switch is no longer current', () async {
    final scope = ActiveProfileScope.of(manager, 'c1');
    final ticket = scope.capture();
    expect(ticket.owner, 'ana');
    expect(ticket.name, 'ana');
    expect(ticket.isCurrent, isTrue);
    await scope.switchTo('bob');
    expect(ticket.isCurrent, isFalse);
    // Switching back does not revive the old read: a newer read is on its way.
    await scope.switchTo('ana');
    expect(ticket.isCurrent, isFalse);
    expect(scope.capture().isCurrent, isTrue);
  });

  test('a value written behind the manager is still caught by the owner '
      'check', () async {
    final scope = ActiveProfileScope.of(manager, 'c1');
    final ticket = scope.capture();
    await manager.prefs.setString('active_profile_c1', 'zoe');
    expect(scope.name, 'zoe');
    expect(ticket.isCurrent, isFalse);
  });

  test('a fixed ticket (a bot card) ignores the active profile', () async {
    final scope = ActiveProfileScope.of(manager, 'c1');
    final ticket = ProfileReadTicket.fixed('bob');
    expect(ticket.owner, 'bob');
    await scope.switchTo('zoe');
    expect(ticket.isCurrent, isTrue);
    expect(ProfileReadTicket.fixed('').name, '');
    expect(ProfileReadTicket.fixed('').owner, 'default');
  });
}
