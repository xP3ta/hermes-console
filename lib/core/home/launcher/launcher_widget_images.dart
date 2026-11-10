// Publishes the pictures of the launcher widgets.
//
// Android writes, on every redraw, the sizes of the widgets placed on the
// home screen ([lwSizesKey]); this publisher reads them with the snapshots
// the app already stores, draws one picture per widget and size in the
// active theme, and writes where they are ([lwImagesKey]) before asking the
// receivers to redraw. It runs only when something the app did asks for it
// (a snapshot written, a theme or text-size change, the app coming back):
// no timer, no service, no network.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:home_widget/home_widget.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/home_widget_snapshot.dart';
import '../../models/launcher_widget_chats.dart';
import '../../models/launcher_widget_cron.dart';
import '../../models/launcher_widget_tasks.dart';
import '../../theme/app_theme.dart' show HermesThemeColors;
import 'launcher_widget_geometry.dart';
import 'launcher_widget_identity.dart';
import 'launcher_widget_painter.dart';
import 'launcher_widget_palette.dart';
import 'launcher_widget_raster.dart';
import 'launcher_widget_scene.dart';
import 'launcher_widget_words.dart';

/// Written by Android: the sizes of the placed widgets, per subject.
const lwSizesKey = 'hermes_widget_lw_sizes_v1';

/// Written here: where each picture is, with its zones and description.
const lwImagesKey = 'hermes_widget_lw_images_v1';
const lwImagesSchema = 1;

/// Android receivers, by subject.
const lwProviders = <LwSubject, List<String>>{
  LwSubject.ahora: ['com.hermesagent.hermes_android.NewSessionWidgetProvider'],
  LwSubject.newChat: [
    'com.hermesagent.hermes_android.HermesCompactWidgetProvider',
    'com.hermesagent.hermes_android.HermesControlWidgetProvider',
  ],
  LwSubject.cron: ['com.hermesagent.hermes_android.HermesCronWidgetProvider'],
  LwSubject.tasks: ['com.hermesagent.hermes_android.HermesTasksWidgetProvider'],
  LwSubject.chats: ['com.hermesagent.hermes_android.HermesChatsWidgetProvider'],
};

/// The sizes Android reported, as this publisher reads them.
class LwSizeManifest {
  const LwSizeManifest({
    required this.density,
    required this.fontScale,
    required this.sizes,
  });

  /// The screen's density and the system font scale the widgets are shown
  /// at, as Android reads them; 0 when not told. The pictures are drawn at
  /// these (not at what the app's engine reports), because Android only
  /// shows a picture drawn at its own values.
  final double density;
  final double fontScale;

  /// Distinct sizes in dp per subject.
  final Map<LwSubject, List<ui.Size>> sizes;

  static LwSizeManifest? parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['v'] != 1) return null;
      final sizes = <LwSubject, List<ui.Size>>{};
      final listed = json['sizes'];
      if (listed is Map) {
        for (final entry in listed.entries) {
          final subject = LwSubject.byKey(entry.key.toString());
          final pairs = entry.value;
          if (subject == null || pairs is! List) continue;
          final out = <ui.Size>[];
          for (final pair in pairs.take(8)) {
            if (pair is! List || pair.length < 2) continue;
            final w = pair[0] is num ? (pair[0] as num).toDouble() : 0.0;
            final h = pair[1] is num ? (pair[1] as num).toDouble() : 0.0;
            if (w < 40 || h < 24 || w > 2000 || h > 2000) continue;
            final size = ui.Size(w.roundToDouble(), h.roundToDouble());
            if (!out.contains(size)) out.add(size);
          }
          if (out.isNotEmpty) sizes[subject] = out;
        }
      }
      final density = (json['density'] as num?)?.toDouble() ?? 0;
      final fontScale = (json['font_scale'] as num?)?.toDouble() ?? 0;
      return LwSizeManifest(
        density: density > 0 ? density.clamp(0.5, 6.0) : 0,
        fontScale: fontScale > 0 ? fontScale.clamp(0.5, 3.0) : 0,
        sizes: sizes,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Where the pictures and the manifests live.
abstract interface class LauncherWidgetImageStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> redraw(Iterable<String> providers);
  Future<Directory> directory();
}

