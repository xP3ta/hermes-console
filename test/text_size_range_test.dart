// User report: «font sizing controls … it's getting harder
// for me to read small fonts». Owner decision (2026-11-13): one control
// in Ajustes → Aspecto, live sample, default and reset, persisted, immediate;
// the range is chosen from tests on narrow phone / phone / Fold / tablet over
// menus, dialogs, chat with the keyboard and Settings, never by intuition;
// Android's own accessibility scale is respected, never capped.
//
// The sweep below pumps real screens at system 1.0 × Hermes default 1.10 ×
// factor and records every layout overflow. Lines starting `RANGE ` are the
// evidence the chosen range rests on.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_prefs.dart';
import 'package:hermes_android/core/bots/ui/room/room_screen.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/hosted_groups.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/screens/look_feel_screen.dart';
import 'package:hermes_android/core/screens/mission_control_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/mission_control_repository.dart';
import 'package:hermes_android/core/services/mission_snapshot_cache.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/look_feel.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bots/room/room_fixtures.dart';
import 'support/inter_font.dart';

typedef _Device = ({String name, Size size, double dpr});

const List<_Device> _devices = [
  (name: 'narrow-360x640', size: Size(360, 640), dpr: 3),
  (name: 'phone-412x915', size: Size(412, 915), dpr: 2.625),
  (name: 'fold-cover-344x882', size: Size(344, 882), dpr: 2.625),
  (name: 'fold-inner-673x841', size: Size(673, 841), dpr: 2.625),
  (name: 'tablet-800x1280', size: Size(800, 1280), dpr: 2),
];

/// Candidate factors over the 1.10 default (system 1.0).
const List<double> _sweep = [
  0.80, 0.85, 1.0, 1.15, 1.30, 1.40, 1.50, 1.75, 2.0, //
];

/// Factors also checked on top of Android's own 130 % and 200 %.
/// 1.0 is today's app (no factor): the baseline for Android's own scale.
const List<double> _withSystem = [1.0, 1.15, 1.30, 1.50];

void _setDevice(WidgetTester tester, _Device device) {
  tester.view.physicalSize = device.size * device.dpr;
  tester.view.devicePixelRatio = device.dpr;
}

/// The app's own composition (main.dart): system × Hermes.
Widget _scaled(double system, double factor, Widget child) => Builder(
  builder: (context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: composeAppTextScaler(
        TextScaler.linear(system),
        FontSizeService.defaultScale * factor,
      ),
    ),
    child: child,
  ),
);

/// The language of the next probe (the sweep runs English first, then the
/// languages with the longest labels).
Locale _locale = const Locale('en');

Widget _app(Widget home, {double system = 1.0, double factor = 1.0}) =>
    MaterialApp(
      locale: _locale,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      builder: (context, child) => _scaled(system, factor, child!),
      home: home,
    );

/// pumpAndSettle that gives up quietly (a screen with a looping animation
/// still gets every frame it needs to lay out).
Future<void> _settle(WidgetTester tester) async {
  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  } on FlutterError {
    // Timed out: frames were pumped, which is all the probe needs.
  }
}

/// Every exception the last frames reported (overflows included).
List<Object> _drain(WidgetTester tester) {
  final out = <Object>[];
  for (Object? e = tester.takeException(); e != null; e = tester.takeException()) {
    out.add(e);
  }
  return out;
}

String _kind(List<Object> errors) => errors.isEmpty
    ? 'ok'
    : errors.any((e) => '$e'.contains('overflowed'))
    ? 'OVERFLOW'
    : 'ERROR(${errors.first.runtimeType})';

// ── surfaces ────────────────────────────────────────────────────────────────

Future<FontSizeService> _service([Map<String, Object> values = const {}]) async {
  SharedPreferences.setMockInitialValues(values);
  return FontSizeService(await SharedPreferences.getInstance());
}

Future<bool> _settings(WidgetTester tester, double system, double factor) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final service = FontSizeService(prefs);
  await tester.pumpWidget(
    _app(
      LookFeelScreen(
        prefsForTesting: LookFeelPrefs(prefs),
        fontIdForTesting: ValueNotifier('inter'),
        onFontForTesting: (_) async {},
        fontSizeForTesting: service,
      ),
      system: system,
      factor: factor,
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  // Walk the whole list so every row (the text size control included) lays
  // out at this size.
  final list = find.byType(Scrollable).first;
  var sawControl = false;
  for (var i = 0; i < 12; i++) {
    await tester.drag(list, const Offset(0, -400), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 50));
    sawControl |= find
        .byKey(const ValueKey('text-size-slider'))
        .evaluate()
        .isNotEmpty;
  }
  return sawControl;
}

