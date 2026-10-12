// The launcher (home-screen) widgets are RemoteViews over plain layout XML,
// so their alignment can be proved from the files: this suite reads the real
// layouts, sizes and styles and checks what a launcher would draw. A picture
// of each one, from the same files, comes from `tool/qa/widget_shots.py`.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
// Transitive via flutter_svg; not added to pubspec to keep the lockfile.
// ignore: depend_on_referenced_packages
import 'package:xml/xml.dart';

const _res = 'android/app/src/main/res';
const _kotlin = 'android/app/src/main/kotlin/com/hermesagent/hermes_android';
const _android = 'http://schemas.android.com/apk/res/android';

String _read(String path) => File(path).readAsStringSync();

XmlElement _xml(String path) => XmlDocument.parse(_read(path)).rootElement;

/// Dimens, colours and styles of `values/launcher_widgets.xml`.
class _Values {
  _Values() {
    for (final node in _xml(
      '$_res/values/launcher_widgets.xml',
    ).childElements) {
      final name = node.getAttribute('name')!;
      switch (node.name.local) {
        case 'dimen':
          dimens[name] = node.innerText.trim();
        case 'color':
          colors[name] = node.innerText.trim();
        case 'style':
          styles[name] = {
            for (final item in node.childElements)
              item.getAttribute('name')!: item.innerText.trim(),
          };
          parents[name] = node.getAttribute('parent');
      }
    }
  }

  final dimens = <String, String>{};
  final colors = <String, String>{};
  final styles = <String, Map<String, String>>{};
  final parents = <String, String?>{};

  /// A dimension in dp (sp counts as dp: font scale 1).
  double dp(String ref) {
    if (ref.startsWith('@dimen/')) return dp(dimens[ref.substring(7)]!);
    final match = RegExp(r'^(-?[0-9.]+)(dp|sp)$').firstMatch(ref);
    if (match == null) throw ArgumentError('not a dimension: $ref');
    return double.parse(match.group(1)!);
  }

  /// Every item of a style, parents first (dotted names inherit).
  Map<String, String> style(String name) {
    final own = styles[name];
    if (own == null) return const {};
    final parent = parents[name];
    return {
      if (parent != null && parent.startsWith('@style/'))
        ...style(parent.substring(7))
      else if (parent == null && name.contains('.'))
        ...style(name.substring(0, name.lastIndexOf('.'))),
      ...own,
    };
  }

  /// An `android:` attribute of a layout element, its own or its style's.
  String? attr(XmlElement el, String name) {
    final own = el.getAttribute(name, namespace: _android);
    if (own != null) return own;
    final style = el.getAttribute('style');
    if (style == null || !style.startsWith('@style/')) return null;
    return this.style(style.substring(7))['android:$name'];
  }
}

String _id(XmlElement el) => (el.getAttribute('id', namespace: _android) ?? '')
    .replaceFirst('@+id/', '')
    .replaceFirst('@android:id/', '');

XmlElement _byId(XmlElement root, String id) =>
    root.descendantElements.followedBy([root]).firstWhere((e) => _id(e) == id);

List<String> _layouts() =>
    Directory('$_res/layout')
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((name) => name.startsWith('lw_') && name.endsWith('.xml'))
        .toList()
      ..sort();

