// The connection help gives the real steps for a computer that already runs
// Hermes, once each, as the exact text Hermes documents. Nothing in it
// installs or downloads anything.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/command_block.dart';
import 'package:hermes_android/core/widgets/platform_setup_commands.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host(Widget child, {Locale locale = const Locale('es')}) => MaterialApp(
  locale: locale,
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

List<String> _commands(WidgetTester tester) => tester
    .widgetList<CommandBlock>(find.byType(CommandBlock))
    .map((block) => block.command)
    .toList();

void main() {
  testWidgets('the two things the computer needs, each said once', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const PlatformConnectionInstructions()));

    expect(
      find.text('1 · El Dashboard, con usuario y contraseña'),
      findsOneWidget,
    );
    expect(find.text('2 · El Gateway, con su clave'), findsOneWidget);
    expect(_commands(tester), [
      'HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin\n'
          'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=tu-contrasena-nueva',
      'hermes dashboard --no-open --host 0.0.0.0 --port 9119',
      'openssl rand -hex 32',
      'API_SERVER_ENABLED=true\n'
          'API_SERVER_HOST=0.0.0.0\n'
          'API_SERVER_KEY=pega-aqui-la-clave',
      'hermes gateway',
    ]);
    // It says where this happens and where it must not be exposed.
    expect(
      find.text(
        'Solo en tu red privada o por Tailscale: no abras estos puertos a '
        'internet.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('it contains no installer and no download, in either language', (
    tester,
  ) async {
    for (final locale in const [Locale('es'), Locale('en')]) {
      await tester.pumpWidget(
        _host(
          PlatformConnectionInstructions(key: ValueKey(locale)),
          locale: locale,
        ),
      );
      final shown = [
        ..._commands(tester),
        ...tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? ''),
      ].join('\n');
      for (final forbidden in [
        'hermes-mobile-setup',
        'hermes-pair',
        'hermes_bridge',
        'bridge',
        'curl',
        'iex',
        'http',
        'sudo',
        '9131',
      ]) {
        expect(
          shown.toLowerCase(),
          isNot(contains(forbidden)),
          reason: forbidden,
        );
      }
    }
  });

  testWidgets('copying a step copies exactly that text', (tester) async {
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
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(_host(const PlatformConnectionInstructions()));

    final run = find.byKey(const ValueKey('setup-step-dashboard-run'));
    await tester.ensureVisible(run);
    await tester.tap(
      find.descendant(
        of: run,
        matching: find.byWidgetPredicate((w) => w is TextButton),
      ),
    );
    await tester.pump();

    expect(copied, PlatformConnectionInstructions.dashboardCommand);
  });
}
