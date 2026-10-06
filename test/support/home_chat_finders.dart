import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every way Inicio v3 (#183) names a chat: a «Retomar» row or the finished
/// card (the bare title), the calm card's «Continue/Seguir con» starter and
/// the working card. The newest chat leaves Retomar for the hero, so a test
/// that only means "Home shows this chat" must accept any of these; a chat
/// that must be gone from Home must match none of them.
Finder findHomeChat(String title, {bool skipOffstage = true}) =>
    find.byWidgetPredicate((widget) {
      if (widget is! Text) return false;
      final text = widget.data ?? widget.textSpan?.toPlainText();
      if (text == null) return false;
      return text == title ||
          text == 'Continue “$title”' ||
          text == 'Seguir con «$title»' ||
          text == 'Working on “$title”' ||
          text == 'Trabajando en «$title»';
    }, skipOffstage: skipOffstage);
