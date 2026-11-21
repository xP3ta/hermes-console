// 1.4.3 (the owner: «how the side panels look and work»): every panel of
// the workspace has the Terminal's look, its context line over a rounded
// card with a hairline, at every width (a phone, the 600-840 dp rail, the
// split), with text at 200 % and in both themes; the Browser has one row
// over its card, not a strip and a bar stacked under the pane's bar.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/browser/browser_tabs.dart';
import 'package:hermes_android/core/browser/in_app_tabbed_browser.dart';
import 'package:hermes_android/core/design/hicons.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/models/git_review.dart';
import 'package:hermes_android/core/screens/git_review_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/core/widgets/workspace/workspace_panel_frame.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'support/fake_git_review_gateway.dart';
import 'support/fake_webview_platform.dart';

const _card = ValueKey('workspace-panel-card');
const _header = ValueKey('workspace-panel-header');
const _paneClip = ValueKey('chat-workspace-panel-clip');

Widget _git() => ChatWorkspacePanel(
  header: const ChatWorkspacePanelHeader(
    icon: HIcons.call_split_rounded,
    title: '/srv/a-rather-long-folder-name/with/more/below/it',
    detail: 'Remote server',
  ),
  child: GitReviewScreen(
    gateway: FakeGitReviewGateway(
      status: const GitRepoStatus(branch: 'main', changed: 2),
      files: const [
        GitReviewFile(path: 'lib/a.dart', status: 'M'),
        GitReviewFile(path: 'README.md', status: 'A'),
      ],
    ),
    connectionId: 'c1',
    repoPath: '/srv/a-rather-long-folder-name/with/more/below/it',
  ),
);

Widget _files() => const ChatWorkspacePanel(
  header: ChatWorkspacePanelHeader(
    icon: HIcons.folder_open_outlined,
    title: 'Remote server',
    mono: false,
    tag: 'SFTP',
  ),
  child: SizedBox.expand(key: ValueKey('fake-files-body')),
);

