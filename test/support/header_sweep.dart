// The overlap sweep (1.4.0, header-glass): mounts a screen with fake data at
// several widths and text scales and measures what the owner saw on his phone:
//
//   (a) at rest, nothing of the body sits under the floating header or in the
//       fade just below it ([HermesAppBar.veilTail]): the first thing the page
//       draws starts at or below the header's foot;
//   (b) no two sibling boxes (HermesCard, HermesGroup, HermesPanel,
//       HermesListGroup, HermesListSection, HermesNavRow) of the same column,
//       row or list intersect or stand closer than [minBoxGap];
//   (c) nothing overflows (a RenderFlex reports it) and nothing throws.
//
// The screens live in `header_sweep_screens.dart`; a screen is a [SweepScreen]
// (an id and how to build it). Add one there and the runner covers it. Every
// violation of every combination is collected and printed in ONE table.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/list.dart' show HermesListGroup;
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/responsive.dart';
import 'package:hermes_android/core/widgets/dock.dart' show dockRailFootprint;
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart'
    show HermesListSection;
import 'package:hermes_android/core/widgets/hermes_ui.dart'
    show HermesCard, HermesGroup, HermesNavRow, HermesPanel;
import 'package:hermes_android/l10n/app_localizations.dart';

/// Two sibling boxes never stand closer than this (dp).
const double minBoxGap = 4;

/// The widths of the sweep: a phone, a large phone or small tablet and the
/// open Fold.
const List<double> sweepWidths = [360, 600, 840];

/// The text scales of the sweep.
const List<double> sweepScales = [1, 2];

/// A page tall enough to build every row of a lazy list at once.
const double sweepHeight = 2600;

/// A screen of the sweep. [build] returns the page (without a MaterialApp)
/// once the test's platform mocks are set; [settle] pumps what the screen
/// needs to show its data (default: a few frames).
class SweepScreen {
  const SweepScreen(
    this.id,
    this.build, {
    this.settle,
    this.header = true,
    this.note = '',
  });

  final String id;
  final Future<Widget> Function(WidgetTester tester) build;
  final Future<void> Function(WidgetTester tester)? settle;

  /// False: the page has no [HermesAppBar] of its own (it sits in a shell);
  /// checks (b) and (c) still run.
  final bool header;

  /// What the screen is shown with, for the report.
  final String note;
}

Widget sweepApp(Widget home, {required String themeId, required double scale}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    theme: AppTheme.fromId(themeId),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: child!,
    ),
    home: home,
  );
}

