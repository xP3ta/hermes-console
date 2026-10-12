// ct1215: one labeller names a tool on every surface, in Hermes Desktop's
// words (`assistant.tool.titles`): a phrase while it runs, the verb alone
// when its target follows, a phrase once done. An MCP or connector call is
// «App · action» as the gateway labels it; a tool without a title is its
// registered name in plain words, never an id.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/session_live_status.dart';
import 'package:hermes_android/core/models/tool_label.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/home_widget_publisher.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/l10n/app_localizations_en.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';

final Strings _es = StringsEs();
final Strings _en = StringsEn();

/// Every tool Hermes Desktop has a title for (`TOOL_META`).
const _titled = [
  'browser_click',
  'browser_fill',
  'browser_navigate',
  'browser_snapshot',
  'browser_take_screenshot',
  'browser_type',
  'clarify',
  'cronjob',
  'edit_file',
  'execute_code',
  'image_generate',
  'list_files',
  'memory',
  'patch',
  'read_file',
  'search_files',
  'session_search_recall',
  'setup_choose',
  'start_chat',
  'terminal',
  'todo',
  'vision_analyze',
  'web_extract',
  'web_search',
  'write_file',
];

/// What Hermes ships beyond those (`toolsets.py` and the tool registry),
/// which Desktop draws as cards or leaves to its plain-name fallback: they
/// have Console's own titles.
const _shipped = [
  'delegate_task',
  'process_manage',
  'skill_manage',
  'text_to_speech',
  'send_message',
  'computer_use',
  'manage_connections',
  'manage_catalog',
  'x_search',
  'fact_store',
  'fact_feedback',
  'video_generate',
  'video_analyze',
  'xai_video_edit',
  'xai_video_extend',
  'browser_scroll',
  'browser_back',
  'browser_press',
  'browser_get_images',
  'browser_vision',
  'browser_console',
  'browser_cdp',
  'browser_dialog',
  'browser_exec',
  'browser_vault_list',
  'browser_vault_unlock',
  'browser_vault_fill',
  'browser_vault_save_login',
  'browser_vault_enter_code',
  'kanban_show',
  'kanban_list',
  'kanban_create',
  'kanban_complete',
  'kanban_block',
  'kanban_unblock',
  'kanban_request_review',
  'kanban_request_changes',
  'kanban_heartbeat',
  'kanban_comment',
  'kanban_link',
  'kanban_attach',
  'kanban_attach_url',
  'kanban_attachments',
  'desktop_project',
  'desktop_preview',
  'drive_preview',
  'annotate_preview',
  'read_terminal',
  'close_terminal',
  'read_window_below',
  'focus_pane',
  'apply_layout',
  'react_to_message',
  'gui_tour',
  'show_tip',
  'discord',
  'discord_admin',
  'feishu_doc_read',
  'feishu_drive_list_comments',
  'feishu_drive_list_comment_replies',
  'feishu_drive_reply_comment',
  'feishu_drive_add_comment',
  'yb_query_group_info',
  'yb_query_group_members',
  'yb_send_dm',
  'yb_search_sticker',
  'yb_send_sticker',
  // Registered under a name that shares another tool's title.
  'todo_list',
  'cronjob_manage',
  'process',
  'session_search',
];

class _Store implements HomeWidgetStore {
  final values = <String, Object?>{};

  @override
  Future<Object?> read(String key) async => values[key];

  @override
  Future<void> write(String key, Object? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> requestUpdate() async {}
}

void main() {
  test(
    'the launcher widget names the running tool in the same words',
    () async {
      final publisher = HermesHomeWidgetPublisher(store: _Store());
      final service = ActiveChatService()
        ..bindHomeWidgetPublisher(publisher, activeConnectionId: 'conn-1')
        ..homeWidgetStrings = () => _es;
      addTearDown(service.dispose);
      final chat = service.attach(
        connection: SavedConnection(
          id: 'conn-1',
          label: 'Test',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'k',
        ),
        sessionId: 'sess-1',
        sessionTitle: 'Widget',
        disableForegroundKeepAlive: true,
      );
      await Future<void>.delayed(Duration.zero);

      chat.state = ChatPipelineState.executing;
      chat.trace.add(
        ChatTraceEvent(id: 'terminal', label: 'terminal', status: 'running'),
      );
      service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.toolProgress);
      await Future<void>.delayed(Duration.zero);
      expect(publisher.latest.toolName, 'Ejecutando comando');

      // Hermes' own bridge is not something the user asked for.
      chat.trace
        ..clear()
        ..add(
          ChatTraceEvent(
            id: 'tool_call',
            label: 'tool_call',
            status: 'running',
          ),
        );
      service.debugHomeWidgetChatEvent(chat, ActiveChatEvent.toolProgress);
      await Future<void>.delayed(Duration.zero);
      expect(publisher.latest.toolName, isNull);
    },
  );

