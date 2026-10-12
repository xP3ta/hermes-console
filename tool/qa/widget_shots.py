#!/usr/bin/env python3
"""Launcher widgets without a phone: check their layouts and draw them.

The widgets are RemoteViews over `android/app/src/main/res/layout/lw_*.xml`.
This tool reads those very files (and the dimens, colours, styles, strings
and drawables they use) and:

  widget_shots.py check
      Lints the resources: only views a launcher can inflate, every
      reference resolves, text is never below 13 sp, labels have no font
      padding, pills have the same padding on both sides, icons are centred
      in their viewport, tap targets are at least 48 dp. Exit 1 on a problem.

  widget_shots.py previews [--write]
      The widget-picker previews are copies of the real layouts with sample
      content. Prints the ones that drifted; --write regenerates them.

  widget_shots.py render [OUT_DIR]
      Writes an HTML approximation of every widget at its cell sizes, built
      from the real sizes, into OUT_DIR (default build/widget_shots) and,
      when a headless Chrome is found, a PNG of each page plus
      `alignment.json`: for every label, how far the centre of its letters
      is from the centre of its pill or row, in dp.

Nothing here talks to a device, a server or the network.
"""
import json
import math
import os
import pathlib
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[2]
RES = ROOT / 'android/app/src/main/res'
A = '{http://schemas.android.com/apk/res/android}'
LOCALE = 'es'  # the approved mock-up is in Spanish

# What RemoteViews can inflate (android.widget.RemoteViews.RemoteView).
ALLOWED_VIEWS = {'LinearLayout', 'FrameLayout', 'RelativeLayout', 'GridLayout', 'TextView', 'ImageView',
                 'ImageButton', 'Button', 'ProgressBar', 'Chronometer', 'include'}
MIN_TEXT_SP = 13.0
TOUCH_DP = 48.0


# --------------------------------------------------------------------------- resources

class Res:
    def __init__(self):
        self.values = {'color': {}, 'dimen': {}, 'string': {}, 'style': {}, 'plurals': {}}
        for folder in ('values', f'values-{LOCALE}'):
            for path in sorted((RES / folder).glob('*.xml')):
                for node in ET.parse(path).getroot():
                    name = node.get('name')
                    if node.tag in ('color', 'dimen', 'string'):
                        self.values[node.tag][name] = (node.text or '').strip()
                    elif node.tag == 'plurals':
                        self.values['plurals'][name] = {i.get('quantity'): (i.text or '') for i in node}
                    elif node.tag == 'style' and folder == 'values':
                        self.values['style'][name] = (node.get('parent'), {i.get('name'): (i.text or '').strip()
                                                                          for i in node})

    def color(self, ref):
        if ref is None:
            return None
        if ref.startswith('@color/'):
            return self.color(self.values['color'][ref[7:]])
        if ref.startswith('@android:color/'):
            return {'transparent': 'transparent', 'white': '#fff', 'black': '#000'}.get(ref[15:], '#f0f')
        value = ref.lstrip('#')
        if len(value) == 8:  # AARRGGBB
            a, r, g, b = (int(value[i:i + 2], 16) for i in (0, 2, 4, 6))
            return f'rgba({r},{g},{b},{a / 255:.3f})'
        return '#' + value

    def dimen(self, ref):
        """A dimension in dp (sp counts as dp: font scale 1)."""
        if ref is None:
            return None
        if ref.startswith('@dimen/'):
            return self.dimen(self.values['dimen'][ref[7:]])
        if ref.startswith('@android:dimen/'):
            return 28.0  # system_app_widget_background_radius on a Pixel
        match = re.fullmatch(r'(-?[0-9.]+)(dp|sp|dip|px)', ref)
        if not match:
            raise ValueError(f'not a dimension: {ref}')
        return float(match.group(1))

    def string(self, ref):
        if ref is None:
            return ''
        if ref.startswith('@string/'):
            return self.values['string'][ref[8:]].replace("\\'", "'")
        return ref

    def style(self, name):
        """All items of a style, parents first (dotted names inherit)."""
        items = {}
        if name not in self.values['style']:
            return items
        parent, own = self.values['style'][name]
        if parent and parent.startswith('@style/'):
            items.update(self.style(parent[7:]))
        elif not parent and '.' in name:
            items.update(self.style(name.rsplit('.', 1)[0]))
        items.update(own)
        return items


def attr(res, el, name, default=None):
    """An android: attribute of a layout element, from the element or its style."""
    value = el.get(A + name)
    if value is not None:
        return value
    style = el.get('style')
    if style and style.startswith('@style/'):
        return res.style(style[7:]).get('android:' + name, default)
    return default


def layout_root(name):
    return ET.parse(RES / 'layout' / f'{name}.xml').getroot()


def expand_includes(el):
    """Replaces <include> by the included layout's root (with the overrides)."""
    for index, child in enumerate(list(el)):
        if child.tag == 'include':
            included = layout_root(child.get('layout')[8:])
            for key, value in child.attrib.items():
                if key != 'layout':
                    included.set(key, value)
            el.remove(child)
            el.insert(index, included)
            child = included
        expand_includes(child)
    return el


def all_layouts():
    return sorted(p.stem for p in (RES / 'layout').glob('lw_*.xml'))