/// Bounding box of the on-curve points of a vector path (arcs that are half
/// circles also count their bulge), enough to tell where a glyph is centred.
({double x, double y}) _pathCentre(Iterable<String> paths) {
  final xs = <double>[];
  final ys = <double>[];
  for (final d in paths) {
    final tokens = RegExp(
      r'[A-Za-z]|-?\d*\.?\d+',
    ).allMatches(d).map((m) => m.group(0)!).toList();
    var x = 0.0, y = 0.0, sx = 0.0, sy = 0.0, i = 0;
    var cmd = '';
    List<double> take(int n) {
      final values = [
        for (final t in tokens.sublist(i, i + n)) double.parse(t),
      ];
      i += n;
      return values;
    }

    while (i < tokens.length) {
      if (RegExp(r'^[A-Za-z]$').hasMatch(tokens[i])) {
        cmd = tokens[i++];
        if (cmd == 'z' || cmd == 'Z') {
          x = sx;
          y = sy;
          continue;
        }
      }
      final rel = cmd == cmd.toLowerCase();
      switch (cmd.toLowerCase()) {
        case 'm':
          final v = take(2);
          x = rel ? x + v[0] : v[0];
          y = rel ? y + v[1] : v[1];
          sx = x;
          sy = y;
          cmd = rel ? 'l' : 'L';
        case 'l':
          final v = take(2);
          x = rel ? x + v[0] : v[0];
          y = rel ? y + v[1] : v[1];
        case 'h':
          final v = take(1);
          x = rel ? x + v[0] : v[0];
        case 'v':
          final v = take(1);
          y = rel ? y + v[0] : v[0];
        case 'c':
          final v = take(6);
          x = rel ? x + v[4] : v[4];
          y = rel ? y + v[5] : v[5];
        case 's' || 'q':
          final v = take(4);
          x = rel ? x + v[2] : v[2];
          y = rel ? y + v[3] : v[3];
        case 'a':
          final v = take(7);
          final ox = x, oy = y;
          x = rel ? x + v[5] : v[5];
          y = rel ? y + v[6] : v[6];
          final chord = math.sqrt(math.pow(x - ox, 2) + math.pow(y - oy, 2));
          if ((chord - 2 * v[0]).abs() < 0.05) {
            xs.addAll([(x + ox) / 2 - v[0], (x + ox) / 2 + v[0]]);
            ys.addAll([(y + oy) / 2 - v[1], (y + oy) / 2 + v[1]]);
          }
        default:
          throw StateError('path command $cmd');
      }
      xs.add(x);
      ys.add(y);
    }
  }
  return (
    x: (xs.reduce(math.min) + xs.reduce(math.max)) / 2,
    y: (ys.reduce(math.min) + ys.reduce(math.max)) / 2,
  );
}