class PluginLauncherWidgetImageStore implements LauncherWidgetImageStore {
  const PluginLauncherWidgetImageStore();

  @override
  Future<String?> read(String key) => HomeWidget.getWidgetData<String>(key);

  @override
  Future<void> write(String key, String value) async {
    await HomeWidget.saveWidgetData<String>(key, value);
  }

  @override
  Future<void> redraw(Iterable<String> providers) async {
    for (final provider in providers) {
      // A failed redraw of one receiver never blocks the others.
      try {
        await HomeWidget.updateWidget(qualifiedAndroidName: provider);
      } catch (_) {}
    }
  }

  @override
  Future<Directory> directory() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/launcher_widgets');
  }
}

/// What the app tells the publisher about itself: the theme in force, the
/// font, the language, the text size. Read at each publication.
class LauncherWidgetImageEnvironment {
  const LauncherWidgetImageEnvironment({
    required this.colors,
    required this.fontFamily,
    required this.locale,
    required this.textScale,
    required this.devicePixelRatio,
    required this.use24h,
    required this.themeId,
    this.appLockEnabled = _noAppLock,
  });

  static bool _noAppLock() => false;

  final HermesThemeColors Function() colors;
  final String Function() fontFamily;
  final ui.Locale Function() locale;
  final double Function() textScale;
  final double Function() devicePixelRatio;
  final bool Function() use24h;
  final String Function() themeId;

  /// App Lock is on: a launcher picture must not offer Permitir / Rechazar
  /// (the native receiver refuses them while locked and says nothing), only
  /// "Abrir", which lands on the lock screen.
  final bool Function() appLockEnabled;
}

/// One published picture, as the manifest describes it.
class LwPublishedImage {
  const LwPublishedImage({
    required this.subject,
    required this.sizeDp,
    required this.path,
    required this.widthPx,
    required this.heightPx,
    required this.description,
    required this.zones,
    required this.plan,
    this.validUntilMs,
  });

  final LwSubject subject;
  final ui.Size sizeDp;
  final String path;
  final int widthPx;
  final int heightPx;
  final String description;
  final List<LwTapZone> zones;
  final String plan;
  final int? validUntilMs;

  String get key =>
      '${subject.key}:${sizeDp.width.round()}x${sizeDp.height.round()}';

  Map<String, Object?> toJson() => {
    'path': path,
    'w': widthPx,
    'h': heightPx,
    'dp_w': sizeDp.width.round(),
    'dp_h': sizeDp.height.round(),
    'desc': description,
    'plan': plan,
    if (validUntilMs != null) 'valid_until_ms': validUntilMs,
    'zones': [for (final z in zones) z.toJson()],
  };
}

class LwPublishReport {
  const LwPublishReport({required this.images, required this.skipped});
  final List<LwPublishedImage> images;

  /// Why nothing was drawn, when nothing was.
  final String? skipped;
}

