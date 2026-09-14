import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

AttachmentDraft _attachment(String path) => AttachmentDraft(
  localId: 'attachment',
  type: AttachmentType.document,
  name: 'private.txt',
  mimeType: 'text/plain',
  sizeBytes: 1,
  localPath: path,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secure = <String, String>{};
  setUp(() async {
    TurnOutboxStore.resetSerializationForTesting();
    secure.clear();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            if (call.method == 'readAll') return Map<String, String>.of(secure);
            return null;
          },
        );
  });

  test('releasing a transfer reservation does not invent retirement', () async {
    final attachment = _attachment('/private/retry.txt');
    final reservation = AttachmentOwnershipCoordinator.reservePendingOwner([
      attachment,
    ]);
    final retired = <AttachmentDraft>[];

    await AttachmentOwnershipCoordinator.withdrawPendingOwner(
      reservation,
      (items) async => retired.addAll(items),
    );

    expect(retired, isEmpty);
    expect(AttachmentOwnershipCoordinator.hasPendingOwner(attachment), isFalse);
  });

  test('producer retention blocks retirement until explicit release', () async {
    final attachment = _attachment('/private/composer.txt');
    final producer = AttachmentOwnershipCoordinator.retainProducer([
      attachment,
    ]);
    final retired = <AttachmentDraft>[];
    Future<void> cleanup(List<AttachmentDraft> items) async {
      retired.addAll(items);
    }

    AttachmentOwnershipCoordinator.deferCleanup(attachment, cleanup);
    expect(retired, isEmpty);
    await AttachmentOwnershipCoordinator.releaseProducer(producer, cleanup);

    expect(retired, [attachment]);
    expect(AttachmentOwnershipCoordinator.hasPendingOwner(attachment), isFalse);
  });

  test('two producers retain independently', () async {
    final attachment = _attachment('/private/shared.txt');
    final first = AttachmentOwnershipCoordinator.retainProducer([attachment]);
    final second = AttachmentOwnershipCoordinator.retainProducer([attachment]);
    final retired = <AttachmentDraft>[];
    Future<void> cleanup(List<AttachmentDraft> items) async {
      retired.addAll(items);
    }

    AttachmentOwnershipCoordinator.deferCleanup(attachment, cleanup);
    await AttachmentOwnershipCoordinator.releaseProducer(first, cleanup);
    expect(retired, isEmpty);
    await AttachmentOwnershipCoordinator.releaseProducer(second, cleanup);
    expect(retired, [attachment]);
  });

  test('legacy V1 references participate in the common inventory', () async {
    final attachment = _attachment('/private/legacy.txt');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'chat_draft_v1_legacy',
      jsonEncode({
        'text': 'retained',
        'attachments': [attachment.toJson()],
      }),
    );

    final inventory =
        await AttachmentOwnershipCoordinator.loadDurableReferences(
          const FlutterSecureStorage(),
          preferences: prefs,
        );

    expect(inventory, isNotNull);
    expect(
      inventory!.any(
        (value) => AttachmentOwnershipCoordinator.durableReferencesAttachment(
          value,
          attachment,
        ),
      ),
      isTrue,
    );
  });

  test('corrupt relevant secure inventory fails closed', () async {
    secure['chat_turn_outbox_v1'] = '{not-json';
    expect(
      await AttachmentOwnershipCoordinator.loadDurableReferences(
        const FlutterSecureStorage(),
      ),
      isNull,
    );
  });
}
