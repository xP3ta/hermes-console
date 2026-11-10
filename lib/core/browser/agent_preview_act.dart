import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'agent_browser_bridge.dart';
import 'hermes_preview_engine.g.dart';

/// Port of Hermes Desktop's `apps/desktop/src/app/chat/right-rail/
/// preview-act.ts` (MIT, Nous Research) on the path Desktop itself takes when
/// a pane has no real-input channel: the injected engine both acts (with
/// synthetic DOM events) and re-reads the page in one trip
/// (`buildScriptedScript`). Android's WebView has no `sendInputEvent`, so the
/// real-input path (`driveAction`, `driveScroll`) has no counterpart here.
///
/// The engine and the overlay are Desktop's own sources
/// (`lib/preview-act/act-in-page.ts` `actEngineSource()`,
/// `watch-in-page.ts` `watchInPage`), generated into
/// `hermes_preview_engine.g.dart` by `tool/browser/generate_preview_engine.sh`.
/// The script templates below are copied verbatim from `preview-act.ts`.

/// `preview-act.ts` `NOTHING_OPEN`.
const String agentPreviewNothingOpen =
    'No live page is open in the in-app browser — open one with open_preview '
    'first.';

/// `preview-act.ts` `runJson`'s answer for a trip with no usable result;
/// also what the agent gets when the WebView itself failed, so a plugin's
/// technical text never reaches the model.
const String agentPreviewNoAnswer = 'The page did not answer the action.';

/// `preview-act.ts` `NAVIGATED`.
const String agentPreviewNavigated =
    'The page stopped answering right after — it is probably navigating. Call '
    'elements to see where you landed.';

/// `preview-act.ts` `SETTLE_MS`.
const int agentPreviewSettleMs = 220;

/// `preview-act.ts` `ACT_TIMEOUT_MS`.
const Duration agentPreviewActTimeout = Duration(milliseconds: 8000);

/// Desktop's `previewAct` handler turns the request params into the engine's
/// action (`server-requests.ts`); absent fields stay absent.
Map<String, Object?> agentPreviewActAction(Map<String, dynamic> p) {
  final kind = p['action'];
  return {
    'allowShortcut': p['allow_shortcut'] == true,
    'amount': ?p['amount'],
    'key': ?p['key'],
    'kind': kind is String ? kind : '',
    'max': ?p['max'],
    'ref': ?p['ref'],
    'selector': ?p['selector'],
    'submit': ?p['submit'],
    'text': ?p['text'],
    'to': ?p['to'],
  };
}

/// Desktop's injectable sources, as bundled.
class AgentPreviewEngineSource {
  const AgentPreviewEngineSource({
    required this.engine,
    required this.watch,
    required this.watchTag,
  });

  /// `actEngineSource()`: `function (doc, holder, action)`.
  final String engine;

  /// `watchInPage.toString()`.
  final String watch;

  /// `WATCH_TAG`: djb2 of [watch].
  final int watchTag;
}

/// Runs one script in the page and returns what the WebView hands back.
typedef AgentPageScript = Future<Object?> Function(String script);

sealed class _Trip {
  const _Trip();
}

final class _Answered extends _Trip {
  const _Answered(this.result);
  final Map<String, Object?> result;
}

final class _Failed extends _Trip {
  const _Failed(this.error);
  final String error;
}

final class _Silent extends _Trip {
  const _Silent();
}

/// Desktop's act pipeline for one page.
class AgentPreviewActEngine {
  AgentPreviewActEngine(
    this._load, {
    this.pollEvery = const Duration(milliseconds: 50),
    this.timeout = agentPreviewActTimeout,
  });

  factory AgentPreviewActEngine.bundled() =>
      AgentPreviewActEngine(() async => hermesPreviewEngine);

  final Future<AgentPreviewEngineSource> Function() _load;
  final Duration pollEvery;
  final Duration timeout;
  Future<AgentPreviewEngineSource>? _source;
  final math.Random _random = math.Random.secure();

  Future<AgentPreviewEngineSource> get _engine => _source ??= _load();

