// The fictional "Project Aurora" dataset served by aurora_fixture_server.dart.
//
// Everything here is invented for the public screenshots: a small team
// shipping the launch of a made-up mobile app. No real names, hosts, paths,
// brands or conversations. Times are relative to the moment the fixture is
// asked, so "2 min ago" is always fresh.
import 'dart:convert';

const projectName = 'Project Aurora';

/// One scripted event of a live turn.
class TurnStep {
  const TurnStep(this.type, this.payload, {this.delayMs = 400});
  final String type;
  final Map<String, dynamic> payload;
  final int delayMs;
}

/// Hold the turn here until the control endpoint releases it.
class TurnPause extends TurnStep {
  const TurnPause() : super('pause', const {});
}

/// Seconds the fixture's clock runs ahead of (or behind) the host's, so the
/// fixture agrees with an emulator whose clock was moved to a fixed time.
double clockOffsetSeconds = 0;

double _now() =>
    DateTime.now().millisecondsSinceEpoch / 1000 + clockOffsetSeconds;
double _ago(num seconds) => _now() - seconds;

class _Bot {
  const _Bot(
    this.name,
    this.display,
    this.role,
    this.model,
    this.provider,
    this.shape,
    this.color,
    this.skills, {
    this.pinned = false,
    this.section = 'sec-team',
    this.sectionName = 'Aurora team',
  });
  final String name;
  final String display;
  final String role;
  final String model;
  final String provider;
  final String shape;
  final String color;
  final int skills;
  final bool pinned;
  final String section;
  final String sectionName;
}

const _bots = <_Bot>[
  _Bot('default', 'Hermes', 'General assistant', 'gpt-5.5', 'openai-codex',
      'blobatar::round', '#8d8aa8', 14,
      section: 'sec-core', sectionName: 'Core'),
  _Bot('nova', 'Nova', 'Lead assistant for the launch', 'gpt-5.5',
      'openai-codex', 'blobatar::organic', '#7c6cff', 12,
      pinned: true, section: 'sec-core', sectionName: 'Core'),
  _Bot('atlas', 'Atlas', 'Research and market notes', 'claude-opus-5',
      'anthropic', 'blobatar::cloud', '#2fb8a6', 9),
  _Bot('pixel', 'Pixel', 'Design and store assets', 'gpt-5.5', 'openai-codex',
      'blobatar::sun', '#f2a03d', 7),
  _Bot('scout', 'Scout', 'QA and release checks', 'gpt-5.5-mini',
      'openai-codex', 'blobatar::hexagon', '#4c9ff0', 11),
  _Bot('ledger', 'Ledger', 'Budget and vendor tracking', 'claude-sonnet-5',
      'anthropic', 'blobatar::capsule', '#e0617d', 6),
  _Bot('echo', 'Echo', 'Support replies and FAQs', 'gpt-5.5-mini',
      'openai-codex', 'blobatar::droplet', '#8fcf5a', 5),
];

class AuroraData {
  final Map<String, List<Map<String, dynamic>>> _extraMessages = {};
  final Map<String, String> _newSessionProfile = {};
  int _todoRevision = 0;

  static const defaultSessionId = 'aurora-chat-launch';
  static const liveSessionId = 'aurora-chat-notes';

  // ------------------------------------------------------------- sessions

  List<Map<String, dynamic>> _sessionDefs() => [
    {
      'id': 'aurora-chat-notes',
      'title': 'Release notes for 1.4',
      'profile': 'nova',
      'preview': 'Eight changes merged. Want me to draft the 1.4 notes?',
      'age': 900,
      'started': 190,
      'messages': 14,
    },
    {
      'id': 'aurora-chat-launch',
      'title': 'Launch status and risks',
      'profile': 'nova',
      'preview': 'Two risks left: store screenshots and the pricing page.',
      'age': 1500,
      'started': 5400,
      'messages': 12,
    },
    {
      'id': 'aurora-chat-brief',
      'title': 'One-page launch brief',
      'profile': 'nova',
      'preview': 'The brief is ready as a PDF.',
      'age': 3600,
      'started': 4200,
      'messages': 4,
    },
    {
      'id': 'aurora-chat-copy',
      'title': 'Landing page copy',
      'profile': 'nova',
      'preview': 'Here are three headline options for the hero section.',
      'age': 7200,
      'started': 9000,
      'messages': 18,
    },
    {
      'id': 'aurora-chat-pricing',
      'title': 'Pricing page numbers',
      'profile': 'nova',
      'preview': 'The annual plan saves 20 percent against monthly billing.',
      'age': 18000,
      'started': 20000,
      'messages': 9,
    },
    {
      'id': 'aurora-chat-qa',
      'title': 'Regression pass on Android 15',
      'profile': 'scout',
      'preview': 'All 48 checks passed, one flaky test re-run.',
      'age': 30000,
      'started': 32000,
      'messages': 22,
    },
    {
      'id': 'aurora-chat-faq',
      'title': 'FAQ for the support desk',
      'profile': 'echo',
      'preview': 'Added eight answers about sync and backups.',
      'age': 52000,
      'started': 54000,
      'messages': 16,
    },
    {
      'id': 'aurora-chat-onboarding',
      'title': 'Onboarding flow ideas',
      'profile': 'pixel',
      'preview': 'A three-step welcome with one permission per screen.',
      'age': 90000,
      'started': 95000,
      'messages': 11,
    },
  ];

