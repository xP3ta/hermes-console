import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/account_usage_limits.dart';
import '../models/desktop_session_config.dart';
import '../models/model_favorites.dart';
import '../models/model_identity.dart';
import '../models/model_provider.dart';
import '../models/provider_usage.dart';
import '../design/tokens.dart' show HermesChrome, HermesSpace, HermesType;
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart' show HermesIcon, HermesMotion;
import 'account_limits_section.dart';
import 'hermes_reasoning_pill.dart';
import 'provider_logo.dart';
import 'sheet_outline.dart';
import 'subscription_limit_block.dart';
import '../feedback/haptics.dart';

export 'hermes_reasoning_pill.dart' show kReasoningTrackInset;

/// What the catalog says about one model card. `null` capabilities are
/// unknown, never false.
@immutable
class SessionModelCardInfo {
  const SessionModelCardInfo({
    this.usable = true,
    this.reasoning,
    this.fast,
    this.free = false,
  });

  final bool usable;
  final bool? reasoning;
  final bool? fast;
  final bool free;
}

/// How a provider pill reads at a glance: the dot beside its name.
enum ModelProviderStatus {
  /// Usable, nowhere near its account limit.
  ready,

  /// The fullest account window is at 80 % or more, or some pooled account
  /// is limited.
  near,

  /// Not signed in, nothing usable, or the limit is reached.
  down,
}

/// The dot of [provider]'s pill. [anyUsable] is whether at least one of its
/// models can be picked. Reads only what Hermes published (`authenticated`,
/// `usage`); a provider that reports no usage is simply [ready].
ModelProviderStatus modelProviderStatus(
  ModelProvider provider, {
  required bool anyUsable,
}) {
  if (!anyUsable || !provider.authenticated) return ModelProviderStatus.down;
  final usage = provider.usage;
  if (usage == null) return ModelProviderStatus.ready;
  double fullest = 0;
  void consider(Iterable<ProviderUsageWindow> windows) {
    for (final w in windows) {
      if (w.scope == ProviderUsageScope.account && w.usedPercent > fullest) {
        fullest = w.usedPercent;
      }
    }
  }

  consider(usage.windows);
  var limited = 0;
  for (final account in usage.accounts) {
    consider(account.windows);
    if (account.state == ProviderUsageState.limited ||
        account.state == ProviderUsageState.unavailable) {
      limited++;
    }
  }
  if (usage.accounts.isNotEmpty && limited == usage.accounts.length) {
    return ModelProviderStatus.down;
  }
  if (fullest >= 100) return ModelProviderStatus.down;
  if (limited > 0 || fullest >= 80) return ModelProviderStatus.near;
  return ModelProviderStatus.ready;
}

/// Name a level of reasoning goes by in the sheet and in the chat's pill.
String reasoningEffortLabel(Strings strings, DesktopReasoningEffort effort) =>
    switch (effort) {
      DesktopReasoningEffort.none => strings.modelPickerLevelNone,
      DesktopReasoningEffort.minimal => strings.modelPickerLevelMinimal,
      DesktopReasoningEffort.low => strings.sp1215ReasoningLow,
      DesktopReasoningEffort.medium => strings.sp1215ReasoningMedium,
      DesktopReasoningEffort.high => strings.sp1215ReasoningHigh,
      DesktopReasoningEffort.xhigh => strings.modelPickerLevelXhigh,
      DesktopReasoningEffort.max => strings.modelPickerLevelMax,
      DesktopReasoningEffort.ultra => strings.modelPickerLevelUltra,
    };

/// The models of [providers] that match [query] across every provider at
/// once: model id, its friendly name ([label]), provider name or slug,
/// case-insensitive. Catalog order is kept.
List<(ModelProvider, String)> searchModelEntries(
  List<ModelProvider> providers,
  String query,
  String Function(String modelId) label,
) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  return [
    for (final p in providers)
      for (final id in p.models)
        if (p.name.toLowerCase().contains(q) ||
            p.slug.toLowerCase().contains(q) ||
            id.toLowerCase().contains(q) ||
            label(id).toLowerCase().contains(q))
          (p, id),
  ];
}

const double _kProviderPillHeight = 38;
const double _kModelPillHeight = 46;
const double _kOptionPillHeight = 34;
const double _kCurrentHeight = 66;
const double _kCurrentLogo = 38;
const double _kFavoriteHeight = 58;
const double _kFavoriteLogo = 34;

/// Least height of a chip when the text is large (still a 48 dp target).
const double _kChipTightHeight = 48;

/// Opacity of a control the model does not have, or that «Razonar» turned
/// off.
const double _kDimmed = 0.45;

/// Room page one needs, at normal text size, to keep the reasoning pill and
/// the buttons in view while the limits and favourites scroll. Large text
/// scrolls the whole page so every section remains reachable.
const double _kPageOnePinned = 300;

/// What the two chips take more when they stack instead of sharing a row.
const double _kChipStackExtra = _kChipTightHeight + _kPillGap;
const double _kSearchHeight = 44;
const double _kLogoDot = 26;
const double _kStatusDot = 6;
const double _kPillGap = 7;

/// Below this much room under the sheet's header (a phone with the keyboard
/// up, a landscape phone) the body stops pinning its fixed parts and scrolls
/// as one.
const double _kPinnedMinHeight = 360;

/// Fill of a pill at rest (one step above the sheet) and of a chosen one (the
/// accent, faint, over that).
Color _pillFill(HermesThemeColors colors, {required bool on}) {
  final raised = HermesChrome.of(colors).raised;
  return on
      ? Color.alphaBlend(colors.accent.withValues(alpha: 0.14), raised)
      : raised;
}

/// Pill chrome: the outline of [hermesSheetOutline] over the raised fill at
/// rest, the accent outline and a faint accent fill when [on]. [onTap] null
/// makes it inert.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.on,
    required this.onTap,
    required this.minHeight,
    required this.padding,
    required this.child,
    this.dim = false,
    this.faded = false,
    this.semanticsLabel,
    this.toggled,
    super.key,
  });

  final bool on;
  final VoidCallback? onTap;
  final double minHeight;
  final EdgeInsetsGeometry padding;
  final Widget child;

  /// Dim and inert (a setting the model does not have).
  final bool dim;

  /// Still tappable, only paler (a provider with nothing to pick).
  final bool faded;
  final String? semanticsLabel;

  /// Set for a switch-like pill (announced as on / off).
  final bool? toggled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final shape = StadiumBorder(
      side: BorderSide(color: on ? colors.accent : hermesSheetOutline(colors)),
    );
    final body = Material(
      color: _pillFill(colors, on: on),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: shape,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: minHeight),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
    return Semantics(
      container: true,
      button: true,
      selected: toggled == null ? on : null,
      toggled: toggled,
      enabled: onTap != null && !dim,
      onTap: semanticsLabel != null && !dim ? onTap : null,
      label: semanticsLabel,
      excludeSemantics: semanticsLabel != null,
      child: dim || faded
          ? Opacity(opacity: dim ? _kDimmed : 0.6, child: body)
          : body,
    );
  }
}

