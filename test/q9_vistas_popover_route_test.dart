// gint72: the chat's «Vistas» popover is a menu over the chat, not a page.
// The app's RouteObserver watches pages; a chat under a page that closes
// re-reads its transcript, profile and model (`didPopNext`). The notch's
// sheet before it was a popup and never did; the popover must not either.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart'
    show showHermesSurface;
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// A page that counts what a chat reacts to.
class _Watcher extends StatefulWidget {
  const _Watcher({required this.observer, required this.child});

  final RouteObserver<PageRoute<dynamic>> observer;
  final Widget child;

  @override
  State<_Watcher> createState() => _WatcherState();
}

class _WatcherState extends State<_Watcher> with RouteAware {
  int covered = 0;
  int returned = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic>) widget.observer.subscribe(this, route);
  }

  @override
  void dispose() {
    widget.observer.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPushNext() => covered++;

  @override
  void didPopNext() => returned++;

  @override
  Widget build(BuildContext context) => widget.child;
}

const _open = ValueKey('test-open');

Future<_WatcherState> _pump(
  WidgetTester tester,
  void Function(BuildContext context) open,
) async {
  final observer = RouteObserver<PageRoute<dynamic>>();
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      navigatorObservers: [observer],
      home: _Watcher(
        observer: observer,
        child: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => TextButton(
                key: _open,
                onPressed: () => open(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return tester.state<_WatcherState>(find.byType(_Watcher));
}

Future<void> _openAndClose(WidgetTester tester, Key surface) async {
  await tester.tap(find.byKey(_open));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.byKey(surface), findsOneWidget);
  await tester.binding.handlePopRoute();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.byKey(surface), findsNothing);
}

void main() {
  testWidgets('the «Vistas» popover opens and closes without the page under '
      'it being told it was left', (tester) async {
    final c = ChatWorkspaceController();
    addTearDown(c.dispose);
    final page = await _pump(
      tester,
      (context) => showChatWorkspaceViews(
        context,
        controller: c,
        availableTabs: const [ChatWorkspaceTab.terminal],
      ),
    );
    await _openAndClose(tester, const ValueKey('chat-workspace-views'));
    expect(page.covered, 0);
    expect(page.returned, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the control: a surface that covers the page (the default) is '
      'a page, and the page under it hears it', (tester) async {
    const key = ValueKey('test-surface');
    final page = await _pump(
      tester,
      (context) => showHermesSurface<void>(
        context: context,
        surfaceKey: key,
        builder: (_) => const SizedBox(height: 120),
      ),
    );
    await _openAndClose(tester, key);
    expect(page.covered, 1);
    expect(page.returned, 1);
  });
}
