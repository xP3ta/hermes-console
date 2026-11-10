// Shared fixtures of the launcher widget picture tests: the fonts the app
// ships, the four reference palettes, the sizes real launchers report, the
// scenes of every state, and the data that tries to break a layout.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show FontLoader;
import 'package:hermes_android/core/home/launcher/launcher_widget_geometry.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_palette.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_scene.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_words.dart';
import 'package:hermes_android/core/models/home_widget_snapshot.dart';
import 'package:hermes_android/core/models/launcher_widget_chats.dart';
import 'package:hermes_android/core/models/launcher_widget_cron.dart';
import 'package:hermes_android/core/models/launcher_widget_tasks.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';

/// A fixed "now": Tuesday 2026-11-03 10:08 local time.
final int lwNow = DateTime(2026, 11, 3, 10, 8).millisecondsSinceEpoch;

int lwMinutesAgo(int minutes) => lwNow - minutes * 60000;
int lwIn(int minutes) => lwNow + minutes * 60000;

/// Loads the app's fonts into the test renderer, once.
Future<void> lwLoadFonts() async {
  for (final (family, file) in const [
    ('Inter', 'assets/fonts/Inter.ttf'),
    ('JetBrainsMono', 'assets/fonts/JetBrainsMono.ttf'),
  ]) {
    final bytes = await File(file).readAsBytes();
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
  // A device falls back to its system fonts for scripts and emoji the app's
  // fonts lack; the test renderer has none. When LW_EXTRA_FONTS names a CJK
  // and an emoji font ("cjk=/path/a.ttc:emoji=/path/b.ttf"), they are
  // registered under the typesetter's fallback names, so Japanese, Chinese
  // and emoji are measured with real glyphs instead of placeholder boxes.
  final extra = Platform.environment['LW_EXTRA_FONTS'];
  if (extra != null && extra.isNotEmpty) {
    for (final part in extra.split(':')) {
      final (role, path) = switch (part.split('=')) {
        [final r, final p] => (r, p),
        _ => ('', ''),
      };
      final family = switch (role) {
        'cjk' => 'sans-serif',
        'emoji' => 'Roboto',
        _ => null,
      };
      if (family == null || !File(path).existsSync()) continue;
      try {
        final bytes = await File(path).readAsBytes();
        await (FontLoader(
          family,
        )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
        lwExtraFonts.add(role);
      } catch (_) {
        // A font the engine cannot read: those scripts stay unmeasured.
      }
    }
  }
  for (final tag in lwLocales) {
    await initializeDateFormatting(tag);
  }
}

const lwLocales = ['es', 'en', 'de', 'ja', 'zh'];

/// The fallback fonts loaded from LW_EXTRA_FONTS (`cjk`, `emoji`).
final lwExtraFonts = <String>{};

/// The reference palettes: Console and Midnight, dark and light.
class LwThemeCase {
  const LwThemeCase(this.id, this.presetId, this.fontFamily);
  final String id;
  final String presetId;
  final String fontFamily;

  LauncherWidgetPalette get palette => LauncherWidgetPalette.of(
    AppTheme.presetById(presetId).colors,
    fontFamily: fontFamily,
    id: id,
  );
}

const lwThemes = [
  LwThemeCase('console-dark', 'console', 'Inter'),
  LwThemeCase('console-light', 'console-light', 'Inter'),
  LwThemeCase('midnight-dark', 'midnight', 'JetBrainsMono'),
  LwThemeCase('midnight-light', 'midnight-light', 'JetBrainsMono'),
];

/// Sizes in dp as three launchers (tight, usual, roomy) report each span.
const lwSizes = <LwSpan, List<ui.Size>>{
  LwSpan.twoByOne: [ui.Size(140, 56), ui.Size(160, 72), ui.Size(200, 96)],
  LwSpan.twoByTwo: [ui.Size(140, 140), ui.Size(160, 170), ui.Size(210, 220)],
  LwSpan.fourByOne: [ui.Size(290, 56), ui.Size(320, 72), ui.Size(420, 100)],
  LwSpan.fourByTwo: [ui.Size(290, 140), ui.Size(320, 170), ui.Size(420, 230)],
  LwSpan.fourByFour: [ui.Size(290, 310), ui.Size(320, 360), ui.Size(420, 470)],
};

/// The spans each subject is offered in (the others still draw something).
const lwSpansOf = <LwSubject, List<LwSpan>>{
  LwSubject.ahora: [
    LwSpan.twoByTwo,
    LwSpan.fourByTwo,
    LwSpan.fourByOne,
    LwSpan.twoByOne,
  ],
  LwSubject.chats: [
    LwSpan.fourByTwo,
    LwSpan.fourByFour,
    LwSpan.twoByTwo,
    LwSpan.twoByOne,
  ],
  LwSubject.cron: [
    LwSpan.twoByTwo,
    LwSpan.fourByTwo,
    LwSpan.fourByOne,
    LwSpan.twoByOne,
  ],
  LwSubject.tasks: [LwSpan.fourByTwo, LwSpan.twoByTwo, LwSpan.fourByOne],
  LwSubject.newChat: [LwSpan.twoByOne, LwSpan.twoByTwo, LwSpan.fourByOne],
};

LwWords lwWords(String locale, {bool use24h = true}) {
  final loc = ui.Locale(locale);
  return LwWords(lookupStrings(loc), locale: loc, use24h: use24h, nowMs: lwNow);
}

/// Data that tries to break a layout.
class LwData {
  const LwData({
    required this.id,
    required this.agent,
    required this.chatTitle,
    required this.what,
    required this.jobName,
    required this.taskTitle,
    required this.instance,
    required this.count,
    this.use24h = true,
  });

  final String id;
  final String agent;
  final String chatTitle;
  final String what;
  final String jobName;
  final String taskTitle;
  final String instance;
  final int count;
  final bool use24h;

  static const plain = LwData(
    id: 'plain',
    agent: 'Nova',
    chatTitle: 'Viaje a Lisboa',
    what: 'Ejecutar un comando en tu equipo',
    jobName: 'Resumen diario',
    taskTitle: 'Preparar la demo',
    instance: 'Casa',
    count: 7,
  );

  static const hostile = LwData(
    id: 'hostile',
    agent: 'Agente de nombre extraordinariamente largo',
    chatTitle: '🚀 Plan de lanzamiento 🎉 con todos los detalles',
    what: 'rm -rf ~/proyectos/antiguos && git push --force origin main',
    jobName: 'Copia de seguridad semanal de todas las carpetas',
    taskTitle: 'Revisar el presupuesto anual de marketing',
    instance: 'Servidor de la oficina de Barcelona',
    count: 999,
    use24h: false,
  );

  static const rtl = LwData(
    id: 'rtl',
    agent: 'نوفا',
    chatTitle: 'رحلة إلى لشبونة مع الأصدقاء',
    what: 'تشغيل أمر على جهازك',
    jobName: 'ملخص يومي',
    taskTitle: 'تحضير العرض',
    instance: 'المنزل',
    count: 3,
  );

  static const bare = LwData(
    id: 'bare',
    agent: 'H',
    chatTitle: '·',
    what: '',
    jobName: 'x',
    taskTitle: 'y',
    instance: '',
    count: 0,
  );

  static const all = [plain, hostile, rtl, bare];
}

/// Every state a subject can be drawn in.
const lwMoodsOf = <LwSubject, List<String>>{
  LwSubject.ahora: [
    'setup',
    'offline',
    'need',
    'need-open',
    'ask',
    'work',
    'calm',
  ],
  LwSubject.chats: ['setup', 'empty', 'rows', 'rows-live', 'offline'],
  LwSubject.cron: ['setup', 'empty', 'next', 'failed', 'paused', 'offline'],
  LwSubject.tasks: ['setup', 'empty', 'counts', 'offline'],
  LwSubject.newChat: ['ready', 'setup'],
};

HermesHomeWidgetSnapshot _chatSnapshot(
  LwData d, {
  HomeWidgetConnectionState connection = HomeWidgetConnectionState.connected,
  HomeWidgetAgentState agent = HomeWidgetAgentState.idle,
  List<HomeWidgetChatActivity> active = const [],
  int? updatedAtMs,
}) => HermesHomeWidgetSnapshot(
  configured: true,
  instanceId: 'home',
  instanceLabel: d.instance.isEmpty ? null : d.instance,
  connectionState: connection,
  agentState: agent,
  sessionId: 's1',
  sessionTitle: d.chatTitle,
  lastActivityAtMs: lwMinutesAgo(27),
  updatedAtMs: updatedAtMs ?? lwMinutesAgo(1),
  active: active,
);

List<LauncherWidgetChat> _chats(LwData d) => [
  LauncherWidgetChat(
    id: 'c1',
    title: d.chatTitle,
    line: 'Te paso tres hoteles cerca del centro',
    atMs: lwMinutesAgo(6),
    profile: 'nova',
  ),
  LauncherWidgetChat(
    id: 'c2',
    title: 'Informe semanal',
    line: 'Voy por el apartado de ventas',
    atMs: lwMinutesAgo(27),
    profile: 'atlas',
  ),
  LauncherWidgetChat(
    id: 'c3',
    title: 'Recetas de la semana',
    line: 'Lista de la compra lista',
    atMs: lwMinutesAgo(60 * 25),
    profile: 'lia',
  ),
  LauncherWidgetChat(
    id: 'c4',
    title: 'Fotos del jardín',
    line: 'He ordenado las 48 fotos por fecha',
    atMs: lwMinutesAgo(60 * 30),
    profile: 'max',
  ),
  LauncherWidgetChat(
    id: 'c5',
    title: 'Presupuesto de casa',
    line: null,
    atMs: lwMinutesAgo(60 * 24 * 3),
    profile: null,
  ),
  LauncherWidgetChat(
    id: 'c6',
    title: d.taskTitle,
    line: d.what.isEmpty ? null : d.what,
    atMs: lwMinutesAgo(60 * 24 * 9),
  ),
];

/// The scene of [subject] in [mood] with [d].
Object lwScene(LwSubject subject, String mood, LwData d) {
  switch (subject) {
    case LwSubject.ahora:
      switch (mood) {
        case 'setup':
          return LwAhoraScene.from(
            HermesHomeWidgetSnapshot.empty,
            nowMs: lwNow,
            agentName: d.agent,
          );
        case 'offline':
          return LwAhoraScene.from(
            _chatSnapshot(
              d,
              connection: HomeWidgetConnectionState.disconnected,
              updatedAtMs: lwMinutesAgo(9),
            ),
            nowMs: lwNow,
            agentName: d.agent,
            recentChats: _chats(d),
          );
        case 'need':
        case 'need-open':
        case 'ask':
          final need = HomeWidgetNeed(
            requestId: 'r1',
            question: mood == 'ask',
            text: d.what.isEmpty ? null : d.what,
            actionPayload: mood == 'need' ? 'payload-approve-deny' : null,
          );
          return LwAhoraScene.from(
            _chatSnapshot(
              d,
              agent: HomeWidgetAgentState.waitingApproval,
              active: [
                HomeWidgetChatActivity(
                  sessionId: 's1',
                  state: HomeWidgetAgentState.waitingApproval,
                  title: d.chatTitle,
                  profile: d.id == 'bare' ? null : d.agent,
                  startedAtMs: lwMinutesAgo(2),
                  need: need,
                ),
                HomeWidgetChatActivity(
                  sessionId: 's2',
                  state: HomeWidgetAgentState.toolExecution,
                  title: 'Informe semanal',
                  profile: 'atlas',
                  phase: 'Ejecutando comando',
                  startedAtMs: lwMinutesAgo(4),
                ),
              ],
            ),
            nowMs: lwNow,
            agentName: d.agent,
            recentChats: _chats(d),
          );
        case 'work':
          return LwAhoraScene.from(
            _chatSnapshot(
              d,
              agent: HomeWidgetAgentState.toolExecution,
              active: [
                HomeWidgetChatActivity(
                  sessionId: 's2',
                  state: HomeWidgetAgentState.toolExecution,
                  title: d.chatTitle,
                  profile: d.id == 'bare' ? null : d.agent,
                  phase: 'Ejecutando comando',
                  startedAtMs: lwMinutesAgo(4),
                ),
              ],
            ),
            nowMs: lwNow,
            agentName: d.agent,
            recentChats: _chats(d),
          );
        default:
          return LwAhoraScene.from(
            _chatSnapshot(d),
            nowMs: lwNow,
            agentName: d.agent,
            recentChats: _chats(d),
          );
      }
    case LwSubject.chats:
      final chat = _chatSnapshot(
        d,
        active: mood == 'rows-live'
            ? [
                HomeWidgetChatActivity(
                  sessionId: 'c2',
                  state: HomeWidgetAgentState.waitingApproval,
                  title: 'Informe semanal',
                  profile: 'atlas',
                  startedAtMs: lwMinutesAgo(2),
                  need: const HomeWidgetNeed(requestId: 'r2', text: 'git push'),
                ),
                HomeWidgetChatActivity(
                  sessionId: 'c1',
                  state: HomeWidgetAgentState.streaming,
                  title: d.chatTitle,
                  profile: 'nova',
                  startedAtMs: lwMinutesAgo(1),
                ),
              ]
            : const [],
      );
      switch (mood) {
        case 'setup':
          return LwChatsScene.from(null, chat, nowMs: lwNow);
        case 'empty':
          return LwChatsScene.from(
            LauncherWidgetChatsSnapshot(
              connectionId: 'home',
              updatedAtMs: lwMinutesAgo(1),
              chats: const [],
            ),
            chat,
            nowMs: lwNow,
          );
        case 'offline':
          return LwChatsScene.from(
            LauncherWidgetChatsSnapshot(
              connectionId: 'home',
              updatedAtMs: lwMinutesAgo(40),
              chats: _chats(d),
            ),
            chat,
            nowMs: lwNow,
          );
        default:
          return LwChatsScene.from(
            LauncherWidgetChatsSnapshot(
              connectionId: 'home',
              updatedAtMs: lwMinutesAgo(1),
              chats: _chats(d),
            ),
            chat,
            nowMs: lwNow,
          );
      }
    case LwSubject.cron:
      final jobs = [
        LauncherWidgetCronJob(
          id: 'j1',
          name: d.jobName,
          profile: 'default',
          nextRunAtMs: lwIn(60 * 8 + 22),
          lastRunAtMs: lwMinutesAgo(60 * 16),
          last: LauncherWidgetCronResult.ok,
          openPayload: 'open-j1',
        ),
        LauncherWidgetCronJob(
          id: 'j2',
          name: 'Copia de seguridad',
          profile: 'default',
          nextRunAtMs: lwIn(60 * 10 + 52),
          openPayload: 'open-j2',
        ),
        LauncherWidgetCronJob(
          id: 'j3',
          name: 'Revisar el correo',
          profile: 'default',
          nextRunAtMs: lwIn(60 * 22),
          openPayload: 'open-j3',
        ),
        LauncherWidgetCronJob(
          id: 'j4',
          name: 'Informe semanal',
          profile: 'default',
          nextRunAtMs: lwIn(60 * 24 * 6 - 68),
          openPayload: 'open-j4',
        ),
      ];
      switch (mood) {
        case 'setup':
          return LwCronScene.from(null, nowMs: lwNow);
        case 'empty':
          return LwCronScene.from(
            LauncherWidgetCronSnapshot(
              connectionId: 'home',
              updatedAtMs: lwMinutesAgo(1),
              jobs: const [],
            ),
            nowMs: lwNow,
          );
        case 'failed':
          return LwCronScene.from(
            LauncherWidgetCronSnapshot(
              connectionId: 'home',
              updatedAtMs: lwMinutesAgo(1),
              jobs: [
                LauncherWidgetCronJob(
                  id: 'j0',
                  name: d.jobName,
                  profile: 'default',
                  lastRunAtMs: lwMinutesAgo(60 * 3),
                  last: LauncherWidgetCronResult.failed,
                  openPayload: 'open-j0',
                ),
                ...jobs.skip(1),
              ],
            ),
            nowMs: lwNow,
          );
        case 'paused':
          return LwCronScene.from(
            LauncherWidgetCronSnapshot(
              connectionId: 'home',
              updatedAtMs: lwMinutesAgo(1),
              jobs: [
                LauncherWidgetCronJob(
                  id: 'j0',
                  name: d.jobName,
                  profile: 'default',
                  paused: true,
                  openPayload: 'open-j0',
                ),
              ],
            ),
            nowMs: lwNow,
          );
        case 'offline':
          return LwCronScene.from(
            LauncherWidgetCronSnapshot(
              connectionId: 'home',
              updatedAtMs: lwMinutesAgo(50),
              jobs: jobs,
            ),
            nowMs: lwNow,
          );
        default:
          return LwCronScene.from(
            LauncherWidgetCronSnapshot(
              connectionId: 'home',
              updatedAtMs: lwMinutesAgo(1),
              jobs: jobs,
            ),
            nowMs: lwNow,
          );
      }
    case LwSubject.tasks:
      final tasks = LauncherWidgetTasksSnapshot(
        connectionId: 'home',
        updatedAtMs: mood == 'offline' ? lwMinutesAgo(45) : lwMinutesAgo(1),
        tasks: [
          LauncherWidgetTask(
            id: 't1',
            title: d.taskTitle,
            state: LauncherWidgetTaskState.running,
            assignee: d.agent,
            openPayload: 'open-t1',
          ),
          const LauncherWidgetTask(
            id: 't2',
            title: 'Reservar hotel',
            state: LauncherWidgetTaskState.pending,
          ),
        ],
        runningCount: d.count == 0 ? 1 : (d.count ~/ 2).clamp(1, 999),
        attentionCount: d.count == 0 ? 0 : (d.count ~/ 3).clamp(0, 999),
        pendingCount: d.count,
      );
      switch (mood) {
        case 'setup':
          return LwTasksScene.from(null, nowMs: lwNow);
        case 'empty':
          return LwTasksScene.from(
            LauncherWidgetTasksSnapshot(
              connectionId: 'home',
              updatedAtMs: lwMinutesAgo(1),
              tasks: const [],
            ),
            nowMs: lwNow,
          );
        default:
          return LwTasksScene.from(tasks, nowMs: lwNow);
      }
    case LwSubject.newChat:
      return LwNewChatScene.from(
        mood == 'setup' ? HermesHomeWidgetSnapshot.empty : _chatSnapshot(d),
      );
  }
}
