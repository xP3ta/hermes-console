// The production General shell and dock over scrolling image/text/code.
// Every case runs normally. DOCK_EVIDENCE_DIR only adds PNG/JSON output.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/general_dock_shell.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/design_shots.dart' show loadDesignFonts;

const _root = ValueKey('dock-capture-root');
final _connection = SavedConnection(
  id: 'dock-capture',
  label: 'QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'test-key',
);

class _Frame {
  const _Frame(this.rgba, this.width, this.png);
  final Uint8List rgba;
  final int width;
  final Uint8List? png;
  Color pixel(int x, int y) {
    final i = (y * width + x) * 4;
    return Color.fromARGB(255, rgba[i], rgba[i + 1], rgba[i + 2]);
  }
}

Future<_Frame> _capture(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_root),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final png = Platform.environment['DOCK_EVIDENCE_DIR'] == null
        ? null
        : await image.toByteData(format: ui.ImageByteFormat.png);
    final result = _Frame(
      rgba!.buffer.asUint8List(),
      image.width,
      png?.buffer.asUint8List(),
    );
    image.dispose();
    return result;
  }))!;
}

Widget _scene(
  ConnectionManager manager,
  String theme,
  String kind,
  ScrollController scroll,
  ValueNotifier<bool> showInk,
  ImageProvider hero,
) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppTheme.fromId(theme),
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(
    body: RepaintBoundary(
      key: _root,
      child: GeneralDockShell(
        connection: _connection,
        connManager: manager,
        bodyBuilder: (context, clearance) {
          final colors = Theme.of(context).hermes;
          return ListView(
            key: const ValueKey('dock-capture-list'),
            controller: scroll,
            padding: EdgeInsets.only(bottom: clearance + 28),
            children: [
              for (var i = 0; i < 32; i++)
                SizedBox(
                  height: 96,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: showInk,
                    builder: (_, visible, _) => kind == 'image'
                        ? Opacity(
                            opacity: visible ? 1 : 0,
                            child: Image(
                              image: hero,
                              fit: BoxFit.cover,
                              alignment: Alignment(0, i.isEven ? -.5 : .5),
                            ),
                          )
                        : ColoredBox(
                            color: colors.background,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: Text(
                                kind == 'code'
                                    ? 'final ssh = connect(host);\nawait ssh.exec("pwd"); // línea $i\nif (open) keepSession();\nreturn terminal.output;'
                                    : 'El contenido real cruza detrás del dock.\nLa conversación y los accesos se conservan.\nUna última fila accesible al final de la lista.\nSeguimiento y lectura, sin perder el estado.',
                                style: TextStyle(
                                  fontFamily: kind == 'code'
                                      ? 'JetBrainsMono'
                                      : 'Inter',
                                  fontSize: 15,
                                  height: 1.4,
                                  color: visible
                                      ? colors.textPrimary
                                      : Colors.transparent,
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final prefs = DockPreferencesController.instance;
  setUpAll(loadDesignFonts);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FeatureFlags.instance.resetForTesting(gestureDock: true);
    GestureDockController.instance.resetForTesting(
      settings: const GestureDockSettings(
        tabs: GestureDockTab.legacyDefaultLayout,
      ),
    );
    DockGeometry.instance.resetForTesting();
    await prefs.setUseDock(true);
  });
  tearDown(() async {
    await prefs.setUseDock(true);
    FeatureFlags.instance.resetForTesting();
  });
  for (final theme in ['classic-dark', 'console-light']) {
    for (final kind in ['image', 'text', 'code']) {
      testWidgets(
        'dock real backdrop $theme $kind: geometry, stimulus and ghost',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(390, 844);
          tester.view.padding = const FakeViewPadding(bottom: 34);
          tester.view.viewPadding = const FakeViewPadding(bottom: 34);
          addTearDown(tester.view.reset);
          final manager = await ConnectionManager.create(
            await SharedPreferences.getInstance(),
          );
          final scroll = ScrollController();
          final showInk = ValueNotifier(true);
          final hero = MemoryImage(
            File('assets/branding/hermes_console_hero.png').readAsBytesSync(),
          );
          addTearDown(scroll.dispose);
          addTearDown(showInk.dispose);
          await tester.pumpWidget(
            _scene(manager, theme, kind, scroll, showInk, hero),
          );
          if (kind == 'image') {
            await tester.runAsync(
              () => precacheImage(
                hero,
                tester.element(find.byType(GeneralDockShell)),
              ),
            );
          }
          await tester.pumpAndSettle();
          scroll.jumpTo(600);
          await tester.pumpAndSettle();
          final barFinder = find.byKey(const ValueKey('gesture-dock-pointer'));
          final bar = tester.getRect(barFinder);
          final viewport = tester.getRect(
            find.byKey(const ValueKey('dock-capture-list')),
          );
          expect(viewport.contains(bar.center), isTrue);
          final pieces = [
            tester.getRect(find.byKey(const ValueKey('gesture-dock-glass'))),
            tester.getRect(
              find.byKey(const ValueKey('gesture-dock-create-glass')),
            ),
          ];
          final icons = find
              .descendant(of: barFinder, matching: find.byType(Icon))
              .evaluate()
              .map((e) => tester.getRect(find.byWidget(e.widget)).inflate(3))
              .toList();
          final actual = await _capture(tester);
          showInk.value = false;
          await tester.pump();
          final control = await _capture(tester);
          await prefs.setUseDock(false);
          await tester.pumpAndSettle();
          expect(scroll.offset, 600);
          final blank = await _capture(tester);
          showInk.value = true;
          await tester.pump();
          final stimulus = await _capture(tester);
          final measures = <Map<String, Object?>>[];
          for (var index = 0; index < pieces.length; index++) {
            final inner = pieces[index].deflate(9);
            var stimulusMax = 1.0, ghostMax = 1.0, challenged = 0, samples = 0;
            var signalSum = 0.0;
            for (var y = inner.top.ceil(); y < inner.bottom.floor(); y++) {
              for (var x = inner.left.ceil(); x < inner.right.floor(); x++) {
                if (icons.any(
                  (r) => r.contains(Offset(x.toDouble(), y.toDouble())),
                )) {
                  continue;
                }
                samples++;
                final before = ThemeContrast.ratio(
                  stimulus.pixel(x, y),
                  blank.pixel(x, y),
                );
                stimulusMax = math.max(stimulusMax, before);
                if (before > 3) challenged++;
                ghostMax = math.max(
                  ghostMax,
                  ThemeContrast.ratio(actual.pixel(x, y), control.pixel(x, y)),
                );
                final painted = actual.pixel(x, y);
                final plain = control.pixel(x, y);
                signalSum +=
                    ((painted.r - plain.r).abs() +
                        (painted.g - plain.g).abs() +
                        (painted.b - plain.b).abs()) *
                    255 /
                    3;
              }
            }
            measures.add({
              'piece': index,
              'rect': [inner.left, inner.top, inner.right, inner.bottom],
              'samples': samples,
              'challenged': challenged,
              'stimulusMax': stimulusMax,
              'ghostMax': ghostMax,
              'meanRgbSignal': samples == 0 ? 0 : signalSum / samples,
              'ghostLimit': kind == 'image' ? null : 1.1,
            });
          }
          final output = Platform.environment['DOCK_EVIDENCE_DIR'];
          if (output != null) {
            final directory = Directory(output)..createSync(recursive: true);
            for (final (name, frame) in [
              ('actual', actual),
              ('control', control),
              ('stimulus', stimulus),
              ('blank', blank),
            ]) {
              File(
                '${directory.path}/$theme-$kind-$name.png',
              ).writeAsBytesSync(frame.png!);
            }
            File('${directory.path}/$theme-$kind.json').writeAsStringSync(
              jsonEncode({
                'source': Platform.environment['DOCK_SOURCE_SHA'],
                'theme': theme,
                'kind': kind,
                'viewport': [
                  viewport.left,
                  viewport.top,
                  viewport.right,
                  viewport.bottom,
                ],
                'bar': [bar.left, bar.top, bar.right, bar.bottom],
                'scroll': scroll.offset,
                'dpr': 1,
                'safeBottom': 34,
                'measures': measures,
                'gpuCertified': false,
              }),
            );
          }
          // Preserve the physical controls and measures even when an
          // assertion below is red; generating a PNG is never acceptance.
          for (final measure in measures) {
            expect(measure['samples'], greaterThan(0));
            expect(
              measure['challenged'],
              greaterThan(20),
              reason: '$kind must physically cross each piece',
            );
            expect(measure['stimulusMax'], greaterThan(3));
            if (kind == 'image') {
              expect(
                measure['meanRgbSignal'],
                greaterThan(3),
                reason: 'real image must change the dock interior',
              );
            } else {
              expect(
                measure['ghostMax'],
                lessThanOrEqualTo(1.1),
                reason: '$kind under piece ${measure['piece']}',
              );
            }
          }
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
