import 'package:flutter/foundation.dart';

import 'bot_character.dart';

/// The character being edited, with undo and redo.
///
/// A discrete change ([apply]) is one step. A drag is bracketed by
/// [beginGesture] and [endGesture]: every [update] in between repaints but
/// the whole drag is a single step, so one undo reverts one drag.
class CharacterDraft extends ChangeNotifier {
  /// Steps kept for undo.
  static const int limit = 100;

  CharacterDraft(BotCharacter initial) : _value = initial, _origin = initial;

  BotCharacter _value;
  BotCharacter _origin;
  final List<BotCharacter> _undo = [];
  final List<BotCharacter> _redo = [];
  BotCharacter? _gestureBase;

  BotCharacter get value => _value;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// True when the character differs from the one the editor opened with
  /// (or was last [load]ed / [markSaved]).
  bool get dirty => _value != _origin;

  /// A discrete change, one undo step.
  void apply(BotCharacter next) {
    endGesture();
    if (next == _value) return;
    _push(_value);
    _redo.clear();
    _value = next;
    notifyListeners();
  }

  /// Starts a drag; everything until [endGesture] is one step.
  void beginGesture() {
    _gestureBase ??= _value;
  }

  /// A live value inside a drag. Outside one it acts as [apply].
  void update(BotCharacter next) {
    if (_gestureBase == null) {
      apply(next);
      return;
    }
    if (next == _value) return;
    _value = next;
    notifyListeners();
  }

  /// Closes the drag: one undo step if the value moved.
  void endGesture() {
    final base = _gestureBase;
    if (base == null) return;
    _gestureBase = null;
    if (base == _value) return;
    _push(base);
    _redo.clear();
    notifyListeners();
  }

  bool undo() {
    endGesture();
    if (_undo.isEmpty) return false;
    _redo.add(_value);
    _value = _undo.removeLast();
    notifyListeners();
    return true;
  }

  bool redo() {
    endGesture();
    if (_redo.isEmpty) return false;
    _undo.add(_value);
    _value = _redo.removeLast();
    notifyListeners();
    return true;
  }

  /// Replaces the character without history (opening a saved one).
  void load(BotCharacter next) {
    _gestureBase = null;
    _undo.clear();
    _redo.clear();
    _value = next;
    _origin = next;
    notifyListeners();
  }

  /// Declares the current value saved: it is no longer [dirty].
  void markSaved() {
    _origin = _value;
    notifyListeners();
  }

  void _push(BotCharacter previous) {
    _undo.add(previous);
    if (_undo.length > limit) _undo.removeAt(0);
  }
}
