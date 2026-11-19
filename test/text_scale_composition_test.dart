// Review m5 (console-reddit-independent-review.md):
//  * composeAppTextScaler linearised Android 14's non-linear text scale
//    (`system.scale(1.0) * app`), so large text grew past what the system
//    asked for and the system curve was lost.
//  * The main ChatScreen was not part of the text size sweep (report §7.8).
//
// The composed scaler applies the app size to the font size and then the
// system's own curve: `system.scale(fontSize * app)`. It is never a cap.

import 'package:flutter/painting.dart';
import 'package:flutter/material.dart' show Scrollable, ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/home_dashboard_screen.dart';
import 'package:hermes_android/core/services/font_size_service.dart';

import 'support/a11y_main_screen_harness.dart';

/// A non-linear system scale like Android 14's: small text doubled, large
/// text grows by a fixed amount past 14.
final class _Curve extends TextScaler {
  const _Curve();
  @override
  double scale(double fontSize) =>
      fontSize <= 14 ? fontSize * 2 : 28 + (fontSize - 14);
  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => 2;
  @override
  bool operator ==(Object other) => other is _Curve;
  @override
  int get hashCode => 7;
}

/// Like Flutter's system scaler: reads the current setting on every call.
// ignore: must_be_immutable
final class _LiveScaler extends TextScaler {
  double factor = 1;
  @override
  double scale(double fontSize) => fontSize * factor;
  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => factor;
}

