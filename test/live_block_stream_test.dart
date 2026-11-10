// A Markdown block written live in the real chat (a table, a code block, a
// list), fed in small chunks with frames in between. What the reader sees
// is checked on every painted frame of the live reply: once a part of the
// block is painted it stays painted, it is never replaced by the frame of
// an incomplete table, and the paragraph above it does not move.
//
// Report (owner, physical Fold, synthetic chat): the table header appeared,
// then the whole table vanished for ~300 ms and came back with several rows
// at once. Painted visibility is read from the live reply's own clip at the
// moment it paints its child (`debugOnProfilePaint`), not from the widget
// tree: the cells are in the tree even when they are not painted.
//
// The transcript is a reversed list that follows the stream, so growth at
// the bottom moves the whole bubble up by exactly that growth; that is the
// follow, not a reflow. What must not change is the layout inside the
// reply: the paragraph above the block keeps its place in the reply and the
// gap between it and the block stays the same, including when a long reply
// switches to its split rendering (1600 characters) and when it finishes.
// And the live reply never gets shorter while it streams: in that list a
// reply that shrinks and grows again bounces everything above it.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/pinned_prompt_prefs.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/widgets/chat/live_reply_reveal.dart';
import 'package:hermes_android/core/widgets/chat/streaming_markdown_blocks.dart';
import 'package:hermes_android/core/widgets/markdown_table.dart';
import 'package:hermes_android/main.dart';

import 'support/test_api_client.dart';

class _StreamingGateway
    implements HermesDesktopGateway, HermesDesktopSessionLifecycleGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-live-block',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async => DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-live-block',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-live-block',
    storedSessionId: 'sess-live-block',
    created: true,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  void emit(String type, [Map<String, dynamic> payload = const {}]) {
    _events.add(
      TuiGatewayEvent(
        type: type,
        sessionId: 'runtime-live-block',
        payload: payload,
      ),
    );
  }

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

SavedConnection _connection() => SavedConnection(
  id: 'conn-live-block',
  label: 'Bloques en vivo',
  host: 'example.test',
  port: 8642,
  apiKey: 'test-key',
);

Session _session() => Session(
  id: 'sess-live-block',
  title: 'Bloques en vivo',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 0,
  isActive: true,
  preview: '',
  startedAt: 0,
);

ApiClient _safeApi() => testApiClient(
  baseUrl: 'https://example.test',
  httpClient: MockClient((_) async => http.Response('not found', 404)),
);

List<Map<String, dynamic>> _history() => [
  {'id': 'h-a-0', 'role': 'assistant', 'content': 'Respuesta anterior, corta.'},
  {'id': 'h-u-0', 'role': 'user', 'content': 'Pregunta anterior.'},
];

/// From this length a live reply is drawn as a closed prefix of blocks
/// plus a mutable tail.
const int _splitAt = liveAssistantStableSplitMinChars;

const String _marker = 'Justo antes del bloque';

enum _Kind { table, code, list }

const String _table =
    '| Servicio | Estado | Latencia |\n'
    '|---|---|---|\n'
    '| Pasarela | activa | 12 ms |\n'
    '| Planificador | activo | 30 ms |\n'
    '| Memoria | en pausa | 4 ms |\n'
    '| Archivo | activo | 7 ms |\n'
    '| Notificaciones | degradado | 95 ms |\n';

const String _code =
    '```python\n'
    'def total(valores):\n'
    '    suma = 0\n'
    '    for valor in valores:\n'
    '        suma += valor\n'
    '    return suma\n'
    '```\n';

const String _list =
    '- Primera tarea pendiente\n'
    '- Segunda tarea, revisar los registros\n'
    '- Tercera tarea, avisar al equipo\n'
    '- Cuarta tarea, cerrar la incidencia\n';

/// Every cell of [_table], row by row. A text seen before in the table gets
/// `#2`, `#3`: the cells are told apart by their place in reading order.
final List<String> _tableCells = _cellNames([
  for (final line in _table.trim().split('\n'))
    if (!line.contains('---'))
      for (final cell in line.split('|'))
        if (cell.trim().isNotEmpty) cell.trim(),
]);

List<String> _cellNames(Iterable<String> texts) {
  final counts = <String, int>{};
  return [
    for (final text in texts)
      switch (counts[text] = (counts[text] ?? 0) + 1) {
        1 => text,
        final n => '$text#$n',
      },
  ];
}

const List<String> _listItems = [
  'Primera tarea pendiente',
  'Segunda tarea',
  'Tercera tarea',
  'Cuarta tarea',
];

