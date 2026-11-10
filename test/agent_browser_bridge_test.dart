import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/browser/agent_browser_bridge.dart';
import 'package:hermes_android/core/browser/agent_preview_act.dart';
import 'package:hermes_android/core/browser/agent_preview_protocol.dart';
import 'package:hermes_android/core/browser/hermes_preview_engine.g.dart';

/// A chat screen: on screen or not, recording the browsers it was asked to
/// open.
class _Chat implements AgentChatPresence {
  _Chat(this.sessionId, {this.connectionId = _conn, this.onScreen = true});

  @override
  final String connectionId;
  @override
  final String? sessionId;
  @override
  bool onScreen;
  final opened = <(Uri, String)>[];

  @override
  void openBrowser(Uri url, String label) => opened.add((url, label));
}

/// An open browser whose page answers scripts through [respond].
class _Page implements AgentBrowserPage {
  _Page(
    this.ownerSessionId, {
    this.ownerConnectionId = _conn,
    this.blank = false,
    this.openedByAgent = false,
    this.currentUrl = 'https://example.com/a',
    this.initialUrl = 'https://example.com/a',
    this.label = '',
    this.pageTitle = 'Example',
    this.respond,
  });

  @override
  final String? ownerConnectionId;
  @override
  final String? ownerSessionId;
  @override
  bool onScreen = true;
  @override
  bool blank;
  @override
  bool openedByAgent;
  @override
  String currentUrl;
  @override
  final String initialUrl;
  @override
  String label;
  String pageTitle;
  Object? Function(String script)? respond;
  final scripts = <String>[];
  final calls = <String>[];
  final navigated = <(Uri, String)>[];
  final reading = <bool>[];

  /// A page whose main thread is stuck: no script ever comes back.
  bool stuck = false;

  @override
  Future<String> title() async => pageTitle;

  @override
  Future<Object?> runScript(String script) {
    scripts.add(script);
    if (stuck) return Completer<Object?>().future;
    return Future.sync(() => respond?.call(script) ?? '');
  }

  @override
  void goBack() => calls.add('back');
  @override
  void goForward() => calls.add('forward');
  @override
  void reload() => calls.add('reload');

  @override
  void navigate(Uri url, String label) => navigated.add((url, label));

  @override
  void setAgentReading(bool value) => reading.add(value);

  @override
  void close() => calls.add('close');
}

/// The connection every fake chat and page belongs to unless told otherwise.
const _conn = 'conn-a';

PreviewBridgeRequest _req(
  String method,
  String session, [
  Map<String, dynamic> params = const {},
  String connection = _conn,
]) => PreviewBridgeRequest(
  method: method,
  connectionId: connection,
  sessionId: session,
  params: params,
  isOpen: () => true,
);

Map<String, dynamic> _value(PreviewBridgeAnswer answer) {
  expect(answer.notShown, isFalse);
  return jsonDecode(answer.value) as Map<String, dynamic>;
}

/// Answers the polling trips the way a page that ran [result] would.
Object? Function(String) _pageThatAnswers(Map<String, Object?> result) {
  return (script) {
    if (script.contains('w.__hermesTrips[id] = { v: v }')) return 'started';
    if (script.contains('delete w.__hermesTrips')) {
      return jsonEncode(jsonEncode({'v': jsonEncode(result)}));
    }
    return '';
  };
}

AgentBrowserBridge _bridge({
  Duration timeout = agentPreviewActTimeout,
  bool Function()? unlocked,
}) => AgentBrowserBridge(
  engine: AgentPreviewActEngine(
    () async => hermesPreviewEngine,
    pollEvery: const Duration(milliseconds: 1),
    timeout: timeout,
  ),
  unlocked: unlocked,
);

