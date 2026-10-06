import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../shell/gesture_dock_state.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_ui.dart';

/// Ajustes › Dock while the gesture dock is on: when it hides, gestures,
/// glass or solid, and the way to Trucos y gestos.
class GestureDockSettingsScreen extends StatelessWidget {
  final GestureDockController? controller;

  const GestureDockSettingsScreen({this.controller, super.key});

  @override
  Widget build(BuildContext context) {
    final c = controller ?? GestureDockController.instance;
    unawaited(c.ensureLoaded());
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: AppBar(title: Text(strings.gdSettingsTitle)),
      body: ValueListenableBuilder<GestureDockSettings>(
        valueListenable: c.settings,
        builder: (context, s, _) {
          final description = switch (s.mode) {
            DockHideMode.fixed => strings.gdModeFixedDesc,
            DockHideMode.manual => strings.gdModeManualDesc,
            DockHideMode.auto => strings.gdModeAutoDesc,
          };
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              Text(
                strings.gdModeLabel,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              SegmentedButton<DockHideMode>(
                key: const ValueKey('gesture-dock-mode'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: DockHideMode.fixed,
                    label: Text(strings.gdModeFixed),
                  ),
                  ButtonSegment(
                    value: DockHideMode.manual,
                    label: Text(strings.gdModeManual),
                  ),
                  ButtonSegment(
                    value: DockHideMode.auto,
                    label: Text(strings.gdModeAuto),
                  ),
                ],
                selected: {s.mode},
                onSelectionChanged: (value) =>
                    unawaited(c.setMode(value.first)),
              ),
              const SizedBox(height: 8),
              Text(
                s.mode == DockHideMode.fixed
                    ? description
                    : '$description ${strings.gdModeHiddenNote}',
                style: TextStyle(color: colors.textSecondary),
              ),
              const SizedBox(height: 16),
              HermesGroup(
                children: [
                  Material(
                    type: MaterialType.transparency,
                    child: HermesSwitchTile(
                      controlKey: const ValueKey('gesture-dock-gestures'),
                      title: strings.gdGesturesTitle,
                      subtitle: strings.gdGesturesSubtitle,
                      value: s.gestures,
                      onChanged: (v) => unawaited(c.setGestures(v)),
                    ),
                  ),
                  Material(
                    type: MaterialType.transparency,
                    child: HermesSwitchTile(
                      controlKey: const ValueKey('gesture-dock-opaque'),
                      title: strings.gdOpaqueTitle,
                      subtitle: strings.gdOpaqueSubtitle,
                      value: s.opaque,
                      onChanged: (v) => unawaited(c.setOpaque(v)),
                    ),
                  ),
                  HermesNavRow(
                    key: const ValueKey('gesture-dock-tricks'),
                    icon: Icons.touch_app_outlined,
                    title: strings.gdTricksTitle,
                    subtitle: strings.gdTricksSubtitle,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => GestureTricksScreen(controller: c),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Ajustes › Trucos y gestos: the six gestures, which are learned, a way
/// to try each one, the tips switch and the welcome again.
class GestureTricksScreen extends StatelessWidget {
  final GestureDockController? controller;

  const GestureTricksScreen({this.controller, super.key});

  @override
  Widget build(BuildContext context) {
    final c = controller ?? GestureDockController.instance;
    unawaited(c.ensureLoaded());
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    void backToDock(VoidCallback then) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      then();
    }

    return Scaffold(
      appBar: AppBar(title: Text(strings.gdTricksTitle)),
      body: ValueListenableBuilder<GestureDockSettings>(
        valueListenable: c.settings,
        builder: (context, s, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            Container(
              key: const ValueKey('gesture-tricks-note'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.accent.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                strings.gdTricksNote,
                style: TextStyle(color: colors.textPrimary),
              ),
            ),
            const SizedBox(height: 12),
            HermesGroup(
              children: [
                for (final gesture in DockGesture.values)
                  _GestureRow(
                    gesture: gesture,
                    learned: s.learned.contains(gesture),
                    onTry: gesture == DockGesture.chatHandle
                        ? null
                        : () => backToDock(() => c.tryGesture(gesture)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            HermesGroup(
              children: [
                Material(
                  type: MaterialType.transparency,
                  child: HermesSwitchTile(
                    controlKey: const ValueKey('gesture-tricks-tips'),
                    title: strings.gdTipsToggleTitle,
                    subtitle: strings.gdTipsToggleSubtitle,
                    value: s.tips,
                    onChanged: (v) => unawaited(c.setTips(v)),
                  ),
                ),
                HermesNavRow(
                  key: const ValueKey('gesture-tricks-replay'),
                  icon: Icons.replay_rounded,
                  title: strings.gdReplayWelcome,
                  onTap: () => backToDock(c.startTour),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GestureRow extends StatelessWidget {
  final DockGesture gesture;
  final bool learned;
  final VoidCallback? onTry;

  const _GestureRow({
    required this.gesture,
    required this.learned,
    required this.onTry,
  });

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final (glyph, title, body) = switch (gesture) {
      DockGesture.swipe => (
        '← →',
        strings.gdGestSwipeTitle,
        strings.gdGestSwipeBody,
      ),
      DockGesture.hide => (
        '↓',
        strings.gdGestHideTitle,
        strings.gdGestHideBody,
      ),
      DockGesture.show => (
        '—',
        strings.gdGestShowTitle,
        strings.gdGestShowBody,
      ),
      DockGesture.up => ('↑', strings.gdGestUpTitle, strings.gdGestUpBody),
      DockGesture.hold => (
        '●',
        strings.gdGestHoldTitle,
        strings.gdGestHoldBody,
      ),
      DockGesture.chatHandle => (
        '▬',
        strings.gdGestChatTitle,
        strings.gdGestChatBody,
      ),
    };
    final Widget trailing = learned
        ? Text(
            '✓ ${strings.gdTrickLearned}',
            key: ValueKey('gesture-tricks-learned-${gesture.name}'),
            style: TextStyle(color: colors.accent, fontWeight: FontWeight.w600),
          )
        : onTry == null
        ? Text(
            strings.gdTrickChatOnly,
            style: TextStyle(color: colors.textSecondary),
          )
        : TextButton(
            key: ValueKey('gesture-tricks-try-${gesture.name}'),
            onPressed: onTry,
            child: Text(strings.gdTrickTry),
          );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            ExcludeSemantics(
              child: SizedBox(
                width: 36,
                child: Text(
                  glyph,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.accent, fontSize: 16),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(body, style: TextStyle(color: colors.textSecondary)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing,
          ],
        ),
      ),
    );
  }
}
