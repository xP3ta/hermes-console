// Keys: the variables of the selected profile's `.env` (provider keys, tool
// settings and the user's own), as the server lists them.
//
//   GET    /api/env[?profile=]   the list: name, is_set, group, description
//   PUT    /api/env              {key, value[, profile]}
//   DELETE /api/env[?profile=]   {key[, profile]}
//   POST   /api/env/reveal       {key[, profile]}   one value, on request
//
// The list never carries a value: the server's `redacted_value` is not read.
// A stored value is asked for with `POST /api/env/reveal` only when the user
// taps "Show value" in a key's sheet (after a first-time confirmation and, if
// App Lock is on, its check), over a connection that may carry a secret, and
// it is never kept, cached or logged (see `env_key_sheet.dart`). The page asks
// for FLAG_SECURE while it is open (the sheet is above it), writes only over
// a connection that may carry a secret, always names the profile it writes
// to, and asks before replacing a key that is set or deleting one.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart' show HermesAppState;
import '../design/content.dart' show HermesInlineNotice, HermesTag;
import '../design/edges.dart' show HermesControlsScroll;
import '../design/modal.dart' show showHermesSurface;
import '../design/tokens.dart';
import '../feedback/feedback_policy.dart';
import '../keys/env_key.dart';
import '../services/app_lock.dart';
import '../services/connection_manager.dart';
import '../services/screen_security.dart';
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import '../utils/transport_privacy.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_pill.dart' show TuiLoader;
import '../widgets/hermes_ui.dart' show HermesPanel, HermesSecondaryButton;
import '../widgets/read_only.dart' show showReadOnlyNotice;
import 'env_key_sheet.dart';
import 'lock_screen.dart' show LockScreen;

/// Pushes FLAG_SECURE for the page and returns its release.
typedef EnvKeysSecureScope = Future<Future<void> Function()> Function();

Future<Future<void> Function()> _defaultSecureScope() async {
  final prefs = await SharedPreferences.getInstance();
  final lease = await ScreenSecurityService(prefs).pushSecureScope();
  return lease.release;
}

class EnvKeysScreen extends StatefulWidget {
  const EnvKeysScreen({
    required this.connection,
    required this.profile,
    this.secureScope = _defaultSecureScope,
    this.appLocked,
    this.appLockService,
    @visibleForTesting this.clientOverride,
    @visibleForTesting this.sheetControllerFactory,
    super.key,
  });

  final SavedConnection connection;

  /// The profile whose `.env` this is; empty or `default` is the server's own.
  final String profile;

  final EnvKeysSecureScope secureScope;

  /// True while App Lock covers the app; the app's own lock by default.
  final ValueListenable<bool>? appLocked;

  /// The App Lock that must approve showing a stored value; the app's own by
  /// default.
  final AppLockService? appLockService;

  final DashboardClient? clientOverride;
  final TextEditingController Function()? sheetControllerFactory;

  @override
  State<EnvKeysScreen> createState() => _EnvKeysScreenState();
}

class _EnvKeysScreenState extends State<EnvKeysScreen> {
  late final DashboardClient _client;
  Future<void> Function()? _releaseSecure;
  bool _disposed = false;
  ValueListenable<bool>? _appLocked;

  List<EnvKeyEntry> _entries = const [];

  /// Set messaging variables: not listed, but typing one's name replaces it.
  Set<String> _hiddenSet = const {};
  bool _loading = true;
  Object? _error;
  int _generation = 0;

  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool? _setFilter;
  String? _category;

  bool get _isDefaultProfile =>
      widget.profile.trim().isEmpty || widget.profile.trim() == 'default';

  TransportPrivacyClass get _transport =>
      TransportPrivacy.classify(widget.connection.effectiveDashboardUrl);

  /// A secret does not go in the clear over a network that is not the user's.
  bool get _writesBlocked =>
      _transport == TransportPrivacyClass.publicCleartext;

  @override
  void initState() {
    super.initState();
    _client = widget.clientOverride ?? DashboardClient.lazy(widget.connection);
    _appLocked =
        widget.appLocked ??
        context.findAncestorStateOfType<HermesAppState>()?.appLock.locked;
    unawaited(_acquireSecure());
    _load();
  }

