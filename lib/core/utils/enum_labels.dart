/// Localized labels for shared enums (approval mode, risk), used by
/// permissions, the chat (approvals) and runs. The approval mode has no other
/// name for people; the UI always goes through these helpers.
library;

import '../../l10n/app_localizations.dart';
import '../services/approval_policy.dart';
import '../services/command_risk.dart';

String approvalModeLabel(Strings s, ApprovalMode m) => switch (m) {
      ApprovalMode.globalDefault => s.modeGlobalDefault,
      ApprovalMode.yolo => s.modeYolo,
      ApprovalMode.interactive => s.modeInteractive,
      ApprovalMode.conservative => s.modeConservative,
      ApprovalMode.readOnly => s.modeReadOnly,
    };

String commandRiskLabel(Strings s, CommandRisk r) => switch (r) {
      CommandRisk.low => s.riskLow,
      CommandRisk.medium => s.riskMedium,
      CommandRisk.high => s.riskHigh,
    };
