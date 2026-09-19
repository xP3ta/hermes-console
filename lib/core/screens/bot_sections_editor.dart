import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/agent_profile.dart';
import '../services/bot_section_service.dart';
import '../widgets/hermes_premium_ui.dart';

Future<String?> botSectionNameDialog(
  BuildContext context, {
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  return showHermesFloatingSurface<String>(
    context: context,
    builder: (context) {
      final s = Strings.of(context);
      return DisposeControllersOnUnmount(
        controllers: [controller],
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                initial.isEmpty ? s.botSectionNew : s.botSectionRename,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                maxLength: 40,
                decoration: InputDecoration(labelText: s.botSectionName),
                onSubmitted: (value) {
                  if (value.trim().isNotEmpty) {
                    Navigator.pop(context, value.trim());
                  }
                },
              ),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(s.botCancel),
                  ),
                  const Spacer(),
                  ValueListenableBuilder(
                    valueListenable: controller,
                    builder: (context, value, _) => TextButton(
                      onPressed: value.text.trim().isEmpty
                          ? null
                          : () => Navigator.pop(context, value.text.trim()),
                      child: Text(s.botSave),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

Future<Map<String, BotSectionChange>?> chooseBotSection(
  BuildContext context,
  List<AgentProfile> profiles, {
  AgentProfile? bot,
}) async {
  final names = <String, String>{};
  for (final profile in profiles) {
    final id = profile.botSectionId;
    final name = profile.botSectionName;
    if (id != null &&
        name != null &&
        (!names.containsKey(id) || name.compareTo(names[id]!) < 0)) {
      names[id] = name;
    }
  }
  final ids = names.keys.toList()
    ..sort((a, b) {
      final order = names[a]!.toLowerCase().compareTo(names[b]!.toLowerCase());
      return order != 0 ? order : a.compareTo(b);
    });
  BotSectionChange? change;
  if (bot != null) {
    final selected = await showHermesFloatingSurface<String>(
      context: context,
      builder: (context) {
        final s = Strings.of(context);
        return ListView(
          shrinkWrap: true,
          children: [
            for (final id in ids)
              ListTile(
                title: Text(names[id]!),
                leading: const Icon(Icons.folder_outlined),
                onTap: () => Navigator.pop(context, id),
              ),
            ListTile(
              title: Text(s.botSectionNew),
              leading: const Icon(Icons.create_new_folder_outlined),
              onTap: () => Navigator.pop(context, 'new'),
            ),
            if (bot.botSectionId != null)
              ListTile(
                title: Text(s.botSectionRemove),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(s.botSectionOrderHint),
            ),
          ],
        );
      },
    );
    if (selected == null || !context.mounted) return null;
    if (selected == 'remove') {
      return {bot.name: const BotSectionChange(null, null)};
    }
    if (selected != 'new') change = BotSectionChange(selected, names[selected]);
  }
  if (change == null) {
    final name = await botSectionNameDialog(context);
    if (name == null || !context.mounted) return null;
    change = BotSectionChange.create(name);
  }
  if (bot != null) return {bot.name: change};
  final selected = <String>{};
  final confirmed = await showHermesFloatingSurface<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final s = Strings.of(context);
        return ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(s.botSectionChooseMembers),
              subtitle: Text(s.botSectionOrderHint),
            ),
            for (final profile in profiles)
              CheckboxListTile(
                title: Text(profile.botTitle ?? profile.name),
                value: selected.contains(profile.name),
                onChanged: (value) => setState(() {
                  if (value == true) {
                    selected.add(profile.name);
                  } else {
                    selected.remove(profile.name);
                  }
                }),
              ),
            TextButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text(s.botSave),
            ),
          ],
        );
      },
    ),
  );
  return confirmed == true ? {for (final name in selected) name: change} : null;
}
