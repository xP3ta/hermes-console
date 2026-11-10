// Draws one launcher widget at one size.
//
// Every widget is a ladder of plans, from the fullest to the barest. A plan
// measures each text first ([LwTypesetter.fit]) and gives up the moment one
// does not fit its box, so the next, simpler plan is tried; the last plan
// (an icon alone) always fits. Nothing is painted that was not measured, and
// no two things are painted in the same place.
//
// Tap zones come from the same rects the buttons and rows are painted with:
// Android lays a transparent view on each, so what is tapped is what is seen.
//
// Times are absolute ("Hoy · 18:30", "10:02"): a picture cannot age a
// relative one. Everything moves only when the app redraws it.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../models/launcher_widget_cron.dart' show LauncherWidgetCronJob;
import '../../services/notifications/bot_face_bitmap.dart'
    show BotFaceBitmapState, paintBotSphere, sphereEyePose;
import '../../widgets/bot_face_identity.dart';
import 'launcher_widget_geometry.dart';
import 'launcher_widget_identity.dart';
import 'launcher_widget_palette.dart';
import 'launcher_widget_scene.dart';
import 'launcher_widget_text.dart';
import 'launcher_widget_words.dart';

/// Everything a drawing needs.
class LwPaintRequest {
  const LwPaintRequest({
    required this.subject,
    required this.scene,
    required this.sizeDp,
    required this.palette,
    required this.words,
    required this.fontScale,
    this.textDirection = TextDirection.ltr,
    this.instanceId,
    this.avatars = const {},
  });

  final LwSubject subject;

  /// [LwAhoraScene], [LwChatsScene], [LwCronScene], [LwTasksScene] or
  /// [LwNewChatScene], by [subject].
  final Object scene;
  final Size sizeDp;
  final LauncherWidgetPalette palette;
  final LwWords words;
  final double fontScale;
  final TextDirection textDirection;

  /// The instance a new chat is started on.
  final String? instanceId;

  /// Prepared once per subject and shared by all placed sizes.
  final Map<String, LwAvatar> avatars;
}

/// A finished drawing: the picture (in dp; scale it to pixels), its tap
/// zones, what a screen reader says, and when it stops being true.
class LwFrame {
  const LwFrame({
    required this.sizeDp,
    required this.picture,
    required this.zones,
    required this.description,
    required this.log,
    required this.plan,
    required this.validUntilMs,
  });

  final Size sizeDp;
  final ui.Picture picture;

  /// In the order Android lays them: the first is the lowest (the card), a
  /// later one lies over an earlier one.
  final List<LwTapZone> zones;
  final String description;
  final LwPaintLog log;

  /// Name of the plan that fitted (for the tests).
  final String plan;

  /// When the drawing stops being true by itself (data turns old, a job's
  /// time comes, the day changes); null when it stays true.
  final int? validUntilMs;

  void dispose() => picture.dispose();
}

enum _Icon { zap, clock, msg, kanban, plus, mic, check, cross, wifiOff }

enum _Ring { none, waits, works }

/// Draws [request].
LwFrame paintLauncherWidget(LwPaintRequest request) {
  final painter = _Painter(request);
  return switch (request.subject) {
    LwSubject.ahora => painter.ahora(request.scene as LwAhoraScene),
    LwSubject.chats => painter.chats(request.scene as LwChatsScene),
    LwSubject.cron => painter.cron(request.scene as LwCronScene),
    LwSubject.tasks => painter.tasks(request.scene as LwTasksScene),
    LwSubject.newChat => painter.newChat(request.scene as LwNewChatScene),
  };
}

typedef _Plan = bool Function(_Ctx ctx);

class _Painter {
  _Painter(this.r)
    : span = LwSpan.of(r.sizeDp),
      typesetter = LwTypesetter(
        fontFamily: r.palette.fontFamily,
        fontScale: r.fontScale,
        textDirection: r.textDirection,
        locale: r.words.locale,
      );

  final LwPaintRequest r;
  final LwSpan span;
  final LwTypesetter typesetter;

  LwWords get w => r.words;

  LwFrame _run(List<(String, _Plan)> plans, {int? validUntilMs}) {
    for (final (name, plan) in plans) {
      final ctx = _Ctx(r, span, typesetter);
      ctx.card();
      if (plan(ctx)) return ctx.finish(name, validUntilMs);
      ctx.discard();
    }
    final ctx = _Ctx(r, span, typesetter);
    ctx.card();
    ctx.minimal(switch (r.subject) {
      LwSubject.ahora => _Icon.zap,
      LwSubject.chats => _Icon.msg,
      LwSubject.cron => _Icon.clock,
      LwSubject.tasks => _Icon.kanban,
      LwSubject.newChat => _Icon.plus,
    });
    return ctx.finish('minimal', validUntilMs);
  }

  int? _staleAt(int updatedMs) =>
      updatedMs > 0 ? updatedMs + lwStaleAfterMs + 1 : null;

  int? _earliest(Iterable<int?> moments) {
    int? least;
    for (final m in moments) {
      if (m == null || m <= w.nowMs) continue;
      if (least == null || m < least) least = m;
    }
    return least;
  }

  int _nextMidnight() {
    final t = DateTime.fromMillisecondsSinceEpoch(w.nowMs);
    return DateTime(t.year, t.month, t.day + 1).millisecondsSinceEpoch;
  }

  // ------------------------------------------------------------------ Ahora

  LwFrame ahora(LwAhoraScene s) {
    final validUntil = _earliest([
      if (s.mood != LwMood.setup) _staleAt(s.sinceMs > 0 ? s.sinceMs : w.nowMs),
      if (s.lastAtMs != null || s.needs.isNotEmpty) _nextMidnight(),
    ]);
    final plans = <(String, _Plan)>[];
    switch (s.mood) {
      case LwMood.need:
        final need = s.needs.first;
        final description = need.question
            ? w.s.lwpA11yAsks(need.who, need.what ?? w.s.lwpAsksYou)
            : w.s.lwpA11yNeeds(need.who, need.what ?? w.s.lwpNeedsPermission);
        if (!span.oneRow) {
          // Two cells wide: the stacked form first, it keeps the request
          // whole where a side-by-side one would cut it.
          if (!span.wide) {
            for (var level = 0; level <= 2; level++) {
              plans.add((
                'need/narrow/$level',
                (c) => _needNarrow(c, need, level, description),
              ));
            }
          }
          for (var level = 0; level <= 8; level++) {
            plans.add((
              'need/$level',
              (c) => _needBoard(c, s, need, level, description),
            ));
          }
        }
        for (var level = 0; level <= 3; level++) {
          plans.add((
            'need/strip/$level',
            (c) => _needStrip(c, need, level, description),
          ));
        }
      case LwMood.work:
        final run = s.runs.first;
        final about = [
          w.phase(run.phase),
          if (run.about != null) run.about!,
        ].join(' · ');
        final description = w.s.lwpA11yWorking(run.who, about);
        if (!span.oneRow) {
          for (var level = 0; level <= 4; level++) {
            plans.add((
              'work/$level',
              (c) => _workBoard(c, run, level, description),
            ));
          }
        }
        for (var level = 0; level <= 2; level++) {
          plans.add((
            'work/strip/$level',
            (c) => _strip(
              c,
              face: LwFace(run.profile),
              ring: _Ring.works,
              title: run.who,
              line: about,
              level: level,
              open: run.open,
              description: description,
            ),
          ));
        }
      case LwMood.calm:
        final line = s.lastTitle == null || s.lastAtMs == null
            ? null
            : w.s.lwpLastFinished(s.lastTitle!, w.moment(s.lastAtMs!));
        final description = w.s.lwpCalmTitle;
        if (!span.oneRow) {
          for (var level = 0; level <= 5; level++) {
            plans.add((
              'calm/$level',
              (c) => _calmBoard(c, s, line, level, description),
            ));
          }
        }
        for (var level = 0; level <= 2; level++) {
          plans.add((
            'calm/strip/$level',
            (c) => _strip(
              c,
              icon: _Icon.zap,
              title: w.s.lwpCalmTitle,
              line: line ?? w.s.lwpCalmEnd,
              wordsTitle: true,
              level: level,
              open: s.open,
              description: description,
            ),
          ));
        }
      case LwMood.offline:
        final since = s.sinceMs > 0 ? w.moment(s.sinceMs) : null;
        final title = s.instanceLabel == null || s.instanceLabel!.trim().isEmpty
            ? w.s.lwpOfflineTitleGeneric
            : w.s.lwpOfflineTitle(s.instanceLabel!.trim());
        final line = s.lastTitle == null || s.lastAtMs == null
            ? null
            : w.s.lwpLastFinished(s.lastTitle!, w.moment(s.lastAtMs!));
        final description = since == null
            ? w.s.lwpOffline
            : w.s.lwpA11yOffline(since);
        if (!span.oneRow) {
          for (var level = 0; level <= 5; level++) {
            plans.add((
              'offline/$level',
              (c) =>
                  _offlineBoard(c, s, title, line, since, level, description),
            ));
          }
        }
        for (var level = 0; level <= 2; level++) {
          plans.add((
            'offline/strip/$level',
            (c) => _strip(
              c,
              icon: _Icon.wifiOff,
              title: w.s.lwpOffline,
              line: since == null ? title : w.s.lwpStartedAt(since),
              wordsTitle: true,
              wordsLine: since != null,
              level: level,
              open: s.open,
              description: description,
              dim: true,
            ),
          ));
        }
      case LwMood.setup:
      case LwMood.empty:
        final description = w.s.lwpA11ySetup;
        if (!span.oneRow) {
          for (var level = 0; level <= 3; level++) {
            plans.add((
              'setup/$level',
              (c) => _setupBoard(c, level, description),
            ));
          }
        }
        for (var level = 0; level <= 2; level++) {
          plans.add((
            'setup/strip/$level',
            (c) => _strip(
              c,
              icon: _Icon.zap,
              title: w.s.lwpSetupTitle,
              line: w.s.lwpSetupLine,
              wordsTitle: true,
              wordsLine: true,
              level: level,
              open: const LwOpen.setup(),
              description: description,
            ),
          ));
        }
    }
    return _run(plans, validUntilMs: validUntil);
  }

