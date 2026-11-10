import 'package:flutter/widgets.dart';

import '../models/agent_profile.dart';

/// The name of the agent a chat talks to, for the texts inside it that speak
/// of "the agent" (permission and question cards, the steer label, the
/// edit hint): the profile's own visible name ([AgentProfile.visibleName]),
/// never a hard-coded «Hermes». The chat screen provides it; anything built
/// outside a chat reads the last resort.
class AgentNameScope extends InheritedWidget {
  const AgentNameScope({required this.name, required super.child, super.key});

  final String name;

  /// The agent's name at [context], [kMainProfileFallbackName] without a chat.
  static String of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AgentNameScope>();
    final name = scope?.name.trim() ?? '';
    return name.isEmpty ? kMainProfileFallbackName : name;
  }

  @override
  bool updateShouldNotify(AgentNameScope oldWidget) => name != oldWidget.name;
}