# --------------------------------------------------------------------------- check

def path_bbox(d):
    """A rough bounding box of the on-curve points of a vector path."""
    tokens = re.findall(r'[A-Za-z]|-?\d*\.?\d+', d)
    x = y = 0.0
    start = (0.0, 0.0)
    xs, ys = [], []
    i, cmd = 0, None

    def take(n):
        nonlocal i
        vals = [float(t) for t in tokens[i:i + n]]
        i += n
        return vals

    while i < len(tokens):
        if tokens[i].isalpha():
            cmd = tokens[i]
            i += 1
            if cmd in 'zZ':
                x, y = start
                continue
        rel = cmd.islower()
        c = cmd.lower()
        if c == 'm':
            px, py = take(2)
            x, y = (x + px, y + py) if rel else (px, py)
            start = (x, y)
            cmd = 'l' if rel else 'L'
        elif c == 'l':
            px, py = take(2)
            x, y = (x + px, y + py) if rel else (px, py)
        elif c == 'h':
            (px,) = take(1)
            x = x + px if rel else px
        elif c == 'v':
            (py,) = take(1)
            y = y + py if rel else py
        elif c == 'c':
            v = take(6)
            x, y = (x + v[4], y + v[5]) if rel else (v[4], v[5])
        elif c == 's' or c == 'q':
            v = take(4)
            x, y = (x + v[2], y + v[3]) if rel else (v[2], v[3])
        elif c == 'a':
            v = take(7)
            ox, oy = x, y
            x, y = (x + v[5], y + v[6]) if rel else (v[5], v[6])
            # A half or full circle bulges by its radius beyond the chord.
            if abs(math.hypot(x - ox, y - oy) - 2 * v[0]) < 0.05:
                mx, my = (x + ox) / 2, (y + oy) / 2
                xs += [mx - v[0], mx + v[0]]
                ys += [my - v[1], my + v[1]]
        else:
            raise ValueError(f'path command {cmd}')
        xs.append(x)
        ys.append(y)
    return min(xs), min(ys), max(xs), max(ys)


def check():
    res = Res()
    problems = []

    def bad(where, what):
        problems.append(f'{where}: {what}')

    def exists(ref, where):
        if ref is None or not ref.startswith('@') or ref.startswith('@android:') or ref.startswith('@+id/'):
            return
        kind, name = ref[1:].split('/', 1)
        if kind in ('color', 'dimen', 'string', 'style', 'plurals'):
            if name not in res.values[kind]:
                bad(where, f'{ref} does not exist')
        elif kind in ('drawable', 'layout', 'xml'):
            folders = [p for p in RES.glob(f'{kind}*') if any(p.glob(f'{name}.*'))]
            if not folders:
                bad(where, f'{ref} does not exist')
        elif kind != 'id':
            bad(where, f'unknown reference {ref}')

    for name in all_layouts():
        root = layout_root(name)
        for el in root.iter():
            where = f'{name}.xml <{el.tag} {el.get(A + "id", "")}>'
            if el.tag not in ALLOWED_VIEWS:
                bad(where, 'a launcher cannot inflate this view')
            for key, value in el.attrib.items():
                exists(value, where)
            if el.tag in ('TextView', 'Chronometer'):
                size = res.dimen(attr(res, el, 'textSize'))
                if size is None or size < MIN_TEXT_SP:
                    bad(where, f'text of {size} sp (minimum {MIN_TEXT_SP})')
                if attr(res, el, 'includeFontPadding') != 'false':
                    bad(where, 'font padding is on: the letters would not be centred')
                # One line everywhere, except the sentence a board says when it has
                # nothing to list ("Abre Chats en Console para verlos aquí"): two, then the ellipsis.
                lines = attr(res, el, 'maxLines')
                if lines != ('2' if el.get(A + 'id') == '@+id/lw_calm_title' else '1'):
                    bad(where, 'more than one line')
                top, bottom = attr(res, el, 'paddingTop'), attr(res, el, 'paddingBottom')
                if top or bottom:
                    bad(where, 'a label is placed by centring, not by vertical padding')
            start, end = attr(res, el, 'paddingStart'), attr(res, el, 'paddingEnd')
            if (start or end) and start != end:
                bad(where, f'padding {start} at the start and {end} at the end')
            if attr(res, el, 'paddingLeft') or attr(res, el, 'paddingRight'):
                bad(where, 'left/right padding: use start/end')
            if el.tag == 'LinearLayout' and attr(res, el, 'orientation') != 'vertical':
                if attr(res, el, 'baselineAligned') != 'false' and el is not root:
                    bad(where, 'a row aligned by baselines: its children must be centred instead')
                if 'center' not in (attr(res, el, 'gravity') or '') and len(el) > 1 \
                        and attr(res, el, 'id') != '@+id/lw_buttons':
                    bad(where, 'a row whose children are not centred on one line')
        # Tap targets: anything given a click in LauncherWidgets.kt.
        for el in root.iter():
            ident = (el.get(A + 'id') or '').replace('@+id/', '')
            if ident in TAP_TARGETS:
                for side in ('layout_width', 'layout_height'):
                    value = attr(res, el, side)
                    if value in ('match_parent', 'wrap_content', '0dp'):
                        continue
                    if res.dimen(value) < TOUCH_DP:
                        bad(f'{name}.xml {ident}', f'tap target of {res.dimen(value)} dp')
    for path in sorted((RES / 'drawable').glob('lw_ic_*.xml')):
        root = ET.parse(path).getroot()
        if root.get(A + 'viewportWidth') != '24' or root.get(A + 'viewportHeight') != '24':
            bad(path.name, 'viewport is not 24 x 24')
        boxes = [path_bbox(p.get(A + 'pathData')) for p in root.iter('path')]
        x0, y0 = min(b[0] for b in boxes), min(b[1] for b in boxes)
        x1, y1 = max(b[2] for b in boxes), max(b[3] for b in boxes)
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        if path.stem in CENTRED_ICONS and (abs(cx - 12) > 0.3 or abs(cy - 12) > 0.3):
            bad(path.name, f'glyph centred on ({cx:.2f}, {cy:.2f}), not (12, 12)')
    kotlin = (ROOT / 'android/app/src/main/kotlin/com/hermesagent/hermes_android')
    source = ''.join(p.read_text(encoding='utf-8') for p in kotlin.glob('LauncherWidget*.kt'))
    ids = {el.get(A + 'id', '').replace('@+id/', '') for name in all_layouts() for el in layout_root(name).iter()}
    for used in sorted(set(re.findall(r'R\.id\.(lw_\w+)', source))):
        if used not in ids:
            bad('LauncherWidgets.kt', f'R.id.{used} is in no layout')
    for kind, known in (('layout', set(all_layouts())),
                        ('drawable', {p.stem for p in RES.glob('drawable*/*')}),
                        ('string', set(res.values['string'])), ('plurals', set(res.values['plurals'])),
                        ('color', set(res.values['color'])), ('dimen', set(res.values['dimen']))):
        for used in sorted(set(re.findall(rf'R\.{kind}\.(\w+)', source))):
            if used not in known:
                bad('LauncherWidgets.kt', f'R.{kind}.{used} does not exist')
    en = {n.get('name') for n in ET.parse(RES / 'values/launcher_widgets_strings.xml').getroot()
          if n.get('translatable') != 'false'}
    es = {n.get('name') for n in ET.parse(RES / f'values-{LOCALE}/launcher_widgets_strings.xml').getroot()}
    for missing in sorted(en ^ es):
        bad('launcher_widgets_strings.xml', f'{missing} is not in both languages')
    for line in previews(write=False):
        bad('previews', line)
    for p in problems:
        print('PROBLEM', p)
    print(f'{len(all_layouts())} layouts checked, {len(problems)} problems')
    return 1 if problems else 0


