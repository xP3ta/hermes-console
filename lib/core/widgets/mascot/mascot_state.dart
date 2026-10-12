import '../../models/activity_snapshot.dart';

/// What the header mascot shows. One value per pill state of the floating
/// chat header (chat v2): resting, thinking, running a tool, waiting for
/// the user (amber), just finished (one wave, then idle), no connection and
/// a failed turn.
enum MascotState { idle, thinking, tool, needsYou, done, offline, error }

extension MascotStateTraits on MascotState {
  /// States that animate continuously while visible (≤ 30 fps). The others
  /// rest: idle only blinks now and then, and offline/error hold a pose.
  bool get isActive => switch (this) {
    MascotState.thinking ||
    MascotState.tool ||
    MascotState.needsYou ||
    MascotState.done => true,
    MascotState.idle || MascotState.offline || MascotState.error => false,
  };
}

/// Maps the chat's activity model to a mascot state.
///
/// [ActivitySnapshot] knows what is alive now; the connection, a failed
/// turn and the short "just finished" window are owned by the host (the
/// header pill), so they come in as flags. Priority, highest first:
/// offline, error, needs you, tool, thinking, done, idle. A pending
/// permission wins over a running tool because it is the only state that
/// asks the user for something.
MascotState mascotStateFor(
  ActivitySnapshot snapshot, {
  bool offline = false,
  bool error = false,
  bool justFinished = false,
}) {
  if (offline) return MascotState.offline;
  if (error) return MascotState.error;
  if (snapshot.waitingForUser) return MascotState.needsYou;
  final current = snapshot.current;
  if (current != null &&
      current.isRunning &&
      current.kind != ActivityStepKind.reasoning) {
    return MascotState.tool;
  }
  if (snapshot.isLive) return MascotState.thinking;
  if (justFinished) return MascotState.done;
  return MascotState.idle;
}
