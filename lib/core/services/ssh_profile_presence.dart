import 'package:flutter/foundation.dart';

/// Whether the app has at least one SSH profile, as a value the dock can read
/// without waiting: SSH settings live in secure storage, which is async.
///
/// The dock's «Agentes» item shows only while this is true; without an SSH
/// profile it is not on the bar and Ajustes › SSH / Terminal says how to
/// start. Tests set [value] directly; the app refreshes it from the stored
/// profiles when a dock mounts and when a profile is saved or cleared.
class SshProfilePresence extends ValueNotifier<bool> {
  SshProfilePresence() : super(false);

  static final SshProfilePresence instance = SshProfilePresence();

  /// Bumped when an SSH profile was saved or cleared: the docks read the
  /// profiles again.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// A profile was just saved: there is one now.
  void noteSaved() {
    value = true;
    revision.value++;
  }

  /// A profile was cleared: others may remain, so read again.
  void noteCleared() => revision.value++;
}
