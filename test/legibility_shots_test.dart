// Visual evidence of the legibility pass: the key screens and a board of
// the components in the themes the matrix scored worst (dark and light, the
// catalogue and Look & Feel, a tinted page, a near-black one, a white one),
// at 412×915 in Spanish, and the board at 2x text.
//
// PNGs are written only where `LEGIBILITY_SHOTS` (a `--dart-define` or an
// environment variable) points; without it this is a layout smoke test
// (nothing overflows, nothing throws, in any of the themes).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/config/feature_flags.dart';
import 'package:hermes_android/core/design/hermes_design.dart'
    hide HermesListRow, HermesListGroup;
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/screens/look_feel_screen.dart';
import 'package:hermes_android/core/screens/profile_editor_screen.dart';
import 'package:hermes_android/core/screens/onboarding/manual_connect_page.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/settings/settings_sections.dart';
import 'package:hermes_android/core/shell/dock_geometry.dart';
import 'package:hermes_android/core/shell/dock_mode.dart';
import 'package:hermes_android/core/shell/gesture_dock_state.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/look_feel.dart';
import 'package:hermes_android/core/widgets/general_dock_shell.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/design_shots.dart';

const _size = Size(412, 915);
const _key = ValueKey('legibility-shot');

String _dir() {
  const defined = String.fromEnvironment('LEGIBILITY_SHOTS');
  return defined.isNotEmpty
      ? defined
      : (Platform.environment['LEGIBILITY_SHOTS'] ?? '');
}

/// The worst-scored combinations of the matrix (before the pass), plus the
/// theme of the captures that opened this work (a Look & Feel green accent
/// on the charcoal page).
final Map<String, ThemeData> _themes = {
  'console': AppTheme.fromId('console'),
  'lf-gray-green': _lookFeel(
    accent: 'green',
    dark: LookDarkBackground.gray,
    brightness: Brightness.dark,
  ),
  'lf-black-violet': _lookFeel(
    accent: 'violet',
    dark: LookDarkBackground.black,
    brightness: Brightness.dark,
  ),
  'lf-midnight-indigo': _lookFeel(
    accent: 'indigo',
    dark: LookDarkBackground.midnight,
    brightness: Brightness.dark,
  ),
  'amber': AppTheme.fromId('amber'),
  'lf-white-terracotta': _lookFeel(
    accent: 'terracotta',
    light: LookLightBackground.white,
    brightness: Brightness.light,
  ),
  'claude-light': AppTheme.fromId('claude-light'),
  'solarized': AppTheme.fromId('solarized'),
};

ThemeData _lookFeel({
  required String accent,
  required Brightness brightness,
  LookDarkBackground dark = LookDarkBackground.gray,
  LookLightBackground light = LookLightBackground.paper,
}) => LookFeel.themeData(
  LookFeelSettings(
    source: LookFeelSource.derived,
    appearance: brightness == Brightness.dark
        ? LookAppearance.dark
        : LookAppearance.light,
    accentId: accent,
    darkBackground: dark,
    lightBackground: light,
  ),
  brightness,
);

Future<void> _pump(
  WidgetTester tester,
  Widget home,
  ThemeData theme, {
  double textScale = 1,
}) async {
  await loadDesignFonts();
  // A SwitchListTile inside a decorated group trips a debug-only framework
  // lint about ink splashes; everything else still fails the test.
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains(
      'ListTile background color or ink splashes may be invisible',
    )) {
      return;
    }
    previousOnError?.call(details);
  };
  addTearDown(() => FlutterError.onError = previousOnError);
  tester.view.physicalSize = _size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 36, bottom: 24);
  tester.view.viewPadding = const FakeViewPadding(top: 36, bottom: 24);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: home,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _shot(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull, reason: name);
  final dir = _dir();
  if (dir.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_key));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

void _mockSecureStorage() {
  TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => call.method == 'readAll' ? <String, String>{} : null,
      );
}

SavedConnection _connection() => SavedConnection(
  id: 'legibility',
  label: 'casa',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-only',
);

/// Every state of the components the pass touched, on one page.
class _Board extends StatefulWidget {
  const _Board();

  @override
  State<_Board> createState() => _BoardState();
}

