// SFTP downloads (orden DESCARGAS-DIRECTAS, point 2): the notification of a
// finished download offers Abrir, Compartir and Guardar otra copia… of the
// document the user chose. Its payload carries that document's
// `content://` Uri and a name the app could suggest, never a path or a
// file, and only that destination.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';

const _doc =
    'content://com.android.externalstorage.documents/document/primary%3ADownload%2Finforme.pdf';

void main() {
  test('a finished download round-trips to its document', () {
    const open = NotificationOpen(
      connId: 'c1',
      downloadUri: _doc,
      downloadName: 'informe (1).pdf',
    );
    final back = NotificationOpen.tryParse(open.toPayload());
    expect(back, isNotNull);
    expect(back!.connId, 'c1');
    expect(back.downloadUri, _doc);
    expect(back.downloadName, 'informe (1).pdf');
    expect(back.sessionId, isEmpty);
    expect(back.taskId, isNull);
  });

  test('only a document Uri of a provider is accepted', () {
    for (final bad in [
      '/data/user/0/app/files/x.pdf',
      'file:///sdcard/Download/x.pdf',
      'https://example.com/x.pdf',
      'content://',
      'content:///no-authority',
      'content://a/b c',
      'content://a/b\u0000',
      '../x',
      'content://a/${'x' * 2050}',
    ]) {
      expect(
        NotificationOpen.tryParse(
          jsonEncode({'conn': 'c1', 'dl': bad, 'dln': 'x.pdf'}),
        ),
        isNull,
        reason: jsonEncode(bad),
      );
    }
    expect(
      NotificationOpen.tryParse(
        jsonEncode({'conn': 'c1', 'dl': 3, 'dln': 'x.pdf'}),
      ),
      isNull,
    );
  });

  test('only a name the app could suggest is accepted', () {
    for (final bad in ['../x', '/etc/passwd', 'a/b', '..', 'x\u0000', '']) {
      expect(
        NotificationOpen.tryParse(
          jsonEncode({'conn': 'c1', 'dl': _doc, 'dln': bad}),
        ),
        isNull,
        reason: jsonEncode(bad),
      );
    }
    expect(
      NotificationOpen.tryParse(jsonEncode({'conn': 'c1', 'dl': _doc})),
      isNull,
    );
    expect(
      NotificationOpen.tryParse(
        jsonEncode({'conn': 'c1', 'dl': _doc, 'dln': 3}),
      ),
      isNull,
    );
    // A name without its document says nothing.
    expect(
      NotificationOpen.tryParse(
        jsonEncode({'conn': 'c1', 'sid': 's1', 'dln': 'a.txt'}),
      ),
      isNull,
    );
  });

  test('a download is the only destination of its notification', () {
    expect(
      NotificationOpen.tryParse(
        jsonEncode({'conn': 'c1', 'sid': 's1', 'dl': _doc, 'dln': 'a.txt'}),
      ),
      isNull,
    );
    // The chat notifications are read as before.
    final chat = NotificationOpen.tryParse(
      jsonEncode({'conn': 'c1', 'sid': 's1'}),
    );
    expect(chat!.downloadUri, isNull);
    expect(chat.downloadName, isNull);
    expect(chat.sessionId, 's1');
  });
}
