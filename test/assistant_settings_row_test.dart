import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/assistant_settings_row.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget host(Widget child) => MaterialApp(
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  locale: const Locale('en'),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('shows nothing when the native side does not say', (t) async {
    await t.pumpWidget(
      host(
        AssistantSettingsGroup(
          load: () async => null,
          openSettings: () async => true,
        ),
      ),
    );
    await t.pump();
    expect(find.byKey(const ValueKey('assistant_settings_row')), findsNothing);
  });

  testWidgets('says whether Console is the assistant and opens settings', (
    t,
  ) async {
    var opened = 0;
    var isDefault = false;
    await t.pumpWidget(
      host(
        AssistantSettingsGroup(
          load: () async => isDefault,
          openSettings: () async {
            opened++;
            return true;
          },
        ),
      ),
    );
    await t.pump();
    expect(find.textContaining('never reads the screen'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('assistant_settings_row')));
    expect(opened, 1);

    isDefault = true;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(find.textContaining('invoking it opens a new chat'), findsOneWidget);
  });
}
