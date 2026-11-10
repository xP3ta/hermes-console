import 'package:flutter/material.dart';

/// The one trailing control of a plugin, tool, MCP or skill row: the switch,
/// in a slot of fixed width so every row of a list ends on the same line
/// whatever its origin. A busy or read-only switch is disabled but keeps its place,
/// and it still claims the touch so a tap on it never opens the detail.
class HermesRowSwitch extends StatelessWidget {
  final Key switchKey;
  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const HermesRowSwitch({
    super.key,
    required this.switchKey,
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 60,
    height: 48,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: enabled ? null : () {},
      child: Semantics(
        container: true,
        label: label,
        child: Center(
          child: Switch(
            key: switchKey,
            materialTapTargetSize: MaterialTapTargetSize.padded,
            value: value,
            onChanged: enabled ? onChanged : null,
          ),
        ),
      ),
    ),
  );
}