  List<Map<String, dynamic>> sessionRows() => [
    for (final s in _sessionDefs())
      {
        'id': s['id'],
        'title': s['title'],
        'model': _botFor(s['profile'] as String).model,
        'source': 'mobile',
        'message_count': s['messages'],
        'is_active': s['active'] == true,
        'preview': s['preview'],
        'started_at': _ago(s['started'] as num),
        'last_active': _ago(s['age'] as num),
        '_lineage_root_id': s['id'],
        'input_tokens': 18200,
        'output_tokens': 2100,
        'api_call_count': 6,
        'profile': s['profile'],
        'is_default_profile': s['profile'] == 'default',
      },
  ];

  List<Map<String, dynamic>> rpcSessionRows(Map<String, dynamic> params) {
    final title = params['title'];
    final profile = params['profile'];
    if (title == 'Bot Chat' && profile is String) {
      final bot = _botFor(profile);
      return [
        {
          'id': 'aurora-botchat-${bot.name}',
          'resolved_id': 'aurora-botchat-${bot.name}',
          'title': 'Bot Chat',
          'preview': _botPreview(bot.name),
          'started_at': _ago(400000),
          'message_count': 24,
          'source': 'tui',
        },
      ];
    }
    return [
      for (final row in sessionRows())
        if (profile == null || row['profile'] == profile)
          {
            ...row,
            'last_active': row['last_active'],
          },
    ];
  }

  List<Map<String, dynamic>> activeSessions() => [
    {
      'current': false,
      'id': 'rt-scout-1',
      'last_active': _ago(60),
      'message_count': 22,
      'model': 'gpt-5.5-mini',
      'preview': 'Running the regression pass…',
      'session_key': 'aurora-botchat-scout',
      'started_at': _ago(900),
      'status': 'working',
      'title': 'Bot Chat',
    },
    {
      'current': false,
      'id': 'rt-atlas-1',
      'last_active': _ago(1800),
      'message_count': 24,
      'model': 'claude-opus-5',
      'preview': _botPreview('atlas'),
      'session_key': 'aurora-botchat-atlas',
      'started_at': _ago(9000),
      'status': 'idle',
      'title': 'Bot Chat',
    },
  ];

  String? storedForRuntime(String runtime) {
    for (final row in activeSessions()) {
      if (row['id'] == runtime) return row['session_key'] as String?;
    }
    return null;
  }

  void newSession(String id, String? profile) {
    _extraMessages[id] = [];
    if (profile != null) _newSessionProfile[id] = profile;
  }

  // ------------------------------------------------------------- messages

  List<Map<String, dynamic>> messages(String id) {
    final base = switch (id) {
      defaultSessionId => _launchChat(),
      liveSessionId => _notesChat(),
      'aurora-chat-brief' => _briefChat(),
      _ => _genericChat(id),
    };
    return [...base, ...(_extraMessages[id] ?? const [])];
  }

  List<Map<String, dynamic>> _briefChat() => [
    _user('Turn the launch plan into a one-page PDF brief.'),
    {
      'role': 'assistant',
      'content': '',
      'tool_calls': [
        _call('call_b1', 'write_file', {
          'path': 'aurora/aurora-brief.pdf',
        }),
      ],
    },
    _toolResult(
      'call_b1',
      'write_file',
      'Wrote aurora-brief.pdf\nMEDIA:/srv/aurora/aurora-brief.pdf',
    ),
    _assistant(
      'The one-page brief is ready: the goal, three launch priorities and '
      'what is left to review.\n\nMEDIA:/srv/aurora/aurora-brief.pdf',
    ),
  ];

  List<Map<String, dynamic>> _notesChat() => [
    _user('What has landed since the 1.3 release?'),
    _assistant(
      'Eight changes merged: a faster first connection, a simpler welcome '
      'flow and a few voice fixes. Want me to draft the 1.4 notes?',
    ),
  ];

  List<Map<String, dynamic>> _genericChat(String id) {
    final row = _sessionDefs().where((s) => s['id'] == id).firstOrNull;
    final preview = row?['preview']?.toString() ?? 'Done.';
    return [
      _user('Can you take this on for the Aurora launch?'),
      _assistant(preview),
    ];
  }

  Map<String, dynamic> _user(String text) => {
    'role': 'user',
    'content': text,
    'text': text,
  };

  Map<String, dynamic> _assistant(String text, {List<Object>? calls}) => {
    'role': 'assistant',
    'content': text,
    'text': text,
    'tool_calls': ?calls,
  };

  Map<String, dynamic> _call(String id, String name, Map<String, dynamic> args) =>
      {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': jsonEncode(args)},
      };

  Map<String, dynamic> _toolResult(String id, String name, String content) => {
    'role': 'tool',
    'tool_call_id': id,
    'tool_name': name,
    'name': name,
    'content': content,
  };

