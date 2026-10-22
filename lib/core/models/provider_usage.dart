import 'package:flutter/foundation.dart';

/// Whether a window caps the whole login or only one model family
/// (`scope` of `ProviderUsageWindow`, Hermes `agent/account_usage.py`).
enum ProviderUsageScope { account, model }

/// `state` of one pooled account (`ProviderUsageAccount`, Hermes
/// `hermes_cli/inventory.py::_pool_usage_accounts`).
enum ProviderUsageState { ready, limited, unknown, unavailable }

/// One subscription window of `usage` in `/api/model/options`.
@immutable
class ProviderUsageWindow {
  const ProviderUsageWindow({
    required this.label,
    required this.usedPercent,
    this.resetsAt,
    this.scope = ProviderUsageScope.account,
  });

  final String label;

  /// 0..100.
  final double usedPercent;
  final DateTime? resetsAt;
  final ProviderUsageScope scope;

  /// A window Hermes sent whole, or null (anything else is ignored).
  static ProviderUsageWindow? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final label = raw['label'];
    final used = raw['used_percent'];
    if (label is! String || label.trim().isEmpty) return null;
    if (used is! num || !used.isFinite) return null;
    final scope = switch (raw['scope']) {
      null || 'account' => ProviderUsageScope.account,
      'model' => ProviderUsageScope.model,
      _ => null,
    };
    if (scope == null) return null;
    final at = raw['resets_at'];
    return ProviderUsageWindow(
      label: label.trim(),
      usedPercent: used.toDouble().clamp(0, 100).toDouble(),
      resetsAt: at is String ? DateTime.tryParse(at.trim()) : null,
      scope: scope,
    );
  }
}

/// One account of a multi-entry credential pool. [id] is Hermes' stable
/// non-secret identity; [label] may be empty.
@immutable
class ProviderUsageAccount {
  const ProviderUsageAccount({
    required this.id,
    required this.state,
    this.label = '',
    this.windows = const [],
    this.resetsAt,
  });

  final String id;
  final String label;
  final ProviderUsageState state;
  final List<ProviderUsageWindow> windows;
  final DateTime? resetsAt;

  static ProviderUsageAccount? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.trim().isEmpty) return null;
    // A state Console does not know is "unknown": never a gauge.
    final state = switch (raw['state']) {
      'ready' => ProviderUsageState.ready,
      'limited' => ProviderUsageState.limited,
      'unavailable' => ProviderUsageState.unavailable,
      _ => ProviderUsageState.unknown,
    };
    final label = raw['label'];
    final at = raw['resets_at'];
    return ProviderUsageAccount(
      id: id.trim(),
      label: label is String ? label.trim() : '',
      state: state,
      windows: ProviderUsage._windows(raw['windows']),
      resetsAt: at is String ? DateTime.tryParse(at.trim()) : null,
    );
  }
}

/// `usage` of one provider row in `/api/model/options`: [windows] for a
/// single-account provider, [accounts] (and no windows) for a pool.
@immutable
class ProviderUsage {
  const ProviderUsage({this.windows = const [], this.accounts = const []});

  static const _maxWindows = 16;
  static const _maxAccounts = 32;

  final List<ProviderUsageWindow> windows;
  final List<ProviderUsageAccount> accounts;

  bool get isEmpty => windows.isEmpty && accounts.isEmpty;

  /// Null for a missing, malformed or empty `usage`. Never throws.
  static ProviderUsage? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final accounts = <ProviderUsageAccount>[];
    final rawAccounts = raw['accounts'];
    if (rawAccounts is List) {
      for (final item in rawAccounts.take(_maxAccounts)) {
        final account = ProviderUsageAccount.tryParse(item);
        if (account != null) accounts.add(account);
      }
    }
    final usage = ProviderUsage(
      windows: _windows(raw['windows']),
      accounts: List.unmodifiable(accounts),
    );
    return usage.isEmpty ? null : usage;
  }

  static List<ProviderUsageWindow> _windows(Object? raw) {
    if (raw is! List) return const [];
    return List.unmodifiable([
      for (final item in raw.take(_maxWindows))
        if (ProviderUsageWindow.tryParse(item) case final window?) window,
    ]);
  }
}
