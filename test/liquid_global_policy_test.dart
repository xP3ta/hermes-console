import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/liquid_glass.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/core/theme/app_theme.dart';

Widget _host(Widget child, {bool reduced = false, bool contrast = false}) =>
    MaterialApp(
      theme: AppTheme.fromId('classic-dark'),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: reduced, highContrast: contrast),
        child: child!,
      ),
      home: Scaffold(body: Center(child: child)),
    );

Widget _piece({double width = 200, double height = 44, Widget? child}) =>
    Builder(
      builder: (context) => HermesGlassPiece(
        shape: const StadiumBorder(),
        child: ColoredBox(
          color: HermesGlassStrip.of(context)?.veil ?? Colors.black,
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    );

int _layers(WidgetTester tester) =>
    tester.layers.whereType<BackdropFilterLayer>().length;

void main() {
  final originalValidated = FrostedBackdropPolicy.liquidGpuValidated.value;
  setUp(() {
    FrostedBackdropPolicy.liquidGpuValidated.value = false;
    FrostedBackdropPolicy.knownHighEnd.value = true;
    FrostedBackdropPolicy.blurAllowed.value = true;
    FrostedBackdropPolicy.reducedPerformance.value = false;
  });
  tearDown(() {
    FrostedBackdropPolicy.liquidGpuValidated.value = originalValidated;
    FrostedBackdropPolicy.knownHighEnd.value = false;
    FrostedBackdropPolicy.blurAllowed.value = true;
    FrostedBackdropPolicy.reducedPerformance.value = false;
  });

  testWidgets('unmeasured GPU uses consumed glass, without loading liquid', (
    tester,
  ) async {
    final loads = HermesLiquidShader.loadAttempts;
    await tester.pumpWidget(
      _host(HermesGlassStrip(liquid: HermesLiquid.header, child: _piece())),
    );
    await tester.pump();
    expect(_layers(tester), 1);
    final piece = tester.element(find.byType(HermesGlassPiece));
    expect(HermesGlassStrip.debugShaderActive(piece), isFalse);
    expect(HermesGlassStrip.of(piece)!.veil.a, greaterThan(0));
    expect(HermesLiquidShader.loadAttempts, loads);
  });

  for (final reason in ['motion', 'contrast', 'battery', 'transparency']) {
    testWidgets('$reason veto survives liquid opt-in, with no filter/load', (
      tester,
    ) async {
      FrostedBackdropPolicy.liquidGpuValidated.value = true;
      if (reason == 'battery') {
        FrostedBackdropPolicy.reducedPerformance.value = true;
      }
      if (reason == 'transparency') {
        FrostedBackdropPolicy.blurAllowed.value = false;
      }
      final loads = HermesLiquidShader.loadAttempts;
      await tester.pumpWidget(
        _host(
          FrostedBackdrop.glass(
            liquid: HermesLiquid.pill,
            borderRadius: BorderRadius.circular(22),
            child: const SizedBox(width: 200, height: 44),
          ),
          reduced: reason == 'motion',
          contrast: reason == 'contrast',
        ),
      );
      await tester.pump();
      expect(_layers(tester), 0);
      expect(HermesLiquidShader.loadAttempts, loads);
    });
  }

  testWidgets('legacy glass and liquid bands share their zone', (tester) async {
    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FrostedBackdrop.glass(
              zone: FrostedZone.bottom,
              zonePriority: 1,
              borderRadius: BorderRadius.circular(22),
              child: const SizedBox(width: 200, height: 44),
            ),
            HermesGlassStrip(
              zone: FrostedZone.bottom,
              liquid: HermesLiquid.dock,
              child: _piece(),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(_layers(tester), 1);
    final glass = HermesGlassStrip.of(
      tester.element(find.byType(HermesGlassPiece)),
    );
    expect(glass!.blurs, isFalse);
    expect(glass.veil.a, greaterThan(0));
  });

  testWidgets('large overlay has opaque backing and no filter', (tester) async {
    FrostedBackdropPolicy.liquidGpuValidated.value = true;
    final loads = HermesLiquidShader.loadAttempts;
    await tester.pumpWidget(
      _host(
        HermesLiquidSurface(
          maxFilterArea: 1000,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          builder: (_, fill) => ColoredBox(
            color: fill,
            child: const SizedBox(width: 300, height: 400),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(_layers(tester), 0);
    expect(HermesLiquidShader.loadAttempts, loads);
  });

  testWidgets('opaque or zero-sigma legacy member releases its zone live', (
    tester,
  ) async {
    final tint = ValueNotifier<Color>(const Color(0xFF222222));
    final sigma = ValueNotifier<double>(16);
    addTearDown(tint.dispose);
    addTearDown(sigma.dispose);
    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<Color>(
              valueListenable: tint,
              builder: (_, fill, _) => ValueListenableBuilder<double>(
                valueListenable: sigma,
                builder: (_, value, _) => FrostedBackdrop(
                  tint: fill,
                  sigma: value,
                  zone: FrostedZone.bottom,
                  zonePriority: 5,
                  borderRadius: BorderRadius.circular(22),
                  builder: (_, fill) => ColoredBox(
                    color: fill,
                    child: const SizedBox(width: 200, height: 44),
                  ),
                ),
              ),
            ),
            HermesGlassStrip(
              zone: FrostedZone.bottom,
              liquid: HermesLiquid.dock,
              child: _piece(),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    final piece = tester.element(find.byType(HermesGlassPiece));
    expect(HermesGlassStrip.of(piece)!.blurs, isTrue);
    expect(_layers(tester), 1);
    tint.value = const Color(0xCC222222);
    await tester.pump();
    expect(
      _layers(tester),
      lessThanOrEqualTo(1),
      reason: 'the losing retained band stops in this frame',
    );
    await tester.pump();
    expect(HermesGlassStrip.of(piece)!.blurs, isFalse);
    expect(_layers(tester), 1);
    sigma.value = 0;
    await tester.pump();
    expect(_layers(tester), lessThanOrEqualTo(1));
    await tester.pump();
    expect(HermesGlassStrip.of(piece)!.blurs, isTrue);
    expect(_layers(tester), 1);
  });

  testWidgets('live veto keeps field state, text and geometry', (tester) async {
    final text = TextEditingController(text: 'borrador');
    addTearDown(text.dispose);
    const fieldKey = ValueKey('field');
    await tester.pumpWidget(
      _host(
        HermesGlassStrip(
          liquid: HermesLiquid.header,
          child: _piece(
            child: TextField(key: fieldKey, controller: text),
          ),
        ),
      ),
    );
    final state = tester.state(find.byKey(fieldKey));
    final rect = tester.getRect(find.byKey(fieldKey));
    expect(_layers(tester), 1);
    FrostedBackdropPolicy.blurAllowed.value = false;
    await tester.pump();
    expect(_layers(tester), 0);
    expect(tester.state(find.byKey(fieldKey)), same(state));
    expect(tester.getRect(find.byKey(fieldKey)), rect);
    expect(text.text, 'borrador');
    FrostedBackdropPolicy.blurAllowed.value = true;
    await tester.pump();
    expect(_layers(tester), 1);
    expect(tester.state(find.byKey(fieldKey)), same(state));
  });

  testWidgets(
    'liquid tier needs measured, known high-end, supported hardware',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      );
      HermesGlassTier tier(bool supported) =>
          FrostedBackdropPolicy.tierIn(context, shaderSupported: supported);
      expect(tier(true), HermesGlassTier.glass);
      FrostedBackdropPolicy.liquidGpuValidated.value = true;
      expect(tier(false), HermesGlassTier.glass);
      FrostedBackdropPolicy.knownHighEnd.value = false;
      expect(tier(true), HermesGlassTier.glass);
      FrostedBackdropPolicy.knownHighEnd.value = true;
      expect(tier(true), HermesGlassTier.liquid);
      FrostedBackdropPolicy.blurAllowed.value = false;
      expect(tier(true), HermesGlassTier.chrome);
    },
  );
}