# Views that LauncherWidgets.kt gives a click of their own (the card itself
# is always one tap target).
TAP_TARGETS = {'lw_quick_new', 'lw_quick_voice', 'lw_quick_camera', 'lw_quick_agent', 'lw_button_yes',
               'lw_button_no', 'lw_button_open', 'lw_buttons', 'lw_calm'}
# Icons that sit next to a label or alone in a round button.
CENTRED_ICONS = {'lw_ic_plus', 'lw_ic_mic', 'lw_ic_cam', 'lw_ic_clock', 'lw_ic_lock', 'lw_ic_ring'}


# --------------------------------------------------------------------------- picker previews

def _sub(text, pattern, replacement, count=1):
    new, n = re.subn(pattern, replacement, text, count=count, flags=re.S)
    if n != count:
        raise SystemExit(f'preview recipe no longer matches: {pattern}')
    return new


def preview_ahora(source):
    """Ahora in the picker: the real one-row layout showing something running."""
    s = _sub(source, r'<!--.*?-->', '<!-- Picker preview of Ahora. GENERATED from lw_strip.xml by\n'
             '     tool/qa/widget_shots.py previews (the same layout, sample content): edit\n'
             '     lw_strip.xml and regenerate, never this file. -->')
    s = _sub(s, r'(android:id="@\+id/lw_lead_glyph".*?android:tint="@color/lw_muted")',
             r'\1\n            android:visibility="gone"')
    s = _sub(s, r'(android:id="@\+id/lw_lead_face".*?android:importantForAccessibility="no")\n'
                r'\s*android:visibility="gone"',
             r'\1\n            android:src="@drawable/lw_sample_face_lead"')
    s = _sub(s, r'@string/lw_sample_cron_job', '@string/lw_sample_run_title')
    s = _sub(s, r'@string/lw_sample_cron_next', '@string/lw_sample_run_about')
    # A static picker cannot run a timer: the same box, as text.
    s = _sub(s, r'<Chronometer(\s+android:id="@\+id/lw_end_timer".*?)\n\s*android:visibility="gone" />',
             r'<TextView\1\n        android:text="@string/lw_sample_timer" />')
    return s


