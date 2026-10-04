// The terminal never runs without App Lock: off means a notice and zero
// requests, a failed verify sends nothing, and coming back after the lock
// timeout needs a fresh verify with everything on screen wiped.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/terminal_pane_controller.dart';

import 'support/fake_terminal_gateway.dart';

void main() {
  test('App Lock off: notice only, no verify, no request', () async {
    final gateway = FakeTerminalGateway();
    var verifies = 0;
    final c = TerminalPaneController(
      gateway: gateway,
      profile: 'p',
      appLockEnabled: () => false,
      verify: () async {
        verifies++;
        return true;
      },
    );
    addTearDown(c.dispose);
    await c.open();
    expect(c.access, TerminalPaneAccess.appLockRequired);
    await c.run('ls');
    expect(gateway.commands, isEmpty);
    expect(verifies, 0);
  });

  test('a failed verify sends nothing and keeps the page locked', () async {
    final gateway = FakeTerminalGateway();
    final c = TerminalPaneController(
      gateway: gateway,
      profile: 'p',
      appLockEnabled: () => true,
      verify: () async => false,
    );
    addTearDown(c.dispose);
    await c.open();
    expect(c.access, TerminalPaneAccess.locked);
    await c.run('ls');
    expect(gateway.commands, isEmpty);
  });

  test('a verified open probes once and becomes ready', () async {
    final gateway = FakeTerminalGateway();
    final c = TerminalPaneController(
      gateway: gateway,
      profile: 'p',
      appLockEnabled: () => true,
      verify: () async => true,
    );
    addTearDown(c.dispose);
    await c.open();
    expect(c.access, TerminalPaneAccess.ready);
    expect(gateway.commands.map((x) => x.command), ['']);
  });

  test('re-locking wipes history and output and needs a new verify', () async {
    final gateway = FakeTerminalGateway();
    final appLocked = ValueNotifier<bool>(false);
    var verifies = 0;
    final c = TerminalPaneController(
      gateway: gateway,
      profile: 'p',
      appLockEnabled: () => true,
      verify: () async {
        verifies++;
        return true;
      },
      appLocked: appLocked,
    );
    addTearDown(c.dispose);
    await c.open();
    await c.run('ls');
    expect(c.history, ['ls']);

    appLocked.value = true;
    expect(c.access, TerminalPaneAccess.locked);
    expect(c.history, isEmpty);
    expect(c.lastResult, isNull);
    await c.run('pwd');
    expect(gateway.ran, ['ls'], reason: 'nothing runs while locked');

    appLocked.value = false;
    expect(c.access, TerminalPaneAccess.locked, reason: 'unlock is not verify');
    await c.unlock();
    expect(verifies, 2);
    expect(c.access, TerminalPaneAccess.ready);
    await c.run('pwd');
    expect(gateway.ran, ['ls', 'pwd']);
  });

  test('a failed re-verify stays locked and sends nothing', () async {
    final gateway = FakeTerminalGateway();
    final appLocked = ValueNotifier<bool>(false);
    var allow = true;
    final c = TerminalPaneController(
      gateway: gateway,
      profile: 'p',
      appLockEnabled: () => true,
      verify: () async => allow,
      appLocked: appLocked,
    );
    addTearDown(c.dispose);
    await c.open();
    appLocked.value = true;
    appLocked.value = false;
    allow = false;
    await c.unlock();
    expect(c.access, TerminalPaneAccess.locked);
    await c.run('ls');
    expect(gateway.ran, isEmpty);
  });

  test('App Lock turned off while open stops further commands', () async {
    final gateway = FakeTerminalGateway();
    var enabled = true;
    final c = TerminalPaneController(
      gateway: gateway,
      profile: 'p',
      appLockEnabled: () => enabled,
      verify: () async => true,
    );
    addTearDown(c.dispose);
    await c.open();
    enabled = false;
    await c.run('ls');
    expect(gateway.ran, isEmpty);
    expect(c.access, TerminalPaneAccess.appLockRequired);
  });
}