String _blockOf(_Kind kind) => switch (kind) {
  _Kind.table => _table,
  _Kind.code => _code,
  _Kind.list => _list,
};

/// The paragraph right above the block, and before it enough closed text
/// for a long reply to cross [_splitAt] halfway through the block.
String _intro({required bool long, required int blockLength}) {
  const last = '$_marker, el resumen que pediste revisar:\n\n';
  if (!long) return 'Aquí tienes lo que pediste esta mañana. $last';
  final target = _splitAt - blockLength ~/ 2 - last.length;
  final parts = <String>[];
  var length = 0;
  for (var i = 0; ; i++) {
    final part =
        'Contexto $i: el despliegue de hoy siguió el plan y no '
        'hubo avisos nuevos en la cola.\n\n';
    if (length + part.length > target) break;
    parts.add(part);
    length += part.length;
  }
  // A short closing paragraph lands the split close to the block's middle.
  final pad = StringBuffer('Nota:');
  while (length + pad.length + 6 < target) {
    pad.write(' sin cambios.');
  }
  parts.add('$pad\n\n');
  return '${parts.join()}$last';
}

/// What the touch test compares: the live reply's height, the table's, the
/// incomplete table frame's, and how many cells are selectable text.
typedef _Shape = ({
  double reply,
  double table,
  double skeleton,
  int selectable,
});

const String _afterMarker = 'El resto no muestra cambios';
const String _after = '\n$_afterMarker desde ayer.';

Finder _richFinder(Finder root, String text) => find.descendant(
  of: root,
  matching: find.byWidgetPredicate(
    (widget) => widget is RichText && widget.text.toPlainText().contains(text),
  ),
);

/// The watched parts of the block under [root], by name.
Map<String, Element> _parts(_Kind kind, Finder root) {
  final out = <String, Element>{};
  switch (kind) {
    case _Kind.table:
      // A cell is selectable text or plain text, whichever the table
      // draws; either way it is found by its words.
      final cells = find.descendant(
        of: find.descendant(of: root, matching: find.byType(MarkdownTable)),
        matching: find.byWidgetPredicate(
          (widget) => widget is SelectableText || widget is RichText,
        ),
      );
      final elements = cells.evaluate().toList();
      final texts = [
        for (final element in elements)
          (switch (element.widget) {
            SelectableText(:final textSpan, :final data) =>
              textSpan?.toPlainText() ?? data ?? '',
            RichText(:final text) => text.toPlainText(),
            _ => '',
          }).trim(),
      ];
      final names = _cellNames(texts);
      for (var i = 0; i < elements.length; i++) {
        if (_tableCells.contains(names[i])) {
          out.putIfAbsent(names[i], () => elements[i]);
        }
      }
    case _Kind.code:
      final block = find.descendant(
        of: root,
        matching: find.byKey(const ValueKey('chat-code-block')),
      );
      final label = find.descendant(of: block, matching: find.text('python'));
      final code = find.descendant(
        of: block,
        matching: find.byKey(const ValueKey('chat-code-text')),
      );
      if (label.evaluate().isNotEmpty) out['python'] = label.evaluate().first;
      if (code.evaluate().isNotEmpty) out['code'] = code.evaluate().first;
    case _Kind.list:
      for (final item in _listItems) {
        final found = _richFinder(root, item).evaluate();
        if (found.isNotEmpty) out[item] = found.first;
      }
  }
  return out;
}

/// The top of the block on screen, or null while there is none.
double? _blockTop(WidgetTester tester, _Kind kind) {
  final finder = switch (kind) {
    _Kind.table => find.byType(MarkdownTable),
    _Kind.code => find.byKey(const ValueKey('chat-code-block')),
    _Kind.list => _richFinder(find.byType(ChatScreen), _listItems.first),
  };
  if (finder.evaluate().isEmpty) return null;
  return tester.getRect(finder.first).top;
}

class _Watch {
  _Watch(this.kind);

  final _Kind kind;
  final List<String> violations = [];

  /// Parts painted at least once.
  final Set<String> seen = {};

  /// Visibility of each part at the last paint of the live reply.
  Map<String, bool> painted = const {};

  /// Where each part was probed at the last paint, in the reveal's box,
  /// and that box's size: the failure says where a hidden part is.
  Map<String, Offset> probedAt = const {};
  Size revealSize = Size.zero;
  int paints = 0;
  int _paintsRead = 0;
  int frame = 0;
  double? gap;
  double? introTop;
  double? replyHeight;
  bool blockSeen = false;

