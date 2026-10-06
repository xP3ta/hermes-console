import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/room/room_gateway.dart';
import 'package:hermes_android/core/bots/ui/room/room_models.dart';
import 'package:hermes_android/core/bots/ui/room/room_widgets.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/artifact_export_service.dart';
import 'package:hermes_android/core/services/generated_media_service.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// Room attachment actions backed by a cache, like the Dashboard ones.
final class _CachedActions
    implements RoomAttachmentActions, RoomAttachmentCache {
  _CachedActions({this.cached, this.fetchGate});
  final File? cached;
  final Future<File>? fetchGate;
  final List<String> fetches = [];
  final List<String> prefetches = [];

  @override
  File? cachedFile(RoomAttachmentRef ref) => cached;
  @override
  void prefetch(RoomAttachmentRef ref) => prefetches.add(ref.name);
  @override
  bool canFetch(RoomAttachmentRef ref) => true;
  @override
  Future<File> fetch(RoomAttachmentRef ref) {
    fetches.add(ref.name);
    return fetchGate ?? Future<File>.value(cached ?? File('/nope'));
  }

  @override
  Future<void> open(RoomAttachmentRef ref, File file) async {}
  @override
  Future<void> share(RoomAttachmentRef ref, File file) async {}
  @override
  Future<ArtifactSaveResult> save(RoomAttachmentRef ref, File file) async =>
      ArtifactSaveResult.saved;
}

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  home: Scaffold(
    body: SingleChildScrollView(child: SizedBox(width: 360, child: child)),
  ),
);

const _ref = RoomAttachmentRef(name: 'render.png', path: '/srv/out/render.png');

void main() {
  late Directory temp;
  late File photo;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('room-media-prefetch-');
    photo = File('${temp.path}/render.png')
      ..writeAsBytesSync(<int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  });

  tearDown(() {
    GeneratedMediaService.cacheRootForTesting = null;
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  testWidgets('a cached room image paints on its first frame with no fetch', (
    tester,
  ) async {
    final actions = _CachedActions(cached: photo);
    await tester.pumpWidget(
      _host(
        RoomAttachmentCard(
          key: const ValueKey('room-card'),
          attachment: _ref,
          actions: actions,
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('room-attachment-media-/srv/out/render.png')),
      findsOneWidget,
    );
    expect(actions.fetches, isEmpty);
  });

  testWidgets('a loading room image reserves the preview box: no jump', (
    tester,
  ) async {
    final gate = Completer<File>();
    final actions = _CachedActions(fetchGate: gate.future);
    await tester.pumpWidget(
      _host(
        RoomAttachmentCard(
          key: const ValueKey('room-card'),
          attachment: _ref,
          actions: actions,
        ),
      ),
    );
    await tester.pump();
    final loading = tester.getSize(find.byKey(const ValueKey('room-card')));
    expect(
      find.byKey(
        const ValueKey('room-attachment-skeleton-/srv/out/render.png'),
      ),
      findsOneWidget,
    );
    gate.complete(photo);
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('room-attachment-media-/srv/out/render.png')),
      findsOneWidget,
    );
    expect(tester.getSize(find.byKey(const ValueKey('room-card'))), loading);
  });

  test('Dashboard room actions read the private cache synchronously', () async {
    final connection = SavedConnection(
      id: 'room-conn',
      label: 'Room host',
      host: 'hermes.example.test',
      port: 443,
      apiKey: 'test-key',
      useHttps: true,
    );
    final dashboard = DashboardRoomAttachmentActions(
      connection: connection,
      profile: 'ops',
    );
    final reference = GeneratedMediaService.referenceFromSource(_ref.path)!;
    expect(dashboard.cachedFile(_ref), isNull);
    final file = await GeneratedMediaService.ensureDownloaded(
      'room-conn\u0000ops',
      reference,
      fetchServerPath: (_) async => photo.readAsBytesSync(),
      baseDir: temp,
    );
    GeneratedMediaService.cacheRootForTesting = temp;
    expect(dashboard.cachedFile(_ref)?.path, file.path);
  });
}