  /// A narrow card (two cells): who and when on top, the face beside the
  /// request in up to two lines, the answers along the bottom. Simpler
  /// levels drop the top row, then the face.
  bool _needNarrow(_Ctx c, LwNeed need, int level, String description) {
    final C = c.content;
    final buttonsTop = C.bottom - LwGrid.button;
    final textBottom = buttonsTop - LwGrid.gap;
    var y = C.top;
    LwTextBox? who;
    LwTextBox? when;
    if (level == 0) {
      if (need.sinceMs > 0) {
        when = c.fit(
          w.time(need.sinceMs),
          LwType.caption,
          c.p.ink3,
          maxWidth: C.width / 2,
          ellipsis: false,
        );
      }
      who = c.fit(
        need.who,
        LwType.eyebrow,
        c.p.ink2,
        maxWidth: C.width - (when == null ? 0 : when.width + LwGrid.gap),
      );
      if (who == null) return false;
    }
    final topH = who == null ? 0.0 : math.max(who.height, when?.height ?? 0);
    if (who != null) y += topH + LwGrid.gap;
    final face = level <= 1 ? LwGrid.face : 0.0;
    final left = C.left + (face > 0 ? face + LwGrid.gap : 0);
    final title = c.fit(
      need.question ? w.s.lwpAsksYou : w.s.lwpNeedsPermission,
      LwType.titleSmall,
      c.p.ink,
      maxWidth: C.right - left,
      maxLines: 2,
      minSp: LwGrid.rowLine,
      ellipsis: false,
    );
    if (title == null) return false;
    final rowH = math.max(face, title.height);
    if (y + rowH > textBottom) return false;
    c.zone(c.bounds, need.open, w.s.lwpA11yOpenChat(need.who));
    if (who != null) {
      c.put(who, Offset(C.left, C.top + (topH - who.height) / 2));
      if (when != null) {
        c.put(
          when,
          Offset(C.right - when.width, C.top + (topH - when.height) / 2),
        );
      }
    }
    if (face > 0) {
      c.face(
        Rect.fromLTWH(
          C.left + _Ctx.ringReach,
          y + (rowH - face) / 2,
          face - _Ctx.ringReach * 2,
          face - _Ctx.ringReach * 2,
        ),
        LwFace(need.profile),
        ring: _Ring.waits,
      );
    }
    c.put(title, Offset(left, y + (rowH - title.height) / 2));
    final row = Rect.fromLTWH(C.left, buttonsTop, C.width, LwGrid.button);
    if (!_answerButtons(c, need, row) &&
        !_answerButtons(c, need, row, iconsOnly: true)) {
      return false;
    }
    c.description = description;
    return true;
  }

  bool _needBoard(
    _Ctx c,
    LwAhoraScene s,
    LwNeed need,
    int plan,
    String description,
  ) {
    var level = plan;
    final C = c.content;
    final buttonsTop = C.bottom - LwGrid.button;
    final textBottom = buttonsTop - LwGrid.gap;
    final avail = textBottom - C.top;
    if (avail < 0) return false;
    // From level 7 the answers are icons alone (their words stay in the
    // tap zones a screen reader hears); level 7 keeps a one-line title.
    final iconsOnly = level >= 7;
    final textLevel = level == 7
        ? 4
        : level == 8
        ? 6
        : level;
    level = textLevel;
    final face = level >= 6
        ? 0.0
        : avail >= LwGrid.faceLarge && C.width >= 200
        ? LwGrid.faceLarge
        : avail >= LwGrid.faceMedium
        ? LwGrid.faceMedium
        : avail >= LwGrid.face
        ? LwGrid.face
        : 0.0;
    final left = C.left + (face > 0 ? face + LwGrid.gap : 0);
    // A second face, of who works meanwhile, only in the fullest plan.
    final second =
        level == 0 &&
            span.wide &&
            s.runs.isNotEmpty &&
            avail >= LwGrid.faceMedium
        ? s.runs.first
        : null;
    final right = second == null ? C.right : C.right - LwGrid.face - LwGrid.gap;
    final width = right - left;
    if (width < 40) return false;
    final blocks = <LwTextBox>[];
    final gaps = <double>[];
    LwTextBox? end;
    if (level <= 2) {
      if (level <= 1 && need.sinceMs > 0) {
        // A time is whole or absent: never "10…".
        end = c.fit(
          w.time(need.sinceMs),
          LwType.caption,
          c.p.ink3,
          maxWidth: width / 2,
          ellipsis: false,
        );
      }
      final eyebrow = c.fit(
        need.who,
        LwType.eyebrow,
        c.p.ink2,
        maxWidth: width - (end == null ? 0 : end.width + LwGrid.gap),
      );
      if (eyebrow == null) return false;
      blocks.add(eyebrow);
    }
    final titleWords = need.question ? w.s.lwpAsksYou : w.s.lwpNeedsPermission;
    if (level <= 4) {
      final title = c.fit(
        titleWords,
        LwType.title,
        c.p.ink,
        maxWidth: width,
        maxLines: level <= 3 ? 2 : 1,
        minSp: LwGrid.rowTitle,
        ellipsis: false,
      );
      if (title == null) return false;
      if (blocks.isNotEmpty) gaps.add(LwGrid.gapTight);
      blocks.add(title);
    }
    if (level == 0 && need.what != null) {
      final line = c.fit(need.what!, LwType.line, c.p.ink2, maxWidth: width);
      if (line == null) return false;
      gaps.add(LwGrid.gapTight);
      blocks.add(line);
    }
    // The first row is as tall as the taller of the eyebrow and its end.
    final firstH = blocks.isEmpty
        ? 0.0
        : math.max(blocks.first.height, end?.height ?? 0);
    final blockH =
        firstH +
        blocks.skip(1).fold(0.0, (h, b) => h + b.height) +
        gaps.fold(0.0, (a, b) => a + b);
    if (blockH > avail) return false;
    // Paint. The face is centred on the text block (or on the room when the
    // block is shorter than the face).
    c.zone(c.bounds, need.open, w.s.lwpA11yOpenChat(need.who));
    if (face > 0) {
      final top =
          C.top + math.max(0.0, math.min((blockH - face) / 2, avail - face));
      c.face(
        Rect.fromLTWH(C.left, top, face, face),
        LwFace(need.profile),
        ring: _Ring.waits,
      );
    }
    var y = C.top;
    for (var i = 0; i < blocks.length; i++) {
      if (i > 0) y += gaps[i - 1];
      if (i == 0) {
        c.put(blocks[i], Offset(left, y + (firstH - blocks[i].height) / 2));
        if (end != null) {
          c.put(end, Offset(right - end.width, y + (firstH - end.height) / 2));
        }
        y += firstH;
      } else {
        c.put(blocks[i], Offset(left, y));
        y += blocks[i].height;
      }
    }
    if (second != null) {
      final box = Rect.fromLTWH(
        C.right - LwGrid.face,
        C.top,
        LwGrid.face,
        LwGrid.face,
      );
      c.face(box, LwFace(second.profile), ring: _Ring.works);
      // The name sits under the ring, not under the face: the ring of work
      // reaches [_Ctx.ringReach] beyond the face on every side.
      final name = c.fit(
        second.who,
        LwType.caption,
        c.p.ink3,
        maxWidth: LwGrid.face + LwGrid.gap,
        ellipsis: false,
      );
      final nameTop = box.bottom + _Ctx.ringReach + LwGrid.gapTight;
      if (name != null &&
          nameTop + name.height <= textBottom &&
          name.width <= C.right - (box.center.dx - name.width / 2)) {
        c.put(
          name,
          Offset(
            math.min(box.center.dx - name.width / 2, C.right - name.width),
            nameTop,
          ),
        );
      }
    }
    if (!_answerButtons(
      c,
      need,
      Rect.fromLTWH(C.left, buttonsTop, C.width, LwGrid.button),
      iconsOnly: iconsOnly,
    )) {
      return false;
    }
    c.description = description;
    return true;
  }

  /// Allow / Deny side by side; without an answer payload, Open alone.
  /// The answers carry their words when both fit their pills (with or
  /// without the icon), else both are icons alone: never one of each.
  bool _answerButtons(_Ctx c, LwNeed need, Rect row, {bool iconsOnly = false}) {
    if (need.answerPayload == null) {
      final words = !iconsOnly && c.buttonFits(row, w.s.lwpOpen);
      if (!c.button(
        row,
        words ? w.s.lwpOpen : '',
        primary: true,
        icon: words ? null : _Icon.check,
      )) {
        return false;
      }
      c.zone(row, need.open, w.s.lwpOpen);
      return true;
    }
    final half = LwGrid.floor((row.width - LwGrid.gap) / 2);
    if (half < LwGrid.tap) return false;
    final yes = Rect.fromLTWH(row.left, row.top, half, row.height);
    final no = Rect.fromLTWH(row.right - half, row.top, half, row.height);
    final words =
        !iconsOnly &&
        c.buttonFits(yes, w.s.lwpAllow) &&
        c.buttonFits(no, w.s.lwpDeny);
    final withIcons =
        words &&
        c.buttonFits(yes, w.s.lwpAllow, icon: true) &&
        c.buttonFits(no, w.s.lwpDeny, icon: true);
    if (!c.button(
      yes,
      words ? w.s.lwpAllow : '',
      primary: true,
      icon: withIcons || !words ? _Icon.check : null,
    )) {
      return false;
    }
    if (!c.button(
      no,
      words ? w.s.lwpDeny : '',
      primary: false,
      icon: withIcons || !words ? _Icon.cross : null,
    )) {
      return false;
    }
    c.answer(yes, LwActionKind.approve, need, w.s.lwpA11yAllow(need.who));
    c.answer(no, LwActionKind.deny, need, w.s.lwpA11yDeny(need.who));
    return true;
  }

