import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import 'island.dart';

IslandEvent chatTurnRecoveryUnconfirmedEvent({
  required Strings str,
  required VoidCallback onRetry,
  required VoidCallback onStop,
}) => IslandEvent(
  id: 'turn-recovery-unconfirmed',
  key: const ValueKey('chat-turn-recovery-unconfirmed'),
  tone: IslandTone.warning,
  weight: IslandTone.needsYou.rank + 1,
  sticky: true,
  line: str.islandRecoveredTurn,
  action: IslandAction(
    key: const ValueKey('chat-turn-recovery-retry'),
    label: str.commonRetry,
    closes: false,
    onPressed: onRetry,
  ),
  secondary: IslandAction(
    key: const ValueKey('chat-turn-recovery-stop'),
    label: str.cq1215StopTurn,
    closes: false,
    onPressed: onStop,
  ),
);
