// Shared presentation helpers of the Capabilities hub: human labels, icons,
// failure copy and the non-dismissible progress surface used while a server
// action runs.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../theme/app_theme.dart';
import 'capabilities_repository.dart';
import 'capability_models.dart';

IconData capabilityKindIcon(CapabilityKind kind) => switch (kind) {
  CapabilityKind.skill => Icons.auto_awesome_outlined,
  CapabilityKind.plugin => Icons.extension_outlined,
  CapabilityKind.mcp => Icons.hub_outlined,
};

String capabilityKindLabel(Strings s, CapabilityKind kind) => switch (kind) {
  CapabilityKind.skill => s.cphKindSkill,
  CapabilityKind.plugin => s.cphKindPlugin,
  CapabilityKind.mcp => s.cphKindMcpOne,
};

String capabilityKindGroupLabel(Strings s, CapabilityKind kind) =>
    switch (kind) {
      CapabilityKind.skill => s.cphKindSkills,
      CapabilityKind.plugin => s.cphKindPlugins,
      CapabilityKind.mcp => s.cphKindMcp,
    };

String capabilityTrustLabel(Strings s, CapabilityTrust trust) =>
    switch (trust) {
      CapabilityTrust.official => s.cphTrustOfficial,
      CapabilityTrust.trusted => s.cphTrustTrusted,
      CapabilityTrust.community => s.cphTrustCommunity,
      CapabilityTrust.local => s.cphTrustLocal,
      CapabilityTrust.unknown => s.cphTrustUnknown,
    };

String capabilityTrustBody(Strings s, CapabilityTrust trust) => switch (trust) {
  CapabilityTrust.official => s.cphTrustOfficialBody,
  CapabilityTrust.trusted => s.cphTrustTrustedBody,
  CapabilityTrust.community => s.cphTrustCommunityBody,
  CapabilityTrust.local => s.cphTrustLocalBody,
  CapabilityTrust.unknown => s.cphTrustUnknownBody,
};

/// Row status: only states that change the decision are shown in lists.
({String label, HermesStatusTone tone})? capabilityRowStatus(
  Strings s,
  CapabilityItem item,
) {
  if (!item.installed) return null;
  if (item.updateAvailable) {
    return (label: s.cphStatusUpdateShort, tone: HermesStatusTone.warn);
  }
  if (item.enabled == false) {
    return (label: s.cphStatusDisabled, tone: HermesStatusTone.neutral);
  }
  return (label: s.cphStatusInstalled, tone: HermesStatusTone.ok);
}

/// Detail status line (always present).
({String label, HermesStatusTone tone}) capabilityDetailStatus(
  Strings s,
  CapabilityItem item,
) {
  if (!item.installed) {
    return (label: s.cphStatusNotInstalled, tone: HermesStatusTone.neutral);
  }
  if (item.updateAvailable) {
    return (label: s.cphStatusUpdate, tone: HermesStatusTone.warn);
  }
  if (item.enabled == false) {
    return (label: s.cphStatusDisabled, tone: HermesStatusTone.neutral);
  }
  if (item.enabled == true) {
    return (label: s.cphStatusEnabled, tone: HermesStatusTone.ok);
  }
  return (label: s.cphStatusInstalled, tone: HermesStatusTone.ok);
}

CapabilityFailureKind capabilityFailureKindOf(Object error) =>
    error is CapabilityFailure ? error.kind : CapabilityFailureKind.unavailable;

String capabilityFailureMessage(Strings s, Object error) {
  final kind = capabilityFailureKindOf(error);
  final base = switch (kind) {
    CapabilityFailureKind.unsupported => s.cphFailUnsupported,
    CapabilityFailureKind.forbidden => s.cphFailForbidden,
    CapabilityFailureKind.rejected => s.cphFailRejected,
    CapabilityFailureKind.unavailable => s.cphFailUnavailable,
    CapabilityFailureKind.blockedByScan => s.cphFailBlockedByScan,
    CapabilityFailureKind.uncertain => s.cphFailUncertain,
    CapabilityFailureKind.invalidResponse => s.cphFailInvalid,
  };
  final detail = error is CapabilityFailure ? error.detail.trim() : '';
  return detail.isEmpty ? base : '$base\n$detail';
}

/// Runs [task] behind a non-dismissible progress surface (no tap-out, no
/// back): closing it would orphan a server action that keeps running.
/// [task] may publish the latest log line through the notifier.
Future<T> runCapabilityProgress<T>(
  BuildContext context, {
  required String label,
  required Future<T> Function(ValueNotifier<String> line) task,
}) async {
  // Not disposed: the surface's listener may outlive the task by a frame and
  // the notifier holds no resources.
  final line = ValueNotifier<String>('');
  final navigator = Navigator.of(context);
  final opened = Completer<BuildContext>();
  unawaited(
    showHermesSurface<void>(
      context: context,
      surfaceKey: const ValueKey('cph-progress'),
      barrierDismissible: false,
      systemDismissible: false,
      maxWidth: 360,
      builder: (surfaceContext) {
        if (!opened.isCompleted) opened.complete(surfaceContext);
        final colors = Theme.of(surfaceContext).hermes;
        final s = Strings.of(surfaceContext);
        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      label,
                      style: HermesType.title.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ValueListenableBuilder<String>(
                valueListenable: line,
                builder: (context, value, _) => Text(
                  value.isEmpty ? s.cphProgressKeepOpen : value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HermesType.support.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
  try {
    return await task(line);
  } finally {
    // The surface builds on the next frame; a task that fails first waits
    // for it so the exact route (not whatever is on top) is removed.
    final surfaceContext = await opened.future;
    final route = surfaceContext.mounted ? ModalRoute.of(surfaceContext) : null;
    if (route != null && route.isActive) navigator.removeRoute(route);
  }
}
