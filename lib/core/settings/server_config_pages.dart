/// The pages of Settings › Advanced and the server config fields on each: the
/// table of Hermes Desktop's `config-subpages.ts` (a field is on a page when
/// its dotted path is listed or starts with one of the page's prefixes).
enum ServerConfigPage {
  mainModel,
  behavior,
  projects,
  shell,
  files,
  network,
  context,
  conversation,
  runtime,
}

final class _PageRule {
  const _PageRule(this.fields, [this.prefixes = const []]);

  final Set<String> fields;
  final List<String> prefixes;

  bool matches(String path) =>
      fields.contains(path) || prefixes.any(path.startsWith);
}

// Order matters: a field listed on two pages (`agent.service_tier`) belongs to
// the first, as in Desktop's `configSubpageForField`.
const _rules = <ServerConfigPage, _PageRule>{
  ServerConfigPage.mainModel: _PageRule(
    {
      'model',
      'model_context_length',
      'agent.reasoning_effort',
      'agent.service_tier',
    },
    ['model.'],
  ),
  ServerConfigPage.behavior: _PageRule({
    'display.personality',
    'timezone',
    'display.show_reasoning',
  }),
  ServerConfigPage.projects: _PageRule(
    {'terminal.cwd'},
    ['desktop.repo_scan_'],
  ),
  ServerConfigPage.shell: _PageRule({
    'terminal.persistent_shell',
    'terminal.env_passthrough',
  }),
  ServerConfigPage.files: _PageRule({
    'code_execution.mode',
    'file_read_max_chars',
  }),
  ServerConfigPage.network: _PageRule({
    'browser.allow_private_urls',
    'browser.auto_local_for_private_urls',
  }),
  ServerConfigPage.context: _PageRule({}, [
    'context.',
    'compression.',
    'auxiliary.compression.',
  ]),
  ServerConfigPage.conversation: _PageRule(
    {
      'voice.voice_chat_mode',
      'voice.max_recording_seconds',
      'voice.client_direct',
    },
    ['voice.gpt_live.'],
  ),
  ServerConfigPage.runtime: _PageRule({
    'agent.max_turns',
    'agent.api_max_retries',
    'agent.service_tier',
  }),
};

/// The page [path] belongs to, or null when it is on none.
ServerConfigPage? serverConfigPageForField(String path) {
  for (final entry in _rules.entries) {
    if (entry.value.matches(path)) return entry.key;
  }
  return null;
}

// `agent.api_max_retries` is in Desktop's runtime table and holds a count,
// not a credential, so it is the one `api_` path that stays.
const _secretFreeApiPaths = {'agent.api_max_retries'};
final _secretLike = RegExp(
  'key|token|secret|password|api_',
  caseSensitive: false,
);

/// Whether Console edits [path] (of schema type [type]) from these pages.
/// Never: `model` (changed by the model picker), `object` fields, anything
/// that looks like a credential, and anything not in the page table.
bool isEditableServerConfigField(String path, String type) {
  if (path == 'model' || type == 'object') return false;
  if (!_secretFreeApiPaths.contains(path) && _secretLike.hasMatch(path)) {
    return false;
  }
  return serverConfigPageForField(path) != null;
}
