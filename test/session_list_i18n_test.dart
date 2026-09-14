import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations_en.dart';
import 'package:hermes_android/l10n/app_localizations_es.dart';

void main() {
  test('session list labels and relative times follow the selected locale', () {
    final en = StringsEn();
    final es = StringsEs();

    expect(en.slFilterAll, 'Chats');
    expect(en.slFilterAutomation, 'Automation');
    expect(en.slFilterEverything, 'All');
    expect(en.slFilterArchived, 'Archive');
    expect(en.slEmptyAutomationTitle, 'No automation sessions');
    expect(en.slReportBadge, 'report');
    expect(en.slRelativeNow, 'now');
    expect(en.slRelativeMinutes(2), '2m ago');
    expect(en.slRelativeHours(3), '3h ago');
    expect(en.slRelativeDays(4), '4d ago');

    expect(es.slFilterAll, 'Chats');
    expect(es.slFilterAutomation, 'Automatización');
    expect(es.slFilterEverything, 'Todo');
    expect(es.slFilterArchived, 'Archivo');
    expect(es.slEmptyAutomationTitle, 'Sin sesiones de automatización');
    expect(es.slReportBadge, 'informe');
    expect(es.slRelativeNow, 'ahora');
    expect(es.slRelativeMinutes(2), 'hace 2m');
    expect(es.slRelativeHours(3), 'hace 3h');
    expect(es.slRelativeDays(4), 'hace 4d');
  });

  test('steering ambiguity states that delivery was not confirmed', () {
    final en = StringsEn();
    final es = StringsEs();
    expect(es.chaSteerFailed, contains('No se confirmó el envío'));
    expect(en.chaSteerFailed, contains('was not confirmed'));
  });
}
