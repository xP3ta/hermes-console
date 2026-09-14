import 'dart:collection';

import '../models/connection.dart';
import '../models/new_session_launch_action.dart';
import '../models/session.dart';
import 'new_session_factory.dart';

enum NewSessionLaunchCoordinatorState {
  idle,
  waitingForNavigator,
  waitingForOnboarding,
  waitingForUnlock,
  selectingInstance,
  navigating,
  delivered,
  cancelled,
  failedRecoverable,
}

enum NewSessionLaunchDisposition {
  delivered,
  queued,
  duplicate,
  cancelled,
  failedRecoverable,
}

enum NavigationDeliveryOutcome { delivered, deferred }

typedef NewSessionConnectionSelector =
    Future<SavedConnection?> Function(List<SavedConnection> candidates);
typedef NewSessionDraftNavigator =
    Future<NavigationDeliveryOutcome> Function(
      SavedConnection connection,
      Session draft,
      NewSessionLaunchTarget target,
    );
typedef WidgetRouteNavigator = Future<void> Function();
typedef WidgetSessionNavigator =
    Future<NavigationDeliveryOutcome> Function(
      SavedConnection connection,
      String sessionId,
    );

/// Serializes shortcut/widget actions behind Splash, onboarding, App Lock and
/// Navigator readiness without creating any remote session.
///
/// Gate owners call [retry] when their state changes. [navigate] must complete
/// after the route is pushed, not after the route is later popped.
class NewSessionLaunchCoordinator {
  final List<SavedConnection> Function() connections;
  final String? Function() activeConnectionId;
  final String? Function() defaultConnectionId;
  final bool Function() onboardingComplete;
  final bool Function() unlocked;
  final bool Function() navigatorReady;
  final String Function() newChatTitle;
  final NewSessionConnectionSelector selectConnection;
  final NewSessionDraftNavigator navigate;
  final WidgetRouteNavigator? openApp;
  final WidgetRouteNavigator? openSetup;
  final WidgetSessionNavigator? openSession;
  final NewSessionFactory factory;
  final Duration duplicateWindow;
  final int Function() _elapsedMs;

  final Queue<NewSessionLaunchAction> _pending =
      Queue<NewSessionLaunchAction>();
  final Set<String> _queuedFingerprints = <String>{};
  final Map<String, int> _recentlyDelivered = <String, int>{};
  bool _draining = false;
  String? _inFlightFingerprint;

  NewSessionLaunchCoordinator({
    required this.connections,
    required this.activeConnectionId,
    required this.defaultConnectionId,
    required this.onboardingComplete,
    required this.unlocked,
    required this.navigatorReady,
    required this.newChatTitle,
    required this.selectConnection,
    required this.navigate,
    this.openApp,
    this.openSetup,
    this.openSession,
    NewSessionFactory? factory,
    this.duplicateWindow = const Duration(milliseconds: 850),
    int Function()? elapsedMs,
  }) : factory = factory ?? NewSessionFactory(),
       _elapsedMs = elapsedMs ?? _monotonicElapsedMs;

  static final Stopwatch _clock = Stopwatch()..start();
  static int _monotonicElapsedMs() => _clock.elapsedMilliseconds;

  NewSessionLaunchCoordinatorState state =
      NewSessionLaunchCoordinatorState.idle;

  bool get hasPending => _pending.isNotEmpty;

  Future<NewSessionLaunchDisposition> enqueue(
    NewSessionLaunchAction action,
  ) async {
    final fingerprint = action.dedupeFingerprint;
    final now = _elapsedMs();
    final lastDelivered = _recentlyDelivered[fingerprint];
    final duplicate =
        _inFlightFingerprint == fingerprint ||
        _queuedFingerprints.contains(fingerprint) ||
        (lastDelivered != null &&
            now - lastDelivered <= duplicateWindow.inMilliseconds);
    if (duplicate) return NewSessionLaunchDisposition.duplicate;

    _pending.add(action);
    _queuedFingerprints.add(fingerprint);
    return _drain();
  }

  Future<NewSessionLaunchDisposition> retry() => _drain();

