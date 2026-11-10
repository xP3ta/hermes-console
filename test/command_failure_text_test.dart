// ORDEN-COMANDOS, point d: a slash command that fails says why. The reason
// by Hermes' code, translated in the nine languages, and Hermes' own text
// under it, sanitized. Never «Hermes could not run that command» alone.
import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/utils/command_failure.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  final en = lookupStrings(const Locale('en'));
  final es = lookupStrings(const Locale('es'));

  TuiGatewayRpcError rpc(int code, String message) =>
      TuiGatewayRpcError('slash.exec', message, code: code);

  test('each known code says its reason, with Hermes\' words under it', () {
    final cases = <int, (String, String)>{
      4001: (
        '/goal: this chat has no session in Hermes yet. Send a message '
            'first or try again.',
        'no active session',
      ),
      4004: (
        '/goal: Hermes did not accept what you wrote after the command.',
        'usage: /goal <text>',
      ),
      4007: (
        '/goal: Hermes has no live session for this chat. Try again in a '
            'moment.',
        'No live runtime is available for this command',
      ),
      4018: ('/goal: Hermes could not run it.', 'goal: failed to persist'),
      403: (
        '/goal: this connection is read-only.',
        'Remote commands are unavailable in read-only mode',
      ),
      -32601: (
        '/goal: this Hermes server does not support it. Update Hermes Agent.',
        'Method not found',
      ),
      5000: ('/goal failed.', 'internal error'),
    };
    for (final MapEntry(key: code, value: (reason, server)) in cases.entries) {
      expect(
        commandFailureText(en, 'goal', rpc(code, server)),
        '$reason\n$server',
        reason: '$code',
      );
    }
    expect(
      commandFailureText(es, '/goal', rpc(4001, 'no active session')),
      '/goal: este chat aún no tiene sesión en Hermes. Envía un mensaje '
      'primero o reintenta.\nno active session',
    );
  });

  test('no connection and no answer in time are said as such', () {
    expect(
      commandFailureText(
        en,
        'plan',
        const TuiGatewayRpcError(
          'slash.exec',
          'socket closed',
          failureKind: TuiGatewayRpcFailureKind.connectionLost,
        ),
      ),
      '/plan: no connection to Hermes.\nsocket closed',
    );
    expect(
      commandFailureText(
        en,
        'plan',
        const TuiGatewayRpcError(
          'slash.exec',
          'timed out',
          failureKind: TuiGatewayRpcFailureKind.timeout,
        ),
      ),
      '/plan: Hermes did not answer in time.\ntimed out',
    );
    expect(
      commandFailureText(en, 'plan', const SocketException('refused')),
      '/plan: no connection to Hermes.',
    );
    expect(
      commandFailureText(en, 'plan', TimeoutException('slow')),
      '/plan: Hermes did not answer in time.',
    );
    // Anything else still names what it was.
    expect(
      commandFailureText(en, 'plan', StateError('boom')),
      '/plan failed.\nStateError',
    );
  });

  test('Hermes\' text is sanitized: no controls, no runs, bounded', () {
    expect(
      sanitizeCommandFailureDetail('  a\u0007b \t  c\n\n\n  d  '),
      'ab c\nd',
    );
    final long = sanitizeCommandFailureDetail('x' * 1000);
    expect(long, hasLength(commandFailureDetailMaxLength));
    expect(long, endsWith('…'));
    expect(commandFailureText(en, 'goal', rpc(4004, '   ')), contains('/goal'));
    expect(
      commandFailureText(en, 'goal', rpc(4004, '   ')),
      isNot(contains('\n')),
    );
  });

  test('a command Hermes did not accept says so, with its words', () {
    expect(
      commandRejectedText(en, 'goal', 'goal gate refused'),
      '/goal: Hermes could not run it.\ngoal gate refused',
    );
    expect(
      commandRejectedText(en, 'goal', null),
      '/goal: Hermes could not run it.',
    );
  });

  test('every language names the command in every reason', () {
    for (final code in ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh']) {
      final strings = lookupStrings(Locale(code));
      for (final error in <Object>[
        rpc(4001, ''),
        rpc(4004, ''),
        rpc(4007, ''),
        rpc(4018, ''),
        rpc(403, ''),
        rpc(-32601, ''),
        rpc(1, ''),
        const SocketException('x'),
        TimeoutException('x'),
      ]) {
        final text = commandFailureText(strings, 'goal', error);
        expect(text, contains('/goal'), reason: '$code $error');
        expect(text.trim(), isNotEmpty);
      }
    }
  });
}