  List<Map<String, dynamic>> _launchChat() => [
    _user(
      'Where do we stand on the Aurora launch? Give me a table by '
      'workstream and flag anything at risk.',
    ),
    {
      'role': 'assistant',
      'content': '',
      'reasoning':
          'The user wants a status table. I should read the launch checklist '
          'and the task board before answering, then flag what is blocked.',
      'tool_calls': [
        _call('call_1', 'read_file', {'path': 'docs/launch-checklist.md'}),
        _call('call_2', 'search_files', {
          'pattern': 'TODO|BLOCKED',
          'path': 'docs',
        }),
      ],
    },
    _toolResult(
      'call_1',
      'read_file',
      '# Launch checklist\n[x] First-run walkthrough\n[x] Voice flow review\n'
          '[x] Getting-started guide\n[ ] Store screenshots\n'
          '[ ] Final pricing page review\n',
    ),
    _toolResult(
      'call_2',
      'search_files',
      'docs/pricing.md:12: TODO confirm annual discount\n'
          'docs/store-listing.md:30: BLOCKED waiting on screenshots\n',
    ),
    _assistant(
      'Aurora is on track for **Thursday**. Two items still need a decision.\n\n'
      '| Workstream | Owner | Status |\n'
      '| --- | --- | --- |\n'
      '| Onboarding flow | Pixel | Done |\n'
      '| Voice mode | Scout | Done |\n'
      '| Store listing | Pixel | At risk |\n'
      '| Pricing page | Ledger | At risk |\n\n'
      'Once both are in, run the preflight:\n\n'
      '```bash\n'
      './scripts/preflight.sh --release\n'
      '```\n',
    ),
  ];

  void appendTurn(String stored, String prompt, String reply) {
    final list = _extraMessages.putIfAbsent(stored, () => []);
    list
      ..add(_user(prompt))
      ..add(_assistant(reply));
  }

  // ------------------------------------------------------------- snapshot

  Map<String, dynamic> snapshot(String stored, String runtimeId) {
    final row = _sessionDefs().where((s) => s['id'] == stored).firstOrNull;
    final profileName =
        (row?['profile'] as String?) ?? _newSessionProfile[stored] ?? 'nova';
    final bot = _botFor(profileName);
    final msgs = messages(stored);
    return {
      'session_id': runtimeId,
      'resumed': stored,
      'session_key': stored,
      'messages': msgs,
      'message_count': msgs.length,
      'running': false,
      'status': 'idle',
      'info': {
        'model': bot.model,
        'provider': bot.provider,
        'reasoning_effort': 'medium',
        'fast': false,
        'running': false,
        'title': (row?['title'] as String?) ?? 'New chat',
        'stored_session_id': stored,
        'desktop_contract': 19,
        'version': '0.20.1',
        'profile_name': profileName,
        'cwd': '~/aurora',
        'branch': 'release/1.4',
        'usage': {
          'calls': 6,
          'input': 18200,
          'output': 2100,
          'total': 20300,
          'context_used': 24800,
          'context_max': 400000,
          'context_percent': 6,
          'cost_usd': 0.42,
        },
      },
    };
  }

  Map<String, dynamic> contextBreakdown() => {
    'categories': [
      {'id': 'system', 'label': 'System', 'tokens': 3200},
      {'id': 'tools', 'label': 'Tools', 'tokens': 6100},
      {'id': 'conversation', 'label': 'Conversation', 'tokens': 15500},
    ],
    'context_used': 24800,
    'context_max': 400000,
    'context_percent': 6.2,
    'estimated_total': 24800,
    'model': 'gpt-5.5',
  };

  Map<String, dynamic> sessionUsage() => {
    'model': 'gpt-5.5',
    'input': 18200,
    'output': 2100,
    'total': 20300,
    'calls': 6,
    'context_used': 24800,
    'context_max': 400000,
    'context_percent': 6,
    'account_lines': [
      '📈 **Account limits**',
      'Provider: openai-codex (Plus)',
      '5-hour window: 38% used • resets in 2h 10m',
      'Weekly window: 61% used • resets Monday',
    ],
  };

  Map<String, dynamic> usageBars() => {'available': false};

  // ------------------------------------------------------------- profiles

  _Bot _botFor(String name) =>
      _bots.where((b) => b.name == name).firstOrNull ?? _bots.first;

  String _botPreview(String name) => switch (name) {
    'atlas' => 'Three competitors changed their pricing this month.',
    'pixel' => 'The store banner is ready for review.',
    'scout' => 'Regression pass: 46 of 48 checks done.',
    'ledger' => 'Vendor invoices reconciled for October.',
    'echo' => 'Eight FAQ answers drafted for the support desk.',
    _ => 'Launch is on track for Thursday.',
  };

  List<Map<String, dynamic>> profileNames() => [
    for (final b in _bots) {'name': b.name, 'is_default': b.name == 'default'},
  ];

