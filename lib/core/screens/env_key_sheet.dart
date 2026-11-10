// The sheet of one key of the profile's `.env`: what the server says about
// it (set or not, group, description), a write-only field for a new value and,
// for a key that is set, an on-demand "Show value".
//
// Showing a stored value is the one time a secret is on screen, so:
//  * nothing is asked before the user taps "Show value" (never when the list or
//    the sheet opens); the first time in a session it asks to confirm, and the
//    App Lock check (when the user has one) comes before the request;
//  * the value lives only in a read-only, selectable field whose menu cannot
//    copy, share or look it up; the explicit Copy button is the only way out
//    (see [SensitiveClipboard]);
//  * it hides itself after 15 s, when the field loses the focus, when the app
//    leaves the front, when the screen turns and when the sheet closes, and
//    the text is emptied from the controller each time;
//  * its semantics say only "value hidden" / "value visible".
//
// The value that is typed is a secret from the first keystroke:
//  * the field is obscured, with no autocorrect, suggestions, keyboard
//    learning or autofill, and a menu that can paste and select but not copy, cut, share or look up;
//  * the eye shows what was typed only while the field has the focus and the
//    app is in front: losing the focus, leaving the app or App Lock hides it
//    again (App Lock also empties the field and closes the sheet);
//  * the text lives only in the controller. It is handed to [onSave] once,
//    and the controller is emptied and disposed when the sheet leaves;
//  * no message, log or semantics label ever carries it.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../design/content.dart' show HermesInlineNotice, HermesTag;
import '../design/modal.dart'
    show HermesDialogAction, HermesDialogActionStyle, showHermesDialog;
import '../design/page.dart' show HermesActionButton, HermesGlassActionButton;
import '../design/tokens.dart';
import '../keys/env_key.dart';
import '../services/sensitive_clipboard.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_ui.dart' show HermesField;

/// Saves [value] under [name]; answers the sentence to show when it failed,
/// null when it went through.
typedef EnvKeySave = Future<String?> Function(String name, String value);

/// Deletes [name]; same answer as [EnvKeySave].
typedef EnvKeyDelete = Future<String?> Function(String name);

/// What asking for a stored value came to: the value, or the sentence to show
/// when there is none. Never both, and the sentence never carries a value.
class EnvKeyRevealOutcome {
  const EnvKeyRevealOutcome.value(String this.value) : error = null;
  const EnvKeyRevealOutcome.failed(String this.error) : value = null;

  final String? value;
  final String? error;
}

/// Asks the server for the stored value of [name], on demand.
typedef EnvKeyReveal = Future<EnvKeyRevealOutcome> Function(String name);

/// Checks who is asking (App Lock) right before a value is requested.
typedef EnvKeyAuthorize = Future<bool> Function(BuildContext context);

/// Whether the user already confirmed "it will be shown on screen" in this
/// session of the app.
class EnvRevealSession {
  EnvRevealSession._();

  static bool confirmed = false;

  @visibleForTesting
  static void reset() => confirmed = false;
}

/// How long a revealed value stays on screen.
const Duration kEnvRevealWindow = Duration(seconds: 15);

/// Ticks the countdown; the default is a one second periodic [Timer].
typedef EnvRevealTicker = Timer Function(void Function(Timer timer) onTick);

Timer _secondTicker(void Function(Timer timer) onTick) =>
    Timer.periodic(const Duration(seconds: 1), onTick);

/// What the field's menu may offer: actions that bring text in or select it.
/// Everything else (copy, cut, share, web search, look up, live text, custom
/// entries) can take the selection out of the app, so it is dropped.
const Set<ContextMenuButtonType> _inwardMenuButtons = {
  ContextMenuButtonType.paste,
  ContextMenuButtonType.selectAll,
};

/// The selection menu of a secret's field: what the platform offers minus
/// anything that sends the selected text out of the app.
List<ContextMenuButtonItem> pasteOnlyMenuItems(
  List<ContextMenuButtonItem> items,
) => [
  for (final item in items)
    if (_inwardMenuButtons.contains(item.type)) item,
];

