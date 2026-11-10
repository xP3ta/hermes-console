import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('ChatWorkspaceController', () {
    test('starts as the plain chat; opening a tab splits', () {
      final c = ChatWorkspaceController();
      expect(c.hasWorkspace, isFalse);
      expect(c.mode, ChatWorkspaceMode.chat);

      c.open(ChatWorkspaceTab.terminal);
      expect(c.tabs, [ChatWorkspaceTab.terminal]);
      expect(c.active, ChatWorkspaceTab.terminal);
      expect(c.mode, ChatWorkspaceMode.split);

      c.open(ChatWorkspaceTab.files);
      c.open(ChatWorkspaceTab.terminal);
      expect(c.tabs, [ChatWorkspaceTab.terminal, ChatWorkspaceTab.files]);
      expect(c.active, ChatWorkspaceTab.terminal);
    });

    test('closing hands over to the right, then the left (Desktop)', () {
      final c = ChatWorkspaceController()
        ..open(ChatWorkspaceTab.terminal)
        ..open(ChatWorkspaceTab.files)
        ..activate(ChatWorkspaceTab.terminal);

      c.close(ChatWorkspaceTab.terminal);
      expect(c.active, ChatWorkspaceTab.files);
      expect(c.closed, [ChatWorkspaceTab.terminal]);

      c
        ..open(ChatWorkspaceTab.terminal)
        ..activate(ChatWorkspaceTab.terminal);
      // terminal is now last: the left neighbour takes over.
      c.close(ChatWorkspaceTab.terminal);
      expect(c.active, ChatWorkspaceTab.files);
    });

    test('closing the last tab gives the chat the whole screen', () {
      final c = ChatWorkspaceController()..open(ChatWorkspaceTab.terminal);
      c.setMode(ChatWorkspaceMode.workspace);
      c.close(ChatWorkspaceTab.terminal);
      expect(c.hasWorkspace, isFalse);
      expect(c.active, isNull);
      expect(c.mode, ChatWorkspaceMode.chat);
    });

    test('modes need a tab; expand toggles workspace only and split', () {
      final c = ChatWorkspaceController();
      c.setMode(ChatWorkspaceMode.split);
      expect(c.mode, ChatWorkspaceMode.chat);

      c.open(ChatWorkspaceTab.files);
      c.toggleExpanded();
      expect(c.mode, ChatWorkspaceMode.workspace);
      c.toggleExpanded();
      expect(c.mode, ChatWorkspaceMode.split);
      c.setMode(ChatWorkspaceMode.chat);
      expect(c.mode, ChatWorkspaceMode.chat);
      // Opening a tab from chat-only shows the workspace again.
      c.open(ChatWorkspaceTab.files);
      expect(c.mode, ChatWorkspaceMode.split);
    });

    // the owner, Fold horizontal (APK 9708): the split is remembered per kind of
    // panel. The Terminal and the Browser start with the chat at its floor;
    // Files and Git at 58/42.
    test('ratio: per panel defaults, clamp, saved on commit, reset', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ChatWorkspaceController(prefs: prefs);
      String key(ChatWorkspaceTab tab) =>
          ChatWorkspaceController.ratioKeyFor(tab);

      expect(c.ratioFor(ChatWorkspaceTab.terminal), 0.25);
      expect(c.ratioFor(ChatWorkspaceTab.browser), 0.25);
      expect(c.ratioFor(ChatWorkspaceTab.files), 0.58);
      expect(c.ratioFor(ChatWorkspaceTab.git), 0.58);

      // Nothing open: no panel to size.
      c.setRatio(0.5);
      expect(c.storedRatio, isNull);

      c.open(ChatWorkspaceTab.files);
      c.setRatio(0.9);
      expect(c.storedRatio, 0.70);
      c.setRatio(0.1);
      expect(c.storedRatio, 0.25);
      expect(prefs.getDouble(key(ChatWorkspaceTab.files)), isNull);
      c.setRatio(0.5);
      c.commitRatio();
      expect(prefs.getDouble(key(ChatWorkspaceTab.files)), 0.5);
      expect(c.ratioFor(), 0.5);
      // The Terminal keeps its own.
      expect(c.ratioFor(ChatWorkspaceTab.terminal), 0.25);
      expect(prefs.getDouble(key(ChatWorkspaceTab.terminal)), isNull);

      final reloaded = ChatWorkspaceController(prefs: prefs);
      expect(reloaded.ratioFor(ChatWorkspaceTab.files), 0.5);
      expect(reloaded.ratioFor(ChatWorkspaceTab.git), 0.58);

      c.resetRatio();
      expect(c.storedRatio, isNull);
      expect(c.ratioFor(), 0.58);
      expect(prefs.getDouble(key(ChatWorkspaceTab.files)), isNull);
    });

    test('a stored ratio out of range is clamped on load', () async {
      SharedPreferences.setMockInitialValues({
        ChatWorkspaceController.ratioKeyFor(ChatWorkspaceTab.terminal): 0.95,
      });
      final prefs = await SharedPreferences.getInstance();
      expect(
        ChatWorkspaceController(
          prefs: prefs,
        ).ratioFor(ChatWorkspaceTab.terminal),
        0.70,
      );
    });

    test('the old shared ratio is dropped on load', () async {
      SharedPreferences.setMockInitialValues({
        ChatWorkspaceController.legacyRatioKey: 0.44,
      });
      final prefs = await SharedPreferences.getInstance();
      final c = ChatWorkspaceController(prefs: prefs);
      expect(c.ratioFor(ChatWorkspaceTab.files), 0.58);
      expect(
        prefs.containsKey(ChatWorkspaceController.legacyRatioKey),
        isFalse,
      );
    });

    test('canSplit follows the width the host last laid out at', () {
      final c = ChatWorkspaceController();
      expect(c.canSplit, isFalse);
      c.layoutWidth = 412;
      expect(c.canSplit, isFalse);
      c.layoutWidth = 839;
      expect(c.canSplit, isFalse);
      c.layoutWidth = 840;
      expect(c.canSplit, isTrue);
      c.layoutWidth = 933;
      expect(c.canSplit, isTrue);
    });
  });

  group('ChatWorkspaceGeometry', () {
    test('tablet 1280 dp at 0.42', () {
      final g = ChatWorkspaceGeometry.compute(width: 1280, ratio: 0.42);
      // (1280 - 2 * 10 - 14) * 0.42 = 523.3
      expect(g.chatWidth, 523);
      expect(g.dividerWidth, 14);
      expect(g.chatWidth + g.dividerWidth + g.workspaceWidth, 1260);
      expect(g.lockedToHinge, isFalse);
    });

    // the owner (APK 9708): 0.44 gave the chat 396 dp of the open Fold.
    test('Fold 933 dp: the chat never below 480 dp beside a panel', () {
      final g = ChatWorkspaceGeometry.compute(width: 933, ratio: 0.44);
      expect(g.chatWidth, 480);
      expect(g.workspaceWidth, 933 - 20 - 14 - 480);
      // Files and Git: 58/42 of the 899 dp the panes share.
      expect(
        ChatWorkspaceGeometry.compute(width: 933, ratio: 0.58).chatWidth,
        521,
      );
      // The Terminal at its default: the chat at its floor.
      expect(
        ChatWorkspaceGeometry.compute(
          width: 933,
          ratio: ChatWorkspaceController.defaultRatioFor(
            ChatWorkspaceTab.terminal,
          ),
        ).chatWidth,
        480,
      );
    });

    test('ratio limits, the 480 dp chat and the 280 dp panel', () {
      expect(
        ChatWorkspaceGeometry.compute(width: 1280, ratio: 0).chatWidth,
        480, // 0.25 * 1246 = 312, below the chat's floor
      );
      expect(
        ChatWorkspaceGeometry.compute(width: 1280, ratio: 1).chatWidth,
        872, // 0.70 * 1246
      );
      final narrow = ChatWorkspaceGeometry.compute(width: 840, ratio: 0.25);
      expect(narrow.chatWidth, 480);
      expect(narrow.workspaceWidth, greaterThanOrEqualTo(280));
      // The panel never goes below its own floor either.
      final wide = ChatWorkspaceGeometry.compute(width: 933, ratio: 0.70);
      expect(wide.workspaceWidth, 280);
    });

    test('too narrow for 480 dp and a panel: a fixed 58/42', () {
      // 700 dp: 666 dp to share; 480 + 280 do not fit.
      final g = ChatWorkspaceGeometry.compute(width: 700, ratio: 0.25);
      expect(g.chatWidth, 386); // 0.58 * 666
      expect(g.workspaceWidth, 280);
      expect(
        ChatWorkspaceGeometry.compute(width: 700, ratio: 0.70).chatWidth,
        386,
      );
    });

    test('a hinge decides the split', () {
      final g = ChatWorkspaceGeometry.compute(
        width: 1280,
        ratio: 0.42,
        hinge: const Rect.fromLTWH(630, 0, 20, 800),
      );
      expect(g.lockedToHinge, isTrue);
      expect(g.dividerWidth, 20);
      expect(g.chatWidth, 620);
      // The chat ends where the hinge starts (10 dp padding on the left)
      // and the workspace begins where it ends.
      expect(10 + g.chatWidth, 630);
      expect(10 + g.chatWidth + g.dividerWidth, 650);
    });

    test('ratioForChatWidth inverts compute', () {
      final ratio = ChatWorkspaceGeometry.ratioForChatWidth(623, 1280);
      expect(
        ChatWorkspaceGeometry.compute(width: 1280, ratio: ratio).chatWidth,
        623,
      );
    });
  });

  group('chatWorkspaceHinge', () {
    const window = Size(1280, 800);

    test('an occluding vertical hinge counts', () {
      const hinge = DisplayFeature(
        bounds: Rect.fromLTWH(630, 0, 20, 800),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.unknown,
      );
      expect(chatWorkspaceHinge(const [hinge], window), hinge.bounds);
    });

    test('a fold counts only half open', () {
      const flat = DisplayFeature(
        bounds: Rect.fromLTWH(640, 0, 0, 800),
        type: DisplayFeatureType.fold,
        state: DisplayFeatureState.postureFlat,
      );
      const book = DisplayFeature(
        bounds: Rect.fromLTWH(640, 0, 0, 800),
        type: DisplayFeatureType.fold,
        state: DisplayFeatureState.postureHalfOpened,
      );
      expect(chatWorkspaceHinge(const [flat], window), isNull);
      expect(chatWorkspaceHinge(const [book], window), book.bounds);
    });

    test('horizontal folds and cutouts are ignored', () {
      const horizontal = DisplayFeature(
        bounds: Rect.fromLTWH(0, 400, 1280, 0),
        type: DisplayFeatureType.fold,
        state: DisplayFeatureState.postureHalfOpened,
      );
      const cutout = DisplayFeature(
        bounds: Rect.fromLTWH(600, 0, 80, 800),
        type: DisplayFeatureType.cutout,
        state: DisplayFeatureState.unknown,
      );
      expect(chatWorkspaceHinge(const [horizontal, cutout], window), isNull);
    });
  });

  test('two panes only from 840 dp', () {
    expect(chatWorkspaceSplitFits(412), isFalse);
    expect(chatWorkspaceSplitFits(800), isFalse);
    expect(chatWorkspaceSplitFits(840), isTrue);
    expect(chatWorkspaceSplitFits(933), isTrue);
    expect(chatWorkspaceSplitFits(1280), isTrue);
  });

  // the owner's «Vistas» (mock 134): one controller for the list, the chat and
  // the workspace.
  group('views (list, chat, workspace)', () {
    ChatWorkspaceController chats(double width, {SharedPreferences? prefs}) =>
        ChatWorkspaceController(
            prefs: prefs,
            screen: ChatWorkspaceScreen.chats,
          )
          ..windowWidth = width;

    test('open Fold: two views; opening the workspace folds the list', () {
      final c = chats(933);
      expect(c.maxViews, 2);
      expect(c.visibleViews, [ChatWorkspaceView.list, ChatWorkspaceView.chat]);
      c.open(ChatWorkspaceTab.terminal);
      expect(c.visibleViews, [
        ChatWorkspaceView.chat,
        ChatWorkspaceView.workspace,
      ]);
      expect(c.canSplit, isTrue);
    });

    test('tablet: three views from 1141 dp (list + a split that fits)', () {
      expect(chats(1280).maxViews, 3);
      // ≥ 1100 but 300 dp of list leave less than 840 to split.
      expect(chats(1120).maxViews, 2);
      final c = chats(1280)..open(ChatWorkspaceTab.files);
      expect(c.visibleViews, ChatWorkspaceView.values);
    });

    test('the chat hides only while the workspace shows', () {
      final c = chats(933)..setViewVisible(ChatWorkspaceView.chat, false);
      expect(c.chatVisible, isTrue);
      expect(c.canHide(ChatWorkspaceView.chat), isFalse);
      c
        ..open(ChatWorkspaceTab.terminal)
        ..setViewVisible(ChatWorkspaceView.chat, false);
      expect(c.chatVisible, isFalse);
      expect(c.mode, ChatWorkspaceMode.workspace);
      // Turning the workspace off brings the chat back: never no view.
      c.setViewVisible(ChatWorkspaceView.workspace, false);
      expect(c.chatVisible, isTrue);
      expect(c.workspaceVisible, isFalse);
    });

    test('turning a view on folds the least recently turned on', () {
      final c = chats(933)..open(ChatWorkspaceTab.terminal);
      // chat (older) and workspace show; the list comes back: the chat,
      // the least recent, makes way (the workspace keeps the screen).
      c.setViewVisible(ChatWorkspaceView.list, true);
      expect(c.visibleViews, [
        ChatWorkspaceView.list,
        ChatWorkspaceView.workspace,
      ]);
      // And the chat back: now the workspace is the least recent.
      c.setViewVisible(ChatWorkspaceView.chat, true);
      expect(c.visibleViews, [ChatWorkspaceView.list, ChatWorkspaceView.chat]);
    });

    test('the list button: a column when there is room, else over', () {
      final c = chats(933)..toggleList();
      expect(c.listVisible, isFalse);
      c.toggleList();
      expect(c.listVisible, isTrue);
      c
        ..open(ChatWorkspaceTab.terminal)
        ..toggleList();
      // Chat + workspace fill the Fold: the list comes over them.
      expect(c.listVisible, isFalse);
      expect(c.listOverlay, isTrue);
      expect(c.workspaceVisible, isTrue);
      c.chatOpened();
      expect(c.listOverlay, isFalse);
    });

    test('upright Fold: nothing side by side; the list only over the chat, '
        'and turning the device loses no choice', () {
      final c = chats(933)..open(ChatWorkspaceTab.terminal);
      c.updateWindowWidth(657);
      expect(c.stacked, isTrue);
      expect(c.listVisible, isFalse);
      c.toggleList();
      expect(c.listOverlay, isTrue);
      // Back on its side: the overlay belonged to the upright layout; the
      // split is still there.
      expect(c.updateWindowWidth(933), isTrue);
      expect(c.listOverlay, isFalse);
      expect(c.workspaceVisible, isTrue);
      expect(c.mode, ChatWorkspaceMode.split);
    });

    test('a tablet folding to a Fold-sized window folds the oldest view', () {
      final c = chats(1280)..open(ChatWorkspaceTab.terminal);
      expect(c.visibleViews.length, 3);
      expect(c.updateWindowWidth(933), isTrue);
      expect(c.visibleViews, [
        ChatWorkspaceView.chat,
        ChatWorkspaceView.workspace,
      ]);
    });

    test('the list and the tab are remembered per kind of screen', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      chats(933, prefs: prefs)
        ..toggleList()
        ..open(ChatWorkspaceTab.git);
      final again = chats(933, prefs: prefs);
      expect(again.listVisible, isFalse);
      expect(again.preferredTab, ChatWorkspaceTab.git);
      // A chat on its own has its own memory.
      final alone = ChatWorkspaceController(prefs: prefs);
      expect(alone.preferredTab, isNull);
      expect(alone.hasList, isFalse);
    });
  });
}
