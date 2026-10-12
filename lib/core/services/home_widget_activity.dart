// What the launcher widgets say about the chats of the instance in use: which
// ones run right now (with a plain-word phase and the turn's start, for the
// widget's timer) and which ones wait for the owner (with the request an
// answer from the widget would be for). Pure state fed by chat events the
// app already receives; it reads nothing from the network.
import '../models/home_widget_snapshot.dart';
import '../models/interactive_prompt.dart';
import '../models/tool_name.dart';
import 'approval_policy.dart';
import 'notifications/rich_notifications.dart'
    show NotificationActionPayload, NotificationActionRoute;

/// What a running tool is called on a home screen: a few plain words, never
/// its arguments (they may hold paths, commands or secrets).
///
/// ONE function on purpose: every phase the widgets show goes through it.
/// The chat service already hands it the shared wording of the tool
/// (`toolOrSkillStepTitle` of `models/tool_label.dart`: "Ejecutando
/// comando", "GitHub · create issue"), which is kept as it is, only bounded.
/// A bare tool id (`web_search`, `mcp__github__create_issue`) from any
/// other caller is still put in words here instead of being shown raw.
String? homeWidgetToolPhrase(String? toolName) {
  final raw = toolName?.trim() ?? '';
  if (raw.isEmpty) return null;
  if (!_toolId.hasMatch(raw)) {
    // Already words: the shared wording chose them.
    return raw.length <= _maxPhrase
        ? raw
        : '${raw.substring(0, _maxPhrase).trimRight()}…';
  }
  var name = canonicalToolName(raw);
  // A native MCP tool is `mcp__<server>__<tool>`: the tool is the word.
  final separator = name.lastIndexOf('__');
  if (separator >= 0 && separator + 2 < name.length) {
    name = name.substring(separator + 2);
  }
  final words = name
      .replaceAll(RegExp(r'[_\-.]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (words.isEmpty) return null;
  final phrase = words[0].toUpperCase() + words.substring(1);
  return phrase.length <= _maxPhrase
      ? phrase
      : phrase.substring(0, _maxPhrase).trimRight();
}

/// A registered tool name, not a phrase: lower case, digits and underscores.
final _toolId = RegExp(r'^[a-z][a-z0-9_]*$');

/// A phase is one line beside a name and a timer.
const _maxPhrase = 40;

/// The request a chat is waiting on, as a widget may show and answer it.
///
/// [approval] is the chat's pending approval as the gateway sent it. The
/// answer payload is only built when the request has an id, the instance is
/// writable and both "once" and "deny" are choices the request permits: the
/// widget offers Permitir / Rechazar or nothing. It is the same payload a
/// notification's buttons carry, so the same executor answers it.
HomeWidgetNeed? homeWidgetNeedForApproval({
  required Map<String, dynamic>? approval,
  required String connectionId,
  required String sessionId,
  required String? profile,
  required bool readOnly,
  bool hideSensitive = false,
}) {
  if (approval == null) return null;
  final requestId = (approval['request_id'] ?? approval['approval_id'])
      ?.toString()
      .trim();
  if (requestId == null || requestId.isEmpty) return null;
  final choices = permittedApprovalChoices(approval);
  String? action;
  if (!readOnly && choices.contains('once') && choices.contains('deny')) {
    final payload = NotificationActionPayload(
      route: NotificationActionRoute.chat,
      connId: connectionId,
      profile: profile,
      sessionId: sessionId,
      requestId: requestId,
      choices: [
        for (final choice in const ['once', 'session', 'always', 'deny'])
          if (choices.contains(choice)) choice,
      ],
    ).encode();
    // Only a payload the executor would accept; otherwise the widget opens
    // the chat instead of offering buttons that could not work.
    if (NotificationActionPayload.tryParse(payload) != null) action = payload;
  }
  final command = approval['command'] ?? approval['description'];
  final text = command?.toString().split('\n').first.trim() ?? '';
  return HomeWidgetNeed(
    requestId: requestId,
    text: hideSensitive || text.isEmpty ? null : text,
    actionPayload: action,
  );
}

/// The question a chat is waiting on, as a widget may show it.
///
/// Only a question in words (`clarify`) is described: a password or a secret
/// prompt is nothing to show on a home screen, and reads as "te necesita".
/// It carries no answer payload. The shared action path answers permissions
/// (approve / deny) and has no route that answers a question, so the widget
/// shows the question with "Abrir" and its choices are answered in the app.
HomeWidgetNeed? homeWidgetNeedForPrompt(
  InteractivePromptRequest? request, {
  bool hideSensitive = false,
}) {
  if (request is! ClarifyPromptRequest) return null;
  final asked = request.isBatch
      ? request.questions.first.question
      : request.question;
  final text = asked.split('\n').first.trim();
  return HomeWidgetNeed(
    requestId: request.key.requestId,
    question: true,
    text: hideSensitive || text.isEmpty ? null : text,
  );
}

/// The chats that are running or waiting for the owner.
///
/// Keyed by the chat itself ([owner]), not by its session id: a chat keeps
/// its turn when its provisional id becomes the durable one.
class HomeWidgetActivityTracker {
  final Map<Object, HomeWidgetChatActivity> _chats = {};

  /// Applies the state of one chat. Returns true when the list changed.
  bool update({
    required Object owner,
    required String sessionId,
    required HomeWidgetAgentState state,
    required int nowMs,
    String? title,
    String? profile,
    String? toolName,
    HomeWidgetNeed? need,

    /// Start of the live turn by the chat's own clock (the one its in-app
    /// timer counts from), when the chat knows it.
    int? turnStartedAtMs,
  }) {
    final before = _chats[owner];
    if (!HomeWidgetChatActivity.activeStates.contains(state)) {
      return _chats.remove(owner) != null;
    }
    final waiting = state == HomeWidgetAgentState.waitingApproval;
    final next = HomeWidgetChatActivity(
      sessionId: sessionId,
      state: state,
      title: title ?? before?.title,
      profile: profile ?? before?.profile,
      phase: state == HomeWidgetAgentState.toolExecution
          ? homeWidgetToolPhrase(toolName)
          : null,
      // The turn's own start when the chat knows it. Otherwise the moment
      // this list first saw it run: a turn that pauses for an answer and goes
      // on is still the same turn. A start after "now" is not believed.
      startedAtMs:
          (turnStartedAtMs != null &&
                  turnStartedAtMs > 0 &&
                  turnStartedAtMs <= nowMs
              ? turnStartedAtMs
              : null) ??
          before?.startedAtMs ??
          nowMs,
      need: waiting ? need ?? before?.need : null,
    );
    _chats[owner] = next;
    return before == null || _signature(before) != _signature(next);
  }

  /// The chat is gone (closed, or its registry entry dropped).
  bool remove(Object owner) => _chats.remove(owner) != null;

  void clear() => _chats.clear();

  /// The ones waiting for the owner first, then the longest running.
  List<HomeWidgetChatActivity> get list {
    final sorted = _chats.values.toList()
      ..sort((a, b) {
        if (a.needsYou != b.needsYou) return a.needsYou ? -1 : 1;
        return (a.startedAtMs ?? 0).compareTo(b.startedAtMs ?? 0);
      });
    return List.unmodifiable(sorted.take(HermesHomeWidgetSnapshot.maxActive));
  }

  static String _signature(HomeWidgetChatActivity chat) =>
      chat.toMap().toString();
}