/// Body of «Modelo y sesión», in two pages that slide into each other.
///
/// Page one, «Ajustes del modelo»: the current model as a long pill (it opens
/// page two), the reasoning pill with the real levels, two selection buttons (Razonar,
/// Rápido) and the favourites. Permissions are not here: the chat's status
/// pill already sets them. Page two, «Todos los modelos»: the
/// magnifier, the provider pills with their status dot and the models of the
/// open provider, each with a star to keep it in the favourites.
///
/// Pure projection: the chat screen owns loading and applying; every change
/// goes through its callbacks, and a null callback disables that control.
class SessionModelSheetBody extends StatefulWidget {
  const SessionModelSheetBody({
    required this.providers,
    required this.isSelected,
    required this.isSelectedProvider,
    required this.cardInfo,
    required this.modelLabel,
    required this.onPick,
    required this.reasoning,
    required this.reasoningSupported,
    required this.onReasoning,
    required this.fastMode,
    required this.fastSupported,
    required this.onFastMode,
    this.currentModel,
    this.modelLoading = false,
    this.favorites = ModelFavorites.empty,
    this.onToggleFavorite,
    this.limits,
    this.accountLimits,
    this.catalogLimits,
    this.header,
    this.frequent = const [],
    this.profileName,
    this.onOpenModelSettings,
    this.onConnectAccount,
    super.key,
  });

  /// The same resolved identity shown by the composer, including a profile's
  /// default before a new chat has an explicit model selection.
  final ({String modelId, String? providerSlug})? currentModel;
  final bool modelLoading;

  final List<ModelProvider> providers;
  final bool Function(String providerSlug, String modelId) isSelected;
  final bool Function(String providerSlug) isSelectedProvider;
  final SessionModelCardInfo Function(String providerSlug, String modelId)
  cardInfo;
  final String Function(String modelId) modelLabel;
  final void Function(ModelProvider provider, String modelId)? onPick;

  final DesktopReasoningEffort? reasoning;
  final bool reasoningSupported;
  final ValueChanged<DesktopReasoningEffort>? onReasoning;

  final DesktopFastMode? fastMode;
  final bool fastSupported;
  final ValueChanged<DesktopFastMode>? onFastMode;

  /// What the person starred (device-local, per connection and profile).
  final ModelFavorites favorites;

  /// Stars or unstars a model; null hides nothing but disables the stars.
  final void Function(ModelProvider provider, String modelId)? onToggleFavorite;

  /// Only real Hermes data; null hides the block.
  final SubscriptionLimits? limits;

  /// «Límites de tu plan» from `session.usage` / `usage.bars`; follows the
  /// notifier so a read that lands while the sheet is open shows at once.
  final ValueListenable<AccountUsageLimits?>? accountLimits;

  /// Existing catalog usage when a draft has no session.usage yet.
  final AccountUsageLimits? catalogLimits;

  /// Optional widgets above both pages (loading, errors, the bridge install
  /// offer).
  final Widget? header;

  /// The models picked most here: offered under the current one while there
  /// are no favourites.
  final List<({String provider, String model})> frequent;

  /// Profile this chat talks with, shown quietly at the foot.
  final String? profileName;

  /// Opens Settings › Models; offered when a search finds nothing.
  final VoidCallback? onOpenModelSettings;

  /// Starts connecting a Nous Portal account; offered when no provider has
  /// a usable model (nothing to pick without an account).
  final VoidCallback? onConnectAccount;

  @override
  State<SessionModelSheetBody> createState() => _SessionModelSheetBodyState();
}