def preview_bots(source):
    """Bots in the picker: the real one-row layout with four sample faces."""
    s = _sub(source, r'<!--.*?-->', '<!-- Picker preview of Bots. GENERATED from lw_faces.xml by\n'
             '     tool/qa/widget_shots.py previews (the same layout, sample content): edit\n'
             '     lw_faces.xml and regenerate, never this file. -->')
    faces = ''.join(
        '\n        <ImageView\n            android:layout_width="@dimen/lw_face"\n'
        '            android:layout_height="@dimen/lw_face"\n'
        '            android:layout_marginEnd="@dimen/lw_face_gap"\n'
        '            android:importantForAccessibility="no"\n'
        f'            android:src="@drawable/lw_sample_face_{name}" />\n'
        for name in ('builder', 'review', 'scout', 'lead'))
    s = _sub(s, r'(android:id="@\+id/lw_faces"\n.*?android:orientation="horizontal") />',
             r'\1>\n' + faces + '    </LinearLayout>')
    s = _sub(s, r'(android:id="@\+id/lw_faces_title".*?android:layout_marginTop="5dp") />',
             r'\1\n        android:text="@string/lw_bots_calm" />')
    return s


def preview_rooms(source):
    """Salas in the picker: the real one-row layout with a sample room."""
    s = _sub(source, r'<!--.*?-->', '<!-- Picker preview of Salas. GENERATED from lw_strip.xml by\n'
             '     tool/qa/widget_shots.py previews (the same layout, sample content): edit\n'
             '     lw_strip.xml and regenerate, never this file. -->')
    s = _sub(s, r'@drawable/lw_ic_clock', '@drawable/lw_ic_rooms')
    s = _sub(s, r'@string/lw_sample_cron_job', '@string/lw_sample_room')
    s = _sub(s, r'@string/lw_sample_cron_next', '@string/lw_sample_room_line')
    return s


def preview_tasks(source):
    """Tareas in the picker: the real one-row layout with a sample card."""
    s = _sub(source, r'<!--.*?-->', '<!-- Picker preview of Tareas. GENERATED from lw_strip.xml by\n'
             '     tool/qa/widget_shots.py previews (the same layout, sample content): edit\n'
             '     lw_strip.xml and regenerate, never this file. -->')
    s = _sub(s, r'@drawable/lw_ic_clock', '@drawable/lw_ic_kanban')
    s = _sub(s, r'@string/lw_sample_cron_job', '@string/lw_sample_task')
    s = _sub(s, r'@string/lw_sample_cron_next', '@string/lw_sample_task_line')
    return s


def preview_chats(source):
    """Chats in the picker: the real one-row layout with a sample conversation."""
    s = _sub(source, r'<!--.*?-->', '<!-- Picker preview of Chats. GENERATED from lw_strip.xml by\n'
             '     tool/qa/widget_shots.py previews (the same layout, sample content): edit\n'
             '     lw_strip.xml and regenerate, never this file. -->')
    s = _sub(s, r'@drawable/lw_ic_clock', '@drawable/lw_ic_history')
    s = _sub(s, r'@string/lw_sample_cron_job', '@string/lw_sample_chat')
    s = _sub(s, r'@string/lw_sample_cron_next', '@string/lw_sample_chat_line')
    return s


PREVIEWS = {'lw_preview_ahora': ('lw_strip', preview_ahora), 'lw_preview_bots': ('lw_faces', preview_bots),
            'lw_preview_rooms': ('lw_strip', preview_rooms), 'lw_preview_tasks': ('lw_strip', preview_tasks),
            'lw_preview_chats': ('lw_strip', preview_chats)}


def previews(write):
    drift = []
    for name, (source, recipe) in PREVIEWS.items():
        wanted = recipe((RES / 'layout' / f'{source}.xml').read_text(encoding='utf-8'))
        target = RES / 'layout' / f'{name}.xml'
        current = target.read_text(encoding='utf-8') if target.exists() else ''
        if current != wanted:
            if write:
                target.write_text(wanted, encoding='utf-8')
                print('written', target.relative_to(ROOT))
            else:
                drift.append(f'{name}.xml is not {source}.xml with sample content (run: previews --write)')
    return drift


# --------------------------------------------------------------------------- render (HTML approximation)



def _roboto_dir():
    """Roboto as Flutter ships it (WIDGET_SHOTS_FONTS overrides); None means the system sans."""
    if os.environ.get('WIDGET_SHOTS_FONTS'):
        return pathlib.Path(os.environ['WIDGET_SHOTS_FONTS'])
    flutter = shutil.which('flutter')
    if flutter:
        return pathlib.Path(flutter).resolve().parent / 'cache/artifacts/material_fonts'
    return pathlib.Path('/nonexistent')


ROBOTO = _roboto_dir()
# Roboto's own line box (ascent + descent), which is what a TextView without
# font padding is as tall as.
LINE = 1.172


def css_color(res, ref):
    return res.color(ref)


