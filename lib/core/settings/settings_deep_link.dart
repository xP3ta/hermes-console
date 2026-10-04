import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'settings_search.dart';

/// A search result that leads to a section of the main Settings screen: the
/// section scrolls into view and is highlighted once.
abstract final class SettingsDeepLink {
  /// The section waiting to be shown; the [SettingsDeepLinkScope] of the open
  /// Settings screen consumes it.
  static final ValueNotifier<SettingsSection?> pending = ValueNotifier(null);

  static void request(SettingsSection section) => pending.value = section;
}

class _ScopeData extends InheritedWidget {
  final Map<SettingsSection, GlobalKey> keys;
  final ValueNotifier<SettingsSection?> highlighted;

  const _ScopeData({
    required this.keys,
    required this.highlighted,
    required super.child,
  });

  @override
  bool updateShouldNotify(_ScopeData oldWidget) => false;
}

/// Owns the scroll controller of the main Settings list and answers
/// [SettingsDeepLink] requests: it scrolls the list until the section is
/// built, brings it into view and highlights it once. [sections] are the
/// ones it hosts (each wrapped in a [SettingsDeepLinkTarget] below it); a
/// request for any other is left alone.
class SettingsDeepLinkScope extends StatefulWidget {
  final Set<SettingsSection> sections;
  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  const SettingsDeepLinkScope({
    super.key,
    required this.sections,
    required this.builder,
  });

  @override
  State<SettingsDeepLinkScope> createState() => _SettingsDeepLinkScopeState();
}

class _SettingsDeepLinkScopeState extends State<SettingsDeepLinkScope> {
  static const _highlightFor = Duration(seconds: 2);
  static const _maxSteps = 60;

  final ScrollController _controller = ScrollController();
  final Map<SettingsSection, GlobalKey> _keys = {
    for (final section in SettingsSection.values) section: GlobalKey(),
  };
  final ValueNotifier<SettingsSection?> _highlighted = ValueNotifier(null);
  Timer? _timer;
  bool _revealing = false;

  @override
  void initState() {
    super.initState();
    SettingsDeepLink.pending.addListener(_onRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onRequest());
  }

  @override
  void dispose() {
    SettingsDeepLink.pending.removeListener(_onRequest);
    _timer?.cancel();
    _controller.dispose();
    _highlighted.dispose();
    super.dispose();
  }

  void _onRequest() {
    final section = SettingsDeepLink.pending.value;
    if (!mounted ||
        section == null ||
        _revealing ||
        !widget.sections.contains(section)) {
      return;
    }
    SettingsDeepLink.pending.value = null;
    _revealing = true;
    _step(section, 0);
  }

  void _step(SettingsSection section, int attempt) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = _keys[section]!.currentContext;
      if (context != null) {
        unawaited(
          Scrollable.ensureVisible(
            context,
            duration: const Duration(milliseconds: 200),
            alignment: .1,
          ),
        );
        _highlighted.value = section;
        _timer?.cancel();
        _timer = Timer(_highlightFor, () {
          if (mounted) _highlighted.value = null;
        });
        _revealing = false;
        return;
      }
      // Not built yet: the list builds lazily, so walk down until it is.
      if (!_controller.hasClients || attempt >= _maxSteps) {
        _revealing = false;
        return;
      }
      final position = _controller.position;
      if (position.pixels >= position.maxScrollExtent) {
        _revealing = false;
        return;
      }
      _controller.jumpTo(
        (position.pixels + position.viewportDimension * .8).clamp(
          0.0,
          position.maxScrollExtent,
        ),
      );
      _step(section, attempt + 1);
    });
  }

  @override
  Widget build(BuildContext context) => _ScopeData(
    keys: _keys,
    highlighted: _highlighted,
    child: Builder(builder: (context) => widget.builder(context, _controller)),
  );
}

/// Wraps one section of the main Settings screen so a [SettingsDeepLink]
/// request for it can find it, and highlights it once when it is shown.
class SettingsDeepLinkTarget extends StatelessWidget {
  final SettingsSection section;
  final Widget child;

  const SettingsDeepLinkTarget({
    super.key,
    required this.section,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final data = context.getInheritedWidgetOfExactType<_ScopeData>();
    if (data == null) return child;
    return KeyedSubtree(
      key: data.keys[section],
      child: ValueListenableBuilder<SettingsSection?>(
        valueListenable: data.highlighted,
        child: child,
        builder: (context, highlighted, child) {
          if (highlighted != section) return child!;
          return DecoratedBox(
            key: ValueKey('settings-highlight-${section.name}'),
            decoration: BoxDecoration(
              color: Theme.of(context).hermes.accent.withValues(alpha: .14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: child,
          );
        },
      ),
    );
  }
}
