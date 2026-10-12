// "Configuración avanzada" of a profile: the heading, each label, each field
// and its counter have their own line, and "Guardar" says whether there is
// anything to save.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/bot_profile_settings_screen.dart';
import 'package:hermes_android/core/services/bot_profile_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _description = 'Hermes: orquestador';

BotProfileClient _gateway() => BotProfileClient((method, params) async {
  if (method == 'profiles.describe') {
    return {
      'description': _description,
      'soul': 'Plain claims over adjectives; when unsure, say so plainly.',
      'skills': [
        {'name': 'a', 'enabled': true},
      ],
    };
  }
  return {
    'applied': {'description': true},
  };
});

Future<void> _pump(
  WidgetTester tester, {
  double width = 390,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 1600);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: BotProfileSettingsScreen(profile: 'default', gateway: _gateway()),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const _descriptionField = ValueKey('bot-settings-description');
const _soulField = ValueKey('bot-settings-soul');

void main() {
  for (final (width, scale) in const [
    (320.0, 1.0),
    (390.0, 1.0),
    (412.0, 1.0),
    (390.0, 2.0),
  ]) {
    testWidgets('qa9529: heading, labels, fields and counters do not touch at '
        '${width.toInt()} dp, text ×${scale.toInt()}', (tester) async {
      await _pump(tester, width: width, textScale: scale);
      final heading = tester.getRect(
        find.byKey(const ValueKey('bot-settings-heading')),
      );
      final label = tester.getRect(find.text('Descripción'));
      final field = tester.getRect(find.byKey(_descriptionField));
      final input = tester.getRect(
        find.descendant(
          of: find.byKey(_descriptionField),
          matching: find.byType(EditableText),
        ),
      );
      final counter = tester.getRect(find.text('${_description.length}/2048'));
      final nextLabel = tester.getRect(find.text('SOUL.md'));
      final nextField = tester.getRect(find.byKey(_soulField));

      // Heading, then the label, then its field, each under the other.
      expect(label.top, greaterThanOrEqualTo(heading.bottom + 8));
      expect(field.top, greaterThanOrEqualTo(label.bottom));
      // The counter is under what is typed, and the next label under it.
      expect(counter.top, greaterThanOrEqualTo(input.bottom));
      expect(nextLabel.top, greaterThanOrEqualTo(counter.bottom));
      expect(nextField.top, greaterThanOrEqualTo(nextLabel.bottom));
      // One left edge for the heading and the labels' fields.
      expect(field.left, heading.left);
      expect(nextField.left, heading.left);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('qa9529: «Guardar» stays at the bottom and says whether there is '
      'anything to save', (tester) async {
    await _pump(tester);
    const save = ValueKey('bot-settings-save');
    expect(find.text('Sin cambios pendientes'), findsOneWidget);
    expect(tester.widget<HermesPrimaryButton>(find.byKey(save)).onTap, isNull);
    // Not a row of the form: it does not scroll away with it.
    expect(
      find.ancestor(of: find.byKey(save), matching: find.byType(ListView)),
      findsNothing,
    );

    await tester.enterText(find.byKey(_descriptionField), 'Otra descripción');
    await tester.pump();
    expect(find.text('Cambios sin guardar'), findsOneWidget);
    expect(find.text('Sin cambios pendientes'), findsNothing);
    expect(
      tester.widget<HermesPrimaryButton>(find.byKey(save)).onTap,
      isNotNull,
    );

    // Back to what the server has: nothing to save again.
    await tester.enterText(find.byKey(_descriptionField), _description);
    await tester.pump();
    expect(find.text('Sin cambios pendientes'), findsOneWidget);
  });
}