def drawable_html(res, ref, tint=None, alpha=None):
    """(css for a background, inner html for an image) of a drawable."""
    if ref is None:
        return '', ''
    if ref.startswith('@color/') or ref.startswith('#'):
        return f'background:{res.color(ref)};', ''
    name = ref.split('/', 1)[1]
    for folder in ('drawable', 'drawable-nodpi'):
        png = RES / folder / f'{name}.png'
        if png.exists():
            opacity = f'opacity:{alpha / 255:.2f};' if alpha is not None else ''
            return '', f'<img src="file://{png}" style="width:100%;height:100%;object-fit:contain;{opacity}">'
    root = ET.parse(RES / 'drawable' / f'{name}.xml').getroot()
    if root.tag == 'shape':
        css = []
        oval = root.get(A + 'shape') == 'oval'
        for node in root:
            if node.tag == 'solid':
                css.append(f'background:{res.color(node.get(A + "color"))};')
            elif node.tag == 'gradient':
                css.append(f'background:linear-gradient(180deg,{res.color(node.get(A + "startColor"))},'
                           f'{res.color(node.get(A + "centerColor"))} '
                           f'{float(node.get(A + "centerY")) * 100:.0f}%);')
            elif node.tag == 'corners':
                css.append(f'border-radius:{res.dimen(node.get(A + "radius"))}px;')
            elif node.tag == 'stroke':
                css.append(f'box-shadow:inset 0 0 0 {res.dimen(node.get(A + "width"))}px '
                           f'{res.color(node.get(A + "color"))};')
        if oval:
            css.append('border-radius:50%;')
        return ''.join(css), ''
    if root.tag == 'inset':
        inset = res.dimen(root.get(A + 'inset'))
        css, _ = drawable_html(res, None)
        shape = root.find('shape')
        color = res.color(shape.find('solid').get(A + 'color'))
        return '', (f'<span style="position:absolute;inset:{inset}px;border-radius:50%;'
                    f'background:{color}"></span>')
    if root.tag == 'vector':
        paths = []
        for p in root.iter('path'):
            fill = p.get(A + 'fillColor', '#00000000')
            stroke = p.get(A + 'strokeColor')
            own = None if tint else (res.color(stroke or fill))
            paint = tint or own
            if stroke:
                paths.append(f'<path d="{p.get(A + "pathData")}" fill="none" stroke="{paint}" '
                             f'stroke-width="{p.get(A + "strokeWidth")}" '
                             f'stroke-linecap="{p.get(A + "strokeLineCap", "butt")}" '
                             f'stroke-linejoin="{p.get(A + "strokeLineJoin", "miter")}"/>')
            else:
                paths.append(f'<path d="{p.get(A + "pathData")}" fill="{paint}"/>')
        opacity = f'opacity:{alpha / 255:.2f};' if alpha is not None else ''
        return '', (f'<svg viewBox="0 0 24 24" style="width:100%;height:100%;display:block;{opacity}">'
                    + ''.join(paths) + '</svg>')
    raise ValueError(f'drawable {ref}')


def px(value):
    return f'{value:g}px'


class Renderer:
    """Turns a layout plus what the provider would set on it into HTML."""

    def __init__(self, res):
        self.res = res

    def box(self, el, ov, parent):
        """parent: 'row', 'column' or 'frame' (how the parent lays this out)."""
        res = self.res
        ident = (el.get(A + 'id') or '').replace('@+id/', '').replace('@android:id/', '')
        o = ov.get(ident, {})
        visible = o.get('visible', attr(res, el, 'visibility') != 'gone')
        if not visible:
            return ''
        css = ['box-sizing:border-box;position:relative;min-width:0;min-height:0;']
        width, height = attr(res, el, 'layout_width'), attr(res, el, 'layout_height')
        weight = attr(res, el, 'layout_weight')
        orientation = 'column' if attr(res, el, 'orientation') == 'vertical' else 'row'

        def side(value, main, name):
            if value == 'match_parent':
                return 'flex:1 1 auto;' if main else 'align-self:stretch;'
            if value == 'wrap_content':
                return ('flex:0 1 auto;' if weight else 'flex:none;') if main else ''
            size = res.dimen(value)
            if main and weight and size == 0:
                return f'flex:{weight} 1 0px;'
            return (f'flex:none;{name}:{px(size)};' if main else f'{name}:{px(size)};')

        if parent == 'frame':
            gravity = attr(res, el, 'layout_gravity') or ''
            css.append('grid-area:1/1;')
            css.append('justify-self:' + ('stretch' if width == 'match_parent' else
                                          'center' if gravity in ('center', 'center_horizontal') else
                                          'end' if 'end' in gravity else 'start') + ';')
            css.append('align-self:' + ('stretch' if height == 'match_parent' else
                                        'center' if 'center' in gravity else
                                        'end' if 'bottom' in gravity else 'start') + ';')
            for value, name in ((width, 'width'), (height, 'height')):
                if value not in ('match_parent', 'wrap_content'):
                    css.append(f'{name}:{px(res.dimen(value))};')
        else:
            css.append(side(width, parent == 'row', 'width'))
            css.append(side(height, parent == 'column', 'height'))
            gravity = attr(res, el, 'layout_gravity') or ''
            if 'center_vertical' in gravity and parent == 'row':
                css.append('align-self:center;')
        for name, prop in (('layout_marginStart', 'margin-left'), ('layout_marginEnd', 'margin-right'),
                           ('layout_marginTop', 'margin-top'), ('layout_marginBottom', 'margin-bottom'),
                           ('paddingStart', 'padding-left'), ('paddingEnd', 'padding-right'),
                           ('paddingTop', 'padding-top'), ('paddingBottom', 'padding-bottom'),
                           ('minWidth', 'min-width'), ('minHeight', 'min-height')):
            value = attr(res, el, name)
            if value:
                css.append(f'{prop}:{px(res.dimen(value))};')
        pad = o.get('pad', attr(res, el, 'padding'))
        if pad is not None:
            css.append(f'padding:{px(pad if isinstance(pad, (int, float)) else res.dimen(pad))};')
        background, _ = drawable_html(res, o.get('bg', attr(res, el, 'background')))
        css.append(background)
        data = f' data-id="{ident}"' if ident else ''

        if el.tag in ('TextView', 'Chronometer'):
            size = res.dimen(attr(res, el, 'textSize'))
            color = res.color(o.get('color', attr(res, el, 'textColor')))
            style = el.get('style', '')
            family = 'RobotoMono,monospace' if attr(res, el, 'fontFamily') == 'monospace' else 'Roboto,sans-serif'
            weight_css = '500' if '.Medium' in style else '400'
            gravity = attr(res, el, 'gravity') or ''
            justify = 'center' if gravity == 'center' else 'flex-start'
            text = o.get('text', self.res.string(attr(res, el, 'text')))
            features = "font-feature-settings:'tnum';" if attr(res, el, 'fontFeatureSettings') else ''
            css.append(f'display:flex;align-items:center;justify-content:{justify};'
                       f'font:{weight_css} {px(size)}/{LINE} {family};color:{color};{features}')
            shown = html(text)
            if o.get('gold_prefix'):  # the first words in the accent colour (a span on Android)
                cut = o['gold_prefix']
                shown = f'<span style="color:{res.color("@color/lw_gold")}">{html(text[:cut])}</span>{html(text[cut:])}'
            inner = (f'<span class="ink" style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis;'
                     f'min-width:0">{shown}</span>')
            return f'<div{data} style="{"".join(css)}">{inner}</div>'
        if el.tag == 'ImageView':
            src = o.get('src', attr(res, el, 'src'))
            tint = o['tint'] if 'tint' in o else attr(res, el, 'tint')
            shape, inner = drawable_html(res, src, res.color(tint) if tint else None, o.get('alpha'))
            if shape and not inner:  # a shape used as the image itself
                inner = f'<span style="position:absolute;inset:0;{shape}"></span>'
            css.append('display:block;')
            return f'<div{data} style="{"".join(css)}">{inner}</div>'
        # A container.
        gravity = attr(res, el, 'gravity') or ''
        if el.tag == 'FrameLayout':
            css.append('display:grid;')
            kind = 'frame'
        else:
            css.append(f'display:flex;flex-direction:{orientation};')
            if orientation == 'row':
                css.append('align-items:' + ('center' if 'center' in gravity else 'flex-start') + ';')
                css.append('justify-content:' + ('center' if gravity == 'center' else 'flex-start') + ';')
            else:
                css.append('justify-content:' + ('center' if 'center' in gravity else 'flex-start') + ';')
            kind = orientation
        children = ''.join(self.box(child, ov, kind) for child in el)
        for layout, child_ov in o.get('children', []):
            children += self.layout(layout, child_ov, kind)
        return f'<div{data} style="{"".join(css)}">{children}</div>'

    def layout(self, name, ov, parent='frame'):
        return self.box(expand_includes(layout_root(name)), ov, parent)


