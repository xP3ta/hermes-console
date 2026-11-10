import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/floating.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/liquid_glass.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/models/dock_config.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/core/widgets/dock_style.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const liquidBenchViewportKey = ValueKey('liquid-bench-viewport');
const liquidBenchLiveWindowKey = ValueKey('liquid-bench-live-window');
const liquidBenchLiveAnswerKey = ValueKey('liquid-bench-live-answer');
const liquidBenchDockKey = ValueKey('liquid-bench-dock');
const liquidBenchOverlayKey = ValueKey('liquid-bench-overlay');
const _liveSliverKey = ValueKey('liquid-bench-live-sliver');
const liquidBenchInitialText = 'Inicio de respuesta.';
const double liquidBenchAnchor = .75;
const double liquidBenchLiveHeight = 200;

double liquidBenchScrollAt(int step) => 60.0 + step * 6;
String liquidBenchDeltaAt(int step) => ' palabra$step';

Widget _history(int from, int to) => SliverPadding(
  padding: const EdgeInsets.symmetric(horizontal: 16),
  sliver: SliverList.list(
    children: [
      for (var i = from; i < to; i++)
        ChatMarkdownBody(
          data:
              'Respuesta **$i**\n\nContenido del transcript con varias '
              'líneas, herramientas y texto que pasan detrás del material.',
          selectable: false,
        ),
    ],
  ),
);

