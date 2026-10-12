import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/feedback/feedback_policy.dart';
import 'package:hermes_android/core/feedback/screen_help.dart';
import 'package:hermes_android/core/screens/embed_settings_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_notice.dart';
import 'package:hermes_android/core/widgets/chat/embeds/embed_consent_store.dart';
import 'package:hermes_android/core/widgets/chat/embeds/embed_detector.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/quiet_feedback.dart';

/// Owner rule: routine confirmations never dirty the window; errors, undo,
/// and critical messages still do. Screen readers hear everything.

Widget _app(Widget Function(BuildContext) body, {Locale? locale}) =>
    MaterialApp(
      theme: AppTheme.fromId('github'),
      locale: locale ?? const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: Scaffold(body: Builder(builder: body)),
    );

Finder get _anyNotice => find.byType(HermesNoticeCard);

void main() {
  group('FeedbackPolicy', () {
    test('only routine feedback is invisible', () {
      expect(FeedbackPolicy.isVisual(FeedbackKind.routine), isFalse);
      expect(FeedbackPolicy.isVisual(FeedbackKind.error), isTrue);
      expect(FeedbackPolicy.isVisual(FeedbackKind.undo), isTrue);
      expect(FeedbackPolicy.isVisual(FeedbackKind.critical), isTrue);
    });
  });

  group('AppFeedback.notify', () {
    testWidgets('routine draws nothing but is announced to screen readers', (
      tester,
    ) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        _app((context) {
          ctx = context;
          return const SizedBox.expand();
        }),
      );
      tester.takeAnnouncements();

      final handle = AppFeedback.notify(ctx, FeedbackKind.routine, 'Guardado');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(handle, isNull);
      expect(_anyNotice, findsNothing);
      expect(find.text('Guardado'), findsNothing);
      expect(
        tester.takeAnnouncements().map((a) => a.message),
        contains('Guardado'),
      );
    });

    testWidgets('error is drawn with the error tone', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        _app((context) {
          ctx = context;
          return const SizedBox.expand();
        }),
      );

      AppFeedback.notify(ctx, FeedbackKind.error, 'No se pudo guardar');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(_anyNotice, findsOneWidget);
      expect(find.text('No se pudo guardar'), findsOneWidget);
      final card = tester.widget<HermesNoticeCard>(_anyNotice);
      expect(card.kind, HermesNoticeKind.error);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('error with warning uses the warning tone', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        _app((context) {
          ctx = context;
          return const SizedBox.expand();
        }),
      );

      AppFeedback.notify(
        ctx,
        FeedbackKind.error,
        'Solo lectura',
        warning: true,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final card = tester.widget<HermesNoticeCard>(_anyNotice);
      expect(card.kind, HermesNoticeKind.warning);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('undo is drawn with its action and the action runs', (
      tester,
    ) async {
      late BuildContext ctx;
      var undone = 0;
      await tester.pumpWidget(
        _app((context) {
          ctx = context;
          return const SizedBox.expand();
        }),
      );

      AppFeedback.notify(
        ctx,
        FeedbackKind.undo,
        'Proveedor oculto',
        action: HermesNoticeAction(
          label: 'Deshacer',
          onPressed: () => undone++,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Proveedor oculto'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hermes-notice-action')));
      await tester.pump();
      expect(undone, 1);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('critical is drawn', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        _app((context) {
          ctx = context;
          return const SizedBox.expand();
        }),
      );

      AppFeedback.notify(ctx, FeedbackKind.critical, 'Claves borradas');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Claves borradas'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a sink captured before an await still applies the policy', (
      tester,
    ) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        _app((context) {
          ctx = context;
          return const SizedBox.expand();
        }),
      );
      tester.takeAnnouncements();
      final sink = AppFeedback.of(ctx);

      sink.routine('Copiado');
      sink.error('Falló la copia');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Copiado'), findsNothing);
      expect(find.text('Falló la copia'), findsOneWidget);
      expect(
        tester.takeAnnouncements().map((a) => a.message),
        contains('Copiado'),
      );
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('ofNavigator applies the same policy', (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          theme: AppTheme.fromId('github'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: const Scaffold(),
        ),
      );
      tester.takeAnnouncements();
      final sink = AppFeedback.ofNavigator(navigatorKey.currentState)!;

      sink.routine('Listo');
      await tester.pump();
      expect(find.text('Listo'), findsNothing);
      expect(
        tester.takeAnnouncements().map((a) => a.message),
        contains('Listo'),
      );

      sink.error('Enlace no válido');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Enlace no válido'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(AppFeedback.ofNavigator(null), isNull);
    });
  });

  group('ScreenHelpButton', () {
    testWidgets('keeps the explanation off screen until asked', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.fromId('github'),
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: Scaffold(
            appBar: AppBar(
              actions: const [
                ScreenHelpButton(
                  title: 'Pantalla',
                  paragraphs: ['Primera explicación', 'Segunda explicación'],
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Primera explicación'), findsNothing);
      final button = find.byKey(const ValueKey('screen-help-button'));
      expect(button, findsOneWidget);
      expect(tester.widget<IconButton>(button).tooltip, '¿Cómo funciona?');

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Pantalla'), findsOneWidget);
      expect(find.text('Primera explicación'), findsOneWidget);
      expect(find.text('Segunda explicación'), findsOneWidget);
    });
  });

  group('a real screen under the policy (embed settings)', () {
    late EmbedConsentStore consent;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      consent = EmbedConsentStore.forTesting(
        await SharedPreferences.getInstance(),
      );
    });

    Widget app() => MaterialApp(
      theme: AppTheme.fromId('github'),
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: EmbedSettingsScreen(store: consent),
    );

    testWidgets('the intro paragraph lives behind (?)', (tester) async {
      await tester.pumpWidget(app());
      final s = Strings.of(tester.element(find.byType(EmbedSettingsScreen)));
      expect(find.text(s.embedSettingsIntro), findsNothing);

      await tester.tap(find.byKey(const ValueKey('screen-help-button')));
      await tester.pumpAndSettle();
      expect(find.text(s.embedSettingsIntro), findsOneWidget);
    });

    testWidgets('clearing allowed services is routine: no toast, announced', (
      tester,
    ) async {
      await consent.setMode(EmbedType.youtube, EmbedMode.always);
      await tester.pumpWidget(app());
      final s = Strings.of(tester.element(find.byType(EmbedSettingsScreen)));
      tester.takeAnnouncements();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('embed-clear-allowed')),
        200,
      );
      await tester.tap(find.byKey(const ValueKey('embed-clear-allowed')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(consent.modeFor(EmbedType.youtube), EmbedMode.ask);
      expect(_anyNotice, findsNothing);
      expectRoutineFeedback(tester, s.embedSettingsCleared);
    });
  });
}