Future<ChatWorkspaceController> _pump(
  WidgetTester tester, {
  required double width,
  required ThemeData theme,
  double textScale = 1,
  BrowserTabs? tabs,
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = Size(width, 800);
  addTearDown(tester.view.reset);
  final c = ChatWorkspaceController();
  addTearDown(c.dispose);
  final browserTabs = tabs ?? BrowserTabs();
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: const [
        Strings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: Strings.supportedLocales,
      theme: theme,
      builder: (context, home) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: home!,
      ),
      home: ChatWorkspaceHost(
        controller: c,
        chat: const Scaffold(body: SizedBox.expand()),
        availableTabs: const [
          ChatWorkspaceTab.files,
          ChatWorkspaceTab.git,
          ChatWorkspaceTab.browser,
        ],
        tabBuilder: (_, tab) => switch (tab) {
          ChatWorkspaceTab.git => _git(),
          ChatWorkspaceTab.browser => InAppTabbedBrowser(tabs: browserTabs),
          _ => _files(),
        },
      ),
    ),
  );
  return c;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() => WebViewPlatform.instance = FakeWebViewPlatform());

  testWidgets('outside the pane a panel is its screen alone; inside it, '
      'the Terminal\'s context line over its card', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.hermesRedDark,
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(height: 300, child: _files()),
              SizedBox(
                height: 300,
                child: ChatWorkspacePaneScope(
                  tab: ChatWorkspaceTab.files,
                  child: _files(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final bodies = find.byKey(const ValueKey('fake-files-body'));
    expect(bodies, findsNWidgets(2));
    expect(find.byKey(_card), findsOneWidget);
    expect(find.byKey(_header), findsOneWidget);
    // The bare one has neither around it.
    expect(
      find.ancestor(of: bodies.first, matching: find.byKey(_card)),
      findsNothing,
    );
    final card = tester.widget<DecoratedBox>(find.byKey(_card));
    final decoration = card.decoration as BoxDecoration;
    expect(
      decoration.borderRadius,
      BorderRadius.circular(ChatWorkspaceTokens.cardRadius),
    );
    expect(card.position, DecorationPosition.foreground);
    expect(decoration.border, isNotNull);
    // The Terminal's margins: the pane's inset at the card's sides.
    final pane = tester.getRect(
      find.byType(ChatWorkspacePanel).last,
    );
    final cardRect = tester.getRect(find.byKey(_card));
    expect(cardRect.left - pane.left, ChatWorkspaceTokens.inset);
    expect(pane.right - cardRect.right, ChatWorkspaceTokens.inset);
    expect(pane.bottom - cardRect.bottom, HermesSpace.x2);
    expect(
      tester.getRect(find.byKey(_header)).bottom + HermesSpace.x1,
      cardRect.top,
    );
    expect(find.text('SFTP'), findsOneWidget);
  });

  for (final width in const [360.0, 700.0, 1000.0]) {
    for (final (name, theme) in [
      ('dark', AppTheme.hermesRedDark),
      ('light', AppTheme.hermesRedLight),
    ]) {
      for (final scale in const [1.0, 2.0]) {
        testWidgets('${width.toInt()} dp, $name, text ${scale}x: Files, Git '
            'and the Browser sit in one card inside the pane', (
          tester,
        ) async {
          final c = await _pump(
            tester,
            width: width,
            theme: theme,
            textScale: scale,
          );
          for (final tab in const [
            ChatWorkspaceTab.files,
            ChatWorkspaceTab.git,
            ChatWorkspaceTab.browser,
          ]) {
            c.open(tab);
            await _settle(tester);
            expect(tester.takeException(), isNull, reason: tab.name);
            final pane = tester.getRect(find.byKey(_paneClip));
            final card = find.byKey(_card);
            expect(card, findsOneWidget, reason: tab.name);
            final rect = tester.getRect(card);
            expect(
              rect.left,
              greaterThanOrEqualTo(pane.left),
              reason: tab.name,
            );
            expect(
              rect.right,
              lessThanOrEqualTo(pane.right),
              reason: tab.name,
            );
            expect(rect.bottom, lessThanOrEqualTo(pane.bottom));
            expect(rect.height, greaterThan(pane.height * 0.4));
            if (tab == ChatWorkspaceTab.browser) {
              // One row over the card: the browser's bar, with the count
              // of tabs in it; no strip of its own.
              expect(
                find.byKey(const ValueKey('browser-tab-strip')),
                findsNothing,
              );
              final bar = tester.getRect(
                find.byKey(const ValueKey('in-app-browser-bar')),
              );
              expect(bar.bottom, lessThanOrEqualTo(rect.top));
              expect(
                find.descendant(
                  of: find.byKey(const ValueKey('in-app-browser-bar')),
                  matching: find.byKey(const ValueKey('browser-tab-count')),
                ),
                findsOneWidget,
              );
            } else {
              final header = tester.getRect(find.byKey(_header));
              expect(header.bottom, lessThanOrEqualTo(rect.top));
              expect(header.left, greaterThanOrEqualTo(pane.left));
              expect(header.right, lessThanOrEqualTo(pane.right));
            }
          }
        });
      }
    }
  }

  testWidgets('the Browser\'s count in the pane opens every tab', (
    tester,
  ) async {
    final tabs = BrowserTabs()
      ..open(url: Uri.parse('https://one.example.invalid/'))
      ..open(url: Uri.parse('https://two.example.invalid/'));
    final c = await _pump(
      tester,
      width: 1000,
      theme: AppTheme.hermesRedDark,
      tabs: tabs,
    );
    c.open(ChatWorkspaceTab.browser);
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('browser-tab-count')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('browser-tab-grid')), findsOneWidget);
    for (final tab in tabs.tabs) {
      expect(
        find.byKey(ValueKey('browser-tab-card-${tab.id}')),
        findsOneWidget,
      );
    }
    expect(tester.takeException(), isNull);
  });
}
