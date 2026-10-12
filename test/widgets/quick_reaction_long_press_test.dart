import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/chat/chat_message_frame.dart';
import 'package:hermes_android/core/widgets/chat/chat_message_selection_area.dart';
import 'package:hermes_android/core/widgets/chat/quick_reaction_bar.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// rr1215: long-press on a message that can take a reaction opens ONE
/// surface (quick reactions on top of the message actions). Text selection
/// starts only from «Select text» (or a double-tap, as before): no handles
/// or selection toolbar while the reactions are open, and the surface never
/// covers the pressed message.
const _text = 'Una respuesta del bot con varias palabras';

Widget _host({
  ValueChanged<String>? onReact,
  String? selected,
  String Function()? copyText,
  VoidCallback? onReply,
  Alignment alignment = Alignment.center,
  bool frame = false,
  bool field = false,
}) {
  final Widget message = frame
      // Chat answers and room member cards: header + body in one frame,
      // laid out with unbounded height as in a transcript list.
      ? const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ChatMessageFrame(header: Text('builder'), children: [Text(_text)]),
          ],
        )
      : const ChatMessageSelectionArea(child: Text(_text));
  return MaterialApp(
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    locale: const Locale('en'),
    home: Scaffold(
      appBar: field
          ? AppBar(title: const TextField(key: ValueKey('other-field')))
          : null,
      body: Align(
        alignment: alignment,
        child: onReact == null
            ? message
            : MessageQuickReactScope(
                onReact: onReact,
                selected: selected,
                copyText: copyText,
                onReply: onReply,
                replyLabel: onReply == null ? null : 'Reply to @builder',
                child: message,
              ),
      ),
    ),
  );
}

final _bar = find.byKey(const ValueKey('quick-reaction-bar'));
final _surface = find.byKey(const ValueKey('message-actions-surface'));
final _select = find.byKey(const ValueKey('message-action-select'));
final _copy = find.byKey(const ValueKey('message-action-copy'));
final _reply = find.byKey(const ValueKey('message-action-reply'));

SelectableRegionState _region(WidgetTester tester) => tester
    .state<SelectionAreaState>(find.byType(SelectionArea))
    .selectableRegion;

/// Records what reaches the clipboard.
List<String?> _clipboard(WidgetTester tester) {
  final writes = <String?>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        writes.add((call.arguments as Map)['text'] as String?);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return writes;
}