  group('a tool with a title', () {
    test('running: the phrase, or the verb when its target follows', () {
      expect(
        toolStepTitle(_es, 'terminal', running: true),
        'Ejecutando comando',
      );
      expect(
        toolStepTitle(_es, 'terminal', running: true, hasDetail: true),
        'Ejecutando',
      );
      expect(toolStepTitle(_en, 'terminal', running: true), 'Running command');
      expect(
        toolStepTitle(_en, 'read_file', running: true, hasDetail: true),
        'Reading',
      );
      expect(
        toolStepTitle(_es, 'memory', running: true),
        'Guardando en la memoria',
      );
    });

    test('done: what it did, or the past verb when its target follows', () {
      expect(
        toolStepTitle(_es, 'terminal', running: false),
        'Comando ejecutado',
      );
      expect(
        toolStepTitle(_es, 'terminal', running: false, hasDetail: true),
        'Ejecutó',
      );
      expect(
        toolStepTitle(_en, 'web_search', running: false, hasDetail: true),
        'Searched',
      );
      // No past verb of its own: the phrase stays, the target follows it.
      expect(
        toolStepTitle(_es, 'edit_file', running: false, hasDetail: true),
        'Archivo editado',
      );
      expect(toolStepTitle(_en, 'memory', running: false), 'Saved to memory');
    });

    test('every Desktop title exists in both languages', () {
      for (final strings in [_es, _en]) {
        for (final tool in _titled) {
          for (final running in [true, false]) {
            final title = toolStepTitle(strings, tool, running: running);
            expect(title, isNotEmpty, reason: '$tool running=$running');
            expect(title, isNot(contains('_')), reason: tool);
          }
          expect(
            toolStepTitle(strings, tool, running: true, hasDetail: true),
            isNotEmpty,
            reason: tool,
          );
        }
      }
    });

    test('the wire id and the renamed task tool resolve to the same title', () {
      expect(
        toolStepTitle(_es, 'mcp__terminal', running: true),
        'Ejecutando comando',
      );
      expect(
        toolStepTitle(_es, 'todo_list', running: true),
        'Actualizando tareas',
      );
      expect(
        toolStepTitle(_en, 'mcp__context_notes', running: false),
        'Saved to memory',
      );
    });
  });

