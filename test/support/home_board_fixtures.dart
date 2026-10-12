import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/home/board/home_board_data.dart';
import 'package:hermes_android/core/home/board/home_board_kit.dart';
import 'package:hermes_android/core/home/board/home_board_model.dart';
import 'package:hermes_android/core/home/board/home_board_tiles.dart';
import 'package:hermes_android/core/home/home_now.dart';
import 'package:hermes_android/core/models/account_usage_limits.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/soft_tokens.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// The world of the approved Home mockups (Sunday 11 October, 22:04): the
/// main agent Hermes, the bots Forja, Fable, Astra, Radar and Argos, the
/// rooms Console Devs, Ideas and Homelab, five cron jobs and a Kanban
/// board. Tile tests and the design shots draw the widgets from it.
final homeFixtureNow = DateTime(2026, 10, 11, 22, 4);

DateTime homeAgoAt(Duration d) => homeFixtureNow.subtract(d);
DateTime homeIn(Duration d) => homeFixtureNow.add(d);

const homeQuestion = '¿Uso Sonnet 5.5 como modelo de reserva?';
const homeT1 = 'Prueba con subagentes, herramientas y pensamiento';
const homeT2 = 'Buscar cómo era onboarding nuevo';
const homeT3 = 'Diseño de píldora de estados en Hermes Console';
const homeT4 = 'Saludo amistoso';
const homeT5 = 'Arreglar selección de modelo fallback en Hermes Console';

HomeChatItem homeChat(
  String key,
  String title, {
  bool working = false,
  Duration running = const Duration(seconds: 41),
  String? step,
  bool asks = false,
  bool draft = false,
  bool failed = false,
  bool unread = false,
  String preview = '',
  String? agent,
  Duration ago = const Duration(minutes: 20),
  DateTime? at,
}) => HomeChatItem(
  key: key,
  title: title,
  preview: preview,
  at: at ?? homeAgoAt(ago),
  ref: key,
  working: working,
  workingSince: working ? homeAgoAt(running) : null,
  step: step,
  waitingForUser: asks,
  draft: draft,
  failed: failed,
  unread: unread,
  profileName: agent?.toLowerCase() ?? 'default',
  agentName: agent,
);

/// The five chats of the mockup's large «Chats».
List<HomeChatItem> homeChats() => [
  homeChat('t1', homeT1, working: true, step: '2 subagentes'),
  homeChat('t2', homeT2, asks: true, ago: const Duration(minutes: 3)),
  homeChat(
    't3',
    homeT3,
    preview: 'Te dejo tres opciones de píldora',
    at: DateTime(2026, 10, 11, 21, 44),
  ),
  homeChat(
    't4',
    homeT4,
    draft: true,
    preview: 'Hola, necesito hacer unos retoques',
    at: DateTime(2026, 10, 11, 20, 15),
  ),
  homeChat(
    't5',
    homeT5,
    preview: 'Ya elige Sonnet 5.5 si falla el principal',
    at: DateTime(2026, 10, 11, 18, 2),
  ),
];

HomeQuestionItem homeQuestionItem({
  String key = 'q1',
  String? sessionKey,
  String? actor = 'Astra',
  String question = homeQuestion,
  List<String> choices = const ['Sí, úsalo', 'No'],
}) => HomeQuestionItem(
  key: key,
  sessionKey: sessionKey,
  where: '',
  actor: actor,
  profileName: actor?.toLowerCase() ?? 'default',
  question: question,
  choices: choices,
  ref: key,
);

HomeApprovalItem homeApproval({
  String key = 'a1',
  String actor = 'Forja',
  bool canAllow = true,
  bool canDeny = true,
  String command = 'git push origin fix/dock',
}) => HomeApprovalItem(
  key: key,
  where: '',
  command: command,
  canAllow: canAllow,
  canDeny: canDeny,
  ref: key,
  actor: actor,
  profileName: actor.toLowerCase(),
);

HomeBoardBot homeBot(
  String name, {
  HomeBotState state = HomeBotState.idle,
  String? step,
  Duration? running,
  String? lastTitle,
  DateTime? lastAt,
}) => HomeBoardBot(
  profileName: name.toLowerCase(),
  displayName: name,
  state: state,
  step: step,
  since: running == null ? null : homeAgoAt(running),
  lastTitle: lastTitle,
  lastAt: lastAt,
);

