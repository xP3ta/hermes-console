import 'package:flutter/material.dart';

import '../services/pairing_link.dart';
import 'onboarding/onboarding_scanner.dart';

/// The scanner as a route of its own: used to scan a new code into a saved
/// connection. First run embeds the same [QrScanView] in its own flow. Only
/// this view mounts a camera; a denied permission keeps paste usable.
class QrScanScreen extends StatelessWidget {
  const QrScanScreen({this.cameraBuilder, super.key});
  final Widget Function(ValueChanged<String>, ValueChanged<bool>)?
  cameraBuilder;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF15151B),
    body: QrScanView(
      cameraBuilder: cameraBuilder,
      onBack: () => Navigator.of(context).maybePop(),
      onLink: (PairingLink link) => Navigator.of(context).pop(link),
    ),
  );
}
