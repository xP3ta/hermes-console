// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// The two pieces every block of the Models page is drawn with: the quiet
// uppercase label above a block and the tonal surface a block sits on.

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/hermes_premium_ui.dart' show HermesListSection;

/// Uppercase label above a block ("MAIN MODEL · PROVIDERS").
class ModelsSectionLabel extends StatelessWidget {
  const ModelsSectionLabel(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
    child: Semantics(
      header: true,
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).hermes.textTertiary,
          letterSpacing: 1.5,
        ),
      ),
    ),
  );
}

/// One tonal surface holding a single card or row.
class ModelsTonalGroup extends StatelessWidget {
  const ModelsTonalGroup({
    this.margin = EdgeInsets.zero,
    this.shape,
    required this.child,
    super.key,
  });

  final EdgeInsetsGeometry margin;
  final ShapeBorder? shape;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final content = shape == null
        ? child
        : ClipPath(
            clipper: ShapeBorderClipper(shape: shape!),
            child: child,
          );
    return HermesListSection(
      margin: margin,
      showDividers: false,
      children: [content],
    );
  }
}
