import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart'
    show kChatCodeFontFamily;
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/interactive_prompt_card.dart'
    show blockingRequestSurface;
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    theme: AppTheme.fromMode(AppThemeMode.dark),
    home: Scaffold(body: child),
  );

  testWidgets('ChatApprovalCard pinta título, comando y los 4 alcances', (
    tester,
  ) async {
    final taps = <String>[];
    await tester.pumpWidget(
      host(
        // companion: null → cae al icono de candado (sin depender de assets).
        ChatApprovalCard(
          approval: const {
            'command': 'ls -la /home',
            'description': 'run_shell',
          },
          busy: false,
          onChoice: taps.add,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Hermes pide tu permiso'), findsOneWidget);
    expect(find.text('ls -la /home'), findsOneWidget);
    // Acciones principales + alcances ampliados.
    expect(find.text('Permitir'), findsOneWidget);
    expect(find.text('Denegar'), findsOneWidget);
    expect(find.text('Esta sesión'), findsOneWidget);
    expect(find.text('Siempre'), findsOneWidget);

    await tester.tap(find.text('Permitir'));
    await tester.tap(find.text('Siempre'));
    await tester.pumpAndSettle();
    // Ola 5: «Siempre» asks first, as Desktop (tool/approval.tsx:390-416).
    expect(taps, ['once']);
    await tester.tap(find.byKey(const ValueKey('approval-always-confirm')));
    await tester.pumpAndSettle();
    expect(taps, ['once', 'always']);
  });

  testWidgets('«Siempre» shows the command and pattern; Cancelar sends '
      'nothing', (tester) async {
    final taps = <String>[];
    await tester.pumpWidget(
      host(
        ChatApprovalCard(
          approval: const {
            'command': 'rm -rf build',
            'description': 'recursive delete',
            'pattern_key': 'rm -rf',
          },
          busy: false,
          onChoice: taps.add,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('approval-always')));
    await tester.pumpAndSettle();
    final dialog = find.byKey(const ValueKey('approval-always-dialog'));
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(
        of: dialog,
        matching: find.text('¿Permitir siempre este comando?'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dialog,
        matching: find.textContaining('“recursive delete”'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dialog,
        matching: find.textContaining('rm -rf build'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('approval-always-cancel')));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(taps, isEmpty);
  });

  testWidgets('el comando se puede copiar (formato código)', (tester) async {
    // Interceptamos el canal del portapapeles para verificar el copiado.
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );

    await tester.pumpWidget(
      host(
        ChatApprovalCard(
          approval: const {
            'command': 'rm -f /tmp/x',
            'description': 'run_shell',
          },
          busy: false,
          onChoice: (_) {},
        ),
      ),
    );
    await tester.pump();

    // El botón de copiar de la caja del comando (icono content_copy).
    await tester.tap(find.byIcon(Icons.content_copy));
    await tester.pump();
    expect(copied, 'rm -f /tmp/x');
    // Drena el temporizador de 900 ms que repone el icono (evita "Timer pending").
    await tester.pump(const Duration(seconds: 1));

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  testWidgets('busy bloquea las pulsaciones', (tester) async {
    final taps = <String>[];
    await tester.pumpWidget(
      host(
        ChatApprovalCard(
          approval: const {'command': 'rm -rf x'},
          busy: true,
          onChoice: taps.add,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Permitir'));
    expect(taps, isEmpty);
  });

  // Ola 5 (AUDITORIA-PULIDO §2.16): the request sits on the accent's tint
  // with radius 22 (v25 `.apv`), «Permitir» is the primary action and
  // «Denegar» neutral, copying is a 48 dp button, the command in the
  // theme's mono, and an answer in flight shows.
  group('Ola 5 look', () {
    const approval = {
      'command': 'git push origin main',
      'description': 'git',
    };

    Future<HermesThemeColors> pump(
      WidgetTester tester, {
      bool busy = false,
    }) async {
      await tester.pumpWidget(
        host(
          ChatApprovalCard(
            approval: approval,
            busy: busy,
            onChoice: (_) {},
          ),
        ),
      );
      await tester.pump();
      return Theme.of(tester.element(find.byType(ChatApprovalCard))).hermes;
    }

    testWidgets('accent surface with radius 22', (tester) async {
      final colors = await pump(tester);
      final box = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('approval-card-surface')),
      );
      final decoration = box.decoration as BoxDecoration;
      expect(decoration.color, blockingRequestSurface(colors));
      expect(decoration.borderRadius, BorderRadius.circular(22));
    });

    testWidgets('«Permitir» filled in the accent, «Denegar» neutral', (
      tester,
    ) async {
      final colors = await pump(tester);
      Color? background(String key) => tester
          .widget<FilledButton>(
            find.descendant(
              of: find.byKey(ValueKey(key)),
              matching: find.byWidgetPredicate((w) => w is FilledButton),
            ),
          )
          .style!
          .backgroundColor!
          .resolve(const <WidgetState>{});
      expect(background('approval-allow'), colors.accent);
      expect(
        background('approval-deny'),
        colors.textPrimary.withValues(alpha: 0.14),
      );
      expect(background('approval-deny'), isNot(colors.error));
    });

    testWidgets('copy is a 48 dp button TalkBack can name', (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester);
      final copy = find.byKey(const ValueKey('approval-copy-command'));
      final size = tester.getSize(copy);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(find.byTooltip('Copiar comando'), findsOneWidget);
      expect(
        tester.getSemantics(copy),
        isSemantics(isButton: true, hasTapAction: true),
      );
      semantics.dispose();
    });

    testWidgets('the command uses the theme mono', (tester) async {
      await pump(tester);
      final text = tester.widget<Text>(find.text('git push origin main'));
      expect(text.style?.fontFamily, kChatCodeFontFamily);
    });

    testWidgets('an answer in flight shows and is announced', (tester) async {
      await pump(tester, busy: true);
      expect(
        find.byKey(const ValueKey('approval-responding')),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });
}