final class _RoomGateway implements RoomGateway {
  final HostedGroupRoom room;
  final HostedGroupLogPage log;
  _RoomGateway(this.room, this.log);
  @override
  Future<HostedGroupWorkspaceReadback> read(HostedGroupRoom room) async =>
      HostedGroupWorkspaceReadback(
        room: this.room,
        log: log,
        capabilityGeneration: 1,
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _NoTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => true;
  @override
  int get tick => 0;
}

Future<bool> _chatWithKeyboard(
  WidgetTester tester,
  _Device device,
  double system,
  double factor,
) async {
  final seq = EventSeq();
  final events = <Map<String, dynamic>>[];
  for (var i = 0; i < 4; i++) {
    final u = seq.user(
      'Could you review the deployment checklist for step $i?',
      thread: 't$i',
      id: 'user-$i',
    );
    events
      ..add(u)
      ..add(
        seq.member(
          'm-builder',
          'builder',
          'Done. The checklist is green; one warning about the cache '
              'headers on step $i, details below.',
          u['event_id'] as String,
          thread: 't$i',
        ),
      );
  }
  final log = buildLog(events);
  final room = buildRoom(latestSeq: log.latestSeq);
  await tester.pumpWidget(
    _app(
      RoomScreen(
        room: room,
        log: log,
        gateway: _RoomGateway(room, log),
        capabilities: const RoomCapabilities(
          canSend: true,
          canRename: true,
          canStop: true,
          canDisband: true,
          canApprove: true,
          canRetry: true,
        ),
        profileFor: (_) => null,
        prefs: MemoryRoomPrefs(),
        pollTimer: (_, _) => _NoTimer(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(1790000400 * 1000),
      ),
      system: system,
      factor: factor,
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  final field = find.descendant(
    of: find.byType(ConsoleComposer),
    matching: find.byType(TextField),
  );
  await tester.tap(field);
  await tester.enterText(field, 'A longer reply that wraps onto a second line');
  // The keyboard takes ~40 % of the height.
  tester.view.viewInsets = FakeViewPadding(
    bottom: device.size.height * 0.4 * device.dpr,
  );
  await tester.pump(const Duration(milliseconds: 300));
  return tester.testTextInput.isVisible &&
      find.text('A longer reply that wraps onto a second line').evaluate().isNotEmpty;
}

Map<String, dynamic> _member(String profile) => {
  'member_id': 'm-$profile',
  'profile': profile,
  'handle': profile,
  'target': {'kind': 'local', 'profile': profile},
};

MissionBackendSnapshot _botsSnapshot() {
  Map<String, dynamic> room(String id, String name) => {
    'room_id': id,
    'name': name,
    'members': [_member('builder'), _member('reviewer')],
    'authority_gateway_id': 'gw',
    'authority_epoch': 1,
    'revision': 1,
    'created_at': 1700000000.0,
    'updated_at': 1700000001.0,
    'idempotent': false,
    'latest_seq': 0,
  };
  HostedGroupLogPage log(String id) => HostedGroupLogPage.fromJson(
    {
      'events': <Object>[],
      'cursor': 0,
      'latest_seq': 0,
      'has_more': false,
      'authority': {'gateway_id': 'gw', 'epoch': 1},
    },
    expectedRoomId: id,
    sinceSeq: 0,
  );
  return MissionBackendSnapshot(
    profiles: const [
      AgentProfile(name: 'builder'),
      AgentProfile(name: 'reviewer'),
      AgentProfile(name: 'researcher'),
    ],
    profilesCapability: MissionCapabilityState.available,
    sessionsCapability: MissionCapabilityState.available,
    kanbanCapability: MissionCapabilityState.available,
    board: const KanbanBoard(columns: []),
    hostedGroups: HostedGroupsSnapshot(
      capabilities: GroupsCapabilities.tryParse(
        {
          'protocol_version': 2,
          'driver': true,
          'max_log_limit': 500,
          'methods': [
            'groups.capabilities', 'groups.list', 'groups.create',
            'groups.state', 'groups.log', 'groups.send',
          ],
        },
        connectionId: 'range',
        generation: 1,
      ),
      rooms: [
        HostedGroupRoom.fromJson(room('room-a', 'Release coordination')),
        HostedGroupRoom.fromJson(room('room-b', 'Design review')),
      ],
      logs: [log('room-a'), log('room-b')],
      unreadableRooms: const [
        HostedGroupUnreadableRoom(
          roomId: 'room-c',
          name: 'Weekly planning',
          reason: HostedGroupUnreadableReason.serverError,
        ),
      ],
    ),
    hostedGroupsCapability: MissionCapabilityState.available,
    loadedAt: DateTime.fromMillisecondsSinceEpoch(1),
  );
}

final class _BotsSource
    implements MissionControlDataSource, MissionHostedGroupsDataSource {
  @override
  Future<MissionBackendSnapshot> load() async => _botsSnapshot();
  @override
  Stream<KanbanEvent>? watchKanban({required int since}) => null;
  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('range: ${invocation.memberName}');
}

Future<bool> _botsWithMenu(
  WidgetTester tester,
  double system,
  double factor,
) async {
  SharedPreferences.setMockInitialValues({});
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  addTearDown(manager.dispose);
  await tester.pumpWidget(
    _app(
      MissionControlScreen(
        connection: SavedConnection(
          id: 'range',
          label: 'Range',
          host: 'localhost',
          port: 8642,
          apiKey: 'unused',
        ),
        connManager: manager,
        dataSource: _BotsSource(),
        snapshotCache: MissionSnapshotCache(),
      ),
      system: system,
      factor: factor,
    ),
  );
  await _settle(tester);
  final create = find.byKey(const ValueKey('mission-create-agent'));
  if (create.evaluate().isEmpty) return false;
  await tester.tap(create);
  await _settle(tester);
  return find
          .byKey(const ValueKey('mission-create-chooser-room'))
          .evaluate()
          .isNotEmpty &&
      find.byKey(const ValueKey('mission-rooms-unreadable')).evaluate().isNotEmpty;
}

/// The two real confirmations with the longest button labels across the
/// nine languages: a room's «Cancel wait / Keep waiting»
/// (room_screen.dart:1205) and the forced worktree removal
/// (git_hub_worktrees_screen.dart:121).
Future<bool> _dialog(
  WidgetTester tester,
  double system,
  double factor, {
  bool worktree = false,
}) async {
  await tester.pumpWidget(
    _app(
      Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const ValueKey('open-dialog'),
              onPressed: () {
                final s = Strings.of(context);
                unawaited(
                  worktree
                      ? showHermesConfirmDialog(
                          context: context,
                          title: s.ghtWorktreeRemoveForceTitle,
                          message: s.ghtWorktreeRemoveForceBody(
                            '/srv/hermes/worktrees/feature-text-size',
                          ),
                          confirmLabel: s.ghtWorktreeRemoveForce,
                          cancelLabel: s.commonCancel,
                          destructive: true,
                        )
                      : showHermesConfirmDialog(
                          context: context,
                          title: s.rq1215CancelWaitTitle('Researcher Bot'),
                          message: s.rq1215CancelWaitBody('Researcher Bot'),
                          confirmLabel: s.rq1215CancelWait,
                          cancelLabel: s.rq1215KeepWaiting,
                        ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
      system: system,
      factor: factor,
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-dialog')));
  await _settle(tester);
  return find.byKey(const ValueKey('hermes-confirm-dialog')).evaluate().isNotEmpty;
}

/// Positive control: a fixed 100 px row with text that never fits. If the
/// probe did not flag this, an «ok» elsewhere would prove nothing.
Future<bool> _alwaysOverflows(
  WidgetTester tester,
  double system,
  double factor,
) async {
  await tester.pumpWidget(
    _app(
      const Scaffold(
        body: Center(
          child: SizedBox(
            width: 100,
            child: Row(children: [Text('This label never fits in 100 px')]),
          ),
        ),
      ),
      system: system,
      factor: factor,
    ),
  );
  await tester.pump();
  return true;
}

/// Pumps a surface; true when the parts that matter were really on screen.
typedef _Surface =
    Future<bool> Function(
      WidgetTester tester,
      _Device device,
      double system,
      double factor,
    );

final Map<String, _Surface> _surfaces = {
  'settings-look-feel': (t, d, s, f) => _settings(t, s, f),
  'chat-room-keyboard': _chatWithKeyboard,
  'bots-new-menu': (t, d, s, f) => _botsWithMenu(t, s, f),
  'confirm-dialog-room-wait': (t, d, s, f) => _dialog(t, s, f),
  'confirm-dialog-worktree': (t, d, s, f) => _dialog(t, s, f, worktree: true),
};

/// Languages whose labels run longest (and two CJK ones for line height).
const List<String> _locales = ['es', 'de', 'fr', 'pt', 'it', 'ja', 'zh'];

Future<String> _probe(
  WidgetTester tester,
  _Device device,
  _Surface surface,
  double system,
  double factor,
) async {
  _setDevice(tester, device);
  tester.view.resetViewInsets();
  final rendered = await surface(tester, device, system, factor);
  final errors = _drain(tester);
  final result = rendered || errors.isNotEmpty
      ? _kind(errors)
      : 'NOT-RENDERED';
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  _drain(tester);
  tester.view.resetViewInsets();
  return result;
}

void main() {
  setUpAll(loadInterFont);
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('FontSizeService', () {
    test('default is the 1.10 density, shown as 100 %', () async {
      final service = await _service();
      expect(service.factor, 1.0);
      expect(service.scale, FontSizeService.defaultScale);
      expect(service.isDefault, isTrue);
    });

    test('a value stored by an old build under font_size_scale is ignored',
        () async {
      final service = await _service({'font_size_scale': 1.4});
      expect(service.scale, FontSizeService.defaultScale);
    });

    test('setFactor persists, notifies and snaps to the range', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final service = FontSizeService(prefs);
      var notified = 0;
      service.addListener(() => notified++);

      await service.setFactor(1.17);
      expect(service.factor, 1.15);
      expect(notified, 1);
      expect(prefs.getDouble(FontSizeService.prefsKey), 1.15);
      expect(FontSizeService(prefs).factor, 1.15, reason: 'persisted');

      await service.setFactor(9);
      expect(service.factor, FontSizeService.maxFactor);
      await service.setFactor(-1);
      expect(service.factor, FontSizeService.minFactor);
      await service.setFactor(double.nan);
      expect(service.factor, 1.0);

      await service.setFactor(1.2);
      await service.reset();
      expect(service.factor, 1.0);
      expect(prefs.containsKey(FontSizeService.prefsKey), isFalse);
    });

    test('a corrupt stored value falls back to the default', () async {
      final service = await _service({FontSizeService.prefsKey: 'big'});
      expect(service.factor, 1.0);
    });

    test("Android's accessibility scale multiplies, never capped", () {
      for (final system in [1.0, 1.3, 2.0]) {
        for (final factor in [
          FontSizeService.minFactor,
          1.0,
          FontSizeService.maxFactor,
        ]) {
          final scaler = composeAppTextScaler(
            TextScaler.linear(system),
            FontSizeService.defaultScale * factor,
          );
          expect(
            scaler.scale(10),
            closeTo(10 * system * FontSizeService.defaultScale * factor, 1e-9),
          );
        }
      }
    });
  });

  testWidgets('Look & Feel has the one text size control: live sample, '
      'steps, value, reset; applies at once and persists', (tester) async {
    _setDevice(tester, _devices[1]);
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = FontSizeService(prefs);
    await tester.pumpWidget(
      ListenableBuilder(
        listenable: service,
        builder: (context, _) => MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark'),
          // Exactly what main.dart does with the service.
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: composeAppTextScaler(
                MediaQuery.of(context).textScaler,
                service.scale,
              ),
            ),
            child: child!,
          ),
          home: LookFeelScreen(
            prefsForTesting: LookFeelPrefs(prefs),
            fontIdForTesting: ValueNotifier('inter'),
            onFontForTesting: (_) async {},
            fontSizeForTesting: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final control = find.byKey(const ValueKey('lfl-text-size'));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('text-size-reset')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(control, findsOneWidget);
    expect(find.byKey(const ValueKey('text-size-slider')), findsOneWidget);
    expect(find.text('100 %'), findsOneWidget);
    expect(
      tester.widget<TextButton>(find.byKey(const ValueKey('text-size-reset')))
          .onPressed,
      isNull,
      reason: 'nothing to reset at the default',
    );
    final sampleBefore = tester.getSize(
      find.byKey(const ValueKey('text-size-sample')),
    );

    await tester.tap(find.byKey(const ValueKey('text-size-larger')));
    await tester.pumpAndSettle();
    expect(service.factor, 1.05);
    expect(find.text('105 %'), findsOneWidget);
    expect(prefs.getDouble(FontSizeService.prefsKey), 1.05);
    final sampleAfter = tester.getSize(
      find.byKey(const ValueKey('text-size-sample')),
    );
    expect(
      sampleAfter.height * sampleAfter.width,
      greaterThan(sampleBefore.height * sampleBefore.width),
      reason: 'the sample (and the whole app) grows at once',
    );

    await tester.tap(find.byKey(const ValueKey('text-size-reset')));
    await tester.pumpAndSettle();
    expect(service.factor, 1.0);
    expect(find.text('100 %'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('RANGE positive control: the probe does flag an overflow', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final results = [
      for (final factor in const [0.85, 1.0, 1.3])
        await _probe(
          tester,
          _devices.first,
          (t, d, s, f) => _alwaysOverflows(t, s, f),
          1.0,
          factor,
        ),
    ];
    // ignore: avoid_print
    print('RANGE positive-control ${results.join(' ')}');
    expect(results, everyElement('OVERFLOW'));
  });

  for (final surface in _surfaces.entries) {
    testWidgets('RANGE sweep: ${surface.key}', (tester) async {
      addTearDown(tester.view.reset);
      final failures = <String>[];
      for (final device in _devices) {
        final row = <String>[];
        for (final factor in _sweep) {
          final result = await _probe(
            tester,
            device,
            surface.value,
            1.0,
            factor,
          );
          row.add('${factor.toStringAsFixed(2)}=$result');
          final inRange =
              factor >= FontSizeService.minFactor - 1e-9 &&
              factor <= FontSizeService.maxFactor + 1e-9;
          if (inRange && result != 'ok') {
            failures.add('${device.name} ×$factor: $result');
          }
        }
        // ignore: avoid_print
        print('RANGE ${surface.key} ${device.name} system=1.0 ${row.join(' ')}');
      }
      // Android's own scale on top of the chosen maximum: recorded, not
      // capped (the app never limits the system setting).
      for (final system in const [1.3, 2.0]) {
        for (final factor in _withSystem) {
          final row = <String>[];
          for (final device in _devices) {
            final result = await _probe(
              tester,
              device,
              surface.value,
              system,
              factor,
            );
            row.add('${device.name}=$result');
          }
          // ignore: avoid_print
          print(
            'RANGE ${surface.key} system=$system factor=$factor '
            '${row.join(' ')}',
          );
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    });
  }

  for (final surface in _surfaces.entries) {
    testWidgets('RANGE languages: ${surface.key}', (tester) async {
      addTearDown(tester.view.reset);
      addTearDown(() => _locale = const Locale('en'));
      final failures = <String>[];
      for (final code in _locales) {
        _locale = Locale(code);
        for (final device in _devices) {
          final row = <String>[];
          for (final factor in const [0.85, 1.0, 1.15, 1.30, 1.50]) {
            final result = await _probe(
              tester,
              device,
              surface.value,
              1.0,
              factor,
            );
            row.add('${factor.toStringAsFixed(2)}=$result');
            if (result != 'ok') {
              failures.add('$code ${device.name} ×$factor: $result');
            }
          }
          // ignore: avoid_print
          print('RANGE-L ${surface.key} $code ${device.name} ${row.join(' ')}');
        }
        // Android's own scale on top of the maximum: recorded, not gated
        // (the app never limits the system setting).
        for (final system in const [1.3, 2.0]) {
          final row = <String>[];
          for (final device in _devices) {
            row.add(
              '${device.name}=${await _probe(tester, device, surface.value, system, FontSizeService.maxFactor)}',
            );
          }
          // ignore: avoid_print
          print(
            'RANGE-L ${surface.key} $code system=$system '
            'factor=${FontSizeService.maxFactor} ${row.join(' ')}',
          );
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    });
  }
}