void main() {
  testWidgets('long-press opens the reactions on top of the actions, with '
      'no selection, handles or selection toolbar', (tester) async {
    await tester.pumpWidget(_host(onReact: (_) {}, copyText: () => _text));
    await tester.longPress(find.text(_text));
    await tester.pumpAndSettle();

    expect(_surface, findsOneWidget);
    expect(find.descendant(of: _surface, matching: _bar), findsOneWidget);
    expect(
      find.descendant(of: _bar, matching: find.byType(InkWell)),
      findsNWidgets(6),
    );
    expect(_copy, findsOneWidget);
    expect(_select, findsOneWidget);
    expect(_reply, findsNothing, reason: 'nothing to reply to here');
    // Reactions first, the actions right under them.
    expect(
      tester.getRect(_bar).bottom,
      lessThanOrEqualTo(tester.getRect(_copy).top),
    );
    // The long-press started no text selection.
    expect(_region(tester).selectionOverlay, isNull);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    expect(find.byType(TextSelectionToolbar), findsNothing);
  });

  testWidgets('the surface sits above the pressed message and never covers '
      'its text', (tester) async {
    await tester.pumpWidget(_host(onReact: (_) {}, copyText: () => _text));
    await tester.longPress(find.text(_text));
    await tester.pumpAndSettle();
    final text = tester.getRect(find.text(_text));
    final surface = tester.getRect(_surface);
    expect(surface.bottom, lessThanOrEqualTo(text.top));
    expect(surface.overlaps(text), isFalse);
  });

  testWidgets('with no room above (message at the top) it goes below the '
      'message, still without covering it', (tester) async {
    await tester.pumpWidget(
      _host(
        onReact: (_) {},
        copyText: () => _text,
        alignment: Alignment.topCenter,
      ),
    );
    await tester.longPress(find.text(_text));
    await tester.pumpAndSettle();
    final text = tester.getRect(find.text(_text));
    final surface = tester.getRect(_surface);
    expect(surface.top, greaterThanOrEqualTo(text.bottom));
    expect(surface.overlaps(text), isFalse);
    expect(
      surface.bottom,
      lessThanOrEqualTo(tester.getRect(find.byType(Scaffold)).bottom),
    );
  });

  testWidgets('a framed message (header + body) keeps its header clear too', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(onReact: (_) {}, copyText: () => _text, frame: true),
    );
    await tester.longPress(find.text(_text));
    await tester.pumpAndSettle();
    expect(_surface, findsOneWidget);
    expect(_region(tester).selectionOverlay, isNull);
    final surface = tester.getRect(_surface);
    expect(surface.overlaps(tester.getRect(find.text('builder'))), isFalse);
    expect(surface.overlaps(tester.getRect(find.text(_text))), isFalse);
  });

  testWidgets('«Select text» closes the surface and starts the selection '
      'with handles and the selection toolbar', (tester) async {
    final clip = _clipboard(tester);
    await tester.pumpWidget(_host(onReact: (_) {}, copyText: () => _text));
    await tester.longPress(find.text(_text));
    await tester.pumpAndSettle();
    expect(_region(tester).selectionOverlay, isNull);
    await tester.tap(_select);
    await tester.pumpAndSettle();

    expect(_surface, findsNothing);
    expect(_bar, findsNothing, reason: 'no reactions over the selection');
    final region = _region(tester);
    expect(region.selectionOverlay, isNotNull);
    expect(region.selectionOverlay!.toolbarIsVisible, isTrue);
    final copy = region.contextMenuButtonItems.firstWhere(
      (item) => item.type == ContextMenuButtonType.copy,
    );
    copy.onPressed!();
    await tester.pumpAndSettle();
    expect(clip, [_text], reason: 'the whole message was selected');
  });

  testWidgets('the selection from «Select text» ends when focus moves on, '
      'like any selection', (tester) async {
    // A region only drops its selection on blur while the app is resumed.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      _host(onReact: (_) {}, copyText: () => _text, field: true),
    );
    await tester.longPress(find.text(_text));
    await tester.pumpAndSettle();
    await tester.tap(_select);
    await tester.pumpAndSettle();
    expect(_region(tester).selectionOverlay, isNotNull);
    await tester.tap(find.byKey(const ValueKey('other-field')));
    await tester.pumpAndSettle();
    expect(_region(tester).selectionOverlay, isNull);
  });

  testWidgets('«Copy» copies the message; «Reply» answers it', (tester) async {
    final clip = _clipboard(tester);
    var replies = 0;
    await tester.pumpWidget(
      _host(
        onReact: (_) {},
        copyText: () => 'texto plano del mensaje',
        onReply: () => replies++,
      ),
    );
    await tester.longPress(find.text(_text));
    await tester.pumpAndSettle();
    await tester.tap(_copy);
    await tester.pumpAndSettle();
    expect(clip, ['texto plano del mensaje']);
    expect(_surface, findsNothing);
    expect(_region(tester).selectionOverlay, isNull);

    await tester.longPress(find.text(_text));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _reply, matching: find.text('Reply to @builder')),
      findsOneWidget,
    );
    await tester.tap(_reply);
    await tester.pumpAndSettle();
    expect(replies, 1);
    expect(_surface, findsNothing);
  });

  testWidgets('a pick reacts and closes the surface', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(
      _host(onReact: picked.add, selected: '❤️', copyText: () => _text),
    );
    await tester.longPress(find.text(_text));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quick-reaction-🙏')));
    await tester.pumpAndSettle();
    expect(picked, ['🙏']);
    expect(_surface, findsNothing);
    expect(_bar, findsNothing);
    expect(_region(tester).selectionOverlay, isNull);
  });

  testWidgets('tapping outside closes the surface without reacting', (
    tester,
  ) async {
    final picked = <String>[];
    await tester.pumpWidget(_host(onReact: picked.add, copyText: () => _text));
    await tester.longPress(find.text(_text));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(4, 590));
    await tester.pumpAndSettle();
    expect(_surface, findsNothing);
    expect(picked, isEmpty);
    expect(_region(tester).selectionOverlay, isNull);
  });

  testWidgets('double-tap still selects a word directly', (tester) async {
    await tester.pumpWidget(_host(onReact: (_) {}, copyText: () => _text));
    final at = tester.getCenter(find.text(_text));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(at);
    await tester.pumpAndSettle();
    expect(_surface, findsNothing);
    expect(_region(tester).selectionOverlay, isNotNull);
  });

  testWidgets('control: without a reaction scope long-press is the plain '
      'selection menu', (tester) async {
    await tester.pumpWidget(_host());
    await tester.longPress(find.text(_text));
    await tester.pumpAndSettle();
    expect(_bar, findsNothing);
    expect(_surface, findsNothing);
    expect(_region(tester).selectionOverlay, isNotNull);
  });
}