def html(text):
    return (text or '').replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


# Cell sizes of the mock-up's launcher grid (4 columns, 88 dp rows, 12 dp gaps
# in a 390 dp phone) and of a Pixel 8 with its default 4 x 5 grid.
CELLS = {'2x1': (171, 88), '4x1': (354, 88), '2x2': (171, 188), '4x2': (354, 188), '4x3': (354, 288)}
PIXEL = {'2x1': (184, 98), '4x1': (380, 98), '2x2': (184, 208), '4x2': (380, 208), '4x3': (380, 318)}

MEASURE_JS = r'''
<script>
// For every label: where the centre of its letters is, against the centre of
// the box it must be centred in (its pill, or its line box).
function inkCentre(span) {
  const cs = getComputedStyle(span.parentElement);
  const ctx = document.createElement('canvas').getContext('2d');
  ctx.font = cs.fontWeight + ' ' + cs.fontSize + ' ' + cs.fontFamily;
  const m = ctx.measureText(span.textContent);
  const r = span.getBoundingClientRect();
  const content = m.fontBoundingBoxAscent + m.fontBoundingBoxDescent;
  const baseline = r.top + (r.height - content) / 2 + m.fontBoundingBoxAscent;
  return {y: baseline - (m.actualBoundingBoxAscent - m.actualBoundingBoxDescent) / 2,
          x: r.left + r.width / 2, left: r.left, right: r.right};
}
function centre(el) { const r = el.getBoundingClientRect(); return {x: r.left + r.width / 2, y: r.top + r.height / 2, left: r.left, right: r.right, top: r.top, bottom: r.bottom}; }
// '.' is the piece being measured itself (the card, or one row of it).
function find(scope, id) { return id === '.' ? scope : (scope.dataset.id === id ? scope : scope.querySelector('[data-id="' + id + '"]')); }
function all(scope, id) { return [...scope.querySelectorAll('[data-id="' + id + '"]')]; }
function firstOf(scope, ids) { for (const id of [].concat(ids)) { const el = find(scope, id); if (el) return el; } return null; }
function baseline(el) {
  const span = el.querySelector('.ink');
  if (!span) return null;
  const cs = getComputedStyle(el);
  const ctx = document.createElement('canvas').getContext('2d');
  ctx.font = cs.fontWeight + ' ' + cs.fontSize + ' ' + cs.fontFamily;
  const m = ctx.measureText(span.textContent);
  const r = span.getBoundingClientRect();
  return r.top + (r.height - (m.fontBoundingBoxAscent + m.fontBoundingBoxDescent)) / 2 + m.fontBoundingBoxAscent;
}
function spread(values) { return +(Math.max(...values) - Math.min(...values)).toFixed(2); }
function measure(name, card, scope, probe, out) {
  // The same probes for every piece with this id (every row of a board).
  if (probe.each) {
    all(scope, probe.each).forEach((item, i) => {
      for (const p of probe.probes) measure(name + ' · ' + (probe.name || probe.each) + ' ' + (i + 1), card, item, p, out);
    });
    return;
  }
  // These start at the same left edge.
  if (probe.starts) {
    const xs = probe.starts.map(id => find(scope, id)).filter(Boolean).map(el => centre(el).left);
    if (xs.length > 1) out.push({shot: name, starts: probe.starts, dy: spread(xs)});
    return;
  }
  // These sit on one centre line.
  if (probe.centres) {
    const ys = probe.centres.map(id => find(scope, id)).filter(Boolean).map(el => centre(el).y);
    if (ys.length > 1) out.push({shot: name, centres: probe.centres, n: ys.length, dy: spread(ys)});
    return;
  }
  // These labels stand on one baseline.
  if (probe.baselines) {
    const ys = probe.baselines.map(id => find(scope, id)).filter(Boolean).map(baseline).filter(y => y !== null);
    if (ys.length > 1) out.push({shot: name, baselines: probe.baselines, dy: spread(ys)});
    return;
  }
  // The padding before the first piece equals the padding after the last
  // one, against the card (or, frame: 'scope', against the row).
  if (probe.insets) {
    const first = firstOf(scope, probe.insets[0]), last = firstOf(scope, probe.insets[1]);
    if (!first || !last) return;
    const frame = (probe.frame === 'scope' ? scope : card).getBoundingClientRect();
    const a = first.getBoundingClientRect(), b = last.getBoundingClientRect();
    const before = probe.axis === 'y' ? a.top - frame.top : a.left - frame.left;
    const after = probe.axis === 'y' ? frame.bottom - b.bottom : frame.right - b.right;
    out.push({shot: name, insets: [first.dataset.id, last.dataset.id], axis: probe.axis || 'x',
              before: +before.toFixed(2), after: +after.toFixed(2), dy: +(before - after).toFixed(2)});
    return;
  }
  // Every piece with this id is as tall as the others (rows share the body)
  // and, with 'least', no shorter than a tap target.
  if (probe.heights) {
    const hs = all(scope, probe.heights).map(el => el.getBoundingClientRect().height);
    if (hs.length) {
      const row = {shot: name, heights: probe.heights, n: hs.length, each: +Math.min(...hs).toFixed(2), dy: spread(hs)};
      if (probe.least) row.least = probe.least;
      out.push(row);
    }
    return;
  }
  // The pieces with this id stand in one line with the same gap between them.
  if (probe.gaps) {
    const rs = all(scope, probe.gaps).map(el => el.getBoundingClientRect());
    if (rs.length > 1) {
      out.push({shot: name, centres: [probe.gaps + ' ×' + rs.length], n: rs.length, dy: spread(rs.map(r => r.top + r.height / 2))});
    }
    if (rs.length > 2) {
      const gaps = rs.slice(1).map((r, i) => r.left - rs[i].right);
      out.push({shot: name, gaps: probe.gaps, n: gaps.length, each: +gaps[0].toFixed(2), dy: spread(gaps)});
    }
    return;
  }
  // The letters of a label against the centre of the box it must be centred in.
  const holder = find(scope, probe.label);
  const label = holder && holder.querySelector('.ink');
  const box = find(scope, probe.box);
  if (!label || !box) return;
  const ink = inkCentre(label), b = centre(box);
  const row = {shot: name, label: probe.label, box: probe.box, dy: +(ink.y - b.y).toFixed(2)};
  if (probe.sides) {
    const first = box.firstElementChild.getBoundingClientRect();
    row.left = +(first.left - b.left).toFixed(2); row.right = +(b.right - ink.right).toFixed(2);
  }
  if (probe.with) { const w = centre(find(card, probe.with)); row.withDy = +(w.y - b.y).toFixed(2); }
  out.push(row);
}
window.addEventListener('load', async () => {
  await document.fonts.ready;
  const out = [];
  for (const shot of document.querySelectorAll('[data-shot]')) {
    const card = shot.firstElementChild;
    for (const probe of JSON.parse(shot.dataset.probes || '[]')) measure(shot.dataset.shot, card, card, probe, out);
  }
  const pre = document.createElement('pre'); pre.id = 'alignment'; pre.textContent = JSON.stringify(out);
  pre.style.display = 'none'; document.body.appendChild(pre);
});
</script>
'''


