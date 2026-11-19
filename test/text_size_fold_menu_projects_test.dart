// Owner (1.4.1): «se tiene que adaptar el texto a tablet, fold y móvil». Two
// screens that did not adapt at the largest supported text size (Android
// 200 % × the reader's 150 % = 3.3×), measured with the font the app ships
// (Inter, loadInterFont), on simulated windows (not a physical Fold):
//
//  * Projects on the Fold cover in landscape (882×344): the list's loading
//    message (ConsoleLoader, first open: nothing cached yet) and the empty
//    detail pane («pick a project») overflowed their panes. Both now scroll
//    when they do not fit.
//  * The side menu: «Console» beside its logo was cut at 3.3×. It now goes
//    under the logo, whole, when both do not fit on one line; at the normal
//    size and at 2.2× it stays beside the logo.
//
// Each cell runs at the normal size (1.1×), 2.2× and 3.3×; Projects in
// Spanish and German. A cell fails on any layout error in any frame, from
// the first one (the loading state) to the settled screen.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/projects_center_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/console_loader.dart';
import 'package:hermes_android/core/widgets/hermes_drawer.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/a11y_main_screen_harness.dart';
import 'support/inter_font.dart';
import 'support/pj1215_fake_projects_gateway.dart';

/// Hermes' own density under the reader's factor (FontSizeService).
const double _density = 1.10;

/// Android's scale × the reader's factor: normal, 2.2× and the maximum.
const _scales = [(1.0, 1.0), (2.0, 1.0), (2.0, 1.5)];

bool _isMaximum(double system, double factor) => system * factor == 3.0;

Widget _host(
  Widget child, {
  required double textScale,
  required Locale locale,
}) => MaterialApp(
  locale: locale,
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: child,
);

void _setView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

RenderParagraph _paragraphOf(WidgetTester tester, Finder finder) {
  RenderParagraph? found;
  void visit(RenderObject node) {
    if (found != null) return;
    if (node is RenderParagraph) {
      found = node;
      return;
    }
    node.visitChildren(visit);
  }

  visit(tester.renderObject(finder));
  return found!;
}

/// The measurement is only valid with Inter: the Ahem test font (one em per
/// glyph, ratio 1.0) would give other widths.
void _expectInter(RenderParagraph paragraph) {
  final text = paragraph.text.toPlainText();
  final size = paragraph.text.style?.fontSize ?? 14;
  final painter = TextPainter(
    text: paragraph.text,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    maxLines: 1,
  )..layout();
  final ratio = painter.width / (text.length * paragraph.textScaler.scale(size));
  painter.dispose();
  expect(
    ratio,
    lessThan(0.95),
    reason: 'measured with the test font, not Inter ("$text")',
  );
}

/// Every layout error reported while [body] runs, with the widget chain that
/// built the failing render object (read when it is reported).
Future<List<String>> _layoutErrors(Future<void> Function() body) async {
  final errors = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    String? creator;
    final Iterable<DiagnosticsNode> nodes =
        details.informationCollector?.call() ?? const <DiagnosticsNode>[];
    for (final node in nodes) {
      final value = node.value;
      if (value is DebugCreator) {
        creator = value.element.debugGetCreatorChain(8);
      }
    }
    errors.add(
      '${details.exceptionAsString().split('\n').first}'
      '${creator == null ? '' : ' ($creator)'}',
    );
  };
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  return errors;
}

/// pumpAndSettle with the errors of every frame kept.
Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 100; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (!tester.binding.hasScheduledFrame) return;
  }
  fail('the screen never settled');
}