  Future<void> _acquireSecure() async {
    final release = await widget.secureScope();
    if (_disposed) {
      await release();
    } else {
      _releaseSecure = release;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final release = _releaseSecure;
    if (release != null) unawaited(release());
    _client.close();
    _search.dispose();
    super.dispose();
  }

  String _profileName(Strings s) =>
      _isDefaultProfile ? s.kluProfileDefault : widget.profile.trim();

  /// Reads the list. The answer is parsed and dropped: only names, states and
  /// metadata are kept, never a value of any kind.
  Future<void> _load({bool quiet = false}) async {
    final generation = ++_generation;
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final raw = await _client.getEnvVars(profile: widget.profile);
      final entries = parseEnvKeys(raw);
      final hiddenSet = setChannelManagedNames(raw);
      if (!mounted || generation != _generation) return;
      setState(() {
        _entries = entries;
        _hiddenSet = hiddenSet;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  /// Why a write failed, in words that cannot carry a value: only errors
  /// with a known, fixed message are described; anything else is generic.
  String _reason(Strings s, Object error) {
    if (error is DashboardHttpException ||
        error is DashboardAuthException ||
        error is TimeoutException ||
        error is SocketException ||
        error is http.ClientException) {
      return localizedApiError(s, error);
    }
    return s.apiErrorUnknown;
  }

  /// Runs one write under the guard; answers the sentence for the sheet when
  /// it did not happen, null when it did.
  Future<String?> _write(
    Future<void> Function() body, {
    required String failure,
  }) async {
    final s = Strings.of(context);
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return s.readOnlyNotice;
    }
    if (_writesBlocked) return s.kluCleartextBlocked;
    try {
      await DashboardClient.guardedWrite(
        () => mounted && !widget.connection.readOnly && !_writesBlocked,
        body,
      );
      return null;
    } on DashboardWriteRevoked {
      return failure;
    } catch (error) {
      return '$failure ${_reason(s, error)}';
    }
  }

  Future<String?> _saveKey(String name, String value) async {
    final s = Strings.of(context);
    final failure = s.kluSaveFailed;
    final error = await _write(() async {
      final accepted = await _client.setEnvVar(
        name,
        value,
        profile: widget.profile,
      );
      if (!accepted) throw StateError('not accepted');
    }, failure: failure);
    if (error != null) return error;
    await _load(quiet: true);
    if (!mounted) return null;
    final stored =
        _entries.any((e) => e.name == name && e.isSet) ||
        _hiddenSet.contains(name);
    if (!stored) return failure;
    AppFeedback.of(context).notify(FeedbackKind.routine, s.kluSaved(name));
    return null;
  }

  Future<String?> _deleteKey(String name) async {
    final s = Strings.of(context);
    final failure = s.kluDeleteFailed;
    final error = await _write(
      () => _client.deleteEnvVar(name, profile: widget.profile),
      failure: failure,
    );
    if (error != null) return error;
    await _load(quiet: true);
    if (!mounted) return null;
    if (_entries.any((e) => e.name == name && e.isSet)) return failure;
    AppFeedback.of(context).notify(FeedbackKind.routine, s.kluDeleted(name));
    return null;
  }

  /// Asks the server for one stored value. Only the sentence for a known
  /// failure comes back with no value; nothing here keeps or logs the value.
  Future<EnvKeyRevealOutcome> _reveal(String name) async {
    final s = Strings.of(context);
    if (_writesBlocked) {
      return EnvKeyRevealOutcome.failed(s.krhRevealBlocked);
    }
    try {
      final value = await _client.revealEnvVar(name, profile: widget.profile);
      if (value == null) return EnvKeyRevealOutcome.failed(s.krhRevealFailed);
      return EnvKeyRevealOutcome.value(value);
    } on DashboardHttpException catch (error) {
      return EnvKeyRevealOutcome.failed(switch (error.statusCode) {
        429 => s.krhRevealTooMany,
        404 => s.krhRevealNotFound,
        _ => '${s.krhRevealFailed} ${_reason(s, error)}',
      });
    } catch (error) {
      return EnvKeyRevealOutcome.failed(
        '${s.krhRevealFailed} ${_reason(s, error)}',
      );
    }
  }

  /// App Lock check before a stored value is requested; nothing to check when
  /// the user has no App Lock.
  ///
  /// [sheetContext] is the sheet's: the lock screen must go on the navigator
  /// the sheet is on, above it, or it could end up hidden underneath.
  Future<bool> _authorizeReveal(BuildContext sheetContext) {
    final lock =
        widget.appLockService ??
        sheetContext.findAncestorStateOfType<HermesAppState>()?.appLock;
    if (lock == null || !lock.enabled) return Future.value(true);
    return LockScreen.verify(
      sheetContext,
      lock,
      reason: Strings.of(sheetContext).krhRevealAuthReason,
    );
  }

  Future<void> _openSheet(EnvKeyEntry? entry) async {
    final s = Strings.of(context);
    await showHermesSurface<void>(
      context: context,
      surfaceKey: const ValueKey('env-key-sheet'),
      maxHeightFactor: 0.92,
      builder: (_) => EnvKeyValueSheet(
        entry: entry,
        setNames: {
          for (final e in _entries)
            if (e.isSet) e.name,
          ..._hiddenSet,
        },
        profileName: _profileName(s),
        onSave: _saveKey,
        onDelete: _deleteKey,
        writesBlocked: _writesBlocked,
        appLocked: _appLocked,
        controllerFactory: widget.sheetControllerFactory,
        // A read-only connection keeps to what it does today: no secrets out.
        onReveal: widget.connection.readOnly ? null : _reveal,
        authorizeReveal: _authorizeReveal,
      ),
    );
  }

  List<String> get _categories {
    final names = <String>{
      for (final e in _entries)
        if (e.category.isNotEmpty) e.category,
    }.toList()..sort();
    return names;
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final visible = filterEnvKeys(
      _entries,
      query: _query,
      isSet: _setFilter,
      category: _category,
    );
    final showList = !_loading && _error == null && visible.isNotEmpty;
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(s.kluKeysTitle),
        actions: [
          IconButton(
            key: const ValueKey('env-add'),
            tooltip: s.kluAddKey,
            constraints: const BoxConstraints(
              minWidth: HermesSpace.tap,
              minHeight: HermesSpace.tap,
            ),
            onPressed: _loading ? null : () => _openSheet(null),
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: HermesControlsScroll(
        refreshColor: colors.accent,
        onRefresh: _load,
        controls: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HermesSpace.pageH,
              HermesSpace.x2,
              HermesSpace.pageH,
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Summary(
                  available: _entries.length,
                  configured: _entries.where((e) => e.isSet).length,
                  profile: _profileName(s),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    HermesSpace.x2,
                    HermesSpace.x2,
                    HermesSpace.x2,
                    HermesSpace.x3,
                  ),
                  child: Text(
                    s.krhKeysNote,
                    style: HermesType.support.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                if (_writesBlocked)
                  HermesInlineNotice(
                    message: s.kluCleartextBlocked,
                    icon: Icons.lock_outline_rounded,
                    tone: HermesStatusTone.error,
                  ),
                _SearchField(
                  controller: _search,
                  onChanged: (value) => setState(() => _query = value),
                  onClear: () {
                    _search.clear();
                    setState(() => _query = '');
                  },
                ),
              ],
            ),
          ),
          _FilterRow(
            setFilter: _setFilter,
            category: _category,
            categories: _categories,
            onSet: (value) => setState(() => _setFilter = value),
            onCategory: (value) => setState(() => _category = value),
          ),
        ],
        slivers: [
          showList
              ? HermesControlsScroll.list(
                  padding: const EdgeInsets.fromLTRB(
                    HermesSpace.pageH,
                    HermesSpace.x1,
                    HermesSpace.pageH,
                    HermesSpace.pageBottom,
                  ),
                  itemCount: visible.length,
                  itemBuilder: (_, i) => _KeyRow(
                    entry: visible[i],
                    onTap: () => _openSheet(visible[i]),
                  ),
                )
              : HermesControlsScroll.fill(_state(context, colors)),
        ],
      ),
    );
  }

  Widget _state(BuildContext context, HermesThemeColors colors) {
    final s = Strings.of(context);
    if (_loading) return Center(child: TuiLoader(label: s.kluKeysLoading));
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(HermesSpace.x6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 36, color: colors.error),
              const SizedBox(height: 12),
              Text(
                s.kluKeysLoadError,
                textAlign: TextAlign.center,
                style: HermesType.text.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                localizedApiError(s, error),
                textAlign: TextAlign.center,
                style: HermesType.support.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: 16),
              HermesSecondaryButton(
                label: s.commonRetry,
                icon: Icons.refresh,
                onTap: _load,
              ),
            ],
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HermesSpace.x6),
        child: Text(
          _entries.isEmpty ? s.kluKeysEmpty : s.kluKeysNoMatches,
          key: const ValueKey('env-empty'),
          textAlign: TextAlign.center,
          style: HermesType.text.copyWith(color: colors.textSecondary),
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.available,
    required this.configured,
    required this.profile,
  });

  final int available;
  final int configured;
  final String profile;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    Widget line(String label, String value, Key key) => ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 40),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: HermesType.text.copyWith(color: colors.textSecondary),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              key: key,
              textAlign: TextAlign.end,
              style: HermesType.body.copyWith(color: colors.textPrimary),
            ),
          ),
        ],
      ),
    );
    return HermesPanel(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: HermesSpace.x4,
          vertical: HermesSpace.x2,
        ),
        child: Column(
          children: [
            line(
              s.kluSummaryAvailable,
              '$available',
              const ValueKey('env-count-available'),
            ),
            line(
              s.kluSummaryConfigured,
              '$configured',
              const ValueKey('env-count-configured'),
            ),
            line(
              s.kluProfileLabel,
              profile,
              const ValueKey('env-summary-profile'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return TextField(
      key: const ValueKey('env-search'),
      controller: controller,
      onChanged: onChanged,
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: TextInputAction.search,
      style: TextStyle(
        fontSize: HermesType.textSize,
        color: colors.textPrimary,
      ),
      decoration: InputDecoration(
        hintText: s.kluKeysSearch,
        hintStyle: TextStyle(
          fontSize: HermesType.textSize,
          color: colors.textSecondary,
        ),
        prefixIcon: Icon(Icons.search, size: 18, color: colors.textSecondary),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: s.slClearSearch,
                constraints: const BoxConstraints(
                  minWidth: HermesSpace.tap,
                  minHeight: HermesSpace.tap,
                ),
                icon: Icon(Icons.clear, size: 18, color: colors.textSecondary),
                onPressed: onClear,
              ),
        isDense: true,
        filled: true,
        fillColor: colors.surfaceVariant.withValues(alpha: 0.3),
        contentPadding: const EdgeInsets.symmetric(vertical: HermesSpace.x3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HermesRadius.control),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

/// Status first (all, set, not set), then the groups the server names.
class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.setFilter,
    required this.category,
    required this.categories,
    required this.onSet,
    required this.onCategory,
  });

  final bool? setFilter;
  final String? category;
  final List<String> categories;
  final ValueChanged<bool?> onSet;
  final ValueChanged<String?> onCategory;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    Widget chip(Key key, String text, bool on, VoidCallback onTap) => Semantics(
      button: true,
      selected: on,
      label: text,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(HermesRadius.chip),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: HermesSpace.tap,
            minWidth: HermesSpace.tap,
          ),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: HermesSpace.x3,
                vertical: HermesSpace.x2,
              ),
              decoration: BoxDecoration(
                color: on ? colors.surfaceVariant : Colors.transparent,
                borderRadius: BorderRadius.circular(HermesRadius.chip),
                border: Border.all(
                  color: on
                      ? colors.textSecondary.withValues(alpha: 0.5)
                      : colors.divider,
                ),
              ),
              child: Text(
                text,
                style: TextStyle(
                  fontSize: HermesType.supportSize,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                  color: on ? colors.textPrimary : colors.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final allOn = setFilter == null && category == null;
    return SizedBox(
      height: HermesSpace.tap + HermesSpace.x1,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: HermesSpace.pageH),
        child: Row(
          children: [
            chip(const ValueKey('env-filter-all'), s.commonAll, allOn, () {
              onSet(null);
              onCategory(null);
            }),
            const SizedBox(width: HermesSpace.x2),
            chip(
              const ValueKey('env-filter-set'),
              s.kluStatusSet,
              setFilter == true,
              () => onSet(setFilter == true ? null : true),
            ),
            const SizedBox(width: HermesSpace.x2),
            chip(
              const ValueKey('env-filter-unset'),
              s.kluStatusNotSet,
              setFilter == false,
              () => onSet(setFilter == false ? null : false),
            ),
            for (final name in categories) ...[
              const SizedBox(width: HermesSpace.x2),
              chip(
                ValueKey('env-filter-cat-$name'),
                name == 'custom' ? s.kluCategoryCustom : name,
                category == name,
                () => onCategory(category == name ? null : name),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _KeyRow extends StatelessWidget {
  const _KeyRow({required this.entry, required this.onTap});

  final EnvKeyEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final category = entry.category == 'custom'
        ? s.kluCategoryCustom
        : entry.category;
    final status = entry.isSet ? s.kluStatusSet : s.kluStatusNotSet;
    return Semantics(
      key: ValueKey('env-key-${entry.name}'),
      button: true,
      label: s.kluRowLabel(entry.name, status, category),
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: HermesSpace.rowMin),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HermesSpace.x2,
              vertical: HermesSpace.x3,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: HermesType.textSize,
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    if (entry.isSet) ...[
                      const SizedBox(width: 8),
                      HermesTag(label: status, tone: HermesStatusTone.ok),
                    ],
                  ],
                ),
                if (category.isNotEmpty || entry.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (category.isNotEmpty) category,
                      if (entry.description.isNotEmpty) entry.description,
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: HermesType.support.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