  bool _needStrip(_Ctx c, LwNeed need, int level, String description) {
    final C = c.content;
    if (C.height < 24) return false;
    final face = LwGrid.floor(math.min(LwGrid.face, C.height));
    var right = C.right;
    // Four cells: the answers as two small pills at the end.
    final answers =
        need.answerPayload != null &&
        span.wide &&
        level <= 1 &&
        C.height >= LwGrid.buttonSmall;
    Rect? yes;
    Rect? no;
    if (answers) {
      final h = LwGrid.buttonSmall;
      final top = C.top + (C.height - h) / 2;
      final labels = level == 0;
      final yesW = labels ? _pillWidth(c, w.s.lwpAllow, h) : h;
      final noW = labels ? _pillWidth(c, w.s.lwpDeny, h) : h;
      if (yesW == null || noW == null) return false;
      no = Rect.fromLTWH(C.right - noW, top, noW, h);
      // Apart by the tap minimum less the pill: their 48 dp targets touch,
      // never overlap.
      yes = Rect.fromLTWH(
        no.left - math.max(LwGrid.gapTight * 2, LwGrid.tap - h) - yesW,
        top,
        yesW,
        h,
      );
      right = yes.left - LwGrid.gap;
    }
    final left = C.left + face + LwGrid.gap;
    final width = right - left;
    if (width < 40) return false;
    final title = c.fit(need.who, LwType.rowTitle, c.p.ink, maxWidth: width);
    if (title == null) return false;
    // The request in words, else the shorter "te necesita", else nothing.
    LwTextBox? line;
    if (level <= 2) {
      for (final words in [
        need.question ? w.s.lwpAsksYou : w.s.lwpNeedsPermission,
        w.s.lwpNeedsYou,
      ]) {
        line = c.fit(
          words,
          LwType.rowLine,
          c.p.ink2,
          maxWidth: width,
          ellipsis: false,
        );
        if (line != null) break;
      }
    }
    final blockH =
        title.height + (line == null ? 0 : LwGrid.gapTight / 2 + line.height);
    if (blockH > C.height) return false;
    c.zone(c.bounds, need.open, w.s.lwpA11yOpenChat(need.who));
    c.face(
      Rect.fromLTWH(C.left, C.top + (C.height - face) / 2, face, face),
      LwFace(need.profile),
      ring: _Ring.waits,
    );
    var y = C.top + (C.height - blockH) / 2;
    c.put(title, Offset(left, y));
    if (line != null) {
      y += title.height + LwGrid.gapTight / 2;
      c.put(line, Offset(left, y));
    }
    if (yes != null && no != null) {
      final labels = level == 0;
      if (!c.button(
        yes,
        labels ? w.s.lwpAllow : '',
        primary: true,
        icon: _Icon.check,
      )) {
        return false;
      }
      if (!c.button(
        no,
        labels ? w.s.lwpDeny : '',
        primary: false,
        icon: _Icon.cross,
      )) {
        return false;
      }
      c.answer(yes, LwActionKind.approve, need, w.s.lwpA11yAllow(need.who));
      c.answer(no, LwActionKind.deny, need, w.s.lwpA11yDeny(need.who));
    }
    c.description = description;
    return true;
  }

  /// Width of a small pill holding [label] with its icon, or null when the
  /// label cannot be set in one line at the smallest size.
  double? _pillWidth(_Ctx c, String label, double height) {
    final box = c.fit(
      label,
      LwType.button,
      c.p.ink,
      maxWidth: 160,
      ellipsis: false,
    );
    if (box == null) return null;
    // Up to the grid, never down: the label and its icon always fit.
    return LwGrid.ceil(
      box.width + _Ctx.buttonPad * 2 + _Ctx.buttonIcon + _Ctx.buttonIconGap,
    );
  }

  bool _workBoard(_Ctx c, LwRun run, int level, String description) {
    final C = c.content;
    final face = level <= 2 ? LwGrid.faceMedium : 0.0;
    final dots = _Ctx.dotsWidth;
    // The word is whole or left out: the still dots say it alone.
    final eyebrow = c.fit(
      w.s.lwpWorking,
      LwType.eyebrow,
      c.p.ink2,
      maxWidth: C.width - face - LwGrid.gap - dots - LwGrid.gapTight * 2,
      ellipsis: false,
    );
    final topH = math.max(face, eyebrow?.height ?? _Ctx.dotSmall);
    final title = c.fit(run.who, LwType.titleSmall, c.p.ink, maxWidth: C.width);
    if (title == null) return false;
    final about = [
      w.phase(run.phase),
      if (run.about != null) run.about!,
    ].join(' · ');
    final line = level <= 1
        ? c.fit(about, LwType.line, c.p.ink2, maxWidth: C.width)
        : null;
    final since = level == 0 && run.sinceMs > 0
        ? c.fit(
            w.s.lwpStartedAt(w.time(run.sinceMs)),
            LwType.caption,
            c.p.ink3,
            maxWidth: C.width,
          )
        : null;
    if (level >= 4 && (line != null || since != null)) return false;
    final blockH =
        title.height +
        (line == null ? 0 : LwGrid.gapTight + line.height) +
        (since == null ? 0 : LwGrid.gapTight + since.height);
    if (C.top + topH + LwGrid.gap + blockH > C.bottom) return false;
    c.zone(c.bounds, run.open, w.s.lwpA11yOpenChat(run.who));
    if (face > 0) {
      c.face(
        Rect.fromLTWH(C.left, C.top, face, face),
        LwFace(run.profile),
        ring: _Ring.works,
      );
    }
    if (eyebrow != null) {
      final ex = C.right - dots - LwGrid.gapTight * 2 - eyebrow.width;
      c.put(eyebrow, Offset(ex, C.top + (topH - eyebrow.height) / 2));
    }
    c.dots(Offset(C.right - dots, C.top + topH / 2));
    var y = C.bottom - blockH;
    c.put(title, Offset(C.left, y));
    y += title.height;
    if (line != null) {
      y += LwGrid.gapTight;
      c.put(line, Offset(C.left, y));
      y += line.height;
    }
    if (since != null) {
      y += LwGrid.gapTight;
      c.put(since, Offset(C.left, y));
    }
    c.description = description;
    return true;
  }

  bool _calmBoard(
    _Ctx c,
    LwAhoraScene s,
    String? line,
    int level,
    String description,
  ) {
    final C = c.content;
    final head = c.eyebrow(
      C.top,
      icon: _Icon.zap,
      text: w.s.lwpAhora,
      end: level <= 2 ? w.s.lwpCalmEnd : null,
    );
    if (head == null) return false;
    var y = C.top + head;
    final faces = level <= 1 ? s.faces : const <LwFace>[];
    final faceD = LwGrid.face;
    final fit = ((C.width + 8) / (faceD + 8)).floor();
    final shown = faces.take(math.max(0, math.min(fit, 4))).toList();
    final title = level <= 4
        ? c.fit(
            w.s.lwpCalmTitle,
            LwType.titleSmall,
            c.p.ink,
            maxWidth: C.width,
            maxLines: 2,
            minSp: LwGrid.rowTitle,
            ellipsis: false,
          )
        : null;
    if (level <= 4 && title == null) return false;
    // "Última: …" is whole or left out: cut, it would say only "Última: …".
    final sub = level == 0 && line != null
        ? c.fit(line, LwType.line, c.p.ink2, maxWidth: C.width, ellipsis: false)
        : null;
    final blockH =
        (title?.height ?? 0) + (sub == null ? 0 : LwGrid.gapTight + sub.height);
    final facesH = shown.isEmpty ? 0.0 : LwGrid.gap + faceD;
    if (y + facesH + (blockH > 0 ? LwGrid.gap + blockH : 0) > C.bottom) {
      return false;
    }
    c.zone(c.bounds, s.open, w.s.lwpA11yOpenApp);
    if (shown.isNotEmpty) {
      y += LwGrid.gap;
      var x = C.left;
      for (final f in shown) {
        c.face(Rect.fromLTWH(x, y, faceD, faceD), f);
        x += faceD + 8;
      }
    }
    if (title != null) {
      var ty = C.bottom - blockH;
      c.put(title, Offset(C.left, ty));
      ty += title.height;
      if (sub != null) c.put(sub, Offset(C.left, ty + LwGrid.gapTight));
    }
    c.description = description;
    return true;
  }

  bool _offlineBoard(
    _Ctx c,
    LwAhoraScene s,
    String title,
    String? line,
    String? since,
    int level,
    String description,
  ) {
    final C = c.content;
    final head = c.eyebrow(
      C.top,
      icon: _Icon.wifiOff,
      text: w.s.lwpOffline,
      end: level <= 2 && since != null ? w.s.lwpStartedAt(since) : null,
    );
    if (head == null) return false;
    final y = C.top + head + LwGrid.gap;
    final face = level <= 1 ? LwGrid.faceMedium : 0.0;
    final left = C.left + (face > 0 ? face + LwGrid.gap : 0);
    final width = C.right - left;
    final titleBox = level <= 4
        ? c.fit(
            title,
            LwType.titleSmall,
            c.p.dim(c.p.ink),
            maxWidth: width,
            maxLines: level <= 3 ? 2 : 1,
            minSp: LwGrid.rowTitle,
          )
        : null;
    if (level <= 4 && titleBox == null) return false;
    final sub = level == 0 && line != null
        ? c.fit(
            line,
            LwType.line,
            c.p.dim(c.p.ink2),
            maxWidth: width,
            ellipsis: false,
          )
        : null;
    final blockH =
        (titleBox?.height ?? 0) +
        (sub == null ? 0 : LwGrid.gapTight + sub.height);
    if (y + math.max(blockH, face) > C.bottom) return false;
    c.zone(c.bounds, s.open, w.s.lwpA11yOpenApp);
    if (face > 0) {
      c.face(
        Rect.fromLTWH(C.left, y + math.max(0, (blockH - face) / 2), face, face),
        s.faces.first,
        dim: true,
      );
    }
    if (titleBox != null) {
      final ty = y + math.max(0, (face - blockH) / 2);
      c.put(titleBox, Offset(left, ty));
      if (sub != null) {
        c.put(sub, Offset(left, ty + titleBox.height + LwGrid.gapTight));
      }
    }
    c.description = description;
    return true;
  }

