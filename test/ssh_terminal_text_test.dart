// 1.4.3: what the terminal reads from its buffer (the question it waits
// on, the address under a finger, the text a selection copies) and what
// it sends besides typing (sticky Ctrl/Alt, a paste).
import 'package:clock/clock.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/ssh_compose_uploads.dart';
import 'package:hermes_android/core/services/ssh_terminal_input.dart';
import 'package:hermes_android/core/services/ssh_terminal_text.dart';
import 'package:xterm/xterm.dart';

List<String>? _labels(List<SshPromptAnswer>? answers) =>
    answers?.map((a) => a.label).toList();

Terminal _terminal({int width = 80, int height = 24}) =>
    Terminal(wordSeparators: sshTerminalWordSeparators)..resize(width, height);

void main() {
  group('the question the shell waits on', () {
    const yesNo = ['y', 'n', '⏎', '^C'];
    for (final (line, expected) in const [
      ('Do you want to continue? [Y/n] ', yesNo),
      ('Proceed (y/n)? ', yesNo),
      ('Overwrite existing file? [y/N]: ', yesNo),
      ('Remove it [ y / n ]', yesNo),
      (
        'Are you sure you want to continue connecting '
            '(yes/no/[fingerprint])? ',
        ['yes', 'no', '⏎', '^C'],
      ),
      ('Proceed (yes/no)? ', ['yes', 'no', '⏎', '^C']),
      ('Press Enter to continue', ['⏎', '^C']),
      ('Press [Enter] to continue...', ['⏎', '^C']),
      ('Press any key to continue . . .', ['⏎', '^C']),
      ('press RETURN to go on:', ['⏎', '^C']),
    ]) {
      test('«$line»', () {
        expect(_labels(sshPromptAnswers(line)), expected);
      });
    }

    for (final line in const [
      'Answer (y/n) later, after the build',
      'echo "[y/N]" > answers.txt',
      'user@host:~/src\$ ',
      '[y/N] is the default answer here.',
      'Press Enter when the build is done and then wait',
      '',
      '   ',
    ]) {
      test('not a question: «$line»', () {
        expect(sshPromptAnswers(line), isNull);
      });
    }

    test('a numbered choice offers its numbers', () {
      expect(
        _labels(
          sshPromptAnswers(
            '#? ',
            above: const ['1) apple', '2) banana', '3) cherry'],
          ),
        ),
        ['1', '2', '3', '⏎', '^C'],
      );
      expect(
        _labels(
          sshPromptAnswers(
            'Select an option [1-2]: ',
            above: const ['Choose a toolchain:', '  1. stable', '  2. nightly'],
          ),
        ),
        ['1', '2', '⏎', '^C'],
      );
      // One row (a hint) may sit between the options and the question.
      expect(
        _labels(
          sshPromptAnswers(
            'Choice: ',
            above: const ['1) yes', '2) no', '(default 1)'],
          ),
        ),
        ['1', '2', '⏎', '^C'],
      );
    });

    test('numbers that are not a choice are left alone', () {
      // A single option, numbers that do not start at 1, options far
      // above, and a prompt that asks nothing.
      expect(sshPromptAnswers('#? ', above: const ['1) only']), isNull);
      expect(sshPromptAnswers('#? ', above: const ['2) b', '3) c']), isNull);
      expect(
        sshPromptAnswers(
          'Choice: ',
          above: const ['1) a', '2) b', 'built in 3 s', 'done'],
        ),
        isNull,
      );
      expect(
        sshPromptAnswers('\$ ', above: const ['1) a', '2) b']),
        isNull,
      );
    });

    test('read from the cursor row of the main screen only', () {
      final terminal = _terminal();
      terminal.write('Remove file? [y/N] ');
      expect(_labels(sshTerminalPrompt(terminal)), yesNo);

      // Answered: the row now ends with the answer, then a new prompt.
      terminal.write('y\r\n\$ ');
      expect(sshTerminalPrompt(terminal), isNull);

      // y/n inside normal output, the cursor on the next prompt.
      terminal.write('Type (y/n) to confirm later\r\n\$ ');
      expect(sshTerminalPrompt(terminal), isNull);

      // Text after the cursor: it is not waiting at the end of a question.
      terminal.write('Delete? [y/N] xyz\x1b[4D');
      expect(sshTerminalPrompt(terminal), isNull);

      terminal.write('\r\n1) apple\r\n2) pear\r\n#? ');
      expect(_labels(sshTerminalPrompt(terminal)), ['1', '2', '⏎', '^C']);

      // A full-screen program draws its own questions.
      terminal.write('\x1b[?1049hContinue? [y/N] ');
      expect(sshTerminalPrompt(terminal), isNull);
    });
  });

  group('the web address under a finger', () {
    test('a wrapped address is read whole from either row', () {
      final terminal = _terminal(width: 20, height: 6);
      terminal.write('go https://example.com/a/very/long/path ok');
      final expected = Uri.parse('https://example.com/a/very/long/path');
      expect(sshTerminalLinkAt(terminal, const CellOffset(5, 0)), expected);
      expect(sshTerminalLinkAt(terminal, const CellOffset(4, 1)), expected);
      expect(sshTerminalLinkAt(terminal, const CellOffset(0, 0)), isNull);
      // «ok» after the address.
      expect(sshTerminalLinkAt(terminal, const CellOffset(1, 2)), isNull);
    });

    test('sentence punctuation and an unopened bracket are not part of it', () {
      final terminal = _terminal();
      terminal.write('(see https://example.com/x). Or ');
      terminal.write('https://en.wikipedia.org/wiki/Tilde_(mark), then');
      expect(
        sshTerminalLinkAt(terminal, const CellOffset(10, 0)),
        Uri.parse('https://example.com/x'),
      );
      expect(
        sshTerminalLinkAt(terminal, const CellOffset(40, 0)),
        Uri.parse('https://en.wikipedia.org/wiki/Tilde_(mark)'),
      );
      // The «).» after the first address.
      expect(sshTerminalLinkAt(terminal, const CellOffset(26, 0)), isNull);
    });

    test('only http and https', () {
      final terminal = _terminal();
      terminal.write('ftp://example.com/x file:///etc/passwd');
      for (var x = 0; x < 38; x++) {
        expect(sshTerminalLinkAt(terminal, CellOffset(x, 0)), isNull);
      }
    });
  });

  group('the text a selection copies', () {
    test('wrapped rows joined, the padding blanks dropped', () {
      final terminal = _terminal(width: 10, height: 6);
      terminal.write('abc   \r\n0123456789wrapped\r\nend');
      final text = sshTerminalText(
        terminal,
        BufferRangeLine(const CellOffset(0, 0), const CellOffset(3, 3)),
      );
      expect(text, 'abc\n0123456789wrapped\nend');
    });

    test('the screen, without the blank rows under it', () {
      final terminal = _terminal(width: 20, height: 4);
      terminal.write('one\r\ntwo\r\nthree\r\nfour\r\nfive');
      expect(sshTerminalScreenText(terminal), 'two\nthree\nfour\nfive');
    });

    test('a long press keeps a path or an address in one word', () {
      final terminal = _terminal();
      terminal.write('cat /var/log/app-1.log now');
      final word = terminal.buffer.getWordBoundary(const CellOffset(8, 0))!;
      expect(
        sshTerminalText(terminal, word),
        '/var/log/app-1.log',
      );
    });
  });

  group('sticky Ctrl and Alt', () {
    test('tap: next key only; double tap: locked; tap again: off', () {
      var now = DateTime(2026, 11, 20, 12);
      withClock(Clock(() => now), () {
        final modifiers = SshKeyModifiers();
        final ctrl = modifiers.ctrl;
        ctrl.tap();
        expect((ctrl.armed.value, ctrl.locked.value), (true, false));
        expect(modifiers.apply('c'), '\x03');
        expect(modifiers.apply('c'), 'c');
        expect(ctrl.armed.value, isFalse);

        // Double tap: locked for every key until tapped again.
        ctrl.tap();
        now = now.add(const Duration(milliseconds: 120));
        ctrl.tap();
        expect((ctrl.armed.value, ctrl.locked.value), (true, true));
        expect(modifiers.apply('a'), '\x01');
        expect(modifiers.apply('e'), '\x05');
        now = now.add(const Duration(seconds: 5));
        ctrl.tap();
        expect((ctrl.armed.value, ctrl.locked.value), (false, false));
        expect(modifiers.apply('a'), 'a');

        // A second tap after the double-tap window lets it go.
        ctrl.tap();
        now = now.add(kDoubleTapTimeout + const Duration(milliseconds: 1));
        ctrl.tap();
        expect((ctrl.armed.value, ctrl.locked.value), (false, false));
        modifiers.dispose();
      });
    });

    test('Alt puts ESC before the key; with Ctrl, before the control', () {
      final modifiers = SshKeyModifiers();
      modifiers.alt.tap();
      expect(modifiers.apply('b'), '\x1bb');
      expect(modifiers.apply('b'), 'b');
      modifiers.ctrl.tap();
      modifiers.alt.armed.value = true;
      expect(modifiers.apply('b'), '\x1b\x02');
      modifiers.dispose();
    });

    test('a terminal reply or a paste does not use them up', () {
      final modifiers = SshKeyModifiers()..ctrl.tap();
      expect(modifiers.apply('\x1b[12;1R'), '\x1b[12;1R');
      final terminal = Terminal();
      final out = <String>[];
      terminal.onOutput = (data) => out.add(modifiers.apply(data));
      sshPasteText(terminal, 'c', modifiers: modifiers);
      expect(out, ['c']);
      expect(modifiers.ctrl.armed.value, isTrue);
      terminal.textInput('c');
      expect(out, ['c', '\x03']);
      modifiers.dispose();
    });

    test('modified arrows emit XTerm CSI and consume sticky modifiers', () {
      final terminal = Terminal();
      final out = <String>[];
      terminal.onOutput = out.add;
      final modifiers = SshKeyModifiers();
      addTearDown(modifiers.dispose);

      modifiers.ctrl.tap();
      sshSendModifiedKey(terminal, modifiers, TerminalKey.arrowLeft);
      expect(out, ['\x1b[1;5D']);
      expect(modifiers.ctrl.armed.value, isFalse);

      out.clear();
      modifiers.alt.tap();
      sshSendModifiedKey(terminal, modifiers, TerminalKey.arrowRight);
      expect(out, ['\x1b[1;3C']);
      expect(modifiers.alt.armed.value, isFalse);

      out.clear();
      modifiers.ctrl.tap();
      modifiers.alt.tap();
      sshSendModifiedKey(terminal, modifiers, TerminalKey.arrowUp);
      expect(out, ['\x1b[1;7A']);
      expect(modifiers.ctrl.armed.value, isFalse);
      expect(modifiers.alt.armed.value, isFalse);

      out.clear();
      sshSendModifiedKey(
        terminal,
        modifiers,
        TerminalKey.arrowDown,
        shift: true,
        ctrl: true,
      );
      expect(out, ['\x1b[1;6B']);
    });
  });

  group('the mouse wheel a full-screen program asked for', () {
    test('wheel up is button 64, down 65, at the cell from 1', () {
      final terminal = Terminal();
      const cell = CellOffset(4, 2);
      expect(sshWheelReport(terminal, up: true, cell: cell), isNull);
      terminal.write('\x1b[?1049h\x1b[?1000h');
      expect(
        sshWheelReport(terminal, up: true, cell: cell),
        '\x1b[M${String.fromCharCodes([32 + 64, 32 + 5, 32 + 3])}',
      );
      terminal.write('\x1b[?1006h');
      expect(sshWheelReport(terminal, up: true, cell: cell), '\x1b[<64;5;3M');
      expect(sshWheelReport(terminal, up: false, cell: cell), '\x1b[<65;5;3M');
      // Clicks only (DECSET 9): no wheel.
      terminal.write('\x1b[?1000l\x1b[?9h');
      expect(sshWheelReport(terminal, up: true, cell: cell), isNull);
    });

    test('the row is the screen\'s, not the scrollback\'s', () {
      final terminal = Terminal()..resize(20, 4);
      for (var i = 0; i < 10; i++) {
        terminal.write('line $i\r\n');
      }
      terminal.write('\x1b[?1002h\x1b[?1006h');
      final scrollBack = terminal.buffer.scrollBack;
      expect(scrollBack, greaterThan(0));
      expect(
        sshWheelReport(terminal, up: true, cell: CellOffset(0, scrollBack)),
        '\x1b[<64;1;1M',
      );
    });

    test('omits out-of-range coordinates in legacy normal and UTF-8 modes', () {
      final normal = Terminal()..write('\x1b[?1000h');
      expect(
        sshWheelReport(normal, up: true, cell: const CellOffset(94, 94)),
        '\x1b[M${String.fromCharCodes([32 + 64, 127, 127])}',
      );
      expect(
        sshWheelReport(normal, up: true, cell: const CellOffset(95, 0)),
        isNull,
      );
      expect(
        sshWheelReport(normal, up: false, cell: const CellOffset(0, 95)),
        isNull,
      );

      final utf = Terminal()..write('\x1b[?1000h\x1b[?1005h');
      expect(
        sshWheelReport(utf, up: true, cell: const CellOffset(2014, 2014)),
        '\x1b[M${String.fromCharCodes([32 + 64, 2047, 2047])}',
      );
      expect(
        sshWheelReport(utf, up: true, cell: const CellOffset(2015, 0)),
        isNull,
      );

      final sgr = Terminal()..write('\x1b[?1000h\x1b[?1006h');
      expect(
        sshWheelReport(sgr, up: true, cell: const CellOffset(249, 119)),
        '\x1b[<64;250;120M',
      );

      final urxvt = Terminal()..write('\x1b[?1000h\x1b[?1015h');
      expect(
        sshWheelReport(urxvt, up: false, cell: const CellOffset(249, 119)),
        '\x1b[97;250;120M',
      );
    });
  });

  group('Compose writes', () {
    test('a path as one shell word, whatever its characters', () {
      expect(sshShellQuote('/tmp/a b.png'), "'/tmp/a b.png'");
      expect(sshShellQuote("/tmp/it's"), r"'/tmp/it'\''s'");
      expect(sshShellQuote(r'/tmp/$(rm -rf ~)'), r"'/tmp/$(rm -rf ~)'");
    });

    test('a clean, stamped, never empty name', () {
      final now = DateTime(2026, 11, 20, 9, 5, 7);
      expect(
        sshUploadFileName('Screenshot 2026 (1).png', now: now, serial: 3),
        '20261120-090507-3-Screenshot_2026_1_.png',
      );
      expect(
        sshUploadFileName('../../.ssh/authorized_keys', now: now, serial: 4),
        '20261120-090507-4-authorized_keys',
      );
      expect(
        sshUploadFileName('.hidden', now: now, serial: 5),
        '20261120-090507-5-hidden',
      );
      expect(sshUploadFileName('ñ', now: now, serial: 6), endsWith('-6-file'));
      expect(
        sshUploadFileName('${'a' * 200}.txt', now: now, serial: 7).length,
        lessThanOrEqualTo(80 + 20),
      );
    });

    test('one write: the paste and its Enter together', () {
      final terminal = Terminal();
      expect(sshPastePayload(terminal, 'ls', enter: true), 'ls\r');
      terminal.write('\x1b[?2004h');
      expect(
        sshPastePayload(terminal, 'a\x1b[201~b', enter: true),
        '\x1b[200~ab\x1b[201~\r',
      );
      expect(sshPastePayload(terminal, 'x'), '\x1b[200~x\x1b[201~');
    });
  });

  group('a paste', () {
    test('bracketed when the program asked for it, plain otherwise', () {
      final terminal = Terminal();
      final out = <String>[];
      terminal.onOutput = out.add;
      sshPasteText(terminal, 'ls -la\nwhoami');
      terminal.write('\x1b[?2004h');
      sshPasteText(terminal, 'ls -la\nwhoami');
      expect(out, ['ls -la\nwhoami', '\x1b[200~ls -la\nwhoami\x1b[201~']);
    });

    test('cannot close its own bracket early', () {
      final terminal = Terminal()..write('\x1b[?2004h');
      final out = <String>[];
      terminal.onOutput = out.add;
      sshPasteText(terminal, 'echo hi\x1b[201~rm -rf x\n');
      expect(out, ['\x1b[200~echo hirm -rf x\n\x1b[201~']);
    });

    test('strips nested, overlapping, 8-bit markers and control bytes', () {
      final terminal = Terminal()..write('\x1b[?2004h');
      final sent = <String>[];
      terminal.onOutput = sent.add;

      const samples = [
        'alpha\x1b[20\x1b[200~1~beta',
        'alpha\x1b[20\x1b[201~0~beta',
        'alpha\x9b201~beta\x9b200~gamma',
        'alpha\x1b]0;label\x07beta\x00\x08\x7f\x85gamma',
      ];
      final forbidden = RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]');

      for (final sample in samples) {
        final payload = sshPastePayload(terminal, sample);
        expect(payload, startsWith('\x1b[200~'));
        expect(payload, endsWith('\x1b[201~'));
        final inner = payload.substring(6, payload.length - 6);
        expect(inner, isNot(contains('\x1b[200~')));
        expect(inner, isNot(contains('\x1b[201~')));
        expect(inner, isNot(contains('\x9b201~')));
        expect(forbidden.hasMatch(inner), isFalse);

        sent.clear();
        sshPasteText(terminal, sample);
        expect(sent, [payload]);
      }

      expect(sshSanitizePaste('a\x1b[20\x1b[200~1~b'), 'ab');
      expect(
        sshSanitizePaste('café\tline1\nline2\r\n'),
        'café\tline1\nline2\r\n',
      );
      expect(sshPastePayload(terminal, '\x1b[201~\x00'), '');
      expect(sshPastePayload(terminal, '\x1b[201~\x00', enter: true), '\r');
    });

    test('preserves letters and newlines across plain and bracketed modes', () {
      final plain = Terminal();
      final plainSent = <String>[];
      plain.onOutput = plainSent.add;
      sshPasteText(plain, 'uno\ndos\t3');
      expect(plainSent, ['uno\ndos\t3']);
      expect(sshPastePayload(plain, 'uno\ndos'), 'uno\ndos');

      final bracketed = Terminal()..write('\x1b[?2004h');
      expect(
        sshPastePayload(bracketed, 'uno\ndos', enter: true),
        '\x1b[200~uno\ndos\x1b[201~\r',
      );
    });

    test('terminal output guard sanitizes direct Terminal.paste frames', () {
      final terminal = Terminal()..write('\x1b[?2004h');
      final wire = <String>[];
      terminal.onOutput = (data) {
        final safe = sshSanitizeTerminalOutput(data);
        if (safe.isNotEmpty) wire.add(safe);
      };

      terminal.paste('left\x1b[20\x1b[200~1~right\x07');
      expect(wire, ['\x1b[200~leftright\x1b[201~']);

      wire.clear();
      terminal.paste('\x1b[201~\x1b');
      expect(wire, isEmpty);
    });
  });
}
