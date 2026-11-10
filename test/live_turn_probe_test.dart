import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/services/live_turn_probe.dart';

/// conn-registry: the verdict of one `session.active_list` answer, as
/// Desktop's `liveTurnVerdict` (apps/desktop/src/store/session-states.ts:
/// 397-418).
void main() {
  DesktopActiveSession row(String id, String? status) =>
      DesktopActiveSession(runtimeSessionId: id, status: status);

  test('the Desktop thresholds', () {
    expect(liveTurnEventSilence, const Duration(seconds: 45));
    expect(liveTurnProbeTimeout, const Duration(seconds: 15));
  });

  test('a runtime missing from a well-formed list has ended', () {
    expect(
      liveTurnVerdictFor(
        DesktopActiveSessionList(sessions: [row('other', 'working')]),
        'rt-1',
      ),
      LiveTurnVerdict.ended,
    );
    expect(
      liveTurnVerdictFor(const DesktopActiveSessionList(), 'rt-1'),
      LiveTurnVerdict.ended,
    );
  });

  test('idle or no status has ended', () {
    for (final status in ['idle', 'IDLE', null, '']) {
      expect(
        liveTurnVerdictFor(
          DesktopActiveSessionList(sessions: [row('rt-1', status)]),
          'rt-1',
        ),
        LiveTurnVerdict.ended,
        reason: '$status',
      );
    }
  });

  test('busy words are running', () {
    for (final status in ['starting', 'waiting', 'working', 'running']) {
      expect(
        liveTurnVerdictFor(
          DesktopActiveSessionList(sessions: [row('rt-1', status)]),
          'rt-1',
        ),
        LiveTurnVerdict.running,
        reason: status,
      );
    }
  });

  test('anything unreadable is unknown, never ended', () {
    expect(liveTurnVerdictFor(null, 'rt-1'), LiveTurnVerdict.unknown);
    expect(
      liveTurnVerdictFor(const DesktopActiveSessionList(), ''),
      LiveTurnVerdict.unknown,
    );
    expect(
      liveTurnVerdictFor(
        const DesktopActiveSessionList(hasMalformedRows: true),
        'rt-1',
      ),
      LiveTurnVerdict.unknown,
      reason: 'an unreadable row may be this runtime',
    );
    expect(
      liveTurnVerdictFor(
        DesktopActiveSessionList(sessions: [row('rt-1', 'mystery')]),
        'rt-1',
      ),
      LiveTurnVerdict.unknown,
    );
    expect(
      liveTurnVerdictFor(
        DesktopActiveSessionList(
          sessions: [row('rt-1', 'idle'), row('rt-1', 'working')],
        ),
        'rt-1',
      ),
      LiveTurnVerdict.unknown,
    );
  });
}