void main() {
  final values = _Values();

  test('a launcher can inflate every widget layout', () {
    // android.widget.RemoteViews only inflates these (no plain View, Space…).
    const inflatable = {
      'LinearLayout',
      'FrameLayout',
      'TextView',
      'ImageView',
      'Chronometer',
      'include',
    };
    expect(_layouts(), isNotEmpty);
    for (final name in _layouts()) {
      final root = _xml('$_res/layout/$name');
      for (final el in root.descendantElements.followedBy([root])) {
        expect(inflatable, contains(el.name.local), reason: '$name ${_id(el)}');
      }
    }
  });

  test('text is 13 sp or more, one line, and has no font padding', () {
    for (final name in _layouts()) {
      final root = _xml('$_res/layout/$name');
      for (final el in root.descendantElements.followedBy([root])) {
        if (!const {'TextView', 'Chronometer'}.contains(el.name.local)) {
          continue;
        }
        final where = '$name ${_id(el)}';
        expect(
          values.dp(values.attr(el, 'textSize')!),
          greaterThanOrEqualTo(13),
          reason: where,
        );
        // The letters, not the font's spare room above them, get centred.
        expect(values.attr(el, 'includeFontPadding'), 'false', reason: where);
        // One line everywhere, but the sentence a board says when it has
        // nothing to list: two, then the ellipsis.
        expect(
          values.attr(el, 'maxLines'),
          _id(el) == 'lw_calm_title' ? '2' : '1',
          reason: where,
        );
        expect(values.attr(el, 'ellipsize'), 'end', reason: where);
        // A label is placed by centring, never nudged by a vertical padding.
        expect(values.attr(el, 'paddingTop'), isNull, reason: where);
        expect(values.attr(el, 'paddingBottom'), isNull, reason: where);
      }
    }
  });

  test(
    'paddings are the same on both sides and rows centre their children',
    () {
      for (final name in _layouts()) {
        final root = _xml('$_res/layout/$name');
        for (final el in root.descendantElements.followedBy([root])) {
          final where = '$name ${_id(el)}';
          expect(
            values.attr(el, 'paddingStart'),
            values.attr(el, 'paddingEnd'),
            reason: where,
          );
          expect(values.attr(el, 'paddingLeft'), isNull, reason: where);
          expect(values.attr(el, 'paddingRight'), isNull, reason: where);
          expect(values.attr(el, 'layout_marginLeft'), isNull, reason: where);
          expect(values.attr(el, 'layout_marginRight'), isNull, reason: where);
          final row =
              el.name.local == 'LinearLayout' &&
              values.attr(el, 'orientation') != 'vertical';
          if (!row) continue;
          // Children of a row are centred on one line, not sat on a baseline.
          expect(values.attr(el, 'baselineAligned'), 'false', reason: where);
          if (el.childElements.length > 1 && _id(el) != 'lw_buttons') {
            expect(
              values.attr(el, 'gravity'),
              contains('center'),
              reason: where,
            );
          }
        }
      }
    },
  );

  test(
    'two lines of text are one block of a fixed height, centred on the lead',
    () {
      final title = values.style('LW.Text.Medium.Title');
      final sub = values.style('LW.Text.Sub');
      expect(title['android:layout_height'], '@dimen/lw_line_title');
      expect(sub['android:layout_height'], '@dimen/lw_line_sub');
      expect(title['android:gravity'], 'center_vertical');
      final block =
          values.dp('@dimen/lw_line_title') + values.dp('@dimen/lw_line_sub');
      expect(block, 36);
      // The block (36) and the lead (34) are both centred in their row, so
      // their centres coincide: 1 dp of the block shows above and below.
      expect(values.dp('@dimen/lw_lead'), 34);
      for (final (file, lead, texts) in [
        ('lw_strip.xml', 'lw_lead', 'lw_texts'),
        ('lw_row.xml', 'lw_row_lead', 'lw_row_texts'),
      ]) {
        final root = _xml('$_res/layout/$file');
        expect(values.attr(root, 'gravity'), 'center_vertical', reason: file);
        final leadBox = _byId(root, lead);
        expect(values.attr(leadBox, 'layout_width'), '@dimen/lw_lead');
        expect(values.attr(leadBox, 'layout_height'), '@dimen/lw_lead');
        expect(values.attr(leadBox, 'layout_gravity'), isNull);
        final column = _byId(root, texts);
        expect(values.attr(column, 'layout_height'), 'wrap_content');
        expect(values.attr(column, 'orientation'), 'vertical');
        for (final line in column.childElements) {
          final height = values.attr(line, 'layout_height')!;
          expect(height, startsWith('@dimen/lw_line_'), reason: '$file line');
        }
      }
      // The cron row's two columns use the same two line boxes, so the time
      // sits on the name's line and the day on the result's.
      final cron = _xml('$_res/layout/lw_row_cron.xml');
      List<String?> boxes(String id) => [
        for (final line in _byId(cron, id).childElements)
          values.attr(line, 'layout_height'),
      ];
      expect(boxes('lw_cron_when'), boxes('lw_row_texts'));
    },
  );

  test(
    'Chat rápido: the label is centred in its pill, on the microphone line',
    () {
      final small = _xml('$_res/layout/lw_quick_small.xml');
      expect(values.attr(small, 'gravity'), 'center_vertical');
      expect(values.attr(small, 'orientation'), 'horizontal');
      final pill = _byId(small, 'lw_quick_new');
      final voice = _byId(small, 'lw_quick_voice');
      // Same height, both centred in the card: one centre line.
      expect(values.attr(pill, 'layout_height'), '@dimen/lw_touch');
      expect(values.attr(voice, 'layout_height'), '@dimen/lw_touch');
      expect(values.attr(voice, 'layout_width'), '@dimen/lw_touch');
      expect(values.dp('@dimen/lw_touch'), 48);
      // The icon + label group is centred both ways in the pill; nothing
      // pushes it from one side.
      expect(values.attr(pill, 'gravity'), 'center');
      expect(
        values.attr(pill, 'paddingStart'),
        values.attr(pill, 'paddingEnd'),
      );
      final children = pill.childElements.toList();
      expect(children.map((e) => e.name.local), ['ImageView', 'TextView']);
      final icon = children.first;
      final label = children.last;
      expect(
        values.attr(icon, 'layout_width'),
        values.attr(icon, 'layout_height'),
      );
      expect(values.attr(icon, 'layout_marginStart'), isNull);
      expect(values.attr(icon, 'layout_marginEnd'), isNull);
      expect(values.attr(icon, 'layout_marginTop'), isNull);
      // The only space inside the group is the gap, and it belongs to the
      // label: when a very narrow pill hides the label, the "+" is alone and
      // still centred.
      expect(
        values.attr(label, 'layout_marginStart'),
        '@dimen/lw_quick_icon_gap',
      );
      expect(values.attr(label, 'layout_marginEnd'), isNull);
      expect(values.attr(label, 'layout_marginTop'), isNull);
      expect(values.attr(label, 'layout_marginBottom'), isNull);
      expect(values.attr(label, 'includeFontPadding'), 'false');
      expect(values.attr(label, 'layout_height'), 'wrap_content');
      // The microphone glyph is centred in its disc.
      final glyph = voice.childElements.single;
      expect(values.attr(glyph, 'layout_gravity'), 'center');
      expect(
        values.attr(glyph, 'layout_width'),
        values.attr(glyph, 'layout_height'),
      );
      // The card's own paddings are equal, so pill and disc sit symmetrically.
      expect(
        values.attr(small, 'paddingStart'),
        values.attr(small, 'paddingEnd'),
      );

      // At the mock-up's two-cell width (171 dp) the label fits with at least
      // the pill padding on each side ("Nuevo" at 14 sp is about 42 dp wide).
      final pillWidth =
          171 -
          2 * values.dp('@dimen/lw_quick_pad') -
          values.dp('@dimen/lw_quick_gap') -
          values.dp('@dimen/lw_touch');
      final group =
          values.dp('@dimen/lw_quick_icon') +
          values.dp('@dimen/lw_quick_icon_gap') +
          42;
      expect(
        (pillWidth - group) / 2,
        greaterThanOrEqualTo(values.dp('@dimen/lw_quick_pill_pad')),
      );

      final wide = _xml('$_res/layout/lw_quick_wide.xml');
      expect(values.attr(wide, 'gravity'), 'center_vertical');
      for (final id in [
        'lw_quick_agent',
        'lw_quick_new',
        'lw_quick_camera',
        'lw_quick_voice',
      ]) {
        expect(
          values.attr(_byId(wide, id), 'layout_height'),
          '@dimen/lw_touch',
          reason: id,
        );
      }
      final field = _byId(wide, 'lw_quick_new');
      expect(values.attr(field, 'gravity'), 'center_vertical');
      expect(
        values.attr(field, 'paddingStart'),
        values.attr(field, 'paddingEnd'),
      );
      for (final id in ['lw_quick_camera', 'lw_quick_voice']) {
        final box = _byId(wide, id);
        expect(values.attr(box, 'layout_width'), '@dimen/lw_touch', reason: id);
        expect(
          values.attr(box.childElements.single, 'layout_gravity'),
          'center',
          reason: id,
        );
      }
    },
  );

  test('buttons: a 32 dp pill centred in a 48 dp tap box, label centred', () {
    final style = values.style('LW.Text.Medium.Button');
    expect(style['android:layout_height'], '@dimen/lw_button_height');
    expect(style['android:layout_gravity'], 'center_vertical');
    expect(style['android:gravity'], 'center');
    expect(style['android:paddingStart'], style['android:paddingEnd']);
    expect(values.dp('@dimen/lw_button_height'), 32);
    for (final file in ['lw_buttons.xml', 'lw_buttons_even.xml']) {
      final root = _xml('$_res/layout/$file');
      expect(values.attr(root, 'layout_height'), '@dimen/lw_touch');
      for (final id in ['lw_button_yes', 'lw_button_no', 'lw_button_open']) {
        final box = _byId(root, id);
        expect(values.attr(box, 'layout_height'), 'match_parent', reason: id);
        final label = box.childElements.single;
        expect(
          label.getAttribute('style'),
          startsWith('@style/LW.Text.Medium.Button'),
        );
        expect(
          values.attr(label, 'paddingStart'),
          values.attr(label, 'paddingEnd'),
        );
      }
    }
    // In one row, what you see (title, 4 dp, pills) is centred: 8 dp of top
    // padding balance the 8 dp of tap box left under the pills.
    final ask = _xml('$_res/layout/lw_ask_strip.xml');
    final touch = values.dp('@dimen/lw_touch');
    final spare = (touch - values.dp('@dimen/lw_button_height')) / 2;
    expect(values.dp(values.attr(ask, 'paddingTop')!), spare);
    expect(values.attr(ask, 'paddingBottom'), isNull);
    expect(values.attr(ask, 'gravity'), 'center_vertical');
  });

  test('everything with its own tap is at least 48 dp', () {
    const targets = {
      'lw_quick_new',
      'lw_quick_voice',
      'lw_quick_camera',
      'lw_quick_agent',
      'lw_button_yes',
      'lw_button_no',
      'lw_button_open',
      'lw_calm',
    };
    final seen = <String>{};
    for (final name in _layouts()) {
      final root = _xml('$_res/layout/$name');
      for (final el in root.descendantElements.followedBy([root])) {
        if (!targets.contains(_id(el))) continue;
        seen.add(_id(el));
        for (final side in ['layout_width', 'layout_height']) {
          final value = values.attr(el, side)!;
          if (const {'match_parent', 'wrap_content', '0dp'}.contains(value)) {
            continue;
          }
          expect(
            values.dp(value),
            greaterThanOrEqualTo(48),
            reason: '$name ${_id(el)} $side',
          );
        }
      }
    }
    expect(seen, targets);
    // Wrap-content buttons cannot be narrower than a tap target.
    expect(
      values.style('LW.Text.Medium.Button')['android:minWidth'],
      '@dimen/lw_touch',
    );
    // A row of a board is a tap target too: rows are only added while each
    // one gets 48 dp.
    expect(values.dp('@dimen/lw_row_min'), 48);
    final renderer = _read('$_kotlin/LauncherWidgets.kt');
    expect(
      renderer,
      contains('maxOf(dp(R.dimen.lw_row_min), TEXT_BLOCK * fontScale + 8f)'),
    );
    expect(
      renderer,
      contains('(room / rowHeight()).toInt().coerceIn(0, MAX_ROWS)'),
    );
    // The hairline between two rows takes no room (the next row starts on
    // it), so the rows share the whole body: three in 144 dp are 48 dp each.
    final line = _xml('$_res/layout/lw_line.xml');
    expect(
      values.dp(values.attr(line, 'layout_height')!) +
          values.dp(values.attr(line, 'layout_marginBottom')!),
      0,
    );
  });

  test('the sizes the renderer counts with are the ones in the layouts', () {
    final renderer = _read('$_kotlin/LauncherWidgets.kt');
    double constant(String name) => double.parse(
      RegExp('const val $name = ([0-9.]+)f').firstMatch(renderer)!.group(1)!,
    );
    expect(constant('LEAD'), values.dp('@dimen/lw_lead'));
    expect(
      constant('TEXT_BLOCK'),
      values.dp('@dimen/lw_line_title') + values.dp('@dimen/lw_line_sub'),
    );
    final ask = _xml('$_res/layout/lw_ask.xml');
    final askHeight =
        values.dp(values.attr(ask, 'layout_marginTop')!) +
        values.dp(values.attr(ask, 'minHeight')!);
    expect(constant('ASK_HEIGHT'), askHeight);
    final touch = values.dp('@dimen/lw_touch');
    final chrome =
        values.dp('@dimen/lw_pad_top') +
        values.dp('@dimen/lw_pad_bottom') +
        values.dp('@dimen/lw_head_height') +
        values.dp('@dimen/lw_head_gap');
    expect(constant('NEED_BOARD_MIN_HEIGHT'), chrome + askHeight + touch);
    final strip = _xml('$_res/layout/lw_ask_strip.xml');
    final line = _byId(strip, 'lw_ask_line');
    final buttons = strip.childElements.last;
    expect(buttons.name.local, 'include');
    final stripHeight =
        values.dp(values.attr(strip, 'paddingTop')!) +
        values.dp(values.attr(line, 'layout_height')!) +
        values.dp(values.attr(buttons, 'layout_marginTop')!) +
        values.dp(values.attr(buttons, 'layout_height')!);
    expect(constant('ASK_STRIP_MIN_HEIGHT'), stripHeight);
    // A two-row card of the mock-up's grid (188 dp) holds three 48 dp rows
    // under its head, and five in three rows (288 dp).
    expect(((188 - chrome) / 48).floor(), 3);
    expect(((288 - chrome) / 48).floor(), 5);
    // With something to answer it still shows one row (4x2) or three (4x3).
    expect(((188 - chrome - askHeight - touch) / 48).floor(), 1);
    expect(((288 - chrome - askHeight - touch) / 48).floor(), 3);
    expect(constant('BOARD_MIN_HEIGHT'), 110);
    expect(constant('WIDE_MIN_WIDTH'), 250);
  });

  test(
    'icons beside a label or alone in a disc are centred in their viewport',
    () {
      for (final name in ['plus', 'mic', 'cam', 'clock', 'lock', 'ring']) {
        final root = _xml('$_res/drawable/lw_ic_$name.xml');
        expect(root.getAttribute('viewportWidth', namespace: _android), '24');
        expect(root.getAttribute('viewportHeight', namespace: _android), '24');
        final centre = _pathCentre(
          root.descendantElements
              .where((e) => e.name.local == 'path')
              .map((e) => e.getAttribute('pathData', namespace: _android)!),
        );
        expect(centre.x, closeTo(12, 0.3), reason: name);
        expect(centre.y, closeTo(12, 0.3), reason: name);
      }
    },
  );

  test(
    'the picker preview of Ahora is the real layout with sample content',
    () {
      final real = _xml('$_res/layout/lw_strip.xml');
      final preview = _xml('$_res/layout/lw_preview_ahora.xml');
      // Only what a widget's content is may differ: texts, images, what shows.
      const content = {'text', 'src', 'visibility', 'tint'};
      void same(XmlElement a, XmlElement b) {
        final where = _id(a);
        // A static picker cannot tick: the timer's box is drawn as text.
        final timer =
            a.name.local == 'Chronometer' && b.name.local == 'TextView';
        if (!timer) expect(b.name.local, a.name.local, reason: where);
        Map<String, String> layout(XmlElement el) => {
          for (final attribute in el.attributes)
            if (!content.contains(attribute.name.local))
              attribute.name.qualified: attribute.value,
        };
        expect(layout(b), layout(a), reason: where);
        final ca = a.childElements.toList();
        final cb = b.childElements.toList();
        expect(cb.length, ca.length, reason: where);
        for (var i = 0; i < ca.length; i++) {
          same(ca[i], cb[i]);
        }
      }

      same(real, preview);
      final text = _read('$_res/layout/lw_preview_ahora.xml');
      expect(text, contains('GENERATED from lw_strip.xml'));
      // Neutral sample content: no address, no model name, no vendor.
      for (final file in _layouts()) {
        final xml = _read('$_res/layout/$file');
        expect(
          xml,
          isNot(contains(RegExp(r'\d+\.\d+\.\d+\.\d+'))),
          reason: file,
        );
        expect(
          xml,
          isNot(contains(RegExp('GPT|Sonnet|Claude|Gemini'))),
          reason: file,
        );
        // No literal text in a layout: every word is a translated resource.
        expect(
          RegExp(r'android:text="(?!@string/)').hasMatch(xml),
          isFalse,
          reason: file,
        );
      }
    },
  );

  test(
    'Bots and Salas: previews are the real layouts; faces and line share an edge',
    () {
      // Salas in the picker is the one-row layout itself with a sample room.
      final strip = _xml('$_res/layout/lw_strip.xml');
      final rooms = _xml('$_res/layout/lw_preview_rooms.xml');
      const content = {'text', 'src', 'visibility', 'tint'};
      Map<String, String> layout(XmlElement el) => {
        for (final attribute in el.attributes)
          if (!content.contains(attribute.name.local))
            attribute.name.qualified: attribute.value,
      };
      void same(XmlElement a, XmlElement b, {String? childrenAreContentOf}) {
        expect(b.name.local, a.name.local, reason: _id(a));
        expect(layout(b), layout(a), reason: _id(a));
        // The faces of the Bots row are added by the provider: in the preview
        // they are sample images, which is content.
        if (_id(a) == childrenAreContentOf) return;
        final ca = a.childElements.toList();
        final cb = b.childElements.toList();
        expect(cb.length, ca.length, reason: _id(a));
        for (var i = 0; i < ca.length; i++) {
          same(ca[i], cb[i], childrenAreContentOf: childrenAreContentOf);
        }
      }

      same(strip, rooms);
      // Tareas in the picker: the same one-row layout with a sample card.
      same(strip, _xml('$_res/layout/lw_preview_tasks.xml'));
      same(strip, _xml('$_res/layout/lw_preview_chats.xml'));
      final faces = _xml('$_res/layout/lw_faces.xml');
      final bots = _xml('$_res/layout/lw_preview_bots.xml');
      same(faces, bots, childrenAreContentOf: 'lw_faces');
      // The sample faces are the size and spacing of a real face.
      final one = _xml('$_res/layout/lw_face.xml');
      final samples = _byId(bots, 'lw_faces').childElements.toList();
      expect(samples, hasLength(4));
      for (final sample in samples) {
        for (final side in [
          'layout_width',
          'layout_height',
          'layout_marginEnd',
        ]) {
          expect(
            values.attr(sample, side),
            values.attr(one, side),
            reason: side,
          );
        }
      }
      // Four faces fit a two-cell card of the mock-up's grid (171 dp).
      final step =
          values.dp('@dimen/lw_face') + values.dp('@dimen/lw_face_gap');
      final inner = 171 - 2 * values.dp('@dimen/lw_pad_h');
      expect(((inner + values.dp('@dimen/lw_face_gap')) / step).floor(), 4);
      // The row of faces and the line under it start at the same edge (the
      // card's padding; neither has a start margin) and are centred together.
      expect(values.attr(faces, 'gravity'), 'center_vertical');
      expect(values.attr(faces, 'orientation'), 'vertical');
      for (final id in ['lw_faces', 'lw_faces_title']) {
        final el = _byId(faces, id);
        expect(values.attr(el, 'layout_marginStart'), isNull, reason: id);
        expect(values.attr(el, 'layout_width'), 'match_parent', reason: id);
      }
      // A room's row centres its faces on its two lines, like any other row.
      final room = _xml('$_res/layout/lw_row_room.xml');
      expect(values.attr(room, 'gravity'), 'center_vertical');
      expect(
        values.attr(_byId(room, 'lw_row_texts'), 'layout_height'),
        'wrap_content',
      );
      // A narrow card (two cells) keeps the room's name readable: two faces,
      // no "+2" and no timer beside the name. With them a 171 dp row left
      // 26 dp for "Console Devs".
      final renderer = _read('$_kotlin/LauncherWidgets.kt');
      expect(renderer, contains('if (more > 0 && size.wide) {'));
      expect(
        renderer,
        contains('if (size.wide) timer(row, R.id.lw_row_timer, room.sinceMs)'),
      );
    },
  );

  test('cards take the launcher radius and are clipped to it', () {
    final card = _read('$_res/drawable/lw_card.xml');
    expect(card, contains('@dimen/lw_radius'));
    expect(
      _read('$_res/values-v31/launcher_widgets.xml'),
      allOf(
        contains('@android:dimen/system_app_widget_background_radius'),
        contains('android:clipToOutline'),
      ),
    );
    for (final file in [
      'lw_strip.xml',
      'lw_board.xml',
      'lw_ask_strip.xml',
      'lw_quick_small.xml',
      'lw_quick_wide.xml',
      'lw_faces.xml',
      'lw_initial.xml',
    ]) {
      final root = _xml('$_res/layout/$file');
      expect(_id(root), 'background', reason: file);
      expect(root.getAttribute('style'), '@style/LW.Card', reason: file);
    }
    // The device's own font, medium by weight from Android 9.
    expect(
      values.parents['LW.Text'],
      '@android:style/TextAppearance.DeviceDefault',
    );
    expect(
      _read('$_res/values-v28/launcher_widgets.xml'),
      contains('android:textFontWeight'),
    );
  });

  test('both languages have every widget string, and the picker names', () {
    Map<String, String> strings(String locale) => {
      for (final node in _xml(
        '$_res/$locale/launcher_widgets_strings.xml',
      ).childElements)
        if (node.getAttribute('translatable') != 'false')
          node.getAttribute('name')!: node.innerText,
    };
    final en = strings('values');
    final es = strings('values-es');
    expect(es.keys.toSet(), en.keys.toSet());
    expect(es['lw_ahora_name'], 'Ahora');
    expect(es['lw_quick_name'], 'Chat rápido');
    expect(es['lw_cron_name'], 'Cron');
    expect(en['lw_ahora_name'], 'Now');
    expect(en['lw_quick_name'], 'Quick chat');
    expect(en['lw_cron_name'], 'Cron');
    expect(es['lw_bots_name'], 'Bots');
    expect(es['lw_rooms_name'], 'Salas');
    expect(en['lw_bots_name'], 'Bots');
    expect(en['lw_rooms_name'], 'Rooms');
    expect(es['lw_tasks_name'], 'Tareas');
    expect(en['lw_tasks_name'], 'Tasks');
    expect(es['lw_chats_name'], 'Chats');
    expect(en['lw_chats_name'], 'Chats');
    expect(es['lw_allow'], 'Permitir');
    expect(es['lw_deny'], 'Rechazar');
    expect(es['lw_no_connection'], 'Sin conexión');
    expect(es['lw_since'], 'desde las %1\$s');
  });
}