Widget _pasteOnlyMenu(BuildContext context, EditableTextState state) =>
    AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: pasteOnlyMenuItems(state.contextMenuButtonItems),
    );

class _UpperCase extends TextInputFormatter {
  const _UpperCase();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => newValue.copyWith(text: newValue.text.toUpperCase());
}

class EnvKeyValueSheet extends StatefulWidget {
  const EnvKeyValueSheet({
    required this.entry,
    required this.setNames,
    required this.profileName,
    required this.onSave,
    required this.onDelete,
    this.writesBlocked = false,
    this.appLocked,
    this.controllerFactory,
    this.onReveal,
    this.authorizeReveal,
    this.revealWindow = kEnvRevealWindow,
    this.revealTicker = _secondTicker,
    super.key,
  });

  /// The key being edited; null adds a key of the user's own.
  final EnvKeyEntry? entry;

  /// Names that are set in the profile, to ask before replacing one.
  final Set<String> setNames;

  /// The profile the value is written to, as the user knows it.
  final String profileName;

  final EnvKeySave onSave;
  final EnvKeyDelete onDelete;

  /// The connection may not carry a secret (HTTP in the clear on a public
  /// network): the fields stay, the actions do not.
  final bool writesBlocked;

  final ValueListenable<bool>? appLocked;

  /// Test seam: the controller of the value, to watch it being emptied.
  final TextEditingController Function()? controllerFactory;

  /// Asks for the stored value. Null leaves "Show value" out (read-only
  /// connection). With [writesBlocked] the button gives way to one line.
  final EnvKeyReveal? onReveal;

  /// App Lock check before the request; null asks nothing more.
  final EnvKeyAuthorize? authorizeReveal;

  /// How long the value stays visible.
  final Duration revealWindow;

  /// The countdown's clock (a seam for tests).
  final EnvRevealTicker revealTicker;

  @override
  State<EnvKeyValueSheet> createState() => _EnvKeyValueSheetState();
}