class _SessionModelSheetBodyState extends State<SessionModelSheetBody>
    with SingleTickerProviderStateMixin {
  final _search = TextEditingController();
  final _searchFieldKey = GlobalKey();
  final _selectedPillKey = GlobalKey();
  final _providerRow = ScrollController();
  final _modelList = ScrollController();

  /// 0 is page one, 1 is page two; between them the pages slide.
  late final AnimationController _page = AnimationController(
    vsync: this,
    duration: HermesMotion.page,
  );
  String _query = '';
  bool _searching = false;
  bool _freeOnly = false;

  /// The page the person is heading to.
  bool _allModels = false;

  /// The provider the user opened; null until they open one.
  String? _slug;

  /// What the model list last scrolled to the chosen row for.
  String? _listPlacedFor;

  /// The last level above «off»: what «Razonar» brings back.
  DesktopReasoningEffort? _lastThinking;

  @override
  void initState() {
    super.initState();
    _lastThinking = _above(widget.reasoning);
  }

  @override
  void didUpdateWidget(SessionModelSheetBody old) {
    super.didUpdateWidget(old);
    _lastThinking = _above(widget.reasoning) ?? _lastThinking;
  }

  @override
  void dispose() {
    _page.dispose();
    _search.dispose();
    _providerRow.dispose();
    _modelList.dispose();
    super.dispose();
  }

  static DesktopReasoningEffort? _above(DesktopReasoningEffort? effort) =>
      effort == null || effort == DesktopReasoningEffort.none ? null : effort;

  /// «Razonar» is on unless the model takes no level or the session is at
  /// the explicit «off» level; no level at all is the model's own default,
  /// which reasons.
  bool get _thinking =>
      widget.reasoningSupported &&
      widget.reasoning != DesktopReasoningEffort.none;

  void _toggleThinking() {
    final change = widget.onReasoning;
    if (change == null || !widget.reasoningSupported) return;
    if (_thinking) {
      _lastThinking = _above(widget.reasoning) ?? _lastThinking;
      change(DesktopReasoningEffort.none);
    } else {
      change(_lastThinking ?? DesktopReasoningEffort.medium);
    }
  }

  void _showPage({required bool all}) {
    if (_allModels == all) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _allModels = all;
      if (all) {
        _listPlacedFor = null;
      } else {
        _searching = false;
        _query = '';
        _search.clear();
      }
    });
    _page.animateTo(
      all ? 1 : 0,
      duration: HermesMotion.duration(context, HermesMotion.page),
      curve: HermesMotion.emphasized,
    );
  }

  /// Brings the open provider's pill into view in the sliding row. Only that
  /// row moves: the sheet's own scrolling stays where it is.
  void _revealSelectedPill() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pill = _selectedPillKey.currentContext?.findRenderObject();
      if (!mounted || pill == null || !_providerRow.hasClients) return;
      _providerRow.position.ensureVisible(pill, alignment: 0.5);
    });
  }

  /// Puts the chosen model within sight when page two opens (or its provider
  /// changes), and the first row at the top otherwise.
  void _placeModelList(String key, int chosenIndex) {
    if (_listPlacedFor == key) return;
    _listPlacedFor = key;
    _revealSelectedPill();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_modelList.hasClients) return;
      final position = _modelList.position;
      final target = chosenIndex < 0
          ? 0.0
          : (chosenIndex - 1) * (_kModelPillHeight + _kPillGap);
      position.jumpTo(
        target.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    });
  }

  ModelProvider? _openProvider(List<ModelProvider> base) {
    if (base.isEmpty) return null;
    for (final p in base) {
      if (p.slug == _slug) return p;
    }
    for (final p in base) {
      if (widget.isSelectedProvider(p.slug)) return p;
    }
    for (final p in base) {
      if (p.isCurrent) return p;
    }
    return base.first;
  }

  bool _isFree(ModelProvider provider, String id) =>
      widget.cardInfo(provider.slug, id).free;

  bool get _anyFree =>
      widget.providers.any((p) => p.models.any((id) => _isFree(p, id)));

  /// [providers] reduced to their free models; providers left with none go.
  List<ModelProvider> _onlyFree(List<ModelProvider> providers) => [
    for (final p in providers)
      if (p.models.where((id) => _isFree(p, id)).toList() case final free
          when free.isNotEmpty)
        p.copyWith(models: free),
  ];

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _query = '';
        _search.clear();
      }
    });
  }

  void _openProviderPill(ModelProvider provider) {
    setState(() => _slug = provider.slug);
    _revealSelectedPill();
  }

  /// Display names of [providers]; two rows with the same name (another
  /// account or key of one provider) are told apart by their slug.
  Map<String, String> _names(List<ModelProvider> providers) {
    String nameOf(ModelProvider p) => p.name.isNotEmpty ? p.name : p.slug;
    final count = <String, int>{};
    for (final p in providers) {
      final key = nameOf(p).toLowerCase();
      count[key] = (count[key] ?? 0) + 1;
    }
    return {
      for (final p in providers)
        p.slug: (count[nameOf(p).toLowerCase()] ?? 0) > 1
            ? '${nameOf(p)} · ${p.slug}'
            : nameOf(p),
    };
  }

  /// The model the session runs, with its provider; null while unknown.
  (ModelProvider, String)? _current() {
    final effective = widget.currentModel;
    if (effective != null) {
      final provider = findActiveModelProvider(
        widget.providers,
        effective.providerSlug ?? '',
      );
      if (provider != null) return (provider, effective.modelId);
      return null;
    }
    for (final p in widget.providers) {
      for (final id in p.models) {
        if (widget.isSelected(p.slug, id)) return (p, id);
      }
    }
    return null;
  }

  /// [pairs] that the catalog still lists, in order.
  List<(ModelProvider, String)> _resolve(
    Iterable<({String provider, String model})> pairs,
  ) => [
    for (final pair in pairs)
      if (widget.providers
              .where(
                (p) => p.slug == pair.provider && p.models.contains(pair.model),
              )
              .firstOrNull
          case final provider?)
        (provider, pair.model),
  ];

  void Function(ModelProvider, String)? get _star => widget.onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final base = _freeOnly ? _onlyFree(widget.providers) : widget.providers;
    final names = _names(widget.providers);
    final open = _openProvider(base);
    final searching = _searching && _query.trim().isNotEmpty;
    final results = searching
        ? searchModelEntries(
            _freeOnly ? base : widget.providers,
            _query,
            widget.modelLabel,
          )
        : const <(ModelProvider, String)>[];
    final entries = searching
        ? results
        : [
            if (open != null)
              for (final id in open.models) (open, id),
          ];
    // Two models the friendly names cannot tell apart keep their raw id.
    final labelCount = <String, int>{};
    for (final (_, id) in entries) {
      final label = widget.modelLabel(id);
      labelCount[label] = (labelCount[label] ?? 0) + 1;
    }

    final pages = LayoutBuilder(
      builder: (context, constraints) => AnimatedBuilder(
        animation: _page,
        builder: (context, _) {
          final progress = _page.value;
          final slide =
              (Directionality.of(context) == TextDirection.rtl ? -1.0 : 1.0) *
              HermesSpace.x8;
          return IgnorePointer(
            ignoring: _page.isAnimating,
            child: Stack(
              children: [
                if (progress < 1)
                  Opacity(
                    opacity: 1 - progress,
                    child: Transform.translate(
                      offset: Offset(-slide * progress, 0),
                      child: _pageOne(strings, colors, constraints, names),
                    ),
                  ),
                if (progress > 0)
                  Opacity(
                    opacity: progress,
                    child: Transform.translate(
                      offset: Offset(slide * (1 - progress), 0),
                      child: _pageTwo(
                        strings,
                        colors,
                        constraints,
                        base: base,
                        open: open,
                        names: names,
                        searching: searching,
                        entries: entries,
                        labelCount: labelCount,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
    return LayoutBuilder(
      builder: (context, outer) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ?widget.header,
          // Without a bound (a host that scrolls) the page takes its height.
          if (outer.hasBoundedHeight) Flexible(child: pages) else pages,
        ],
      ),
    );
  }

  // ─── Page one ───────────────────────────────────────────────────────────

  /// The way to an account, when the host offers one and no model in the
  /// sheet can be picked.
  VoidCallback? get _connectOffer {
    final connect = widget.onConnectAccount;
    if (connect == null) return null;
    final usable = widget.providers.any(
      (p) => p.models.any((id) => widget.cardInfo(p.slug, id).usable),
    );
    return usable ? null : connect;
  }

  Widget _pageOne(
    Strings strings,
    HermesThemeColors colors,
    BoxConstraints constraints,
    Map<String, String> names,
  ) {
    final bounded = constraints.hasBoundedHeight;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    // Below this much room the whole page scrolls; from it only the
    // favourites do and the reasoning pill stays in view.
    final chips = _chipLayout(strings, constraints.maxWidth);
    final pinned =
        bounded &&
        scale <= 1.3 &&
        constraints.maxHeight >=
            _kPageOnePinned * math.max(1, scale) +
                (chips == _ChipLayout.stacked ? _kChipStackExtra : 0);
    final current = _current();
    final thinkingOff =
        widget.reasoningSupported &&
        widget.reasoning == DesktopReasoningEffort.none;
    Widget slider = ReasoningStepSlider(
      key: const ValueKey('model-picker-reasoning'),
      value: widget.reasoning,
      supported: widget.reasoningSupported,
      onChanged: thinkingOff ? null : widget.onReasoning,
    );
    if (thinkingOff) {
      slider = Opacity(
        key: const ValueKey('msv-reasoning-dim'),
        opacity: _kDimmed,
        child: IgnorePointer(child: slider),
      );
    }
    final fixed = <Widget>[
      _CurrentCard(
        key: const ValueKey('msv-current'),
        provider: current?.$1,
        providerName: current == null ? null : names[current.$1.slug],
        modelId: current?.$2,
        label: widget.currentModel != null
            ? widget.modelLabel(widget.currentModel!.modelId)
            : current != null
            ? widget.modelLabel(current.$2)
            : widget.modelLoading
            ? strings.msvModelLoading
            : strings.msvModelUnavailable,
        loading: widget.modelLoading && current == null,
        providerSlug: widget.currentModel?.providerSlug,
        detail: current == null
            ? widget.currentModel?.providerSlug
            : _rowDetail(
                strings,
                current.$1,
                names[current.$1.slug] ?? current.$1.slug,
                widget.cardInfo(current.$1.slug, current.$2),
                withAccount: true,
              ),
        onTap: () => _showPage(all: true),
      ),
      slider,
      const SizedBox(height: HermesSpace.x2),
      _tiles(strings, layout: chips),
      const SizedBox(height: HermesSpace.x1),
      Align(
        alignment: AlignmentDirectional.centerEnd,
        child: TextButton(
          key: const ValueKey('model-all-link'),
          onPressed: () => _showPage(all: true),
          style: TextButton.styleFrom(
            foregroundColor: colors.accentText,
            minimumSize: const Size(HermesSpace.tap, HermesSpace.x8),
            padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x2),
            tapTargetSize: MaterialTapTargetSize.padded,
          ),
          child: Text(
            strings.modelPickerAllModels,
            textAlign: TextAlign.end,
            style: const TextStyle(
              fontSize: HermesType.supportSize,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    ];
    final scrolling = [
      ..._planLimits(),
      Padding(
        padding: const EdgeInsets.only(bottom: HermesSpace.x2),
        child: _SectionLabel(strings.msvFavorites),
      ),
      // Nothing here can be picked: the way to an account comes first.
      if (_connectOffer case final connect?)
        _ConnectAccountRow(
          key: const ValueKey('model-sheet-connect-account-one'),
          onTap: connect,
        ),
      ..._favoriteItems(strings, colors, names, current),
    ];
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: scrolling,
    );
    if (pinned) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ...fixed,
          Flexible(
            child: SingleChildScrollView(
              key: const ValueKey('msv-fav-scroll'),
              primary: false,
              physics: const ClampingScrollPhysics(),
              padding: _kListPadding,
              child: body,
            ),
          ),
        ],
      );
    }
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ...fixed,
        const SizedBox(height: HermesSpace.x2),
        body,
      ],
    );
    return bounded
        ? SingleChildScrollView(
            primary: false,
            physics: const ClampingScrollPhysics(),
            child: column,
          )
        : column;
  }

  /// What is under the «Favoritos» line: the starred models, or the current
  /// one and the frequent ones while there are none, then the hint, the
  /// subscription limits, the «applies from the next turn» note and the
  /// profile.
  List<Widget> _favoriteItems(
    Strings strings,
    HermesThemeColors colors,
    Map<String, String> names,
    (ModelProvider, String)? current,
  ) {
    final starred = _resolve(widget.favorites.entries);
    final frequent = starred.isNotEmpty
        ? const <(ModelProvider, String)>[]
        : _resolve(widget.frequent)
              .where(
                (e) =>
                    current == null ||
                    e.$1.slug != current.$1.slug ||
                    e.$2 != current.$2,
              )
              .toList();
    final rows = starred.isNotEmpty
        ? starred
        : [
            if (current != null && current.$1.models.contains(current.$2))
              current,
          ];
    Widget favorite((ModelProvider, String) entry) {
      final (provider, id) = entry;
      return _FavoritePill(
        key: ValueKey('msv-fav-${provider.slug}-$id'),
        provider: provider,
        providerName: names[provider.slug] ?? provider.slug,
        modelId: id,
        label: widget.modelLabel(id),
        info: widget.cardInfo(provider.slug, id),
        active: widget.isSelected(provider.slug, id),
        starred: widget.favorites.contains(provider.slug, id),
        starEnabled:
            _star != null &&
            (widget.favorites.contains(provider.slug, id) ||
                !widget.favorites.isFull),
        onPick: widget.onPick,
        onStar: _star,
      );
    }

    final tail = _tail(strings, colors);
    return [
      for (var i = 0; i < rows.length; i++) ...[
        if (i > 0) const SizedBox(height: _kPillGap),
        favorite(rows[i]),
      ],
      if (frequent.isNotEmpty) ...[
        const SizedBox(height: HermesSpace.x3),
        _SectionLabel(strings.msvFrequent),
        const SizedBox(height: HermesSpace.x2),
        for (var i = 0; i < frequent.length; i++) ...[
          if (i > 0) const SizedBox(height: _kPillGap),
          favorite(frequent[i]),
        ],
      ],
      if (starred.isEmpty) ...[
        const SizedBox(height: HermesSpace.x2),
        Text(
          strings.msvFavoritesHint,
          key: const ValueKey('msv-fav-hint'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: HermesType.supportSize,
            color: colors.textSecondary,
          ),
        ),
      ],
      ...tail,
    ];
  }

  /// Width a selection button takes besides its words: padding and,
  /// when [glyph], the glyph with its gap.
  static double _chipExtras({required bool glyph}) =>
      2 * HermesSpace.x3 +
      HermesSpace.x2 +
      HermesIcon.md +
      (glyph ? HermesIcon.lg + HermesSpace.x2 : 0);

  /// Razonar and Rápido: selection buttons side by side. With
  /// large text or a long language the glyph goes first, then the chips stack
  /// one above the other.
  _ChipLayout _chipLayout(Strings strings, double width) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    double measure(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final result = painter.width;
      painter.dispose();
      return result;
    }

    var longest = 0.0;
    for (final (title, state) in [
      (strings.msvThink, strings.msvThinkOn),
      (strings.msvThink, strings.msvThinkOff),
      (strings.sp1215CapFast, strings.msvFastNormal),
      (strings.sp1215CapFast, strings.msvFastActive),
    ]) {
      longest = math.max(
        longest,
        math.max(
          measure(title, _kTileTitleStyle),
          measure(state, _kTileStateStyle),
        ),
      );
    }
    final half = (width - _kPillGap) / 2;
    if (longest <= half - _chipExtras(glyph: true)) return _ChipLayout.full;
    if (longest <= half - _chipExtras(glyph: false)) {
      return _ChipLayout.noGlyph;
    }
    return _ChipLayout.stacked;
  }

  Widget _tiles(Strings strings, {required _ChipLayout layout}) {
    final stacked = layout == _ChipLayout.stacked;
    final onFast = widget.onFastMode;
    final fastOn =
        widget.fastSupported && widget.fastMode == DesktopFastMode.fast;
    final fastUsable = widget.fastSupported && onFast != null;
    final thinkingUsable =
        widget.reasoningSupported && widget.onReasoning != null;
    final think = _SettingTile(
      key: const ValueKey('msv-tile-think'),
      icon: Icons.auto_awesome_rounded,
      title: strings.msvThink,
      state: _thinking ? strings.msvThinkOn : strings.msvThinkOff,
      on: _thinking,
      dim: !widget.reasoningSupported,
      reason: widget.reasoningSupported
          ? null
          : strings.msvCapabilityUnavailable,
      onTap: thinkingUsable ? _toggleThinking : null,
      minHeight: layout == _ChipLayout.full
          ? _kFavoriteHeight
          : _kChipTightHeight,
      glyph: layout != _ChipLayout.noGlyph,
    );
    final fast = _SettingTile(
      key: const ValueKey('session-fast-switch'),
      icon: Icons.speed_rounded,
      title: strings.sp1215CapFast,
      state: fastOn ? strings.msvFastActive : strings.msvFastNormal,
      on: fastOn,
      dim: !widget.fastSupported,
      reason: widget.fastSupported ? null : strings.msvCapabilityUnavailable,
      onTap: !fastUsable
          ? null
          : () =>
                onFast(fastOn ? DesktopFastMode.normal : DesktopFastMode.fast),
      minHeight: layout == _ChipLayout.full
          ? _kFavoriteHeight
          : _kChipTightHeight,
      glyph: layout != _ChipLayout.noGlyph,
    );
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          think,
          const SizedBox(height: _kPillGap),
          fast,
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: think),
          const SizedBox(width: _kPillGap),
          Expanded(child: fast),
        ],
      ),
    );
  }

  /// Real plan data precedes favourites so it remains easy to reach.
  List<Widget> _planLimits() => [
    if (widget.limits case final limits?) ...[
      const SizedBox(height: HermesSpace.x3),
      SubscriptionLimitBlock(limits: limits),
    ],
    if (widget.accountLimits case final account?)
      ValueListenableBuilder<AccountUsageLimits?>(
        valueListenable: account,
        builder: (context, value, _) {
          final limits = value == null || value.isEmpty
              ? widget.catalogLimits
              : value;
          return limits == null || limits.isEmpty
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.symmetric(vertical: HermesSpace.x3),
                  child: AccountLimitsSection(
                    limits: limits,
                    preferredProvider:
                        _current()?.$1.slug ??
                        widget.currentModel?.providerSlug,
                  ),
                );
        },
      ),
  ];

  List<Widget> _tail(Strings strings, HermesThemeColors colors) {
    final profile = widget.profileName?.trim();
    return [
      const SizedBox(height: HermesSpace.x3),
      Text(
        strings.sp1215AppliesNextTurn,
        style: TextStyle(
          fontSize: HermesType.supportSize,
          color: colors.textSecondary,
        ),
      ),
      if (profile != null && profile.isNotEmpty) ...[
        const SizedBox(height: HermesSpace.x2),
        Text(
          strings.mdlPillProfile(profile),
          key: const ValueKey('model-picker-profile'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: HermesType.captionSize,
            color: colors.textTertiary,
          ),
        ),
      ],
    ];
  }

  // ─── Page two ───────────────────────────────────────────────────────────

  Widget _pageTwo(
    Strings strings,
    HermesThemeColors colors,
    BoxConstraints constraints, {
    required List<ModelProvider> base,
    required ModelProvider? open,
    required Map<String, String> names,
    required bool searching,
    required List<(ModelProvider, String)> entries,
    required Map<String, int> labelCount,
  }) {
    // What heads the models: the back button, the magnifier, the provider
    // pills, the search field, and the title of the list.
    final top = <Widget>[
      _pageTwoBar(strings),
      const SizedBox(height: HermesSpace.x2),
      _providerPills(base, open, names),
      if (_connectOffer case final connect?)
        _ConnectAccountRow(
          key: const ValueKey('model-sheet-connect-account'),
          onTap: connect,
        ),
      if (_searching) ...[
        const SizedBox(height: HermesSpace.x2),
        _SearchField(
          key: _searchFieldKey,
          controller: _search,
          hint: strings.mdlPillSearchHint,
          onChanged: (value) => setState(() => _query = value),
        ),
      ],
    ];
    if (widget.providers.isNotEmpty) {
      final freeToggle = (_anyFree || _freeOnly) && !searching
          ? _OptionPill(
              key: const ValueKey('model-free-only'),
              label: strings.modelsBotFreeOnly,
              on: _freeOnly,
              onTap: () => setState(() => _freeOnly = !_freeOnly),
            )
          : null;
      top
        ..add(const SizedBox(height: HermesSpace.x3))
        ..add(
          _SectionTitle(
            searching || open == null
                ? strings.mdlPillSectionResults
                : strings.mdlPillSectionModels(names[open.slug] ?? open.slug),
            key: const ValueKey('model-models-title'),
            trailing: freeToggle,
          ),
        )
        ..add(const SizedBox(height: HermesSpace.x2));
    }

    // Rows of the list (and what stands in for them when there are none).
    final lead = <Widget>[];
    if (widget.providers.isNotEmpty && entries.isEmpty) {
      if (searching) {
        lead.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: HermesSpace.x2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.modelSearchEmpty,
                  key: const ValueKey('model-search-empty'),
                  style: TextStyle(
                    fontSize: HermesType.supportSize,
                    color: colors.textSecondary,
                  ),
                ),
                if (widget.onOpenModelSettings case final openSettings?)
                  TextButton(
                    key: const ValueKey('model-search-open-settings'),
                    onPressed: openSettings,
                    child: Text(strings.mdlPillOpenSettings),
                  ),
              ],
            ),
          ),
        );
      } else if (_freeOnly) {
        lead.add(
          Text(
            strings.modelsBotFreeOnlyEmpty,
            style: TextStyle(
              fontSize: HermesType.supportSize,
              color: colors.textSecondary,
            ),
          ),
        );
      }
    }
    Widget row(int index) {
      final (provider, modelId) = entries[index];
      final starred = widget.favorites.contains(provider.slug, modelId);
      return Padding(
        padding: EdgeInsets.only(
          bottom: index == entries.length - 1 ? 0 : _kPillGap,
        ),
        child: _ModelPill(
          key: ValueKey('model-card-${provider.slug}-$modelId'),
          provider: provider,
          providerName: names[provider.slug] ?? provider.slug,
          modelId: modelId,
          label: widget.modelLabel(modelId),
          info: widget.cardInfo(provider.slug, modelId),
          active: widget.isSelected(provider.slug, modelId),
          highlight: searching ? _query.trim() : '',
          showProvider: searching,
          showId:
              (labelCount[widget.modelLabel(modelId)] ?? 0) > 1 &&
              widget.modelLabel(modelId) != modelId,
          onPick: widget.onPick,
          starred: starred,
          starEnabled: _star != null && (starred || !widget.favorites.isFull),
          onStar: _star,
        ),
      );
    }

    final pinned =
        constraints.hasBoundedHeight &&
        constraints.maxHeight >= _kPinnedMinHeight;
    if (!pinned) {
      // Unbounded or very short: one column, scrolled by whoever hosts it
      // (or by this body when the room is bounded but small).
      final listMax = (MediaQuery.sizeOf(context).height * 0.4).clamp(
        200.0,
        420.0,
      );
      final column = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ...top,
          ...lead,
          if (entries.isNotEmpty)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: listMax),
              child: ListView.builder(
                key: const ValueKey('model-picker-list'),
                primary: false,
                shrinkWrap: true,
                padding: _kListPadding,
                itemCount: entries.length,
                itemBuilder: (context, index) => row(index),
              ),
            ),
        ],
      );
      return constraints.hasBoundedHeight
          ? SingleChildScrollView(
              primary: false,
              physics: const ClampingScrollPhysics(),
              child: column,
            )
          : column;
    }

    // Pinned: the back bar, the providers and the title of the list stay on
    // top, and only the list of models scrolls.
    final chosen = entries.indexWhere(
      (e) => widget.isSelected(e.$1.slug, e.$2),
    );
    _placeModelList('$searching:${open?.slug}', chosen);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ...top,
        Flexible(
          child: ListView.builder(
            key: const ValueKey('model-picker-list'),
            controller: _modelList,
            primary: false,
            shrinkWrap: true,
            padding: _kListPadding,
            itemCount: entries.length + (lead.isEmpty ? 0 : 1),
            itemBuilder: (context, index) {
              if (lead.isNotEmpty && index == 0) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: lead,
                );
              }
              return row(index - (lead.isEmpty ? 0 : 1));
            },
          ),
        ),
      ],
    );
  }

  /// The back button, the title of the page and the magnifier.
  Widget _pageTwoBar(Strings strings) {
    final colors = Theme.of(context).hermes;
    return Row(
      children: [
        _RoundButton(
          key: const ValueKey('msv-back'),
          icon: Icons.arrow_back_rounded,
          label: MaterialLocalizations.of(context).backButtonTooltip,
          onTap: () => _showPage(all: false),
        ),
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              strings.modelPickerAllModels,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: HermesType.bodySize,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
          ),
        ),
        _SearchButton(active: _searching, onTap: _toggleSearch),
      ],
    );
  }

  /// A hair of room round the rows so their outline is not shaved by the
  /// edge of the list.
  static const EdgeInsets _kListPadding = EdgeInsets.symmetric(
    vertical: 2,
    horizontal: 1,
  );

  /// The pills of the providers, always on one line.
  Widget _providerPills(
    List<ModelProvider> base,
    ModelProvider? open,
    Map<String, String> names,
  ) {
    final strings = Strings.of(context);
    if (base.isEmpty) return const SizedBox.shrink();
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: strings.mdlPillSectionProvider,
      child: SingleChildScrollView(
        key: const ValueKey('model-provider-row'),
        controller: _providerRow,
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final p in base) ...[
              _ProviderPill(
                key: p.slug == open?.slug ? _selectedPillKey : null,
                provider: p,
                name: names[p.slug] ?? p.slug,
                on: p.slug == open?.slug,
                status: modelProviderStatus(
                  p,
                  anyUsable: p.models.any(
                    (id) => widget.cardInfo(p.slug, id).usable,
                  ),
                ),
                usable: p.models.any(
                  (id) => widget.cardInfo(p.slug, id).usable,
                ),
                onTap: () => _openProviderPill(p),
              ),
              const SizedBox(width: _kPillGap),
            ],
          ],
        ),
      ),
    );
  }
}