  group('a tool Hermes ships that Desktop does not title', () {
    test('has the three forms in both languages, never its id', () {
      for (final strings in [_es, _en]) {
        for (final tool in _shipped) {
          final forms = [
            toolStepTitle(strings, tool, running: true),
            toolStepTitle(strings, tool, running: true, hasDetail: true),
            toolStepTitle(strings, tool, running: false),
            toolStepTitle(strings, tool, running: false, hasDetail: true),
          ];
          for (final form in forms) {
            expect(form, isNotEmpty, reason: tool);
            expect(form, isNot(contains('_')), reason: '$tool: $form');
          }
          // A phrase of its own, not the fallback, which is the name
          // spelled out with every word capitalised («Read Terminal»; the
          // phrase «Read terminal» is not it).
          final words = tool.split('_');
          final spelled = words
              .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
              .join(' ');
          expect(
            forms[0],
            isNot(strings.ctToolRunning(words.join(' '))),
            reason: tool,
          );
          expect(forms[2], isNot(spelled), reason: tool);
        }
        // Every form is in the table itself, in this language too.
        for (final tool in _shipped.take(_shipped.length - 4)) {
          expect(strings.ctToolPending(tool).trim(), isNotEmpty, reason: tool);
          expect(strings.ctToolAction(tool).trim(), isNotEmpty, reason: tool);
          expect(strings.ctToolDone(tool).trim(), isNotEmpty, reason: tool);
        }
      }
    });

    test('reads in the voice of Desktop\'s own titles', () {
      expect(
        toolStepTitle(_es, 'delegate_task', running: true),
        'Delegando tareas',
      );
      expect(
        toolStepTitle(_es, 'delegate_task', running: true, hasDetail: true),
        'Delegando',
      );
      expect(
        toolStepTitle(_es, 'delegate_task', running: false),
        'Tareas delegadas',
      );
      expect(
        toolStepTitle(_en, 'delegate_task', running: false),
        'Delegated tasks',
      );
      expect(
        toolStepTitle(_es, 'text_to_speech', running: false),
        'Voz generada',
      );
      expect(
        toolStepTitle(_es, 'browser_scroll', running: false),
        'Página desplazada',
      );
      expect(
        toolStepTitle(_en, 'kanban_complete', running: true),
        'Completing task',
      );
      expect(
        toolStepTitle(_es, 'x_search', running: false, hasDetail: true),
        'Buscó',
      );
    });

    test('a renamed tool keeps the title of the one it was', () {
      expect(
        toolStepTitle(_es, 'session_search', running: true),
        toolStepTitle(_es, 'session_search_recall', running: true),
      );
      expect(
        toolStepTitle(_es, 'session_search', running: true),
        'Buscando en el historial de sesiones',
      );
      expect(
        toolStepTitle(_en, 'cronjob_manage', running: true),
        'Scheduling cron job',
      );
      expect(
        toolStepTitle(_es, 'process', running: false),
        toolStepTitle(_es, 'process_manage', running: false),
      );
      expect(
        toolStepTitle(_es, 'process', running: false),
        'Proceso en segundo plano gestionado',
      );
    });

    test('searches of every kind count as searches in the summary', () {
      expect(
        toolRunSummary(_es, ['web_search', 'session_search', 'x_search']),
        ['3 búsquedas'],
      );
    });
  });

  group('a tool nobody titles', () {
    test('is its registered name in plain words', () {
      expect(
        toolStepTitle(_en, 'some_new_tool', running: false),
        'Some New Tool',
      );
      expect(
        toolStepTitle(_es, 'some_new_tool', running: true),
        'Ejecutando some new tool',
      );
      expect(toolStepTitle(_en, 'kanban', running: true), 'Running kanban');
    });

    test('keeps its family as a prefix', () {
      expect(
        toolStepTitle(_es, 'browser_zoom', running: false),
        'Navegador Zoom',
      );
      expect(
        toolStepTitle(_en, 'web_crawl', running: true),
        'Running web crawl',
      );
    });
  });

  group('MCP and connector calls', () {
    test('read «App · action», as the gateway labels them', () {
      expect(
        toolAppActionLabel('mcp__linear__list_issues'),
        'Linear · list issues',
      );
      expect(
        toolAppActionLabel('mcp__vault__list_items'),
        'Vault · list items',
      );
      expect(
        toolAppActionLabel('mcp__my-server__get_thing'),
        'My Server · get thing',
      );
      expect(
        toolAppActionLabel('connectors__github__GITHUB_CREATE_ISSUE'),
        'GitHub · create issue',
      );
      expect(
        toolAppActionLabel('connectors__googlecalendar__list_events'),
        'Google Calendar · list events',
      );
      expect(toolAppActionLabel('terminal'), isNull);
      expect(toolAppActionLabel('mcp__terminal'), isNull);
    });

    test('are the same running and done', () {
      for (final running in [true, false]) {
        expect(
          toolStepTitle(_es, 'mcp__linear__list_issues', running: running),
          'Linear · list issues',
        );
      }
    });

    test('the label the gateway sent wins', () {
      expect(
        toolStepTitle(
          _es,
          'mcp__linear__list_issues',
          running: true,
          gatewayTitle: 'Linear · issues',
        ),
        'Linear · issues',
      );
    });

    test('only MCP and connector labels of an event are titles', () {
      expect(
        gatewayToolTitles([
          {'kind': 'connector', 'text': 'GitHub · create issue'},
          {'kind': 'tool', 'text': 'Running'},
          {'kind': 'mcp', 'text': ' Linear · list issues '},
          'junk',
        ]),
        ['GitHub · create issue', null, 'Linear · list issues', null],
      );
      expect(gatewayToolTitles(null), isEmpty);
    });
  });

