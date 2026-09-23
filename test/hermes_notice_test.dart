import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _card = ValueKey('hermes-notice-card-under-test');

/// App con un "composer" y un "dock" falsos pegados abajo, para medir que los
/// avisos nunca los tocan. Los insets (barra de estado, teclado) se fijan con
/// `tester.view`, igual que en el dispositivo.
Widget _app({
  String theme = 'dark',
  bool reduceMotion = false,
  double textScale = 1,
  Widget? body,
  GlobalKey<NavigatorState>? navigatorKey,
}) => MaterialApp(
  navigatorKey: navigatorKey,
  theme: AppTheme.fromId(theme),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduceMotion,
      textScaler: TextScaler.linear(textScale),
    ),
    child: child!,
  ),
  home: Scaffold(
    body: Stack(
      children: [
        Positioned.fill(child: body ?? const SizedBox.expand()),
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SizedBox(key: ValueKey('fake-composer'), height: 72),
        ),
        const Positioned(
          left: 20,
          right: 20,
          bottom: 84,
          child: SizedBox(key: ValueKey('fake-dock'), height: 48),
        ),
      ],
    ),
  ),
);

void _phone(
  WidgetTester tester, {
  double top = 0,
  double bottom = 0,
  double keyboard = 0,
  Size size = const Size(320, 640),
}) {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size
    ..padding = FakeViewPadding(top: top, bottom: bottom)
    ..viewPadding = FakeViewPadding(top: top, bottom: bottom)
    ..viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.reset);
}

BuildContext _ctx(WidgetTester tester) =>
    tester.element(find.byKey(const ValueKey('fake-composer')));

Finder get _notices => find.byType(HermesNoticeCard);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Widget _cardHost(
  Widget child, {
  bool reduceMotion = true,
  double textScale = 1,
  String theme = 'dark',
}) => MaterialApp(
  theme: AppTheme.fromId(theme),
  builder: (context, page) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduceMotion,
      textScaler: TextScaler.linear(textScale),
    ),
    child: page!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: child,
      ),
    ),
  ),
);

HermesNoticeCard _sample({
  HermesNoticeKind kind = HermesNoticeKind.success,
  String? title = 'Respuesta lista',
  String message = 'Hermes termino el trabajo.',
  HermesNoticeAction? action,
  VoidCallback? onTap,
  VoidCallback? onDismissed,
  bool showDismiss = true,
  Color? tint,
  Key noticeKey = _card,
}) => HermesNoticeCard(
  noticeKey: noticeKey,
  kind: kind,
  tint: tint,
  title: title,
  message: message,
  action: action,
  onTap: onTap,
  onDismissed: onDismissed ?? () {},
  showDismiss: showDismiss,
  dismissLabel: 'Descartar',
);

