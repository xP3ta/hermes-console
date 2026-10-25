import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/ssh_commands.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the default status command queries the real Hermes user units', () async {
    final prefs = await SharedPreferences.getInstance();
    final commands = SshCommandsStore(prefs).load('connection-a');
    final status = commands.singleWhere((cmd) => cmd.label == 'Estado Hermes');

    expect(
      status.command,
      'systemctl --user status '
      'hermes-dashboard hermes-gateway --no-pager || true',
    );
  });
}
