// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/modal.dart';
import '../../design/tokens.dart';
import '../../theme/app_theme.dart';
import '../../widgets/hermes_ui.dart' show PressableScale;
import 'connect_method_draft.dart';

export 'connect_method_draft.dart'
    show ConnectDraft, ConnectWay, phoneOnTailnet, recommendedConnectWay;

/// The three ways in, as cards: one sentence each, the recommended one marked.
///
/// The widget only asks; whoever shows it routes each way to its own flow.
/// Every card is a 48 dp+ button whose text wraps instead of clipping, so it
/// reads at 2x text on a 320 dp phone and stays one column on a tablet.
class ConnectWayCards extends StatelessWidget {
  const ConnectWayCards({
    required this.recommended,
    required this.onPick,
    this.onWhich,
    this.keyFor = defaultKey,
    this.maxWidth = 560,
    super.key,
  });

  final ConnectWay recommended;
  final ValueChanged<ConnectWay> onPick;

  /// «I don't know which to choose»; hidden when null.
  final VoidCallback? onWhich;

  /// The key of each card, so a screen can keep the keys its tests know.
  final Key Function(ConnectWay way) keyFor;
  final double maxWidth;

  static Key defaultKey(ConnectWay way) => ValueKey('connect-way-${way.name}');

  /// The order every entry shares: the hosted account first; the camera
  /// last because it needs a code or a server on the same network.
  static const order = [ConnectWay.nous, ConnectWay.manual, ConnectWay.scan];

  static IconData iconOf(ConnectWay way) => switch (way) {
    ConnectWay.nous => Icons.account_circle_outlined,
    ConnectWay.manual => Icons.language_rounded,
    ConnectWay.ssh => Icons.terminal_rounded,
    ConnectWay.scan => Icons.qr_code_scanner_rounded,
  };

  static String titleOf(Strings s, ConnectWay way) => switch (way) {
    ConnectWay.nous => s.nacWayNousTitle,
    ConnectWay.manual => s.nacWayManualTitle,
    ConnectWay.ssh => s.cnxTabSsh,
    ConnectWay.scan => s.nacWayScanTitle,
  };

  static String bodyOf(Strings s, ConnectWay way) => switch (way) {
    ConnectWay.nous => s.nacWayNousBody,
    ConnectWay.manual => s.nacWayManualBody,
    ConnectWay.ssh => s.nacWayManualBody,
    ConnectWay.scan => s.nacWayScanBody,
  };

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return _CapWidth(
      maxWidth: maxWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, way) in order.indexed) ...[
            if (i > 0) const SizedBox(height: HermesSpace.x3),
            _WayCard(
              key: keyFor(way),
              icon: iconOf(way),
              title: titleOf(s, way),
              body: bodyOf(s, way),
              recommended: way == recommended,
              recommendedLabel: s.nacWayRecommended,
              onTap: () => onPick(way),
            ),
          ],
          if (onWhich != null) ...[
            const SizedBox(height: HermesSpace.x1),
            _WhichLink(label: s.nacWayWhichLink, onTap: onWhich!),
          ],
        ],
      ),
    );
  }
}

/// A centred column no wider than [maxWidth] whose intrinsic height is
/// measured at that width. A `ConstrainedBox` would report the height of
/// the wider layout to an `IntrinsicHeight` ancestor (the welcome's frame)
/// and the wrapped text would then overflow it on a tablet.
class _CapWidth extends SingleChildRenderObjectWidget {
  const _CapWidth({required this.maxWidth, required super.child});
  final double maxWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCapWidth(maxWidth);

  @override
  void updateRenderObject(BuildContext context, _RenderCapWidth renderObject) {
    renderObject.maxWidth = maxWidth;
  }
}

class _RenderCapWidth extends RenderShiftedBox {
  _RenderCapWidth(this._maxWidth) : super(null);

  double _maxWidth;
  set maxWidth(double value) {
    if (value == _maxWidth) return;
    _maxWidth = value;
    markNeedsLayout();
  }

  double _cap(double width) => math.min(width, _maxWidth);