  Map<String, dynamic> _profileRow(_Bot b) {
    final session = {
      'id': 'aurora-botchat-${b.name}',
      'resolved_id': 'aurora-botchat-${b.name}',
      'root_title': 'Bot Chat',
      'title': 'Bot Chat',
      'preview': _botPreview(b.name),
      'started_at': _ago(400000),
      'last_active': _ago(b.name == 'nova'
          ? 40
          : b.name == 'scout'
          ? 60
          : 1800 + _bots.indexOf(b) * 2400),
      'message_count': 24,
    };
    return {
      'name': b.name,
      'path': b.name == 'default'
          ? '~/.hermes'
          : '~/.hermes/profiles/${b.name}',
      'is_default': b.name == 'default',
      'model': b.model,
      'provider': b.provider,
      'display_name': b.display,
      'description': b.role,
      'skill_count': b.skills,
      'gateway_running': true,
      'has_avatar': false,
      'canonical_session': session,
      'last_session': session,
      'ui_meta': {
        'hermes-bots': {
          'title': b.display,
          'shape': b.shape,
          'color': b.color,
          'pinned': b.pinned,
          'sectionId': b.section,
          'sectionName': b.sectionName,
          'chat': 'aurora-botchat-${b.name}',
          'hidden': false,
        },
        if (b.name == 'default') 'hermes-bots-groups': _roomMirror(),
      },
      'ui_meta_revisions': {'hermes-bots': 7, 'hermes-bots-groups': 31},
      if (b.name == 'scout')
        'worker_session': {
          'id': 'aurora-worker-scout',
          'source': 'kanban',
          'title': 'Regression pass on Android 15',
          'last_active': _ago(20),
        },
    };
  }

  Map<String, dynamic> profilesList() => {
    'bot_mode_protocol': true,
    'profiles': [for (final b in _bots) _profileRow(b)],
  };

  Map<String, dynamic> profileDescribe(String name) {
    final b = _botFor(name);
    return {
      'name': b.name,
      'display_name': b.display,
      'description': b.role,
      'model': b.model,
      'provider': b.provider,
      'skill_count': b.skills,
    };
  }

  // --------------------------------------------------------------- rooms

  static const _roomLaunch = 'room-launch-crew';
  static const _roomDesign = 'room-design-review';

  Map<String, dynamic> _roomMirror() => {
    'version': 3,
    'updatedAt': (_now() * 1000).round(),
    'rooms': <String, dynamic>{},
    'deleted': <String, dynamic>{},
  };

  List<Map<String, dynamic>> _members(List<String> names) => [
    for (final n in names)
      {
        'member_id': 'member-$n',
        'profile': n,
        'handle': n,
        'display_name': _botFor(n).display,
        'target': {'kind': 'local', 'profile': n},
      },
  ];

  Map<String, dynamic> _room(String id, String name, List<String> members,
      int latest, double updatedAgo) => {
    'room_id': id,
    'name': name,
    'members': _members(members),
    'authority_gateway_id': 'gw-aurora-1',
    'authority_epoch': 2,
    'revision': 5,
    'created_at': _ago(500000),
    'updated_at': _ago(updatedAgo),
    'latest_seq': latest,
  };

  List<Map<String, dynamic>> _rooms() => [
    _room(_roomLaunch, 'Launch crew',
        ['nova', 'atlas', 'pixel', 'scout'], 14, 90),
    _room(_roomDesign, 'Design review', ['nova', 'pixel', 'echo'], 6, 7200),
  ];

  Map<String, dynamic> groupsCapabilities() => {
    'protocol_version': 2,
    'driver': true,
    'persistent_process': true,
    'authority_gateway_id': 'gw-aurora-1',
    'room_link': {'enabled': false, 'reason': 'gateway_roomlink_secret_unavailable'},
    'features': [
      'authority_epoch',
      'coordinator_fencing',
      'room_identity',
      'monotonic_log',
      'idempotent_send',
      'replayable_disband',
      'typed_events',
      'actor_identity',
      'log_replication',
      'authority_takeover',
    ],
    'methods': [
      'groups.capabilities',
      'groups.list',
      'groups.create',
      'groups.state',
      'groups.send',
      'groups.rename',
      'groups.log',
      'groups.disband',
      'groups.stop',
      'groups.retry',
      'groups.approve',
    ],
    'max_log_limit': 500,
  };

  Map<String, dynamic> groupsList() => {
    'rooms': _rooms(),
    'next_offset': null,
  };

  Map<String, dynamic> groupsState(String roomId) {
    final room = _rooms().where((r) => r['room_id'] == roomId).firstOrNull ??
        _rooms().first;
    return {
      'room': room,
      'driver_status': {
        'running': true,
        'working': false,
        'blocked': false,
        'counts': {'running': 0, 'settled': 4, 'indeterminate': 0},
        'pending_actions': <Object>[],
        'peer_routes': <Object>[],
      },
    };
  }

  Map<String, dynamic> groupsSend(Map<String, dynamic> params) => {
    'accepted': true,
    'event_id': 'user:${DateTime.now().microsecondsSinceEpoch}',
  };

  Map<String, dynamic> groupsLog(Map<String, dynamic> params) {
    final roomId = params['room_id']?.toString() ?? _roomLaunch;
    final since = (params['since_seq'] as num?)?.toInt() ?? 0;
    final limit = (params['limit'] as num?)?.toInt() ?? 100;
    final events = roomId == _roomDesign ? _designLog() : _launchLog();
    final latest = events.isEmpty ? 0 : events.last['seq'] as int;
    final page = [
      for (final e in events)
        if ((e['seq'] as int) > since) e,
    ].take(limit).toList();
    final cursor = page.isEmpty ? since : page.last['seq'] as int;
    return {
      'events': page,
      'cursor': cursor,
      'latest_seq': latest,
      'has_more': cursor < latest,
      'authority': {'gateway_id': 'gw-aurora-1', 'epoch': 2},
    };
  }