  /// A cell of the table was painted by an earlier paint: from then on its
  /// frame (side borders, foot) is painted wherever the reply reaches.
  bool tableShown = false;
  int frameProbes = 0;

  /// Table height and the span from the paragraph above to the one below,
  /// at the last frame of the live reply; compared once it finishes.
  ({double table, double span})? lastLive;
  bool closeChecked = false;
  final List<String> trace = [];

  /// How many frames broke each rule; only the first few are listed.
  final Map<String, int> kinds = {};

  void fail(String what) {
    final kind = what.split(RegExp('[:(]')).first.trim();
    final count = kinds[kind] = (kinds[kind] ?? 0) + 1;
    if (count <= 4) violations.add('frame $frame: $what');
  }

  /// Called while the live reply paints its child: its clip for this frame
  /// is final, so this is what the reader sees.
  void onRevealPaint(RenderLiveReplyReveal reveal) {
    paints++;
    final result = <String, bool>{};
    final at = <String, Offset>{};
    final root = find.byType(LiveReplyReveal);
    for (final MapEntry(:key, :value) in _parts(kind, root).entries) {
      final box = value.renderObject;
      if (box is! RenderBox || !box.hasSize || !box.attached) continue;
      final probe = Offset(4, math.min(8, box.size.height / 2));
      final local = box.localToGlobal(probe, ancestor: reveal);
      // Beside the reply's box: a table wider than the reply scrolls
      // sideways and this column is out of view, not hidden by the reveal.
      if (local.dx < 0 || local.dx >= reveal.size.width) continue;
      at[key] = local;
      result[key] =
          local.dy >= 0 &&
          local.dy < reveal.size.height &&
          reveal.paintsPosition(local);
    }
    painted = result;
    probedAt = at;
    revealSize = reveal.size;
    if (kind == _Kind.table) {
      if (tableShown) _probeFrame(reveal);
      if (result.values.any((value) => value)) tableShown = true;
    }
  }

