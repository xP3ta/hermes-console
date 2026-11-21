// The SSH terminal under the finger (1.4.3): xterm's view with what a phone
// needs around it. Selection with handles and a toolbar (Copy, Paste,
// Select all, Copy screen, and the link under a long press), one finger
// scrolling the scrollback (never arrow keys in a full-screen program),
// two fingers paging, a pinch for the font size, tappable web addresses,
// the answers to a y/n or numbered question, a «jump to bottom» chip and
// Ctrl+Shift+C / Ctrl+Shift+V on a hardware keyboard. The clipboard is
// written only when the user asks; nothing the terminal shows is logged.
import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hermes_android/core/design/hicons.dart';
import 'package:xterm/xterm.dart';

import '../../l10n/app_localizations.dart';
import '../feedback/feedback_policy.dart';
import '../feedback/haptics.dart';
import '../services/ssh_terminal_input.dart';
import '../services/ssh_terminal_text.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';

/// What the current touch sequence turned out to be.
enum _Gesture { none, scroll, pinch, page }

/// The terminal view with its touch layer. Same tree for the life of the
/// screen: the [TerminalView] is never rebuilt from scratch.
class SshTerminalSurface extends StatefulWidget {
  const SshTerminalSurface({
    required this.terminal,
    required this.theme,
    required this.fontSize,
    this.modifiers,
    this.onFontSize,
    this.onOpenLink,
    this.autofocus = false,
    this.readOnly = false,
    super.key,
  });

  final Terminal terminal;
  final TerminalTheme theme;

  /// The font size the terminal is drawn at.
  final double fontSize;

  /// The key row's Ctrl and Alt: a paste and the keys sent from here go
  /// past them.
  final SshKeyModifiers? modifiers;

  /// A pinch asks for this size (whole points, within [minFontSize] and
  /// [maxFontSize]); no pinch zoom when null.
  final ValueChanged<double>? onFontSize;

  /// A web address in the terminal was tapped (or «Open link» chosen).
  final ValueChanged<Uri>? onOpenLink;

  final bool autofocus;

  /// The session is not ready: nothing is sent, the text can still be read
  /// and copied.
  final bool readOnly;

  static const double minFontSize = 8;
  static const double maxFontSize = 24;

  /// How far two fingers travel for one page.
  static const double pageTravel = 2 * HermesSpace.tap;

  @override
  State<SshTerminalSurface> createState() => SshTerminalSurfaceState();
}

class SshTerminalSurfaceState extends State<SshTerminalSurface> {
  final TerminalController _controller = TerminalController();
  final ScrollController _scroll = ScrollController();
  final GlobalKey<TerminalViewState> _view = GlobalKey<TerminalViewState>();
  final GlobalKey _stack = GlobalKey();
  final ContextMenuController _menu = ContextMenuController();

  /// Pointers down on the terminal and where the sequence began.
  final Set<int> _pointers = {};
  Offset? _pressAt;
  DateTime? _pressTime;
  bool _pressMoved = false;
  bool _selectionAtDown = false;
  bool _multiTouch = false;

  /// The address under the finger when the press began.
  Uri? _pressLink;

  /// The menu was opened by a long press on no word: anchored there.
  Offset? _menuAt;
  Uri? _menuLink;

  _Gesture _gesture = _Gesture.none;
  double _startFont = 0;
  double _pageTravel = 0;
  double _lineTravel = 0;

  /// A selection handle is being dragged: no menu meanwhile.
  bool _handleDragging = false;
  Offset _handleGrab = Offset.zero;

  List<SshPromptAnswer>? _prompt;
  bool _scrolledUp = false;
  bool _refreshScheduled = false;

  /// The selection being shown, for tests and the screen.
  @visibleForTesting
  TerminalController get controller => _controller;

  @override
  void initState() {
    super.initState();
    widget.terminal.addListener(_scheduleRefresh);
    _controller.addListener(_onSelection);
    _scroll.addListener(_scheduleRefresh);
    _prompt = _readPrompt();
  }