  test('a skill load is worded as Desktop words it', () {
    expect(skillStepTitle(_es, 'skill_view', running: true), 'Cargando skill');
    expect(
      skillStepTitle(_es, 'skill_view', running: false, detail: 'github-pr'),
      'Skill cargada',
    );
    expect(
      skillStepTitle(
        _es,
        'skill_view',
        running: true,
        detail: 'github-pr → api.md',
      ),
      'Leyendo recurso de la skill',
    );
    expect(skillStepTitle(_en, 'skills_list', running: false), 'Listed skills');
  });

  test('a step is named by its kind', () {
    ActivityStep step(
      ActivityStepKind kind,
      String label, {
      ActivityStepStatus status = ActivityStepStatus.running,
      String? detail,
      String? title,
    }) => ActivityStep(
      id: 'x',
      kind: kind,
      label: label,
      status: status,
      detail: detail,
      title: title,
    );
    expect(
      activityStepTitle(
        _es,
        step(ActivityStepKind.tool, 'terminal', detail: 'echo'),
      ),
      'Ejecutando',
    );
    expect(
      activityStepTitle(
        _es,
        step(
          ActivityStepKind.tool,
          'read_file',
          status: ActivityStepStatus.done,
          detail: 'notas.md',
        ),
      ),
      'Leyó',
    );
    expect(
      activityStepTitle(
        _es,
        step(ActivityStepKind.skill, 'github-pr-workflow'),
      ),
      'github-pr-workflow',
      reason: 'a skill goes by its own name',
    );
    expect(
      activityStepTitle(
        _es,
        step(ActivityStepKind.tool, 'skill_view', detail: 'github-pr'),
      ),
      'Cargando skill',
    );
    expect(
      activityStepTitle(
        _es,
        step(
          ActivityStepKind.tool,
          'connectors__github__create_issue',
          title: 'GitHub · create issue',
        ),
      ),
      'GitHub · create issue',
    );
  });

  test('the folded summary counts what was done, in Desktop\'s order', () {
    expect(
      toolRunSummary(_es, [
        'terminal',
        'read_file',
        'terminal',
        'web_search',
        'execute_code',
        'edit_file',
        'mcp__linear__list_issues',
      ]),
      [
        '1 archivo editado',
        '1 archivo explorado',
        '1 búsqueda',
        '3 comandos',
        '1 herramienta',
      ],
    );
    expect(toolRunSummary(_en, ['terminal', 'terminal']), ['2 commands']);
    expect(
      toolRunSummary(_en, ['browser_navigate', 'browser_click', 'web_extract']),
      ['1 page read', '1 page opened', '1 browser action'],
    );
    expect(toolRunSummary(_es, const []), isEmpty);
  });

  test('the list row and the Home card word the running tool the same', () {
    const running = SessionLiveStatus(
      phase: SessionLivePhase.runningTool,
      toolLabel: 'terminal',
      toolDetail: 'pytest',
    );
    expect(sessionLiveStatusLabel(_es, running), 'Ejecutando · pytest');
    expect(sessionLiveStatusLabel(_en, running), 'Running · pytest');
    expect(
      sessionLiveStatusLabel(
        _es,
        const SessionLiveStatus(
          phase: SessionLivePhase.runningTool,
          toolLabel: 'memory',
        ),
      ),
      'Guardando en la memoria',
    );
    expect(
      sessionLiveStatusLabel(
        _es,
        const SessionLiveStatus(
          phase: SessionLivePhase.runningTool,
          toolLabel: 'github-pr-workflow',
          toolIsSkill: true,
        ),
      ),
      'github-pr-workflow',
    );
  });
}
