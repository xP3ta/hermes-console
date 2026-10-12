import 'dart:ui' show FlutterView;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../widgets/hermes_notice.dart';

/// What a piece of transient feedback is for. The kind, not the call site,
/// decides whether anything is drawn on screen.
enum FeedbackKind {
  /// Routine confirmation of something the user just did and can already
  /// see ("Saved", "Copied", "Model active", "Setting applied"). Never drawn:
  /// screen readers hear it and the control gives a light haptic tick.
  routine,

  /// Something failed or cannot be done and the user has to know or act
  /// (wrong input, a request that failed, a missing prerequisite).
  error,

  /// A reversible change that offers its undo (or the one follow-up that
  /// keeps data safe). Always carries an action.
  undo,

  /// Security, data-loss or long-running state the user must not miss
  /// (keys wiped, update restarting the server, export in progress).
  critical,
}

/// The one rule for transient messages in the app.
///
/// The owner rule: messages that dirty the window should be rare unless they
/// are essential. Only [FeedbackKind.error], [FeedbackKind.undo] and
/// [FeedbackKind.critical] reach the notice lane; [FeedbackKind.routine] is
/// announced to assistive technology and acknowledged with a haptic tick.
abstract final class FeedbackPolicy {
  /// Whether [kind] is drawn as a notice.
  static bool isVisual(FeedbackKind kind) => kind != FeedbackKind.routine;
}

/// Entry point for transient feedback. Use instead of `HermesNotice.show` /
/// `showSnackBar` so the policy applies everywhere.
///
/// ```dart
/// AppFeedback.notify(context, FeedbackKind.routine, s.copied);
/// final feedback = AppFeedback.of(context); // capture before an await
/// feedback.error(s.saveFailed);
/// ```
abstract final class AppFeedback {
  /// Sink bound to [context]'s notice lane and view. Safe to capture before an
  /// `await` (like `ScaffoldMessenger.of`).
  static FeedbackSink of(BuildContext context) => FeedbackSink._(
    HermesNotice.of(context),
    View.maybeOf(context),
    Directionality.maybeOf(context) ?? TextDirection.ltr,
  );

  /// Sink bound to [navigator]'s overlay, for callers without a context of
  /// their own (deep links, share intents). Null when there is no navigator.
  static FeedbackSink? ofNavigator(NavigatorState? navigator) {
    final notices = HermesNotice.ofNavigator(navigator);
    if (notices == null || navigator == null) return null;
    final context = navigator.context;
    return FeedbackSink._(
      notices,
      View.maybeOf(context),
      Directionality.maybeOf(context) ?? TextDirection.ltr,
    );
  }

  /// Shorthand for `AppFeedback.of(context).notify(...)`.
  static HermesNoticeHandle? notify(
    BuildContext context,
    FeedbackKind kind,
    String message, {
    HermesNoticeAction? action,
    Duration? duration,
    bool warning = false,
    Key? noticeKey,
    bool sticky = false,
  }) => of(context).notify(
    kind,
    message,
    action: action,
    duration: duration,
    warning: warning,
    noticeKey: noticeKey,
    sticky: sticky,
  );
}

/// Feedback bound to one notice lane and one view.
class FeedbackSink {
  FeedbackSink._(this._notices, this._view, this._direction);

  final HermesNoticeController _notices;
  final FlutterView? _view;
  final TextDirection _direction;

  /// Applies the policy to [message].
  ///
  /// - routine: no notice; screen-reader announcement + light haptic.
  /// - error: error notice ([warning] = amber "cannot do that" tone).
  /// - undo: notice with its [action].
  /// - critical: notice that stays long enough to be read.
  HermesNoticeHandle? notify(
    FeedbackKind kind,
    String message, {
    HermesNoticeAction? action,
    Duration? duration,
    bool warning = false,
    Key? noticeKey,
    bool sticky = false,
  }) {
    if (!FeedbackPolicy.isVisual(kind)) {
      _announce(message);
      HapticFeedback.selectionClick();
      return null;
    }
    final HermesNoticeKind tone = switch (kind) {
      FeedbackKind.error =>
        warning ? HermesNoticeKind.warning : HermesNoticeKind.error,
      FeedbackKind.critical =>
        warning ? HermesNoticeKind.warning : HermesNoticeKind.info,
      FeedbackKind.undo || FeedbackKind.routine => HermesNoticeKind.info,
    };
    return _notices.show(
      message: message,
      kind: tone,
      action: action,
      duration: duration,
      noticeKey: noticeKey,
      sticky: sticky,
    );
  }

  /// Routine confirmation (never drawn).
  void routine(String message) => notify(FeedbackKind.routine, message);

  /// Error or blocked action the user must see.
  HermesNoticeHandle? error(
    String message, {
    bool warning = false,
    HermesNoticeAction? action,
    Duration? duration,
  }) => notify(
    FeedbackKind.error,
    message,
    warning: warning,
    action: action,
    duration: duration,
  );

  void _announce(String message) {
    final view = _view;
    if (view == null || message.trim().isEmpty) return;
    SemanticsService.sendAnnouncement(view, message, _direction);
  }
}
