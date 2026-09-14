import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'chat_surface_coordinator.dart';

/// Detached Bot Mode dock with two keyed create orbs on one shared axis.
class BotModeDock extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback? onCreateBot;
  final VoidCallback? onCreateRoom;
  final String? createRoomLabel;
  final ChatSurfaceCoordinator? coordinator;

  const BotModeDock({
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.onCreateBot,
    this.onCreateRoom,
    this.createRoomLabel,
    this.coordinator,
    super.key,
  });

  @override
  State<BotModeDock> createState() => _BotModeDockState();
}

class _BotModeDockState extends State<BotModeDock>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  late ChatSurfaceCoordinator _coordinator;
  late bool _ownsCoordinator;
  final FocusNode _createFocus = FocusNode(debugLabel: 'Bot Mode create');
  final FocusNode _botFocus = FocusNode(debugLabel: 'Create bot');
  bool _expanded = false;
  bool _actionsMounted = false;
  int _motionGeneration = 0;

  Duration _duration(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 220);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ownsCoordinator = widget.coordinator == null;
    _coordinator =
        widget.coordinator ??
        ChatSurfaceCoordinator(routeOwner: identityHashCode(this));
    _coordinator.addListener(_onCoordinatorChanged);
    _controller = AnimationController(vsync: this, duration: Duration.zero);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = _duration(context);
    _controller.reverseDuration = _duration(context);
  }

  @override
  void didUpdateWidget(covariant BotModeDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.coordinator, widget.coordinator)) {
      _coordinator.removeListener(_onCoordinatorChanged);
      if (_ownsCoordinator) _coordinator.dispose();
      _ownsCoordinator = widget.coordinator == null;
      _coordinator =
          widget.coordinator ??
          ChatSurfaceCoordinator(routeOwner: identityHashCode(this));
      _coordinator.addListener(_onCoordinatorChanged);
    }
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      unawaited(_close(returnFocus: false));
    }
  }

  void _onCoordinatorChanged() {
    if (!_coordinator.createExpanded && _expanded) {
      unawaited(_close(returnFocus: false, updateCoordinator: false));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _coordinator.handleLifecycle(state);
  }

  Future<void> _open() async {
    if (_expanded) {
      await _close();
      return;
    }
    final generation = ++_motionGeneration;
    _expanded = true;
    _actionsMounted = true;
    _coordinator.openCreate();
    if (_controller.value == 0 && _duration(context) != Duration.zero) {
      // The first painted frame must already communicate departure from the
      // plus origin; subsequent ticks continue from this exact painted value.
      _controller.value = 0.001;
    }
    if (mounted) setState(() {});
    await _controller.animateTo(
      1,
      duration: _duration(context),
      curve: Curves.easeOutCubic,
    );
    if (mounted && _expanded && generation == _motionGeneration) {
      _coordinator.claimFocus(_botFocus);
    }
  }

  Future<void> _close({
    bool returnFocus = true,
    bool updateCoordinator = true,
  }) async {
    if (!_expanded && !_actionsMounted) return;
    final generation = ++_motionGeneration;
    _expanded = false;
    if (updateCoordinator) _coordinator.closeCreate();
    if (mounted) setState(() {});
    await _controller.animateTo(
      0,
      duration: _duration(context),
      curve: Curves.easeInCubic,
    );
    if (!mounted || generation != _motionGeneration || _expanded) return;
    setState(() => _actionsMounted = false);
    if (returnFocus) _coordinator.claimFocus(_createFocus);
  }

  void _toggleCreate() {
    if (_expanded) {
      unawaited(_close());
    } else {
      unawaited(_open());
    }
  }

  void _select(int index) {
    unawaited(_close(returnFocus: false));
    if (index != widget.selectedIndex) widget.onDestinationSelected(index);
  }

  void _runCreate(VoidCallback? action) {
    if (action == null) return;
    unawaited(_close(returnFocus: false));
    action();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _coordinator.removeListener(_onCoordinatorChanged);
    if (_ownsCoordinator) _coordinator.dispose();
    _controller.dispose();
    _createFocus.dispose();
    _botFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final compact = MediaQuery.textScalerOf(context).scale(14) > 17;
    return PopScope(
      canPop: !_expanded,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _expanded) unawaited(_close());
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final dockBottom = _coordinator.bottomInset;
          final plusCenter = Offset(
            constraints.maxWidth / 2,
            constraints.maxHeight - dockBottom - 24,
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              if (_actionsMounted)
                Positioned.fill(
                  child: GestureDetector(
                    key: const ValueKey('bot-mode-create-outside'),
                    behavior: HitTestBehavior.translucent,
                    onTap: _close,
                  ),
                ),
              if (_actionsMounted)
                Positioned.fill(
                  key: const ValueKey('bot-mode-create-actions'),
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      final botValue = Curves.easeOutCubic.transform(
                        _staggered(_controller.value, 0),
                      );
                      final roomValue = Curves.easeOutCubic.transform(
                        _staggered(_controller.value, 38 / 220),
                      );
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          _positionedOrb(
                            plusCenter: plusCenter,
                            finalCenterY: plusCenter.dy - 132,
                            value: botValue,
                            child: _CreateOrb(
                              controlKey: const ValueKey('bot-mode-create-bot'),
                              label: strings.missionCreateBotLabel,
                              icon: Icons.smart_toy_outlined,
                              enabled: widget.onCreateBot != null,
                              focusNode: _botFocus,
                              progress: botValue,
                              onTap: () => _runCreate(widget.onCreateBot),
                            ),
                          ),
                          _positionedOrb(
                            plusCenter: plusCenter,
                            finalCenterY: plusCenter.dy - 68,
                            value: roomValue,
                            child: _CreateOrb(
                              controlKey: const ValueKey(
                                'bot-mode-create-room',
                              ),
                              label:
                                  widget.createRoomLabel ??
                                  strings.missionCreateRoomLabel,
                              icon: Icons.groups_2_outlined,
                              enabled: widget.onCreateRoom != null,
                              progress: roomValue,
                              onTap: () => _runCreate(widget.onCreateRoom),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              Positioned(
                left: 16,
                right: 16,
                bottom: dockBottom,
                child: Center(
                  child: Material(
                    key: const ValueKey('bot-mode-floating-dock'),
                    color: colors.surface.withValues(alpha: 0.98),
                    elevation: 8,
                    shadowColor: Colors.black.withValues(alpha: 0.28),
                    shape: StadiumBorder(
                      side: BorderSide(
                        color: colors.divider.withValues(alpha: 0.72),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(
                      height: 48,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _DockDestination(
                            controlKey: const ValueKey('bot-mode-dock-bots'),
                            semanticsKey: const ValueKey(
                              'mission-destination-bots',
                            ),
                            label: strings.missionBotsLabel,
                            icon: Icons.smart_toy_outlined,
                            selectedIcon: Icons.smart_toy_rounded,
                            selected: widget.selectedIndex == 0,
                            compact: compact,
                            onTap: () => _select(0),
                          ),
                          _CreateDockButton(
                            expanded: _expanded,
                            label: strings.missionCreateLabel,
                            focusNode: _createFocus,
                            onTap: _toggleCreate,
                          ),
                          _DockDestination(
                            controlKey: const ValueKey('bot-mode-dock-work'),
                            semanticsKey: const ValueKey(
                              'mission-destination-work',
                            ),
                            label: strings.missionWorkLabel,
                            icon: Icons.work_outline_rounded,
                            selectedIcon: Icons.work_rounded,
                            selected: widget.selectedIndex == 1,
                            compact: compact,
                            onTap: () => _select(1),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _positionedOrb({
    required Offset plusCenter,
    required double finalCenterY,
    required double value,
    required Widget child,
  }) => Positioned(
    left: plusCenter.dx - 24,
    top: finalCenterY - 28 + (plusCenter.dy - finalCenterY) * (1 - value),
    child: child,
  );

  double _staggered(double value, double delay) {
    if (_duration(context) == Duration.zero) return value == 0 ? 0 : 1;
    return ((value - delay) / (1 - delay)).clamp(0, 1);
  }
}

class _CreateDockButton extends StatelessWidget {
  final bool expanded;
  final String label;
  final FocusNode focusNode;
  final VoidCallback onTap;

  const _CreateDockButton({
    required this.expanded,
    required this.label,
    required this.focusNode,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    toggled: expanded,
    label: label,
    child: Tooltip(
      message: label,
      child: InkWell(
        key: const ValueKey('bot-mode-dock-create'),
        focusNode: focusNode,
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox.square(
          dimension: 48,
          child: AnimatedRotation(
            turns: expanded ? 0.125 : 0,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: const Icon(Icons.add_rounded),
          ),
        ),
      ),
    ),
  );
}

class _DockDestination extends StatelessWidget {
  final Key controlKey;
  final Key semanticsKey;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  const _DockDestination({
    required this.controlKey,
    required this.semanticsKey,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      key: semanticsKey,
      button: true,
      selected: selected,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: InkWell(
          key: controlKey,
          onTap: onTap,
          child: SizedBox(
            width: compact ? 64 : 136,
            height: 48,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    selected ? selectedIcon : icon,
                    size: 21,
                    color: selected ? colors.accentText : colors.textSecondary,
                  ),
                  if (!compact) ...[
                    const SizedBox(width: 7),
                    Text(
                      label,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CreateOrb extends StatelessWidget {
  final Key controlKey;
  final String label;
  final IconData icon;
  final bool enabled;
  final double progress;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  const _CreateOrb({
    required this.controlKey,
    required this.label,
    required this.icon,
    required this.enabled,
    required this.progress,
    required this.onTap,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Opacity(
      opacity: progress,
      child: Transform.scale(
        scale: 0.18 + (0.82 * progress),
        alignment: const Alignment(-2 / 3, 0),
        child: Semantics(
          button: true,
          enabled: enabled,
          label: label,
          excludeSemantics: true,
          child: Tooltip(
            message: label,
            child: SizedBox(
              width: 144,
              height: 56,
              child: Row(
                children: [
                  Material(
                    color: colors.surface,
                    elevation: 7,
                    shape: const CircleBorder(),
                    child: InkWell(
                      key: controlKey,
                      focusNode: focusNode,
                      customBorder: const CircleBorder(),
                      onTap: enabled ? onTap : null,
                      child: SizedBox.square(
                        dimension: 48,
                        child: Icon(
                          icon,
                          color: enabled
                              ? colors.accentText
                              : colors.textDisabled,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      key: ValueKey('bot-mode-create-visible-label'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: enabled
                            ? colors.textPrimary
                            : colors.textDisabled,
                        fontSize: 13,
                        height: 1.05,
                        fontWeight: FontWeight.w700,
                        shadows: const [
                          Shadow(color: Colors.black87, blurRadius: 7),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
