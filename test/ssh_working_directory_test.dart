// Ola 6 (mock 136 v2-A `.ctx`): the second line over the terminal is the
// folder the shell is in, only as the shell itself says it: OSC 7, else the
// title bash sets by default. Nothing is guessed.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/ssh_working_directory.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('OSC 7', () {
    test('a file:// URL gives its decoded path', () {
      expect(
        sshWorkingDirectoryFromOsc7(['file://host/home/ana/proyecto']),
        '/home/ana/proyecto',
      );
      expect(
        sshWorkingDirectoryFromOsc7(['file://host/srv/mi%20carpeta']),
        '/srv/mi carpeta',
      );
      // xterm splits the OSC on «;»: a path with one comes back whole.
      expect(sshWorkingDirectoryFromOsc7(['file://h/a', 'b']), '/a;b');
      expect(sshWorkingDirectoryFromOsc7(['file:///tmp']), '/tmp');
      // gint46: a path after the host is what counts; no host is fine.
      expect(sshWorkingDirectoryFromOsc7(['file:///home/ana']), '/home/ana');
      expect(
        sshWorkingDirectoryFromOsc7(['file://host/home/ana']),
        '/home/ana',
      );
    });

    test('anything else is no folder', () {
      for (final args in [
        <String>[],
        [''],
        ['http://host/x'],
        ['/home/ana'],
        ['file://host'],
        ['file://host/${'x' * 1100}'],
      ]) {
        expect(sshWorkingDirectoryFromOsc7(args), isNull, reason: '$args');
      }
    });
  });

  group('bash\'s default title', () {
    test('user@host: dir gives dir', () {
      expect(
        sshWorkingDirectoryFromTitle('ana@demo: ~/proyecto'),
        '~/proyecto',
      );
      expect(sshWorkingDirectoryFromTitle('root@srv-1:/etc'), '/etc');
      expect(sshWorkingDirectoryFromTitle('ana@demo.lan: ~'), '~');
    });

    test('a program\'s title, or tmux\'s, is no folder', () {
      for (final title in ['vim notes.md', 'demo', 'htop', 'ana@demo', '']) {
        expect(sshWorkingDirectoryFromTitle(title), isNull, reason: title);
      }
    });
  });

  // REVIEW-T2-D P3-2: a server's folder never reads backwards.
  test('bidirectional marks and C1 controls are taken out', () {
    expect(
      sshWorkingDirectoryFromTitle('ana@demo: ~/\u202Etxt.exe'),
      '~/txt.exe',
    );
    expect(
      sshWorkingDirectoryFromOsc7(['file://h/srv/a\u2066b\u2069\u200Fc']),
      '/srv/abc',
    );
    expect(
      sshWorkingDirectoryFromTitle('ana@demo: ~/x\u0085y\u2028'),
      '~/xy',
    );
    // Only marks: nothing left of a folder.
    expect(sshWorkingDirectoryFromTitle('ana@demo: \u202E\u202C'), isNull);
  });

  test('the user\'s home reads as ~', () {
    expect(sshShortDirectory('/home/ana/proyecto', 'ana'), '~/proyecto');
    expect(sshShortDirectory('/home/ana', 'ana'), '~');
    expect(sshShortDirectory('/home/anabel/x', 'ana'), '/home/anabel/x');
    expect(sshShortDirectory('/root/x', 'root'), '~/x');
    expect(sshShortDirectory('/srv/app', 'ana'), '/srv/app');
    expect(sshShortDirectory('/home/ana/x', null), '/home/ana/x');
  });

  test('the session follows what its shell says', () {
    final terminal = Terminal();
    final session = SshTerminalSession('c1', terminal);
    expect(session.workingDirectory.value, isNull);

    terminal.write('\x1b]0;ana@demo: ~/proyecto\x07');
    expect(session.workingDirectory.value, '~/proyecto');

    terminal.write('\x1b]7;file://demo/home/ana/proyecto/lib\x07');
    expect(session.workingDirectory.value, '/home/ana/proyecto/lib');

    // Once OSC 7 speaks, a later title (a program's) does not move it.
    terminal.write('\x1b]0;ana@demo: ~/otra\x07');
    expect(session.workingDirectory.value, '/home/ana/proyecto/lib');

    // Other private OSCs are ignored.
    terminal.write('\x1b]1337;SetMark\x07');
    expect(session.workingDirectory.value, '/home/ana/proyecto/lib');
  });
}