class _BoardState extends State<_Board> {
  int _segment = 0;
  final _plain = TextEditingController(text: 'https://mi-servidor.com');
  final _selected = TextEditingController(
    text: 'Ingeniero de Hermes Console: reproduce fallos y entrega parches.',
  );

  @override
  void initState() {
    super.initState();
    _selected.selection = const TextSelection(baseOffset: 29, extentOffset: 45);
  }

  @override
  void dispose() {
    _plain.dispose();
    _selected.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: const HermesAppBar(title: Text('Componentes')),
      body: ListView(
        clipBehavior: hermesUnderHeader,
        padding: const EdgeInsets.fromLTRB(
          HermesSpace.x4,
          HermesSpace.x2,
          HermesSpace.x4,
          HermesSpace.x6,
        ),
        children: [
          HermesListSection(
            title: 'Filas con icono',
            children: [
              HermesListRow(
                icon: Icons.shield_outlined,
                title: 'Bloqueo y privacidad',
                subtitle: 'Bloqueo, privacidad y protección de credenciales',
                onTap: () {},
              ),
              HermesListRow(
                icon: Icons.key_outlined,
                title: 'Contraseñas e inicios de sesión',
                subtitle: 'Lo que el agente usa para iniciar sesión por ti',
                onTap: () {},
              ),
              const HermesListRow(
                icon: Icons.block,
                title: 'Fila deshabilitada',
                subtitle: 'No disponible en esta instancia',
                enabled: false,
              ),
            ],
          ),
          HermesListSection(
            title: 'Filas sin icono',
            children: [
              HermesListRow(title: 'Modelo', onTap: () {}),
              HermesListRow(title: 'Razonamiento', onTap: () {}),
            ],
          ),
          const SizedBox(height: HermesSpace.x3),
          HermesGroup(
            children: [
              HermesSwitchTile(
                title: 'Interruptor encendido',
                subtitle: 'Un subtítulo de dos líneas que explica lo que hace',
                value: true,
                onChanged: (_) {},
              ),
              HermesSwitchTile(
                title: 'Interruptor apagado',
                value: false,
                onChanged: (_) {},
              ),
              const HermesSwitchTile(
                title: 'Interruptor deshabilitado',
                value: false,
                onChanged: null,
              ),
              HermesNavRow(
                icon: Icons.tune_rounded,
                title: 'Fila de navegación',
                subtitle: 'Con un valor y un chevron',
                value: 'Alto',
                onTap: () {},
              ),
            ],
          ),
          const SizedBox(height: HermesSpace.x3),
          HermesSegmentedControl<int>(
            value: _segment,
            onChanged: (v) => setState(() => _segment = v),
            segments: const [
              HermesSegment(value: 0, label: 'Directo'),
              HermesSegment(value: 1, label: 'SSH'),
            ],
          ),
          const SizedBox(height: HermesSpace.x3),
          HermesGroup(
            children: [
              Padding(
                padding: const EdgeInsets.all(HermesSpace.x4),
                child: HermesField(
                  label: 'Dirección',
                  controller: _plain,
                  hint: 'https://mi-servidor.com',
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(HermesSpace.x4),
                child: HermesField(
                  label: 'Descripción',
                  controller: _selected,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 3,
                ),
              ),
            ],
          ),
          const SizedBox(height: HermesSpace.x3),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () {},
                  child: const Text('Conectar'),
                ),
              ),
              const SizedBox(width: HermesSpace.x2),
              const Expanded(
                child: FilledButton(onPressed: null, child: Text('Conectar')),
              ),
            ],
          ),
          const SizedBox(height: HermesSpace.x2),
          const HermesPrimaryButton(label: 'Guardar', onTap: null),
          const SizedBox(height: HermesSpace.x3),
          HermesCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Texto principal en una tarjeta',
                  style: TextStyle(color: colors.textPrimary),
                ),
                Text(
                  'Texto secundario',
                  style: TextStyle(color: colors.textSecondary),
                ),
                Text(
                  'Texto terciario · 12:40',
                  style: TextStyle(color: colors.textTertiary),
                ),
                Text(
                  'Deshabilitado',
                  style: TextStyle(color: colors.textDisabled),
                ),
                const Divider(),
                Wrap(
                  spacing: HermesSpace.x2,
                  children: [
                    Text('Enlace', style: TextStyle(color: colors.accentText)),
                    Text('Error', style: TextStyle(color: colors.error)),
                    Text('Aviso', style: TextStyle(color: colors.warning)),
                    Text('Correcto', style: TextStyle(color: colors.success)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: HermesSpace.x3),
          const HermesInfoBanner('Un aviso informativo con su tinte.'),
        ],
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final entry in _themes.entries) {
    final id = entry.key;
    final theme = entry.value;

    testWidgets('board · $id', (tester) async {
      await _pump(tester, const _Board(), theme);
      await _shot(tester, 'board_$id');
      await tester.drag(find.byType(ListView), const Offset(0, -520));
      await tester.pump(const Duration(milliseconds: 400));
      await _shot(tester, 'board_${id}_scrolled');
    });

    testWidgets('settings and its security section · $id', (tester) async {
      _mockSecureStorage();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      await _pump(
        tester,
        SettingsScreen(connection: _connection(), connManager: manager),
        theme,
      );
      await _shot(tester, 'settings_$id');
      await tester.drag(find.byType(ListView).first, const Offset(0, -700));
      await tester.pump(const Duration(milliseconds: 400));
      await _shot(tester, 'settings_${id}_scrolled');
      final security = find.byWidgetPredicate(
        (w) =>
            w is Text &&
            w.data != null &&
            w.data!.toLowerCase().contains('seguridad'),
      );
      if (security.evaluate().isNotEmpty) {
        await tester.tap(security.first);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        await _shot(tester, 'settings_security_$id');
      }
    });

    testWidgets('look & feel · $id', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = LookFeelPrefs(await SharedPreferences.getInstance());
      final font = ValueNotifier<String>('system');
      addTearDown(font.dispose);
      await _pump(
        tester,
        LookFeelScreen(
          prefsForTesting: prefs,
          fontIdForTesting: font,
          onFontForTesting: (_) async {},
        ),
        theme,
      );
      await _shot(tester, 'look_feel_$id');
    });

    testWidgets('connect (onboarding) · $id', (tester) async {
      await _pump(
        tester,
        ManualConnectPage(
          onHelp: () {},
          onScan: () {},
          connect: (_) async => null,
        ),
        theme,
      );
      await _shot(tester, 'connect_$id');
    });

    testWidgets('chats with the header and the dock · $id', (tester) async {
      SharedPreferences.setMockInitialValues({});
      _mockSecureStorage();
      FeatureFlags.instance.resetToDefaultForTesting();
      GestureDockController.instance.resetForTesting(
        settings: const GestureDockSettings(),
      );
      DockGeometry.instance.resetForTesting();
      DockModes.instance.resetForTesting();
      addTearDown(FeatureFlags.instance.resetForTesting);
      await DockPreferencesController.instance.setUseDock(true);
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      final colors = theme.hermes;
      await _pump(
        tester,
        Scaffold(
          drawer: const Drawer(),
          appBar: HermesAppBar(
            title: const Text('Conversaciones'),
            actions: [
              IconButton(
                tooltip: 'Nueva',
                icon: const Icon(Icons.add_rounded),
                onPressed: () {},
              ),
            ],
          ),
          body: GeneralDockShell(
            connection: _connection(),
            connManager: manager,
            body: ListView(
              clipBehavior: hermesUnderHeader,
              padding: const EdgeInsets.fromLTRB(
                HermesSpace.x1,
                HermesSpace.x2,
                HermesSpace.x1,
                HermesSpace.x6,
              ),
              children: [
                for (var i = 0; i < 14; i++)
                  HermesCard(
                    margin: const EdgeInsets.symmetric(
                      horizontal: HermesSpace.x3,
                      vertical: HermesSpace.x1,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Conversación $i con un título largo',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: HermesType.bodySize,
                            fontWeight: FontWeight.w600,
                            color: colors.textPrimary,
                          ),
                        ),
                        Text(
                          'Último mensaje · hace 2 h',
                          style: TextStyle(
                            fontSize: HermesType.subtitleSize,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        theme,
      );
      await _shot(tester, 'chats_dock_$id');
    });
  }

  // The screens of the device captures, in their theme (Look & Feel green on
  // the charcoal page) and in Console, at 1x and 2x text.
  for (final id in const ['lf-gray-green', 'console']) {
    for (final scale in const [1.0, 2.0]) {
      final tag = scale == 1 ? id : '${id}_2x';
      testWidgets('profile editor · $tag', (tester) async {
        _mockSecureStorage();
        SharedPreferences.setMockInitialValues({});
        await _pump(
          tester,
          ProfileEditorScreen(
            connection: _connection(),
            profile: AgentProfile.fromJson({
              'name': 'console-builder',
              'description':
                  'Ingeniero de Hermes Console: reproduce fallos, '
                  'implementa correcciones acotadas y entrega parches '
                  'verificables.',
              'ui_meta': {
                'hermes-bots': {'title': 'Forja'},
              },
            }),
          ),
          _themes[id]!,
          textScale: scale,
        );
        await _shot(tester, 'profile_$tag');
        // The group right above the fixed save bar: its foot fades there.
        await tester.drag(
          find.byKey(const ValueKey('profile-editor-scroll')),
          const Offset(0, -260),
        );
        await tester.pump(const Duration(milliseconds: 400));
        await _shot(tester, 'profile_${tag}_scrolled');
        // A pressed row (one that opens something), pressed by its top
        // left: its ink must stay inside the rounded group, no square
        // corner outside it.
        final row = find.byKey(const ValueKey('profile-editor-model-row'));
        if (row.evaluate().isNotEmpty) {
          final gesture = await tester.startGesture(
            tester.getTopLeft(row) +
                const Offset(HermesSpace.x2, HermesSpace.x2),
          );
          await tester.pump(const Duration(milliseconds: 120));
          await _shot(tester, 'profile_${tag}_pressed');
          await gesture.up();
          await tester.pump(const Duration(milliseconds: 400));
        }
      });
    }

    testWidgets('selection handles in a field · $id', (tester) async {
      await _pump(tester, const _Board(), _themes[id]!);
      final field = find.byWidgetPredicate(
        (w) => w is EditableText && w.controller.text.startsWith('https'),
      );
      // A long press on a word of a field with no selection yet: the
      // selection and its handles, as the finger leaves them.
      await tester.longPressAt(
        tester.getTopLeft(field) + const Offset(HermesSpace.x8, HermesSpace.x2),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await _shot(tester, 'selection_$id');
    });

    for (final scale in const [1.0, 2.0]) {
      final tag = scale == 1 ? id : '${id}_2x';
      testWidgets('security section · $tag', (tester) async {
        _mockSecureStorage();
        SharedPreferences.setMockInitialValues({});
        final manager = await ConnectionManager.create(
          await SharedPreferences.getInstance(),
        );
        await _pump(
          tester,
          settingsSectionScreen(
            section: SettingsSection.security,
            connection: _connection(),
            connManager: manager,
          ),
          _themes[id]!,
          textScale: scale,
        );
        await _shot(tester, 'security_$tag');
      });
    }

    testWidgets('settings and security at 2x text · $id', (tester) async {
      _mockSecureStorage();
      SharedPreferences.setMockInitialValues({});
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      await _pump(
        tester,
        SettingsScreen(connection: _connection(), connManager: manager),
        _themes[id]!,
        textScale: 2,
      );
      await _shot(tester, 'settings_${id}_2x');
      final security = find.byWidgetPredicate(
        (w) =>
            w is Text &&
            w.data != null &&
            w.data!.toLowerCase().contains('seguridad'),
      );
      if (security.evaluate().isNotEmpty) {
        await tester.ensureVisible(security.first);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(security.first);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        await _shot(tester, 'settings_security_${id}_2x');
      }
    });
  }

  for (final id in const ['console', 'claude-light']) {
    testWidgets('board at 2x text · $id', (tester) async {
      await _pump(tester, const _Board(), _themes[id]!, textScale: 2);
      await _shot(tester, 'board_${id}_2x');
    });

    testWidgets('connect at 2x text · $id', (tester) async {
      await _pump(
        tester,
        ManualConnectPage(
          onHelp: () {},
          onScan: () {},
          connect: (_) async => null,
        ),
        _themes[id]!,
        textScale: 2,
      );
      await _shot(tester, 'connect_${id}_2x');
    });
  }
}