  /// The table's own frame: its left and right borders and its foot,
  /// probed just inside the border wherever the reply is tall enough to
  /// show them. The cells alone do not tell: the frame is not text.
  void _probeFrame(RenderLiveReplyReveal reveal) {
    final frames = find.descendant(
      of: find.byType(MarkdownTable),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).border != null &&
            (widget.decoration as BoxDecoration).borderRadius != null,
      ),
    );
    for (final element in frames.evaluate()) {
      final box = element.renderObject;
      if (box is! RenderBox || !box.hasSize || !box.attached) continue;
      final size = box.size;
      final right = size.width - 0.5;
      final foot = size.height - 0.5;
      final points = <String, Offset>{
        for (var y = 12.0; y <= size.height - 12; y += 6) ...{
          'left border at ${y.round()}': Offset(0.5, y),
          'right border at ${y.round()}': Offset(right, y),
        },
        for (var x = 12.0; x <= size.width - 12; x += 12)
          'foot at ${x.round()}': Offset(x, foot),
      };
      final hidden = <String>[];
      for (final MapEntry(:key, :value) in points.entries) {
        final local = box.localToGlobal(value, ancestor: reveal);
        if (local.dy < 0 || local.dy >= reveal.size.height) continue;
        frameProbes++;
        if (!reveal.paintsPosition(local)) hidden.add(key);
      }
      if (hidden.isNotEmpty) {
        fail(
          'the table frame is not painted: ${hidden.length} probes, '
          'first ${hidden.first}, last ${hidden.last}',
        );
      }
    }
  }

  void afterFrame(WidgetTester tester) {
    frame++;
    final screen = find.byType(ChatScreen);
    final reveal = find.byType(LiveReplyReveal);
    final live = reveal.evaluate().isNotEmpty;
    final present = _parts(kind, screen);
    if (paints != _paintsRead) {
      _paintsRead = paints;
      for (final MapEntry(:key, :value) in painted.entries) {
        if (value) {
          if (seen.add(key)) trace.add('frame $frame: $key painted');
        } else if (seen.contains(key)) {
          final at = probedAt[key];
          fail(
            '$key was painted before and is hidden now '
            '(at ${at?.dx.round()},${at?.dy.round()} '
            'in ${revealSize.width.round()}x${revealSize.height.round()})',
          );
        }
      }
    }
    if (reveal.evaluate().isEmpty) {
      // A finished reply paints everything it lays out.
      for (final key in present.keys) {
        if (seen.add(key)) trace.add('frame $frame: $key (finished)');
      }
    }
    for (final key in seen) {
      if (!present.containsKey(key)) fail('$key was shown and is gone');
    }
    final top = _blockTop(tester, kind);
    if (seen.isNotEmpty) blockSeen = true;
    if (blockSeen && kind == _Kind.table) {
      if (find.byType(MarkdownTable).evaluate().isEmpty) {
        fail('the table is gone');
      }
      if (find.byType(ChatTableSkeleton).evaluate().isNotEmpty) {
        fail('the table went back to the frame of an incomplete table');
      }
    }
    if (reveal.evaluate().isNotEmpty) {
      // The list follows the stream: a reply that grows lifts the text
      // above it. One that shrinks and grows again bounces it.
      final height = tester.getSize(reveal.first).height;
      final before = replyHeight;
      if (before != null && height < before - 1) {
        fail(
          'the live reply shrank: ${before.toStringAsFixed(1)} -> '
          '${height.toStringAsFixed(1)}',
        );
      }
      replyHeight = height;
    }
    final intro = _richFinder(screen, _marker);
    if (kind == _Kind.table) _checkClose(tester, intro, live: live);
    if (!blockSeen || top == null || intro.evaluate().isEmpty) return;
    final introRect = tester.getRect(intro.first);
    final gapNow = top - introRect.bottom;
    final firstGap = gap ??= gapNow;
    if ((gapNow - firstGap).abs() > 1) {
      fail(
        'gap from the paragraph above to the block moved: '
        '${firstGap.toStringAsFixed(1)} -> ${gapNow.toStringAsFixed(1)}',
      );
    }
    if (reveal.evaluate().isNotEmpty) {
      final origin = tester.getTopLeft(reveal.first);
      final introNow = introRect.top - origin.dy;
      final firstTop = introTop ??= introNow;
      if ((introNow - firstTop).abs() > 1) {
        fail(
          'the paragraph above moved inside the reply: '
          '${firstTop.toStringAsFixed(1)} -> ${introNow.toStringAsFixed(1)}',
        );
      }
    }
  }

  /// The finished reply draws the table the way the live one did: the same
  /// height, and the paragraph below it where it was. In the transcript a
  /// reply that grows when it finishes pushes everything above it.
  void _checkClose(WidgetTester tester, Finder intro, {required bool live}) {
    final table = find.byType(MarkdownTable);
    final after = _richFinder(find.byType(ChatScreen), _afterMarker);
    if (table.evaluate().isEmpty ||
        after.evaluate().isEmpty ||
        intro.evaluate().isEmpty) {
      return;
    }
    final below = tester.getRect(after.first).bottom;
    final above = tester.getRect(intro.first).top;
    final now = (
      table: tester.getSize(table.first).height,
      span: below - above,
    );
    if (live) {
      lastLive = now;
      return;
    }
    final before = lastLive;
    if (closeChecked || before == null) return;
    closeChecked = true;
    if ((now.table - before.table).abs() > 1) {
      fail(
        'the table changed height when the reply finished: '
        '${before.table.toStringAsFixed(1)} -> '
        '${now.table.toStringAsFixed(1)}',
      );
    }
    if ((now.span - before.span).abs() > 1) {
      fail(
        'the reply changed height around the table when it finished: '
        '${before.span.toStringAsFixed(1)} -> '
        '${now.span.toStringAsFixed(1)}',
      );
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};

  void mockChannel(String name) {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }

  setUp(() {
    secureStore.clear();
    TurnOutboxStore.resetSerializationForTesting();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                secureStore[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secureStore[args['key'] as String];
              case 'delete':
                secureStore.remove(args['key'] as String);
                return null;
              case 'readAll':
                return Map<String, String>.from(secureStore);
              case 'containsKey':
                return secureStore.containsKey(args['key'] as String);
            }
            return null;
          },
        );
    mockChannel('dexterous.com/flutter/local_notifications');
    mockChannel('flutter_foreground_task/methods');
    mockChannel('flutter_foreground_task/background');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
  });

  Future<ActiveChat> pumpChat(
    WidgetTester tester,
    _StreamingGateway gateway,
  ) async {
    tester.platformDispatcher.localesTestValue = [const Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    // A folded phone: 1280 x 2856 px at 3x.
    tester.view
      ..physicalSize = const Size(1280, 2856)
      ..devicePixelRatio = 3.0
      ..padding = const FakeViewPadding(top: 120, bottom: 72)
      ..viewPadding = const FakeViewPadding(top: 120, bottom: 72);
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final prefs = await SharedPreferences.getInstance();
    await PinnedPromptPrefs.load(prefs);
    addTearDown(() => PinnedPromptPrefs.debugUse(null));
    final connectionManager = await ConnectionManager.create(prefs);
    final secureStorage = SecureStorage();
    final activeChats = ActiveChatService();
    final connection = _connection();
    final chat = activeChats.attach(
      connection: connection,
      sessionId: 'sess-live-block',
      sessionTitle: 'Bloques en vivo',
      api: _safeApi(),
      desktopGateway: gateway,
      disableForegroundKeepAlive: true,
    );
    chat
      ..internalMessagesForTesting = _history()
      ..messagesLoaded = true;

    await tester.pumpWidget(
      HermesApp(
        connManager: connectionManager,
        appLock: AppLockService(prefs),
        approvalPolicy: ApprovalPolicyService(prefs),
        fontSize: FontSizeService(prefs),
        sshManager: SshManager(secureStorage, connectionManager),
        sftpTransfers: SftpTransferService(
          SshManager(secureStorage, connectionManager),
          NotificationService(prefs),
        ),
        sshSessions: SshSessionService(
          SshManager(secureStorage, connectionManager),
        ),
        notifications: NotificationService(prefs),
        activeChats: activeChats,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));

    final navigatorContext = tester.element(find.byType(Navigator).first);
    Navigator.of(navigatorContext).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(connection: connection, session: _session()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(seconds: 1));
    return chat;
  }

  Future<void> tearDownChat(WidgetTester tester, _StreamingGateway g) async {
    await g.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  }

  for (final kind in _Kind.values) {
    for (final long in [false, true]) {
      final name = '${kind.name} in a ${long ? 'long' : 'short'} reply';
      testWidgets('$name: what was painted stays painted and in place', (
        tester,
      ) async {
        final gateway = _StreamingGateway();
        final chat = await pumpChat(tester, gateway);
        final block = _blockOf(kind);
        final intro = _intro(long: long, blockLength: block.length);
        if (long) {
          // Precondition: the reply switches to its split rendering while
          // the block is being written, not before and not after.
          expect(intro.length, lessThan(_splitAt - 20));
          expect(intro.length + block.length, greaterThan(_splitAt + 20));
        } else {
          expect(intro.length + block.length + _after.length, lessThan(900));
        }
        final watch = _Watch(kind);
        debugOnProfilePaint = (object) {
          final parent = object.parent;
          if (parent is RenderLiveReplyReveal) watch.onRevealPaint(parent);
        };
        addTearDown(() => debugOnProfilePaint = null);
        Future<void> frame() async {
          await tester.pump(const Duration(milliseconds: 16));
          watch.afterFrame(tester);
        }

        await chat.send(
          fullText: 'Resume el estado de hoy',
          model: 'hermes-agent',
          history: chat.buildHistory(),
        );
        gateway.emit('message.start');
        for (var i = 0; i < 6; i++) {
          await frame();
        }
        var splitWhileBlock = false;
        Future<void> stream(
          String text,
          int size, {
          bool inBlock = false,
        }) async {
          for (var at = 0; at < text.length; at += size) {
            final end = math.min(at + size, text.length);
            gateway.emit('message.delta', {'text': text.substring(at, end)});
            await frame();
            await frame();
            if (inBlock &&
                find.byType(StreamingMarkdownBlocks).evaluate().isNotEmpty) {
              splitWhileBlock = true;
            }
          }
        }

        await stream(intro, long ? 400 : 8);
        for (var i = 0; i < 20; i++) {
          await frame();
        }
        if (long) {
          expect(
            find.byType(StreamingMarkdownBlocks),
            findsNothing,
            reason: 'the reply was split before the block',
          );
        }
        await stream(block, 5, inBlock: true);
        await stream(_after, 6);
        for (var i = 0; i < 20; i++) {
          await frame();
        }
        gateway.emit('message.complete', {'text': chat.assistantContent});
        for (var i = 0; i < 60 && chat.isStreaming; i++) {
          await frame();
        }
        for (var i = 0; i < 10; i++) {
          await frame();
        }
        debugOnProfilePaint = null;

        // The harness saw the live reply paint and every part at least
        // once, so the visibility checks above were not vacuous.
        expect(watch.paints, greaterThan(0), reason: 'no live paint seen');
        final expected = switch (kind) {
          _Kind.table => _tableCells,
          _Kind.code => const ['python', 'code'],
          _Kind.list => _listItems,
        };
        expect(
          watch.seen,
          containsAll(expected),
          reason: watch.trace.join('\n'),
        );
        expect(watch.gap, isNotNull, reason: 'the gap was never measured');
        // The long reply really switched to its split rendering while the
        // block was being written, whatever the split length becomes.
        expect(splitWhileBlock, long, reason: 'split while the block came');
        if (kind == _Kind.table) {
          expect(watch.frameProbes, greaterThan(0), reason: 'frame unprobed');
          expect(watch.closeChecked, isTrue, reason: 'close never compared');
        }
        expect(
          watch.violations,
          isEmpty,
          reason:
              '${watch.violations.join('\n')}\n--- frames per rule ---\n'
              '${watch.kinds}\n--- trace ---\n'
              '${watch.trace.take(40).join('\n')}',
        );
        expect(tester.takeException(), isNull);
        await tearDownChat(tester, gateway);
      });
    }
  }

  // Touching the transcript while a reply streams stops following it, and
  // that turns the reveal off until the finger lifts (the app going to the
  // background does the same). The reply is still live: its table must keep
  // the shape it had, with no blank rows, no frame of an incomplete table
  // and no other kind of cell, or the reply moves under the reader's finger.
  testWidgets('table: touching the list mid-stream keeps the live table', (
    tester,
  ) async {
    final gateway = _StreamingGateway();
    final chat = await pumpChat(tester, gateway);
    Future<void> frames(int count) async {
      for (var i = 0; i < count; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    // Until the reveal has shown all it received, so turning it off has
    // nothing left to show at once.
    Future<void> settle() async {
      for (var i = 0; i < 120; i++) {
        await frames(1);
        final reveal = find.byType(LiveReplyReveal);
        if (reveal.evaluate().isNotEmpty &&
            tester.renderObject<RenderLiveReplyReveal>(reveal).settled) {
          break;
        }
      }
      await frames(2);
    }

    await chat.send(
      fullText: 'Resume el estado de hoy',
      model: 'hermes-agent',
      history: chat.buildHistory(),
    );
    gateway.emit('message.start');
    await frames(6);
    void emit(String text) => gateway.emit('message.delta', {'text': text});
    emit(_intro(long: false, blockLength: _table.length));
    await settle();

    final failures = <String>[];
    _Shape shape() {
      double height(Finder finder) =>
          finder.evaluate().isEmpty ? 0 : tester.getSize(finder.first).height;
      final cells = find.descendant(
        of: find.byType(MarkdownTable),
        matching: find.byType(SelectableText),
      );
      return (
        reply: height(find.byType(LiveReplyReveal)),
        table: height(find.byType(MarkdownTable)),
        skeleton: height(find.byType(ChatTableSkeleton)),
        selectable: cells.evaluate().length,
      );
    }

    Future<void> touch(String stage) async {
      final before = shape();
      void compare(String when, _Shape now) {
        if ((now.reply - before.reply).abs() > 1 ||
            (now.table - before.table).abs() > 1 ||
            (now.skeleton - before.skeleton).abs() > 1 ||
            now.selectable != before.selectable) {
          failures.add('$stage, $when: $before -> $now');
        }
      }

      final gesture = await tester.startGesture(
        tester.getCenter(_richFinder(find.byType(ChatScreen), _marker).first),
      );
      await frames(4);
      final reveal = tester.widget<LiveReplyReveal>(
        find.byType(LiveReplyReveal),
      );
      if (reveal.enabled) failures.add('$stage: the touch kept the reveal on');
      compare('finger down', shape());
      await gesture.up();
      await settle();
      compare('finger up', shape());
    }

    final lines = _table.split('\n');
    // Only the header: the table is not there yet.
    emit('${lines[0]}\n');
    await settle();
    await touch('header only');
    // One row, fewer than the blank rows a live table may keep room for.
    emit('${lines[1]}\n${lines[2]}\n');
    await settle();
    await touch('one row');
    emit('${lines[3]}\n${lines[4]}\n');
    await settle();
    await touch('three rows');

    expect(find.byType(MarkdownTable), findsOneWidget);
    expect(failures, isEmpty, reason: failures.join('\n'));
    gateway.emit('message.complete', {'text': chat.assistantContent});
    for (var i = 0; i < 60 && chat.isStreaming; i++) {
      await frames(1);
    }
    await frames(10);
    expect(tester.takeException(), isNull);
    await tearDownChat(tester, gateway);
  });
}
