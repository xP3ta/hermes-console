// Ajustes › Dock no tenía tests propios hasta ahora. Cubre dos hallazgos de
// la revisión exhaustiva del dock:
//
//  - B1 [a11y, MEDIDO]: a `textScale` alto, la lista de items y las
//    miniaturas de Bordes/Profundidad lanzaban overflow de layout real.
//  - E: los tres closures de `_DockStyleEditor` (Bordes/Transparencia/
//    Profundidad) capturaban el `style` de un build ya viejo en vez del
//    `style` ACTUAL del perfil recibido en la actualización, así que dos
//    toques rápidos en distintas dimensiones se pisaban entre sí.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/dock_config.dart';
import 'package:hermes_android/core/screens/dock_settings_screen.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host({double textScale = 1}) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: const DockSettingsScreen(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final controller = DockPreferencesController.instance;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDown(() async {
    // Singleton de proceso: se devuelve al estado por defecto para no
    // filtrar estado entre tests de este archivo.
    await controller.resetBots();
    await controller.resetGeneral();
  });

  testWidgets(
    'renders the Bots tab at 2.0x text scale without layout overflow (B1)',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_host(textScale: 2.0));
      await tester.pumpAndSettle();

      // El propio catálogo por defecto de "Bots" ya tiene 8 items: la
      // altura fija (54dp) sin escalar con el texto lanzaba overflow real
      // en la lista reordenable, y las miniaturas de Bordes/Profundidad en
      // línea desbordaban su fila a este tamaño de fuente.
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'renders the General tab at 2.0x text scale without layout overflow (B1)',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_host(textScale: 2.0));
      await tester.pumpAndSettle();

      await tester.tap(find.text('General'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'quick taps on Border and Depth do not clobber each other (E)',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      // Estado inicial (perfil "Bots" por defecto): borde "Soft", plano
      // "Elevated" — ambos distintos de los que se van a tocar, para que
      // el test detecte de verdad un cambio real en cada dimensión.
      expect(
        controller.value.bots.style.borderShape,
        DockBorderShape.soft,
      );
      expect(controller.value.bots.style.depth, DockDepth.elevated);

      // Antes del fix, `style.copyWith(...)` capturaba el `style` de ESTE
      // build (ya obsoleto tras el primer toque) en vez de `p.style`, así
      // que el segundo toque (Profundidad) revertía el primero (Bordes) al
      // reconstruir sobre el estado viejo.
      await tester.tap(find.text('Rounded'));
      await tester.pump();
      await tester.tap(find.text('Flat'));
      await tester.pumpAndSettle();

      expect(controller.value.bots.style.borderShape, DockBorderShape.rounded);
      expect(controller.value.bots.style.depth, DockDepth.flat);
    },
  );

  testWidgets(
    'quick taps on Transparency and Depth do not clobber each other (E)',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      final slider = find.byType(Slider);
      expect(slider, findsOneWidget);

      await tester.drag(slider, const Offset(80, 0));
      await tester.pump();
      await tester.tap(find.text('Floating'));
      await tester.pumpAndSettle();

      expect(controller.value.bots.style.transparency, greaterThan(0));
      expect(controller.value.bots.style.depth, DockDepth.floating);
    },
  );
}
