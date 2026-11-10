// Q9-NAV (mock navegador-pestanas, approved by the owner): the in-app browser's
// tabs. Closing one never leaves the browser; the agent's page goes to its
// own tab, never to one of the user's; at most three pages are alive.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/browser/browser_tabs.dart';

final _a = Uri.parse('https://boletin.ejemplo.dev/semana-43');
final _b = Uri.parse('https://docs.ejemplo.dev/instalar');
final _c = Uri.parse('https://tienda.ejemplo.dev/');

void main() {
  test('opens with one blank tab; a new tab goes in front, at the end', () {
    final tabs = BrowserTabs()..ensureOne();
    expect(tabs.length, 1);
    expect(tabs.active!.blank, isTrue);
    final b = tabs.open(url: _b);
    expect(tabs.length, 2);
    expect(tabs.active, same(b));
    expect(tabs.activeIndex, 1);
    tabs.ensureOne();
    expect(tabs.length, 2, reason: 'only when there is none');
  });

  test('closing a tab gives the screen to its right, else its left', () {
    final tabs = BrowserTabs();
    final a = tabs.open(url: _a);
    final b = tabs.open(url: _b);
    final c = tabs.open(url: _c);
    tabs.activate(b.id);
    expect(tabs.close(b.id), same(b));
    expect(tabs.active, same(c), reason: 'the one on its right');
    tabs.close(c.id);
    expect(tabs.active, same(a), reason: 'it was the last: the left one');
    expect(tabs.tabs, [a]);
  });

  test('closing the last tab leaves a blank one: the browser stays', () {
    final tabs = BrowserTabs();
    final a = tabs.open(url: _a);
    tabs.close(a.id);
    expect(tabs.length, 1);
    expect(tabs.active!.blank, isTrue);
    expect(tabs.active!.id, isNot(a.id));
  });

  test('«Deshacer» brings back the closed tab where it was', () {
    final tabs = BrowserTabs();
    final a = tabs.open(url: _a);
    final b = tabs.open(url: _b);
    final c = tabs.open(url: _c);
    tabs
      ..activate(b.id)
      ..close(b.id);
    expect(tabs.active, same(c));
    expect(tabs.canUndo, isTrue);
    expect(tabs.undo(), isTrue);
    expect(tabs.tabs, [a, b, c]);
    expect(tabs.active, same(b));
    expect(tabs.canUndo, isFalse);

    // The last one, closed and back: no blank tab is left behind.
    final only = BrowserTabs();
    final x = only.open(url: _a);
    only
      ..close(x.id)
      ..undo();
    expect(only.tabs, [x]);
  });

  test('«Cerrar todas» leaves one blank tab; «Deshacer» brings them all', () {
    final tabs = BrowserTabs();
    final a = tabs.open(url: _a);
    final b = tabs.open(url: _b);
    expect(tabs.closeAll(), 2);
    expect(tabs.length, 1);
    expect(tabs.active!.blank, isTrue);
    expect(tabs.undo(), isTrue);
    expect(tabs.tabs, [a, b]);
    expect(tabs.active, same(b));
    // Only a blank tab: nothing to close.
    final blank = BrowserTabs()..ensureOne();
    expect(blank.closeAll(), 0);
    expect(blank.canUndo, isFalse);
  });

  group('the agent (decision 2 a: its own tab, in front)', () {
    test('its first page takes a blank tab in front', () {
      final tabs = BrowserTabs()..ensureOne();
      final blank = tabs.active!;
      final tab = tabs.openAgent(_a, 'Boletín');
      expect(tab, same(blank));
      expect(tab.agent, isTrue);
      expect(tab.url, _a);
      expect(tab.label, 'Boletín');
      expect(tabs.length, 1);
    });

    test('never a tab of the user\'s: a new one, brought to the front', () {
      final tabs = BrowserTabs();
      final mine = tabs.open(url: _b);
      final agent = tabs.openAgent(_a, '');
      expect(agent, isNot(same(mine)));
      expect(mine.url, _b, reason: 'the user\'s page is untouched');
      expect(tabs.active, same(agent));
      expect(tabs.tabs, [mine, agent]);
    });

    test('its next page goes to its tab again, which comes to the front', () {
      final tabs = BrowserTabs();
      final agent = tabs.openAgent(_a, 'Boletín');
      final mine = tabs.open(url: _b);
      expect(tabs.active, same(mine));
      final again = tabs.openAgent(_c, 'Tienda');
      expect(again, same(agent));
      expect(again.url, _c);
      expect(again.title, '', reason: 'the old title is gone with its page');
      expect(tabs.active, same(agent));
      expect(tabs.length, 2);
    });

    test('a tab the user took over is the user\'s: the next page gets a '
        'new tab', () {
      final tabs = BrowserTabs();
      final agent = tabs.openAgent(_a, 'Boletín');
      tabs.update(agent.id, agent: false);
      expect(agent.label, '');
      final next = tabs.openAgent(_c, '');
      expect(next, isNot(same(agent)));
      expect(tabs.length, 2);
    });

    test('the agent closing its tab leaves no blank one; the last one '
        'empties the browser', () {
      final tabs = BrowserTabs();
      final mine = tabs.open(url: _b);
      final agent = tabs.openAgent(_a, '');
      expect(tabs.removeForAgent(agent.id), isFalse);
      expect(tabs.tabs, [mine]);
      expect(tabs.active, same(mine));
      expect(tabs.canUndo, isFalse);
      expect(tabs.removeForAgent(mine.id), isTrue);
      expect(tabs.isEmpty, isTrue);
      expect(tabs.active, isNull);
    });

    test('closing every tab for the agent empties the browser', () {
      final tabs = BrowserTabs()
        ..open(url: _a)
        ..open(url: _b)
        ..clearForAgent();
      expect(tabs.isEmpty, isTrue);
    });
  });

  test('at most three pages alive: the active one and the most recent', () {
    final tabs = BrowserTabs();
    final a = tabs.open(url: _a);
    final b = tabs.open(url: _b);
    final c = tabs.open(url: _c);
    final d = tabs.open();
    expect(tabs.liveIds, {d.id, c.id, b.id});
    expect(tabs.liveIds.first, d.id, reason: 'the active one first');
    tabs.activate(a.id);
    expect(tabs.liveIds, {a.id, d.id, c.id});
    expect(tabs.liveIds, isNot(contains(b.id)), reason: 'b sleeps');
  });

  test('a page\'s own changes are kept, and only real ones notify', () {
    final tabs = BrowserTabs();
    final a = tabs.open(url: _a);
    var calls = 0;
    tabs.addListener(() => calls++);
    tabs.update(a.id, title: 'Boletín');
    tabs.update(a.id, title: 'Boletín');
    tabs.update(a.id, url: _b);
    expect(calls, 2);
    expect(a.name, 'Boletín');
    expect(BrowserTabs().open(url: _c).name, 'tienda.ejemplo.dev');
  });
}