  bool _setupBoard(_Ctx c, int level, String description) {
    final C = c.content;
    final head = c.eyebrow(C.top, icon: _Icon.zap, text: w.s.lwpAhora);
    if (head == null) return false;
    final y = C.top + head + LwGrid.gap;
    final button = level <= 1;
    final bottom = button ? C.bottom - LwGrid.button - LwGrid.gap : C.bottom;
    final title = c.fit(
      w.s.lwpSetupTitle,
      LwType.title,
      c.p.ink,
      maxWidth: C.width,
      maxLines: 2,
      minSp: LwGrid.rowTitle,
      ellipsis: false,
    );
    if (title == null) return false;
    final line = level == 0
        ? c.fit(
            w.s.lwpSetupLine,
            LwType.line,
            c.p.ink2,
            maxWidth: C.width,
            maxLines: 3,
            ellipsis: false,
          )
        : null;
    final blockH =
        title.height + (line == null ? 0 : LwGrid.gapTight + line.height);
    if (y + blockH > bottom) return false;
    if (level >= 3 && line != null) return false;
    c.zone(c.bounds, const LwOpen.setup(), description);
    c.put(title, Offset(C.left, y));
    if (line != null) {
      c.put(line, Offset(C.left, y + title.height + LwGrid.gapTight));
    }
    if (button) {
      final label = c.fit(
        w.s.lwpSetupButton,
        LwType.button,
        c.p.onAccent,
        maxWidth: C.width - _Ctx.buttonPad * 2,
        ellipsis: false,
      );
      if (label == null) return false;
      final bw = math.min(
        C.width,
        math.max(120.0, LwGrid.snap(label.width + _Ctx.buttonPad * 2)),
      );
      final rect = Rect.fromLTWH(
        C.left,
        C.bottom - LwGrid.button,
        bw,
        LwGrid.button,
      );
      if (!c.button(rect, w.s.lwpSetupButton, primary: true)) return false;
      c.zone(rect, const LwOpen.setup(), w.s.lwpSetupButton);
    }
    c.description = description;
    return true;
  }

  /// A one-row card: a face or an icon chip, a title and a line.
  bool _strip(
    _Ctx c, {
    LwFace? face,
    _Icon? icon,
    _Ring ring = _Ring.none,
    required String title,
    String? line,
    String? end,
    required int level,
    required LwOpen open,
    required String description,
    bool dim = false,
    bool wordsTitle = false,
    bool wordsLine = false,
  }) {
    // [wordsTitle] / [wordsLine]: the app's own words, whole or left out
    // (the owner's data is cut with an ellipsis instead).
    final C = c.content;
    if (C.height < 24 || C.width < 80) return false;
    final lead = LwGrid.floor(math.min(LwGrid.face, C.height));
    final left = C.left + lead + LwGrid.gap;
    LwTextBox? endBox;
    if (end != null && level == 0) {
      endBox = c.fit(
        end,
        LwType.rowTitle,
        c.p.ink,
        maxWidth: C.width / 3,
        ellipsis: false,
      );
    }
    final width =
        C.right - left - (endBox == null ? 0 : endBox.width + LwGrid.gap);
    if (width < 40) return false;
    final ink = dim ? c.p.dim(c.p.ink) : c.p.ink;
    final ink2 = dim ? c.p.dim(c.p.ink2) : c.p.ink2;
    // Without a line, a title of the app's words may take two lines.
    final titleBox = c.fit(
      title,
      LwType.rowTitle,
      ink,
      maxWidth: width,
      maxHeight: C.height,
      maxLines: wordsTitle && (line == null || level >= 2) ? 2 : 1,
      minSp: wordsTitle ? LwGrid.rowLine : null,
      ellipsis: !wordsTitle,
    );
    if (titleBox == null) return false;
    final lineBox = line != null && level <= 1
        ? c.fit(
            line,
            LwType.rowLine,
            ink2,
            maxWidth: width,
            ellipsis: !wordsLine,
          )
        : null;
    if (level <= 1 && line != null && lineBox == null) return false;
    final blockH =
        titleBox.height +
        (lineBox == null ? 0 : LwGrid.gapTight / 2 + lineBox.height);
    if (blockH > C.height) return false;
    c.zone(c.bounds, open, description);
    final leadRect = Rect.fromLTWH(
      C.left,
      C.top + (C.height - lead) / 2,
      lead,
      lead,
    );
    if (face != null) {
      c.face(leadRect, face, ring: ring, dim: dim);
    } else if (icon != null) {
      c.chip(leadRect, icon, dim: dim);
    }
    var y = C.top + (C.height - blockH) / 2;
    c.put(titleBox, Offset(left, y));
    if (lineBox != null) {
      y += titleBox.height + LwGrid.gapTight / 2;
      c.put(lineBox, Offset(left, y));
    }
    if (endBox != null) {
      c.put(
        endBox,
        Offset(C.right - endBox.width, C.top + (C.height - endBox.height) / 2),
      );
    }
    c.description = description;
    return true;
  }

  // ------------------------------------------------------------------ Chats

  LwFrame chats(LwChatsScene s) {
    final validUntil = _earliest([
      if (s.mood != LwMood.setup) _staleAt(s.sinceMs),
      if (s.rows.any((r) => r.atMs != null)) _nextMidnight(),
    ]);
    final plans = <(String, _Plan)>[];
    final first = s.rows.isEmpty ? null : s.rows.first;
    final description = s.rows.isEmpty
        ? (s.mood == LwMood.setup
              ? w.s.lwpChatsEmptyTitle
              : w.s.lwpA11yChats(0, ''))
        : w.s.lwpA11yChats(s.rows.length, first!.title);
    if (s.rows.isEmpty) {
      final open = s.mood == LwMood.setup
          ? const LwOpen.setup()
          : const LwOpen.app();
      if (!span.oneRow) {
        for (var level = 0; level <= 2; level++) {
          plans.add((
            'empty/$level',
            (c) => _emptyBoard(
              c,
              _Icon.msg,
              w.s.lwpChats,
              w.s.lwpChatsEmptyTitle,
              w.s.lwpChatsEmptyLine,
              level,
              open,
              description,
            ),
          ));
        }
      }
      for (var level = 0; level <= 2; level++) {
        plans.add((
          'empty/strip/$level',
          (c) => _strip(
            c,
            icon: _Icon.msg,
            title: w.s.lwpChatsEmptyTitle,
            line: w.s.lwpChatsEmptyLine,
            level: level,
            open: open,
            description: description,
            wordsTitle: true,
            wordsLine: true,
          ),
        ));
      }
      return _run(plans, validUntilMs: validUntil);
    }
    if (!span.oneRow) {
      for (var level = 0; level <= 4; level++) {
        plans.add((
          'rows/$level',
          (c) => _chatsBoard(c, s, level, description),
        ));
      }
    }
    for (var level = 0; level <= 2; level++) {
      plans.add((
        'rows/strip/$level',
        (c) => _strip(
          c,
          face: LwFace(first!.profile),
          ring: first.waits
              ? _Ring.waits
              : first.running
              ? _Ring.works
              : _Ring.none,
          title: first.title,
          line: _chatLine(first),
          end: first.atMs == null ? null : w.moment(first.atMs!),
          level: level,
          open: first.open,
          description: description,
          dim: s.mood == LwMood.offline,
        ),
      ));
    }
    return _run(plans, validUntilMs: validUntil);
  }

  String? _chatLine(LwChatRow row) => row.waits
      ? w.s.lwpChatWaits
      : row.running
      ? w.s.lwpChatWriting
      : row.line;

  List<String> _chatsEnd(LwChatsScene s) => s.mood == LwMood.offline
      ? _lastKnown(s.sinceMs)
      : [
          s.waiting > 0
              ? w.s.lwpChatsWaiting(s.waiting)
              : s.running > 0
              ? w.s.lwpChatsRunning(s.running)
              : w.s.lwpChatsWaiting(0),
        ];

  /// The note of old data: "última conocida · 9:28", else "9:28" alone.
  List<String> _lastKnown(int sinceMs) => sinceMs > 0
      ? ['${w.s.lwpLastKnown} · ${w.moment(sinceMs)}', w.moment(sinceMs)]
      : [w.s.lwpLastKnown];

  bool _chatsBoard(_Ctx c, LwChatsScene s, int level, String description) {
    final C = c.content;
    final dim = s.mood == LwMood.offline;
    final head = c.eyebrow(
      C.top,
      icon: _Icon.msg,
      text: w.s.lwpChats,
      ends: level <= 2 ? _chatsEnd(s) : null,
    );
    if (head == null) return false;
    final top = C.top + head + LwGrid.gapTight * 2;
    final withLine = level == 0;
    final withTime = level <= 1;
    final face = span.wide ? LwGrid.faceSmall : LwGrid.faceTiny;
    final titleH = typesetter.dp(LwGrid.rowTitle) * LwType.rowTitle.lineHeight;
    final lineH = typesetter.dp(LwGrid.rowLine) * LwType.rowLine.lineHeight;
    final rowH = LwGrid.snap(
      math.max(
        LwGrid.tap,
        (withLine ? titleH + 2 + lineH : titleH) + LwGrid.gap,
      ),
    );
    final count = math.min(s.rows.length, ((C.bottom - top) / rowH).floor());
    if (count < 1) return false;
    if (level >= 3 && count > 1) {
      // Level 3: only the first row, as a line of text.
      return _chatsOne(c, s, top, description);
    }
    c.zone(
      c.bounds,
      s.rows.first.open,
      w.s.lwpA11yOpenChat(s.rows.first.title),
    );
    final ink = dim ? c.p.dim(c.p.ink) : c.p.ink;
    final ink2 = dim ? c.p.dim(c.p.ink2) : c.p.ink2;
    final ink3 = dim ? c.p.dim(c.p.ink3) : c.p.ink3;
    // The times stand in one column: the dot's room is kept in every row
    // when any row carries one.
    final dotColumn = !dim && s.rows.take(count).any((r) => r.waits);
    for (var i = 0; i < count; i++) {
      final row = s.rows[i];
      final rect = Rect.fromLTWH(C.left, top + i * rowH, C.width, rowH);
      if (i > 0) c.hairline(rect.top, C.left, C.right);
      final left = rect.left + face + LwGrid.gap;
      var right = rect.right;
      LwTextBox? time;
      if (withTime && row.atMs != null) {
        time = c.fit(
          w.moment(row.atMs!),
          LwType.captionTabular,
          ink3,
          maxWidth: rect.width / 3,
          ellipsis: false,
        );
      }
      final dot = row.waits && !dim;
      if (dotColumn) right -= _Ctx.dotD + LwGrid.gapTight * 2;
      if (time != null) right -= time.width + LwGrid.gap;
      final width = right - left;
      if (width < 40) return false;
      final title = c.fit(row.title, LwType.rowTitle, ink, maxWidth: width);
      if (title == null) return false;
      final lineText = withLine ? _chatLine(row) : null;
      final line = lineText == null
          ? null
          : c.fit(lineText, LwType.rowLine, ink2, maxWidth: width);
      final blockH = title.height + (line == null ? 0 : 2 + line.height);
      if (blockH > rowH) return false;
      final y = rect.top + (rowH - blockH) / 2;
      c.face(
        Rect.fromLTWH(rect.left, rect.top + (rowH - face) / 2, face, face),
        LwFace(row.profile),
        ring: row.waits
            ? _Ring.waits
            : row.running
            ? _Ring.works
            : _Ring.none,
        dim: dim,
      );
      c.put(title, Offset(left, y));
      if (line != null) c.put(line, Offset(left, y + title.height + 2));
      var ex = rect.right;
      if (dotColumn) {
        ex -= _Ctx.dotD;
        if (dot) c.dot(Offset(ex + _Ctx.dotD / 2, rect.center.dy), c.p.accent);
        ex -= LwGrid.gapTight * 2;
      }
      if (time != null) {
        c.put(time, Offset(ex - time.width, rect.center.dy - time.height / 2));
      }
      c.zone(rect, row.open, w.s.lwpA11yOpenChat(row.title));
    }
    c.description = description;
    return true;
  }

