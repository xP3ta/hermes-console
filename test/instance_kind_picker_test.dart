import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/widgets/instance_kind_picker.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/design_shots.dart';
import 'support/onboarding_fakes.dart';

Finder _tile(InstanceKind kind) =>
    find.byKey(ValueKey('instance-kind-${kind.storageKey}'));

void main() {
  const words = {
    'es': ['En casa', 'Servidor', 'Red privada', 'Este ordenador'],
    'en': ['At home', 'Server', 'Private network', 'This computer'],
  };

  for (final language in ['es', 'en']) {
    for (final (width, scale) in [(390.0, 1.0), (320.0, 1.0), (320.0, 2.0)]) {
      testWidgets('$language ${width.toInt()} dp x$scale: four tiles, whole '
          'words, no overflow', (tester) async {
        await loadDesignFonts();
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var changed = <InstanceKind>[];
        await tester.pumpWidget(
          onboardingHost(
            Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: SingleChildScrollView(
                  child: InstanceKindPicker(
                    title: 'Title',
                    value: InstanceKind.homelab,
                    onChanged: changed.add,
                  ),
                ),
              ),
            ),
            language: language,
            scale: scale,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (final kind in kOfferedInstanceKinds) {
          expect(_tile(kind), findsOneWidget);
          final box = tester.getSize(_tile(kind));
          expect(box.height, greaterThanOrEqualTo(48));
          expect(box.width, greaterThanOrEqualTo(48));
        }
        for (var i = 0; i < kOfferedInstanceKinds.length; i++) {
          final text = find.text(words[language]![i]);
          expect(text, findsOneWidget);
          // The label is laid out whole, inside its tile.
          final label = tester.getRect(text);
          final tile = tester.getRect(_tile(kOfferedInstanceKinds[i]));
          expect(label.left, greaterThanOrEqualTo(tile.left));
          expect(label.right, lessThanOrEqualTo(tile.right));
          expect(label.bottom, lessThanOrEqualTo(tile.bottom));
        }
        // One row of four when it fits, two rows of two when it does not.
        final tops = {
          for (final kind in kOfferedInstanceKinds)
            tester.getTopLeft(_tile(kind)).dy.round(),
        };
        if (width == 390 && scale == 1) {
          expect(tops, hasLength(1));
        } else {
          expect(tops, hasLength(2));
        }
        // Every tile stays inside the gutters.
        for (final kind in kOfferedInstanceKinds) {
          final rect = tester.getRect(_tile(kind));
          expect(rect.left, greaterThanOrEqualTo(24 - .01));
          expect(rect.right, lessThanOrEqualTo(width - 24 + .01));
        }
        // The icon of each kind is the one the rest of the app draws.
        for (final kind in kOfferedInstanceKinds) {
          expect(
            find.descendant(
              of: _tile(kind),
              matching: find.byIcon(instanceKindIcon(kind)),
            ),
            findsOneWidget,
          );
        }
        await tester.tap(_tile(InstanceKind.pc));
        expect(changed, [InstanceKind.pc]);
      });
    }
  }

  testWidgets('the selected tile is the only one marked selected', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      onboardingHost(
        Scaffold(
          body: InstanceKindPicker(value: InstanceKind.vps, onChanged: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    bool selected(InstanceKind k) =>
        tester.getSemantics(_tile(k)).flagsCollection.isSelected ==
        Tristate.isTrue;
    expect(selected(InstanceKind.vps), isTrue);
    expect(selected(InstanceKind.homelab), isFalse);
    expect(selected(InstanceKind.pc), isFalse);
    expect(selected(InstanceKind.tailscale), isFalse);
    handle.dispose();
  });

  testWidgets('a saved on-device connection keeps its tile, new ones do not '
      'get it', (tester) async {
    await tester.pumpWidget(
      onboardingHost(
        Scaffold(
          body: SingleChildScrollView(
            child: InstanceKindPicker(
              value: InstanceKind.localhost,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_tile(InstanceKind.localhost), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);
    await tester.pumpWidget(
      onboardingHost(
        Scaffold(
          body: InstanceKindPicker(value: InstanceKind.pc, onChanged: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_tile(InstanceKind.localhost), findsNothing);
  });

  for (final motion in [true, false]) {
    testWidgets(
      'selection ${motion ? 'tints over 150 ms' : 'is instant with reduced motion'}',
      (tester) async {
        var value = InstanceKind.homelab;
        await tester.pumpWidget(
          onboardingHost(
            StatefulBuilder(
              builder: (context, setState) => Scaffold(
                body: InstanceKindPicker(
                  value: value,
                  onChanged: (k) => setState(() => value = k),
                ),
              ),
            ),
            motion: motion,
          ),
        );
        await tester.pumpAndSettle();
        Color? fill() {
          final box = tester.renderObject<RenderDecoratedBox>(
            find
                .descendant(
                  of: _tile(InstanceKind.vps),
                  matching: find.byType(DecoratedBox),
                )
                .first,
          );
          return (box.decoration as BoxDecoration).color;
        }

        final before = fill();
        await tester.tap(_tile(InstanceKind.vps));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));
        final middle = fill();
        await tester.pump(const Duration(milliseconds: 100));
        final end = fill();
        expect(end, isNot(before));
        if (motion) {
          expect(middle, isNot(end));
          expect(middle, isNot(before));
        } else {
          expect(middle, end);
        }
      },
    );
  }

  testWidgets('Strings carry both languages', (tester) async {
    for (final language in ['es', 'en']) {
      await tester.pumpWidget(
        onboardingHost(
          Scaffold(
            body: InstanceKindPicker(value: InstanceKind.pc, onChanged: (_) {}),
          ),
          language: language,
        ),
      );
      await tester.pumpAndSettle();
      final s = Strings.of(tester.element(find.byType(InstanceKindPicker)));
      expect([
        instanceKindLabel(s, InstanceKind.homelab),
        instanceKindLabel(s, InstanceKind.vps),
        instanceKindLabel(s, InstanceKind.tailscale),
        instanceKindLabel(s, InstanceKind.pc),
      ], words[language]);
    }
  });
}
