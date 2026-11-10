// Pictures of the launcher widgets, for the eye and against regressions.
//
// Each case is drawn at density 2 and compared with its golden under
// `test/goldens/launcher_widgets/` with a tolerance (text rasterisation
// differs a little between engines; the geometry is proved exactly by
// launcher_widget_raster_test.dart). Every drawing is also written to
// `build/lw-evidence/` to be looked at.
//
// To regenerate these goldens (and only these), without extra fonts as the
// gate runs them (see the script):
//   tool/qa/launcher_widget_goldens.sh
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show decodeImageFromList;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_painter.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_raster.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_scene.dart';

import 'launcher_widget_fixtures.dart';

/// The share of pixels that may differ before a golden fails.
const _tolerance = 0.06;

class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile);

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= _tolerance) return true;
    throw TestFailure(
      'Golden "$golden": ${(result.diffPercent * 100).toStringAsFixed(2)}% '
      'of pixels differ (tolerance ${(_tolerance * 100).toStringAsFixed(0)}%). '
      'If the change is wanted: flutter test --update-goldens '
      'test/launcher_widget_golden_test.dart',
    );
  }
}

class _Case {
  const _Case(
    this.name,
    this.subject,
    this.mood,
    this.size, {
    this.theme = 0,
    this.fontScale = 1.0,
    this.locale = 'es',
    this.data = LwData.plain,
  });
  final String name;
  final LwSubject subject;
  final String mood;
  final ui.Size size;
  final int theme;
  final double fontScale;
  final String locale;
  final LwData data;
}

