import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/run_registry.dart';

void main() {
  test('profileOwner conserva el owner y hace default explícito', () {
    expect(
      Session.profileOwner(' profile-a ', fallback: 'profile-b'),
      'profile-a',
    );
    expect(Session.profileOwner(null, fallback: ' profile-b '), 'profile-b');
    expect(Session.profileOwner('', fallback: ''), 'default');
  });

  group('Session.fromJson (contrato _session_response del gateway)', () {
    test('parsea las métricas reales del servidor', () {
      final s = Session.fromJson({
        'id': 'abc',
        'title': 'prueba',
        'model': 'gpt-5.5',
        'source': 'telegram',
        'message_count': 4,
        'tool_call_count': 7,
        'input_tokens': 41167,
        'output_tokens': 9092,
        'cache_read_tokens': 1133824,
        'cache_write_tokens': 5000,
        'reasoning_tokens': 12,
        'api_call_count': 40,
        'estimated_cost_usd': 0.0,
        'actual_cost_usd': null,
        'parent_session_id': 'origen',
        'end_reason': 'branched',
        'started_at': 1781186907.9,
        'ended_at': 1781186920.0,
        'last_active': 1781186926.8,
        'has_system_prompt': true,
      });
      expect(s.toolCallCount, 7);
      expect(s.totalTokens, 41167 + 9092);
      expect(s.cacheReadTokens, 1133824);
      expect(s.cacheWriteTokens, 5000);
      expect(s.promptTokens, 41167 + 1133824 + 5000);
      expect(
        s.cacheReadPercent,
        closeTo(100 * 1133824 / (41167 + 1133824 + 5000), 0.0001),
      );
      expect(s.apiCallCount, 40);
      expect(s.parentSessionId, 'origen');
      expect(s.endReason, 'branched');
      expect(s.hasSystemPrompt, isTrue);
      // last_active (campo real del servidor) alimenta updatedAt.
      expect(s.updatedAt, closeTo(1781186926.8, 0.001));
      expect(s.sessionDuration, isNotNull);
      expect(s.sessionDuration!.inSeconds, greaterThan(10));
    });

    test('acepta updated_at como compatibilidad y tolera campos ausentes', () {
      final s = Session.fromJson({
        'id': 'x',
        'started_at': 100.0,
        'updated_at': 200.0,
      });
      expect(s.updatedAt, 200.0);
      expect(s.toolCallCount, 0);
      expect(s.estimatedCostUsd, isNull);
      expect(s.lastActivityAt, 200.0);
    });

    test('pinned conserva la ausencia legacy y parsea booleanos remotos', () {
      final legacy = Session.fromJson({'id': 'legacy'});
      final pinned = Session.fromJson({'id': 'pinned', 'pinned': true});
      final unpinned = Session.fromJson({'id': 'unpinned', 'pinned': false});
      final malformed = Session.fromJson({'id': 'malformed', 'pinned': 1});

      expect(legacy.pinned, isNull);
      expect(pinned.pinned, isTrue);
      expect(unpinned.pinned, isFalse);
      expect(malformed.pinned, isNull);
    });

    test('sessionDuration es null sin señal suficiente', () {
      final s = Session.fromJson({'id': 'x', 'started_at': 0});
      expect(s.sessionDuration, isNull);
    });

    test(
      'reconoce el borrador móvil real sin confundir sesiones persistidas',
      () {
        final provisional = Session.fromJson({
          'id': 'mob-123-uuid',
          'source': 'mobile',
          'message_count': 0,
          'preview': '',
        });
        final persisted = Session.fromJson({
          'id': 'stored-session',
          'source': 'mobile',
          'message_count': 0,
          'preview': '',
        });
        final legacyDraft = Session.fromJson({
          'id': 'legacy-local',
          'source': 'mobile-draft',
        });
        final roomDraft = Session.fromJson({
          'id': 'mob-room-uuid',
          'source': 'mobile-room',
          'message_count': 0,
          'preview': '',
        });
        final botDraft = Session.fromJson({
          'id': 'mob-bot-uuid',
          'source': 'mobile-bot',
          'message_count': 0,
          'preview': '',
        });

        expect(provisional.isUnpersistedMobileDraft, isTrue);
        expect(roomDraft.isUnpersistedMobileDraft, isTrue);
        expect(botDraft.isUnpersistedMobileDraft, isTrue);
        expect(legacyDraft.isUnpersistedMobileDraft, isTrue);
        expect(persisted.isUnpersistedMobileDraft, isFalse);
      },
    );
  });

  test('Cache % es opcional, canónico y nunca divide entre cero', () {
    final cached = Session.fromJson({
      'id': 'cached',
      'input_tokens': 100,
      'cache_read_tokens': 50,
      'cache_write_tokens': 50,
    });
    final uncached = Session.fromJson({
      'id': 'uncached',
      'cache_read_tokens': -1,
      'cache_write_tokens': -1,
    });

    expect(cached.promptTokens, 200);
    expect(cached.cacheReadPercent, 25);
    expect(uncached.cacheReadTokens, isNull);
    expect(uncached.cacheWriteTokens, isNull);
    expect(uncached.cacheReadPercent, isNull);

    final explicitZero = Session.fromJson({
      'id': 'explicit-zero',
      'cache_read_tokens': 0,
      'cache_write_tokens': 0,
    });
    expect(explicitZero.cacheReadTokens, 0);
    expect(explicitZero.cacheWriteTokens, 0);
  });

  group('RunRecord', () {
    test('roundtrip JSON y estados terminales', () {
      final r = RunRecord(
        runId: 'run_1',
        prompt: 'haz algo',
        createdAt: 1000,
        lastStatus: 'waiting_for_approval',
        sessionId: 'sess',
      );
      expect(r.isTerminal, isFalse);
      final back = RunRecord.fromJson(r.toJson());
      expect(back.runId, 'run_1');
      expect(back.sessionId, 'sess');
      expect(back.lastStatus, 'waiting_for_approval');

      expect(r.copyWith(lastStatus: 'completed').isTerminal, isTrue);
      expect(r.copyWith(lastStatus: 'expired').isTerminal, isTrue);
      expect(r.copyWith(lastStatus: 'running').isTerminal, isFalse);
    });
  });

  group('Session — detección de jobs (009)', () {
    Session make(String id, String preview, {String source = 'cron'}) =>
        Session.fromJson({
          'id': id,
          'title': 'Radar semanal',
          'model': 'm',
          'source': source,
          'preview': preview,
        });

    test('isJob detecta cron_* y source:cron; no las normales', () {
      expect(make('cron_bd6a30debe74_20260625', 'x').isJob, isTrue);
      // source:"cron" también marca job aunque el id no empiece por cron_
      // (skills invocadas con id de timestamp).
      expect(make('20260626_180148_1f1816', 'x').isJob, isTrue);
      expect(make('sess-normal', 'x', source: 'chat').isJob, isFalse);
    });

    test('cronJobId extrae el vínculo sin confundir el timestamp', () {
      expect(
        make('cron_job_with_underscores_20260715_214800', 'x').cronJobId,
        'job_with_underscores',
      );
      expect(make('cron_bd6a30debe74_20260625', 'x').cronJobId, 'bd6a30debe74');
      expect(make('legacy-cron-session', 'x').cronJobId, isNull);
    });

    test('invokedSkill extrae el nombre de la skill del preview', () {
      final s = make(
        '20260626_1',
        '[IMPORTANT: The user has invoked the '
            '"xpeta-lab-editorial" skill, indicating…]',
      );
      expect(s.invokedSkill, 'xpeta-lab-editorial');
      expect(make('sess-x', 'hola', source: 'chat').invokedSkill, isNull);
    });

    test('displayTitle de una skill (título placeholder) usa el nombre', () {
      final s = Session.fromJson({
        'id': '20260626_180148_1f1816',
        'title': null, // placeholder → debe caer al nombre de la skill
        'model': 'm',
        'source': 'cron',
        'preview':
            '[IMPORTANT: The user has invoked the "reddit-research" '
            'skill, indicating…]',
      });
      expect(s.displayTitle, 'reddit-research');
    });

    test('displayTitle decodifica percent-encoding accidental del título', () {
      final s = Session.fromJson({
        'id': '20260627_x',
        'title': 'Escribe%20el%20comando%20rm',
        'model': 'm',
        'source': 'chat',
      });
      expect(s.displayTitle, 'Escribe el comando rm');
    });

    test('displayTitle no toca títulos con % legítimo o no decodificables', () {
      final s = Session.fromJson({
        'id': '20260627_y',
        'title': 'Uso 50% de CPU',
        'model': 'm',
        'source': 'chat',
      });
      expect(s.displayTitle, 'Uso 50% de CPU');
    });

    test('displayTitle no expone el título sintético de tareas', () {
      final s = Session.fromJson({
        'id': '20260828_todo',
        'title':
            '[Your active task list was preserved across context compression]',
        'preview':
            '[Your active task list was preserved across context compression]\n'
            '- [>] verify. Ejecutar pruebas (in_progress)',
        'source': 'mobile',
      });
      expect(Session.stripTodoContinuation(s.preview), '');
      expect(s.cleanPreview, '');
      expect(s.displayTitle, 'Conversación');
    });

    test('displayTitle conserva una consulta que empieza citando la cabecera', () {
      const title =
          '[Your active task list was preserved across context compression] ¿qué significa?';
      final s = Session.fromJson({
        'id': '20260828_question',
        'title': title,
        'preview': 'Explícame esa cabecera',
        'source': 'mobile',
      });
      expect(s.displayTitle, title);
    });

    test('displayTitle oculta el snapshot con preview truncado por SessionDB', () {
      final s = Session.fromJson({
        'id': '20260828_todo_truncated',
        'title':
            '[Your active task list was preserved across context compression]',
        'preview':
            '[Your active task list was preserved across context compress...',
        'source': 'mobile',
      });
      expect(s.displayTitle, 'Conversación');
    });

    test('displayTitle de job sin contenido legible → "Tarea programada"', () {
      final s = Session.fromJson({
        'id': 'cron_abc_1',
        'title': null,
        'model': 'm',
        'source': 'cron',
        'preview': '[IMPORTANT: You are running as a scheduled cron job.]',
      });
      expect(s.displayTitle, 'Tarea programada');
    });

    test('worker del Kanban → "Tarea del Kanban" y sin preview crudo', () {
      final s = Session.fromJson({
        'id': '20260627_1',
        'title': 'work kanban task t_aac00edc',
        'model': 'm',
        'source': 'chat',
        'preview': 'work kanban task t_aac00edc',
      });
      expect(s.isKanbanJob, isTrue);
      expect(s.displayTitle, 'Tarea del Kanban');
      expect(s.cleanPreview, '');
      // Un chat normal no se confunde con uno del Kanban.
      expect(
        make('sess-x', 'work in progress', source: 'chat').isKanbanJob,
        isFalse,
      );
    });

    test('preview que es SOLO preámbulo (truncado) → cleanPreview vacío', () {
      // Caso real: el servidor trunca el preview al bloque [IMPORTANT:…].
      const trunc = '[IMPORTANT: You are running as a scheduled cron job.]';
      expect(Session.stripCronPreamble(trunc), '');
    });

    test('snapshot interno de tareas no aparece en el preview', () {
      const raw =
          '[Your active task list was preserved across context compression]\n'
          '- [>] verify. Ejecutar pruebas (in_progress)\n\n'
          '[Skills pruned during compression — reload before acting on these tasks]';
      expect(Session.stripCronPreamble(raw), '');
    });

    test('preview truncado del backend no expone el snapshot interno', () {
      const raw =
          '[Your active task list was preserved across context compress...';
      expect(Session.stripCronPreamble(raw), '');
    });

    test('conserva texto real anterior al snapshot interno', () {
      const raw =
          'Pregunta visible\n\n'
          '[Your active task list was preserved across context compression]\n'
          '- [ ] deploy. Activar cambio (pending)';
      expect(Session.stripTodoContinuation(raw), 'Pregunta visible');
    });

    test('no oculta una conversación normal que cita la cabecera', () {
      const raw =
          '¿Por qué sale [Your active task list was preserved across context compression] todo el rato?';
      expect(Session.stripTodoContinuation(raw), raw);
    });

    test('acepta frontera CRLF antes del snapshot sintético', () {
      const raw =
          'Pregunta visible\r\n\r\n'
          '[Your active task list was preserved across context compression]\r\n'
          '- [>] verify. Ejecutar pruebas (in_progress)';
      expect(Session.stripTodoContinuation(raw), 'Pregunta visible');
    });

    test('no oculta una cita seguida de una etiqueta que no es un estado todo', () {
      const raw =
          'Texto real\n\n'
          '[Your active task list was preserved across context compression]\n'
          '- [question] ¿qué significa?';
      expect(Session.stripTodoContinuation(raw), raw);
    });

    test('resumen de compactación de contexto se quita entero', () {
      const raw =
          '[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted '
          '… ## Historical Task Snapshot … \n'
          '--- END OF CONTEXT SUMMARY — respond to the message below ---';
      expect(Session.stripCronPreamble(raw), '');
    });

    test('compactación con mensaje real detrás conserva el mensaje', () {
      const raw =
          '[CONTEXT COMPACTION — REFERENCE ONLY] bla bla\n'
          '--- END OF CONTEXT SUMMARY ---\n\nDame las noticias de hoy';
      expect(Session.stripCronPreamble(raw), 'Dame las noticias de hoy');
    });

    test('stripCronPreamble quita el preámbulo (scheduled cron job)', () {
      const raw =
          '[IMPORTANT: You are running as a scheduled cron job. DELIVERY: … '
          '[SILENT] …]\n\nDame las 10 noticias.';
      expect(Session.stripCronPreamble(raw), 'Dame las 10 noticias.');
    });

    test(
      'stripCronPreamble quita la variante "invoked" y respeta texto normal',
      () {
        const raw =
            '[IMPORTANT: The user has invoked the skill …]\n\nInforme aquí.';
        expect(Session.stripCronPreamble(raw), 'Informe aquí.');
        expect(Session.stripCronPreamble('Hola mundo'), 'Hola mundo');
      },
    );

    test('cleanPreview limpia el preview del job', () {
      final s = make(
        'cron_x_1',
        '[IMPORTANT: scheduled cron job [SILENT]]\n\nResumen del día.',
      );
      expect(s.cleanPreview, 'Resumen del día.');
    });

    test('cleanPreview no muestra Markdown en la búsqueda de chats', () {
      final s = make(
        'sess-play-store',
        'Para Play Store, **te lo montaría así**.\n\n'
            '## 1) Modelo recomendado (simple y limpio)',
        source: 'chat',
      );

      expect(
        s.cleanPreview,
        'Para Play Store, te lo montaría así. '
        '1) Modelo recomendado (simple y limpio)',
      );
    });
  });
}