  BoxConstraints _inner(BoxConstraints constraints) {
    final max = _cap(constraints.maxWidth);
    return constraints.copyWith(
      minWidth: math.min(constraints.minWidth, max),
      maxWidth: max,
    );
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      child?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      child?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(_cap(width)) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(_cap(width)) ?? 0;

  Size _outer(BoxConstraints constraints, Size inner) => constraints.constrain(
    Size(
      constraints.hasBoundedWidth ? constraints.maxWidth : inner.width,
      inner.height,
    ),
  );

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final c = child;
    if (c == null) return constraints.smallest;
    return _outer(constraints, c.getDryLayout(_inner(constraints)));
  }

  @override
  void performLayout() {
    final c = child;
    if (c == null) {
      size = constraints.smallest;
      return;
    }
    c.layout(_inner(constraints), parentUsesSize: true);
    size = _outer(constraints, c.size);
    (c.parentData! as BoxParentData).offset = Offset(
      (size.width - c.size.width) / 2,
      0,
    );
  }
}

class _WayCard extends StatelessWidget {
  const _WayCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.recommended,
    required this.recommendedLabel,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool recommended;
  final String recommendedLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).hermes;
    final accent = c.accent;
    return Semantics(
      button: true,
      selected: recommended,
      label: recommended ? '$title. $recommendedLabel. $body' : '$title. $body',
      excludeSemantics: true,
      child: PressableScale(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: HermesSpace.tap),
          padding: const EdgeInsets.fromLTRB(
            HermesSpace.x4,
            HermesSpace.x4,
            HermesSpace.x3,
            HermesSpace.x4,
          ),
          decoration: BoxDecoration(
            color: recommended
                ? Color.alphaBlend(accent.withValues(alpha: .08), c.surface)
                : c.surface,
            borderRadius: BorderRadius.circular(HermesRadius.card),
            border: Border.all(
              color: recommended
                  ? accent.withValues(alpha: .6)
                  : c.divider.withValues(alpha: .8),
              width: recommended ? 1.5 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                icon,
                size: 24,
                color: recommended ? accent : c.textSecondary,
              ),
              const SizedBox(width: HermesSpace.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: HermesSpace.x2,
                      runSpacing: HermesSpace.x1,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: HermesType.titleSize,
                            fontWeight: FontWeight.w700,
                            height: 1.25,
                            color: c.textPrimary,
                          ),
                        ),
                        if (recommended) _Tag(label: recommendedLabel),
                      ],
                    ),
                    const SizedBox(height: HermesSpace.x1),
                    Text(
                      body,
                      style: TextStyle(
                        fontSize: HermesType.bodySize,
                        height: 1.4,
                        color: c.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: HermesSpace.x1),
              Icon(
                Icons.chevron_right_rounded,
                size: 22,
                color: c.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// «Recommended», a small accent tag beside the title.
class _Tag extends StatelessWidget {
  const _Tag({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).hermes;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HermesSpace.x2,
        vertical: HermesSpace.x1 / 2,
      ),
      decoration: BoxDecoration(
        color: c.accent,
        borderRadius: BorderRadius.circular(HermesRadius.tag),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: HermesType.captionSize,
          fontWeight: FontWeight.w700,
          height: 1.3,
          color: c.onAccent,
        ),
      ),
    );
  }
}

class _WhichLink extends StatelessWidget {
  const _WhichLink({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).hermes;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkResponse(
        key: const ValueKey('connect-way-which'),
        onTap: onTap,
        containedInkWell: true,
        highlightShape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(HermesRadius.row),
        child: Container(
          constraints: const BoxConstraints(minHeight: HermesSpace.tap),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x3),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: HermesType.bodySize,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.underline,
              decorationColor: c.textSecondary,
              color: c.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// «I don't know which to choose»: one line per way, in an opaque dialog.
Future<void> showConnectWayHelp(BuildContext context) {
  final s = Strings.of(context);
  return showHermesDialog<void>(
    context: context,
    surfaceKey: const ValueKey('connect-way-help'),
    title: s.nacWayWhichTitle,
    message: s.nacWayWhichBody,
    actions: [
      HermesDialogAction<void>(
        key: const ValueKey('connect-way-help-close'),
        label: s.commonClose,
        value: null,
        style: HermesDialogActionStyle.cancel,
      ),
    ],
  );
}