/// Forja works (in Console Devs once the rooms say so), the others are
/// free with the last thing they did; Argos has done nothing lately.
List<HomeBoardBot> homeBots({bool astraWaits = false}) => [
  homeBot(
    'Forja',
    state: HomeBotState.working,
    running: const Duration(minutes: 2, seconds: 14),
    lastTitle: 'Publicar 1.2.15',
    lastAt: DateTime(2026, 10, 11, 19, 30),
  ),
  homeBot(
    'Fable',
    lastTitle: 'Diseño de píldora de estados',
    lastAt: DateTime(2026, 10, 11, 21, 44),
  ),
  homeBot(
    'Astra',
    state: astraWaits ? HomeBotState.waiting : HomeBotState.idle,
    lastTitle: 'Arreglar selección de modelo fallback',
    lastAt: DateTime(2026, 10, 11, 21, 12),
  ),
  homeBot(
    'Radar',
    lastTitle: 'Revisar disco',
    lastAt: DateTime(2026, 10, 11, 22, 0),
  ),
  homeBot('Argos'),
];

HomeBoardRoom homeRoom(
  String key,
  String title, {
  List<String> members = const ['forja', 'fable', 'astra'],
  int unread = 0,
  int mentions = 0,
  String? replying,
  Duration running = const Duration(seconds: 42),
  String? next,
  String? author,
  String? line,
  DateTime? lastAt,
}) => HomeBoardRoom(
  key: key,
  title: title,
  unread: unread,
  mentions: mentions,
  memberProfiles: members,
  responding: [?replying],
  respondingProfiles: [?replying?.toLowerCase()],
  respondingSince: replying == null ? null : homeAgoAt(running),
  next: next,
  lastAt: lastAt,
  lines: [
    if (line != null)
      HomeBoardRoomLine(
        author: author ?? '',
        profileName: author?.toLowerCase(),
        text: line,
      ),
  ],
);

List<HomeBoardRoom> homeRooms({bool live = true}) => [
  homeRoom(
    'devs',
    'Console Devs',
    members: const ['forja', 'fable', 'astra', 'radar', 'argos'],
    unread: live ? 3 : 2,
    mentions: live ? 1 : 0,
    replying: live ? 'Forja' : null,
    running: const Duration(minutes: 2, seconds: 14),
    next: live ? 'Astra' : null,
    author: 'Astra',
    line:
        'Lo reviso cuando acabe Forja y te digo si el arreglo del selector '
        'aguanta.',
    lastAt: live ? homeFixtureNow : DateTime(2026, 10, 11, 21, 50),
  ),
  homeRoom(
    'ideas',
    'Ideas',
    members: const ['fable', 'astra'],
    unread: 2,
    author: 'Fable',
    line:
        '¿Y si el sprite corre por encima de la píldora mientras Hermes '
        'trabaja?',
    lastAt: DateTime(2026, 10, 11, 21, 50),
  ),
  homeRoom(
    'homelab',
    'Homelab',
    members: const ['radar', 'argos'],
    author: 'Radar',
    line: 'Disco al 93 %, sin cambios desde ayer. La carga es normal.',
    lastAt: DateTime(2026, 10, 11, 14, 5),
  ),
];

HomeAutomation homeJob(
  String key,
  String name, {
  DateTime? next,
  DateTime? last,
  bool failed = false,
  bool enabled = true,
  int? every,
}) => HomeAutomation(
  key: key,
  name: name,
  ref: key,
  enabled: enabled,
  failed: failed,
  nextRun: enabled ? next : null,
  lastRunAt: last,
  lastRunOk: last == null ? null : !failed,
  everyMinutes: every,
);

/// The five jobs of the mockup's large «Cron», not in order.
List<HomeAutomation> homeJobs({bool failure = true}) => [
  homeJob(
    'daily',
    'Resumen diario',
    next: DateTime(2026, 10, 12, 8, 30),
    last: DateTime(2026, 10, 11, 8, 30),
    failed: failure,
  ),
  homeJob('social', 'Publicar en redes', enabled: false),
  homeJob(
    'hr',
    'Entrada RRHH',
    next: DateTime(2026, 10, 12, 7, 0),
    last: DateTime(2026, 10, 9, 7, 0),
  ),
  homeJob(
    'backup',
    'Copia de seguridad',
    next: DateTime(2026, 10, 12, 3, 0),
    last: DateTime(2026, 10, 11, 3, 0),
  ),
  homeJob(
    'disk',
    'Revisar disco',
    next: DateTime(2026, 10, 12, 4, 0),
    last: DateTime(2026, 10, 11, 22, 0),
    every: 360,
  ),
];

HomeTaskItem homeTask(String key, String title, {String? assignee}) =>
    HomeTaskItem(key: key, title: title, assignee: assignee, ref: key);

