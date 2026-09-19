import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../models/agent_profile.dart';
import '../services/bot_profile_client.dart';
import '../services/profile_image_normalizer.dart';

class BotAvatarGenerateButton extends StatefulWidget {
  final BotAvatarGenerationGateway gateway;
  final ValueChanged<AgentProfileAvatar> onSelected;
  final bool enabled;
  const BotAvatarGenerateButton({
    super.key,
    required this.gateway,
    required this.onSelected,
    this.enabled = true,
  });
  @override
  State<BotAvatarGenerateButton> createState() =>
      _BotAvatarGenerateButtonState();
}

class _BotAvatarGenerateButtonState extends State<BotAvatarGenerateButton> {
  late final Future<bool> _available = widget.gateway.canGenerateBotAvatar();
  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: _available,
    builder: (context, snapshot) => snapshot.data != true
        ? const SizedBox.shrink()
        : TextButton.icon(
            icon: const Icon(Icons.auto_awesome_outlined),
            label: Text(Strings.of(context).botGenerateAvatar),
            onPressed: !widget.enabled
                ? null
                : () async {
                    final avatar = await showDialog<AgentProfileAvatar>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => _GenerateDialog(gateway: widget.gateway),
                    );
                    if (mounted && avatar != null) widget.onSelected(avatar);
                  },
          ),
  );
}

class _GenerateDialog extends StatefulWidget {
  final BotAvatarGenerationGateway gateway;
  const _GenerateDialog({required this.gateway});
  @override
  State<_GenerateDialog> createState() => _GenerateDialogState();
}

class _GenerateDialogState extends State<_GenerateDialog> {
  final _prompt = TextEditingController();
  bool _busy = false;
  bool _failed = false;
  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (_busy || _prompt.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final generated = await widget.gateway.generateBotAvatar(_prompt.text);
      final avatar = await ProfileImageNormalizer.normalize(generated.bytes);
      if (mounted) Navigator.pop(context, avatar);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(s.botGenerateAvatar),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _prompt,
              enabled: !_busy,
              maxLength: 2048,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(labelText: s.botAvatarPrompt),
              onChanged: (_) => setState(() {}),
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_failed) Text(s.botGenerateFailed),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(s.botCancel),
          ),
          TextButton(
            onPressed: _busy || _prompt.text.trim().isEmpty ? null : _generate,
            child: Text(s.botGenerate),
          ),
        ],
      ),
    );
  }
}
