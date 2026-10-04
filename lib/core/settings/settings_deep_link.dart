import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'settings_search.dart';

/// A search result that leads to a section of the main Settings screen: the
/// section scrolls into view and is highlighted once.
abstract final class SettingsDeepLink {
  /// The section waiting to be shown; its [SettingsDeepLinkTarget] consumes it.
  static final ValueNotifier<SettingsSection?> pending = ValueNotifier(null);

  static void request(SettingsSection section) => pending.value = section;
}

/// Wraps one section of the main Settings screen so a [SettingsDeepLink]
/// request for it scrolls to it and highlights it once. The list that holds
/// it has to keep sections far from the viewport built (a large `cacheExtent`),
/// or there is nothing to scroll to.
class SettingsDeepLinkTarget extends StatefulWidget {
  final SettingsSection section;
  final Widget child;

  const SettingsDeepLinkTarget({
    super.key,
    required this.section,
    required this.child,
  });

  @override
  State<SettingsDeepLinkTarget> createState() => _SettingsDeepLinkTargetState();
}

class _SettingsDeepLinkTargetState extends State<SettingsDeepLinkTarget> {
  static const _highlightFor = Duration(seconds: 2);

  Timer? _timer;
  bool _highlighted = false;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    SettingsDeepLink.pending.addListener(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    SettingsDeepLink.pending.removeListener(_check);
    _timer?.cancel();
    super.dispose();
  }

  void _check() {
    if (!mounted ||
        _scheduled ||
        SettingsDeepLink.pending.value != widget.section) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || SettingsDeepLink.pending.value != widget.section) return;
      SettingsDeepLink.pending.value = null;
      unawaited(
        Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 200),
          alignment: .1,
        ),
      );
      setState(() => _highlighted = true);
      _timer?.cancel();
      _timer = Timer(_highlightFor, () {
        if (mounted) setState(() => _highlighted = false);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_highlighted) return widget.child;
    return DecoratedBox(
      key: ValueKey('settings-highlight-${widget.section.name}'),
      decoration: BoxDecoration(
        color: Theme.of(context).hermes.accent.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: widget.child,
    );
  }
}