  Map<String, dynamic> _ev(String room, int seq, String kind, Map actor,
      Map<String, dynamic> payload, double ago) => {
    'room_id': room,
    'seq': seq,
    'event_id': '$kind:$room:$seq',
    'kind': kind,
    'actor': actor,
    'authority_epoch': 2,
    'payload': payload,
    'created_at': _ago(ago),
    'idempotent': false,
  };

  Map<String, dynamic> _member(String n) => {
    'kind': 'member',
    'id': 'member-$n',
    'profile': n,
    'display_name': _botFor(n).display,
  };

  List<Map<String, dynamic>> _launchLog() {
    final user = {'kind': 'user', 'id': 'desktop'};
    final gw = {'kind': 'gateway', 'id': 'gw-aurora-1'};
    Map<String, dynamic> turn(String n, int i) => {
      'discussion_event_id': 'user:launch-1',
      'member_id': 'member-$n',
      'member_index': i,
      'round_index': 0,
      'task_id': 'task-$n-1',
      'thread_id': 'thread-1',
      'turn_id': 'turn-$n-1',
    };
    return [
      _ev(_roomLaunch, 1, 'message.user', user, {
        'text': '@atlas @pixel @scout where are we on the Thursday launch?',
        'thread_id': 'thread-1',
      }, 900),
      _ev(_roomLaunch, 2, 'turn.started', gw, turn('atlas', 0), 895),
      _ev(_roomLaunch, 3, 'message.member', _member('atlas'), {
        ...turn('atlas', 0),
        'text': 'Market notes are done. Two competitors moved their pricing, '
            'so I added a comparison to the brief.',
      }, 860),
      _ev(_roomLaunch, 4, 'turn.settled', gw, {
        ...turn('atlas', 0),
        'seen_through_seq': 3,
        'message_event_id': 'message.member:$_roomLaunch:3',
        'passed': false,
      }, 858),
      _ev(_roomLaunch, 5, 'turn.started', gw, turn('pixel', 1), 850),
      _ev(_roomLaunch, 6, 'message.member', _member('pixel'), {
        ...turn('pixel', 1),
        'text': 'The store banner and icon are ready. I am still waiting on '
            'the final screenshots from **Scout**.',
      }, 700),
      _ev(_roomLaunch, 7, 'turn.settled', gw, {
        ...turn('pixel', 1),
        'seen_through_seq': 6,
        'message_event_id': 'message.member:$_roomLaunch:6',
        'passed': false,
      }, 698),
      _ev(_roomLaunch, 8, 'turn.started', gw, turn('scout', 2), 690),
      _ev(_roomLaunch, 9, 'message.member', _member('scout'), {
        ...turn('scout', 2),
        'text': 'Regression pass is at 46 of 48 checks. Screenshots will be '
            'ready this afternoon.',
      }, 400),
      _ev(_roomLaunch, 10, 'turn.settled', gw, {
        ...turn('scout', 2),
        'seen_through_seq': 9,
        'message_event_id': 'message.member:$_roomLaunch:9',
        'passed': false,
      }, 398),
      _ev(_roomLaunch, 11, 'message.user', user, {
        'text': 'Great. Atlas, can you add the pricing comparison to the '
            'launch checklist?',
        'thread_id': 'thread-2',
      }, 150),
      _ev(_roomLaunch, 12, 'turn.started', gw, {
        ...turn('atlas', 0),
        'discussion_event_id': 'user:launch-2',
        'task_id': 'task-atlas-2',
        'thread_id': 'thread-2',
        'turn_id': 'turn-atlas-2',
      }, 145),
      _ev(_roomLaunch, 13, 'message.member', _member('atlas'), {
        ...turn('atlas', 0),
        'discussion_event_id': 'user:launch-2',
        'task_id': 'task-atlas-2',
        'thread_id': 'thread-2',
        'turn_id': 'turn-atlas-2',
        'text': 'Done. The comparison is now step 6 in `docs/launch-checklist.md`.',
      }, 100),
      _ev(_roomLaunch, 14, 'turn.settled', gw, {
        ...turn('atlas', 0),
        'discussion_event_id': 'user:launch-2',
        'task_id': 'task-atlas-2',
        'thread_id': 'thread-2',
        'turn_id': 'turn-atlas-2',
        'seen_through_seq': 13,
        'message_event_id': 'message.member:$_roomLaunch:13',
        'passed': false,
      }, 98),
    ];
  }

  List<Map<String, dynamic>> _designLog() {
    final user = {'kind': 'user', 'id': 'desktop'};
    return [
      _ev(_roomDesign, 1, 'message.user', user,
          {'text': '@pixel what do you think of the new onboarding?', 'thread_id': 't1'},
          9000),
      _ev(_roomDesign, 2, 'message.member', _member('pixel'), {
        'member_id': 'member-pixel',
        'thread_id': 't1',
        'text': 'Three short steps work well. I would drop the last tooltip.',
      }, 8900),
    ];
  }

  // ----------------------------------------------------- models / config

