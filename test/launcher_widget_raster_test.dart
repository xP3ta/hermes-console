// The pictures of the launcher widgets never overflow, never collide, keep
// one margin on four sides, and their tap zones are the rects they drew.
//
// The matrix: every subject x every state x three real sizes of every span
// x two fonts x three system font scales x five languages (wide and tall
// scripts among them) x data made to break a layout. Each drawing is
// checked from its paint log: every text was measured and fits its box,
// nothing leaves the card, no two things share a place.
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_geometry.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_painter.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_scene.dart';
import 'package:hermes_android/core/home/launcher/launcher_widget_text.dart';

import 'launcher_widget_fixtures.dart';

const _eps = 0.51;

bool _overlap(ui.Rect a, ui.Rect b) {
  final i = a.intersect(b);
  return i.width > _eps && i.height > _eps;
}

bool _inside(ui.Rect inner, ui.Rect outer) =>
    inner.left >= outer.left - _eps &&
    inner.top >= outer.top - _eps &&
    inner.right <= outer.right + _eps &&
    inner.bottom <= outer.bottom + _eps;

/// Proves one drawing well formed.
void expectWellFormed(LwFrame frame, String label) {
  final bounds = ui.Offset.zero & frame.sizeDp;
  final span = LwSpan.of(frame.sizeDp);
  final content = span.oneRow
      ? ui.Rect.fromLTRB(
          LwGrid.stripPadH,
          LwGrid.stripPadV,
          frame.sizeDp.width - LwGrid.stripPadH,
          frame.sizeDp.height - LwGrid.stripPadV,
        )
      : bounds.deflate(LwGrid.pad);
  final items = frame.log.items;
  expect(items, isNotEmpty, reason: '$label drew nothing');
  final texts = items.where((i) => i.kind == 'text').toList();
  final buttons = items.where((i) => i.kind == 'button').toList();
  final solids = items
      .where((i) => i.kind == 'face' || i.kind == 'bar')
      .toList();
  for (final item in items) {
    expect(
      _inside(item.rect, bounds),
      isTrue,
      reason: '$label: $item leaves the card',
    );
    if (item.kind == 'text') {
      // The same margin on four sides: every text inside the content rect.
      expect(
        _inside(item.rect, content),
        isTrue,
        reason: '$label: $item leaves the margins',
      );
      expect(item.rect.width, greaterThan(0));
      expect(item.rect.height, greaterThan(0));
    }
  }
  for (var i = 0; i < texts.length; i++) {
    for (var j = i + 1; j < texts.length; j++) {
      expect(
        _overlap(texts[i].rect, texts[j].rect),
        isFalse,
        reason: '$label: ${texts[i]} over ${texts[j]}',
      );
    }
    for (final solid in solids) {
      expect(
        _overlap(texts[i].rect, solid.rect),
        isFalse,
        reason: '$label: ${texts[i]} over $solid',
      );
    }
    for (final button in buttons) {
      // A label lies inside its button or clear of it.
      if (_overlap(texts[i].rect, button.rect)) {
        expect(
          _inside(texts[i].rect, button.rect),
          isTrue,
          reason: '$label: ${texts[i]} half over $button',
        );
      }
    }
  }
  for (var i = 0; i < solids.length; i++) {
    for (var j = i + 1; j < solids.length; j++) {
      expect(
        _overlap(solids[i].rect, solids[j].rect),
        isFalse,
        reason: '$label: ${solids[i]} over ${solids[j]}',
      );
    }
    for (final button in buttons) {
      expect(
        _overlap(solids[i].rect, button.rect),
        isFalse,
        reason: '$label: ${solids[i]} over $button',
      );
    }
  }
  for (var i = 0; i < buttons.length; i++) {
    for (var j = i + 1; j < buttons.length; j++) {
      expect(
        _overlap(buttons[i].rect, buttons[j].rect),
        isFalse,
        reason: '$label: ${buttons[i]} over ${buttons[j]}',
      );
    }
  }
  // A screen reader hears the content, never "image".
  expect(
    frame.description.trim(),
    isNotEmpty,
    reason: '$label has no description',
  );
  expect(frame.description.toLowerCase(), isNot(contains('image')));
  // Tap zones: inside the card, never smaller than the tap minimum (or the
  // card), each with words.
  expect(frame.zones, isNotEmpty, reason: '$label has nothing to tap');
  for (final zone in frame.zones) {
    expect(
      _inside(zone.rect, bounds),
      isTrue,
      reason: '$label: zone ${zone.kind} leaves the card',
    );
    expect(
      zone.rect.width,
      greaterThanOrEqualTo(_minOf(LwGrid.tap, bounds.width) - _eps),
      reason: '$label: zone ${zone.kind} too narrow',
    );
    expect(
      zone.rect.height,
      greaterThanOrEqualTo(_minOf(LwGrid.tap, bounds.height) - _eps),
      reason: '$label: zone ${zone.kind} too low',
    );
    expect(
      zone.label.trim(),
      isNotEmpty,
      reason: '$label: zone ${zone.kind} is mute',
    );
  }
  // The first zone is the card itself: the one under all the others.
  expect(
    frame.zones.first.rect,
    bounds,
    reason: '$label: the card is not the first zone',
  );
  // The targets over it never overlap: a finger lands on one of them.
  final targets = frame.zones.skip(1).toList();
  for (var i = 0; i < targets.length; i++) {
    for (var j = i + 1; j < targets.length; j++) {
      expect(
        _overlap(targets[i].rect, targets[j].rect),
        isFalse,
        reason: '$label: zone ${targets[i].kind} over ${targets[j].kind}',
      );
    }
  }
  // Allow / Deny: the zone is the very rect the button was painted with
  // (grown to the tap minimum when the pill is lower than it, same centre).
  for (final zone in frame.zones.where(
    (z) => z.kind == LwActionKind.approve || z.kind == LwActionKind.deny,
  )) {
    final drawn = buttons
        .where((b) => (b.rect.center - zone.rect.center).distance < _eps)
        .toList();
    expect(
      drawn,
      hasLength(1),
      reason: '$label: zone ${zone.kind} has no button under it',
    );
    expect(
      _inside(drawn.single.rect, zone.rect),
      isTrue,
      reason: '$label: button sticks out of its zone',
    );
    expect(
      (drawn.single.rect.width - zone.rect.width).abs() < _eps ||
          zone.rect.width == LwGrid.tap,
      isTrue,
    );
  }
}

