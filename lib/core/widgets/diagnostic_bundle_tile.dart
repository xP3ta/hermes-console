import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../config/flavor.dart';
import '../services/connection_manager.dart';
import '../services/diagnostic_bundle_service.dart';
import '../services/turn_outbox_store.dart';
import '../theme/app_theme.dart';
import 'hermes_notice.dart';

class DiagnosticRuntimeInfo {
  final String version;
  final int build;
  final DiagnosticFlavor flavor;
  final int androidApi;

  const DiagnosticRuntimeInfo({
    required this.version,
    required this.build,
    required this.flavor,
    required this.androidApi,
  });
}

class DiagnosticBundleController {
  final ConnectionManager manager;
  final DiagnosticBundleService service;
  final TurnOutboxStore outbox;
  final Future<DiagnosticRuntimeInfo> Function() _runtimeInfo;
  final Future<Directory> Function() _supportDirectory;
  final Future<void> Function(File file) _shareFile;
  final DateTime Function() _now;

  DiagnosticBundleController({
    required this.manager,
    DiagnosticBundleService? service,
    TurnOutboxStore? outbox,
    Future<DiagnosticRuntimeInfo> Function()? runtimeInfo,
    Future<Directory> Function()? supportDirectory,
    Future<void> Function(File file)? shareFile,
    DateTime Function()? now,
  }) : service = service ?? DiagnosticBundleService(),
       outbox = outbox ?? TurnOutboxStore(),
       _runtimeInfo = runtimeInfo ?? _defaultRuntimeInfo,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _shareFile = shareFile ?? _defaultShareFile,
       _now = now ?? DateTime.now;

  Future<DiagnosticBundle> prepare(DiagnosticFormFactor formFactor) async {
    await service.cleanupExpired();
    final runtime = await _runtimeInfo();
    final now = _now();
    DiagnosticTurnsSnapshot turns;
    try {
      turns = DiagnosticTurnsSnapshot.fromOutboxSummary(
        await outbox.diagnosticSummary(),
        now: now,
      );
    } catch (_) {
      turns = const DiagnosticTurnsSnapshot();
    }

    Map<DiagnosticCacheKind, DiagnosticCacheSnapshot> caches = const {};
    try {
      final support = await _supportDirectory();
      caches = {
        DiagnosticCacheKind.sentImages:
            await DiagnosticCacheSnapshot.fromDirectory(
              Directory('${support.path}/generated_images'),
            ),
        DiagnosticCacheKind.attachments:
            await DiagnosticCacheSnapshot.fromDirectory(
              Directory('${support.path}/sent_images'),
            ),
      };
    } catch (_) {
      // El informe sigue siendo útil sin estadísticas de caché.
    }

    final connections = manager.getConnections();
    return service.build(
      DiagnosticBundleInput(
        appVersion: runtime.version,
        buildNumber: runtime.build,
        flavor: runtime.flavor,
        androidApi: runtime.androidApi,
        formFactor: formFactor,
        connections: [
          for (var index = 0; index < connections.length; index++)
            DiagnosticConnectionSnapshot.fromConnection(
              ordinal: index + 1,
              connection: connections[index],
              matrix: manager.loadCapabilities(connections[index].id),
              health: _healthFromMatrix(
                manager.loadCapabilities(connections[index].id),
              ),
            ),
        ],
        turns: turns,
        caches: caches,
      ),
    );
  }

  Future<void> share(DiagnosticBundle bundle) async {
    final file = await service.write(bundle);
    try {
      await _shareFile(file);
    } finally {
      await service.delete(file);
    }
  }

  static List<DiagnosticHealthSample> _healthFromMatrix(
    CapabilityMatrix matrix,
  ) => [
    DiagnosticHealthSample(
      component: DiagnosticComponent.gateway,
      code: _capCode(matrix.gatewayOnline),
    ),
    DiagnosticHealthSample(
      component: DiagnosticComponent.dashboard,
      code: _capCode(matrix.dashboardOnline),
    ),
  ];

  static DiagnosticCode _capCode(CapState state) => switch (state) {
    CapState.yes => DiagnosticCode.ok,
    CapState.no => DiagnosticCode.error,
    CapState.unknown => DiagnosticCode.unknown,
  };

  static Future<DiagnosticRuntimeInfo> _defaultRuntimeInfo() async {
    final info = await PackageInfo.fromPlatform();
    final packageName = info.packageName.toLowerCase();
    final flavor = packageName.endsWith('.qa')
        ? DiagnosticFlavor.qa
        : switch (kHermesFlavor) {
            'play' => DiagnosticFlavor.play,
            'full' => DiagnosticFlavor.full,
            _ => DiagnosticFlavor.unknown,
          };
    final apiMatch = RegExp(
      r'(?:API|SDK)\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(Platform.operatingSystemVersion);
    return DiagnosticRuntimeInfo(
      version: info.version,
      build: int.tryParse(info.buildNumber) ?? 0,
      flavor: flavor,
      androidApi: int.tryParse(apiMatch?.group(1) ?? '') ?? 0,
    );
  }

  static Future<void> _defaultShareFile(File file) async {
    await Share.shareXFiles([XFile(file.path, mimeType: 'application/json')]);
  }
}

class DiagnosticBundleTile extends StatefulWidget {
  final DiagnosticBundleController controller;

  const DiagnosticBundleTile({super.key, required this.controller});

  @override
  State<DiagnosticBundleTile> createState() => _DiagnosticBundleTileState();
}

class _DiagnosticBundleTileState extends State<DiagnosticBundleTile> {
  bool _busy = false;

  Future<void> _generate() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final formFactor = MediaQuery.sizeOf(context).shortestSide >= 600
          ? DiagnosticFormFactor.tablet
          : DiagnosticFormFactor.phone;
      final bundle = await widget.controller.prepare(formFactor);
      if (!mounted) return;
      final share = await showDialog<bool>(
        context: context,
        builder: (context) {
          final s = Strings.of(context);
          return AlertDialog(
            title: Text(s.diagBundlePreviewTitle),
            content: SizedBox(
              width: 560,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.diagBundlePrivacy),
                  const SizedBox(height: 12),
                  Flexible(
                    child: SingleChildScrollView(
                      child: SelectableText(
                        bundle.preview,
                        key: const ValueKey('diagnostic-bundle-preview'),
                        style: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(s.commonCancel),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.share_outlined),
                label: Text(s.commonShare),
              ),
            ],
          );
        },
      );
      if (share == true) await widget.controller.share(bundle);
    } catch (_) {
      if (mounted) {
        HermesNotice.of(context).showSnackBar(
          SnackBar(content: Text(Strings.of(context).diagBundleError)),
          kind: HermesNoticeKind.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return ListTile(
      leading: Icon(Icons.bug_report_outlined, color: colors.textSecondary),
      title: Text(s.diagBundleTitle),
      subtitle: Text(
        s.diagBundleSubtitle,
        style: TextStyle(fontSize: 12, color: colors.textSecondary),
      ),
      trailing: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.chevron_right, color: colors.textDisabled),
      onTap: _busy ? null : _generate,
    );
  }
}
