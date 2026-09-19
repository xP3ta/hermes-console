import 'package:flutter/material.dart';

import '../models/agent_profile.dart';

class RoomMirrorAvatar extends StatelessWidget {
  final AgentProfileAvatar image;
  final Widget fallback;
  final double size;

  const RoomMirrorAvatar({
    required this.image,
    required this.fallback,
    this.size = 48,
    super.key,
  });

  @override
  Widget build(BuildContext context) => Image.memory(
    image.bytes,
    width: size,
    height: size,
    fit: BoxFit.cover,
    cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).ceil(),
    cacheHeight: (size * MediaQuery.devicePixelRatioOf(context)).ceil(),
    excludeFromSemantics: true,
    frameBuilder: (_, child, _, _) => ClipOval(child: child),
    errorBuilder: (_, _, _) => fallback,
  );
}
