// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors

/// The authority of one change started from the Models screen.
///
/// It is captured when the user starts the action (before any confirmation
/// or sub-page), so what the server finally receives belongs to the profile
/// and connection that were on screen at that moment: a profile switch, a
/// replaced connection or revoked write access voids it instead of letting
/// it land somewhere else.
abstract interface class ModelsWrite {
  /// Profile name for the wire (empty for the default profile).
  String get profile;

  /// Still the profile and writable connection the action was started for.
  bool get isCurrent;

  /// Runs [body] under the write guard, with the screen marked busy. Every
  /// request [body] sends re-checks the authority first. Returns true when
  /// [body] completed and the action still belongs to the screen; a failure
  /// is reported to the user here, as one sentence.
  Future<bool> run(Future<void> Function() body);
}

/// Starts a change for the profile on screen; null when the connection is
/// read-only (the user has been told).
typedef ModelsBeginWrite = ModelsWrite? Function();