class _EnvKeyValueSheetState extends State<EnvKeyValueSheet>
    with WidgetsBindingObserver {
  late final TextEditingController _value =
      widget.controllerFactory?.call() ?? TextEditingController();
  final TextEditingController _name = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _reveal = false;
  bool _busy = false;

  // The stored value, only while it is shown.
  final TextEditingController _shown = TextEditingController();
  final FocusNode _shownFocus = FocusNode();
  Timer? _countdown;
  bool _fetching = false;
  bool _leftWhileFetching = false;
  bool _copied = false;
  int _secondsLeft = 0;
  Orientation? _shownOrientation;
  String? _revealError;
  bool get _showing => _shownOrientation != null;
  String? _nameError;
  String? _valueError;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focus.addListener(_onFocus);
    _shownFocus.addListener(_onShownFocus);
    widget.appLocked?.addListener(_onLock);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Turning the screen hides the value (the build that follows repaints).
    final orientation = MediaQuery.orientationOf(context);
    if (_showing && orientation != _shownOrientation) _dropValue();
  }

  @override
  void dispose() {
    _dropValue();
    _shownFocus
      ..removeListener(_onShownFocus)
      ..dispose();
    _shown.dispose();
    WidgetsBinding.instance.removeObserver(this);
    widget.appLocked?.removeListener(_onLock);
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    _name.dispose();
    _value
      ..clear()
      ..dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!_focus.hasFocus) _hide();
  }

  void _hide() {
    if (_reveal && mounted) setState(() => _reveal = false);
  }

  /// Showing what was typed needs the field in focus, so that losing the
  /// focus is what hides it again.
  void _toggleReveal() {
    if (!_reveal) _focus.requestFocus();
    setState(() => _reveal = !_reveal);
  }

  void _onLock() {
    if (!(widget.appLocked?.value ?? false)) return;
    _value.clear();
    _reveal = false;
    _dropValue();
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    _hide();
    if (_fetching) _leftWhileFetching = true;
    if (_showing && mounted) setState(_dropValue);
  }

  void _onShownFocus() {
    if (!_shownFocus.hasFocus && _showing && mounted) setState(_dropValue);
  }

  /// Forgets the stored value: the text, the clock and what depended on them.
  void _dropValue() {
    _countdown?.cancel();
    _countdown = null;
    _shown.clear();
    _shownOrientation = null;
    _copied = false;
    _secondsLeft = 0;
  }

  Future<void> _startReveal() async {
    final entry = widget.entry;
    final fetch = widget.onReveal;
    if (entry == null || fetch == null || _busy || _fetching || _showing) {
      return;
    }
    final s = Strings.of(context);
    setState(() {
      _revealError = null;
      _copied = false;
    });
    if (!EnvRevealSession.confirmed) {
      final ok = await _confirm(
        title: s.krhRevealConfirmTitle,
        message: s.krhRevealConfirmBody,
        action: s.krhRevealConfirmAction,
      );
      if (!ok) return;
      EnvRevealSession.confirmed = true;
    }
    final authorize = widget.authorizeReveal;
    if (authorize != null) {
      if (!mounted) return;
      final allowed = await authorize(context);
      if (!mounted) return;
      if (!allowed) {
        setState(() => _revealError = s.krhRevealAuthFailed);
        return;
      }
    }
    setState(() {
      _fetching = true;
      _leftWhileFetching = false;
    });
    final EnvKeyRevealOutcome outcome;
    try {
      outcome = await fetch(entry.name);
    } catch (_) {
      // The caller turns known failures into sentences; anything else is
      // generic. The error itself is not kept: it could carry a body.
      if (mounted) {
        setState(() {
          _fetching = false;
          _revealError = s.krhRevealFailed;
        });
      }
      return;
    }
    if (!mounted) return;
    final value = outcome.value;
    if (value == null || _leftWhileFetching) {
      setState(() {
        _fetching = false;
        _revealError = value == null
            ? outcome.error ?? s.krhRevealFailed
            : null;
      });
      return;
    }
    _shown.text = value;
    _shownOrientation = MediaQuery.orientationOf(context);
    _secondsLeft = widget.revealWindow.inSeconds;
    _countdown = widget.revealTicker((timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_secondsLeft <= 1) {
        setState(_dropValue);
      } else {
        setState(() => _secondsLeft -= 1);
      }
    });
    setState(() => _fetching = false);
    // The focus is what is watched: losing it hides the value.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _showing) _shownFocus.requestFocus();
    });
  }

  Future<void> _copyShown() async {
    final text = _shown.text;
    if (text.isEmpty) return;
    await SensitiveClipboard.copy(text);
    if (mounted && _showing) setState(() => _copied = true);
  }

  String _problemText(Strings s, EnvKeyValueProblem problem) =>
      switch (problem) {
        EnvKeyValueProblem.empty => s.kluValueEmpty,
        EnvKeyValueProblem.tooLong => s.kluValueTooLong(kEnvKeyValueMaxLength),
        EnvKeyValueProblem.control ||
        EnvKeyValueProblem.edgeSpace => s.kluValueInvalid,
      };

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
    bool destructive = false,
  }) async {
    final s = Strings.of(context);
    final answer = await showHermesDialog<bool>(
      context: context,
      title: title,
      message: message,
      actions: [
        HermesDialogAction<bool>(
          key: const ValueKey('env-confirm-cancel'),
          label: s.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction<bool>(
          key: const ValueKey('env-confirm-ok'),
          label: action,
          value: true,
          style: destructive
              ? HermesDialogActionStyle.destructive
              : HermesDialogActionStyle.primary,
        ),
      ],
    );
    return answer == true && mounted;
  }

  Future<void> _save() async {
    if (_busy || widget.writesBlocked) return;
    final s = Strings.of(context);
    final name = widget.entry?.name ?? _name.text.trim();
    final nameBad = !isValidEnvKeyName(name);
    final problem = validateEnvKeyValue(_value.text);
    setState(() {
      _error = null;
      _nameError = nameBad ? s.kluNameInvalid : null;
      _valueError = problem == null ? null : _problemText(s, problem);
    });
    if (nameBad || problem != null) return;
    if (widget.setNames.contains(name)) {
      final ok = await _confirm(
        title: s.kluOverwriteTitle(name),
        message: s.kluOverwriteBody(widget.profileName),
        action: s.kluOverwriteAction,
      );
      if (!ok) return;
    }
    setState(() => _busy = true);
    final error = await widget.onSave(name, _value.text);
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _busy = false;
        _error = error;
      });
      return;
    }
    _value.clear();
    Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final entry = widget.entry;
    if (_busy || entry == null || widget.writesBlocked) return;
    final s = Strings.of(context);
    final ok = await _confirm(
      title: s.kluDeleteTitle(entry.name),
      message: s.kluDeleteBody(widget.profileName),
      action: s.kluDeleteAction,
      destructive: true,
    );
    if (!ok) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await widget.onDelete(entry.name);
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _busy = false;
        _error = error;
      });
      return;
    }
    Navigator.of(context).pop();
  }

  bool get _revealAvailable =>
      widget.entry?.isSet == true &&
      widget.onReveal != null &&
      !widget.writesBlocked;

  /// "Show value" for a key that is set: a button, the value with its
  /// countdown, or - over http outside a private network - one line saying why
  /// not.
  Widget _revealSection(Strings s, HermesThemeColors colors) {
    if (widget.writesBlocked) {
      return Padding(
        key: const ValueKey('env-reveal-blocked'),
        padding: const EdgeInsets.only(top: HermesSpace.x2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.visibility_off_outlined, size: 16, color: colors.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                s.krhRevealBlocked,
                style: HermesType.support.copyWith(color: colors.error),
              ),
            ),
          ],
        ),
      );
    }
    if (widget.onReveal == null) return const SizedBox.shrink();
    if (_showing) {
      return Padding(
        padding: const EdgeInsets.only(top: HermesSpace.x3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The text is not exposed to semantics: only whether it is shown.
            Semantics(
              container: true,
              readOnly: true,
              label: s.krhRevealVisibleLabel,
              child: ExcludeSemantics(
                child: Actions(
                  actions: <Type, Action<Intent>>{
                    CopySelectionTextIntent: DoNothingAction(),
                  },
                  child: TextField(
                    key: const ValueKey('env-revealed-input'),
                    controller: _shown,
                    focusNode: _shownFocus,
                    readOnly: true,
                    showCursor: false,
                    maxLines: null,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    contextMenuBuilder: _pasteOnlyMenu,
                    style: HermesType.mono.copyWith(
                      color: colors.textPrimary,
                      fontSize: 14,
                    ),
                    decoration: const InputDecoration(isDense: true),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _copied ? s.krhRevealCopied : s.krhRevealCountdown(_secondsLeft),
              key: const ValueKey('env-reveal-status'),
              style: HermesType.support.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: 8),
            // Pressing these must not take the focus off the value, or the
            // value would hide before it is copied.
            TextFieldTapRegion(
              child: ExcludeFocus(
                child: Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  children: [
                    HermesGlassActionButton(
                      key: const ValueKey('env-reveal-copy'),
                      label: s.commonCopy,
                      icon: Icons.copy_rounded,
                      onPressed: _copyShown,
                    ),
                    HermesGlassActionButton(
                      key: const ValueKey('env-reveal-hide'),
                      label: s.krhRevealHide,
                      icon: Icons.visibility_off_outlined,
                      onPressed: () => setState(_dropValue),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: HermesSpace.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Semantics(
              hint: s.krhRevealHiddenHint,
              child: HermesGlassActionButton(
                key: const ValueKey('env-reveal'),
                label: _fetching ? s.krhRevealLoading : s.krhRevealAction,
                icon: Icons.visibility_outlined,
                onPressed: _busy || _fetching ? null : _startReveal,
              ),
            ),
          ),
          if (_revealError != null) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(
                _revealError!,
                key: const ValueKey('env-reveal-error'),
                textAlign: TextAlign.center,
                style: HermesType.support.copyWith(color: colors.error),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final entry = widget.entry;
    final category = entry == null
        ? ''
        : (entry.category == 'custom' ? s.kluCategoryCustom : entry.category);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.x6,
        HermesSpace.x6,
        HermesSpace.x6,
        HermesSpace.x5,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              entry?.name ?? s.kluAddKey,
              key: const ValueKey('env-sheet-title'),
              style: HermesType.title.copyWith(
                color: colors.textPrimary,
                fontFamily: entry == null ? null : 'monospace',
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            s.kluTargetProfile(widget.profileName),
            key: const ValueKey('env-sheet-profile'),
            style: HermesType.support.copyWith(color: colors.textSecondary),
          ),
          if (entry != null) ...[
            const SizedBox(height: 12),
            _FactRow(
              label: s.kluSheetStatus,
              child: HermesTag(
                label: entry.isSet ? s.kluStatusSet : s.kluStatusNotSet,
                tone: entry.isSet
                    ? HermesStatusTone.ok
                    : HermesStatusTone.neutral,
              ),
            ),
            if (category.isNotEmpty)
              _FactRow(
                label: s.kluSheetCategory,
                child: Text(
                  category,
                  style: HermesType.support.copyWith(color: colors.textPrimary),
                ),
              ),
            if (entry.description.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                entry.description,
                style: HermesType.support.copyWith(color: colors.textSecondary),
              ),
            ],
          ],
          const SizedBox(height: 12),
          if (widget.writesBlocked)
            HermesInlineNotice(
              message: s.kluCleartextBlocked,
              icon: Icons.lock_outline_rounded,
              tone: HermesStatusTone.error,
            ),
          if (entry != null && entry.isSet) _revealSection(s, colors),
          const SizedBox(height: 8),
          Text(
            _revealAvailable ? s.krhWriteOnly : s.kluWriteOnly,
            style: HermesType.support.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 14),
          if (entry == null) ...[
            HermesField(
              key: const ValueKey('env-name-field'),
              fieldKey: const ValueKey('env-name-input'),
              label: s.kluNameLabel,
              controller: _name,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              autofill: false,
              textInputAction: TextInputAction.next,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9_]')),
                const _UpperCase(),
                LengthLimitingTextInputFormatter(128),
              ],
              errorText: _nameError,
              enabled: !_busy,
            ),
            const SizedBox(height: 12),
          ],
          // Copy and cut are off for the keyboard shortcuts too.
          Actions(
            actions: <Type, Action<Intent>>{
              CopySelectionTextIntent: DoNothingAction(),
            },
            child: HermesField(
              key: const ValueKey('env-value-field'),
              fieldKey: const ValueKey('env-value-input'),
              label: s.kluValueLabel,
              hint: s.kluValueHint,
              controller: _value,
              focusNode: _focus,
              obscure: !_reveal,
              keyboardType: TextInputType.visiblePassword,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              autofill: false,
              contextMenuBuilder: _pasteOnlyMenu,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              errorText: _valueError,
              enabled: !_busy,
              suffix: ExcludeFocus(
                child: IconButton(
                  key: const ValueKey('env-value-eye'),
                  tooltip: _reveal ? s.kluHideValue : s.kluRevealValue,
                  constraints: const BoxConstraints(
                    minWidth: HermesSpace.tap,
                    minHeight: HermesSpace.tap,
                  ),
                  onPressed: _busy ? null : _toggleReveal,
                  icon: Icon(
                    _reveal
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 20,
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                key: const ValueKey('env-sheet-error'),
                style: HermesType.support.copyWith(color: colors.error),
              ),
            ),
          ],
          const SizedBox(height: 16),
          HermesActionButton(
            key: const ValueKey('env-save'),
            primary: true,
            label: s.kluSaveKey,
            icon: Icons.check_circle_outline_rounded,
            onPressed: _busy || widget.writesBlocked ? null : _save,
          ),
          if (entry != null && entry.isSet) ...[
            const SizedBox(height: 10),
            Center(
              child: HermesGlassActionButton(
                key: const ValueKey('env-delete'),
                label: s.kluDeleteKey,
                icon: Icons.delete_outline_rounded,
                destructive: true,
                onPressed: _busy || widget.writesBlocked ? null : _delete,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 36),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: HermesType.support.copyWith(color: colors.textSecondary),
            ),
          ),
          child,
        ],
      ),
    );
  }
}
