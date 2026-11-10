// Everything that opens over a page (a menu, a long-press popover, a dialog, a
// picker, a window) has an opaque body: the theme's own surface, with its
// border and its shadow. Nothing under it can be read through it, in a light
// theme or a dark one, whatever the glass level is.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/glass_look.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart'
    show showHermesFloatingSurface;
import 'package:hermes_android/l10n/app_localizations.dart';

const _under = ValueKey('text-under-the-surface');

Future<BuildContext> _host(
  WidgetTester tester,
  String themeId, {
  GlassLevel level = GlassLevel.full,
}) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  GlassLookPrefs.debugUse(GlassLookPrefs.inMemory(level));
  addTearDown(() => GlassLookPrefs.debugUse(null));
  late BuildContext ctx;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId(themeId),
      home: Scaffold(
        body: Builder(
          builder: (c) {
            ctx = c;
            return const Align(
              alignment: Alignment.center,
              child: Text('xPeta social-writer studio-art', key: _under),
            );
          },
        ),
      ),
    ),
  );
  return ctx;
}

void main() {
  for (final id in ['classic', 'classic-dark', 'console', 'console-light']) {
    for (final level in [GlassLevel.off, GlassLevel.full]) {
      final tag = '$id/${level.name}';

      void expectOpaque(WidgetTester tester, Key key) {
        final chrome = HermesChrome.of(AppTheme.fromId(id).hermes);
        final material = tester.widget<Material>(
          find
              .descendant(of: find.byKey(key), matching: find.byType(Material))
              .first,
        );
        expect(material.color, chrome.opaque, reason: tag);
        expect(material.color!.a, 1, reason: tag);
        expect(
          find.descendant(
            of: find.byKey(key),
            matching: find.byType(HermesGlassStrip),
          ),
          findsNothing,
          reason: tag,
        );
        // No filter anywhere: the surface blurs nothing, it hides it.
        expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
      }

      testWidgets('$tag: the popover of a long press (floating surface) is '
          'opaque', (tester) async {
        final ctx = await _host(tester, id, level: level);
        showHermesFloatingSurface<void>(
          context: ctx,
          surfaceKey: const ValueKey('roster-actions'),
          maxWidth: 420,
          maxHeightFactor: 0.6,
          builder: (_) => const SizedBox(
            height: 200,
            child: Center(child: Text('Mover a sección…')),
          ),
        );
        await tester.pumpAndSettle();
        expectOpaque(tester, const ValueKey('roster-actions'));
        expect(find.byKey(_under), findsOneWidget);
      });

      testWidgets('$tag: the menu is opaque', (tester) async {
        final ctx = await _host(tester, id, level: level);
        showHermesMenu<String>(
          context: ctx,
          actions: const [
            HermesAction(value: 'chat', label: 'Chat'),
            HermesAction(value: 'pin', label: 'Fijar'),
            HermesAction(value: 'hide', label: 'Ocultar'),
          ],
        );
        await tester.pumpAndSettle();
        expectOpaque(tester, const ValueKey('hermes-menu'));
      });

      testWidgets('$tag: the dialog is opaque', (tester) async {
        final ctx = await _host(tester, id, level: level);
        showHermesDialog<bool>(
          context: ctx,
          title: 'Borrar',
          message: 'No se puede deshacer.',
          actions: const [
            HermesDialogAction(
              label: 'Cancelar',
              value: false,
              style: HermesDialogActionStyle.cancel,
            ),
            HermesDialogAction(label: 'Borrar', value: true),
          ],
        );
        await tester.pumpAndSettle();
        expectOpaque(tester, const ValueKey('hermes-dialog'));
      });

      testWidgets('$tag: a lifted window over the page is opaque', (
        tester,
      ) async {
        final ctx = await _host(tester, id, level: level);
        showHermesSurface<void>(
          context: ctx,
          surfaceKey: const ValueKey('lifted-window'),
          lifted: true,
          coversPage: false,
          builder: (_) => const SizedBox(height: 120, width: 200),
        );
        await tester.pumpAndSettle();
        expectOpaque(tester, const ValueKey('lifted-window'));
      });
    }
  }
}