/// One short tag: why this model is worth choosing, or why not.
String? _modelTag(
  Strings strings,
  ModelProvider provider,
  SessionModelCardInfo info,
) {
  if (!info.usable) return strings.chaModelUnavailable;
  if (provider.source == 'local-runtime') return strings.mdlPillTagLocal;
  if (info.reasoning == true) return strings.sp1215CapReasoning;
  if (info.fast == true) return strings.sp1215CapFast;
  if (info.free) return strings.sp1215CapFree;
  return null;
}

/// The account Hermes names for [provider], when it names exactly one.
String? _accountLabel(ModelProvider provider) {
  final labels = [
    for (final account
        in provider.usage?.accounts ?? const <ProviderUsageAccount>[])
      if (account.label.trim().isNotEmpty) account.label.trim(),
  ];
  return labels.length == 1 ? labels.first : null;
}

/// «Provider · account» (or the tag) under a model's name.
String _rowDetail(
  Strings strings,
  ModelProvider provider,
  String providerName,
  SessionModelCardInfo info, {
  bool withAccount = false,
}) => [
  providerName,
  if (withAccount) ?_accountLabel(provider),
  ?_modelTag(strings, provider, info),
].join(' · ');

/// "No model is available": the way to a Nous Portal account, shown when
/// nothing in the sheet can be picked.
class _ConnectAccountRow extends StatelessWidget {
  const _ConnectAccountRow({required this.onTap, super.key});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.only(top: HermesSpace.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.nacSheetNoAccountHint,
            style: TextStyle(
              fontSize: HermesType.supportSize,
              color: colors.textSecondary,
            ),
          ),
          TextButton.icon(
            key: const ValueKey('model-sheet-connect-account-button'),
            onPressed: onTap,
            icon: const Icon(Icons.login_rounded, size: 18),
            label: Text(strings.nacSheetConnect),
          ),
        ],
      ),
    );
  }
}