HomeTasks homeTasksBoard({bool running = true}) => HomeTasks(
  running: running
      ? [
          homeTask('k1', 'Publicar 1.2.15', assignee: 'forja'),
          homeTask('k2', 'Rediseñar Inicio', assignee: 'astra'),
        ]
      : const [],
  pending: [
    homeTask('k3', 'Probar GPT-Live con pantalla apagada'),
    homeTask('k4', 'Notas de la versión 1.2.15'),
    homeTask('k5', 'Capturas para Google Play'),
    homeTask('k6', 'Traducir ajustes de voz'),
  ],
);

/// Board data from the pieces above (nothing set means nothing there).
HomeBoardData homeData({
  List<HomeChatItem> chats = const [],
  List<HomeBoardBot> bots = const [],
  List<HomeBoardRoom> rooms = const [],
  List<HomeApprovalItem> approvals = const [],
  List<HomeQuestionItem> questions = const [],
  List<HomeAutomation>? automations = const [],
  bool automationsFailed = false,
  HomeTasks? tasks = const HomeTasks(),
  bool tasksFailed = false,
  bool botsLoaded = true,
  bool chatsLoaded = true,
  bool online = true,
  AccountUsageLimits? limits,
}) => HomeBoardData(
  now: homeFixtureNow,
  chats: chats,
  bots: bots,
  rooms: rooms,
  limits: limits,
  approvals: approvals,
  questions: questions,
  automations: automations,
  automationsFailed: automationsFailed,
  tasks: tasks,
  tasksFailed: tasksFailed,
  botsLoaded: botsLoaded,
  chatsLoaded: chatsLoaded,
  mainName: 'Hermes',
  server: HomeBoardServer(label: 'Hermes', online: online),
).withGlance();

/// What a widget asked the screen to do.
final class HomeCalls {
  final List<String> log = [];
  final List<(String key, bool allow)> answers = [];
  final List<(String key, String choice)> choices = [];

  /// Set to keep an answer in flight.
  Future<void>? hold;

  late final HomeBoardActions actions = HomeBoardActions(
    answer: (item, {required allow}) async {
      answers.add((item.key, allow));
      await hold;
    },
    answerQuestion: (item, choice) async {
      choices.add((item.key, choice));
      await hold;
    },
    viewApproval: (a) => log.add('approval:${a.key}'),
    viewQuestion: (q) => log.add('question:${q.key}'),
    openChat: (c) => log.add('chat:${c.key}'),
    openRoom: (r) => log.add('room:$r'),
    openBot: (b) => log.add('bot:${b.profileName}'),
    openAutomation: (j) => log.add('cron:${j?.key ?? 'all'}'),
    openTasks: (t) => log.add('task:${t?.key ?? 'all'}'),
    openServer: () => log.add('server'),
    openSessions: () => log.add('sessions'),
    retry: () => log.add('retry'),
  );
}

/// The cell the board gives each size on a 390 dp phone with four rows.
Size homeCell(HomeWidgetSize size, {double row = 165}) => switch (size) {
  HomeWidgetSize.small => Size(172.5, row),
  HomeWidgetSize.wide => Size(356, row),
  HomeWidgetSize.large => Size(356, row * 2 + HomeBoardGridRule.gap),
};

/// One widget in its cell, as the board draws it.
Widget homeTile({
  required HomeWidgetKind kind,
  required HomeWidgetSize size,
  required HomeBoardData data,
  required HomeBoardActions actions,
  Map<String, Object?> options = const {},
  bool editing = false,
  Size? cell,
  Key? key,
}) {
  final item = HomeWidgetInstance(
    id: 'tile',
    kind: kind,
    size: size,
    options: options,
  );
  return SizedBox.fromSize(
    key: key,
    size: cell ?? homeCell(size),
    child: Builder(
      builder: (context) => HomeCard(
        hero: !editing && homeWidgetHero(item, data),
        child: HomeWidgetBody(
          HomeTileContext(
            item: item,
            data: data,
            actions: actions,
            tint: homeWidgetTint(
              SoftPalette.ofContext(context),
              item,
              colorful: true,
            ),
            editing: editing,
            clock: () => homeFixtureNow,
          ),
        ),
      ),
    ),
  );
}

Future<HomeCalls> pumpHomeTile(
  WidgetTester tester, {
  required HomeWidgetKind kind,
  required HomeWidgetSize size,
  required HomeBoardData data,
  Map<String, Object?> options = const {},
  bool editing = false,
  Size? cell,
  double textScale = 1,
  Locale locale = const Locale('es'),
  HomeCalls? calls,
}) async {
  final c = calls ?? HomeCalls();
  tester.view.physicalSize = const Size(390, 844) * 3;
  tester.view.devicePixelRatio = 3;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: locale,
      theme: AppTheme.fromId('amber'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.all(17),
            child: homeTile(
              kind: kind,
              size: size,
              data: data,
              actions: c.actions,
              options: options,
              editing: editing,
              cell: cell,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  return c;
}