List<_Case> _cases() {
  const full = [
    ('ahora-need-4x2', LwSubject.ahora, 'need', ui.Size(320, 170)),
    ('ahora-need-2x2', LwSubject.ahora, 'need', ui.Size(160, 170)),
    ('ahora-need-4x1', LwSubject.ahora, 'need', ui.Size(320, 72)),
    ('ahora-ask-2x2', LwSubject.ahora, 'ask', ui.Size(160, 170)),
    ('ahora-work-2x2', LwSubject.ahora, 'work', ui.Size(160, 170)),
    ('ahora-calm-4x2', LwSubject.ahora, 'calm', ui.Size(320, 170)),
    ('ahora-offline-4x2', LwSubject.ahora, 'offline', ui.Size(320, 170)),
    ('ahora-setup-2x2', LwSubject.ahora, 'setup', ui.Size(160, 170)),
    ('chats-live-4x2', LwSubject.chats, 'rows-live', ui.Size(320, 170)),
    ('chats-rows-4x4', LwSubject.chats, 'rows', ui.Size(320, 360)),
    ('chats-empty-4x2', LwSubject.chats, 'empty', ui.Size(320, 170)),
    ('cron-next-2x2', LwSubject.cron, 'next', ui.Size(160, 170)),
    ('cron-next-4x2', LwSubject.cron, 'next', ui.Size(320, 170)),
    ('cron-failed-2x2', LwSubject.cron, 'failed', ui.Size(160, 170)),
    ('tasks-counts-4x2', LwSubject.tasks, 'counts', ui.Size(320, 170)),
    ('tasks-counts-2x2', LwSubject.tasks, 'counts', ui.Size(160, 170)),
    ('new-ready-2x1', LwSubject.newChat, 'ready', ui.Size(160, 72)),
    ('new-ready-2x2', LwSubject.newChat, 'ready', ui.Size(160, 170)),
  ];
  const brief = [
    ('ahora-need-4x2', LwSubject.ahora, 'need', ui.Size(320, 170)),
    ('ahora-work-2x2', LwSubject.ahora, 'work', ui.Size(160, 170)),
    ('ahora-calm-4x2', LwSubject.ahora, 'calm', ui.Size(320, 170)),
    ('ahora-offline-4x2', LwSubject.ahora, 'offline', ui.Size(320, 170)),
    ('chats-live-4x2', LwSubject.chats, 'rows-live', ui.Size(320, 170)),
    ('cron-next-4x2', LwSubject.cron, 'next', ui.Size(320, 170)),
    ('tasks-counts-4x2', LwSubject.tasks, 'counts', ui.Size(320, 170)),
    ('new-ready-2x2', LwSubject.newChat, 'ready', ui.Size(160, 170)),
  ];
  return [
    for (final (name, subject, mood, size) in full)
      _Case('console-dark/$name', subject, mood, size),
    for (var theme = 1; theme < lwThemes.length; theme++)
      for (final (name, subject, mood, size) in brief)
        _Case('${lwThemes[theme].id}/$name', subject, mood, size, theme: theme),
    // Twice the system font size, in the tight sizes.
    const _Case(
      'console-dark/x2/ahora-need-2x2',
      LwSubject.ahora,
      'need',
      ui.Size(140, 140),
      fontScale: 2,
    ),
    const _Case(
      'console-dark/x2/ahora-need-4x2',
      LwSubject.ahora,
      'need',
      ui.Size(320, 170),
      fontScale: 2,
    ),
    const _Case(
      'console-dark/x2/chats-live-4x2',
      LwSubject.chats,
      'rows-live',
      ui.Size(320, 170),
      fontScale: 2,
    ),
    const _Case(
      'console-dark/x2/cron-next-2x2',
      LwSubject.cron,
      'next',
      ui.Size(140, 140),
      fontScale: 2,
    ),
    const _Case(
      'console-dark/x2/tasks-counts-2x2',
      LwSubject.tasks,
      'counts',
      ui.Size(140, 140),
      fontScale: 2,
    ),
    const _Case(
      'console-dark/x2/new-ready-2x1',
      LwSubject.newChat,
      'ready',
      ui.Size(140, 56),
      fontScale: 2,
    ),
    // A third larger system font.
    const _Case(
      'console-dark/x1.3/ahora-need-4x2',
      LwSubject.ahora,
      'need',
      ui.Size(320, 170),
      fontScale: 1.3,
    ),
    const _Case(
      'console-dark/x1.3/cron-next-2x2',
      LwSubject.cron,
      'next',
      ui.Size(160, 170),
      fontScale: 1.3,
    ),
    const _Case(
      'midnight-dark/x1.3/chats-live-4x2',
      LwSubject.chats,
      'rows-live',
      ui.Size(320, 170),
      theme: 2,
      fontScale: 1.3,
    ),
    // More states and spans.
    const _Case(
      'console-dark/ahora-work-4x2',
      LwSubject.ahora,
      'work',
      ui.Size(320, 170),
    ),
    const _Case(
      'console-dark/ahora-calm-2x1',
      LwSubject.ahora,
      'calm',
      ui.Size(160, 72),
    ),
    const _Case(
      'console-dark/chats-offline-4x2',
      LwSubject.chats,
      'offline',
      ui.Size(320, 170),
    ),
    const _Case(
      'console-dark/cron-next-4x1',
      LwSubject.cron,
      'next',
      ui.Size(320, 72),
    ),
    const _Case(
      'console-dark/tasks-offline-4x2',
      LwSubject.tasks,
      'offline',
      ui.Size(320, 170),
    ),
    const _Case(
      'console-light/hostile/ahora-need-4x2',
      LwSubject.ahora,
      'need',
      ui.Size(320, 170),
      theme: 1,
      data: LwData.hostile,
    ),
    const _Case(
      'midnight-light/hostile/chats-rows-4x4',
      LwSubject.chats,
      'rows',
      ui.Size(290, 310),
      theme: 3,
      data: LwData.hostile,
    ),
    // Data made to break a layout.
    const _Case(
      'console-dark/hostile/ahora-need-4x2',
      LwSubject.ahora,
      'need',
      ui.Size(320, 170),
      data: LwData.hostile,
    ),
    const _Case(
      'console-dark/hostile/ahora-need-2x2',
      LwSubject.ahora,
      'need',
      ui.Size(140, 140),
      data: LwData.hostile,
    ),
    const _Case(
      'console-dark/hostile/chats-rows-4x2',
      LwSubject.chats,
      'rows',
      ui.Size(290, 140),
      data: LwData.hostile,
    ),
    const _Case(
      'console-dark/hostile/cron-next-2x2',
      LwSubject.cron,
      'next',
      ui.Size(140, 140),
      data: LwData.hostile,
    ),
    const _Case(
      'console-dark/hostile/tasks-counts-4x2',
      LwSubject.tasks,
      'counts',
      ui.Size(290, 140),
      data: LwData.hostile,
    ),
    const _Case(
      'console-dark/rtl/ahora-need-4x2',
      LwSubject.ahora,
      'need',
      ui.Size(320, 170),
      data: LwData.rtl,
    ),
    const _Case(
      'console-dark/rtl/chats-rows-4x2',
      LwSubject.chats,
      'rows',
      ui.Size(320, 170),
      data: LwData.rtl,
    ),
    // Other languages (wide German, tall scripts).
    const _Case(
      'console-dark/de/ahora-need-4x2',
      LwSubject.ahora,
      'need',
      ui.Size(320, 170),
      locale: 'de',
    ),
    const _Case(
      'console-dark/de/tasks-counts-4x2',
      LwSubject.tasks,
      'counts',
      ui.Size(290, 140),
      locale: 'de',
    ),
    const _Case(
      'console-dark/ja/ahora-need-4x2',
      LwSubject.ahora,
      'need',
      ui.Size(320, 170),
      locale: 'ja',
    ),
    const _Case(
      'console-dark/zh/cron-next-4x2',
      LwSubject.cron,
      'next',
      ui.Size(320, 170),
      locale: 'zh',
    ),
    const _Case(
      'console-dark/en/ahora-setup-4x2',
      LwSubject.ahora,
      'setup',
      ui.Size(320, 170),
      locale: 'en',
    ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await lwLoadFonts();
    goldenFileComparator = _TolerantComparator(
      Uri.file(
        '${Directory.current.path}/test/launcher_widget_golden_test.dart',
      ),
    );
    await Directory('build/lw-evidence').create(recursive: true);
  });

  for (final c in _cases()) {
    test(c.name, () async {
      final theme = lwThemes[c.theme];
      final frame = paintLauncherWidget(
        LwPaintRequest(
          subject: c.subject,
          scene: lwScene(c.subject, c.mood, c.data),
          sizeDp: c.size,
          palette: theme.palette,
          words: lwWords(c.locale, use24h: c.data.use24h),
          fontScale: c.fontScale,
          instanceId: 'home',
        ),
      );
      final rendered = (await lwRenderPng(frame, density: 2))!;
      frame.dispose();
      expect(rendered.widthPx, (c.size.width * 2).round());
      expect(rendered.heightPx, (c.size.height * 2).round());
      final evidence = File(
        'build/lw-evidence/${c.name.replaceAll('/', '_')}.png',
      );
      await evidence.writeAsBytes(rendered.png, flush: true);
      final image = await decodeImageFromList(rendered.png);
      await expectLater(
        image,
        matchesGoldenFile('goldens/launcher_widgets/${c.name}.png'),
      );
      image.dispose();
    });
  }
}