/// Component workload, not ChatScreen. All modes keep the same 40 completed
/// replies, growing payload and 60..486 dp scroll. The center sliver anchors
/// the live window in view; reverse inner scrolling keeps the newest token
/// visible even when the full Markdown paragraph exceeds the 200 dp window.
/// Following rows still scroll behind the dock. The optional modal is above
/// this window, so it cannot hide the response being measured.
Widget liquidBenchScene({
  required GlobalKey root,
  required ValueNotifier<String> stream,
  required ScrollController scroll,
  required bool overlay,
}) => RepaintBoundary(
  key: root,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.fromId('classic-dark'),
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: Scaffold(
      appBar: const HermesAppBar(title: Text('Conversación')),
      body: Stack(
        children: [
          CustomScrollView(
            key: liquidBenchViewportKey,
            controller: scroll,
            center: _liveSliverKey,
            anchor: liquidBenchAnchor,
            clipBehavior: Clip.none,
            slivers: [
              _history(0, 20),
              SliverToBoxAdapter(
                key: _liveSliverKey,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    key: liquidBenchLiveWindowKey,
                    height: liquidBenchLiveHeight,
                    child: SingleChildScrollView(
                      reverse: true,
                      primary: false,
                      physics: const NeverScrollableScrollPhysics(),
                      clipBehavior: Clip.hardEdge,
                      child: ValueListenableBuilder<String>(
                        valueListenable: stream,
                        builder: (_, text, _) => ChatMarkdownBody(
                          key: liquidBenchLiveAnswerKey,
                          data: text,
                          isStreaming: true,
                          selectable: false,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              _history(20, 40),
              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          ),
          Positioned(
            bottom: 20,
            left: 14,
            right: 14,
            child: DockBar(
              key: liquidBenchDockKey,
              style: const DockStyle(transparency: .6),
              children: [
                for (final icon in [Icons.home, Icons.forum, Icons.settings])
                  Expanded(
                    child: IconButton(icon: Icon(icon), onPressed: () {}),
                  ),
              ],
            ),
          ),
          if (overlay)
            Positioned(
              top: 16,
              left: 0,
              right: 0,
              child: Center(
                // A modal surface is opaque now; the overlay band that costs a
                // filter is the notice's and the toolbars': the same strip.
                child: Builder(
                  builder: (context) {
                    final chrome = HermesChrome.ofContext(context);
                    return HermesLiquidSurface(
                      key: liquidBenchOverlayKey,
                      shape: HermesFloatingSurface.rounded(),
                      liquid: HermesLiquid.overlay,
                      sigma: 20,
                      tint: chrome.opaque.withValues(alpha: 0.8),
                      fallbackFill: chrome.opaque,
                      maxFilterArea: HermesLiquid.overlayFilterArea,
                      builder: (context, fill) => Material(
                        color: fill,
                        shape: HermesFloatingSurface.rounded(),
                        child: const SizedBox(
                          width: 260,
                          height: 130,
                          child: Center(
                            child: Text('Acciones de conversación'),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    ),
  ),
);

class LiquidBenchObservation {
  const LiquidBenchObservation({
    required this.renderedText,
    required this.scrollPixels,
    required this.viewport,
    required this.liveWindow,
    required this.tailRects,
  });

  final String renderedText;
  final double scrollPixels;
  final Rect viewport;
  final Rect liveWindow;
  final List<Rect> tailRects;

  Map<String, Object?> toJson() {
    List<double> rect(Rect r) => [r.left, r.top, r.right, r.bottom];
    return {
      'renderedLength': renderedText.length,
      'scrollPixels': scrollPixels,
      'viewport': rect(viewport),
      'liveWindow': rect(liveWindow),
      'visibleTailRects': [for (final r in tailRects) rect(r)],
    };
  }
}

bool _contains(Rect outer, Rect inner) =>
    !inner.isEmpty &&
    inner.left >= outer.left - .001 &&
    inner.top >= outer.top - .001 &&
    inner.right <= outer.right + .001 &&
    inner.bottom <= outer.bottom + .001;

/// Reads the mounted widget AND its laid-out/painted paragraph. It refuses
/// model-only updates, detached/offscreen responses and hidden newest glyphs.
/// The benchmark calls it outside both timing windows, for every warmup and
/// measured step. Negative-control tests deliberately violate these guards.
LiquidBenchObservation observeLiquidBench(
  WidgetTester tester, {
  required String expectedText,
  required String newestToken,
  required ScrollController scroll,
}) {
  final answer = find.byKey(liquidBenchLiveAnswerKey);
  if (answer.evaluate().length != 1) {
    throw StateError('live answer is not mounted');
  }
  final widget = tester.widget<ChatMarkdownBody>(answer);
  if (!widget.isStreaming || widget.data != expectedText) {
    throw StateError('live builder has not consumed the current delta');
  }
  final paragraphs = find
      .descendant(of: answer, matching: find.byType(RichText))
      .evaluate()
      .map((element) => element.findRenderObject())
      .whereType<RenderParagraph>()
      .where(
        (paragraph) => paragraph.text.toPlainText().trimRight() == expectedText,
      )
      .toList();
  if (paragraphs.length != 1) {
    throw StateError('current text did not reach RenderParagraph');
  }
  final paragraph = paragraphs.single;
  if (!paragraph.attached ||
      !paragraph.hasSize ||
      paragraph.size.isEmpty ||
      paragraph.debugNeedsLayout ||
      paragraph.debugNeedsPaint) {
    throw StateError('current paragraph has not completed layout and paint');
  }
  final rendered = paragraph.text.toPlainText().trimRight();
  if (!rendered.endsWith(newestToken)) {
    throw StateError('newest token was not rendered');
  }
  final viewport = tester.getRect(find.byKey(liquidBenchViewportKey));
  final liveWindow = tester.getRect(find.byKey(liquidBenchLiveWindowKey));
  if (!_contains(viewport, liveWindow)) {
    throw StateError('live window left the measured viewport');
  }
  final occluders = [
    tester.getRect(find.byType(HermesAppBar)),
    tester.getRect(find.byKey(liquidBenchDockKey)),
    if (find.byKey(liquidBenchOverlayKey).evaluate().isNotEmpty)
      tester.getRect(find.byKey(liquidBenchOverlayKey)),
  ];
  if (occluders.any(liveWindow.overlaps)) {
    throw StateError('chrome covers the live window');
  }
  final tail = paragraph.getBoxesForSelection(
    TextSelection(
      baseOffset: rendered.length - newestToken.length,
      extentOffset: rendered.length,
    ),
  );
  final tailRects = [
    for (final box in tail)
      MatrixUtils.transformRect(paragraph.getTransformTo(null), box.toRect()),
  ];
  if (tailRects.isEmpty ||
      tailRects.any(
        (rect) => !_contains(viewport, rect) || !_contains(liveWindow, rect),
      )) {
    throw StateError('newest token is not fully visible in both viewports');
  }
  return LiquidBenchObservation(
    renderedText: rendered,
    scrollPixels: scroll.position.pixels,
    viewport: viewport,
    liveWindow: liveWindow,
    tailRects: tailRects,
  );
}