  Map<String, dynamic> modelInfo() => {
    'model': 'gpt-5.5',
    'provider': 'openai-codex',
  };

  Map<String, dynamic> modelCatalog() => {
    'model': 'gpt-5.5',
    'provider': 'openai-codex',
    'providers': [
      {
        'slug': 'openai-codex',
        'name': 'OpenAI Codex',
        'authenticated': true,
        'is_current': true,
        'auth_type': 'oauth',
        'models': ['gpt-5.5', 'gpt-5.5-mini', 'gpt-5.5-codex'],
        'capabilities': {
          'gpt-5.5': {'fast': true, 'reasoning': true},
          'gpt-5.5-mini': {'fast': true, 'reasoning': true},
          'gpt-5.5-codex': {'fast': false, 'reasoning': true},
        },
      },
      {
        'slug': 'anthropic',
        'name': 'Anthropic',
        'authenticated': true,
        'auth_type': 'api_key',
        'models': ['claude-opus-5', 'claude-sonnet-5', 'claude-haiku-5'],
        'capabilities': {
          'claude-opus-5': {'fast': false, 'reasoning': true},
          'claude-sonnet-5': {'fast': true, 'reasoning': true},
          'claude-haiku-5': {'fast': true, 'reasoning': false},
        },
      },
      {
        'slug': 'openrouter',
        'name': 'OpenRouter',
        'authenticated': true,
        'auth_type': 'api_key',
        'models': ['mistral-large-3', 'llama-4-maverick'],
      },
      {
        'slug': 'nous',
        'name': 'Nous Portal',
        'authenticated': false,
        'auth_type': 'oauth',
        'models': ['hermes-5-405b'],
      },
    ],
  };

  Map<String, dynamic> auxiliary() => {
    'main': {'provider': 'openai-codex', 'model': 'gpt-5.5'},
    'tasks': [
      for (final t in const [
        ('vision', 'Image understanding'),
        ('compression', 'Context compression'),
        ('web_extract', 'Web page summaries'),
        ('session_search', 'Chat search'),
        ('title_generation', 'Chat titles'),
      ])
        {
          'task': t.$1,
          'label': t.$2,
          'provider': 'auto',
          'model': '',
        },
    ],
  };

  List<Map<String, dynamic>> oauthProviders() => [
    {
      'id': 'openai-codex',
      'name': 'OpenAI Codex',
      'flow': 'device_code',
      'status': {'logged_in': true},
    },
    {
      'id': 'nous',
      'name': 'Nous Portal',
      'flow': 'device_code',
      'status': {'logged_in': false},
    },
  ];

  Map<String, dynamic> env() => {
    'ANTHROPIC_API_KEY': {
      'category': 'provider',
      'provider': 'anthropic',
      'provider_label': 'Anthropic',
      'is_set': true,
      'is_password': true,
    },
    'OPENROUTER_API_KEY': {
      'category': 'provider',
      'provider': 'openrouter',
      'provider_label': 'OpenRouter',
      'is_set': true,
      'is_password': true,
    },
  };

  Map<String, dynamic> serverConfig() => {
    'model': {'default': 'gpt-5.5', 'provider': 'openai-codex'},
    'compression': {
      'enabled': true,
      'threshold': 0.72,
      'target_ratio': 0.45,
      'protect_last_n': 12,
    },
  };

  Map<String, dynamic> configSchema() => {
    'properties': {
      'compression': {
        'type': 'object',
        'properties': {
          'enabled': {'type': 'boolean'},
          'threshold': {'type': 'number', 'minimum': 0.1, 'maximum': 0.95},
          'target_ratio': {'type': 'number', 'minimum': 0.05, 'maximum': 0.8},
          'protect_last_n': {'type': 'integer', 'minimum': 0, 'maximum': 200},
        },
      },
    },
  };

  List<Map<String, dynamic>> skills() => [
    for (final s in const [
      ('research', 'Research a topic and cite sources'),
      ('release-notes', 'Draft release notes from merged work'),
      ('pdf-brief', 'Turn notes into a formatted PDF brief'),
      ('store-assets', 'Prepare store listing text and images'),
      ('regression-check', 'Run the regression checklist'),
    ])
      {'name': s.$1, 'description': s.$2, 'enabled': true},
  ];

  List<Map<String, dynamic>> toolsets() => [
    for (final t in const [
      ('web', 'Search and read the web', ['web_search', 'web_extract']),
      ('files', 'Read and edit files', ['read_file', 'write_file', 'search_files']),
      ('terminal', 'Run shell commands', ['terminal']),
      ('planning', 'Plan work with a task list', ['todo']),
    ])
      {
        'name': t.$1,
        'description': t.$2,
        'tool_count': t.$3.length,
        'enabled': true,
        'tools': t.$3,
      },
  ];

  Map<String, dynamic> commandsCatalog() => {
    'revision': 'aurora-1',
    'categories': [
      {
        'name': 'Session',
        'pairs': [
          ['/compress', 'Compress context'],
          ['/usage', 'Show context usage'],
        ],
      },
    ],
    'pairs': [
      ['/compress', 'Compress context'],
      ['/usage', 'Show context usage'],
    ],
    'canon': <String, dynamic>{},
  };