  bool _chatsOne(_Ctx c, LwChatsScene s, double top, String description) {
    final C = c.content;
    final row = s.rows.first;
    final title = c.fit(
      row.title,
      LwType.rowTitle,
      c.p.ink,
      maxWidth: C.width,
      maxLines: 2,
    );
    if (title == null || top + title.height > C.bottom) return false;
    c.zone(c.bounds, row.open, w.s.lwpA11yOpenChat(row.title));
    c.put(title, Offset(C.left, top));
    c.description = description;
    return true;
  }

  /// A board with nothing to list: the eyebrow, a title and a line.
  bool _emptyBoard(
    _Ctx c,
    _Icon icon,
    String name,
    String title,
    String line,
    int level,
    LwOpen open,
    String description,
  ) {
    final C = c.content;
    final head = c.eyebrow(C.top, icon: icon, text: name);
    if (head == null) return false;
    final titleBox = c.fit(
      title,
      LwType.titleSmall,
      c.p.ink,
      maxWidth: C.width,
      maxLines: level <= 1 ? 2 : 1,
      minSp: LwGrid.rowTitle,
      ellipsis: false,
    );
    if (titleBox == null) return false;
    final lineBox = level == 0
        ? c.fit(
            line,
            LwType.line,
            c.p.ink2,
            maxWidth: C.width,
            maxLines: 3,
            ellipsis: false,
          )
        : null;
    if (level == 0 && lineBox == null) return false;
    final blockH =
        titleBox.height +
        (lineBox == null ? 0 : LwGrid.gapTight + lineBox.height);
    final top = C.top + head + LwGrid.gap;
    if (top + blockH > C.bottom) return false;
    c.zone(c.bounds, open, description);
    final y = top + (C.bottom - top - blockH) / 2;
    c.put(titleBox, Offset(C.left, y));
    if (lineBox != null) {
      c.put(lineBox, Offset(C.left, y + titleBox.height + LwGrid.gapTight));
    }
    c.description = description;
    return true;
  }

  // ------------------------------------------------------------------ Cron

  LwFrame cron(LwCronScene s) {
    final next = s.jobs.isEmpty ? null : s.jobs.first;
    final validUntil = _earliest([
      if (s.mood != LwMood.setup) _staleAt(s.sinceMs),
      for (final j in s.jobs)
        if ((j.job.nextRunAtMs ?? 0) > w.nowMs) j.job.nextRunAtMs! + 1,
      if (s.jobs.isNotEmpty) _nextMidnight(),
    ]);
    final plans = <(String, _Plan)>[];
    if (next == null) {
      final open = s.mood == LwMood.setup
          ? const LwOpen.setup()
          : const LwOpen.app();
      final description = w.s.lwpCronEmptyTitle;
      if (!span.oneRow) {
        for (var level = 0; level <= 2; level++) {
          plans.add((
            'empty/$level',
            (c) => _emptyBoard(
              c,
              _Icon.clock,
              w.s.lwpCron,
              w.s.lwpCronEmptyTitle,
              w.s.lwpCronEmptyLine,
              level,
              open,
              description,
            ),
          ));
        }
      }
      for (var level = 0; level <= 2; level++) {
        plans.add((
          'empty/strip/$level',
          (c) => _strip(
            c,
            icon: _Icon.clock,
            title: w.s.lwpCronEmptyTitle,
            line: w.s.lwpCronEmptyLine,
            level: level,
            open: open,
            description: description,
            wordsTitle: true,
            wordsLine: true,
          ),
        ));
      }
      return _run(plans, validUntilMs: validUntil);
    }
    final when = _cronWhen(next.job);
    final description = w.s.lwpA11yNextJob(next.job.name, when.$1);
    if (!span.oneRow) {
      for (var level = 0; level <= 4; level++) {
        plans.add(('next/$level', (c) => _cronBoard(c, s, level, description)));
      }
    }
    for (var level = 0; level <= 2; level++) {
      plans.add((
        'next/strip/$level',
        (c) => _strip(
          c,
          icon: _Icon.clock,
          title: next.job.name,
          line: when.$1,
          // "Hoy · 18:30" is whole or left out, never "Hoy · 1…".
          wordsLine: true,
          end: (next.job.nextRunAtMs ?? 0) > w.nowMs
              ? w.time(next.job.nextRunAtMs!)
              : null,
          level: level,
          open: next.open,
          description: description,
          dim: s.mood == LwMood.offline,
        ),
      ));
    }
    return _run(plans, validUntilMs: validUntil);
  }

  /// When a job runs (or how its last run went) and whether that is bad.
  (String, bool) _cronWhen(LauncherWidgetCronJob job) {
    final next = job.nextRunAtMs ?? 0;
    if (job.last.name == 'failed') {
      final last = job.lastRunAtMs ?? 0;
      return (
        [w.s.lwpCronFailed, if (last > 0) w.moment(last)].join(' · '),
        true,
      );
    }
    if (job.last.name == 'running') return (w.s.lwpCronRunning, false);
    if (job.paused) return (w.s.lwpCronPaused, false);
    if (next > w.nowMs) return (w.dayTime(next), false);
    return (w.s.lwpCronNoNext, false);
  }

  bool _cronBoard(_Ctx c, LwCronScene s, int level, String description) {
    final C = c.content;
    final dim = s.mood == LwMood.offline;
    final next = s.jobs.first;
    final others = s.jobs.skip(1).toList();
    final list = level == 0 && span.wide && others.isNotEmpty;
    final leftW = list ? math.max(136.0, LwGrid.snap(C.width * 0.4)) : C.width;
    final head = c.eyebrow(
      C.top,
      icon: _Icon.clock,
      text: w.s.lwpCron,
      ends: dim && level <= 2 ? _lastKnown(s.sinceMs) : null,
      width: leftW,
    );
    if (head == null) return false;
    final ink = dim ? c.p.dim(c.p.ink) : c.p.ink;
    final ink2 = dim ? c.p.dim(c.p.ink2) : c.p.ink2;
    final ahead = (next.job.nextRunAtMs ?? 0) > w.nowMs;
    // What the card is for is when: the time goes last. Levels: everything;
    // no list; no line; the name with its "when" line; the time alone.
    final withBig = level != 3;
    final withLine = level <= 1 || level == 3;
    final withTitle = level <= 3;
    final big = withBig
        ? c.fit(
            ahead ? w.time(next.job.nextRunAtMs!) : '—',
            LwType.big,
            ahead ? ink : c.p.ink3,
            maxWidth: leftW,
            minSp: level == 4 ? LwGrid.rowTitle : 24,
            ellipsis: false,
          )
        : null;
    if (withBig && big == null) return false;
    final title = withTitle
        ? c.fit(
            next.job.name,
            LwType.titleSmall,
            ink,
            maxWidth: leftW,
            minSp: LwGrid.rowLine,
          )
        : null;
    if (withTitle && title == null) return false;
    final (whenText, bad) = _cronWhen(next.job);
    final line = withLine
        ? c.fit(
            whenText,
            LwType.line,
            bad ? c.p.error : ink2,
            maxWidth: leftW,
            ellipsis: false,
          )
        : null;
    if (withLine && line == null) return false;
    final blockH =
        (title?.height ?? 0) +
        (line == null
            ? 0
            : (title == null ? 0 : LwGrid.gapTight) + line.height);
    final top = C.top + head;
    final bigH = big == null ? 0.0 : LwGrid.gap + big.height;
    if (top + bigH + LwGrid.gap + blockH > C.bottom) return false;
    c.zone(c.bounds, next.open, w.s.lwpA11yOpenJob(next.job.name));
    if (big != null) c.put(big, Offset(C.left, top + LwGrid.gap));
    final y = C.bottom - blockH;
    if (title != null) c.put(title, Offset(C.left, y));
    if (line != null) {
      c.put(
        line,
        Offset(C.left, title == null ? y : y + title.height + LwGrid.gapTight),
      );
    }
    if (list) {
      final x0 = C.left + leftW + LwGrid.gap;
      c.vline(x0, C.top, C.bottom);
      final x = x0 + LwGrid.gap;
      final width = C.right - x;
      final nameH = typesetter.dp(LwGrid.line) * LwType.line.lineHeight;
      final whenH = typesetter.dp(LwGrid.caption) * LwType.caption.lineHeight;
      final rowH = LwGrid.snap(
        math.max(LwGrid.tap, nameH + 2 + whenH + LwGrid.gap),
      );
      final count = math.min(others.length, (C.height / rowH).floor());
      if (count < 1 || width < 60) return false;
      final step = C.height / count;
      for (var i = 0; i < count; i++) {
        final job = others[i];
        final rect = Rect.fromLTWH(x0, C.top + i * step, C.right - x0, step);
        final name = c.fit(
          job.job.name,
          LwType.line.at(LwGrid.line),
          ink,
          maxWidth: width,
        );
        final (text, bad) = _cronWhen(job.job);
        final whenBox = c.fit(
          text,
          LwType.caption,
          bad ? c.p.error : ink2,
          maxWidth: width,
          ellipsis: false,
        );
        if (name == null || whenBox == null) return false;
        final h = name.height + 2 + whenBox.height;
        if (h > step) return false;
        final ty = rect.top + (step - h) / 2;
        c.put(name, Offset(x, ty));
        c.put(whenBox, Offset(x, ty + name.height + 2));
        c.zone(rect, job.open, w.s.lwpA11yOpenJob(job.job.name));
      }
    }
    c.description = description;
    return true;
  }