void main() {
  group('composeAppTextScaler', () {
    test('[RED] keeps the system curve: scale(f) == system.scale(f * app)', () {
      const system = _Curve();
      final composed = composeAppTextScaler(system, 1.1);
      for (final size in [10.0, 14.0, 20.0, 32.0]) {
        expect(
          composed.scale(size),
          closeTo(system.scale(size * 1.1), 1e-9),
          reason: 'font $size',
        );
      }
    });

    test('[CONTROL] a linear system scale composes to the product', () {
      final composed = composeAppTextScaler(const TextScaler.linear(1.3), 1.5);
      expect(composed.scale(14), closeTo(14 * 1.3 * 1.5, 1e-9));
      // ignore: deprecated_member_use
      expect(composed.textScaleFactor, closeTo(1.3 * 1.5, 1e-9));
    });

    test('[CONTROL] never smaller than the system at A+ (no cap)', () {
      const system = _Curve();
      for (final app in [1.0, 1.1, 1.65]) {
        final composed = composeAppTextScaler(system, app);
        for (final size in [10.0, 14.0, 20.0, 32.0]) {
          expect(
            composed.scale(size),
            greaterThanOrEqualTo(system.scale(size) - 1e-9),
          );
        }
      }
    });

    test('[CONTROL] equal inputs give equal scalers (no needless rebuilds)', () {
      expect(
        composeAppTextScaler(const TextScaler.linear(1.3), 1.1),
        composeAppTextScaler(const TextScaler.linear(1.3), 1.1),
      );
      expect(
        composeAppTextScaler(const TextScaler.linear(1.3), 1.1),
        isNot(composeAppTextScaler(const TextScaler.linear(1.3), 1.2)),
      );
    });

    // Found by kbc1215_covered_route_inset_test in run r2regress1: wrapping
    // Flutter's live system scaler let a covered route (frozen MediaQuery)
    // change size behind its data. The composition is a value.
    test('the composed scaler is a value: a later change of a live system '
        'scaler does not leak into it', () {
      final live = _LiveScaler()..factor = 1.0;
      final composed = composeAppTextScaler(live, 1.1);
      final before = composed.scale(10);
      live.factor = 1.2;
      expect(composed.scale(10), before);
      expect(before, closeTo(11, 1e-9));
    });

    test('[CONTROL] a local clamp still applies on top of the composition', () {
      final composed = composeAppTextScaler(const TextScaler.linear(2), 1.1);
      expect(composed.clamp(maxScaleFactor: 1.3).scale(10), closeTo(13, 1e-9));
    });
  });

  group('Home welcome (no instance yet) at the largest sizes', () {
    setUp(installA11yPlatformMocks);
    tearDown(clearA11yPlatformMocks);

    // Found by the main-chat sweep (run r2green1, pre-fix code): with
    // Android at 200 % and Hermes at 150 % the welcome column
    // (home_dashboard_screen.dart _EmptyHomeState) overflowed a 360×690
    // phone by 136 px. It now scrolls only when it does not fit.
    for (final (system, factor) in [(2.0, 1.5), (2.0, 1.0), (1.3, 1.5)]) {
      final effective = system * FontSizeService.defaultScale * factor;
      // RED on the pre-fix code only at 3.3× (run r2red_layout); the other
      // two are range points that already passed.
      testWidgets('RANGE home system=$system factor=$factor: no overflow '
          '(${effective.toStringAsFixed(3)}x), Connect clear of the dock', (
        tester,
      ) async {
        useA11yPhoneView(tester);
        final manager = await createA11yManager();
        await tester.pumpWidget(
          a11yHost(HomeDashboardScreen(connManager: manager), textScale: effective),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull);
        final connect = find.text('Connect');
        // Centred, as a reader scrolls it: the dock floats over the bottom.
        await Scrollable.ensureVisible(
          tester.element(connect.first),
          alignment: 0.5,
        );
        await tester.pump();
        expect(connect.hitTestable(), findsWidgets);
      });
    }
  });

  group("[SWEEP] main ChatScreen with the reader's text size", () {
    setUp(installA11yPlatformMocks);
    tearDown(clearA11yPlatformMocks);

    // Android 100 %, 130 % and 200 % × the range ends (85 % and 150 %).
    for (final (system, factor) in [
      for (final system in [1.0, 1.3, 2.0])
        for (final factor in [FontSizeService.minFactor, FontSizeService.maxFactor])
          (system, factor),
      // Where the main chat stops being usable with Android at 200 %.
      for (final factor in [1.0, 1.2, 1.3, 1.4]) (2.0, factor),
      // Around the composer's large-text threshold (effective 1.5): common
      // Android sizes at the default reader size, and just past it.
      for (final system in [1.15, 1.3, 1.5, 1.8]) (system, 1.0),
      (1.3, 1.05),
      (1.3, 1.15),
    ]) {
      {
        final effective = system * FontSizeService.defaultScale * factor;
        // Run r2sweep_chat: from a 120 % reader size with Android at 200 %
        // on 360×690 the empty composer's hint wrapped over ~4.5 lines and
        // the user bubble overlapped the composer. Every case must pass
        // (owner decision, 2026-11-14: not a skip, not an accepted limit).
        testWidgets('RANGE chat system=$system factor=$factor '
            '(${effective.toStringAsFixed(3)}x)', (tester) async {
          useA11yPhoneView(tester);
          await pumpA11yChat(
            tester,
            textScale: system,
            textSizeFactor: factor,
          );
          final chrome = {
            'menu': find.byTooltip('Menu'),
            'views': find.byKey(const ValueKey('chat-views-button')),
            'header pill': find.byKey(const ValueKey('chat-header-pill')),
            'composer': find.byKey(const ValueKey('chat-composer-host')),
          };
          await expectA11yLayoutUsable(tester, {
            ...chrome,
            'user message': find.text('Review the release').last,
            'edit message': find.byTooltip('Edit message'),
            'copy message': find.byTooltip('Copy message'),
          }, textScale: effective);
          // At the largest sizes the transcript is longer than the screen
          // and builds lazily: scroll to the answer, as a reader would.
          final answer = find.text('The release is ready.');
          if (answer.evaluate().isEmpty) {
            final transcript = find
                .ancestor(
                  of: find.text('Review the release').last,
                  matching: find.byType(Scrollable),
                )
                .first;
            for (final delta in [200.0, -200.0]) {
              if (answer.evaluate().isNotEmpty) break;
              try {
                await tester.scrollUntilVisible(
                  answer,
                  delta,
                  scrollable: transcript,
                  maxScrolls: 40,
                );
              } on StateError {
                // Wrong direction: try the other one.
              }
            }
          }
          await expectA11yLayoutUsable(tester, {
            ...chrome,
            'assistant message': answer,
          }, textScale: effective);
        });
      }
    }
  });
}