def page(title, shots):
    fonts = ''.join(
        f"@font-face{{font-family:Roboto;font-weight:{w};src:url('file://{ROBOTO}/Roboto-{n}.ttf')}}"
        for w, n in ((400, 'Regular'), (500, 'Medium')) if (ROBOTO / f'Roboto-{n}.ttf').exists())
    body = []
    for name, (w, h), inner, probes in shots:
        body.append(
            f'<figure><figcaption>{html(name)} · {w} × {h} dp</figcaption>'
            f'<div data-shot="{html(name)}" data-probes=\'{json.dumps(probes)}\' '
            f'style="width:{w}px;height:{h}px;display:grid;overflow:hidden;border-radius:28px">{inner}</div></figure>')
    return (f'<!doctype html><meta charset="utf-8"><title>{html(title)}</title><style>{fonts}'
            'body{margin:0;padding:18px;background:radial-gradient(130% 50% at 85% 0%,#39426a,transparent 62%),'
            'radial-gradient(120% 60% at 0% 100%,#59393a,transparent 60%),#14151c;font-family:Roboto,sans-serif}'
            'h1{color:#f3efde;font:500 16px Roboto,sans-serif;margin:0 0 14px}'
            'figure{margin:0 0 16px;display:inline-block;vertical-align:top;margin-right:12px}'
            'figcaption{color:#b1a793;font:12px Roboto,sans-serif;margin-bottom:5px}'
            f'</style><h1>{html(title)}</h1>{"".join(body)}{MEASURE_JS}')