  // ------------------------------------------------------------------ Tasks

  LwFrame tasks(LwTasksScene s) {
    final validUntil = _earliest([
      if (s.mood != LwMood.setup) _staleAt(s.sinceMs),
    ]);
    final plans = <(String, _Plan)>[];
    if (s.mood == LwMood.setup ||
        s.mood == LwMood.empty ||
        (s.mood == LwMood.offline &&
            s.running + s.attention + s.pending == 0)) {
      final open = s.mood == LwMood.setup ? const LwOpen.setup() : s.open;
      final description = w.s.lwpTasksEmptyTitle;
      if (!span.oneRow) {
        for (var level = 0; level <= 2; level++) {
          plans.add((
            'empty/$level',
            (c) => _emptyBoard(
              c,
              _Icon.kanban,
              w.s.lwpTasks,
              w.s.lwpTasksEmptyTitle,
              w.s.lwpTasksEmptyLine,
              level,
              open,
              description,
            ),
          ));
        }
      }
      for (var level = 0; level <= 2; level++) {
        plans.add((
          'empty/strip/$level',
          (c) => _strip(
            c,
            icon: _Icon.kanban,
            title: w.s.lwpTasksEmptyTitle,
            line: w.s.lwpTasksEmptyLine,
            level: level,
            open: open,
            description: description,
            wordsTitle: true,
            wordsLine: true,
          ),
        ));
      }
      return _run(plans, validUntilMs: validUntil);
    }
    final description = w.s.lwpA11yTasks(s.running, s.attention, s.pending);
    if (!span.oneRow) {
      if (span.wide) {
        for (var level = 0; level <= 4; level++) {
          plans.add((
            'kpi/$level',
            (c) => _tasksWide(c, s, level, description),
          ));
        }
      }
      for (var level = 0; level <= 4; level++) {
        plans.add((
          'big/$level',
          (c) => _tasksNarrow(c, s, level, description),
        ));
      }
    }
    // Figures capped as on the board; a figure and its word never part
    // across lines (a no-break space joins them).
    String bound(String t) =>
        t.replaceAllMapped(RegExp(r'([\d+])\s'), (m) => '${m[1]}\u00A0');
    final strip = [
      bound('${_count(s.running)} ${w.s.lwpTasksInProgressUnit}'),
      if (s.pending > 0)
        bound(
          w.s
              .lwpTasksPendingCount(s.pending)
              .replaceAll('${s.pending}', _count(s.pending)),
        ),
    ].join(' · ');
    for (var level = 0; level <= 2; level++) {
      plans.add((
        'strip/$level',
        (c) => _strip(
          c,
          icon: _Icon.kanban,
          title: strip,
          wordsTitle: true,
          line: s.first,
          level: level,
          open: s.open,
          description: description,
          dim: s.mood == LwMood.offline,
        ),
      ));
    }
    return _run(plans, validUntilMs: validUntil);
  }

  bool _tasksWide(_Ctx c, LwTasksScene s, int level, String description) {
    final C = c.content;
    final dim = s.mood == LwMood.offline;
    final head = c.eyebrow(
      C.top,
      icon: _Icon.kanban,
      text: w.s.lwpTasks,
      ends: dim
          ? _lastKnown(s.sinceMs)
          : level == 0 && s.first != null
          ? [w.s.lwpTasksNext(s.first!)]
          : null,
    );
    if (head == null) return false;
    final ink = dim ? c.p.dim(c.p.ink) : c.p.ink;
    final ink2 = dim ? c.p.dim(c.p.ink2) : c.p.ink2;
    final columns = <(int, String, LwType, Color)>[
      (s.running, w.s.lwpTasksRunning, LwType.kpi.at(LwGrid.kpiLead), ink),
      if (level <= 1) (s.attention, w.s.lwpTasksAttention, LwType.kpi, ink),
      if (level <= 2) (s.pending, w.s.lwpTasksPending, LwType.kpi, ink2),
    ];
    const colGap = 24.0;
    final values = <LwTextBox>[];
    final labels = <LwTextBox>[];
    var total = 0.0;
    for (final (value, label, type, color) in columns) {
      final each = (C.width - colGap * (columns.length - 1)) / columns.length;
      final v = c.fit(
        _count(value),
        level >= 3 ? type.at(LwGrid.bigSmall - 4) : type,
        color,
        maxWidth: each,
        minSp: 20,
        ellipsis: false,
      );
      final l = c.fit(
        label,
        LwType.caption,
        ink2,
        maxWidth: each,
        ellipsis: false,
      );
      if (v == null || l == null) return false;
      values.add(v);
      labels.add(l);
      total += math.max(v.width, l.width);
    }
    total += colGap * (columns.length - 1);
    if (total > C.width) return false;
    final bar = level <= 3;
    final barH = 6.0;
    final valueH = values.map((v) => v.height).reduce(math.max);
    final baseline = values.map((v) => v.baseline).reduce(math.max);
    final labelH = labels.map((l) => l.height).reduce(math.max);
    final blockH = valueH + LwGrid.gapTight + labelH;
    final top = C.top + head + LwGrid.gap;
    final bottom = bar ? C.bottom - barH - LwGrid.gap : C.bottom;
    if (top + blockH > bottom) return false;
    c.zone(c.bounds, s.open, description);
    final y = top + (bottom - top - blockH) / 2;
    var x = C.left;
    for (var i = 0; i < values.length; i++) {
      c.put(values[i], Offset(x, y + (baseline - values[i].baseline)));
      c.put(labels[i], Offset(x, y + valueH + LwGrid.gapTight));
      x += math.max(values[i].width, labels[i].width) + colGap;
    }
    if (bar) {
      c.bar(Rect.fromLTWH(C.left, C.bottom - barH, C.width, barH), s, dim);
    }
    c.description = description;
    return true;
  }

  bool _tasksNarrow(_Ctx c, LwTasksScene s, int level, String description) {
    final C = c.content;
    final dim = s.mood == LwMood.offline;
    final head = c.eyebrow(
      C.top,
      icon: _Icon.kanban,
      text: w.s.lwpTasks,
      ends: dim && level <= 1 ? _lastKnown(s.sinceMs) : null,
    );
    if (head == null) return false;
    final ink = dim ? c.p.dim(c.p.ink) : c.p.ink;
    final ink2 = dim ? c.p.dim(c.p.ink2) : c.p.ink2;
    final big = c.fit(
      _count(s.running),
      LwType.big,
      ink,
      maxWidth: C.width * 0.6,
      minSp: 24,
      ellipsis: false,
    );
    if (big == null) return false;
    // A figure never stands without its unit: beside it on its baseline,
    // else under it, else this plan does not fit.
    var unit = c.fit(
      w.s.lwpTasksInProgressUnit,
      LwType.line,
      ink2,
      maxWidth: C.width - big.width - LwGrid.gapTight * 2,
      ellipsis: false,
    );
    final unitBelow = unit == null;
    unit ??= c.fit(
      w.s.lwpTasksInProgressUnit,
      LwType.line,
      ink2,
      maxWidth: C.width,
      ellipsis: false,
    );
    if (unit == null) return false;
    final figureH = big.height + (unitBelow ? unit.height : 0);
    final lines = <LwTextBox>[];
    if (level <= 2) {
      final texts = [
        if (s.pending > 0) w.s.lwpTasksPendingCount(s.pending),
        if (s.attention > 0 && level <= 1)
          w.s.lwpTasksAttentionCount(s.attention),
      ];
      for (final t in texts) {
        final box = c.fit(
          t,
          LwType.line,
          ink2,
          maxWidth: C.width,
          ellipsis: false,
        );
        if (box == null) return false;
        lines.add(box);
      }
    }
    final bar = level == 0;
    const barH = 6.0;
    final top = C.top + head + LwGrid.gap;
    final bottom = bar ? C.bottom - barH - LwGrid.gap : C.bottom;
    final linesH =
        lines.fold(0.0, (h, b) => h + b.height) +
        (lines.isEmpty ? 0 : LwGrid.gap);
    if (top + figureH + linesH > bottom) return false;
    c.zone(c.bounds, s.open, description);
    c.put(big, Offset(C.left, top));
    if (unitBelow) {
      c.put(unit, Offset(C.left, top + big.height));
    } else {
      // The unit sits on the figure's baseline.
      c.put(
        unit,
        Offset(
          C.left + big.width + LwGrid.gapTight * 2,
          top + big.baseline - unit.baseline,
        ),
      );
    }
    var y = bottom - lines.fold(0.0, (h, b) => h + b.height);
    for (final line in lines) {
      c.put(line, Offset(C.left, y));
      y += line.height;
    }
    if (bar) {
      c.bar(Rect.fromLTWH(C.left, C.bottom - barH, C.width, barH), s, dim);
    }
    c.description = description;
    return true;
  }

  static String _count(int v) => v > 99 ? '99+' : '$v';

  // ------------------------------------------------------------------ New chat

  LwFrame newChat(LwNewChatScene s) {
    final plans = <(String, _Plan)>[];
    if (!span.oneRow) {
      for (var level = 0; level <= 5; level++) {
        plans.add(('new/$level', (c) => _newBoard(c, s, level)));
      }
    }
    for (var level = 0; level <= 3; level++) {
      plans.add(('new/strip/$level', (c) => _newStrip(c, s, level)));
    }
    return _run(plans);
  }

  LwTapZone _newZone(
    _Ctx c,
    Rect drawn,
    LwNewChatScene s,
    String target,
    String label,
  ) => LwTapZone(
    rect: LwTapZone.hit(drawn, c.bounds),
    kind: s.ready ? LwActionKind.newChat : LwActionKind.setup,
    label: label,
    instanceId: s.ready ? s.instanceId : null,
    target: s.ready ? target : null,
  );