  /// `actOnActivePreview` without a real-input channel.
  Future<Map<String, Object?>> act(
    AgentBrowserPage page,
    Map<String, Object?> action, {
    bool Function()? isOpen,
  }) async {
    final kind = action['kind'] as String? ?? '';
    switch (kind) {
      case 'back':
        page.goBack();
      case 'forward':
        page.goForward();
      case 'reload':
        page.reload();
    }
    if (kind == 'back' || kind == 'forward' || kind == 'reload') {
      // Navigation is fire-and-forget through the webview; the new document
      // has its own refs, so the agent has to re-inventory either way.
      return {
        'acted': kind,
        'note': 'Page is loading — call elements to see what is on it.',
        'success': true,
      };
    }
    final source = await _engine;
    // Annotation, not interaction: nothing is clicked, nothing settles, and
    // the page is not re-read.
    if (const {'pin', 'unpin', 'hold', 'strobe'}.contains(kind)) {
      final label = action['text'] as String? ?? '';
      final mark = switch (kind) {
        'hold' => buildHoldScript(source),
        'strobe' => buildStrobeScript(source),
        'pin' => buildPinScript(source, action, label),
        _ => buildUnpinScript(source, action),
      };
      final trip = await _runJson(page.runScript, mark, isOpen);
      return switch (trip) {
        _Failed(:final error) => {'error': error, 'success': false},
        _Answered(:final result) => result,
        _Silent() => {
          'acted': kind,
          'note': agentPreviewNavigated,
          'success': true,
        },
      };
    }
    final settle = kind == 'elements' ? 0 : agentPreviewSettleMs;
    final scripted = await _runJson(
      page.runScript,
      buildScriptedScript(source, action, settle),
      isOpen,
    );
    // The action almost certainly landed: a page that stops answering right
    // after a click is one that navigated. Say so instead of failing it.
    return switch (scripted) {
      _Failed(:final error) => {'error': error, 'success': false},
      _Answered(:final result) => result,
      _Silent() => {
        'acted': kind,
        'note': agentPreviewNavigated,
        'success': true,
      },
    };
  }

  /// `nudgeOverlay`: one stage against an overlay already on the page; a
  /// no-op on a page the agent never acted on.
  Future<void> nudge(AgentPageScript run, String stage) async {
    try {
      await run('''(function () {
  var w = window;
  var fn = w.__hermesWatch_fn;
  if (!fn) { return 'cold'; }
  try { fn(document, w.__hermesActHolder || {}, ${jsonEncode(stage)}); } catch (err) {}
  return 'ok';
})()''');
    } catch (_) {
      // The page navigated out from under us. The next action re-injects.
    }
  }

