import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/utils/home_recent_sessions.dart';

Session _session({
  String preview = '',
  String? lastUserPreview,
  String? lastAssistantPreview,
  double startedAt = 1,
}) => Session(
  id: 'session',
  title: 'title',
  model: 'model',
  source: 'mobile',
  messageCount: 2,
  isActive: false,
  preview: preview,
  lastUserPreview: lastUserPreview,
  lastAssistantPreview: lastAssistantPreview,
  startedAt: startedAt,
);

void main() {
  test('adapta entre seis y ocho filas y protege texto ampliado', () {
    expect(homeRecentSessionLimit(viewportHeight: 640, textScale: 1), 6);
    expect(homeRecentSessionLimit(viewportHeight: 700, textScale: 1), 7);
    expect(homeRecentSessionLimit(viewportHeight: 800, textScale: 1), 8);
    expect(homeRecentSessionLimit(viewportHeight: 800, textScale: 1.2), 7);
    expect(homeRecentSessionLimit(viewportHeight: 800, textScale: 1.4), 6);
  });

  test('agrupa por hoy, ayer y anteriores en hora local', () {
    final now = DateTime(2026, 7, 26, 20);
    double stamp(DateTime value) => value.millisecondsSinceEpoch / 1000;

    expect(
      homeRecentDateGroup(stamp(DateTime(2026, 7, 26, 1)), now),
      HomeRecentDateGroup.today,
    );
    expect(
      homeRecentDateGroup(stamp(DateTime(2026, 7, 25, 23)), now),
      HomeRecentDateGroup.yesterday,
    );
    expect(
      homeRecentDateGroup(stamp(DateTime(2026, 7, 20)), now),
      HomeRecentDateGroup.earlier,
    );
  });

  test('oculta el prompt que repite el título incluso sin tildes', () {
    final preview = homeRecentPreview(
      title: 'Podrías buscar en el repo de',
      session: _session(
        preview: 'Podrias buscar en el repo de Hermes Agent si hay algo nuevo',
      ),
    );

    expect(preview, isNull);
  });

  test('prioriza y limpia la última respuesta del assistant', () {
    final preview = homeRecentPreview(
      title: 'Noticias de hoy',
      session: _session(preview: 'Noticias de hoy en España'),
      assistantPreview: '**Estas son**\n\nlas noticias principales.',
    );

    expect(preview, 'Estas son las noticias principales.');
  });

  test('mantiene juntos el último usuario y la respuesta de Hermes', () {
    final summary = homeRecentSummary(
      title: 'Hola, me podrías dar las noticias',
      session: _session(preview: 'Hola, me podrías dar las noticias'),
      userPreview: 'Entonces, ¿qué es buzz?',
      assistantPreview: 'Buzz es una sala de trabajo compartida.',
    );

    expect(summary.user, 'Entonces, ¿qué es buzz?');
    expect(summary.assistant, 'Buzz es una sala de trabajo compartida.');
  });

  test('extrae el último assistant de historiales en ambos órdenes', () {
    final chronological = [
      {'role': 'user', 'content': 'pregunta'},
      {'role': 'assistant', 'content': 'respuesta anterior'},
      {'role': 'user', 'content': 'otra'},
      {
        'role': 'assistant',
        'content': [
          {'text': 'respuesta final'},
        ],
      },
    ];

    expect(latestAssistantPreview(chronological), 'respuesta final');
    expect(latestUserPreview(chronological), 'otra');
    expect(
      latestAssistantPreview(chronological.reversed, newestFirst: true),
      'respuesta final',
    );
    expect(
      latestUserPreview(chronological.reversed, newestFirst: true),
      'otra',
    );
  });

  test('descarta JSON de tool calls y conserva el último texto humano', () {
    final session = _session(
      preview: '[{"id":"call_latest","type":"function"}]',
      lastUserPreview: 'Revisa el despliegue de producción',
      lastAssistantPreview: '[{"id":"call_latest","type":"function"}]',
    );

    final summary = homeRecentSummary(title: 'Deploy', session: session);

    expect(summary.user, 'Revisa el despliegue de producción');
    expect(summary.assistant, isNull);
    expect(
      sessionListPreview(session),
      'Revisa el despliegue de producción',
    );
  });

  test('omite filas tool, internas y de razonamiento al buscar texto humano', () {
    final messages = <Map<String, dynamic>>[
      {'role': 'assistant', 'content': 'respuesta visible'},
      {
        'role': 'assistant',
        'content': '',
        'reasoning': 'razonamiento privado',
      },
      {
        'role': 'user',
        'content': '[System: compacting conversation]',
        'display_kind': 'auto_continue',
      },
      {
        'role': 'tool',
        'content': '{"tool_call_id":"call_latest","result":"ok"}',
      },
      {
        'role': 'assistant',
        'content': '[{"id":"call_latest","type":"function"}]',
        'tool_calls': const [
          {'id': 'call_latest'},
        ],
      },
    ];

    expect(latestAssistantPreview(messages), 'respuesta visible');
    expect(latestUserPreview(messages), isNull);
  });

  test('oculta referencias privadas de adjuntos en previews recientes', () {
    final marker = '⟦hatt:v1:${List.filled(48, 'A').join()}⟧';
    final content =
        '[📎 brief-aurora.pdf · 75 KB]\n$marker\nHe adjuntado el brief.';

    final preview = latestUserPreview([
      {'role': 'user', 'content': content},
    ]);

    expect(preview, '[📎 brief-aurora.pdf · 75 KB] He adjuntado el brief.');
    expect(preview, isNot(contains('hatt:v1')));
    expect(
      homeRecentPreview(
        title: 'Proyecto Aurora',
        session: _session(),
        userPreview: content.replaceAll('\n', ' '),
      ),
      '[📎 brief-aurora.pdf · 75 KB] He adjuntado el brief.',
    );
  });

  test(
    'omite terminales internos de interrupción y usa respuesta anterior',
    () {
      final messages = [
        {'role': 'assistant', 'content': 'respuesta útil'},
        {
          'role': 'assistant',
          'content': 'Operation interrupted: waiting for model response (185s)',
        },
      ];

      expect(latestAssistantPreview(messages), 'respuesta útil');
      expect(
        homeRecentPreview(
          title: 'Dame las noticias',
          session: _session(
            preview: 'Operation interrupted: waiting for model response',
          ),
        ),
        isNull,
      );
    },
  );
}
