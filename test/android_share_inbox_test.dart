import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/android_share_inbox.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final secureValues = <String, String>{};
  late File sharedImage;

  setUp(() async {
    secureValues.clear();
    sharedImage = File(
      '${Directory.systemTemp.path}/hermes-share-'
      '${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await sharedImage.writeAsBytes([1, 2, 3, 4]);

    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                secureValues[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secureValues[args['key'] as String];
              case 'delete':
                secureValues.remove(args['key'] as String);
                return null;
              case 'readAll':
                return Map<String, String>.from(secureValues);
            }
            return null;
          },
        );
  });

  tearDown(() async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('hermes/share'), null);
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
    if (await sharedImage.exists()) await sharedImage.delete();
  });

  test('convierte ACTION_SEND en una bandeja cifrada y recuperable', () async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('hermes/share'), (
          call,
        ) async {
          expect(call.method, 'takePendingShare');
          return {
            'id': 'share-1',
            'text': 'https://example.com/noticia',
            'attachments': [
              {
                'type': 'image',
                'name': 'captura.jpg',
                'mime_type': 'image/jpeg',
                'size_bytes': 4,
                'local_path': sharedImage.path,
              },
            ],
            'rejected_attachments': 0,
          };
        });

    final inbox = AndroidShareInbox();
    final pending = await inbox.initialize();

    expect(pending?.id, 'share-1');
    expect(pending?.text, 'https://example.com/noticia');
    expect(pending?.attachments.single.name, 'captura.jpg');
    expect(secureValues, hasLength(1));

    await inbox.acknowledge('share-1');
    expect(await inbox.peek(), isNull);
    expect(secureValues, isEmpty);
    await inbox.dispose();
  });

  test('descarta rutas revocadas sin perder el aviso de rechazo', () {
    final content = AndroidSharedContent.fromMap({
      'id': 'share-2',
      'text': '',
      'attachments': [
        {
          'type': 'image',
          'name': 'ya-no-existe.jpg',
          'mime_type': 'image/jpeg',
          'size_bytes': 4,
          'local_path': '${sharedImage.path}.missing',
        },
      ],
      'rejected_attachments': 1,
    });

    expect(content, isNotNull);
    expect(content?.attachments, isEmpty);
    expect(content?.rejectedAttachments, 1);
  });

  test('android-share without durable evidence is an unpersisted draft', () {
    // El caso real: la ruta de compartir sella el texto recibido en `preview`
    // antes de que exista ningún turno durable, así que solo `message_count`
    // puede demostrar persistencia.
    final session = Session.fromJson(const {
      'id': 'mob-share-draft',
      'source': 'android-share',
      'message_count': 0,
      'preview': 'texto compartido desde otra app',
    });
    expect(session.isUnpersistedMobileDraft, isTrue);
  });

  test('android-share with zero durable messages and non-mob id is '
      'unpersisted', () {
    // La importación puede abrirse antes de que exista un id canónico; sin
    // turnos durables sigue siendo un borrador, venga como venga el id.
    final session = Session.fromJson(const {
      'id': 'share-import-before-canonical-id',
      'source': 'android-share',
      'message_count': 0,
      'preview': 'texto compartido desde otra app',
    });
    expect(session.isUnpersistedMobileDraft, isTrue);
  });

  test('source matrix preserves mobile, mobile-draft, mobile-room, and '
      'mobile-bot while changing only android-share classification', () {
    Session session({
      required String id,
      required String source,
      int messageCount = 0,
      String preview = '',
    }) => Session.fromJson({
      'id': id,
      'source': source,
      'message_count': messageCount,
      'preview': preview,
    });
    final matrix = <({Session session, bool expected})>[
      (
        session: session(id: 'mob-share-provisional', source: 'android-share'),
        expected: true,
      ),
      (
        session: session(
          id: 'mob-share-shared-text',
          source: 'android-share',
          preview: 'texto compartido',
        ),
        expected: true,
      ),
      (
        session: session(
          id: 'share-import-before-canonical-id',
          source: 'android-share',
          preview: 'texto compartido',
        ),
        expected: true,
      ),
      (
        session: session(
          id: 'mob-share-durable',
          source: 'android-share',
          messageCount: 1,
          preview: 'texto compartido',
        ),
        expected: false,
      ),
      (session: session(id: 'mob-mobile', source: 'mobile'), expected: true),
      (
        session: session(id: 'mob-mobile', source: 'mobile', messageCount: 1),
        expected: false,
      ),
      (
        session: session(
          id: 'mob-mobile-preview',
          source: 'mobile',
          preview: 'ya hay turno',
        ),
        expected: false,
      ),
      (session: session(id: 'sess-mobile', source: 'mobile'), expected: false),
      (
        session: session(id: 'legacy-mobile-draft', source: 'mobile-draft'),
        expected: true,
      ),
      (
        session: session(
          id: 'sess-mobile-draft',
          source: 'mobile-draft',
          messageCount: 3,
          preview: 'borrador heredado',
        ),
        expected: true,
      ),
      (
        session: session(id: 'mob-room-room', source: 'mobile-room'),
        expected: true,
      ),
      (
        session: session(
          id: 'mob-room-room',
          source: 'mobile-room',
          messageCount: 1,
        ),
        expected: false,
      ),
      (
        session: session(id: 'mob-bot-profile', source: 'mobile-bot'),
        expected: true,
      ),
      (
        session: session(
          id: 'mob-bot-profile',
          source: 'mobile-bot',
          messageCount: 1,
        ),
        expected: false,
      ),
      (
        session: session(id: 'sess-desktop', source: 'desktop'),
        expected: false,
      ),
    ];
    expect(
      matrix.map((row) => row.session.isUnpersistedMobileDraft).toList(),
      matrix.map((row) => row.expected).toList(),
    );
  });

  test(
    'manifest y MainActivity publican el contrato Android sin permisos extra',
    () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      final activity = File(
        'android/app/src/main/kotlin/com/hermesagent/hermes_android/'
        'MainActivity.kt',
      ).readAsStringSync();

      expect(manifest, contains('android.intent.action.SEND'));
      expect(manifest, contains('android.intent.action.SEND_MULTIPLE'));
      expect(manifest, contains('android:mimeType="text/plain"'));
      expect(manifest, contains('android:mimeType="image/*"'));
      expect(
        activity,
        contains('private val shareChannelName = "hermes/share"'),
      );
      expect(activity, contains('File(cacheDir, "shared_intents")'));
      expect(activity, contains('MAX_SHARE_ITEM_BYTES'));
    },
  );
}
