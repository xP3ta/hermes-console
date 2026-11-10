import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/box_edge.dart';

/// The finish of a box ([HermesBoxEdges]) painted somewhere under [owner].
Finder boxEdgesUnder(Finder owner) => find.descendant(
  of: owner,
  matching: find.byWidgetPredicate(
    (w) => w is CustomPaint && w.foregroundPainter is HermesBoxEdge,
  ),
);

/// Same, over [inner] (a box's text, say): the nearest box around it.
Finder boxEdgesAround(Finder inner) => find.ancestor(
  of: inner,
  matching: find.byWidgetPredicate(
    (w) => w is CustomPaint && w.foregroundPainter is HermesBoxEdge,
  ),
);

/// The edge painter of the first box [boxes] finds.
HermesBoxEdge edgeOf(WidgetTester tester, Finder boxes) =>
    tester.widget<CustomPaint>(boxes.first).foregroundPainter! as HermesBoxEdge;

/// The short shadow painter of the first box [boxes] finds, if it has one.
HermesBoxShadow? shadowOf(WidgetTester tester, Finder boxes) =>
    tester.widget<CustomPaint>(boxes.first).painter as HermesBoxShadow?;