/// Serial, coalescing owner of the pictures.
class LauncherWidgetImagePublisher {
  LauncherWidgetImagePublisher({
    this.store = const PluginLauncherWidgetImageStore(),
    int Function()? nowMs,
    this.strings = lookupStrings,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  static final LauncherWidgetImagePublisher instance =
      LauncherWidgetImagePublisher();

  final LauncherWidgetImageStore store;
  final Strings Function(ui.Locale) strings;
  final int Function() _nowMs;

  LauncherWidgetImageEnvironment? _environment;
  bool _dirty = false;
  Future<void> _tail = Future<void>.value();
  bool _running = false;

  /// The last report, for the diagnostics screen and the tests.
  LwPublishReport? last;

  /// The app installs its environment once; without one nothing is drawn
  /// (a background isolate, a test) and the receivers draw natively.
  void configure(LauncherWidgetImageEnvironment? environment) {
    _environment = environment;
  }

  bool get configured => _environment != null;

  /// Android calls this when the sizes of the placed widgets change while
  /// the engine lives (a widget placed or resized, a new font scale).
  static const platformChannel = MethodChannel('hermes/launcher_widgets');

  void attachPlatformChannel() {
    platformChannel.setMethodCallHandler((call) async {
      if (call.method == 'sizesChanged') request();
    });
  }

  /// Asks for a publication. Requests made while one runs are folded into
  /// one more run after it. Returns true when the publisher is in charge of
  /// the redraw (configured); false when the caller must redraw itself.
  bool request() {
    if (_environment == null) return false;
    _dirty = true;
    if (!_running) {
      _running = true;
      _tail = _loop();
    }
    return true;
  }

  Future<void> flush() => _tail;

  Future<void> _loop() async {
    try {
      while (_dirty) {
        _dirty = false;
        try {
          last = await publishOnce();
        } catch (error) {
          if (kDebugMode) {
            debugPrint('[launcher-widget] images (${error.runtimeType})');
          }
          // The snapshot that asked for this run is already stored: the
          // receivers still redraw it, natively when no picture is current.
          await _redrawAll();
        }
      }
    } finally {
      _running = false;
    }
  }

  /// Draws every placed size of every subject once and tells Android.
  Future<LwPublishReport> publishOnce() async {
    final env = _environment;
    if (env == null) {
      await _redrawAll();
      return const LwPublishReport(images: [], skipped: 'unconfigured');
    }
    final manifest = LwSizeManifest.parse(await store.read(lwSizesKey));
    if (manifest == null || manifest.sizes.isEmpty) {
      // Android has not told the sizes yet (or nothing is placed): the
      // receivers redraw natively, and on the way record their sizes.
      await _redrawAll();
      return const LwPublishReport(images: [], skipped: 'no placed widgets');
    }
    final nowMs = _nowMs();
    final locale = env.locale();
    try {
      await initializeDateFormatting(locale.toLanguageTag());
    } catch (_) {
      // Day names fall back to numbers.
    }
    final s = strings(locale);
    final words = LwWords(
      s,
      locale: locale,
      use24h: env.use24h(),
      nowMs: nowMs,
    );
    final palette = LauncherWidgetPalette.of(
      env.colors(),
      fontFamily: env.fontFamily(),
      id: env.themeId(),
    );
    final fontScale = manifest.fontScale > 0
        ? manifest.fontScale
        : env.textScale().clamp(0.5, 3.0);
    final density = manifest.density > 0
        ? manifest.density
        : env.devicePixelRatio();

    final chat = await _readChat();
    final cron = LauncherWidgetCronSnapshot.tryDecode(
      await store.read(LauncherWidgetCronSnapshot.storageKey),
    );
    final chats = LauncherWidgetChatsSnapshot.tryDecode(
      await store.read(LauncherWidgetChatsSnapshot.storageKey),
    );
    final tasks = LauncherWidgetTasksSnapshot.tryDecode(
      await store.read(LauncherWidgetTasksSnapshot.storageKey),
    );
    final sourcesMs = [
      chat.updatedAtMs,
      cron?.updatedAtMs ?? 0,
      chats?.updatedAtMs ?? 0,
      tasks?.updatedAtMs ?? 0,
    ].reduce((a, b) => a > b ? a : b);

    final dir = await store.directory();
    await dir.create(recursive: true);
    final images = <LwPublishedImage>[];
    final keep = <String>{};
    for (final entry in manifest.sizes.entries) {
      final subject = entry.key;
      final scene = switch (subject) {
        LwSubject.ahora => LwAhoraScene.from(
          chat,
          nowMs: nowMs,
          agentName: s.lwpAgent,
          recentChats: chats?.chats ?? const [],
          answersAllowed: !env.appLockEnabled(),
        ),
        LwSubject.chats => LwChatsScene.from(chats, chat, nowMs: nowMs),
        LwSubject.cron => LwCronScene.from(cron, nowMs: nowMs),
        LwSubject.tasks => LwTasksScene.from(tasks, nowMs: nowMs),
        LwSubject.newChat => LwNewChatScene.from(chat),
      };
      final profiles = switch (scene) {
        LwAhoraScene() => {
          ...scene.faces.map((face) => face.profile),
          ...scene.needs.map((need) => need.profile),
          ...scene.runs.map((run) => run.profile),
        },
        LwChatsScene() => scene.rows.map((row) => row.profile).toSet(),
        _ => <String>{},
      };
      final connection = subject == LwSubject.chats
          ? chats?.connectionId
          : chat.instanceId;
      final avatars = <String, LwAvatar>{};
      try {
        for (final profile in profiles) {
          avatars[profile] = await lwLoadAvatar(connection, profile);
        }
        for (final size in entry.value) {
          final frame = paintLauncherWidget(
            LwPaintRequest(
              subject: subject,
              scene: scene,
              sizeDp: size,
              palette: palette,
              words: words,
              fontScale: fontScale,
              instanceId: chat.instanceId,
              avatars: avatars,
            ),
          );
          try {
            final rendered = await lwRenderPng(frame, density: density);
            if (rendered == null) continue;
            final name =
                'lw_${subject.key}_${size.width.round()}x${size.height.round()}.png';
            final file = File('${dir.path}/$name');
            final tmp = File('${file.path}.tmp');
            await tmp.writeAsBytes(rendered.png, flush: true);
            await tmp.rename(file.path);
            keep.add(name);
            images.add(
              LwPublishedImage(
                subject: subject,
                sizeDp: size,
                path: file.path,
                widthPx: rendered.widthPx,
                heightPx: rendered.heightPx,
                description: frame.description,
                zones: frame.zones,
                plan: frame.plan,
                validUntilMs: frame.validUntilMs,
              ),
            );
          } finally {
            frame.dispose();
          }
        }
      } finally {
        for (final avatar in avatars.values) {
          avatar.dispose();
        }
      }
    }
    // Pictures of sizes no longer placed are not kept around.
    try {
      await for (final entity in dir.list()) {
        if (entity is File && !keep.contains(entity.uri.pathSegments.last)) {
          await entity.delete();
        }
      }
    } catch (_) {}
    final written = jsonEncode({
      'v': lwImagesSchema,
      'stamp_ms': nowMs,
      'sources_ms': sourcesMs,
      'density': density,
      'font_scale': fontScale,
      'locale': locale.toLanguageTag(),
      'theme': palette.id,
      'images': {for (final image in images) image.key: image.toJson()},
    });
    await store.write(lwImagesKey, written);
    await store.redraw({
      for (final subject in manifest.sizes.keys) ...?lwProviders[subject],
    });
    return LwPublishReport(images: images, skipped: null);
  }

  Future<void> _redrawAll() async {
    try {
      await store.redraw({for (final list in lwProviders.values) ...list});
    } catch (_) {}
  }

  Future<HermesHomeWidgetSnapshot> _readChat() async {
    final raw = await store.read(HermesHomeWidgetSnapshot.atomicStorageKey);
    if (raw == null || raw.isEmpty) return HermesHomeWidgetSnapshot.empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map &&
          HermesHomeWidgetSnapshot.readableSchemaVersions.contains(
            decoded['schema_version'],
          )) {
        return HermesHomeWidgetSnapshot.fromMap(decoded);
      }
    } catch (_) {}
    return HermesHomeWidgetSnapshot.empty;
  }
}
