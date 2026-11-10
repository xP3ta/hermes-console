import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../design/content.dart' show HermesInlineNotice;
import '../design/tokens.dart';
import '../utils/cleartext_notice_memory.dart';

/// The single, quiet line about plain http towards a public host: an icon and
/// one short sentence with a dismiss button, never a banner or a dialog.
///
/// With a [connectionId] it is shown once for that connection (it is marked as
/// seen as soon as it appears) and then stays away; without one there is
/// nothing to remember it by, so it lasts as long as the widget does.
/// It is only for notes that do not carry a secret: sending a secret over
/// plain http to a public host is blocked or warned about separately.
class CleartextOnceLine extends StatefulWidget {
  const CleartextOnceLine({
    required this.message,
    this.connectionId,
    this.memory,
    super.key,
  });

  final String message;
  final String? connectionId;

  /// Test seam; defaults to the app's preferences.
  final Future<CleartextNoticeMemory> Function()? memory;

  @override
  State<CleartextOnceLine> createState() => _CleartextOnceLineState();
}

class _CleartextOnceLineState extends State<CleartextOnceLine> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(CleartextOnceLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Another connection has its own memory.
    if (oldWidget.connectionId != widget.connectionId) {
      _visible = false;
      _start();
    }
  }

  void _start() {
    final id = widget.connectionId;
    if (id == null || id.isEmpty) {
      _visible = true;
    } else {
      _decide(id);
    }
  }

  Future<void> _decide(String id) async {
    final memory = await (widget.memory?.call() ?? _defaultMemory());
    if (!mounted || widget.connectionId != id || memory.seen(id)) return;
    setState(() => _visible = true);
    await memory.markSeen(id);
  }

  static Future<CleartextNoticeMemory> _defaultMemory() async =>
      CleartextNoticeMemory(await SharedPreferences.getInstance());

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return Padding(
      key: const ValueKey('krh-http-line'),
      padding: const EdgeInsets.only(top: HermesSpace.x2),
      child: HermesInlineNotice(
        message: widget.message,
        icon: Icons.lock_open_outlined,
        tone: HermesStatusTone.warn,
        onDismiss: () => setState(() => _visible = false),
      ),
    );
  }
}