def face(name):
    return f'@drawable/lw_sample_face_{name}'


def scenarios(res):
    """What LauncherWidgets.kt draws for the mock-up's sample content."""
    from widget_scenes import build  # noqa: PLC0415  (kept beside this file)
    return build(res, Renderer(res), CELLS, PIXEL, face)


def find_chrome():
    for candidate in (os.environ.get('CHROME'), shutil.which('google-chrome-stable'), shutil.which('google-chrome'),
                      shutil.which('chromium'), shutil.which('chromium-browser')):
        if candidate and os.path.exists(candidate):
            return candidate
    return None


def crop(png):
    """Cuts the empty page under the last widget (needs Pillow; skipped without it)."""
    try:
        from PIL import Image, ImageChops  # noqa: PLC0415
    except ImportError:
        return
    if not png.exists():
        return
    image = Image.open(png).convert('RGB')
    # The page background is a gradient: look for the last row that has a card colour.
    card = (39, 40, 52)
    width, height = image.size
    pixels = image.load()
    last = 0
    for y in range(height - 1, 0, -4):
        if any(pixels[x, y] == card for x in range(0, width, 16)):
            last = y
            break
    if last:
        image.crop((0, 0, width, min(height, last + 80))).save(png, optimize=True)
    del ImageChops


def render(out_dir):
    res = Res()
    out = pathlib.Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    chrome = find_chrome()
    alignment = []
    for slug, title, shots in scenarios(res):
        target = out / f'{slug}.html'
        target.write_text(page(title, shots), encoding='utf-8')
        print('written', target)
        if not chrome:
            continue
        height = sum(h + 44 for _, (_, h), _, _ in shots) + 90
        common = [chrome, '--headless=new', '--no-sandbox', '--disable-gpu', '--hide-scrollbars',
                  '--allow-file-access-from-files', '--virtual-time-budget=4000']
        subprocess.run(common + ['--force-device-scale-factor=2', f'--window-size=800,{height}',
                                 f'--screenshot={out / (slug + ".png")}', f'file://{target.resolve()}'],
                       capture_output=True, timeout=120, check=False)
        crop(out / (slug + '.png'))
        dom = subprocess.run(common + ['--dump-dom', f'file://{target.resolve()}'],
                             capture_output=True, text=True, timeout=120, check=False).stdout
        match = re.search(r'<pre id="alignment"[^>]*>(.*?)</pre>', dom, re.S)
        if match:
            alignment += json.loads(match.group(1).replace('&quot;', '"'))
    off = []
    if chrome:
        (out / 'alignment.json').write_text(json.dumps(alignment, indent=1, ensure_ascii=False), encoding='utf-8')
        kinds = {}
        for row in alignment:
            # The letters of a label are centred by eye: one dp of slack (a
            # word of small letters sits lower than one of capitals). What
            # the layout itself decides (one centre line, one baseline, one
            # left edge, equal paddings, equal rows) must simply be equal.
            ink = 'label' in row
            kind = 'label' if ink else next(k for k in ('centres', 'baselines', 'starts', 'insets', 'heights', 'gaps')
                                            if k in row)
            count, worst = kinds.get(kind, (0, 0.0))
            kinds[kind] = (count + 1, max(worst, abs(row['dy'])))
            if abs(row['dy']) > (1.0 if ink else 0.05) or abs(row.get('withDy', 0)) > 0.01 \
                    or abs(row.get('left', 0) - row.get('right', 0)) > 1.0 \
                    or ('least' in row and row['each'] < row['least'] - 0.01):
                off.append(row)
        print(f'{len(alignment)} measures, ' + ', '.join(
            f'{count} {kind} (worst {worst:g} dp)' for kind, (count, worst) in kinds.items()))
        for row in off:
            print('OFF', row)
    return 1 if off else 0


def main():
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    command = sys.argv[1] if len(sys.argv) > 1 else 'check'
    if command == 'check':
        return check()
    if command == 'previews':
        drift = previews(write='--write' in sys.argv)
        for line in drift:
            print('DRIFT', line)
        return 1 if drift else 0
    if command == 'render':
        return render(sys.argv[2] if len(sys.argv) > 2 else ROOT / 'build/widget_shots')
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main())