double _minOf(double a, double b) => a < b ? a : b;

void main() {
  setUpAll(lwLoadFonts);

  group('matrix: every subject, state, size, font, scale, language, data', () {
    for (final subject in LwSubject.values) {
      test(subject.key, () {
        var drawn = 0;
        final plans = <String>{};
        for (final mood in lwMoodsOf[subject]!) {
          for (final data in LwData.all) {
            final scene = lwScene(subject, mood, data);
            for (final span in lwSpansOf[subject]!) {
              for (final size in lwSizes[span]!) {
                for (final theme in [lwThemes[0], lwThemes[2]]) {
                  for (final fontScale in const [1.0, 1.3, 2.0]) {
                    for (final locale in lwLocales) {
                      // Hostile data in every language would only repeat
                      // itself: the plain case covers the words, the
                      // others the data.
                      if (data.id != 'plain' &&
                          locale != 'es' &&
                          locale != 'ja') {
                        continue;
                      }
                      final label =
                          '${subject.key}/$mood/${data.id}/${span.code}/${size.width.round()}x${size.height.round()}/${theme.id}/x$fontScale/$locale';
                      final frame = paintLauncherWidget(
                        LwPaintRequest(
                          subject: subject,
                          scene: scene,
                          sizeDp: size,
                          palette: theme.palette,
                          words: lwWords(locale, use24h: data.use24h),
                          fontScale: fontScale,
                          instanceId: 'home',
                        ),
                      );
                      try {
                        expectWellFormed(frame, label);
                        plans.add(frame.plan);
                        drawn++;
                      } finally {
                        frame.dispose();
                      }
                    }
                  }
                }
              }
            }
          }
        }
        expect(drawn, greaterThan(100));
        // The ladder was really climbed: more than one plan served.
        expect(plans.length, greaterThan(1), reason: plans.toString());
      });
    }
  });

  group('rules', () {
    test(
      'a text that does not fit is shrunk to the minimum, then cut, then refused',
      () {
        final t = LwTypesetter(
          fontFamily: 'Inter',
          fontScale: 1,
          textDirection: ui.TextDirection.ltr,
        );
        const long = 'Una conversación con un título extraordinariamente largo';
        final wide = t.fit(
          long,
          LwType.title,
          color: const ui.Color(0xFF000000),
          maxWidth: 600,
        )!;
        expect(wide.sp, LwType.title.sp);
        expect(wide.truncated, isFalse);
        // Asked to shrink: down to the minimum, then cut.
        final narrow = t.fit(
          long,
          LwType.title,
          color: const ui.Color(0xFF000000),
          maxWidth: 120,
          minSp: LwGrid.minSp,
        )!;
        expect(narrow.sp, LwGrid.minSp);
        expect(narrow.truncated, isTrue);
        expect(narrow.width, lessThanOrEqualTo(120));
        // By default a text keeps its size and is cut (the rows of a list
        // keep one size).
        final kept = t.fit(
          long,
          LwType.title,
          color: const ui.Color(0xFF000000),
          maxWidth: 120,
        )!;
        expect(kept.sp, LwType.title.sp);
        expect(kept.shrunk, isFalse);
        expect(kept.truncated, isTrue);
        expect(
          t.fit(
            long,
            LwType.title,
            color: const ui.Color(0xFF000000),
            maxWidth: 120,
            ellipsis: false,
            minSp: LwGrid.minSp,
          ),
          isNull,
        );
        expect(
          t.fit(
            'Permitir',
            LwType.button,
            color: const ui.Color(0xFF000000),
            maxWidth: 30,
            ellipsis: false,
          ),
          isNull,
        );
      },
    );

    test('a cut keeps at least three ems before its ellipsis', () {
      final t = LwTypesetter(
        fontFamily: 'Inter',
        fontScale: 1,
        textDirection: ui.TextDirection.ltr,
      );
      // "Inf…" says nothing: refused, so the plan is simplified instead.
      expect(
        t.fit(
          'Informe semanal',
          LwType.rowTitle,
          color: const ui.Color(0xFF000000),
          maxWidth: 40,
        ),
        isNull,
      );
      final cut = t.fit(
        'Informe semanal',
        LwType.rowTitle,
        color: const ui.Color(0xFF000000),
        maxWidth: 80,
      )!;
      expect(cut.truncated, isTrue);
      expect(cut.width, greaterThanOrEqualTo(3 * LwGrid.rowTitle));
    });

    test('a word is never broken across lines', () {
      final t = LwTypesetter(
        fontFamily: 'Inter',
        fontScale: 1,
        textDirection: ui.TextDirection.ltr,
      );
      const black = ui.Color(0xFF000000);
      final word = t.fit(
        'conversación',
        LwType.rowTitle,
        color: black,
        maxWidth: 1000,
      )!;
      // Narrower than its longest word at its size: not "conver-/sación".
      expect(
        t.fit(
          'Nueva conversación',
          LwType.rowTitle,
          color: black,
          maxWidth: word.width - 4,
          maxLines: 2,
          ellipsis: false,
        ),
        isNull,
      );
      // Allowed to shrink, it shrinks until the word fits on its line.
      final shrunk = t.fit(
        'Nueva conversación',
        LwType.rowTitle,
        color: black,
        maxWidth: word.width - 4,
        maxLines: 2,
        ellipsis: false,
        minSp: LwGrid.minSp,
      )!;
      expect(shrunk.shrunk, isTrue);
      expect(shrunk.painter.computeLineMetrics(), hasLength(2));
      // Scripts without spaces wrap anywhere, as they should.
      expect(
        t.fit(
          '新しい会話を始めましょう',
          LwType.rowTitle,
          color: black,
          maxWidth: 110,
          maxLines: 3,
          ellipsis: false,
        ),
        isNotNull,
      );
    });

    test("the app's own words are whole or absent, never cut", () {
      for (final subject in LwSubject.values) {
        for (final mood in lwMoodsOf[subject]!) {
          for (final span in lwSpansOf[subject]!) {
            for (final size in lwSizes[span]!) {
              for (final fontScale in const [1.0, 2.0]) {
                final words = lwWords('de');
                final frame = paintLauncherWidget(
                  LwPaintRequest(
                    subject: subject,
                    scene: lwScene(subject, mood, LwData.plain),
                    sizeDp: size,
                    palette: lwThemes[0].palette,
                    words: words,
                    fontScale: fontScale,
                  ),
                );
                final own = {
                  words.s.lwpAhora,
                  words.s.lwpChats,
                  words.s.lwpCron,
                  words.s.lwpTasks,
                  words.s.lwpNewChat,
                  words.s.lwpNeedsPermission,
                  words.s.lwpAsksYou,
                  words.s.lwpWorking,
                  words.s.lwpCalmTitle,
                  words.s.lwpOffline,
                  words.s.lwpSetupTitle,
                  words.s.lwpSetupLine,
                  words.s.lwpAllow,
                  words.s.lwpDeny,
                  words.s.lwpChatsEmptyTitle,
                  words.s.lwpCronEmptyTitle,
                  words.s.lwpTasksEmptyTitle,
                  words.s.lwpTasksRunning,
                  words.s.lwpTasksPending,
                  words.s.lwpTasksAttention,
                }.map((w) => w.toUpperCase()).toSet();
                for (final text in frame.log.texts) {
                  if (own.contains((text.text ?? '').toUpperCase())) {
                    expect(
                      text.truncated,
                      isFalse,
                      reason:
                          '${subject.key}/$mood/${size.width}x${size.height}/x$fontScale: $text',
                    );
                  }
                }
                frame.dispose();
              }
            }
          }
        }
      }
    });

    test('the rows of a list keep one size', () {
      for (final data in LwData.all) {
        for (final fontScale in const [1.0, 1.3, 2.0]) {
          for (final size in [
            ...lwSizes[LwSpan.fourByTwo]!,
            ...lwSizes[LwSpan.fourByFour]!,
          ]) {
            final frame = paintLauncherWidget(
              LwPaintRequest(
                subject: LwSubject.chats,
                scene: lwScene(LwSubject.chats, 'rows', data),
                sizeDp: size,
                palette: lwThemes[0].palette,
                words: lwWords('es'),
                fontScale: fontScale,
              ),
            );
            for (final text in frame.log.texts) {
              expect(
                text.shrunk,
                isFalse,
                reason:
                    '${data.id}/${size.width}x${size.height}/x$fontScale: $text',
              );
            }
            frame.dispose();
          }
        }
      }
    });

    test('what a card is for survives every simplification', () {
      for (final fontScale in const [1.0, 1.3, 2.0]) {
        for (final span in const [LwSpan.twoByTwo, LwSpan.fourByTwo]) {
          for (final size in lwSizes[span]!) {
            final label = '${size.width}x${size.height}/x$fontScale';
            // Cron: when the next job runs.
            final cron = paintLauncherWidget(
              LwPaintRequest(
                subject: LwSubject.cron,
                scene: lwScene(LwSubject.cron, 'next', LwData.plain),
                sizeDp: size,
                palette: lwThemes[0].palette,
                words: lwWords('es'),
                fontScale: fontScale,
              ),
            );
            expect(
              cron.log.texts
                  .map((t) => t.text ?? '')
                  .any((t) => t.contains('18:30')),
              isTrue,
              reason: 'cron $label ${cron.plan}',
            );
            cron.dispose();
            // Tasks: a figure is never drawn without its unit.
            final tasks = paintLauncherWidget(
              LwPaintRequest(
                subject: LwSubject.tasks,
                scene: lwScene(LwSubject.tasks, 'counts', LwData.plain),
                sizeDp: size,
                palette: lwThemes[0].palette,
                words: lwWords('es'),
                fontScale: fontScale,
              ),
            );
            final texts = tasks.log.texts
                .map((t) => (t.text ?? '').toLowerCase())
                .toList();
            if (texts.contains('3')) {
              expect(
                texts.any((t) => t.contains('en curso')),
                isTrue,
                reason: 'tasks $label ${tasks.plan}',
              );
            }
            tasks.dispose();
          }
        }
      }
    });

    test('sp become dp through the system font scale', () {
      final one =
          LwTypesetter(
            fontFamily: 'Inter',
            fontScale: 1,
            textDirection: ui.TextDirection.ltr,
          ).fit(
            'Ahora',
            LwType.line,
            color: const ui.Color(0xFF000000),
            maxWidth: 400,
          )!;
      final two =
          LwTypesetter(
            fontFamily: 'Inter',
            fontScale: 2,
            textDirection: ui.TextDirection.ltr,
          ).fit(
            'Ahora',
            LwType.line,
            color: const ui.Color(0xFF000000),
            maxWidth: 400,
          )!;
      expect(two.height, closeTo(one.height * 2, 1));
    });

    test(
      'the plan ladder: a 2x2 at twice the font size keeps its buttons and loses the line',
      () {
        final scene = lwScene(LwSubject.ahora, 'need', LwData.plain);
        final full = paintLauncherWidget(
          LwPaintRequest(
            subject: LwSubject.ahora,
            scene: scene,
            sizeDp: const ui.Size(320, 170),
            palette: lwThemes[0].palette,
            words: lwWords('es'),
            fontScale: 1,
          ),
        );
        final tight = paintLauncherWidget(
          LwPaintRequest(
            subject: LwSubject.ahora,
            scene: scene,
            sizeDp: const ui.Size(140, 140),
            palette: lwThemes[0].palette,
            words: lwWords('es'),
            fontScale: 2,
          ),
        );
        expect(full.plan, 'need/0');
        expect(
          full.log.texts.map((t) => t.text),
          contains('Ejecutar un comando en tu equipo'),
        );
        expect(tight.plan, isNot('need/0'));
        expect(
          tight.zones.map((z) => z.kind),
          containsAll([LwActionKind.approve, LwActionKind.deny]),
        );
        full.dispose();
        tight.dispose();
      },
    );

    test('a figure and its unit share a baseline', () {
      final frame = paintLauncherWidget(
        LwPaintRequest(
          subject: LwSubject.tasks,
          scene: lwScene(LwSubject.tasks, 'counts', LwData.plain),
          sizeDp: const ui.Size(160, 170),
          palette: lwThemes[0].palette,
          words: lwWords('es'),
          fontScale: 1,
        ),
      );
      final texts = frame.log.texts.toList();
      final big = texts.firstWhere((t) => t.text == '3');
      final unit = texts.firstWhere((t) => t.text == 'en curso');
      // Both boxes end on the same line within a pixel: their baselines meet.
      final t = LwTypesetter(
        fontFamily: 'Inter',
        fontScale: 1,
        textDirection: ui.TextDirection.ltr,
      );
      final bigBox = t.fit(
        '3',
        LwType.big,
        color: const ui.Color(0xFF000000),
        maxWidth: 200,
      )!;
      final unitBox = t.fit(
        'en curso',
        LwType.line,
        color: const ui.Color(0xFF000000),
        maxWidth: 200,
      )!;
      expect(
        big.rect.top + bigBox.baseline,
        closeTo(unit.rect.top + unitBox.baseline, 0.6),
      );
      frame.dispose();
    });

    test('tap zones are the painted rects, from one computation', () {
      final drawn = const ui.Rect.fromLTWH(16, 110, 130, 44);
      final bounds = const ui.Rect.fromLTWH(0, 0, 320, 170);
      final hit = LwTapZone.hit(drawn, bounds);
      expect(hit.width, drawn.width);
      expect(hit.height, LwGrid.tap);
      expect(hit.center, drawn.center);
      final edge = LwTapZone.hit(
        const ui.Rect.fromLTWH(300, 150, 20, 20),
        bounds,
      );
      expect(edge.right, lessThanOrEqualTo(bounds.right));
      expect(edge.bottom, lessThanOrEqualTo(bounds.bottom));
      expect(edge.width, LwGrid.tap);
    });

    test('spans from real sizes', () {
      expect(LwSpan.of(const ui.Size(160, 72)), LwSpan.twoByOne);
      expect(LwSpan.of(const ui.Size(320, 100)), LwSpan.fourByOne);
      expect(LwSpan.of(const ui.Size(160, 170)), LwSpan.twoByTwo);
      expect(LwSpan.of(const ui.Size(320, 170)), LwSpan.fourByTwo);
      expect(LwSpan.of(const ui.Size(320, 360)), LwSpan.fourByFour);
    });
  });

  group('privacy and words', () {
    test(
      'a hidden request shows no command, in the picture or to a reader',
      () {
        // The request's text is null when the owner hides sensitive content;
        // the chat's title stands in, as the native widget already did.
        final scene =
            lwScene(LwSubject.ahora, 'need', LwData.bare) as LwAhoraScene;
        expect(scene.needs.single.what, '·');
        final frame = paintLauncherWidget(
          LwPaintRequest(
            subject: LwSubject.ahora,
            scene: scene,
            sizeDp: const ui.Size(320, 170),
            palette: lwThemes[0].palette,
            words: lwWords('es'),
            fontScale: 1,
          ),
        );
        expect(
          frame.log.texts.map((t) => t.text),
          isNot(contains(contains('rm -rf'))),
        );
        expect(frame.description, 'H necesita tu permiso: ·');
        frame.dispose();
        final hostile =
            lwScene(LwSubject.ahora, 'need', LwData.hostile) as LwAhoraScene;
        final shown = paintLauncherWidget(
          LwPaintRequest(
            subject: LwSubject.ahora,
            scene: hostile,
            sizeDp: const ui.Size(320, 170),
            palette: lwThemes[0].palette,
            words: lwWords('es'),
            fontScale: 1,
          ),
        );
        // What the app published is what is drawn: no more, no less.
        expect(
          shown.log.texts
              .map((t) => t.text)
              .any((t) => (t ?? '').startsWith('rm -rf')),
          isTrue,
        );
        shown.dispose();
      },
    );

    test('a chat line hidden by the owner stays hidden', () {
      final scene =
          lwScene(LwSubject.chats, 'rows', LwData.plain) as LwChatsScene;
      final hidden = scene.rows.firstWhere(
        (r) => r.title == 'Presupuesto de casa',
      );
      expect(hidden.line, isNull);
    });

    test('the description says the content in the language asked', () {
      final en = paintLauncherWidget(
        LwPaintRequest(
          subject: LwSubject.ahora,
          scene: lwScene(LwSubject.ahora, 'need', LwData.plain),
          sizeDp: const ui.Size(320, 170),
          palette: lwThemes[0].palette,
          words: lwWords('en'),
          fontScale: 1,
        ),
      );
      expect(
        en.description,
        'Nova needs your permission: Ejecutar un comando en tu equipo',
      );
      expect(
        en.zones.map((z) => z.label),
        containsAll(['Allow Nova', 'Deny the request from Nova']),
      );
      en.dispose();
      final cron = paintLauncherWidget(
        LwPaintRequest(
          subject: LwSubject.cron,
          scene: lwScene(LwSubject.cron, 'next', LwData.plain),
          sizeDp: const ui.Size(160, 170),
          palette: lwThemes[0].palette,
          words: lwWords('es'),
          fontScale: 1,
        ),
      );
      expect(
        cron.description,
        'Próxima tarea programada: Resumen diario, Hoy · 18:30',
      );
      expect(cron.log.texts.map((t) => t.text), contains('18:30'));
      cron.dispose();
    });

    test('a picture only carries absolute times: nothing in it ages', () {
      for (final subject in LwSubject.values) {
        for (final mood in lwMoodsOf[subject]!) {
          final frame = paintLauncherWidget(
            LwPaintRequest(
              subject: subject,
              scene: lwScene(subject, mood, LwData.plain),
              sizeDp: const ui.Size(320, 170),
              palette: lwThemes[0].palette,
              words: lwWords('es'),
              fontScale: 1,
            ),
          );
          for (final text in frame.log.texts) {
            expect(
              text.text,
              isNot(matches(RegExp(r'hace \d|en \d+ (h|min)'))),
              reason: '${subject.key}/$mood',
            );
          }
          frame.dispose();
        }
      }
    });

    test(
      'old data says since when and dims; a picture expires with its data',
      () {
        final frame = paintLauncherWidget(
          LwPaintRequest(
            subject: LwSubject.ahora,
            scene: lwScene(LwSubject.ahora, 'offline', LwData.plain),
            sizeDp: const ui.Size(320, 170),
            palette: lwThemes[0].palette,
            words: lwWords('es'),
            fontScale: 1,
          ),
        );
        expect(
          frame.log.texts.map((t) => t.text),
          containsAll(['SIN CONEXIÓN', 'desde las 9:59', 'Casa no responde']),
        );
        expect(frame.validUntilMs, isNotNull);
        frame.dispose();
        final fresh = paintLauncherWidget(
          LwPaintRequest(
            subject: LwSubject.chats,
            scene: lwScene(LwSubject.chats, 'rows', LwData.plain),
            sizeDp: const ui.Size(320, 170),
            palette: lwThemes[0].palette,
            words: lwWords('es'),
            fontScale: 1,
          ),
        );
        expect(fresh.validUntilMs, lwMinutesAgo(1) + lwStaleAfterMs + 1);
        fresh.dispose();
      },
    );
  });
}
