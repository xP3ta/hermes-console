import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../main.dart';
import '../../../design/hermes_design.dart';
import '../../../feedback/feedback_policy.dart';
import '../../../models/desktop_model_catalog.dart';
import '../../../services/bot_profile_client.dart';
import '../../../services/bot_roster_store.dart';
import '../../../services/model_catalog_cache.dart';
import '../../../services/model_picker_loader.dart';

/// The models a profile can really use (`model.options {profile}`), kept per
/// server and profile so its picker opens at once.
///
/// The server may take several seconds to build that catalog, and the read
/// rides a socket that can wedge without anyone noticing. Desktop keeps the
/// answer in its query cache for two minutes and gives a read 20 s (#95279);
/// so does this: one read at a time per profile, bounded, and the last answer
/// is what a tap paints while a newer one is fetched behind.
final class ProfileModelCatalogs {
  ProfileModelCatalogs({
    this.settle = const Duration(seconds: 20),
    this.staleAfter = const Duration(minutes: 2),
    this.capacity = 32,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static final shared = ProfileModelCatalogs();

  /// How long a read may take before it counts as failed.
  final Duration settle;

  /// Age after which a kept answer is refreshed behind the picker.
  final Duration staleAfter;
  final int capacity;
  final DateTime Function() _now;
  final _kept = <String, ({DesktopModelCatalog catalog, DateTime at})>{};
  final _reads = <String, Future<DesktopModelCatalog>>{};

  static String _key(String scope, String profile) => '$scope|$profile';

  /// The last answer for [profile] on [scope], whatever its age.
  DesktopModelCatalog? peek(String scope, String profile) =>
      _kept[_key(scope, profile)]?.catalog;

  bool isFresh(String scope, String profile) {
    final kept = _kept[_key(scope, profile)];
    return kept != null && _now().difference(kept.at) < staleAfter;
  }

  /// Reads the catalog, joining a read already on the wire, and keeps it.
  Future<DesktopModelCatalog> read(
    BotModelGateway gateway,
    String scope,
    String profile,
  ) {
    final key = _key(scope, profile);
    return _reads[key] ??=
        Future<DesktopModelCatalog>.sync(() => gateway.botModelOptions(profile))
            .timeout(settle)
            .then((catalog) {
              _kept.remove(key);
              _kept[key] = (catalog: catalog, at: _now());
              while (_kept.length > capacity) {
                _kept.remove(_kept.keys.first);
              }
              return catalog;
            })
            // A block: returning the removed future would make this wait on
            // itself.
            .whenComplete(() {
              _reads.remove(key);
            });
  }

  void clear() {
    _kept.clear();
    _reads.clear();
  }
}

/// The model each profile was last given from this app, for that profile's
/// chat: it follows the profile at once, before the roster is read again.
/// Once the shared roster has been read after the edit, the roster is what
/// says the profile's model (it may have been changed elsewhere since); a
/// read that was already on the wire when the model was saved does not
/// count, it still carries the model the profile had.
final class ProfileModelEdits {
  static final shared = ProfileModelEdits();

  final _latest = <String, ({String provider, String model, int at})>{};

  ({String provider, String model})? latest(String scope, String profile) {
    final key = '$scope|$profile';
    final edit = _latest[key];
    if (edit == null) return null;
    final registry = BotRosterRegistry.shared;
    if (registry.store(scope).isLive && registry.lastRead(scope) > edit.at) {
      _latest.remove(key);
      return null;
    }
    return (provider: edit.provider, model: edit.model);
  }

  void record(
    String scope,
    String profile, {
    required String provider,
    required String model,
  }) => _latest['$scope|$profile'] = (
    provider: provider,
    model: model,
    at: BotRosterRegistry.shared.mark(),
  );

  void clear() => _latest.clear();
}

/// What the row of a profile's model paints.
final class ProfileModelRow {
  final String provider;
  final String model;

  /// The catalog is being read for a tap, or the choice is being saved.
  final bool busy;

  /// Opens the picker; null where the model cannot be changed.
  final VoidCallback? onTap;

  const ProfileModelRow({
    required this.provider,
    required this.model,
    required this.busy,
    required this.onTap,
  });
}

/// A profile's model as a picker: provider and model are chosen from what
/// that profile can use, never typed. The catalog is `model.options
/// {profile}` and the choice is written with `profiles.configure {model,
/// provider}`, as Desktop's profile editor does; a model the server wants
/// acknowledged first is asked once.
///
/// Only this row waits for the server. [builder] draws it, so the bot's
/// card and the profile editor keep their own rows.
class ProfileModelPicker extends StatefulWidget {
  final String profile;

  /// Whose catalog this is: the connection id.
  final String scope;
  final String provider;
  final String model;
  final BotModelGateway? catalogGateway;
  final BotProfileGateway? writer;
  final bool readOnly;

  /// Prefix of the keys: `-picker`, `-<provider>-<model>`, `-confirm`.
  final String keyPrefix;

  /// The server accepted another model.
  final VoidCallback? onChanged;
  final ProfileModelCatalogs? catalogs;

  /// The chat's own copies of the catalog; the app's when null.
  @visibleForTesting
  final ({ModelPickerCache picker, ModelCatalogCache catalog})? chatCatalogs;
  final Widget Function(BuildContext context, ProfileModelRow row) builder;

  const ProfileModelPicker({
    super.key,
    required this.profile,
    required this.scope,
    required this.provider,
    required this.model,
    required this.catalogGateway,
    required this.writer,
    required this.keyPrefix,
    required this.builder,
    this.readOnly = false,
    this.onChanged,
    this.catalogs,
    this.chatCatalogs,
  });

  @override
  State<ProfileModelPicker> createState() => _ProfileModelPickerState();
}

class _ProfileModelPickerState extends State<ProfileModelPicker> {
  /// What the server accepted here, until the roster says the same.
  ({String provider, String model})? _accepted;
  bool _reading = false;
  bool _writing = false;

  ProfileModelCatalogs get _catalogs =>
      widget.catalogs ?? ProfileModelCatalogs.shared;

  bool get _editable =>
      !widget.readOnly &&
      widget.catalogGateway != null &&
      widget.writer != null;

  String get _provider => _accepted?.provider ?? widget.provider;
  String get _model => _accepted?.model ?? widget.model;

  @override
  void initState() {
    super.initState();
    _warm();
  }

  @override
  void didUpdateWidget(covariant ProfileModelPicker old) {
    super.didUpdateWidget(old);
    if (old.profile != widget.profile ||
        old.scope != widget.scope ||
        old.provider != widget.provider ||
        old.model != widget.model) {
      _accepted = null;
    }
    if (old.profile != widget.profile || old.scope != widget.scope) _warm();
  }

  /// Fetches the catalog behind, so a tap finds it.
  void _warm() {
    final gateway = widget.catalogGateway;
    if (!_editable || gateway == null) return;
    if (_catalogs.isFresh(widget.scope, widget.profile)) return;
    unawaited(
      _catalogs
          .read(gateway, widget.scope, widget.profile)
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }

  void _notice(String text, {bool error = false}) {
    if (!mounted) return;
    AppFeedback.notify(
      context,
      error ? FeedbackKind.error : FeedbackKind.routine,
      text,
    );
  }

  Future<void> _open() async {
    final gateway = widget.catalogGateway;
    if (!_editable || gateway == null || _reading || _writing) return;
    final s = Strings.of(context);
    var catalog = _catalogs.peek(widget.scope, widget.profile);
    if (catalog == null) {
      setState(() => _reading = true);
      try {
        catalog = await _catalogs.read(gateway, widget.scope, widget.profile);
      } catch (_) {
        if (mounted) setState(() => _reading = false);
        _notice(s.botProfileModelUnavailable, error: true);
        return;
      }
      if (!mounted) return;
      setState(() => _reading = false);
      // Another screen is on top by now: nothing opens over it.
      if (ModalRoute.of(context)?.isCurrent == false) return;
    } else {
      _warm();
    }
    final groups = [
      for (final p in catalog.providers)
        if (p.authenticated != false && p.models.isNotEmpty)
          HermesModelGroup(
            slug: p.slug,
            name: p.name,
            models: p.models,
            unavailableModels: p.unavailableModels.toSet(),
          ),
    ];
    if (groups.isEmpty) {
      _notice(s.botProfileModelUnavailable, error: true);
      return;
    }
    final choice = await showHermesModelPicker(
      context: context,
      groups: groups,
      current: HermesModelChoice(_provider, _model),
      surfaceKey: ValueKey('${widget.keyPrefix}-picker'),
      keyPrefix: widget.keyPrefix,
    );
    if (choice == null || choice.isDefault || !mounted) return;
    if (choice.provider == _provider && choice.model == _model) return;
    await _apply(choice.provider, choice.model);
  }

  Future<void> _apply(
    String provider,
    String model, {
    bool confirmed = false,
  }) async {
    final writer = widget.writer!;
    final s = Strings.of(context);
    setState(() => _writing = true);
    try {
      final result = await writer.configureBotProfile(widget.profile, {
        'model': model,
        'provider': provider,
        if (confirmed) 'confirm_expensive_model': true,
      });
      if (!mounted) return;
      if (result['confirm_required'] == true && !confirmed) {
        setState(() => _writing = false);
        final yes = await showHermesDialog<bool>(
          context: context,
          surfaceKey: ValueKey('${widget.keyPrefix}-confirm'),
          title: s.botProfileModel,
          message: (result['confirm_message'] as String?) ?? s.botProfileModel,
          actions: [
            HermesDialogAction(
              label: s.botCancel,
              value: false,
              style: HermesDialogActionStyle.cancel,
            ),
            HermesDialogAction(
              key: ValueKey('${widget.keyPrefix}-confirm-save'),
              label: s.botSave,
              value: true,
            ),
          ],
        );
        if (yes == true && mounted) {
          await _apply(provider, model, confirmed: true);
        }
        return;
      }
      final applied = result['applied'];
      if (applied is! Map || applied['model'] != true) {
        throw StateError('model not applied');
      }
      setState(() => _accepted = (provider: provider, model: model));
      _tellTheChat(provider, model);
      _notice(s.botProfileModelSaved);
      widget.onChanged?.call();
    } catch (_) {
      _notice(s.botProfileFailed, error: true);
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  /// The profile's chat keeps its own copy of the catalog and, for a Bot
  /// Chat, follows the profile's model: both learn of the change now, so
  /// the chat never paints or uses the model the profile had.
  void _tellTheChat(String provider, String model) {
    ProfileModelEdits.shared.record(
      widget.scope,
      widget.profile,
      provider: provider,
      model: model,
    );
    final caches =
        widget.chatCatalogs ??
        switch (context.findAncestorStateOfType<HermesAppState>()) {
          final app? => (
            picker: app.activeChats.modelPickerCache,
            catalog: app.activeChats.modelCatalogCache,
          ),
          null => null,
        };
    if (caches == null) return;
    // A chat names the default profile `default`, or nothing.
    for (final profile in {
      widget.profile,
      if (widget.profile == 'default') '',
    }) {
      caches.picker.profileModelChanged(
        ModelPickerCache.key(widget.scope, profile),
        provider: provider,
        model: model,
      );
      caches.catalog.invalidate(widget.scope, profile);
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    context,
    ProfileModelRow(
      provider: _provider,
      model: _model,
      busy: _reading || _writing,
      onTap: _editable ? _open : null,
    ),
  );
}