Rect _within(WidgetTester tester, Finder target, Finder container) {
  final rect = tester.getRect(target);
  final bounds = tester.getRect(container);
  expect(
    rect.top >= bounds.top - 0.5 &&
        rect.bottom <= bounds.bottom + 0.5 &&
        rect.left >= bounds.left - 0.5 &&
        rect.right <= bounds.right + 0.5,
    isTrue,
    reason: '$rect is not inside $bounds',
  );
  return rect;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadInterFont);
  setUp(installA11yPlatformMocks);
  tearDown(clearA11yPlatformMocks);

  for (final locale in const [Locale('es'), Locale('de')]) {
    for (final (system, factor) in _scales) {
      final scale = system * _density * factor;
      final name =
          'Projects on the Fold cover in landscape (882×344), '
          '${locale.languageCode}, ${scale.toStringAsFixed(2)}x text: the '
          'loading message and the empty pane fit or scroll';
      testWidgets(name, (tester) async {
        _setView(tester, const Size(882, 344));
        SharedPreferences.setMockInitialValues({});
        final manager = await ConnectionManager.create(
          await SharedPreferences.getInstance(),
        );
        // A connection new to the screen's in-memory tree cache: the list
        // opens in its loading state, as on the first open in the app.
        final connection = SavedConnection(
          id: 'fold-land-${locale.languageCode}-$system-$factor',
          label: 'Hermes QA',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'k',
        );
        var loading = false;
        final errors = await _layoutErrors(() async {
          await tester.pumpWidget(
            _host(
              ProjectsCenterScreen(
                connection: connection,
                connectionManager: manager,
                gateway: Pj1215FakeProjectsGateway.sample(),
                chatLauncher: (_, _) {},
              ),
              textScale: scale,
              locale: locale,
            ),
          );
          final loader = find.byType(ConsoleLoader);
          loading = loader.evaluate().isNotEmpty;
          if (loading) _expectInter(_paragraphOf(tester, loader.first));
          await _settle(tester);
        });
        expect(
          loading,
          isTrue,
          reason: 'the first frame must show the loading state',
        );
        expect(errors, isEmpty, reason: errors.join('\n'));

        final placeholder = find.byKey(
          const ValueKey('projects-pane-placeholder'),
        );
        expect(placeholder, findsOneWidget);
        _expectInter(_paragraphOf(tester, placeholder));
        // Inside its pane, on screen and not covered.
        final pane = find
            .ancestor(of: placeholder, matching: find.byType(ColoredBox))
            .first;
        _within(tester, placeholder, pane);
        expect(placeholder.hitTestable(), findsOneWidget);
        expect(_paragraphOf(tester, placeholder).didExceedMaxLines, isFalse);
      });
    }
  }

  // The drawer has a fixed width; the window only changes its height.
  for (final size in const [Size(344, 882), Size(882, 344)]) {
    for (final (system, factor) in _scales) {
      final scale = system * _density * factor;
      final name =
          'side menu (${size.width.toInt()}×${size.height.toInt()}), '
          '${scale.toStringAsFixed(2)}x text: «Console» whole, beside its '
          'logo when both fit';
      testWidgets(name, (tester) async {
        _setView(tester, size);
        SharedPreferences.setMockInitialValues({});
        final manager = await ConnectionManager.create(
          await SharedPreferences.getInstance(),
        );
        await manager.upsertConnection(a11yConnection);
        await manager.setActiveConnection(a11yConnection.id);
        final scaffoldKey = GlobalKey<ScaffoldState>();
        final errors = await _layoutErrors(() async {
          await tester.pumpWidget(
            _host(
              Scaffold(
                key: scaffoldKey,
                body: const SizedBox.shrink(),
                drawer: HermesDrawer(
                  connection: a11yConnection,
                  connManager: manager,
                  current: DrawerSection.home,
                ),
              ),
              textScale: scale,
              locale: const Locale('es'),
            ),
          );
          scaffoldKey.currentState!.openDrawer();
          await _settle(tester);
        });
        expect(errors, isEmpty, reason: errors.join('\n'));

        final selector = find.byKey(
          const ValueKey('drawer-instance-selector'),
        );
        final title = find.descendant(
          of: selector,
          matching: find.text('Console'),
        );
        final paragraph = _paragraphOf(tester, title);
        _expectInter(paragraph);
        // The name is inside the selector by construction: each is checked
        // on its own turn (visible, tappable, at the requested scale).
        await expectA11yLayoutUsable(tester, {
          'instance selector': selector,
        }, textScale: scale);
        await expectA11yLayoutUsable(tester, {
          'app name': title,
        }, textScale: scale);
        final rect = _within(tester, title, selector);
        expect(
          paragraph.didExceedMaxLines,
          isFalse,
          reason: '«Console» is cut (${paragraph.size.width} wide)',
        );
        if (!_isMaximum(system, factor)) {
          final mark = tester.getRect(
            find.byKey(const ValueKey('drawer-header-mark')),
          );
          expect(
            rect.top < mark.center.dy && mark.center.dy < rect.bottom,
            isTrue,
            reason: '«Console» $rect left its logo\'s line $mark',
          );
        }
      });
    }
  }
}
