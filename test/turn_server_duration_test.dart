// The duration of a finished turn by the server's clock («Trabajó 186 s» for
// a 41 s turn reconciled minutes later from the background).
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/turn_server_duration.dart';

const prompt = 1800000000.0; // seconds, as Hermes stamps its rows

Map<String, dynamic> user({double? at = prompt, bool optimistic = false}) => {
  'role': 'user',
  'content': 'Ejecuta sleep 30',
  'timestamp': ?at,
  if (optimistic) '_optimistic': true,
};

Map<String, dynamic> assistant(double? at, {bool pipeline = false}) => {
  'role': 'assistant',
  'content': 'listo',
  'timestamp': ?at,
  if (pipeline) '_pipeline': true,
};

void main() {
  test('server times: final row minus the prompt', () {
    final rows = [
      assistant(prompt + 41),
      {'role': 'tool', 'content': 'ok', 'timestamp': prompt + 35},
      {'role': 'assistant', 'content': '', 'timestamp': prompt + 3},
      user(),
    ];
    expect(serverTurnDuration(rows, 0), const Duration(seconds: 41));
  });

  test('milliseconds and fractional seconds are both server time', () {
    final rows = [
      assistant((prompt + 27.5) * 1000),
      user(at: prompt),
    ];
    expect(serverTurnDuration(rows, 0), const Duration(milliseconds: 27500));
  });

  test('a tool result stamped after the final row extends the turn', () {
    final rows = [
      assistant(prompt + 20),
      {'role': 'tool', 'content': 'ok', 'timestamp': prompt + 22},
      user(),
    ];
    expect(serverTurnDuration(rows, 0), const Duration(seconds: 22));
  });

  test('the prompt is the nearest real user row; older turns do not count',
      () {
    final rows = [
      assistant(prompt + 41),
      {
        'role': 'user',
        'content': 'corrección',
        '_steer': true,
        'timestamp': prompt + 10,
      },
      user(),
      assistant(prompt - 100),
      user(at: prompt - 300),
    ];
    expect(serverTurnDuration(rows, 0), const Duration(seconds: 41));
  });

  test('missing timestamps: null (the caller keeps its own measure)', () {
    expect(serverTurnDuration([assistant(null), user()], 0), isNull);
    expect(serverTurnDuration([assistant(prompt + 41), user(at: null)], 0),
        isNull);
    expect(serverTurnDuration([assistant(prompt + 41)], 0), isNull,
        reason: 'no prompt');
  });

  test('local copies never mix with server time', () {
    expect(
      serverTurnDuration([assistant(prompt + 41, pipeline: true), user()], 0),
      isNull,
      reason: 'the live row is not the durable final row',
    );
    expect(
      serverTurnDuration([
        assistant(prompt + 41),
        user(at: prompt, optimistic: true),
        user(at: prompt - 600),
      ], 0),
      isNull,
      reason: 'the prompt is still the local copy',
    );
  });

  test('absurd values: null', () {
    expect(
      serverTurnDuration([assistant(prompt - 5), user()], 0),
      isNull,
      reason: 'negative',
    );
    expect(
      serverTurnDuration([assistant(prompt), user()], 0),
      isNull,
      reason: 'zero',
    );
    expect(
      serverTurnDuration([assistant(prompt + 25 * 3600), user()], 0),
      isNull,
      reason: 'a day or more',
    );
    expect(serverTurnDuration([assistant(prompt + 41), user()], 3), isNull);
    expect(serverTurnDuration([assistant(prompt + 41), user()], -1), isNull);
    expect(
      serverTurnDuration([user(), assistant(prompt + 41)], 0),
      isNull,
      reason: 'not an assistant row',
    );
  });
}