  @override
  void didUpdateWidget(SshTerminalSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.terminal, widget.terminal)) {
      oldWidget.terminal.removeListener(_scheduleRefresh);
      widget.terminal.addListener(_scheduleRefresh);
    }
    if (oldWidget.fontSize != widget.fontSize ||
        oldWidget.readOnly != widget.readOnly) {
      _scheduleRefresh();
    }
  }

  @override
  void dispose() {
    widget.terminal.removeListener(_scheduleRefresh);
    _controller.removeListener(_onSelection);
    _scroll.removeListener(_scheduleRefresh);
    _menu.remove();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ── geometry ──────────────────────────────────────────────────────────

  /// xterm's view, once its text is laid out.
  TerminalViewState? get _laidOut {
    final view = _view.currentState;
    if (view == null || !view.mounted) return null;
    final render = view.renderTerminal;
    return render.attached && render.hasSize ? view : null;
  }

  CellOffset? _cellAt(Offset global) {
    final render = _laidOut?.renderTerminal;
    if (render == null) return null;
    return render.getCellOffset(render.globalToLocal(global));
  }

  /// The top-left corner of [cell] in global coordinates.
  Offset? _globalOf(CellOffset cell) {
    final render = _laidOut?.renderTerminal;
    if (render == null) return null;
    return render.localToGlobal(render.getOffset(cell));
  }

  double get _lineHeight => _laidOut?.renderTerminal.lineHeight ?? 0;

  Rect? get _viewRect {
    final render = _laidOut?.renderTerminal;
    if (render == null) return null;
    return render.localToGlobal(Offset.zero) & render.size;
  }

  // ── state that follows the buffer ─────────────────────────────────────

  List<SshPromptAnswer>? _readPrompt() =>
      widget.readOnly ? null : sshTerminalPrompt(widget.terminal);

  /// The scrollback's position is laid out.
  bool get _hasScroll =>
      _scroll.hasClients && _scroll.position.hasContentDimensions;

  bool _readScrolledUp() {
    if (widget.terminal.isUsingAltBuffer || !_hasScroll) return false;
    final position = _scroll.position;
    final line = _lineHeight;
    return position.pixels < position.maxScrollExtent - math.max(line, 1);
  }

  /// Output, a scroll or a new font size: what depends on the buffer and
  /// on the layout is read again after the frame (once per frame).
  void _scheduleRefresh() {
    if (_refreshScheduled) return;
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (!mounted) return;
      final prompt = _readPrompt();
      final scrolledUp = _readScrolledUp();
      final selected = _controller.selection != null;
      if (!listEquals(prompt, _prompt) ||
          scrolledUp != _scrolledUp ||
          selected) {
        setState(() {
          _prompt = prompt;
          _scrolledUp = scrolledUp;
        });
      }
      if (_menu.isShown) _showMenu();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _onSelection() {
    if (_controller.selection == null) {
      _menu.remove();
      _menuAt = null;
    }
    _scheduleRefresh();
    if (mounted) setState(() {});
  }

  // ── pointers: taps, long presses, links ───────────────────────────────

  void _onPointerDown(PointerDownEvent event) {
    _pointers.add(event.pointer);
    if (_pointers.length > 1) {
      _multiTouch = true;
      return;
    }
    _pressAt = event.position;
    _pressTime = clock.now();
    _pressMoved = false;
    _multiTouch = false;
    _gesture = _Gesture.none;
    _selectionAtDown = _controller.selection != null;
    _menuLink = null;
    _menuAt = null;
    final cell = _cellAt(event.position);
    _pressLink = cell == null ? null : sshTerminalLinkAt(widget.terminal, cell);
    _menu.remove();
    // A finger on the terminal stops a fling.
    if (_scroll.hasClients && _scroll.position.hasPixels) {
      final position = _scroll.position;
      position.jumpTo(position.pixels);
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    final start = _pressAt;
    if (start != null && (event.position - start).distance > kTouchSlop) {
      _pressMoved = true;
    }
  }

  void _onPointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.isNotEmpty) return;
    final start = _pressTime;
    if (start == null || event is PointerCancelEvent) {
      _pressTime = null;
      return;
    }
    _pressTime = null;
    final held = clock.now().difference(start);
    final selected = _controller.selection != null;
    final still = !_pressMoved && !_multiTouch && _gesture == _Gesture.none;
    if (still && held < kLongPressTimeout) {
      // A tap. On a selection it only clears it (xterm does); on a word a
      // double tap selected, the menu opens; on an address, it opens.
      if (_selectionAtDown) return;
      if (selected) {
        _showMenu();
        return;
      }
      final link = _pressLink;
      if (link != null) widget.onOpenLink?.call(link);
      return;
    }
    if (_gesture == _Gesture.none &&
        !_multiTouch &&
        held >= kLongPressTimeout) {
      // A long press: xterm selected the word under it, or there was none
      // (a blank): the menu opens there all the same, for Paste.
      _menuLink = _pressLink;
      _menuAt = selected ? null : _pressAt;
      _showMenu();
      return;
    }
    if (selected) _showMenu();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (widget.terminal.isUsingAltBuffer) {
      _altScroll(-event.scrollDelta.dy, event.position);
    } else {
      _scrollBy(-event.scrollDelta.dy);
    }
  }

  // ── one finger scrolls, two page, a pinch zooms ───────────────────────

  void _onScaleStart(ScaleStartDetails details) {
    _gesture = _Gesture.none;
    _startFont = widget.fontSize;
    _pageTravel = 0;
    _lineTravel = 0;
    _menu.remove();
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final dy = details.focalPointDelta.dy;
    if (details.pointerCount >= 2) {
      if (_gesture == _Gesture.scroll || _gesture == _Gesture.none) {
        _gesture = _Gesture.none;
        if ((details.scale - 1).abs() > 0.12 && widget.onFontSize != null) {
          _gesture = _Gesture.pinch;
        } else {
          _pageTravel += dy;
          if (_pageTravel.abs() >= SshTerminalSurface.pageTravel) {
            _gesture = _Gesture.page;
          }
        }
      } else if (_gesture == _Gesture.page) {
        _pageTravel += dy;
      }
      switch (_gesture) {
        case _Gesture.pinch:
          const min = SshTerminalSurface.minFontSize;
          const max = SshTerminalSurface.maxFontSize;
          final size = (_startFont * details.scale).roundToDouble();
          final clamped = size.clamp(min, max).toDouble();
          if (clamped != widget.fontSize) widget.onFontSize?.call(clamped);
        case _Gesture.page:
          const travel = SshTerminalSurface.pageTravel;
          while (_pageTravel.abs() >= travel) {
            final back = _pageTravel > 0;
            _pageTravel -= back ? travel : -travel;
            _page(back: back);
          }
        case _Gesture.none:
        case _Gesture.scroll:
          break;
      }
      return;
    }
    // One finger left of a pinch or a page: the rest of it does nothing.
    if (_gesture == _Gesture.pinch || _gesture == _Gesture.page) return;
    _gesture = _Gesture.scroll;
    if (widget.terminal.isUsingAltBuffer) {
      _altScroll(dy, details.focalPoint);
    } else {
      _scrollBy(dy);
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (_gesture != _Gesture.scroll || widget.terminal.isUsingAltBuffer) {
      return;
    }
    if (!_hasScroll) return;
    final position = _scroll.position;
    if (position is ScrollPositionWithSingleContext) {
      position.goBallistic(-details.velocity.pixelsPerSecond.dy);
    }
  }

  /// Moves the scrollback as the finger moves ([dy] down shows older
  /// lines).
  void _scrollBy(double dy) {
    if (!_hasScroll) return;
    final position = _scroll.position;
    final target = (position.pixels - dy).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    position.jumpTo(target.toDouble());
  }

  /// One finger in a full-screen program. Mouse wheel reports when the
  /// program turned mouse reporting on (tmux with `mouse on`, vim with
  /// `mouse=a`, Herdr); arrow keys only when it asked for them (DECSET
  /// 1007, alternate scroll). Otherwise nothing: an arrow in a shell
  /// recalls history, so the swipe sends no keys of its own.
  void _altScroll(double dy, Offset at) {
    final line = _lineHeight;
    if (line <= 0 || widget.readOnly) return;
    _lineTravel += dy;
    while (_lineTravel.abs() >= line) {
      final up = _lineTravel > 0;
      _lineTravel -= up ? line : -line;
      final cell = _cellAt(at) ?? const CellOffset(0, 0);
      final terminal = widget.terminal;
      _unmodified(() {
        final wheel = sshWheelReport(terminal, up: up, cell: cell);
        if (wheel != null) {
          terminal.textInput(wheel);
        } else if (terminal.altBufferMouseScrollMode) {
          terminal.keyInput(up ? TerminalKey.arrowUp : TerminalKey.arrowDown);
        }
      });
    }
  }

  /// Two fingers: a page of scrollback, or Page Up / Page Down to a
  /// full-screen program (less, vim, man, htop, tmux's copy mode).
  void _page({required bool back}) {
    final terminal = widget.terminal;
    if (terminal.isUsingAltBuffer) {
      if (widget.readOnly) return;
      _unmodified(
        () => terminal.keyInput(
          back ? TerminalKey.pageUp : TerminalKey.pageDown,
        ),
      );
      return;
    }
    if (!_hasScroll) return;
    final position = _scroll.position;
    final page = math.max(position.viewportDimension - _lineHeight, 1.0);
    _scrollBy(back ? page : -page);
  }

  void _unmodified(VoidCallback send) {
    final modifiers = widget.modifiers;
    if (modifiers == null) {
      send();
    } else {
      modifiers.unmodified(send);
    }
  }

  // ── selection: handles and menu ───────────────────────────────────────

  /// The selection's ends, top-left corner of the first cell and of the
  /// cell after the last, in global coordinates.
  (Offset, Offset)? _selectionEnds() {
    final selection = _controller.selection?.normalized;
    if (selection == null) return null;
    final begin = _globalOf(selection.begin);
    final end = _globalOf(selection.end);
    if (begin == null || end == null) return null;
    return (begin, end);
  }

  void _showMenu() {
    if (!mounted || _handleDragging) return;
    final view = _viewRect;
    if (view == null) return;
    final selection = _controller.selection;
    final line = _lineHeight;
    Offset top;
    Offset bottom;
    final ends = _selectionEnds();
    if (selection != null && ends != null) {
      final (begin, end) = ends;
      final x = begin.dy == end.dy ? (begin.dx + end.dx) / 2 : view.center.dx;
      top = Offset(x, begin.dy);
      // Below, the menu clears the handles under the last line.
      final handle = materialTextSelectionControls.getHandleSize(line).height;
      bottom = Offset(x, end.dy + line + handle);
    } else if (_menuAt != null) {
      top = _menuAt!;
      bottom = _menuAt!;
    } else {
      return;
    }
    double clampY(double y) => y.clamp(view.top, view.bottom).toDouble();
    final anchors = TextSelectionToolbarAnchors(
      primaryAnchor: Offset(top.dx, clampY(top.dy)),
      secondaryAnchor: Offset(bottom.dx, clampY(bottom.dy)),
    );
    final link = _menuLink;
    _menu.show(
      context: context,
      contextMenuBuilder: (context) {
        final strings = Strings.of(context);
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: anchors,
          buttonItems: [
            if (_controller.selection != null)
              ContextMenuButtonItem(
                type: ContextMenuButtonType.copy,
                onPressed: () => unawaited(copySelection()),
              ),
            if (link != null) ...[
              ContextMenuButtonItem(
                label: strings.termUxOpenLink,
                onPressed: () {
                  _dismiss();
                  widget.onOpenLink?.call(link);
                },
              ),
              ContextMenuButtonItem(
                label: strings.termUxCopyLink,
                onPressed: () {
                  _dismiss();
                  unawaited(_copy(link.toString()));
                },
              ),
            ],
            if (!widget.readOnly)
              ContextMenuButtonItem(
                type: ContextMenuButtonType.paste,
                onPressed: () {
                  _dismiss();
                  unawaited(paste());
                },
              ),
            ContextMenuButtonItem(
              type: ContextMenuButtonType.selectAll,
              onPressed: _selectAll,
            ),
            ContextMenuButtonItem(
              label: strings.termUxCopyScreen,
              onPressed: () {
                _dismiss();
                unawaited(_copy(sshTerminalScreenText(widget.terminal)));
              },
            ),
          ],
        );
      },
    );
  }

  /// Closes the menu and lets the selection go.
  void _dismiss() {
    _menu.remove();
    _menuAt = null;
    _menuLink = null;
    if (_controller.selection != null) _controller.clearSelection();
  }

  Future<void> _copy(String text) async {
    if (text.isEmpty) return;
    final feedback = AppFeedback.of(context);
    final copied = Strings.of(context).termUxCopied;
    await Clipboard.setData(ClipboardData(text: text));
    feedback.notify(FeedbackKind.routine, copied);
  }

  /// Copies the selection (the toolbar's Copy, Ctrl+Shift+C) and lets it
  /// go. Nothing happens without one.
  Future<void> copySelection() async {
    final selection = _controller.selection;
    if (selection == null) return;
    final text = sshTerminalText(widget.terminal, selection);
    _dismiss();
    await _copy(text);
  }

  /// The clipboard into the shell (the toolbar's Paste, the Paste key,
  /// Ctrl+Shift+V), as one bracketed paste when the program asked for it.
  Future<void> paste() async {
    if (widget.readOnly) return;
    if (_controller.selection != null) _controller.clearSelection();
    await sshPasteClipboard(widget.terminal, modifiers: widget.modifiers);
  }

  /// The keyboard for typing straight into the terminal (the dock's
  /// keyboard key).
  void showKeyboard() => _view.currentState?.requestKeyboard();

  /// Puts the terminal's keyboard away.
  void hideKeyboard() {
    _view.currentState?.closeKeyboard();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _selectAll() {
    final terminal = widget.terminal;
    final range = sshTerminalAllRange(terminal);
    _menuAt = null;
    _controller.setSelection(
      terminal.buffer.createAnchorFromOffset(range.begin),
      terminal.buffer.createAnchorFromOffset(range.end),
      mode: SelectionMode.line,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _showMenu());
  }

  void _onHandleStart(DragStartDetails details, Offset anchor) {
    _handleDragging = true;
    _handleGrab = anchor - details.globalPosition;
    _menu.remove();
  }

  void _onHandleUpdate(DragUpdateDetails details, {required bool start}) {
    final selection = _controller.selection?.normalized;
    if (selection == null) return;
    // The point the finger holds, half a line above the handle's tip.
    final target =
        details.globalPosition + _handleGrab - Offset(0, _lineHeight / 2);
    final cell = _cellAt(target);
    if (cell == null) return;
    var begin = selection.begin;
    var end = selection.end;
    if (start) {
      begin = cell;
    } else {
      end = CellOffset(
        math.min(cell.x + 1, widget.terminal.viewWidth),
        cell.y,
      );
    }
    if (end.isBefore(begin)) {
      final swap = begin;
      begin = end;
      end = swap;
    }
    final buffer = widget.terminal.buffer;
    _controller.setSelection(
      buffer.createAnchorFromOffset(begin),
      buffer.createAnchorFromOffset(end),
      mode: SelectionMode.line,
    );
  }

  void _onHandleEnd() {
    _handleDragging = false;
    _showMenu();
  }

  // ── hardware keyboard ─────────────────────────────────────────────────

  /// Ctrl+Shift+C and Ctrl+Shift+V copy and paste, as desktop terminals
  /// do; physical navigation keys consume armed sticky modifiers (and
  /// modified arrows emit standard XTerm CSI sequences).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed && keyboard.isShiftPressed) {
      if (event.logicalKey == LogicalKeyboardKey.keyC) {
        unawaited(copySelection());
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyV) {
        unawaited(paste());
        return KeyEventResult.handled;
      }
    }
    if (widget.readOnly) return KeyEventResult.ignored;
    final termKey = sshTerminalKeyForLogical(event.logicalKey);
    final modifiers = widget.modifiers;
    if (termKey == null || modifiers == null) return KeyEventResult.ignored;
    final stickyArmed = modifiers.ctrl.armed.value || modifiers.alt.armed.value;
    final isArrow =
        termKey == TerminalKey.arrowUp ||
        termKey == TerminalKey.arrowDown ||
        termKey == TerminalKey.arrowLeft ||
        termKey == TerminalKey.arrowRight;
    final physicalModified =
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed;
    if (!stickyArmed && !(isArrow && physicalModified)) {
      return KeyEventResult.ignored;
    }
    sshSendModifiedKey(
      widget.terminal,
      modifiers,
      termKey,
      shift: keyboard.isShiftPressed,
      ctrl: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
    );
    return KeyEventResult.handled;
  }

  // ── build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final view = TerminalView(
      widget.terminal,
      key: _view,
      controller: _controller,
      scrollController: _scroll,
      // Desktop: light or dark palette with the app.
      theme: widget.theme,
      textStyle: TerminalStyle(fontSize: widget.fontSize),
      padding: const EdgeInsets.all(HermesSpace.x2),
      autofocus: widget.autofocus,
      readOnly: widget.readOnly,
      // U-03 (spec 028): con IME software (Gboard) el default
      // deleteDetection=false deja el editing state vacío y el
      // backspace nunca llega al terminal; y el keyboardType
      // emailAddress activa composición/autocorrección que corta la
      // entrada. visiblePassword = sin sugerencias (tradeoff: sin
      // swipe-typing, aceptable en un terminal; Compose has them).
      deleteDetection: true,
      keyboardType: TextInputType.visiblePassword,
      // The swipe is this widget's: xterm's would send arrow keys in a
      // full-screen program.
      simulateScroll: false,
      // xterm's defaults take Ctrl+A and Ctrl+V from the shell.
      shortcuts: const {},
      onKeyEvent: _onKey,
    );
    final touch = RawGestureDetector(
      gestures: {
        ScaleGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<ScaleGestureRecognizer>(
              () => ScaleGestureRecognizer(
                debugOwner: this,
                supportedDevices: const {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.stylus,
                  PointerDeviceKind.invertedStylus,
                },
              ),
              (recognizer) => recognizer
                ..onStart = _onScaleStart
                ..onUpdate = _onScaleUpdate
                ..onEnd = _onScaleEnd,
            ),
      },
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerUp,
        onPointerSignal: _onPointerSignal,
        // The terminal's own scrollables take no drags: one finger, two
        // and a pinch are read above.
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            scrollbars: false,
            overscroll: false,
            physics: const NeverScrollableScrollPhysics(
              parent: ClampingScrollPhysics(),
            ),
          ),
          child: view,
        ),
      ),
    );
    return Stack(
      key: _stack,
      children: [
        Positioned.fill(child: touch),
        ..._handles(context),
        if (_prompt != null) _promptChips(colors, strings),
        if (_scrolledUp)
          PositionedDirectional(
            start: 0,
            end: 0,
            bottom: HermesSpace.x2,
            child: Center(
              child: _Chip(
                key: const ValueKey('ssh-terminal-jump-bottom'),
                colors: colors,
                semanticLabel: strings.termUxJumpToBottom,
                icon: HIcons.arrow_downward_rounded,
                onTap: () {
                  if (!_hasScroll) return;
                  final position = _scroll.position;
                  position.jumpTo(position.maxScrollExtent);
                },
              ),
            ),
          ),
      ],
    );
  }

  /// The answers to the question the shell waits on, where they do not
  /// cover it: at the top when the cursor is in the lower half, else at
  /// the bottom. Each sends only its own key, and only when tapped.
  Widget _promptChips(HermesThemeColors colors, Strings strings) {
    final render = _laidOut?.renderTerminal;
    var atTop = true;
    if (render != null) {
      atTop = render.cursorOffset.dy > render.size.height / 2;
    }
    final chips = Wrap(
      key: const ValueKey('ssh-terminal-prompt'),
      spacing: HermesSpace.x2,
      runSpacing: HermesSpace.x2,
      children: [
        for (final answer in _prompt!)
          _Chip(
            key: ValueKey('ssh-terminal-prompt-${answer.label}'),
            colors: colors,
            label: answer.label,
            semanticLabel: identical(answer, sshPromptEnter)
                ? strings.termUxKeyEnter
                : identical(answer, sshPromptInterrupt)
                ? strings.sshKeyInterrupt
                : strings.termUxPromptSend(answer.label),
            onTap: () {
              HermesHaptics.selection();
              final terminal = widget.terminal;
              _unmodified(() => terminal.textInput(answer.input));
            },
          ),
      ],
    );
    return PositionedDirectional(
      start: HermesSpace.x2,
      end: HermesSpace.x2,
      top: atTop ? HermesSpace.x2 : null,
      bottom: atTop ? null : HermesSpace.x2,
      child: chips,
    );
  }

  /// The two handles of a selection, 48 dp to touch, the platform's look.
  List<Widget> _handles(BuildContext context) {
    final ends = _selectionEnds();
    final stack = _stack.currentContext?.findRenderObject();
    if (ends == null || stack is! RenderBox || !stack.hasSize) return const [];
    final line = _lineHeight;
    final controls = materialTextSelectionControls;
    final size = controls.getHandleSize(line);
    Widget handle(Offset tip, TextSelectionHandleType type, bool start) {
      final local = stack.globalToLocal(tip);
      final anchor = controls.getHandleAnchor(type, line);
      final inset = (HermesSize.tap - size.width) / 2;
      return Positioned(
        left: local.dx - anchor.dx - inset,
        top: local.dy - anchor.dy,
        child: GestureDetector(
          key: ValueKey(
            start ? 'ssh-terminal-handle-start' : 'ssh-terminal-handle-end',
          ),
          behavior: HitTestBehavior.opaque,
          // The grab is measured from where the finger went down.
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: (details) => _onHandleStart(details, tip),
          onPanUpdate: (details) => _onHandleUpdate(details, start: start),
          onPanEnd: (_) => _onHandleEnd(),
          onPanCancel: _onHandleEnd,
          child: SizedBox(
            width: HermesSize.tap,
            height: HermesSize.tap,
            child: Align(
              alignment: Alignment.topCenter,
              child: controls.buildHandle(context, type, line),
            ),
          ),
        ),
      );
    }

    final (begin, end) = ends;
    return [
      handle(begin + Offset(0, line), TextSelectionHandleType.left, true),
      handle(end + Offset(0, line), TextSelectionHandleType.right, false),
    ];
  }
}

/// A floating chip over the terminal: an answer or «jump to bottom».
class _Chip extends StatelessWidget {
  const _Chip({
    required this.colors,
    required this.semanticLabel,
    required this.onTap,
    this.label,
    this.icon,
    super.key,
  });

  final HermesThemeColors colors;
  final String semanticLabel;
  final VoidCallback onTap;
  final String? label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final chrome = HermesChrome.of(colors);
    final text = label;
    return Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: chrome.opaque,
        shape: StadiumBorder(side: BorderSide(color: chrome.line)),
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: HermesSize.tap,
              minHeight: HermesSize.tap,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x4),
              child: Center(
                widthFactor: 1,
                child: text != null
                    ? Text(
                        text,
                        style: HermesType.value.copyWith(
                          fontFamily: HermesType.monoFamily,
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                      )
                    : Icon(
                        icon,
                        size: HermesIcon.md,
                        color: colors.textPrimary,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
