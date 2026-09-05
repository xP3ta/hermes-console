import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/services/voice/voice_tool_phase.dart';

void main() {
  test('agrupa herramientas para el estado operativo del modo voz', () {
    const cases = {
      'execute_code': 'exec',
      'bash': 'exec',
      'web_search': 'search',
      'web_extract': 'search',
      'research_reddit': 'search',
      'browser_navigate': 'browse',
      'browser_console': 'browse',
      'write_file': 'write',
      'edit_file': 'write',
      'install_package': 'install',
      'delete_file': 'delete',
      'read_file': 'read',
      'grep': 'read',
      'get_status': 'check',
      'delegate_task': 'coordinate',
    };

    for (final MapEntry(key: tool, value: phase) in cases.entries) {
      expect(voiceToolPhase(tool), phase, reason: tool);
    }
  });

  test('una etiqueta desconocida no inventa una actividad', () {
    expect(voiceToolPhase('unknown_thing'), isNull);
    expect(voiceToolActivity('unknown_thing'), isNull);
  });

  test('labels maliciosos solo producen categoría o desconocido', () {
    const sensitive = '/home/private/project --token secret-value';
    final category = voiceToolPhase('browser\n$sensitive');

    expect(category, 'browse');
    expect(category, isNot(contains('/home')));
    expect(category, isNot(contains('secret-value')));
    expect(voiceToolPhase('unknown_thing\n$sensitive'), isNull);
    expect(
      voiceToolPhase('user_agent_search'),
      'search',
      reason: 'la acción concreta gana sobre un token incidental',
    );
  });

  test('el comentario público gana también durante thinking y speaking', () {
    for (final fallback in const ['Pensando…', 'Hablando…']) {
      expect(
        voiceActivityLineLabel(
          paused: false,
          pausedLabel: 'En pausa',
          publicCommentary: '  Voy a comprobar la integración.  ',
          fallbackLabel: fallback,
        ),
        'Voy a comprobar la integración.',
        reason: fallback,
      );
    }

    expect(
      voiceActivityLineLabel(
        paused: false,
        pausedLabel: 'En pausa',
        publicCommentary: '   ',
        fallbackLabel: 'Pensando…',
      ),
      'Pensando…',
    );
    expect(
      voiceActivityLineLabel(
        paused: true,
        pausedLabel: 'En pausa',
        publicCommentary: 'Voy a comprobar la integración.',
        fallbackLabel: 'Pensando…',
      ),
      'En pausa',
    );
    expect(
      voiceActivityLineLabel(
        paused: false,
        pausedLabel: 'En pausa',
        publicCommentary: '',
        fallbackLabel: 'Could not start the microphone.',
      ),
      'Could not start the microphone.',
    );
  });
}
