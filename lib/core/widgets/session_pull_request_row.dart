import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../services/session_pull_requests.dart';

/// Resolves a session's pull request once and builds [builder] only when one
/// exists: no placeholder, spinner or empty row while loading or when there
/// is nothing to show.
class SessionPullRequestRow extends StatefulWidget {
  final Future<PullRequestInfo?> Function() load;
  final Widget Function(BuildContext context, String label, VoidCallback onTap)
  builder;

  /// Test seam: opens an https link outside the app.
  final Future<void> Function(Uri uri)? openUrl;

  const SessionPullRequestRow({
    required this.load,
    required this.builder,
    this.openUrl,
    super.key,
  });

  static String labelFor(Strings s, PullRequestInfo pr) {
    final state = switch (pr.bucket) {
      PullRequestBucket.merged => s.sesPrStateMerged,
      PullRequestBucket.closed => s.sesPrStateClosed,
      PullRequestBucket.draft => s.sesPrStateDraft,
      PullRequestBucket.open => s.sesPrStateOpen,
      PullRequestBucket.none => pr.state,
    };
    return s.sesPrTag(pr.number, state);
  }

  @override
  State<SessionPullRequestRow> createState() => _SessionPullRequestRowState();
}

class _SessionPullRequestRowState extends State<SessionPullRequestRow> {
  PullRequestInfo? _pr;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    PullRequestInfo? pr;
    try {
      pr = await widget.load();
    } catch (_) {
      pr = null;
    }
    if (!mounted || pr == null) return;
    setState(() => _pr = pr);
  }

  Future<void> _open(PullRequestInfo pr) async {
    final uri = safePullRequestUri(pr.url);
    if (uri == null) return;
    final open = widget.openUrl;
    if (open != null) {
      await open(uri);
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final pr = _pr;
    if (pr == null) return const SizedBox.shrink();
    return widget.builder(
      context,
      SessionPullRequestRow.labelFor(Strings.of(context), pr),
      () => _open(pr),
    );
  }
}