Rect _rectOf(RenderObject object) {
  final box = object as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

bool _isBox(Widget widget) =>
    widget is HermesCard ||
    widget is HermesGroup ||
    widget is HermesPanel ||
    widget is HermesListGroup ||
    widget is HermesListSection ||
    widget is HermesNavRow;

/// The painted box of [element]: a panel carries 3 dp of margin inside its
/// own bounds.
Rect _paintedBox(Element element) {
  final rect = _rectOf(element.renderObject!);
  final widget = element.widget;
  if (widget is HermesPanel) return rect.deflate(3);
  if (widget is HermesListSection) {
    // The margin is inside the section's bounds, not painted.
    final margin = widget.margin.resolve(TextDirection.ltr);
    return Rect.fromLTRB(
      rect.left + margin.left,
      rect.top + margin.top,
      rect.right - margin.right,
      rect.bottom - margin.bottom,
    );
  }
  return rect;
}

String _label(Element element) {
  final texts = <String>[];
  void visit(Element child) {
    if (texts.length >= 2) return;
    final widget = child.widget;
    if (widget is Text && (widget.data ?? '').trim().isNotEmpty) {
      texts.add(widget.data!.trim());
      return;
    }
    child.visitChildren(visit);
  }

  visit(element);
  final name = element.widget.runtimeType.toString();
  return texts.isEmpty ? name : '$name «${texts.join(' / ')}»';
}

/// The render object that lays [object] out among its siblings: the nearest
/// flex or list. Null when it sits in a stack or any other free layout.
RenderObject? _flow(RenderObject object) {
  for (var node = object.parent; node != null; node = node.parent) {
    if (node is RenderFlex || node is RenderSliverMultiBoxAdaptor) return node;
    if (node is RenderStack ||
        node is RenderCustomMultiChildLayoutBox ||
        node is RenderWrap) {
      return null;
    }
  }
  return null;
}

double _gap(Rect a, Rect b) {
  final dx = math.max(
    0.0,
    math.max(a.left, b.left) - math.min(a.right, b.right),
  );
  final dy = math.max(
    0.0,
    math.max(a.top, b.top) - math.min(a.bottom, b.bottom),
  );
  return dx > 0 && dy > 0 ? math.sqrt(dx * dx + dy * dy) : math.max(dx, dy);
}

bool _overlaps(Rect a, Rect b) =>
    math.min(a.right, b.right) - math.max(a.left, b.left) > 0.5 &&
    math.min(a.bottom, b.bottom) - math.max(a.top, b.top) > 0.5;

String _fmt(Rect r) =>
    '${r.left.toStringAsFixed(0)},${r.top.toStringAsFixed(0)} '
    '${r.width.toStringAsFixed(0)}x${r.height.toStringAsFixed(0)}';

/// The violations of what is on screen now.
List<String> measureSweep(
  WidgetTester tester, {
  required bool header,
  required double railFootprint,
}) {
  final out = <String>[];

  // (a) the header and what is under it at rest.
  if (header) {
    final bars = find.byType(AppBar).evaluate().toList();
    if (bars.isEmpty) {
      out.add('(a) sin cabecera: no se encontró un AppBar');
    } else {
      final bar = _rectOf(bars.first.renderObject!);
      final foot = bar.bottom;
      final tail = foot + HermesAppBar.veilTail;
      final inHeader = find
          .descendant(
            of: find.byType(HermesAppBar),
            matching: find.byType(RichText),
          )
          .evaluate()
          .toSet();
      for (final element in find.byType(RichText).evaluate()) {
        if (inHeader.contains(element)) continue;
        final paragraph = element.renderObject;
        if (paragraph is! RenderBox || !paragraph.hasSize) continue;
        final rect = _rectOf(paragraph);
        if (rect.height < 1 || rect.width < 1) continue;
        final text = (element.widget as RichText).text.toPlainText().trim();
        if (text.isEmpty) continue;
        final shown = text.length > 28 ? '${text.substring(0, 28)}…' : text;
        if (rect.top < foot - 0.5 && rect.bottom > bar.top + 0.5) {
          out.add(
            '(a) texto «$shown» bajo la cabecera '
            '(${_fmt(rect)}; la cabecera acaba en ${foot.toStringAsFixed(0)})',
          );
        } else if (rect.top < tail - 0.5 && rect.left >= railFootprint) {
          out.add(
            '(a) texto «$shown» dentro de la cola de la cabecera '
            '(${_fmt(rect)}; debe empezar en ${tail.toStringAsFixed(0)} o más)',
          );
        }
      }
    }
  }

  // (b) sibling boxes.
  final boxes = <Element>[];
  for (final element in find.byWidgetPredicate((w) => _isBox(w)).evaluate()) {
    final ro = element.renderObject;
    if (ro is! RenderBox || !ro.hasSize || ro.size.isEmpty) continue;
    var nested = false;
    element.visitAncestorElements((ancestor) {
      if (_isBox(ancestor.widget)) {
        nested = true;
        return false;
      }
      return true;
    });
    if (!nested) boxes.add(element);
  }
  final groups = <RenderObject, List<Element>>{};
  for (final element in boxes) {
    final flow = _flow(element.renderObject!);
    if (flow != null) (groups[flow] ??= []).add(element);
  }
  for (final siblings in groups.values) {
    for (var i = 0; i < siblings.length; i++) {
      for (var j = i + 1; j < siblings.length; j++) {
        final a = _paintedBox(siblings[i]);
        final b = _paintedBox(siblings[j]);
        if (a.height < 1 || b.height < 1) continue;
        final names = '${_label(siblings[i])} y ${_label(siblings[j])}';
        if (_overlaps(a, b)) {
          out.add('(b) se intersectan $names (${_fmt(a)} | ${_fmt(b)})');
        } else if (_gap(a, b) < minBoxGap) {
          out.add(
            '(b) a ${_gap(a, b).toStringAsFixed(1)} dp (< $minBoxGap) '
            '$names (${_fmt(a)} | ${_fmt(b)})',
          );
        }
      }
    }
  }
  if (header) {
    final bars = find.byType(AppBar).evaluate().toList();
    if (bars.isNotEmpty) {
      final foot = _rectOf(bars.first.renderObject!).bottom;
      for (final element in boxes) {
        final rect = _paintedBox(element);
        if (rect.top < foot - 0.5 && rect.bottom > 1) {
          out.add(
            '(a) caja ${_label(element)} bajo la cabecera (${_fmt(rect)})',
          );
        }
      }
    }
  }
  return out;
}

/// Which widget raised [details]: the render object the error talks about,
/// its widget chain upwards and the first texts below it.
String? _creator(FlutterErrorDetails details) {
  final error = details.exception;
  if (error is! FlutterError) return null;
  for (final node in error.diagnostics) {
    final value = node.value;
    if (value is! RenderObject) continue;
    final found = _describe(value);
    if (found != null) return found;
  }
  return null;
}

/// The widget chain above [object], and the first texts below it.
String? _describe(RenderObject object) {
  final creator = object.debugCreator;
  if (creator is! DebugCreator) return null;
  final chain = <String>[creator.element.widget.runtimeType.toString()];
  creator.element.visitAncestorElements((ancestor) {
    chain.add(ancestor.widget.runtimeType.toString());
    return chain.length < 9;
  });
  final texts = <String>[];
  void visit(Element child) {
    if (texts.length >= 3) return;
    final widget = child.widget;
    if (widget is Text && (widget.data ?? '').trim().isNotEmpty) {
      texts.add(widget.data!.trim());
      return;
    }
    child.visitChildren(visit);
  }

  visit(creator.element);
  return '${chain.join(' < ')}; «${texts.join(' / ')}»';
}

/// Every row or column whose children run past its own edge: what a
/// RenderFlex reports as an overflow, found in the tree, with where it is.
List<String> _flexOverflows(WidgetTester tester) {
  final out = <String>[];
  void visit(RenderObject object) {
    if (object is RenderFlex && object.hasSize) {
      final horizontal = object.direction == Axis.horizontal;
      var end = 0.0;
      var child = object.firstChild;
      while (child != null) {
        final parentData = child.parentData! as FlexParentData;
        end = math.max(
          end,
          horizontal
              ? parentData.offset.dx + child.size.width
              : parentData.offset.dy + child.size.height,
        );
        child = parentData.nextSibling;
      }
      final extent = horizontal ? object.size.width : object.size.height;
      if (end > extent + 0.5) {
        out.add(
          '(c) ${horizontal ? 'fila' : 'columna'} desbordada '
          '${(end - extent).toStringAsFixed(0)} dp [${_describe(object)}]',
        );
      }
    }
    object.visitChildren(visit);
  }

  visit(tester.binding.renderViews.first);
  return out;
}

/// Mounts [screen] at [width] x [scale] under [themeId] and returns its
/// violations, labelled. A screen that fails to mount is one violation.
Future<List<String>> sweepOnce(
  WidgetTester tester,
  SweepScreen screen, {
  required double width,
  required double scale,
  required String themeId,
}) async {
  final label = '${screen.id} @${width.toStringAsFixed(0)}dp x$scale $themeId';
  final errors = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    final text = details.exceptionAsString().split('\n').first;
    final where = _creator(details);
    errors.add(
      '${text.contains('overflowed') ? '(c) desbordamiento' : '(c) excepción'}'
      ': $text${where == null ? '' : ' [$where]'}',
    );
  };
  tester.view.physicalSize = Size(width, sweepHeight);
  tester.view.devicePixelRatio = 1;
  final found = <String>[];
  try {
    final home = await screen.build(tester);
    await tester.pumpWidget(sweepApp(home, themeId: themeId, scale: scale));
    if (screen.settle != null) {
      await screen.settle!(tester);
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 600));
    }
    final context = tester.element(find.byType(Scaffold).first);
    final rail = _railFootprint(context);
    found.addAll(
      measureSweep(tester, header: screen.header, railFootprint: rail),
    );
    found.addAll(_flexOverflows(tester));
  } catch (error) {
    found.add('(c) no se pudo montar: ${error.toString().split('\n').first}');
  } finally {
    FlutterError.onError = previous;
  }
  // Leave the page, so the next combination starts clean.
  try {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
  } catch (_) {}
  return [
    for (final line in {...errors, ...found}) '$label: $line',
  ];
}

/// The column the header's tail leaves alone where a side rail is on screen.
double _railFootprint(BuildContext context) =>
    Responsive.usesRail(context) ? dockRailFootprint(context) : 0;
