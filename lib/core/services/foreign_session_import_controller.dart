import 'package:flutter/foundation.dart';

import '../models/foreign_session.dart';
import 'desktop_control_gateway.dart';

/// State behind the "Import from Claude/Codex" screens: one page at a time
/// (no auto-fetch), ids deduplicated, a local text filter and one import in
/// flight at most.
class ForeignSessionImportController extends ChangeNotifier {
  final HermesForeignSessionGateway gateway;
  final String? profile;

  ForeignSessionImportController({required this.gateway, this.profile});

  final List<ForeignSessionRow> _all = [];
  final Set<String> _seen = {};
  ForeignSource? _source;
  int? _nextOffset;
  int _epoch = 0;
  bool _loading = false;
  bool _unsupported = false;
  bool _failed = false;
  bool _importing = false;
  bool _disposed = false;
  String _host = '';
  int _unreadable = 0;
  String _query = '';

  ForeignSource? get source => _source;
  bool get loading => _loading;
  bool get unsupported => _unsupported;
  bool get failed => _failed;
  bool get importing => _importing;
  bool get hasMore => _nextOffset != null;
  String get host => _host;
  int get unreadable => _unreadable;

  List<ForeignSessionRow> get rows {
    final needle = _query.trim().toLowerCase();
    if (needle.isEmpty) return List.unmodifiable(_all);
    return List.unmodifiable(
      _all.where(
        (row) =>
            row.title.toLowerCase().contains(needle) ||
            (row.cwd ?? '').toLowerCase().contains(needle) ||
            row.excerpt.toLowerCase().contains(needle),
      ),
    );
  }

  void setQuery(String query) {
    _query = query;
    _notify();
  }

  Future<void> setSource(ForeignSource? source) {
    _source = source;
    return loadFirst();
  }

  Future<void> loadFirst() async {
    final epoch = ++_epoch;
    _all.clear();
    _seen.clear();
    _nextOffset = null;
    _unreadable = 0;
    _failed = false;
    await _load(epoch, null);
  }

  Future<void> loadMore() async {
    final offset = _nextOffset;
    if (offset == null || _loading) return;
    await _load(_epoch, offset);
  }

  Future<void> _load(int epoch, int? offset) async {
    _loading = true;
    _failed = false;
    _notify();
    try {
      final page = await gateway.foreignList(
        profile: profile,
        source: _source,
        offset: offset,
      );
      if (epoch != _epoch || _disposed) return;
      for (final row in page.sessions) {
        if (_seen.add(row.id)) _all.add(row);
      }
      _nextOffset = page.nextOffset;
      _unreadable += page.unreadable;
      if (page.host.isNotEmpty) _host = page.host;
    } on DesktopControlFailure catch (failure) {
      if (epoch != _epoch || _disposed) return;
      if (failure.kind == DesktopControlFailureKind.unsupported) {
        _unsupported = true;
      } else {
        _failed = true;
      }
    } catch (_) {
      if (epoch != _epoch || _disposed) return;
      _failed = true;
    } finally {
      if (epoch == _epoch && !_disposed) {
        _loading = false;
        _notify();
      }
    }
  }

  Future<ForeignPreview?> preview(ForeignSessionRow row) async {
    try {
      return await gateway.foreignPreview(row.id, profile: profile);
    } on DesktopControlFailure catch (failure) {
      if (failure.kind == DesktopControlFailureKind.unsupported) {
        _unsupported = true;
        _notify();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Imports [row] and returns the local session id; null when another
  /// import is already running or the call failed.
  Future<String?> import(ForeignSessionRow row) async {
    if (_importing) return null;
    _importing = true;
    _notify();
    try {
      final result = await gateway.foreignImport(row.id, profile: profile);
      return result.sessionId;
    } catch (_) {
      return null;
    } finally {
      _importing = false;
      _notify();
    }
  }

  /// An already-imported conversation just opens its existing copy.
  Future<String?> open(ForeignPreview preview) async => preview.alreadyImported;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