  /// Desktop's `runJson`, adapted: Android's `evaluateJavascript` hands back
  /// a Promise as `{}` instead of awaiting it, so the trip starts the same
  /// async wrapper, parks its outcome on the page and is collected by
  /// polling, under the same [timeout]. A page that navigates loses the
  /// parked outcome and the trip ends silent, as in Desktop.
  Future<_Trip> _runJson(
    AgentPageScript run,
    String code,
    bool Function()? isOpen,
  ) async {
    // An id the page cannot guess, in a holder it does not see by walking
    // `window` (the page could still look for it; it already controls what
    // the agent reads).
    final hex = [
      for (var i = 0; i < 16; i++)
        _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    final id = jsonEncode('t$hex');
    // Desktop races the whole trip against ACT_TIMEOUT_MS: a page whose main
    // thread is stuck must not hold the request (REVIEW-R5-B #9). Each call
    // gets what is left of the same deadline.
    final deadline = DateTime.now().add(timeout);
    Duration left() {
      final rest = deadline.difference(DateTime.now());
      return rest.isNegative ? Duration.zero : rest;
    }

    try {
      await run(
        '(function () { var w = window; if (!w.__hermesTrips) { '
        'Object.defineProperty(w, "__hermesTrips", { value: {} }); } '
        'var id = $id; (async () => ($code))().then(function (v) { '
        'w.__hermesTrips[id] = { v: v }; }, function (e) { '
        'w.__hermesTrips[id] = { e: String(e) }; }); return "started"; })()',
      ).timeout(left());
    } on TimeoutException {
      // The page never took the trip: as silent as a page that navigated.
      return const _Silent();
    } catch (_) {
      // The WebView failed, not the page: no plugin text for the model.
      return const _Failed(agentPreviewNoAnswer);
    }
    final collect =
        '(function () { var w = window; var t = w.__hermesTrips && '
        'w.__hermesTrips[$id]; if (!t) { return ""; } delete '
        'w.__hermesTrips[$id]; return JSON.stringify(t); })()';
    while (DateTime.now().isBefore(deadline)) {
      if (isOpen != null && !isOpen()) return const _Silent();
      await Future<void>.delayed(pollEvery);
      Object? raw;
      try {
        raw = await run(collect).timeout(left());
      } on TimeoutException {
        break;
      } catch (_) {
        continue;
      }
      final parked = decodeWebViewString(raw);
      if (parked == null || parked.isEmpty) continue;
      final Object? trip;
      try {
        trip = jsonDecode(parked);
      } on FormatException {
        continue;
      }
      if (trip is! Map) continue;
      if (trip['e'] != null) {
        return _Failed('The page rejected the action: ${trip['e']}');
      }
      final value = trip['v'];
      if (value is! String || value.isEmpty) {
        return const _Failed(agentPreviewNoAnswer);
      }
      try {
        final result = jsonDecode(value);
        if (result is Map) return _Answered(Map<String, Object?>.from(result));
      } on FormatException {
        // Falls through: an answer that is not a result.
      }
      return const _Failed(agentPreviewNoAnswer);
    }
    return const _Silent();
  }
}

// ── Script templates, verbatim from preview-act.ts ─────────────────────────

/// `preamble()`: the engine, the overlay, and the helpers every script shares.
String agentPreviewPreamble(AgentPreviewEngineSource s) =>
    '''  var w = window;
  // Reassigned on every trip rather than cached behind a guard: the source is in
  // this payload either way, so the guard saved nothing and pinned a long-lived
  // tab to whichever build first touched it. The holder is the exception — it
  // carries the aimed element from the locate trip to the act trip.
  w.__hermesActHolder = w.__hermesActHolder || {};
  w.__hermesAct = ${s.engine};
  w.__hermesWatch_fn = (${s.watch});
  w.__hermesWatchTag = ${s.watchTag};
  var holder = w.__hermesActHolder;
  var act = function (a) { return w.__hermesAct(document, holder, a); };
  var watch = function (stage, label) {
    try { w.__hermesWatch_fn(document, holder, stage, label); } catch (err) {}
  };
  var wait = function (ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); };
  // Sit out a smooth scroll so the pointer is aimed at a target that has stopped
  // moving. A scroll that never started fires no scrollend, so only wait on one
  // we can actually see happening; capture catches nested scrollers, whose
  // scrollend does not bubble.
  var restAfterScroll = function () {
    return new Promise(function (resolve) {
      var sc = document.scrollingElement || document.documentElement;
      var x0 = sc ? sc.scrollLeft : 0;
      var y0 = sc ? sc.scrollTop : 0;
      requestAnimationFrame(function () {
        if (!sc || (sc.scrollLeft === x0 && sc.scrollTop === y0)) { return resolve(); }
        var done = false;
        var finish = function () {
          if (done) { return; }
          done = true;
          document.removeEventListener('scrollend', finish, true);
          clearTimeout(timer);
          resolve();
        };
        var timer = setTimeout(finish, 350);
        document.addEventListener('scrollend', finish, true);
      });
    });
  };''';

/// `buildScriptedScript`: the engine acts and re-reads in one trip.
String buildScriptedScript(
  AgentPreviewEngineSource s,
  Map<String, Object?> action,
  int settleMs,
) =>
    '''(function () {
${agentPreviewPreamble(s)}
  var result = act(${jsonEncode(action)});
  ${action['kind'] == 'elements' ? "if (result.success) { watch('strobe'); }" : ''}
  if (!result.success || $settleMs <= 0) { return Promise.resolve(JSON.stringify(result)); }
  return wait($settleMs).then(function () {
    try {
      var after = act({ kind: 'elements' });
      watch('sweep');
      // One or the other, never both: a re-read answers with the whole
      // inventory only when it is the first look at this page.
      result.elements = after.elements;
      result.delta = after.delta;
      result.url = after.url;
      result.title = after.title;
    } catch (err) {
      result.note = 'The page changed before it could be re-read: ' + err;
    }
    return JSON.stringify(result);
  });
})()''';

Map<String, Object?> _locate(Map<String, Object?> action) => {
  'kind': 'locate',
  'ref': ?action['ref'],
  'selector': ?action['selector'],
};

/// `buildPinScript`.
String buildPinScript(
  AgentPreviewEngineSource s,
  Map<String, Object?> action,
  String label,
) =>
    '''(function () {
${agentPreviewPreamble(s)}
  var found = act(${jsonEncode(_locate(action))});
  if (!found.success) { return JSON.stringify(found); }
  watch('pin', ${jsonEncode(label)});
  return JSON.stringify({ acted: 'pinned ' + String(found.acted || 'it').replace(/^looking at /, ''), success: true });
})()''';

/// `buildHoldScript`.
String buildHoldScript(AgentPreviewEngineSource s) =>
    '''(function () {
${agentPreviewPreamble(s)}
  var found = act({ kind: 'elements' });
  if (!found.success) { return JSON.stringify(found); }
  watch('hold');
  found.acted = 'held the field';
  return JSON.stringify(found);
})()''';

/// `buildStrobeScript`.
String buildStrobeScript(AgentPreviewEngineSource s) =>
    '''(function () {
${agentPreviewPreamble(s)}
  var found = act({ kind: 'elements' });
  if (!found.success) { return JSON.stringify(found); }
  watch('strobe');
  found.acted = 'strobed the field';
  return JSON.stringify(found);
})()''';

/// `buildUnpinScript`.
String buildUnpinScript(
  AgentPreviewEngineSource s,
  Map<String, Object?> action,
) {
  final one = action['ref'] != null || action['selector'] != null;
  final body = one
      ? '''  var found = act(${jsonEncode(_locate(action))});
  if (!found.success) { return JSON.stringify(found); }
  var gone = 'unpinned ' + String(found.acted || 'it').replace(/^looking at /, '');'''
      : '''  holder.aimed = null;
  var gone = 'cleared every pin';''';
  return '''(function () {
${agentPreviewPreamble(s)}
$body
  watch('unpin');
  return JSON.stringify({ acted: gone, success: true });
})()''';
}
