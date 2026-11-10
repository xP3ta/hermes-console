// Q9-CRISTAL-DETRAS (the owner, 9714 on the Fold: «no veo que el contenido pase
// por detrás»). A long conversation under the chat's header: with the glass
// (HermesGlassStrip), the turns that scroll under it show between its
// pieces, fading as they rise; without blur (the chrome of before, what the
// Fold showed while its policy said no) a solid band hides them. The band
// measured lies between the pieces, where the blur (clipped to them) does
// not reach: what differs is the page's fade, the glass's soft one against
// the solid one of before. The policy that turns the glass on is tested in
// test/frosted_glass_test.dart. With
// CHAT_GLASS_CAPTURE_DIR set, the header is written there as PNG, before
// and after, for the owner.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

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
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/core/widgets/island.dart';
import 'package:hermes_android/main.dart';

import 'support/test_api_client.dart';

class _IdleGateway
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
    runtimeSessionId: 'runtime-md-baseline',
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
    runtimeSessionId: 'runtime-md-baseline',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-md-baseline',
    storedSessionId: 'sess-md-baseline',
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
        sessionId: 'runtime-md-baseline',
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
  id: 'conn-md-baseline',
  label: 'Markdown baseline',
  host: '192.168.255.254',
  port: 8642,
  apiKey: 'test-key',
);

Session _session() => Session(
  id: 'sess-md-baseline',
  title: 'Baseline markdown',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 0,
  isActive: true,
  preview: '',
  startedAt: 0,
);

ApiClient _safeApi() => testApiClient(
  baseUrl: 'http://192.168.255.254:8642',
  httpClient: MockClient((_) async => http.Response('not found', 404)),
);

/// T101 (spec 070): línea base del render del chat principal antes y después
/// de extraer las piezas compartidas (ChatMarkdownBody, ChatMessageFrame,

/// A long conversation: the turns above the last reach far above the
/// header.
List<Map<String, dynamic>> _history() => [
  for (var i = 0; i < 24; i++) ...[
    {
      'role': 'assistant',
      'content':
          'Respuesta $i: el contenido de esta respuesta ocupa varias líneas '
          'para que, al leer el final de la conversación, las anteriores '
          'pasen por detrás de la cabecera del chat.',
      'created_at': 1700000000 - i * 20,
    },
    {
      'role': 'user',
      'content': 'Pregunta $i del usuario',
      'created_at': 1700000000 - i * 20 - 10,
    },
  ],
];

final String? _out = Platform.environment['CHAT_GLASS_CAPTURE_DIR'];

/// The header's button left of the island, whichever the layout shows.
const _leftButtons = [
  'chat-menu-button',
  'chat-list-toggle',
  'floating-header-back',
];

/// The app's fonts, for frames that read as the app does.
Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    final bytes = file.readAsBytesSync();
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }

  for (final family in const ['Inter', 'Montserrat', 'Nunito']) {
    await load(family, 'assets/fonts/$family.ttf');
  }
  await load('JetBrainsMono', 'assets/fonts/JetBrainsMono.ttf');
  final flutter = Platform.environment['FLUTTER_ROOT'];
  if (flutter != null) {
    await load(
      'MaterialIcons',
      '$flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};
  final root = GlobalKey();

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
    final support = Directory.systemTemp.createTempSync('main-chat-baseline-');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => support.path);
    addTearDown(() {
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null);
      if (support.existsSync()) support.deleteSync(recursive: true);
    });
  });

  tearDown(() => FrostedBackdropPolicy.blurAllowed.value = true);

  Future<void> pumpChat(WidgetTester tester, {required bool glass}) async {
    FrostedBackdropPolicy.blurAllowed.value = glass;
    tester.platformDispatcher.localesTestValue = [const Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final prefs = await SharedPreferences.getInstance();
    final connectionManager = await ConnectionManager.create(prefs);
    final secureStorage = SecureStorage();
    final activeChats = ActiveChatService();
    final connection = _connection();
    final chat = activeChats.attach(
      connection: connection,
      sessionId: 'sess-md-baseline',
      sessionTitle: 'Baseline markdown',
      api: _safeApi(),
      desktopGateway: _IdleGateway(),
      disableForegroundKeepAlive: true,
    );
    chat
      ..internalMessagesForTesting = _history()
      ..messagesLoaded = true;

    await tester.pumpWidget(
      RepaintBoundary(
        key: root,
        child: HermesApp(
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
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    final navigatorContext = tester.element(find.byType(Navigator).first);
    unawaited(
      Navigator.of(navigatorContext).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              ChatScreen(connection: connection, session: _session()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  /// The header's band beside the island: from the button on its left to
  /// the island, as tall as the island (a line of text crosses it), and
  /// clear of the island's shadow in the chrome of before.
  Rect band(WidgetTester tester) {
    final island = tester.getRect(find.byType(IslandSurface).first);
    Finder? left;
    for (final key in _leftButtons) {
      final finder = find.byKey(ValueKey(key));
      if (finder.evaluate().isNotEmpty) left = finder;
    }
    final button = tester.getRect(left!);
    return Rect.fromLTRB(
      button.right + 4,
      island.top,
      island.left - 24,
      island.bottom,
    );
  }

  /// The spread of brightness in [area] of the screen: a band with text
  /// behind it varies; a solid one does not.
  Future<int> spread(WidgetTester tester, Rect area, String? name) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(root),
    );
    final result = await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final out = _out;
      if (out != null && name != null) {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$out/$name.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(png!.buffer.asUint8List());
      }
      var low = 255;
      var high = 0;
      for (var y = area.top.round(); y < area.bottom.round(); y++) {
        for (var x = area.left.round(); x < area.right.round(); x++) {
          final i = (y * image.width + x) * 4;
          final r = bytes!.getUint8(i);
          final g = bytes.getUint8(i + 1);
          final b = bytes.getUint8(i + 2);
          final lum = (r * 54 + g * 183 + b * 19) >> 8;
          if (lum < low) low = lum;
          if (lum > high) high = lum;
        }
      }
      image.dispose();
      return high - low;
    });
    return result!;
  }

  testWidgets('with the glass, the turns under the header show between its '
      'pieces', (tester) async {
    if (_out != null) await tester.runAsync(_loadFonts);
    await pumpChat(tester, glass: true);
    final area = band(tester);
    expect(area.width, greaterThan(8), reason: 'room beside the island');
    expect(
      await spread(tester, area, 'chat-header-glass'),
      greaterThan(24),
      reason: 'text passes behind the header, faded',
    );
    await unmount(tester);
  });

  testWidgets('without blur (the chrome of before), a solid band hides them: '
      'what the Fold showed', (tester) async {
    if (_out != null) await tester.runAsync(_loadFonts);
    await pumpChat(tester, glass: false);
    expect(
      await spread(tester, band(tester), 'chat-header-before'),
      lessThan(8),
    );
    await unmount(tester);
  });
}