  bool _newBoard(_Ctx c, LwNewChatScene s, int level) {
    final C = c.content;
    final plus = LwGrid.iconButtonLarge;
    final mic = level <= 2 ? LwGrid.iconButton : 0.0;
    final title = c.fit(
      w.s.lwpNewChat,
      LwType.title,
      c.p.ink,
      maxWidth: C.width,
      maxLines: 2,
      minSp: level >= 4 ? LwGrid.minSp : LwGrid.rowTitle,
      ellipsis: false,
    );
    if (level <= 4 && title == null) return false;
    final line = level == 0
        ? c.fit(
            s.ready ? w.s.lwpNewChatLine : w.s.lwpNewChatSetup,
            LwType.caption,
            c.p.ink2,
            maxWidth: C.width,
            maxLines: 2,
            ellipsis: false,
          )
        : null;
    if (level == 0 && line == null) return false;
    final blockH =
        (title?.height ?? 0) +
        (line == null ? 0 : LwGrid.gapTight + line.height);
    if (C.top + plus + LwGrid.gap + blockH > C.bottom) return false;
    if (mic > 0 && C.width < plus + mic + LwGrid.gap) return false;
    c.zones.add(_newZone(c, c.bounds, s, 'composer', w.s.lwpA11yNewChat));
    c.circle(
      Rect.fromLTWH(C.left, C.top, plus, plus),
      _Icon.plus,
      primary: true,
    );
    if (mic > 0) {
      final rect = Rect.fromLTWH(C.right - mic, C.top, mic, mic);
      c.circle(rect, _Icon.mic, primary: false);
      c.zones.add(_newZone(c, rect, s, 'voice', w.s.lwpA11yVoice));
    }
    if (title != null) {
      final y = C.bottom - blockH;
      c.put(title, Offset(C.left, y));
      if (line != null) {
        c.put(line, Offset(C.left, y + title.height + LwGrid.gapTight));
      }
    }
    c.description = w.s.lwpA11yNewChat;
    return true;
  }

  bool _newStrip(_Ctx c, LwNewChatScene s, int level) {
    final C = c.content;
    if (C.height < 24) return false;
    // Levels: the full button and the words in two lines; a smaller button
    // to give the words room; one line; the button alone.
    final plus = LwGrid.floor(
      math.min(level == 1 ? LwGrid.faceSmall : LwGrid.face, C.height),
    );
    final left = C.left + plus + LwGrid.gap;
    final width = C.right - left;
    if (width < 40) return false;
    final title = level <= 2
        ? c.fit(
            w.s.lwpNewChat,
            LwType.rowTitle,
            c.p.ink,
            maxWidth: width,
            maxLines: level <= 1 && C.height >= 40 ? 2 : 1,
            maxHeight: C.height,
            minSp: level == 0 ? LwGrid.minSp + 1 : LwGrid.minSp,
            ellipsis: false,
          )
        : null;
    if (level <= 2 && title == null) return false;
    c.zones.add(_newZone(c, c.bounds, s, 'composer', w.s.lwpA11yNewChat));
    c.circle(
      Rect.fromLTWH(C.left, C.top + (C.height - plus) / 2, plus, plus),
      _Icon.plus,
      primary: true,
    );
    if (title != null) {
      c.put(title, Offset(left, C.top + (C.height - title.height) / 2));
    }
    c.description = w.s.lwpA11yNewChat;
    return true;
  }
}

/// One attempt at a drawing: a canvas, the palette, the log, the zones.
class _Ctx {
  _Ctx(this.r, this.span, this.t)
    : p = r.palette,
      bounds = Offset.zero & r.sizeDp,
      content = contentOf(span, r.sizeDp) {
    canvas = Canvas(recorder);
  }

  /// The inner rect of a card: the same margin on four sides (a one-row
  /// card keeps less above and below).
  static Rect contentOf(LwSpan span, Size size) => span.oneRow
      ? Rect.fromLTRB(
          LwGrid.stripPadH,
          LwGrid.stripPadV,
          size.width - LwGrid.stripPadH,
          size.height - LwGrid.stripPadV,
        )
      : (Offset.zero & size).deflate(LwGrid.pad);

  final LwPaintRequest r;
  final LwSpan span;
  final LwTypesetter t;
  final LauncherWidgetPalette p;
  final Rect bounds;
  final Rect content;
  final recorder = ui.PictureRecorder();
  late final Canvas canvas;
  final log = LwPaintLog();
  final zones = <LwTapZone>[];
  String description = '';

  static const double buttonPad = 14;
  static const double buttonIcon = 16;
  static const double buttonIconGap = 8;
  static const double dotD = 8;
  static const double dotSmall = 4.5;
  static const double dotsWidth = dotSmall * 3 + 3 * 2;

  /// How far a ring reaches beyond its face, on every side.
  static const double ringReach = LwGrid.ringGap + LwGrid.ringStroke;

  LwFrame finish(String plan, int? validUntilMs) => LwFrame(
    sizeDp: r.sizeDp,
    picture: recorder.endRecording(),
    zones: List.unmodifiable(zones),
    description: description,
    log: log,
    plan: plan,
    validUntilMs: validUntilMs,
  );

  void discard() => recorder.endRecording().dispose();

  double get radius =>
      math.min(LwGrid.radius, math.min(bounds.width, bounds.height) / 2);

  RRect get cardRRect =>
      RRect.fromRectAndRadius(bounds, Radius.circular(radius));

  void card() {
    canvas.drawRRect(cardRRect, Paint()..color = p.card);
    canvas.drawRRect(cardRRect, Paint()..color = p.veil);
    canvas.drawRRect(
      cardRRect.deflate(LwGrid.hairline / 2),
      Paint()
        ..color = p.hair
        ..style = PaintingStyle.stroke
        ..strokeWidth = LwGrid.hairline,
    );
  }

  LwTextBox? fit(
    String text,
    LwType type,
    Color color, {
    required double maxWidth,
    double? maxHeight,
    int maxLines = 1,
    bool ellipsis = true,
    double? minSp,
  }) => t.fit(
    text,
    type,
    color: color,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    maxLines: maxLines,
    ellipsis: ellipsis,
    minSp: minSp,
  );

  void put(LwTextBox box, Offset at) => t.paint(canvas, box, at, log: log);

  void zone(Rect drawn, LwOpen open, String label) => zones.add(
    LwTapZone(
      rect: LwTapZone.hit(drawn, bounds),
      kind: open.kind,
      label: label,
      payload: open.payload,
      instanceId: open.instanceId,
      sessionId: open.sessionId,
    ),
  );

  void answer(Rect drawn, LwActionKind kind, LwNeed need, String label) =>
      zones.add(
        LwTapZone(
          rect: LwTapZone.hit(drawn, bounds),
          kind: kind,
          label: label,
          payload: need.answerPayload,
        ),
      );

  /// Icon, name and, at the end, a short note. Returns the height used.
  ///
  /// The name is the app's own word: whole or the widget is simplified.
  /// The note is whole too: the first of [ends] that fits beside the name
  /// (a long form, then a shorter one), or none.
  double? eyebrow(
    double y, {
    _Icon? icon,
    required String text,
    String? end,
    List<String>? ends,
    double? width,
  }) {
    final w = width ?? content.width;
    final iconD = icon == null
        ? 0.0
        : LwGrid.snap(14 * math.min(t.fontScale, 1.5));
    final iconSpace = icon == null ? 0.0 : iconD + LwGrid.gapTight * 2;
    final textBox = fit(
      text,
      LwType.eyebrow,
      p.ink2,
      maxWidth: w - iconSpace,
      ellipsis: false,
    );
    if (textBox == null) return null;
    LwTextBox? endBox;
    for (final candidate in [?end, ...?ends]) {
      endBox = fit(
        candidate,
        LwType.caption,
        p.ink3,
        maxWidth: w - iconSpace - textBox.width - LwGrid.gap,
        ellipsis: false,
      );
      if (endBox != null) break;
    }
    final h = math.max(iconD, math.max(textBox.height, endBox?.height ?? 0));
    if (icon != null) {
      this.icon(
        icon,
        Rect.fromLTWH(content.left, y + (h - iconD) / 2, iconD, iconD),
        p.ink2,
      );
    }
    put(
      textBox,
      Offset(content.left + iconSpace, y + (h - textBox.height) / 2),
    );
    if (endBox != null) {
      put(
        endBox,
        Offset(content.left + w - endBox.width, y + (h - endBox.height) / 2),
      );
    }
    return h;
  }