  Future<NewSessionLaunchDisposition> _drain() async {
    if (_draining) return NewSessionLaunchDisposition.queued;
    if (_pending.isEmpty) {
      state = NewSessionLaunchCoordinatorState.idle;
      return NewSessionLaunchDisposition.delivered;
    }
    final pendingKind = _pending.first.kind;
    final opensExistingSurface =
        pendingKind == NewSessionLaunchKind.openApp ||
        pendingKind == NewSessionLaunchKind.openSetup;
    if (!opensExistingSurface && !onboardingComplete()) {
      state = NewSessionLaunchCoordinatorState.waitingForOnboarding;
      return NewSessionLaunchDisposition.queued;
    }
    if (!unlocked()) {
      state = NewSessionLaunchCoordinatorState.waitingForUnlock;
      return NewSessionLaunchDisposition.queued;
    }
    if (!navigatorReady()) {
      state = NewSessionLaunchCoordinatorState.waitingForNavigator;
      return NewSessionLaunchDisposition.queued;
    }

    _draining = true;
    final action = _pending.first;
    final fingerprint = action.dedupeFingerprint;
    _inFlightFingerprint = fingerprint;
    try {
      if (action.kind == NewSessionLaunchKind.openApp ||
          action.kind == NewSessionLaunchKind.openSetup) {
        final route = action.kind == NewSessionLaunchKind.openApp
            ? openApp
            : openSetup;
        if (route == null) {
          state = NewSessionLaunchCoordinatorState.failedRecoverable;
          return NewSessionLaunchDisposition.failedRecoverable;
        }
        state = NewSessionLaunchCoordinatorState.navigating;
        await route();
        _consume(action);
        _recentlyDelivered[fingerprint] = _elapsedMs();
        _pruneDelivered();
        state = NewSessionLaunchCoordinatorState.delivered;
        return NewSessionLaunchDisposition.delivered;
      }
      final snapshot = connections();
      final resolution = resolveNewSessionInstance(
        action: action,
        connectionIds: snapshot.map((connection) => connection.id),
        activeConnectionId: activeConnectionId(),
        defaultConnectionId: defaultConnectionId(),
      );

      SavedConnection? selected;
      if (resolution.kind == InstanceResolutionKind.needsOnboarding) {
        state = NewSessionLaunchCoordinatorState.waitingForOnboarding;
        return NewSessionLaunchDisposition.queued;
      }
      if (resolution.kind == InstanceResolutionKind.invalidAction) {
        _consume(action);
        state = NewSessionLaunchCoordinatorState.failedRecoverable;
        return NewSessionLaunchDisposition.failedRecoverable;
      }
      if (resolution.kind == InstanceResolutionKind.needsSelection) {
        state = NewSessionLaunchCoordinatorState.selectingInstance;
        selected = await selectConnection(
          List.unmodifiable(
            snapshot.where(
              (connection) => resolution.candidateIds.contains(connection.id),
            ),
          ),
        );
        if (selected == null) {
          _consume(action);
          state = NewSessionLaunchCoordinatorState.cancelled;
          return NewSessionLaunchDisposition.cancelled;
        }
      } else {
        for (final connection in snapshot) {
          if (connection.id == resolution.connectionId) {
            selected = connection;
            break;
          }
        }
        if (selected == null) {
          state = NewSessionLaunchCoordinatorState.failedRecoverable;
          return NewSessionLaunchDisposition.failedRecoverable;
        }
      }

      state = NewSessionLaunchCoordinatorState.navigating;
      if (action.kind == NewSessionLaunchKind.openSession) {
        final sessionNavigator = openSession;
        final sessionId = action.sessionId;
        if (sessionNavigator == null || sessionId == null) {
          state = NewSessionLaunchCoordinatorState.failedRecoverable;
          return NewSessionLaunchDisposition.failedRecoverable;
        }
        final outcome = await sessionNavigator(selected, sessionId);
        if (outcome == NavigationDeliveryOutcome.deferred) {
          return _deferNavigation();
        }
        _consume(action);
        _recentlyDelivered[fingerprint] = _elapsedMs();
        _pruneDelivered();
        state = NewSessionLaunchCoordinatorState.delivered;
        return NewSessionLaunchDisposition.delivered;
      }
      final draft = factory.create(title: newChatTitle());
      final outcome = await navigate(selected, draft, action.target);
      if (outcome == NavigationDeliveryOutcome.deferred) {
        return _deferNavigation();
      }
      _consume(action);
      _recentlyDelivered[fingerprint] = _elapsedMs();
      _pruneDelivered();
      state = NewSessionLaunchCoordinatorState.delivered;
      return NewSessionLaunchDisposition.delivered;
    } catch (_) {
      state = NewSessionLaunchCoordinatorState.failedRecoverable;
      return NewSessionLaunchDisposition.failedRecoverable;
    } finally {
      _inFlightFingerprint = null;
      _draining = false;
    }
  }

  NewSessionLaunchDisposition _deferNavigation() {
    state = unlocked()
        ? NewSessionLaunchCoordinatorState.waitingForNavigator
        : NewSessionLaunchCoordinatorState.waitingForUnlock;
    return NewSessionLaunchDisposition.queued;
  }

  void _consume(NewSessionLaunchAction action) {
    if (_pending.isNotEmpty && identical(_pending.first, action)) {
      _pending.removeFirst();
    } else {
      _pending.remove(action);
    }
    _queuedFingerprints.remove(action.dedupeFingerprint);
  }

  void _pruneDelivered() {
    final cutoff = _elapsedMs() - duplicateWindow.inMilliseconds;
    _recentlyDelivered.removeWhere((_, deliveredAt) => deliveredAt < cutoff);
  }
}
