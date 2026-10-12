// The commands the app shows are the setup helper's own
// (github.com/xP3ta/hermes-setup): pinned here, letter for letter, so the app
// and the helper cannot drift apart unnoticed.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/hermes_setup_commands.dart';

void main() {
  const raw = 'https://raw.githubusercontent.com/xP3ta/hermes-setup/main';

  test('one line per system for each thing the helper does', () {
    expect(
      HermesSetupCommands.setup(SetupHostSystem.unix),
      'curl -fsSL $raw/hermes-mobile-setup.sh | sh',
    );
    expect(
      HermesSetupCommands.setup(SetupHostSystem.windows),
      'irm $raw/hermes-mobile-setup.ps1 | iex',
    );
    expect(
      HermesSetupCommands.showCodeAgain(SetupHostSystem.unix),
      'curl -fsSL $raw/hermes-pair.sh | sh',
    );
    expect(
      HermesSetupCommands.showCodeAgain(SetupHostSystem.windows),
      'irm $raw/hermes-pair.ps1 | iex',
    );
    expect(
      HermesSetupCommands.newAccess(SetupHostSystem.unix),
      'curl -fsSL $raw/hermes-mobile-setup.sh | sh -s -- --new-access',
    );
    expect(
      HermesSetupCommands.newAccess(SetupHostSystem.windows),
      '& ([scriptblock]::Create((irm $raw/hermes-mobile-setup.ps1))) '
      '-NewAccess',
    );
    expect(
      HermesSetupCommands.retireBridge(SetupHostSystem.unix),
      'curl -fsSL $raw/hermes-mobile-setup.sh | sh -s -- --retire-bridge',
    );
    expect(
      HermesSetupCommands.retireBridge(SetupHostSystem.windows),
      '& ([scriptblock]::Create((irm $raw/hermes-mobile-setup.ps1))) '
      '-RetireBridge',
    );
  });

  test(
    'every command is one line, asks for no administrator, hides nothing',
    () {
      for (final system in SetupHostSystem.values) {
        for (final command in [
          HermesSetupCommands.setup(system),
          HermesSetupCommands.showCodeAgain(system),
          HermesSetupCommands.newAccess(system),
          HermesSetupCommands.retireBridge(system),
        ]) {
          expect(command, isNot(contains('\n')));
          expect(command, isNot(contains('sudo')));
          if (system == SetupHostSystem.unix) {
            expect(command, startsWith('curl -fsSL $raw/'));
          } else {
            expect(
              command,
              matches(RegExp(r'^(irm|& \(\[scriptblock\]::Create\(\(irm) ')),
            );
          }
          expect(command, contains('$raw/hermes-'));
        }
      }
    },
  );
}