  void face(
    Rect box,
    LwFace face, {
    _Ring ring = _Ring.none,
    bool dim = false,
  }) {
    final avatar = r.avatars[face.profile];
    final identity =
        avatar?.fallback ?? BotFaceIdentity.resolve(profile: face.profile);
    final state = switch (ring) {
      _Ring.waits => BotFaceBitmapState.needsYou,
      _Ring.works => BotFaceBitmapState.working,
      _Ring.none => BotFaceBitmapState.idle,
    };
    canvas.save();
    if (dim) {
      canvas.saveLayer(
        box.inflate(8),
        Paint()
          ..color = const Color(
            0xFFFFFFFF,
          ).withValues(alpha: LauncherWidgetPalette.dimOpacity),
      );
    }
    canvas.translate(box.left, box.top);
    canvas.scale(box.width / 100);
    final faceSaveCount = canvas.getSaveCount();
    canvas.save();
    canvas.clipPath(Path()..addOval(const Rect.fromLTWH(0, 0, 100, 100)));
    var painted = false;
    try {
      painted =
          avatar?.paint(canvas, const Size.square(100), p.accent) ?? false;
    } catch (_) {
      // A cosmetic failure cannot prevent the widget from being published.
    } finally {
      canvas.restoreToCount(faceSaveCount);
    }
    if (!painted) {
      paintBotSphere(canvas, identity.sphere, sphereEyePose(state, 0));
    }
    if (dim) canvas.restore();
    canvas.restore();
    final ringRect = box.inflate(LwGrid.ringGap + LwGrid.ringStroke / 2);
    switch (ring) {
      case _Ring.waits:
        canvas.drawOval(
          ringRect,
          Paint()
            ..color = p.accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = LwGrid.ringStroke,
        );
      case _Ring.works:
        // A still arc: the ring of work, three quarters faint, one quarter ink.
        final faint = Paint()
          ..color = p.ink3.withValues(alpha: 0.4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5;
        canvas.drawOval(ringRect, faint);
        canvas.drawArc(
          ringRect,
          -math.pi / 2,
          math.pi / 2,
          false,
          Paint()
            ..color = p.ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..strokeCap = StrokeCap.round,
        );
      case _Ring.none:
        break;
    }
    log.add(
      LwPainted(
        'face',
        ring == _Ring.none ? box : ringRect.inflate(LwGrid.ringStroke / 2),
      ),
    );
  }

  /// An icon on a glass disc (the lead of a one-row card).
  void chip(Rect box, _Icon icon, {bool dim = false}) {
    canvas.drawOval(box, Paint()..color = p.veil);
    canvas.drawOval(
      box.deflate(0.5),
      Paint()
        ..color = p.hair
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    final d = LwGrid.snap(box.width * 0.5);
    this.icon(
      icon,
      Rect.fromCenter(center: box.center, width: d, height: d),
      dim ? p.dim(p.ink) : p.ink,
    );
  }

  /// A round button: the accent (primary) or glass (secondary) with an icon.
  void circle(Rect box, _Icon icon, {required bool primary}) {
    if (primary) {
      canvas.drawOval(box, Paint()..color = p.accent);
      _sheen(RRect.fromRectAndRadius(box, Radius.circular(box.width / 2)));
    } else {
      canvas.drawOval(box, Paint()..color = p.veil);
      canvas.drawOval(
        box.deflate(0.5),
        Paint()
          ..color = p.hair
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    final d = LwGrid.snap(box.width * 0.5);
    this.icon(
      icon,
      Rect.fromCenter(center: box.center, width: d, height: d),
      primary ? p.onAccent : p.ink,
      stroke: primary ? 2.4 : 2,
    );
    log.add(LwPainted('button', box));
  }

  /// The label of a pill, whole at its size, with ([icon]) or without the
  /// icon before it; null when it does not fit.
  LwTextBox? _buttonLabel(
    Rect rect,
    String label,
    Color color, {
    required bool icon,
  }) => fit(
    label,
    LwType.button,
    color,
    maxWidth:
        rect.width - buttonPad * 2 - (icon ? buttonIcon + buttonIconGap : 0),
    maxHeight: rect.height,
    ellipsis: false,
  );

  /// [label] fits the pill [rect] (with its icon when [icon]).
  bool buttonFits(Rect rect, String label, {bool icon = false}) =>
      _buttonLabel(rect, label, p.ink, icon: icon) != null;

  /// A pill with a centred label (and an icon before it). False when the
  /// label does not fit the pill even without the icon.
  bool button(Rect rect, String label, {required bool primary, _Icon? icon}) {
    final color = primary ? p.onAccent : p.ink;
    LwTextBox? box;
    var withIcon = icon != null;
    if (label.isNotEmpty) {
      box = _buttonLabel(rect, label, color, icon: withIcon);
      if (box == null && withIcon) {
        withIcon = false;
        box = _buttonLabel(rect, label, color, icon: false);
      }
      if (box == null) return false;
    }
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2));
    if (primary) {
      canvas.drawRRect(rr, Paint()..color = p.accent);
      _sheen(rr);
    } else {
      canvas.drawRRect(rr, Paint()..color = p.veil);
      canvas.drawRRect(
        rr.deflate(0.5),
        Paint()
          ..color = p.hair
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    final total =
        (box?.width ?? 0) +
        (withIcon ? buttonIcon + (box == null ? 0 : buttonIconGap) : 0);
    var x = rect.left + (rect.width - total) / 2;
    if (withIcon) {
      this.icon(
        icon!,
        Rect.fromLTWH(
          x,
          rect.center.dy - buttonIcon / 2,
          buttonIcon,
          buttonIcon,
        ),
        color,
        stroke: 2.4,
      );
      x += buttonIcon + (box == null ? 0 : buttonIconGap);
    }
    if (box != null) put(box, Offset(x, rect.center.dy - box.height / 2));
    log.add(LwPainted('button', rect));
    return true;
  }

  /// The gel's light: a soft white from the top-left, gone by a third.
  void _sheen(RRect rr) {
    final rect = rr.outerRect;
    canvas.drawRRect(
      rr,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topLeft,
          Offset(rect.left + rect.width * 0.38, rect.top + rect.height * 0.9),
          [
            const Color(0xFFFFFFFF).withValues(alpha: p.dark ? 0.2 : 0.45),
            const Color(0x00FFFFFF),
          ],
        ),
    );
  }

  void dot(Offset center, Color color) {
    canvas.drawCircle(center, dotD / 2, Paint()..color = color);
    log.add(
      LwPainted('dot', Rect.fromCircle(center: center, radius: dotD / 2)),
    );
  }

  /// Three still dots: the first in the accent's ink, the others fading.
  void dots(Offset left) {
    var x = left.dx + dotSmall / 2;
    for (final alpha in const [1.0, 0.55, 0.3]) {
      canvas.drawCircle(
        Offset(x, left.dy),
        dotSmall / 2,
        Paint()..color = p.accentText.withValues(alpha: alpha),
      );
      x += dotSmall + 3;
    }
    log.add(
      LwPainted(
        'dot',
        Rect.fromLTWH(left.dx, left.dy - dotSmall / 2, dotsWidth, dotSmall),
      ),
    );
  }

  void hairline(double y, double x1, double x2) {
    canvas.drawLine(
      Offset(x1, y),
      Offset(x2, y),
      Paint()
        ..color = p.hair
        ..strokeWidth = 1,
    );
  }

  void vline(double x, double y1, double y2) {
    canvas.drawLine(
      Offset(x, y1),
      Offset(x, y2),
      Paint()
        ..color = p.hair
        ..strokeWidth = 1,
    );
  }

  /// The three-part bar of the board: in progress (accent), waiting (ink),
  /// pending (hairline), each at least a dot wide when it counts.
  void bar(Rect rect, LwTasksScene s, bool dim) {
    final total = s.running + s.attention + s.pending;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
      Paint()..color = p.hair,
    );
    if (total == 0) return;
    const gap = 2.0;
    final parts = [
      (s.running, dim ? p.dim(p.accent) : p.accent),
      (s.attention, dim ? p.dim(p.ink2) : p.ink2),
    ];
    var x = rect.left;
    for (final (count, color) in parts) {
      if (count == 0) continue;
      final width = math.max(
        rect.height,
        (rect.width - gap * 2) * count / total,
      );
      final seg = Rect.fromLTWH(
        x,
        rect.top,
        math.min(width, rect.right - x),
        rect.height,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(seg, Radius.circular(rect.height / 2)),
        Paint()..color = color,
      );
      x += seg.width + gap;
    }
    log.add(LwPainted('bar', rect));
  }

  /// An icon alone, centred: the drawing of last resort.
  void minimal(_Icon icon) {
    final d = LwGrid.snap(
      math.min(24, math.min(bounds.width, bounds.height) * 0.5),
    );
    this.icon(
      icon,
      Rect.fromCenter(center: bounds.center, width: d, height: d),
      p.ink2,
    );
    zone(bounds, const LwOpen.app(), r.words.s.lwpA11yOpenApp);
    description = r.words.s.lwpA11yOpenApp;
  }

  /// Stroke icons on a 24-unit grid, one weight (2 of 24).
  void icon(_Icon icon, Rect box, Color color, {double stroke = 2}) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.save();
    canvas.translate(box.left, box.top);
    canvas.scale(box.width / 24, box.height / 24);
    final path = Path();
    switch (icon) {
      case _Icon.zap:
        path
          ..moveTo(13, 2)
          ..lineTo(3.5, 13.5)
          ..lineTo(11, 13.5)
          ..lineTo(11, 22)
          ..lineTo(20.5, 10.5)
          ..lineTo(13, 10.5)
          ..close();
      case _Icon.clock:
        path
          ..addOval(const Rect.fromLTWH(2, 2, 20, 20))
          ..moveTo(12, 6)
          ..lineTo(12, 12)
          ..lineTo(16, 14);
      case _Icon.msg:
        path
          ..moveTo(7.9, 20)
          ..arcToPoint(
            const Offset(4, 16.1),
            radius: const Radius.circular(9),
            largeArc: true,
            clockwise: false,
          )
          ..lineTo(2, 22)
          ..close();
      case _Icon.kanban:
        path
          ..moveTo(6, 5)
          ..lineTo(6, 16)
          ..moveTo(12, 5)
          ..lineTo(12, 11)
          ..moveTo(18, 5)
          ..lineTo(18, 19);
      case _Icon.plus:
        path
          ..moveTo(5, 12)
          ..lineTo(19, 12)
          ..moveTo(12, 5)
          ..lineTo(12, 19);
      case _Icon.mic:
        path
          ..addRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTWH(9, 2, 6, 13),
              const Radius.circular(3),
            ),
          )
          ..moveTo(5, 10)
          ..lineTo(5, 12)
          ..arcToPoint(
            const Offset(19, 12),
            radius: const Radius.circular(7),
            clockwise: false,
          )
          ..lineTo(19, 10)
          ..moveTo(12, 19)
          ..lineTo(12, 22);
      case _Icon.check:
        path
          ..moveTo(20, 6)
          ..lineTo(9, 17)
          ..lineTo(4, 12);
      case _Icon.cross:
        path
          ..moveTo(18, 6)
          ..lineTo(6, 18)
          ..moveTo(6, 6)
          ..lineTo(18, 18);
      case _Icon.wifiOff:
        for (final radius in const [13.0, 8.5, 4.5]) {
          path.addArc(
            Rect.fromCircle(center: const Offset(12, 20), radius: radius),
            -math.pi * 0.78,
            math.pi * 0.56,
          );
        }
        path
          ..moveTo(2, 2)
          ..lineTo(22, 22);
        canvas.drawCircle(const Offset(12, 20), 1.2, Paint()..color = color);
    }
    canvas.drawPath(path, paint);
    canvas.restore();
    log.add(LwPainted('icon', box));
  }
}