  Map<String, dynamic> projectsTree() => {
    'active_id': 'aurora',
    'projects': [
      {
        'id': 'aurora',
        'label': projectName,
        'sessionCount': 7,
        'repos': <Object>[],
      },
    ],
  };

  Object? rpcFallback(String method, Map<String, dynamic> params) => null;

  // ----------------------------------------------------------------- cron

  List<Map<String, dynamic>> cronJobs(String? profile) {
    Map<String, dynamic> job(String id, String name, String prompt,
        String expr, String display, String owner,
        {String state = 'scheduled',
        String status = 'ok',
        double lastAgo = 3600,
        double nextIn = 7200,
        String deliver = 'local'}) => {
      'id': id,
      'name': name,
      'prompt': prompt,
      'schedule': {'kind': 'cron', 'expr': expr, 'display': display},
      'schedule_display': display,
      'enabled': state != 'paused',
      'state': state,
      'deliver': deliver,
      'model': '',
      'provider': '',
      'profile': owner,
      'last_status': status,
      'last_run_at': _ago(lastAgo),
      'next_run_at': _now() + nextIn,
    };
    return [
      job('cron-brief', 'Morning launch brief',
          'Summarise open launch risks and what changed overnight.',
          '0 8 * * 1-5', 'Weekdays at 08:00', 'nova',
          lastAgo: 5400, nextIn: 80000),
      job('cron-changelog', 'Weekly changelog draft',
          'Draft the weekly changelog from merged work.',
          '0 16 * * 5', 'Fridays at 16:00', 'nova',
          lastAgo: 300000, nextIn: 190000),
      job('cron-audit', 'Dependency audit',
          'Check dependencies for security advisories.',
          '30 6 * * *', 'Daily at 06:30', 'scout',
          lastAgo: 11000, nextIn: 74000),
      job('cron-invoices', 'Vendor invoice check',
          'Reconcile vendor invoices against the budget sheet.',
          '0 9 1 * *', 'Monthly on the 1st at 09:00', 'ledger',
          lastAgo: 900000, nextIn: 1500000),
      job('cron-faq', 'Support FAQ refresh',
          'Add new support questions to the FAQ.',
          '0 12 * * 3', 'Wednesdays at 12:00', 'echo',
          state: 'paused', lastAgo: 600000, nextIn: 0),
    ];
  }

  // --------------------------------------------------------------- kanban

  Object? kanban(
    String method,
    String path,
    Map<String, String> query,
    Map<String, dynamic> body,
  ) {
    final rest = path.substring('/api/plugins/kanban/'.length);
    if (method == 'GET' && rest == 'boards') {
      return {
        'boards': [
          {'slug': 'aurora', 'name': projectName, 'is_current': true},
        ],
        'current': 'aurora',
      };
    }
    if (method == 'GET' && rest == 'board') return _kanbanBoard();
    if (method == 'GET' && rest == 'profiles') {
      return {
        'profiles': [
          for (final b in _bots)
            {'name': b.name, 'display_name': b.display, 'is_default': b.name == 'default'},
        ],
      };
    }
    final task = RegExp(r'^tasks/([^/]+)$').firstMatch(rest);
    if (method == 'GET' && task != null) {
      final id = Uri.decodeComponent(task.group(1)!);
      final t = _tasks().where((t) => t['id'] == id).firstOrNull;
      if (t == null) return null;
      return {
        'task': t,
        'comments': [
          {
            'id': 1,
            'task_id': id,
            'author': 'nova',
            'body': 'Looks good. Ping me when the review is up.',
            'created_at': _ago(5400).round(),
          },
        ],
        'events': [
          {
            'id': 1,
            'task_id': id,
            'kind': 'created',
            'payload': <String, dynamic>{},
            'created_at': _ago(86400).round(),
          },
        ],
        'links': {'parents': <String>[], 'children': <String>[], 'blocked_by': <String>[], 'blocks': <String>[]},
        'runs': <Object>[],
        'attachments': <Object>[],
      };
    }
    return null;
  }