void main() {
  group('preview.open (Desktop use-preview-routing.ts)', () {
    test('opens at once for the chat on screen, with its label', () {
      final bridge = _bridge();
      final chat = _Chat('rt-1');
      bridge.attachChat(chat);
      bridge.onAgentPreviewEvent(
        connectionId: _conn,
        sessionId: 'rt-1',
        type: 'preview.open',
        payload: {'url': 'https://news.example/', 'label': 'News'},
      );
      expect(chat.opened, [(Uri.parse('https://news.example/'), 'News')]);
      expect(bridge.offerFor(_conn, 'rt-1'), isNull);
    });

    test('a chat not on screen gets an offer, never an open', () {
      final bridge = _bridge();
      final chat = _Chat('rt-1', onScreen: false);
      bridge.attachChat(chat);
      bridge.onAgentPreviewEvent(
        connectionId: _conn,
        sessionId: 'rt-1',
        type: 'preview.open',
        payload: {'url': 'https://news.example/'},
      );
      expect(chat.opened, isEmpty);
      expect(
        bridge.offerFor(_conn, 'rt-1')?.url,
        Uri.parse('https://news.example/'),
      );
      // Another chat's session is not on screen either.
      bridge.onAgentPreviewEvent(
        connectionId: _conn,
        sessionId: 'rt-2',
        type: 'preview.open',
        payload: {'url': 'https://other.example/'},
      );
      expect(bridge.offerFor(_conn, 'rt-2'), isNotNull);
    });

    test('the agent\'s own open page navigates in place (one view)', () {
      final bridge = _bridge();
      bridge.attachChat(_Chat('rt-1'));
      final page = _Page('rt-1', openedByAgent: true);
      bridge.attach(page);
      bridge.onAgentPreviewEvent(
        connectionId: _conn,
        sessionId: 'rt-1',
        type: 'preview.open',
        payload: {'url': 'https://b.example/', 'label': 'B'},
      );
      expect(page.navigated, [(Uri.parse('https://b.example/'), 'B')]);
      expect(bridge.offerFor(_conn, 'rt-1'), isNull);
    });

    test('a blank browser shows the agent\'s page at once', () {
      final bridge = _bridge();
      final page = _Page('rt-1', blank: true, currentUrl: '', initialUrl: '');
      bridge.attach(page);
      bridge.onAgentPreviewEvent(
        connectionId: _conn,
        sessionId: 'rt-1',
        type: 'preview.open',
        payload: {'url': 'https://b.example/'},
      );
      expect(page.navigated, [(Uri.parse('https://b.example/'), '')]);
    });

    test('the user\'s own page is never replaced: the agent gets «Ver»', () {
      final bridge = _bridge();
      bridge.attachChat(_Chat('rt-1'));
      final page = _Page('rt-1', currentUrl: 'https://mine.example/');
      bridge.attach(page);
      bridge.onAgentPreviewEvent(
        connectionId: _conn,
        sessionId: 'rt-1',
        type: 'preview.open',
        payload: {'url': 'https://b.example/', 'label': 'B'},
      );
      expect(page.navigated, isEmpty);
      expect(page.currentUrl, 'https://mine.example/');
      final offer = bridge.offerFor(_conn, 'rt-1');
      expect(offer?.url, Uri.parse('https://b.example/'));
      expect(offer?.label, 'B');
    });

    test('another connection\'s session with the same id is not this chat', () {
      final bridge = _bridge();
      final chat = _Chat('rt-1');
      final page = _Page('rt-1');
      bridge
        ..attachChat(chat)
        ..attach(page);
      bridge.onAgentPreviewEvent(
        connectionId: 'conn-b',
        sessionId: 'rt-1',
        type: 'preview.open',
        payload: {'url': 'https://b.example/'},
      );
      expect(chat.opened, isEmpty);
      expect(page.navigated, isEmpty);
      // The offer waits for conn-b's own chat, never shown in conn-a's.
      expect(bridge.offerFor(_conn, 'rt-1'), isNull);
      expect(bridge.offerFor('conn-b', 'rt-1'), isNotNull);
      bridge.onAgentPreviewEvent(
        connectionId: 'conn-b',
        sessionId: 'rt-1',
        type: 'preview.close',
        payload: const {},
      );
      expect(page.calls, isEmpty);
    });

    test('only http/https targets: file paths and scripts are dropped', () {
      final bridge = _bridge();
      final chat = _Chat('rt-1');
      bridge.attachChat(chat);
      for (final url in [
        '/home/user/report.html',
        'file:///tmp/x.html',
        'javascript:alert(1)',
        '',
      ]) {
        bridge.onAgentPreviewEvent(
          connectionId: _conn,
          sessionId: 'rt-1',
          type: 'preview.open',
          payload: {'url': url},
        );
      }
      expect(chat.opened, isEmpty);
      expect(bridge.offers.value, isEmpty);
    });
  });

  group('preview.close (Desktop closeAgentPreview)', () {
    test('a chat not on screen never closes the browser', () {
      final bridge = _bridge();
      final page = _Page('rt-1')..onScreen = false;
      bridge
        ..attachChat(_Chat('rt-1', onScreen: false))
        ..attach(page);
      bridge.onAgentPreviewEvent(
        connectionId: _conn,
        sessionId: 'rt-1',
        type: 'preview.close',
        payload: const {},
      );
      expect(page.calls, isEmpty);
    });

    test('closes the whole browser, or only the matching page', () {
      final bridge = _bridge();
      final page = _Page(
        'rt-1',
        currentUrl: 'https://example.com/now',
        initialUrl: 'https://example.com/start',
      );
      bridge.attach(page);
      bridge.onAgentPreviewEvent(
        connectionId: _conn,
        sessionId: 'rt-1',
        type: 'preview.close',
        payload: {'url': 'https://elsewhere.example/'},
      );
      expect(page.calls, isEmpty);
      bridge.onAgentPreviewEvent(
        connectionId: _conn,
        sessionId: 'rt-1',
        type: 'preview.close',
        payload: {'url': 'https://example.com/start'},
      );
      expect(page.calls, ['close']);
      bridge.onAgentPreviewEvent(
        connectionId: _conn,
        sessionId: 'rt-1',
        type: 'preview.close',
        payload: const {},
      );
      expect(page.calls, ['close', 'close']);
    });

    test('a close drops a pending offer of that chat', () {
      final bridge = _bridge();
      bridge.attachChat(_Chat('rt-1', onScreen: false));
      bridge.onAgentPreviewEvent(
        connectionId: _conn,
        sessionId: 'rt-1',
        type: 'preview.open',
        payload: {'url': 'https://a.example/'},
      );
      bridge.onAgentPreviewEvent(
        connectionId: _conn,
        sessionId: 'rt-1',
        type: 'preview.close',
        payload: {'url': 'https://a.example/'},
      );
      expect(bridge.offerFor(_conn, 'rt-1'), isNull);
    });
  });

  group('only what the user sees, in an unlocked app (REVIEW-R5-B #3)', () {
    test('a hidden browser is never read, driven, navigated or closed', () {
      final bridge = _bridge();
      final chat = _Chat('rt-1');
      // The chat is in front, its browser is a hidden workspace tab.
      final page = _Page(
        'rt-1',
        openedByAgent: true,
        respond: (_) => '"secreto"',
      )..onScreen = false;
      bridge
        ..attachChat(chat)
        ..attach(page);
      expect(bridge.sessionOnScreen(_conn, 'rt-1'), isTrue);
      bridge.onAgentPreviewEvent(
        connectionId: _conn,
        sessionId: 'rt-1',
        type: 'preview.open',
        payload: {'url': 'https://b.example/'},
      );
      expect(page.navigated, isEmpty);
      expect(chat.opened, isEmpty);
      // What it asked to show waits as an offer. (A close drops a pending
      // offer, as in Desktop: it is checked before the close below.)
      expect(
        bridge.offerFor(_conn, 'rt-1')?.url,
        Uri.parse('https://b.example/'),
      );
      bridge.onAgentPreviewEvent(
        connectionId: _conn,
        sessionId: 'rt-1',
        type: 'preview.close',
        payload: const {},
      );
      expect(page.navigated, isEmpty);
      expect(page.calls, isEmpty, reason: 'the hidden browser is not closed');
      expect(chat.opened, isEmpty);
    });

    test('a hidden browser declines read and act (NOT_SHOWN)', () async {
      final bridge = _bridge();
      final page = _Page('rt-1', respond: (_) => '"secreto"')
        ..onScreen = false;
      bridge
        ..attachChat(_Chat('rt-1'))
        ..attach(page);
      for (final method in ['preview.read', 'preview.act']) {
        final answer = await bridge.answer(
          _req(method, 'rt-1', {'action': 'elements'}),
        );
        expect(answer.notShown, isTrue, reason: method);
      }
      expect(page.scripts, isEmpty);
    });

    test('a locked app shows nothing: no read, act, open or close', () async {
      final bridge = _bridge(unlocked: () => false);
      final chat = _Chat('rt-1');
      final page = _Page(
        'rt-1',
        openedByAgent: true,
        respond: (_) => '"secreto"',
      );
      bridge
        ..attachChat(chat)
        ..attach(page);
      expect(bridge.sessionOnScreen(_conn, 'rt-1'), isFalse);
      for (final method in ['preview.read', 'preview.act']) {
        final answer = await bridge.answer(
          _req(method, 'rt-1', {'action': 'elements'}),
        );
        expect(answer.notShown, isTrue, reason: method);
      }
      bridge
        ..onAgentPreviewEvent(
          connectionId: _conn,
          sessionId: 'rt-1',
          type: 'preview.open',
          payload: {'url': 'https://b.example/'},
        )
        ..onAgentPreviewEvent(
          connectionId: _conn,
          sessionId: 'rt-1',
          type: 'preview.close',
          payload: const {},
        );
      expect(page.scripts, isEmpty);
      expect(page.navigated, isEmpty);
      expect(page.calls, isEmpty);
      expect(chat.opened, isEmpty);
    });
  });

  group('preview.read (Desktop previewRead / readActivePreview)', () {
    test('a session not on screen is declined (NOT_SHOWN)', () async {
      final bridge = _bridge();
      bridge.attachChat(_Chat('rt-1', onScreen: false));
      final answer = await bridge.answer(_req('preview.read', 'rt-1'));
      expect(answer.notShown, isTrue);
      expect(
        (await bridge.answer(_req('preview.read', 'rt-9'))).notShown,
        isTrue,
      );
    });

    test('the same session id from another connection is declined', () async {
      final bridge = _bridge();
      final page = _Page('rt-1', respond: (_) => 'secret page text');
      bridge
        ..attachChat(_Chat('rt-1'))
        ..attach(page);
      for (final method in ['preview.read', 'preview.act']) {
        final answer = await bridge.answer(
          _req(method, 'rt-1', {'action': 'elements'}, 'conn-b'),
        );
        expect(answer.notShown, isTrue, reason: method);
      }
      expect(page.scripts, isEmpty);
    });

    test('two connections sharing a session id never see each other', () async {
      final bridge = _bridge();
      // conn-a's chat and page are behind; conn-b's, with the same runtime
      // id, are on screen.
      final chatA = _Chat('rt-1', onScreen: false);
      final pageA = _Page('rt-1', respond: (_) => '"texto A"')
        ..onScreen = false;
      final chatB = _Chat('rt-1', connectionId: 'conn-b');
      final pageB = _Page(
        'rt-1',
        ownerConnectionId: 'conn-b',
        openedByAgent: true,
        respond: (_) => '"texto B"',
      );
      bridge
        ..attachChat(chatA)
        ..attachChat(chatB)
        ..attach(pageA)
        ..attach(pageB);

      expect(bridge.sessionOnScreen(_conn, 'rt-1'), isFalse);
      expect(bridge.sessionOnScreen('conn-b', 'rt-1'), isTrue);
      // conn-b on screen does not make conn-a's request answerable.
      expect(
        (await bridge.answer(_req('preview.read', 'rt-1'))).notShown,
        isTrue,
      );
      expect(pageA.scripts, isEmpty);
      expect(pageB.scripts, isEmpty);
      // conn-b reads its own page, never conn-a's.
      final read = _value(
        await bridge.answer(_req('preview.read', 'rt-1', const {}, 'conn-b')),
      );
      expect(read['text'], 'texto B');
      expect(pageA.scripts, isEmpty);

      // conn-a's open waits as conn-a's offer; conn-b's chat and page stay.
      bridge.onAgentPreviewEvent(
        connectionId: _conn,
        sessionId: 'rt-1',
        type: 'preview.open',
        payload: {'url': 'https://a.example/'},
      );
      expect(chatB.opened, isEmpty);
      expect(pageB.navigated, isEmpty);
      expect(
        bridge.offerFor(_conn, 'rt-1')?.url,
        Uri.parse('https://a.example/'),
      );
      expect(bridge.offerFor('conn-b', 'rt-1'), isNull);

      // conn-b's open and close reach only conn-b's page.
      bridge
        ..onAgentPreviewEvent(
          connectionId: 'conn-b',
          sessionId: 'rt-1',
          type: 'preview.open',
          payload: {'url': 'https://b.example/'},
        )
        ..onAgentPreviewEvent(
          connectionId: 'conn-b',
          sessionId: 'rt-1',
          type: 'preview.close',
          payload: const {},
        );
      expect(pageB.navigated, [(Uri.parse('https://b.example/'), '')]);
      expect(pageB.calls, ['close']);
      expect(pageA.navigated, isEmpty);
      expect(pageA.calls, isEmpty);
      expect(chatA.opened, isEmpty);
    });

    test('the chat on screen with nothing open answers empty', () async {
      final bridge = _bridge();
      bridge.attachChat(_Chat('rt-1'));
      final answer = await bridge.answer(_req('preview.read', 'rt-1'));
      expect(answer.notShown, isFalse);
      expect(answer.value, '');
    });

    test('reads the visible text with Desktop\'s shape, no dialog', () async {
      final bridge = _bridge();
      final page = _Page(
        'rt-1',
        respond: (s) => s == agentPreviewTextScript ? '"Hola mundo"' : 'cold',
      );
      bridge.attach(page);
      final result = _value(await bridge.answer(_req('preview.read', 'rt-1')));
      expect(result, {
        'kind': 'url',
        'title': 'Example',
        'url': 'https://example.com/a',
        'end': 10,
        'start': 0,
        'text': 'Hola mundo',
        'total_chars': 10,
      });
      expect(page.scripts.first, agentPreviewTextScript);
    });

    test('the read shows in the browser, even a failed one', () async {
      final bridge = _bridge();
      final page = _Page('rt-1', respond: (_) => '"x"');
      bridge.attach(page);
      await bridge.answer(_req('preview.read', 'rt-1'));
      expect(page.reading, [true, false]);
      page.respond = (_) => throw StateError('boot');
      await bridge.answer(_req('preview.read', 'rt-1'));
      expect(page.reading, [true, false, true, false]);
      // A declined request reads nothing and shows nothing.
      page.onScreen = false;
      await bridge.answer(_req('preview.read', 'rt-1'));
      expect(page.reading, hasLength(4));
    });

    test('pages with start/count and caps at 24 000 characters', () async {
      final bridge = _bridge();
      final long = 'x' * 30000;
      final page = _Page('rt-1', respond: (_) => long);
      bridge.attach(page);
      final first = _value(await bridge.answer(_req('preview.read', 'rt-1')));
      expect(first['end'], agentPreviewReadMaxChars);
      expect(first['total_chars'], 30000);
      final window = _value(
        await bridge.answer(
          _req('preview.read', 'rt-1', {'start': 29990, 'count': 50}),
        ),
      );
      expect(window['start'], 29990);
      expect(window['end'], 30000);
      expect((window['text'] as String).length, 10);
    });

    test('a page with no title falls back to the agent\'s label', () async {
      final bridge = _bridge();
      bridge.attach(
        _Page('rt-1', pageTitle: '', label: 'Docs', respond: (_) => 'x'),
      );
      final result = _value(await bridge.answer(_req('preview.read', 'rt-1')));
      expect(result['title'], 'Docs');
    });

    test('a page not ready answers its identity and Desktop\'s note', () async {
      final bridge = _bridge();
      bridge.attach(_Page('rt-1', respond: (_) => throw StateError('boot')));
      final result = _value(await bridge.answer(_req('preview.read', 'rt-1')));
      expect(
        result['note'],
        'The page has not finished loading — retry in a moment.',
      );
      expect(result['text'], '');
      expect(result['url'], 'https://example.com/a');
    });
  });

  group('preview.act (Desktop previewAct / actOnActivePreview)', () {
    test('a session not on screen is declined', () async {
      final bridge = _bridge();
      bridge.attachChat(_Chat('rt-1', onScreen: false));
      expect(
        (await bridge.answer(
          _req('preview.act', 'rt-1', {'action': 'elements'}),
        )).notShown,
        isTrue,
      );
    });

    test('nothing open answers Desktop\'s NOTHING_OPEN', () async {
      final bridge = _bridge();
      bridge.attachChat(_Chat('rt-1'));
      final result = _value(
        await bridge.answer(_req('preview.act', 'rt-1', {'action': 'click'})),
      );
      expect(result, {'error': agentPreviewNothingOpen, 'success': false});
    });

    test('back, forward and reload drive the WebView history', () async {
      final bridge = _bridge();
      final page = _Page('rt-1');
      bridge.attach(page);
      for (final verb in ['back', 'forward', 'reload']) {
        final result = _value(
          await bridge.answer(_req('preview.act', 'rt-1', {'action': verb})),
        );
        expect(result, {
          'acted': verb,
          'note': 'Page is loading — call elements to see what is on it.',
          'success': true,
        });
      }
      expect(page.calls, ['back', 'forward', 'reload']);
      expect(page.reading, [true, false, true, false, true, false]);
    });

    test('elements runs Desktop\'s engine and answers its result', () async {
      final bridge = _bridge();
      final inventory = {
        'elements': [
          {'ref': 'btn-sign-in', 'role': 'button', 'label': 'Sign in'},
        ],
        'success': true,
        'title': 'Example',
        'url': 'https://example.com/a',
      };
      final page = _Page('rt-1', respond: _pageThatAnswers(inventory));
      bridge.attach(page);
      final result = _value(
        await bridge.answer(
          _req('preview.act', 'rt-1', {'action': 'elements'}),
        ),
      );
      expect(result, inventory);
      // The trip carried Desktop's engine, overlay and the scripted path.
      final trip = page.scripts.first;
      expect(trip, contains('w.__hermesAct = (function (doc, holder, action)'));
      expect(trip, contains('w.__hermesWatch_fn = ('));
      expect(trip, contains('"kind":"elements"'));
      expect(trip, contains("if (result.success) { watch('strobe'); }"));
    });

    test('a page that stops answering is reported as navigating', () async {
      final bridge = _bridge(timeout: const Duration(milliseconds: 30));
      final page = _Page(
        'rt-1',
        respond: (s) => s.contains('{ v: v }') ? 'started' : '',
      );
      bridge.attach(page);
      final result = _value(
        await bridge.answer(
          _req('preview.act', 'rt-1', {'action': 'click', 'ref': 'btn-x'}),
        ),
      );
      expect(result, {
        'acted': 'click',
        'note': agentPreviewNavigated,
        'success': true,
      });
    });

    test('a page that throws is reported like Desktop', () async {
      final bridge = _bridge();
      final page = _Page(
        'rt-1',
        respond: (s) {
          if (s.contains('{ v: v }')) return 'started';
          if (s.contains('delete w.__hermesTrips')) {
            return jsonEncode({'e': 'TypeError: boom'});
          }
          return '';
        },
      );
      bridge.attach(page);
      final result = _value(
        await bridge.answer(
          _req('preview.act', 'rt-1', {'action': 'elements'}),
        ),
      );
      expect(result, {
        'error': 'The page rejected the action: TypeError: boom',
        'success': false,
      });
    });
  });

  group('a stuck page never holds the request (REVIEW-R5-B #9)', () {
    test('a read gives up with the not-ready note', () async {
      final bridge = AgentBrowserBridge(
        engine: AgentPreviewActEngine(() async => hermesPreviewEngine),
        readTimeout: const Duration(milliseconds: 30),
      );
      final page = _Page('rt-1')..stuck = true;
      bridge.attach(page);
      final result = _value(await bridge.answer(_req('preview.read', 'rt-1')));
      expect(
        result['note'],
        'The page has not finished loading — retry in a moment.',
      );
      expect(page.reading, [true, false]);
    });

    test('an action gives up as a page that navigated', () async {
      final bridge = _bridge(timeout: const Duration(milliseconds: 30));
      final page = _Page('rt-1')..stuck = true;
      bridge.attach(page);
      final result = _value(
        await bridge.answer(
          _req('preview.act', 'rt-1', {'action': 'click', 'ref': 'btn-x'}),
        ),
      );
      expect(result['note'], agentPreviewNavigated);
      expect(page.reading, [true, false]);
    });
  });

  group('preview.act hardening (REVIEW-R4 P3)', () {
    test('a WebView that fails answers Desktop\'s fixed text', () async {
      final bridge = _bridge();
      bridge.attach(
        _Page(
          'rt-1',
          respond: (_) => throw StateError('PlatformException(channel-error)'),
        ),
      );
      final result = _value(
        await bridge.answer(
          _req('preview.act', 'rt-1', {'action': 'elements'}),
        ),
      );
      expect(result, {'error': agentPreviewNoAnswer, 'success': false});
    });

    test('a page that leaves the screen stops the trip at once', () async {
      final bridge = _bridge();
      var collects = 0;
      late final _Page page;
      page = _Page(
        'rt-1',
        respond: (s) {
          if (s.contains('{ v: v }')) return 'started';
          if (++collects == 2) page.onScreen = false;
          return '';
        },
      );
      bridge.attach(page);
      final result = _value(
        await bridge.answer(
          _req('preview.act', 'rt-1', {'action': 'click', 'ref': 'btn-x'}),
        ),
      );
      expect(result['note'], agentPreviewNavigated);
      // Not the 8 s of polling: it stopped right after the page left.
      expect(collects, 2);
    });

    test('every trip has its own unguessable id', () async {
      final bridge = _bridge();
      final page = _Page('rt-1', respond: _pageThatAnswers({'success': true}));
      bridge.attach(page);
      for (var i = 0; i < 2; i++) {
        await bridge.answer(
          _req('preview.act', 'rt-1', {'action': 'elements'}),
        );
      }
      final ids = page.scripts
          .where((s) => s.contains('{ v: v }'))
          .map((s) => RegExp(r'var id = "(t[0-9a-f]+)"').firstMatch(s)?[1])
          .toList();
      expect(ids, hasLength(2));
      expect(ids.every((id) => id != null && id.length == 33), isTrue);
      expect(ids.first, isNot(ids.last));
    });
  });

  group('privacy (REVIEW-R4 P1-a1, a deliberate difference from Desktop)', () {
    test('the inventory never reports a secret field\'s value', () {
      final engine = hermesPreviewEngine.engine;
      // Desktop's naming kit reports every field's value; Console's patched
      // engine checks for passwords, one-time codes and card fields first and
      // never lends their value attribute as a label.
      expect(engine, contains('const sensitiveKind = (el) =>'));
      expect(engine, contains('const secret = sensitiveKind(el);'));
      expect(engine, contains('" field, " + length + " characters]"'));
      const labelGuard = 'attr === "value" && sensitiveKind(el) ? "" : ';
      expect(engine, contains(labelGuard));
      // REVIEW-R5-B #11: 2FA, MFA, TOTP, passcode, PIN and verification
      // codes, named by aria-label, <label> or aria-labelledby; one-digit
      // boxes; and a contenteditable's typed text never used as its label.
      expect(engine, contains('verif(y|ication)?.?code'));
      expect(engine, contains(r'\b2fa\b'));
      expect(engine, contains('pass.?code'));
      expect(engine, contains(r'\bpin\b'));
      expect(engine, contains('el.labels ? Array.from(el.labels)'));
      expect(engine, contains('max > 0 && max <= 1'));
      expect(engine, contains('const text = editable ? "" :'));
      expect(
        engine.indexOf('const secret = sensitiveKind(el);'),
        lessThan(
          engine.indexOf(
            'if (typeof control.value === "string" && control.value)',
          ),
        ),
      );
    });
  });

  group('the offer\'s label (REVIEW-R5-B #22)', () {
    test('only plain, short text the agent gave', () {
      expect(agentPreviewSafeLabel('  Noticias  '), 'Noticias');
      expect(agentPreviewSafeLabel(null), '');
      expect(agentPreviewSafeLabel(7), '');
      expect(agentPreviewSafeLabel('x' * 121), '');
      expect(agentPreviewSafeLabel('Tu \u202Eocnab'), '');
      expect(agentPreviewSafeLabel('Tu\u2066banco'), '');
      expect(agentPreviewSafeLabel('línea\nnueva'), '');
      expect(agentPreviewSafeLabel('Docs · API'), 'Docs · API');
    });
  });

  group('wire helpers', () {
    test('the action is built like Desktop\'s previewAct handler', () {
      expect(
        agentPreviewActAction({
          'action': 'type',
          'ref': 'inp-email',
          'text': 'a@b.c',
          'submit': true,
        }),
        {
          'allowShortcut': false,
          'kind': 'type',
          'ref': 'inp-email',
          'submit': true,
          'text': 'a@b.c',
        },
      );
      final shortcut = agentPreviewActAction({'allow_shortcut': true});
      expect(shortcut['allowShortcut'], isTrue);
    });

    test('Android quotes strings; the fake and iOS do not', () {
      expect(decodeWebViewString('"a\\nb"'), 'a\nb');
      expect(decodeWebViewString('plain'), 'plain');
      expect(decodeWebViewString(null), isNull);
      expect(decodeWebViewString(3), isNull);
    });

    test('annotation scripts follow preview-act.ts', () {
      final pin = buildPinScript(
        hermesPreviewEngine,
        {'kind': 'pin', 'ref': 'btn-go'},
        'Aquí',
      );
      expect(pin, contains('"kind":"locate","ref":"btn-go"'));
      expect(pin, contains("watch('pin', \"Aquí\");"));
      expect(
        buildUnpinScript(hermesPreviewEngine, {'kind': 'unpin'}),
        contains("var gone = 'cleared every pin';"),
      );
      expect(
        buildScriptedScript(hermesPreviewEngine, {'kind': 'click'}, 220),
        contains('return wait(220).then('),
      );
    });
  });
}