/// Small caps label of a block of the sheet.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      header: true,
      child: Text(
        text.toUpperCase(),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: HermesType.captionSize,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.9,
          color: colors.textSecondary,
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.trailing, super.key});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _SectionLabel(text)),
        ?trailing,
      ],
    );
  }
}

class _SearchButton extends StatelessWidget {
  const _SearchButton({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Tooltip(
      message: strings.mdlPillSearchTooltip,
      child: Semantics(
        button: true,
        toggled: active,
        label: strings.mdlPillSearchTooltip,
        excludeSemantics: true,
        child: InkResponse(
          key: const ValueKey('model-search-toggle'),
          onTap: onTap,
          radius: HermesSpace.x6,
          child: SizedBox.square(
            dimension: HermesSpace.x8 + HermesSpace.x4,
            child: Center(
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  shape: CircleBorder(
                    side: BorderSide(
                      color: active
                          ? colors.accent
                          : hermesSheetOutline(colors),
                    ),
                  ),
                  color: _pillFill(colors, on: active),
                ),
                child: SizedBox.square(
                  dimension: HermesSpace.x8 + HermesSpace.x2,
                  child: Icon(
                    active ? Icons.close_rounded : Icons.search_rounded,
                    size: HermesSpace.x4 + HermesSpace.x1,
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.hint,
    required this.onChanged,
    super.key,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: StadiumBorder(side: BorderSide(color: colors.accent)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _kSearchHeight),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x4),
          child: TextField(
            key: const ValueKey('chat-model-search'),
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: onChanged,
            style: TextStyle(
              fontSize: HermesType.textSize,
              color: colors.textPrimary,
            ),
            decoration: InputDecoration(
              hintText: hint,
              isDense: true,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              hintStyle: TextStyle(
                fontSize: HermesType.textSize,
                color: colors.textTertiary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OptionPill extends StatelessWidget {
  const _OptionPill({
    required this.label,
    required this.on,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool on;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return _Pill(
      on: on,
      toggled: on,
      onTap: onTap,
      minHeight: _kOptionPillHeight,
      padding: const EdgeInsets.symmetric(
        horizontal: HermesSpace.x4,
        vertical: HermesSpace.x1,
      ),
      semanticsLabel: label,
      child: Center(
        widthFactor: 1,
        child: Text(
          label,
          style: TextStyle(
            fontSize: HermesType.supportSize,
            fontWeight: on ? FontWeight.w700 : FontWeight.w500,
            color: on ? colors.textPrimary : colors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _ProviderPill extends StatelessWidget {
  const _ProviderPill({
    required this.provider,
    required this.name,
    required this.on,
    required this.status,
    required this.usable,
    required this.onTap,
    super.key,
  });

  final ModelProvider provider;
  final String name;
  final bool on;
  final ModelProviderStatus status;
  final bool usable;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final dot = switch (status) {
      ModelProviderStatus.ready => colors.success,
      ModelProviderStatus.near => colors.warning,
      ModelProviderStatus.down => colors.error,
    };
    final statusText = switch (status) {
      ModelProviderStatus.ready => null,
      ModelProviderStatus.near => strings.sp1215LimitNear,
      ModelProviderStatus.down => usable ? null : strings.chaModelUnavailable,
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: _Pill(
        key: ValueKey('model-provider-pill-${provider.slug}'),
        on: on,
        faded: !usable,
        onTap: onTap,
        minHeight: _kProviderPillHeight,
        padding: const EdgeInsetsDirectional.only(
          start: HermesSpace.x1,
          end: HermesSpace.x4,
          top: HermesSpace.x1,
          bottom: HermesSpace.x1,
        ),
        semanticsLabel: statusText == null ? name : '$name. $statusText',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: HermesChrome.of(colors).opaque,
              ),
              child: SizedBox.square(
                dimension: _kLogoDot,
                child: Center(
                  child: ProviderLogo(
                    key: ValueKey(
                      'provider-logo-picker-provider-${provider.slug}',
                    ),
                    provider: provider.slug,
                    providerName: provider.name,
                    size: HermesSpace.x4,
                    selected: on,
                  ),
                ),
              ),
            ),
            const SizedBox(width: HermesSpace.x2),
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: HermesType.supportSize,
                  fontWeight: FontWeight.w600,
                  color: on ? colors.textPrimary : colors.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: HermesSpace.x2),
            DecoratedBox(
              key: ValueKey('model-provider-dot-${provider.slug}'),
              decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
              child: const SizedBox.square(dimension: _kStatusDot),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelPill extends StatelessWidget {
  const _ModelPill({
    required this.provider,
    required this.providerName,
    required this.modelId,
    required this.label,
    required this.info,
    required this.active,
    required this.highlight,
    required this.showProvider,
    required this.showId,
    required this.onPick,
    required this.starred,
    required this.starEnabled,
    required this.onStar,
    super.key,
  });

  final ModelProvider provider;
  final String providerName;
  final String modelId;
  final String label;
  final SessionModelCardInfo info;
  final bool active;

  /// Text the search is looking for, marked in the name; empty for none.
  final String highlight;

  /// Search results name their provider before the tag.
  final bool showProvider;

  /// Name the raw model id too (another model has the same friendly name).
  final bool showId;
  final void Function(ModelProvider provider, String modelId)? onPick;

  /// Whether the model is in the favourites, and whether its star can change
  /// that now (a full list only lets stars go).
  final bool starred;
  final bool starEnabled;
  final void Function(ModelProvider provider, String modelId)? onStar;

  List<InlineSpan> _nameSpans(HermesThemeColors colors) {
    final needle = highlight.toLowerCase();
    final at = needle.isEmpty ? -1 : label.toLowerCase().indexOf(needle);
    if (at < 0) return [TextSpan(text: label)];
    return [
      TextSpan(text: label.substring(0, at)),
      TextSpan(
        text: label.substring(at, at + needle.length),
        style: TextStyle(color: colors.accentText),
      ),
      TextSpan(text: label.substring(at + needle.length)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final pick = onPick;
    final enabled = pick != null && info.usable && !active;
    void select() => pick?.call(provider, modelId);
    final detail = [
      if (showProvider) providerName,
      if (showId) modelId,
      ?_modelTag(strings, provider, info),
    ].join(' · ');
    final large = MediaQuery.textScalerOf(context).scale(10) > 13;
    return Material(
      color: _pillFill(colors, on: active),
      shape: StadiumBorder(
        side: BorderSide(
          color: active ? colors.accent : hermesSheetOutline(colors),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _kModelPillHeight),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: InkWell(
                  onTap: enabled ? select : null,
                  excludeFromSemantics: true,
                  child: Semantics(
                    container: true,
                    button: true,
                    selected: active,
                    enabled: info.usable,
                    label: detail.isEmpty ? label : '$label. $detail',
                    excludeSemantics: true,
                    onTap: enabled ? select : null,
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: HermesSpace.x4,
                        top: HermesSpace.x1,
                        bottom: HermesSpace.x1,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text.rich(
                              TextSpan(
                                style: TextStyle(
                                  fontSize: HermesType.textSize,
                                  fontWeight: FontWeight.w700,
                                  color: info.usable
                                      ? colors.textPrimary
                                      : colors.textDisabled,
                                ),
                                children: _nameSpans(colors),
                              ),
                              maxLines: large ? 2 : 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (detail.isNotEmpty) ...[
                            const SizedBox(width: HermesSpace.x2),
                            Flexible(
                              child: Text(
                                detail,
                                maxLines: large ? 2 : 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.end,
                                style: TextStyle(
                                  fontSize: HermesType.captionSize,
                                  color: colors.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _StarButton(
                key: ValueKey('msv-star-${provider.slug}-$modelId'),
                starred: starred,
                enabled: starEnabled && onStar != null,
                label: label,
                onTap: () => onStar?.call(provider, modelId),
              ),
              _SelectTap(on: active, onTap: enabled ? select : null),
            ],
          ),
        ),
      ),
    );
  }
}

/// A favourite on page one: provider circle, name, «provider · tag», the
/// filled star that takes it off the list and the round selector.
class _FavoritePill extends StatelessWidget {
  const _FavoritePill({
    required this.provider,
    required this.providerName,
    required this.modelId,
    required this.label,
    required this.info,
    required this.active,
    required this.starred,
    required this.starEnabled,
    required this.onPick,
    required this.onStar,
    super.key,
  });

  final ModelProvider provider;
  final String providerName;
  final String modelId;
  final String label;
  final SessionModelCardInfo info;
  final bool active;
  final bool starred;
  final bool starEnabled;
  final void Function(ModelProvider provider, String modelId)? onPick;
  final void Function(ModelProvider provider, String modelId)? onStar;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final pick = onPick;
    final enabled = pick != null && info.usable && !active;
    void select() => pick?.call(provider, modelId);
    final detail = _rowDetail(strings, provider, providerName, info);
    return Material(
      color: _pillFill(colors, on: active),
      shape: StadiumBorder(
        side: BorderSide(
          color: active ? colors.accent : hermesSheetOutline(colors),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _kFavoriteHeight),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: InkWell(
                  onTap: enabled ? select : null,
                  excludeFromSemantics: true,
                  child: Semantics(
                    container: true,
                    button: true,
                    selected: active,
                    enabled: info.usable,
                    label: '$label. $detail',
                    excludeSemantics: true,
                    onTap: enabled ? select : null,
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: HermesSpace.x2,
                        top: HermesSpace.x1,
                        bottom: HermesSpace.x1,
                      ),
                      child: Row(
                        children: [
                          _LogoDot(
                            provider: provider.slug,
                            providerName: provider.name,
                            dimension: _kFavoriteLogo,
                          ),
                          const SizedBox(width: HermesSpace.x3),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  label,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: HermesType.textSize,
                                    fontWeight: FontWeight.w700,
                                    color: info.usable
                                        ? colors.textPrimary
                                        : colors.textTertiary,
                                  ),
                                ),
                                Text(
                                  detail,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: HermesType.captionSize,
                                    color: colors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _StarButton(
                key: ValueKey('msv-star-${provider.slug}-$modelId'),
                starred: starred,
                enabled: starEnabled && onStar != null,
                label: label,
                onTap: () => onStar?.call(provider, modelId),
              ),
              _SelectTap(on: active, onTap: enabled ? select : null),
            ],
          ),
        ),
      ),
    );
  }
}

/// The round selector as the tail of a row: a wide tap area round the dot.
class _SelectTap extends StatelessWidget {
  const _SelectTap({required this.on, required this.onTap});

  final bool on;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      excludeFromSemantics: true,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: HermesSpace.x2,
          end: HermesSpace.x4,
        ),
        child: Center(
          child: ExcludeSemantics(child: _SelectDot(on: on)),
        ),
      ),
    );
  }
}

/// The star of a model row: filled when the model is a favourite. It is its
/// own button for the screen reader, outside the row's selection.
class _StarButton extends StatelessWidget {
  const _StarButton({
    required this.starred,
    required this.enabled,
    required this.label,
    required this.onTap,
    super.key,
  });

  final bool starred;
  final bool enabled;

  /// The model's name.
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final text = starred
        ? strings.msvFavRemove(label)
        : enabled
        ? strings.msvFavAdd(label)
        : strings.msvFavLimit(ModelFavorites.maxEntries);
    return Tooltip(
      message: text,
      child: Semantics(
        container: true,
        button: true,
        toggled: starred,
        enabled: enabled,
        label: text,
        excludeSemantics: true,
        onTap: enabled ? onTap : null,
        child: InkResponse(
          onTap: enabled ? onTap : null,
          excludeFromSemantics: true,
          radius: HermesSpace.x6,
          child: SizedBox(
            width: HermesSpace.tap - HermesSpace.x1,
            child: Center(
              child: Opacity(
                opacity: enabled || starred ? 1 : _kDimmed,
                child: Icon(
                  starred ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: HermesIcon.xl,
                  color: starred ? colors.accentText : colors.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A provider's circle: its logo on the opaque surface.
class _LogoDot extends StatelessWidget {
  const _LogoDot({
    required this.provider,
    required this.providerName,
    required this.dimension,
  });

  final String? provider;
  final String? providerName;
  final double dimension;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: HermesChrome.of(colors).opaque,
      ),
      child: SizedBox.square(
        dimension: dimension,
        child: Center(
          child: ProviderLogo(
            provider: provider,
            providerName: providerName,
            size: dimension * 0.6,
          ),
        ),
      ),
    );
  }
}

/// The current model as a long pill; it opens page two.
class _CurrentCard extends StatelessWidget {
  const _CurrentCard({
    required this.provider,
    required this.providerName,
    required this.modelId,
    required this.label,
    required this.detail,
    required this.onTap,
    this.loading = false,
    this.providerSlug,
    super.key,
  });

  final bool loading;
  final String? providerSlug;
  final ModelProvider? provider;
  final String? providerName;
  final String? modelId;
  final String label;
  final String? detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return _Pill(
      on: true,
      onTap: onTap,
      minHeight: _kCurrentHeight,
      padding: const EdgeInsetsDirectional.only(
        start: HermesSpace.x3,
        end: HermesSpace.x4,
        top: HermesSpace.x2,
        bottom: HermesSpace.x2,
      ),
      semanticsLabel: [
        label,
        if (detail != null && detail!.isNotEmpty) detail!,
        strings.msvCurrentHint,
      ].join('. '),
      child: Row(
        children: [
          if (provider != null || providerSlug?.isNotEmpty == true)
            _LogoDot(
              provider: provider?.slug ?? providerSlug,
              providerName: provider?.name ?? providerSlug,
              dimension: _kCurrentLogo,
            )
          else
            Icon(
              loading ? Icons.hourglass_top_rounded : Icons.smart_toy_outlined,
              size: _kCurrentLogo,
              color: colors.textSecondary,
            ),
          const SizedBox(width: HermesSpace.x3),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: HermesType.bodySize,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                if (detail != null && detail!.isNotEmpty)
                  Text(
                    detail!,
                    maxLines: MediaQuery.textScalerOf(context).scale(1) > 1.3
                        ? null
                        : 2,
                    overflow: MediaQuery.textScalerOf(context).scale(1) > 1.3
                        ? null
                        : TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: HermesType.captionSize,
                      color: colors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: HermesSpace.x2),
          Icon(Icons.chevron_right_rounded, color: colors.textSecondary),
        ],
      ),
    );
  }
}

const TextStyle _kTileTitleStyle = TextStyle(
  fontSize: HermesType.supportSize,
  fontWeight: FontWeight.w700,
);
const TextStyle _kTileStateStyle = TextStyle(fontSize: HermesType.captionSize);

/// How the two chips of page one lay out, both alike.
enum _ChipLayout {
  /// Side by side, each with its glyph.
  full,

  /// Side by side without the glyph (large text).
  noGlyph,

  /// One above the other.
  stacked,
}

/// A selection button with an explicit state and checkmark. The entire
/// surface is the touch target; unsupported settings explain why.
class _SettingTile extends StatelessWidget {
  const _SettingTile({
    required this.icon,
    required this.title,
    required this.state,
    required this.on,
    required this.onTap,
    required this.minHeight,
    this.glyph = true,
    this.dim = false,
    this.reason,
    super.key,
  });

  final double minHeight;
  final IconData icon;
  final String title;
  final String state;
  final bool on;
  final VoidCallback? onTap;
  final bool dim;
  final String? reason;

  /// Whether the glyph is drawn (not with large text in half the width).
  final bool glyph;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final duration = HermesMotion.duration(context, HermesMotion.fast);
    final glyphIcon = TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: on ? colors.accentText : colors.textSecondary),
      duration: duration,
      builder: (context, color, _) =>
          Icon(icon, size: HermesIcon.lg, color: color),
    );
    final words = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: _kTileTitleStyle.copyWith(color: colors.textPrimary),
        ),
        Text(
          reason ?? state,
          style: _kTileStateStyle.copyWith(
            color: on ? colors.accentText : colors.textSecondary,
          ),
        ),
      ],
    );
    final usable = onTap != null && !dim;
    return _Pill(
      on: on,
      dim: dim,
      toggled: on,
      onTap: usable
          ? () {
              HermesHaptics.selection();
              onTap!();
            }
          : null,
      minHeight: minHeight,
      padding: const EdgeInsets.symmetric(
        horizontal: HermesSpace.x3,
        vertical: HermesSpace.x2,
      ),
      semanticsLabel: [title, state, ?reason].join('. '),
      child: Row(
        children: [
          if (glyph) ...[glyphIcon, const SizedBox(width: HermesSpace.x2)],
          Expanded(child: words),
          const SizedBox(width: HermesSpace.x2),
          Icon(
            on ? Icons.check_circle_rounded : Icons.circle_outlined,
            size: HermesIcon.md,
            color: on ? colors.accentText : colors.textSecondary,
          ),
        ],
      ),
    );
  }
}

/// A round outlined button (the back button of page two).
class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Tooltip(
      message: label,
      child: Semantics(
        container: true,
        button: true,
        label: label,
        excludeSemantics: true,
        child: InkResponse(
          onTap: onTap,
          radius: HermesSpace.x6,
          child: SizedBox.square(
            dimension: HermesSpace.x8 + HermesSpace.x4,
            child: Center(
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  shape: CircleBorder(
                    side: BorderSide(color: hermesSheetOutline(colors)),
                  ),
                  color: _pillFill(colors, on: false),
                ),
                child: SizedBox.square(
                  dimension: HermesSpace.x8 + HermesSpace.x2,
                  child: Icon(
                    icon,
                    size: HermesSpace.x4 + HermesSpace.x1,
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The round selector at the start of a model pill: an empty ring (3:1 on
/// the sheet), and once chosen the accent ring with the accent filling it.
class _SelectDot extends StatelessWidget {
  const _SelectDot({required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return DecoratedBox(
      key: ValueKey(on ? 'model-select-dot-on' : 'model-select-dot-off'),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: on ? colors.accent : hermesSheetRing(colors),
          width: 2,
        ),
      ),
      child: SizedBox.square(
        dimension: HermesSpace.x4 + 2,
        child: on
            ? Padding(
                padding: const EdgeInsets.all(2),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.accent,
                  ),
                ),
              )
            : null,
      ),
    );
  }
}

/// Stepped control for the session's reasoning effort: one step per level
/// Console already knows ([DesktopReasoningEffort], in order), drawn by the
/// shared [HermesReasoningPill].
class ReasoningStepSlider extends StatelessWidget {
  const ReasoningStepSlider({
    required this.value,
    required this.supported,
    required this.onChanged,
    super.key,
  });

  /// Null while the session has no explicit level.
  final DesktopReasoningEffort? value;

  /// False when the model does not take an adjustable level.
  final bool supported;

  /// Null disables the control (a change is already being applied).
  final ValueChanged<DesktopReasoningEffort>? onChanged;

  static String _impact(Strings strings, DesktopReasoningEffort? effort) =>
      switch (effort) {
        null => strings.modelPickerImpactDefault,
        DesktopReasoningEffort.none => strings.modelPickerImpactOff,
        DesktopReasoningEffort.minimal ||
        DesktopReasoningEffort.low => strings.modelPickerImpactLight,
        DesktopReasoningEffort.medium => strings.modelPickerImpactBalanced,
        _ => strings.modelPickerImpactDeep,
      };

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final change = onChanged;
    return HermesReasoningPill(
      levels: [
        for (final effort in DesktopReasoningEffort.values)
          HermesReasoningLevel(
            effort.wire,
            reasoningEffortLabel(strings, effort),
          ),
      ],
      value: value?.wire,
      supported: supported,
      title: strings.chaSessionReasoningLabel,
      defaultLabel: strings.modelPickerLevelDefault,
      unavailableText: strings.chaModelReasoningUnavailable,
      impactOf: (wire) => _impact(
        strings,
        DesktopReasoningEffort.values
            .where((effort) => effort.wire == wire)
            .firstOrNull,
      ),
      onChanged: change == null
          ? null
          : (wire) => change(
              DesktopReasoningEffort.values.firstWhere(
                (effort) => effort.wire == wire,
              ),
            ),
    );
  }
}
