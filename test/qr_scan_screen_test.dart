import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/qr_scan_screen.dart';
import 'package:hermes_android/core/services/pairing_link.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/onboarding_fakes.dart';

void main() {
  for (final language in ['es', 'en']) {
    testWidgets(
      '$language: camera denial is one sentence and one paste action at 320/2x',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        ValueChanged<bool>? permission;
        await tester.pumpWidget(
          onboardingHost(
            QrScanScreen(
              cameraBuilder: (_, notify) {
                permission = notify;
                return const SizedBox();
              },
            ),
            language: language,
            scale: 2,
          ),
        );
        await tester.pumpAndSettle();
        permission!(false);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('qr-denied-paste')), findsOneWidget);
        expect(find.byKey(const ValueKey('qr-open-settings')), findsOneWidget);
        expect(find.byKey(const ValueKey('qr-paste')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final language in ['es', 'en']) {
    Widget host(Widget child) => onboardingHost(child, language: language);

    testWidgets('$language: wrong QR is announced and retry resumes scanning', (
      tester,
    ) async {
      ValueChanged<String>? detected;
      await tester.pumpWidget(
        host(
          QrScanScreen(
            cameraBuilder: (scan, _) {
              detected = scan;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      detected!('https://example.invalid/not-a-console-code');
      await tester.pumpAndSettle();
      expect(
        find.text(
          Strings.of(tester.element(find.byType(QrScanScreen))).o2InvalidCode,
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('qr-retry')), findsOneWidget);
      await tapOnboarding(tester, 'qr-retry');
      expect(find.byKey(const ValueKey('qr-paste')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '$language: the denied-camera paste returns the full pairing, never shows its secrets',
      (tester) async {
        ValueChanged<bool>? permission;
        PairingLink? result;
        var reads = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.getData') {
              reads++;
              return {'text': fakeFullPairing.build()};
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
        await tester.pumpWidget(
          host(
            Builder(
              builder: (context) => TextButton(
                child: const Text('Open scanner'),
                onPressed: () async {
                  result = await Navigator.of(context).push<PairingLink>(
                    MaterialPageRoute(
                      builder: (_) => QrScanScreen(
                        cameraBuilder: (_, notify) {
                          permission = notify;
                          return const SizedBox();
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open scanner'));
        await tester.pumpAndSettle();
        expect(reads, 0);
        permission!(false);
        await tester.pumpAndSettle();
        await tapOnboarding(tester, 'qr-denied-paste');
        expect(reads, 1);
        expect(result!.hasDashboardLogin, isTrue);
        expect(result!.dashboardPassword, fakeFullPairing.dashboardPassword);
        expect(find.textContaining('synthetic-panel-password'), findsNothing);
      },
    );

    testWidgets('$language: a camera scan returns only one link', (
      tester,
    ) async {
      ValueChanged<String>? detected;
      var results = 0;
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) => TextButton(
              child: const Text('Open scanner'),
              onPressed: () async {
                final result = await Navigator.of(context).push<PairingLink>(
                  MaterialPageRoute(
                    builder: (_) => QrScanScreen(
                      cameraBuilder: (scan, _) {
                        detected = scan;
                        return const SizedBox();
                      },
                    ),
                  ),
                );
                if (result != null) results++;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open scanner'));
      await tester.pumpAndSettle();
      detected!(fakeFullPairing.build());
      detected!(fakeFullPairing.build());
      await tester.pumpAndSettle();
      expect(results, 1);
    });
  }
}
