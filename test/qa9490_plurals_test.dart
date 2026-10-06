import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// QA 9490: Models showed "IA Core · 1 modelos". Every count string in
// Models agrees in number with its count in both locales.
void main() {
  final es = lookupStrings(const Locale('es'));
  final en = lookupStrings(const Locale('en'));

  test('model count', () {
    expect(es.mdlModelCount(0), '0 modelos');
    expect(es.mdlModelCount(1), '1 modelo');
    expect(es.mdlModelCount(2), '2 modelos');
    expect(en.mdlModelCount(0), '0 models');
    expect(en.mdlModelCount(1), '1 model');
    expect(en.mdlModelCount(2), '2 models');
  });

  test('unconfigured providers hint', () {
    expect(es.mdlUnconfiguredHint(0), '0 disponibles · pulsa para configurar');
    expect(es.mdlUnconfiguredHint(1), '1 disponible · pulsa para configurar');
    expect(es.mdlUnconfiguredHint(2), '2 disponibles · pulsa para configurar');
    expect(en.mdlUnconfiguredHint(1), '1 available · tap to configure');
    expect(en.mdlUnconfiguredHint(2), '2 available · tap to configure');
  });

  test('customized auxiliary functions', () {
    expect(es.mdlAuxCustomized(1, 1), '1 personalizada · 1 función');
    expect(es.mdlAuxCustomized(2, 2), '2 personalizadas · 2 funciones');
    expect(es.mdlAuxCustomized(1, 0), '1 personalizada · 0 funciones');
    expect(en.mdlAuxCustomized(1, 1), '1 custom · 1 function');
    expect(en.mdlAuxCustomized(2, 0), '2 custom · 0 functions');
    expect(en.mdlAuxCustomized(2, 2), '2 custom · 2 functions');
  });
}
