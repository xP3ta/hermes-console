// sa1215: the chat menu opens «Artefactos» (Desktop's Artifacts view) with
// what the loaded transcript shared, including tool deliveries that never
// render as text.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/screens/chat_content_screen.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/attachment_uploader.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/theme/hermes_style.dart';
import 'package:hermes_android/core/widgets/media_viewer/media_viewer.dart';
import 'package:hermes_android/core/widgets/user_server_attachment_card.dart';
import 'package:hermes_android/main.dart';
import 'support/test_api_client.dart';

SavedConnection _connection() => SavedConnection(
  id: 'conn-chat-content',
  label: 'Chat content',
  host: '192.168.255.254',
  port: 8642,
  apiKey: 'test-key',
  dashboardUrl: 'http://127.0.0.1:9119',
);

Session _session() => Session(
  id: 'sess-chat-content',
  title: 'Contenido del chat',
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

/// Newest first, as ActiveChat stores it internally.
List<Map<String, dynamic>> _history() => [
  {
    'role': 'assistant',
    'content': 'Te dejo la guía: https://example.com/docs/guia',
    'timestamp': 1781774300,
  },
  {
    'role': 'tool',
    'tool_name': 'image_generate',
    'tool_call_id': 'call-img',
    'content': jsonEncode({'image': 'https://cdn.example.com/gen/gato.png'}),
    'timestamp': 1781774250,
  },
  {
    'role': 'assistant',
    'content': '',
    'tool_calls': [
      {
        'id': 'call-img',
        'type': 'function',
        'function': {'name': 'image_generate', 'arguments': '{}'},
      },
    ],
    'timestamp': 1781774200,
  },
  {
    'role': 'user',
    'content': 'Hazme un gato\n@file:/home/u/.hermes/uploads/brief.pdf',
    'timestamp': 1781774100,
  },
];

/// The sheet builds rows lazily and the workspace row and Search sit above
/// the grid, so drag the sheet list until [target] is built and inside it.
Future<void> _scrollSheetTo(WidgetTester tester, Finder target) async {
  final list = find.byKey(const ValueKey('chat-control-sheet'));
  for (var i = 0; i < 20; i++) {
    if (target.evaluate().isNotEmpty &&
        tester.getRect(list).contains(tester.getCenter(target))) {
      return;
    }
    await tester.drag(list, const Offset(0, -80));
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureStore = <String, String>{};

  void mockChannel(String name) {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }

  tearDown(() => HermesStylePrefs.debugUse(null));

  setUp(() {
    // These tests read titles as written; Contour upper-cases them.
    HermesStylePrefs.debugUse(HermesStylePrefs.inMemory(HermesStyle.soft));
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
  });

  Future<ActiveChat> pumpChat(
    WidgetTester tester, {
    List<Map<String, dynamic>>? history,
    ApiClient? api,
    bool messagesLoaded = true,
    Future<void> Function(String path, File destination)?
    userServerMediaFetcher,
  }) async {
    tester.platformDispatcher.localesTestValue = [const Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    tester.view
      ..physicalSize = const Size(1080, 2280)
      ..devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final prefs = await SharedPreferences.getInstance();
    final connectionManager = await ConnectionManager.create(prefs);
    final secureStorage = SecureStorage();
    final activeChats = ActiveChatService(attachDesktopRuntimeOnLoad: false);
    addTearDown(activeChats.dispose);
    final connection = _connection();
    final chat = activeChats.attach(
      connection: connection,
      sessionId: _session().id,
      sessionTitle: _session().title,
      api: api ?? _safeApi(),
      attachDesktopRuntimeOnLoad: false,
      allowUnownedDesktopSnapshotForTesting: messagesLoaded,
      transcriptPageSizeForTesting: 120,
    );
    if (history != null) chat.internalMessagesForTesting = history;
    chat.messagesLoaded = messagesLoaded;

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
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 500));

    final navigatorContext = tester.element(find.byType(Navigator).first);
    Navigator.of(navigatorContext).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          connection: connection,
          session: _session(),
          userServerMediaFetcher: userServerMediaFetcher,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    return chat;
  }

  testWidgets('el menú del chat abre Artefactos con su contenido', (
    tester,
  ) async {
    await pumpChat(tester, history: _history());
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byKey(const ValueKey('chat-settings-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final entry = find.byKey(const ValueKey('chat-control-content'));
    await _scrollSheetTo(tester, entry);
    expect(
      find.descendant(of: entry, matching: find.text('Artefactos')),
      findsOneWidget,
    );
    // One entry, as Desktop: the empty second artifacts sheet is gone.
    expect(find.byKey(const ValueKey('chat-control-artifacts')), findsNothing);
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byType(ChatContentScreen), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ChatContentScreen),
        matching: find.text('Artefactos'),
      ),
      findsOneWidget,
    );
    for (final label in ['guia', 'gato.png', 'brief.pdf']) {
      expect(
        find.byKey(ValueKey('sa1215-item-$label')),
        findsOneWidget,
        reason: label,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the bubble hides the context Hermes attaches for the model', (
    tester,
  ) async {
    // agent/context_references.py: expand_context_references keeps the
    // `@file:` token the user sent and appends `--- Attached Context ---`;
    // _binary_reference_block writes the note for a file it did not inline.
    final temp = Directory.systemTemp.createTempSync('attached-context-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => temp.path);
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );
    const path = '/home/u/.hermes/attachments/3f2a9c.jpg';
    const block =
        '\n\n--- Attached Context ---\n\n'
        '📎 @file:$path (image/jpeg, 67.6 KB) — binary file, not inlined as '
        'text. It is available on disk at `$path`. Use your tools to work '
        'with it (read or convert it, extract its text, or view/render it as '
        'needed); do not tell the user the file type is unsupported.';
    await pumpChat(
      tester,
      history: [
        {'role': 'assistant', 'content': 'Recibido.'},
        {
          'role': 'user',
          // An older backend stripped the token from the prose.
          'content': 'Y esta otra$block',
          'timestamp': 1781774400,
        },
        {'role': 'assistant', 'content': 'Hola.'},
        {
          'role': 'user',
          'content': 'Mira esta foto\n@file:$path$block',
          'timestamp': 1781774300,
        },
      ],
      // The server copy is out of reach here; failing at once frees the
      // shared fetch slots for the tests that follow.
      userServerMediaFetcher: (_, _) async =>
          throw const FileSystemException('offline'),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.textContaining('Attached Context', findRichText: true),
      findsNothing,
    );
    expect(
      find.textContaining('not inlined', findRichText: true),
      findsNothing,
    );
    expect(
      find.textContaining('do not tell the user', findRichText: true),
      findsNothing,
    );
    expect(
      find.textContaining('/home/u/.hermes', findRichText: true),
      findsNothing,
    );
    // What the user wrote stays.
    expect(
      find.textContaining('Mira esta foto', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('Y esta otra', findRichText: true),
      findsOneWidget,
    );
    // Each message still shows its attachment, once.
    expect(find.byType(UserServerAttachmentCard), findsNWidgets(2));
    for (var frame = 0; frame < 10; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('an image turn shows its image and none of the hints Hermes '
      'stored with it', (tester) async {
    final temp = Directory.systemTemp.createTempSync('image-hints-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => temp.path);
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );
    // Console's own send keeps a private copy of the picture and names it
    // in the text it sends (ChatScreen `_send`).
    late final AttachmentHistoryReference copy;
    await tester.runAsync(() async {
      final picked = File('${temp.path}/IMG_20261120.jpg');
      await picked.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDw'
          'AChwGA60e6kgAAAABJRU5ErkJggg==',
        ),
      );
      copy = (await AttachmentUploader.persistForHistory(
        AttachmentDraft(
          type: AttachmentType.image,
          name: 'IMG_20261120.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: await picked.length(),
          localPath: picked.path,
        ),
        index: 0,
        baseDir: temp,
      ))!;
    });
    // agent/image_routing.py build_native_content_parts writes the caption,
    // a blank line and one hint per image; the session store writes each
    // image part as a `[screenshot]` line after it.
    await pumpChat(
      tester,
      history: [
        {'role': 'assistant', 'content': 'Veo un cuaderno.'},
        {
          // Quoted in the caption, the same words are the user's.
          'role': 'user',
          'content': 'Escribe tal cual [Image attached at: x] y nada más',
          'timestamp': 1781774500,
        },
        {'role': 'assistant', 'content': 'Dos fotos de la playa.'},
        {
          // Two images, from any client.
          'role': 'user',
          'content':
              'Compara estas dos\n\n'
              '[Image attached at: /home/u/.hermes/images/upload_a.jpg]\n'
              '[Image attached at: /home/u/.hermes/images/upload b.png]\n'
              '[screenshot]\n'
              '[screenshot]',
          'timestamp': 1781774400,
        },
        {'role': 'assistant', 'content': 'Una mesa.'},
        {
          // Console's own send (Files, gallery and camera share it): its
          // attachment line, the caption, its copy's marker, then what
          // Hermes added.
          'role': 'user',
          'content':
              '[📎 IMG_20261120.jpg · 1.2 MB]\n'
              'PRUEBA J1. Di en una frase que ves en la imagen.\n'
              '${copy.toMarker()}\n\n'
              '[Image attached at: '
              '/home/u/.hermes/images/upload_qa1.jpg]\n'
              '[screenshot]',
          'timestamp': 1781774300,
        },
      ],
      userServerMediaFetcher: (_, _) async =>
          throw const FileSystemException('offline'),
    );
    // Room for the three turns at once.
    tester.view.physicalSize = const Size(1080, 7200);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.textContaining('PRUEBA J1', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('Compara estas dos', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('upload_qa1', findRichText: true),
      findsNothing,
    );
    expect(
      find.textContaining('[screenshot]', findRichText: true),
      findsNothing,
    );
    expect(
      find.textContaining('Image attached at: /home', findRichText: true),
      findsNothing,
    );
    expect(
      find.textContaining(
        'Escribe tal cual [Image attached at: x] y nada más',
        findRichText: true,
      ),
      findsOneWidget,
    );
    // One image for Console's send (its line and Hermes' path are the same
    // image), two for the other turn.
    final cards = tester
        .widgetList<UserServerAttachmentCard>(
          find.byType(UserServerAttachmentCard),
        )
        .toList();
    expect(
      cards.map((card) => card.serverRef.path),
      unorderedEquals([
        '/home/u/.hermes/images/upload_qa1.jpg',
        '/home/u/.hermes/images/upload_a.jpg',
        '/home/u/.hermes/images/upload b.png',
      ]),
    );
    expect(cards.every((card) => card.serverRef.isImage), isTrue);
    final sent = cards.singleWhere(
      (card) => card.serverRef.path.endsWith('upload_qa1.jpg'),
    );
    expect(sent.name, 'IMG_20261120.jpg');
    expect(sent.localReference?.storageKey, copy.storageKey);
    for (var frame = 0; frame < 10; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('una imagen adjunta en el servidor se abre en el visor', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('sa1215-media-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => temp.path);
    addTearDown(
      () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null),
    );
    const serverPath = '/home/u/.hermes/images/plano.png';
    final fetched = <String>[];
    await pumpChat(
      tester,
      history: [
        {'role': 'assistant', 'content': 'Recibido.'},
        {
          'role': 'user',
          'content': 'Revisa el plano\n@image:$serverPath',
          'timestamp': 1781774300,
        },
      ],
      userServerMediaFetcher: (path, destination) async {
        fetched.add(path);
        await destination.writeAsBytes(base64Decode(_pngBase64));
      },
    );
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byKey(const ValueKey('chat-settings-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final entry = find.byKey(const ValueKey('chat-control-content'));
    await _scrollSheetTo(tester, entry);
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(find.byKey(const ValueKey('sa1215-item-plano.png')));
    for (var frame = 0; frame < 40; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(fetched.last, serverPath);
    final viewer = find.byType(MediaViewerScreen);
    expect(viewer, findsOneWidget);
    expect(
      find.descendant(of: viewer, matching: find.byType(InteractiveViewer)),
      findsOneWidget,
    );
  });
}

const _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