void main() {
  group('HermesNotice: posicion y solapes', () {
    testWidgets('flota ARRIBA, bajo la barra de estado (safe area)', (
      tester,
    ) async {
      _phone(tester, top: 40, bottom: 24);
      await tester.pumpWidget(_app());
      HermesNotice.of(_ctx(tester)).show(message: 'Copiado');
      await _settle(tester);

      expect(_notices, findsOneWidget);
      final rect = tester.getRect(_notices);
      expect(rect.top, 40 + 8, reason: 'safe area + 8 dp de respiro');
      expect(rect.left, 16);
      expect(rect.right, 320 - 16);
      expect(rect.bottom, lessThan(640 / 3));
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('respeta el recorte lateral (notch en horizontal)', (
      tester,
    ) async {
      _phone(tester, size: const Size(640, 320));
      tester.view
        ..padding = const FakeViewPadding(left: 44, right: 44)
        ..viewPadding = const FakeViewPadding(left: 44, right: 44);
      await tester.pumpWidget(_app());
      HermesNotice.of(_ctx(tester)).show(message: 'Copiado');
      await _settle(tester);
      final rect = tester.getRect(_notices);
      expect(rect.left, greaterThanOrEqualTo(44 + 16));
      expect(rect.right, lessThanOrEqualTo(640 - 44 - 16));
    });

    testWidgets(
      'nunca toca el composer, el dock ni el teclado (ni con 3 lineas)',
      (tester) async {
        _phone(tester, top: 24, bottom: 24, keyboard: 300);
        await tester.pumpWidget(_app(textScale: 1.3));
        HermesNotice.of(_ctx(tester)).show(
          title: 'Hermes respondio en un chat con un nombre bastante largo',
          message:
              'Una respuesta larga que ocupa varias lineas para comprobar que '
              'el aviso crece hacia abajo desde el borde superior y no hacia '
              'el composer.',
          kind: HermesNoticeKind.warning,
          action: const HermesNoticeAction(label: 'Ir', onPressed: _noop),
        );
        await _settle(tester);

        final notice = tester.getRect(_notices);
        final composer = tester.getRect(
          find.byKey(const ValueKey('fake-composer')),
        );
        final dock = tester.getRect(find.byKey(const ValueKey('fake-dock')));
        final keyboard = Rect.fromLTWH(0, 640 - 300, 320, 300);
        for (final other in [composer, dock, keyboard]) {
          expect(notice.overlaps(other), isFalse, reason: '$notice vs $other');
        }
        expect(notice.top, 24 + 8);
        expect(notice.bottom, lessThan(640 / 2));
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('HermesNotice: carril unico', () {
    testWidgets('duplicados se fusionan y los distintos hacen cola FIFO', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app());
      final notices = HermesNotice.of(_ctx(tester));
      notices.show(message: 'Copiado');
      await _settle(tester);
      notices.show(message: 'Copiado');
      await tester.pump();
      expect(_notices, findsOneWidget);
      expect(find.text('Copiado'), findsOneWidget);

      // Otro mensaje distinto espera su turno: como maximo UNO visible.
      notices.show(message: 'Guardado', kind: HermesNoticeKind.success);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_notices, findsOneWidget);
      expect(find.text('Copiado'), findsOneWidget);
      expect(find.text('Guardado'), findsNothing);

      // Con alguien esperando, el visible cede tras su tiempo minimo (2,5 s).
      await tester.pump(const Duration(milliseconds: 2400));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_notices, findsOneWidget);
      expect(find.text('Guardado'), findsOneWidget);
      expect(find.text('Copiado'), findsNothing);
    });

    testWidgets('la cola es corta: se descartan los mas antiguos', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app());
      final notices = HermesNotice.of(_ctx(tester));
      for (var i = 1; i <= 6; i++) {
        notices.show(message: 'Aviso $i', kind: HermesNoticeKind.error);
      }
      await _settle(tester);
      expect(_notices, findsOneWidget);
      expect(find.text('Aviso 1'), findsOneWidget);
      final seen = <String>['Aviso 1'];
      for (var step = 0; step < 6; step++) {
        await tester.pump(const Duration(milliseconds: 2600));
        await tester.pump(const Duration(milliseconds: 300));
        for (var i = 2; i <= 6; i++) {
          if (find.text('Aviso $i').evaluate().isNotEmpty) seen.add('Aviso $i');
        }
        expect(_notices.evaluate().length, lessThanOrEqualTo(1));
      }
      // 1 visible + 3 en cola: el 2 y el 3 (los mas antiguos en espera) caen.
      expect(seen.toSet(), {'Aviso 1', 'Aviso 4', 'Aviso 5', 'Aviso 6'});
      await tester.pump(const Duration(seconds: 7));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_notices, findsNothing);
    });

    testWidgets('hide muestra el siguiente y clear vacia toda la cola', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app());
      final notices = HermesNotice.of(_ctx(tester));
      notices.show(message: 'Uno');
      notices.show(message: 'Dos');
      await _settle(tester);
      notices.hideCurrentSnackBar();
      await tester.pump();
      await _settle(tester);
      expect(find.text('Dos'), findsOneWidget);
      expect(find.text('Uno'), findsNothing);

      notices.show(message: 'Tres');
      notices.clearSnackBars();
      await _settle(tester);
      expect(_notices, findsNothing);
    });

    testWidgets('un aviso importante vacia la cola y toma el carril', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app());
      final notices = HermesNotice.of(_ctx(tester));
      notices.show(message: 'Uno');
      notices.show(message: 'Dos');
      await _settle(tester);
      notices.show(
        message: 'Aprobacion',
        priority: HermesNoticePriority.high,
        sticky: true,
      );
      await _settle(tester);
      expect(find.text('Aprobacion'), findsOneWidget);
      expect(find.text('Uno'), findsNothing);
      await tester.pump(const Duration(seconds: 20));
      expect(find.text('Aprobacion'), findsOneWidget);
      expect(find.text('Dos'), findsNothing, reason: 'cola vaciada');
    });

    testWidgets('un duplicado reinicia el temporizador sin reanimar', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app());
      final notices = HermesNotice.of(_ctx(tester));
      notices.show(message: 'Copiado');
      await _settle(tester);
      await tester.pump(const Duration(seconds: 3));
      notices.show(message: 'Copiado');
      await tester.pump(const Duration(seconds: 3));
      // 6 s desde el primero, pero solo 3 s desde el ultimo duplicado.
      expect(_notices, findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_notices, findsNothing);
    });

    testWidgets('se cierra solo a los 4 s y no deja temporizadores', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app());
      HermesNotice.of(_ctx(tester)).show(message: 'Copiado');
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 3400));
      expect(_notices, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_notices, findsNothing);
    });

    testWidgets('los errores duran mas y con accion aun mas', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app());
      final notices = HermesNotice.of(_ctx(tester));
      notices.show(message: 'Fallo', kind: HermesNoticeKind.error);
      await _settle(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(_notices, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_notices, findsNothing);

      notices.show(
        message: 'Borrado',
        action: const HermesNoticeAction(label: 'Deshacer', onPressed: _noop),
      );
      await _settle(tester);
      await tester.pump(const Duration(seconds: 7));
      expect(_notices, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_notices, findsNothing);
    });

    testWidgets('sticky no caduca; el feedback normal lo aparca y vuelve', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app());
      final notices = HermesNotice.of(_ctx(tester));
      var closed = 0;
      notices.show(
        title: 'Necesita tu permiso',
        message: 'Aprobacion pendiente',
        priority: HermesNoticePriority.high,
        sticky: true,
        id: 'approval',
        onClosed: () => closed++,
      );
      await _settle(tester);
      await tester.pump(const Duration(seconds: 30));
      expect(find.text('Necesita tu permiso'), findsOneWidget);

      notices.show(message: 'Copiado');
      await _settle(tester);
      expect(_notices, findsOneWidget);
      expect(find.text('Copiado'), findsOneWidget);
      expect(find.text('Necesita tu permiso'), findsNothing);
      expect(closed, 0, reason: 'aparcado, no cerrado');

      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Copiado'), findsNothing);
      expect(find.text('Necesita tu permiso'), findsOneWidget);
      expect(closed, 0);
      await tester.pump(const Duration(seconds: 30));
      expect(find.text('Necesita tu permiso'), findsOneWidget);
    });

    testWidgets('hideCurrentSnackBar nunca retira un aviso importante', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app());
      final notices = HermesNotice.of(_ctx(tester));
      notices.show(
        message: 'Aprobacion',
        priority: HermesNoticePriority.high,
        sticky: true,
      );
      await _settle(tester);
      notices.hideCurrentSnackBar();
      notices.clearSnackBars();
      await _settle(tester);
      expect(find.text('Aprobacion'), findsOneWidget);
    });
  });

  group('HermesNotice: interaccion', () {
    testWidgets('la accion ejecuta su callback y cierra el aviso', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app());
      var pressed = 0;
      HermesNotice.of(_ctx(tester)).show(
        message: 'Borrado',
        action: HermesNoticeAction(label: 'Deshacer', onPressed: () => pressed++),
      );
      await _settle(tester);
      final action = find.byKey(const ValueKey('hermes-notice-action'));
      expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
      await tester.tap(action);
      await _settle(tester);
      expect(pressed, 1);
      expect(_notices, findsNothing);
    });

    testWidgets('closesNotice:false deja el cierre al propietario', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app());
      var pressed = 0;
      final handle = HermesNotice.of(_ctx(tester)).show(
        message: 'Respuesta lista',
        sticky: true,
        action: HermesNoticeAction(
          label: 'Ir',
          onPressed: () => pressed++,
          closesNotice: false,
        ),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('hermes-notice-action')));
      await _settle(tester);
      expect(pressed, 1);
      expect(_notices, findsOneWidget, reason: 'sigue hasta que el dueño cierre');
      handle!.dismiss();
      await _settle(tester);
      expect(_notices, findsNothing);
    });

    testWidgets('tocar la tarjeta, deslizar y el handle lo descartan', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app());
      final notices = HermesNotice.of(_ctx(tester));

      notices.show(message: 'Uno');
      await _settle(tester);
      await tester.tap(find.text('Uno'));
      await _settle(tester);
      expect(_notices, findsNothing);

      notices.show(message: 'Dos');
      await _settle(tester);
      await tester.drag(_notices, const Offset(-400, 0));
      await _settle(tester);
      expect(_notices, findsNothing);

      notices.show(message: 'Tres');
      await _settle(tester);
      await tester.fling(_notices, const Offset(0, -120), 1200);
      await _settle(tester);
      expect(_notices, findsNothing);

      final handle = notices.show(message: 'Cuatro');
      await _settle(tester);
      expect(handle!.isActive, isTrue);
      handle.dismiss();
      await _settle(tester);
      expect(_notices, findsNothing);
      expect(handle.isActive, isFalse);
    });

    testWidgets('onTap propio y onClosed se respetan', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app());
      var opened = 0;
      var closed = 0;
      HermesNotice.of(_ctx(tester)).show(
        title: 'Respuesta lista',
        message: 'Toca para abrir',
        onTap: () => opened++,
        onClosed: () => closed++,
        showDismiss: true,
        dismissLabel: 'Descartar',
      );
      await _settle(tester);
      await tester.tap(find.text('Respuesta lista'));
      await tester.pump();
      expect(opened, 1);
      expect(_notices, findsOneWidget, reason: 'onTap propio no cierra');
      await tester.tap(find.byTooltip('Descartar'));
      await _settle(tester);
      expect(closed, 1);
      expect(_notices, findsNothing);
    });

    testWidgets('showSnackBar traduce texto, accion, duracion y clave', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app());
      var undone = 0;
      HermesNotice.of(_ctx(tester)).showSnackBar(
        SnackBar(
          key: const ValueKey('legacy-snack'),
          content: const Text('Chat borrado'),
          duration: const Duration(seconds: 2),
          action: SnackBarAction(label: 'Deshacer', onPressed: () => undone++),
        ),
        kind: HermesNoticeKind.success,
      );
      await _settle(tester);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byKey(const ValueKey('legacy-snack')), findsOneWidget);
      expect(find.text('Chat borrado'), findsOneWidget);
      await tester.tap(find.text('Deshacer'));
      await tester.pump();
      expect(undone, 1);
    });

    testWidgets('resuelve tambien desde el contexto del propio Navigator', (
      tester,
    ) async {
      _phone(tester);
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(_app(navigatorKey: key));
      HermesNotice.of(key.currentContext!).show(message: 'Desde el Navigator');
      await _settle(tester);
      expect(find.text('Desde el Navigator'), findsOneWidget);
      HermesNotice.ofNavigator(key.currentState)!.clearSnackBars();
      await _settle(tester);
      HermesNotice.ofNavigator(key.currentState)!.show(message: 'Otro');
      await _settle(tester);
      expect(find.text('Otro'), findsOneWidget);
    });

    testWidgets('sin Overlay degrada al SnackBar del ScaffoldMessenger', (
      tester,
    ) async {
      _phone(tester);
      late BuildContext aboveNavigator;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) {
            aboveNavigator = context;
            return child!;
          },
          home: const Scaffold(body: SizedBox.expand()),
        ),
      );
      HermesNotice.of(aboveNavigator).show(message: 'Respaldo');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('Respaldo'), findsOneWidget);
    });
  });

  group('HermesNotice: movimiento', () {
    testWidgets('entra con fade + deslizamiento corto hacia abajo', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app());
      HermesNotice.of(_ctx(tester)).show(message: 'Copiado');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      final early = tester.getRect(_notices);
      await tester.pump(const Duration(milliseconds: 400));
      final settled = tester.getRect(_notices);
      expect(early.top, lessThan(settled.top), reason: 'viene desde arriba');
      expect(settled.top, 8);
    });

    testWidgets('con reducir movimiento aparece ya en su sitio', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(reduceMotion: true));
      HermesNotice.of(_ctx(tester)).show(message: 'Copiado');
      await tester.pump();
      expect(tester.getRect(_notices).top, 8);
      final opacity = tester.widget<Opacity>(
        find
            .ancestor(of: _notices, matching: find.byType(Opacity))
            .first,
      );
      expect(opacity.opacity, 1);
      HermesNotice.of(_ctx(tester)).clearSnackBars();
      await tester.pump();
      expect(_notices, findsNothing);
    });
  });

  group('HermesNoticeCard', () {
    testWidgets('toda la tarjeta abre su destino', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        _cardHost(
          _sample(
            action: const HermesNoticeAction(label: 'Ir', onPressed: _noop),
            onTap: () => opened++,
          ),
        ),
      );
      expect(find.text('Respuesta lista'), findsOneWidget);
      expect(find.text('Hermes termino el trabajo.'), findsOneWidget);
      expect(find.byTooltip('Descartar'), findsOneWidget);
      await tester.tap(find.text('Respuesta lista'));
      await tester.pump();
      expect(opened, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('el deslizamiento horizontal solo descarta', (tester) async {
      var visible = true;
      var dismissed = 0;
      var opened = 0;
      await tester.pumpWidget(
        _cardHost(
          StatefulBuilder(
            builder: (context, setState) => visible
                ? _sample(
                    noticeKey: const ValueKey('approval-pending'),
                    onTap: () => opened++,
                    onDismissed: () {
                      dismissed++;
                      setState(() => visible = false);
                    },
                  )
                : const SizedBox.shrink(),
          ),
        ),
      );
      await tester.drag(
        find.byKey(const ValueKey('approval-pending')),
        const Offset(-600, 0),
      );
      await tester.pumpAndSettle();
      expect(dismissed, 1);
      expect(opened, 0);
      expect(find.text('Respuesta lista'), findsNothing);
    });

    testWidgets('descartar esta aislado de la accion y mide 48 dp', (
      tester,
    ) async {
      var opened = 0;
      var dismissed = 0;
      var acted = 0;
      await tester.pumpWidget(
        _cardHost(
          _sample(
            action: HermesNoticeAction(label: 'Ir', onPressed: () => acted++),
            onTap: () => opened++,
            onDismissed: () => dismissed++,
          ),
        ),
      );
      final action = tester.getRect(
        find.byKey(const ValueKey('hermes-notice-action')),
      );
      final dismiss = tester.getRect(
        find.byKey(const ValueKey('hermes-notice-dismiss')),
      );
      expect(dismiss.size, const Size(48, 48));
      expect(action.height, greaterThanOrEqualTo(48));
      expect(action.width, greaterThanOrEqualTo(48));
      expect(action.right, lessThanOrEqualTo(dismiss.left));

      await tester.tap(find.byKey(const ValueKey('hermes-notice-dismiss')));
      await tester.pump();
      expect((dismissed, opened, acted), (1, 0, 0));
      await tester.tap(find.byKey(const ValueKey('hermes-notice-action')));
      await tester.pump();
      expect((dismissed, opened, acted), (1, 0, 1));
    });

    for (final theme in ['dark', 'nous']) {
      testWidgets('solo usa tokens del tema: sin barra lateral ($theme)', (
        tester,
      ) async {
        const tint = Color(0xFF12AB34);
        await tester.pumpWidget(
          _cardHost(
            _sample(
              tint: tint,
              action: const HermesNoticeAction(label: 'Ir', onPressed: _noop),
              noticeKey: const ValueKey('neutral-style'),
            ),
            theme: theme,
          ),
        );
        final notice = find.byKey(const ValueKey('neutral-style'));
        final colors = Theme.of(tester.element(notice)).hermes;

        final material = tester.widget<Material>(
          find.descendant(of: notice, matching: find.byType(Material)).first,
        );
        expect(material.color, colors.surface);
        final decorations = find
            .descendant(of: notice, matching: find.byType(DecoratedBox))
            .evaluate()
            .map((e) => (e.widget as DecoratedBox).decoration)
            .whereType<BoxDecoration>()
            .toList();
        final hairline = Border.all(
          color: colors.divider.withValues(alpha: 0.78),
        );
        expect(decorations.any((d) => d.border == hairline), isTrue);

        // Sin barra lateral ni bloques de color: el unico color de estado es
        // el circulo suave de 32 dp (tinte al 14 %) y su glifo.
        expect(
          find.descendant(of: notice, matching: find.byType(ColoredBox)),
          findsNothing,
        );
        final badge = tester.widget<Container>(
          find.byKey(const ValueKey('hermes-notice-badge')),
        );
        final badgeDecoration = badge.decoration! as BoxDecoration;
        expect(badgeDecoration.shape, BoxShape.circle);
        expect(
          badgeDecoration.color,
          Color.alphaBlend(tint.withValues(alpha: 0.14), colors.surface),
        );
        expect(
          tester.getSize(find.byKey(const ValueKey('hermes-notice-badge'))),
          const Size(32, 32),
        );
        for (final decoration in decorations) {
          if (decoration.color != null && decoration.shape != BoxShape.circle) {
            expect(decoration.color!.withValues(alpha: 1), isNot(tint));
          }
        }
        final glyph = tester.widget<Icon>(
          find.byKey(const ValueKey('hermes-notice-icon')),
        );
        expect(
          ThemeContrast.ratio(glyph.color!, badgeDecoration.color!),
          greaterThanOrEqualTo(3.0),
        );
        expect(
          tester.widget<Text>(find.text('Respuesta lista')).style?.color,
          colors.textPrimary,
        );
        expect(
          tester.widget<Text>(find.text('Hermes termino el trabajo.')).style?.color,
          colors.textSecondary,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('mantiene una huella compacta', (tester) async {
      await tester.pumpWidget(
        _cardHost(
          _sample(
            action: const HermesNoticeAction(label: 'Ir', onPressed: _noop),
          ),
        ),
      );
      final size = tester.getSize(find.byKey(_card));
      expect(size.height, lessThanOrEqualTo(80));
      expect(size.height, greaterThanOrEqualTo(56));
      // Solo mensaje, sin titulo ni botones: una pastilla baja.
      await tester.pumpWidget(
        _cardHost(_sample(title: null, message: 'Copiado', showDismiss: false)),
      );
      expect(tester.getSize(find.byKey(_card)).height, lessThanOrEqualTo(60));
    });

    testWidgets('texto x2 a 320 dp no desborda y conserva los objetivos', (
      tester,
    ) async {
      _phone(tester);
      for (final withAction in [false, true]) {
        await tester.pumpWidget(
          _cardHost(
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _sample(
                title: 'Hermes respondio en una conversacion con nombre largo',
                message:
                    'Una respuesta muy larga que tiene que envolverse sin '
                    'desbordar aunque el texto del sistema este al doble de '
                    'tamano en una pantalla de 320 dp de ancho.',
                action: withAction
                    ? const HermesNoticeAction(
                        label: 'Restablecer todo',
                        onPressed: _noop,
                      )
                    : null,
              ),
            ),
            textScale: 2,
          ),
        );
        expect(tester.takeException(), isNull, reason: 'accion=$withAction');
        final rect = tester.getRect(find.byKey(_card));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(320));
        expect(
          tester.getSize(find.byKey(const ValueKey('hermes-notice-dismiss'))),
          const Size(48, 48),
        );
        if (withAction) {
          final action = tester.getRect(
            find.byKey(const ValueKey('hermes-notice-action')),
          );
          expect(action.height, greaterThanOrEqualTo(48));
          expect(action.right, lessThanOrEqualTo(rect.right));
        }
      }
    });

    testWidgets('es un anuncio accesible: region viva con prefijo de severidad', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _cardHost(
          _sample(kind: HermesNoticeKind.error).copyForTest(kindLabel: 'Error'),
        ),
      );
      final node = tester.getSemantics(
        find.bySemanticsLabel('Error. Respuesta lista. Hermes termino el trabajo.'),
      );
      expect(node.flagsCollection.isLiveRegion, isTrue);
      handle.dispose();
    });

    testWidgets('26 temas x 4 severidades: glifo legible y sin errores', (
      tester,
    ) async {
      for (final preset in AppTheme.presets) {
        await tester.pumpWidget(
          _cardHost(
            Column(
              children: [
                for (final kind in HermesNoticeKind.values)
                  _sample(
                    kind: kind,
                    title: null,
                    message: 'Mensaje ${kind.name}',
                    showDismiss: false,
                    noticeKey: ValueKey('card-${kind.name}'),
                    action: const HermesNoticeAction(
                      label: 'Ir',
                      onPressed: _noop,
                    ),
                  ),
              ],
            ),
            theme: preset.id,
          ),
        );
        final colors = Theme.of(
          tester.element(find.byKey(const ValueKey('card-info'))),
        ).hermes;
        for (final kind in HermesNoticeKind.values) {
          final card = find.byKey(ValueKey('card-${kind.name}'));
          final badge = tester.widget<Container>(
            find.descendant(
              of: card,
              matching: find.byKey(const ValueKey('hermes-notice-badge')),
            ),
          );
          final fill = (badge.decoration! as BoxDecoration).color!;
          final glyph = tester.widget<Icon>(
            find.descendant(
              of: card,
              matching: find.byKey(const ValueKey('hermes-notice-icon')),
            ),
          );
          expect(
            ThemeContrast.ratio(glyph.color!, fill),
            greaterThanOrEqualTo(3.0),
            reason: '${preset.id}/${kind.name}',
          );
          expect(
            ThemeContrast.ratio(colors.textPrimary, colors.surface),
            greaterThanOrEqualTo(4.5),
            reason: '${preset.id} texto',
          );
        }
        expect(tester.takeException(), isNull, reason: preset.id);
      }
      expect(
        AppTheme.presets.any((p) => p.brightness == Brightness.light),
        isTrue,
      );
      expect(
        AppTheme.presets.any((p) => p.brightness == Brightness.dark),
        isTrue,
      );
    });
  });
}

void _noop() {}

extension on HermesNoticeCard {
  HermesNoticeCard copyForTest({String? kindLabel}) => HermesNoticeCard(
    noticeKey: noticeKey,
    kind: kind,
    icon: icon,
    tint: tint,
    title: title,
    message: message,
    action: action,
    onTap: onTap,
    onDismissed: onDismissed,
    showDismiss: showDismiss,
    dismissLabel: dismissLabel,
    kindLabel: kindLabel,
  );
}
