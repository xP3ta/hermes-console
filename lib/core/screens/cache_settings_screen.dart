// Settings → Data → Cache: what this phone keeps of the chats so that they
// are on screen before the server answers (the Chats list and the newest
// messages of the chats opened last), how many chats keep their messages, and
// how much space that takes. All on this device; nothing is removed from the
// server.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/cache_settings.dart';
import '../services/cold_start_store.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_ui.dart';

class CacheSettingsScreen extends StatefulWidget {
  const CacheSettingsScreen({
    required this.store,
    required this.settings,
    super.key,
  });

  final ColdStartStore store;
  final CacheSettings settings;

  @override
  State<CacheSettingsScreen> createState() => _CacheSettingsScreenState();
}

class _CacheSettingsScreenState extends State<CacheSettingsScreen> {
  int? _usedBytes;

  @override
  void initState() {
    super.initState();
    _refreshUsage();
  }

  Future<void> _refreshUsage() async {
    int? bytes;
    try {
      bytes = await widget.store.usedBytes();
    } catch (_) {
      bytes = null;
    }
    if (mounted) setState(() => _usedBytes = bytes);
  }

  Future<void> _setChatList(bool value) async {
    await widget.settings.setChatList(value);
    // Turning one off deletes what was already kept for it.
    if (!value) await widget.store.clearLists();
    await _refreshUsage();
  }

  Future<void> _setMessages(bool value) async {
    await widget.settings.setMessages(value);
    if (!value) await widget.store.clearMessages();
    await _refreshUsage();
  }

  Future<void> _clear() async {
    await widget.store.clearLists();
    await widget.store.clearMessages();
    await _refreshUsage();
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(Strings.of(context).cacheCleared)));
  }

  /// Plain units on purpose: the size is a number, not a sentence.
  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Widget _label(BuildContext context, String text) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.labelLarge?.copyWith(color: colors.textSecondary),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final settings = widget.settings;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(title: Text(s.cacheTitle)),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          clipBehavior: hermesUnderHeader,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
          children: [
            _label(context, s.cacheOnDevice),
            HermesGroup(
              children: [
                // The tile paints its ink on its own Material, not under
                // the group's tinted box.
                Material(
                  type: MaterialType.transparency,
                  child: HermesSwitchTile(
                    controlKey: const ValueKey('cache-chat-list'),
                    title: s.cacheChatList,
                    subtitle: s.cacheChatListDesc,
                    value: settings.chatList,
                    onChanged: _setChatList,
                  ),
                ),
                // The tile paints its ink on its own Material, not under
                // the group's tinted box.
                Material(
                  type: MaterialType.transparency,
                  child: HermesSwitchTile(
                    controlKey: const ValueKey('cache-messages'),
                    title: s.cacheMessages,
                    subtitle: s.cacheMessagesDesc,
                    value: settings.messages,
                    onChanged: _setMessages,
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                s.cacheOffNote,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
              ),
            ),
            _label(context, s.cacheLimitSection),
            HermesPanel(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.cacheLimitLabel(settings.maxChats),
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final n in CacheSettings.limits)
                          ChoiceChip(
                            key: ValueKey('cache-limit-$n'),
                            label: Text('$n'),
                            selected: settings.maxChats == n,
                            onSelected: settings.messages
                                ? (_) => settings.setMaxChats(n)
                                : null,
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      s.cacheLimitHint,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _label(context, s.cacheUsage),
            HermesPanel(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        s.cacheOnThisDevice,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      _usedBytes == null ? '…' : _size(_usedBytes!),
                      key: const ValueKey('cache-usage'),
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      key: const ValueKey('cache-clear'),
                      onPressed: _clear,
                      child: Text(s.cacheClear),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