  List<Map<String, dynamic>> _tasks() {
    Map<String, dynamic> t(String id, String title, String status,
        String? assignee, int priority,
        {String body = '',
        String? block,
        String? summary,
        int comments = 0,
        int done = 0,
        int total = 0}) => {
      'id': id,
      'title': title,
      'body': body,
      'status': status,
      'priority': priority,
      'assignee': assignee,
      'block_reason': block,
      'latest_summary': summary,
      'created_at': _ago(172800).round(),
      'started_at': status == 'running' ? _ago(1500).round() : null,
      'completed_at': status == 'done' ? _ago(36000).round() : null,
      'comment_count': comments,
      if (total > 0) 'progress': {'done': done, 'total': total},
    };
    return [
      t('AUR-101', 'Collect final store screenshots', 'triage', null, 2,
          body: 'Capture the six hero screens in English.'),
      t('AUR-111', 'Decide the launch-day banner copy', 'triage', null, 1),
      t('AUR-102', 'Write the launch announcement', 'todo', 'atlas', 2,
          body: 'Short post for the blog and the changelog.'),
      t('AUR-103', 'Confirm the annual plan discount', 'todo', 'ledger', 3,
          comments: 2),
      t('AUR-104', 'Draft the onboarding tooltips', 'ready', 'pixel', 1),
      t('AUR-112', 'Prepare the press kit folder', 'ready', 'pixel', 1),
      t('AUR-113', 'Reply to beta tester feedback', 'ready', 'echo', 2,
          comments: 4),
      t('AUR-105', 'Regression pass on Android 15', 'running', 'scout', 3,
          summary: '46 of 48 checks done', done: 46, total: 48),
      t('AUR-106', 'Update the store listing text', 'running', 'pixel', 2,
          summary: 'Short description rewritten', done: 2, total: 5),
      t('AUR-114', 'Compare competitor pricing', 'running', 'atlas', 2,
          summary: 'Three of five plans compared', done: 3, total: 5),
      t('AUR-115', 'Reconcile October vendor invoices', 'running', 'ledger', 1,
          done: 7, total: 9),
      t('AUR-107', 'Publish the support FAQ', 'blocked', 'echo', 2,
          block: 'Waiting on the pricing page numbers'),
      t('AUR-116', 'Review the pricing page copy', 'review', 'nova', 3),
      t('AUR-108', 'Voice mode review', 'done', 'scout', 2,
          summary: 'Passed with no open issues'),
      t('AUR-109', 'First-run walkthrough', 'done', 'pixel', 2,
          summary: 'Approved by the team'),
      t('AUR-110', 'Getting-started guide', 'done', 'nova', 1,
          summary: 'Published to the docs site'),
      t('AUR-117', 'Set up the crash dashboard', 'done', 'scout', 1),
    ];
  }

  Map<String, dynamic> _kanbanBoard() {
    final tasks = _tasks();
    return {
      'columns': [
        for (final name in const [
          'triage',
          'todo',
          'ready',
          'running',
          'blocked',
          'review',
          'done',
        ])
          {
            'name': name,
            'tasks': [
              for (final t in tasks)
                if (t['status'] == name) t,
            ],
          },
      ],
      'latest_event_id': 42,
    };
  }

  // ------------------------------------------------------------ live turn

  List<TurnStep> liveTurn(String stored, String prompt, {bool hold = false}) {
    Map<String, Object> todo(List<Map<String, String>> items) => {
      'todos': items,
      'revision': ++_todoRevision,
    };
    Map<String, String> task(String id, String content, String status) =>
        {'id': id, 'content': content, 'status': status};
    final plan1 = [
      task('1', 'Read what merged since 1.3', 'in_progress'),
      task('2', 'Group changes by theme', 'pending'),
      task('3', 'Write the 1.4 notes', 'pending'),
      task('4', 'Open tracking tasks', 'pending'),
    ];
    final plan2 = [
      task('1', 'Read what merged since 1.3', 'completed'),
      task('2', 'Group changes by theme', 'in_progress'),
      task('3', 'Write the 1.4 notes', 'pending'),
      task('4', 'Open tracking tasks', 'pending'),
    ];
    final reply = 'Here are the **1.4 release notes**.\n\n'
        '### New\n- Faster first connection\n- A simpler welcome flow\n\n'
        '### Fixed\n- Voice replies no longer cut off\n';
    return [
      const TurnStep('message.start', {}, delayMs: 200),
      const TurnStep(
        'reasoning.delta',
        {
          'text': 'I should read the merged work first, then group it by '
              'theme before writing the notes.',
        },
        delayMs: 500,
      ),
      TurnStep('tool.start', {
        'name': 'todo',
        'tool_id': 'live-todo-1',
        'args': todo(plan1),
      }, delayMs: 400),
      TurnStep('tool.complete', {
        'name': 'todo',
        'tool_id': 'live-todo-1',
        ...todo(plan1),
      }, delayMs: 300),
      const TurnStep('tool.start', {
        'name': 'terminal',
        'tool_id': 'live-term-1',
        'args': {'command': 'git log --oneline v1.3..HEAD'},
        'preview': 'git log --oneline v1.3..HEAD',
      }, delayMs: 500),
      const TurnStep('tool.complete', {
        'name': 'terminal',
        'tool_id': 'live-term-1',
        'preview': 'git log --oneline v1.3..HEAD',
        'result': '8f2a4c1 Polish the voice flow\n3b7d902 Simplify first connection\n',
      }, delayMs: 900),
      TurnStep('tool.start', {
        'name': 'todo',
        'tool_id': 'live-todo-2',
        'args': todo(plan2),
      }, delayMs: 300),
      TurnStep('tool.complete', {
        'name': 'todo',
        'tool_id': 'live-todo-2',
        ...todo(plan2),
      }, delayMs: 200),
      const TurnStep('tool.start', {
        'name': 'read_file',
        'tool_id': 'live-read-1',
        'args': {'path': 'CHANGELOG.md'},
        'preview': 'CHANGELOG.md',
      }, delayMs: 500),
      if (hold) const TurnPause(),
      const TurnStep('tool.complete', {
        'name': 'read_file',
        'tool_id': 'live-read-1',
        'preview': 'CHANGELOG.md',
      }, delayMs: 300),
      TurnStep('message.delta', {'text': reply}, delayMs: 400),
      TurnStep('message.complete', {'text': reply}, delayMs: 200),
    ];
  }
}
