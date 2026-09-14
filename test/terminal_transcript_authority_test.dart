import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/terminal_transcript_authority.dart';

Map<String, dynamic> user({Object? id = 'user-1'}) => {
  'message_id': ?id,
  'role': 'user',
  'content': 'prompt',
};

Map<String, dynamic> assistant(
  String content, {
  Object? id = 'assistant-1',
  Object? toolCalls = absent,
  String role = 'assistant',
}) => {
  'message_id': ?id,
  'role': role,
  'content': content,
  if (!identical(toolCalls, absent)) 'tool_calls': toolCalls,
};

Map<String, dynamic> tool({
  Object? id = 'tool-1',
  Object? callId = absent,
  String name = 'search',
  String content = 'result',
}) => {
  'message_id': ?id,
  'role': 'tool',
  'name': name,
  'content': content,
  if (!identical(callId, absent)) 'tool_call_id': callId,
};

const absent = Object();
const callsA = [
  {
    'id': 'A',
    'type': 'function',
    'function': {'name': 'search', 'arguments': '{}'},
  },
];

TerminalAuthorityDecision decide(
  List<Map<String, dynamic>> messages, {
  TerminalEvidenceSource source = TerminalEvidenceSource.durableTranscript,
  bool complete = true,
  bool terminal = false,
  bool terminalError = false,
  bool compaction = false,
  bool current = true,
  bool visible = false,
  bool legacy = true,
}) => decideTerminalAuthority(
  chronological: messages,
  expectedUsers: 1,
  source: source,
  sourceTranscriptComplete: complete,
  transportTerminalObserved: terminal,
  transportTerminalIsError: terminalError,
  compactionFenceActive: compaction,
  currentAuthorityFence: current,
  visibleAssistantTextPresent: visible,
  allowLegacyDirectToolTerminal: legacy,
);

void main() {
  group('terminal transcript authority precedence', () {
    final cases =
        <
          ({
            String name,
            List<Map<String, dynamic>> messages,
            TerminalAuthorityKind kind,
          })
        >[
          (
            name: 'assistant call A then unlinked tool stays incomplete',
            messages: [
              user(),
              assistant('', toolCalls: callsA),
              tool(),
            ],
            kind: TerminalAuthorityKind.incompleteAwaitingAssistant,
          ),
          (
            name: 'assistant call A then linked A stays incomplete',
            messages: [
              user(),
              assistant('', toolCalls: callsA),
              tool(callId: 'A'),
            ],
            kind: TerminalAuthorityKind.incompleteAwaitingAssistant,
          ),
          (
            name: 'assistant call A then linked B is malformed',
            messages: [
              user(),
              assistant('', toolCalls: callsA),
              tool(callId: 'B'),
            ],
            kind: TerminalAuthorityKind.malformed,
          ),
          (
            name: 'assistant final with absent tool calls succeeds',
            messages: [user(), assistant('final')],
            kind: TerminalAuthorityKind.authoritativeSuccess,
          ),
          (
            name: 'assistant final with empty tool calls succeeds',
            messages: [
              user(),
              assistant('final', toolCalls: const []),
            ],
            kind: TerminalAuthorityKind.authoritativeSuccess,
          ),
          (
            name: 'empty assistant with empty calls stays incomplete',
            messages: [
              user(),
              assistant('', toolCalls: const []),
            ],
            kind: TerminalAuthorityKind.incompleteAwaitingAssistant,
          ),
          (
            name: 'scalar tool calls are malformed',
            messages: [
              user(),
              assistant('', toolCalls: 'A'),
            ],
            kind: TerminalAuthorityKind.malformed,
          ),
          (
            name: 'call without durable call id is malformed',
            messages: [
              user(),
              assistant(
                '',
                toolCalls: const [
                  {
                    'function': {'name': 'search', 'arguments': '{}'},
                  },
                ],
              ),
            ],
            kind: TerminalAuthorityKind.malformed,
          ),
          (
            name: 'assistant error wins over valid tool metadata',
            messages: [
              user(),
              assistant('failed', role: 'assistant_error', toolCalls: callsA),
            ],
            kind: TerminalAuthorityKind.authoritativeFailure,
          ),
          (
            name: 'durable direct legacy tool succeeds',
            messages: [user(), tool()],
            kind: TerminalAuthorityKind.authoritativeSuccess,
          ),
          (
            name: 'id-less direct legacy user is not terminal',
            messages: [user(id: null), tool()],
            kind: TerminalAuthorityKind.malformed,
          ),
          (
            name: 'id-less direct legacy tool is not terminal',
            messages: [user(), tool(id: null)],
            kind: TerminalAuthorityKind.malformed,
          ),
          (
            name: 'orphan linked tool is malformed',
            messages: [
              user(),
              tool(callId: 'A'),
            ],
            kind: TerminalAuthorityKind.malformed,
          ),
          (
            name: 'assistant final after tool chain succeeds',
            messages: [
              user(),
              assistant('', toolCalls: callsA),
              tool(callId: 'A'),
              assistant('final', id: 'assistant-2'),
            ],
            kind: TerminalAuthorityKind.authoritativeSuccess,
          ),
        ];

    for (final entry in cases) {
      test(entry.name, () {
        expect(decide(entry.messages).kind, entry.kind);
      });
    }

    test('correlated message.complete error wins over tool metadata', () {
      final result = decide(
        [user(), assistant('', toolCalls: callsA), tool(callId: 'A')],
        terminal: true,
        terminalError: true,
      );
      expect(result.kind, TerminalAuthorityKind.authoritativeFailure);
    });

    test('stale fence wins over otherwise malformed transcript', () {
      final result = decide([
        user(),
        assistant('', toolCalls: 'bad'),
      ], current: false);
      expect(result.kind, TerminalAuthorityKind.stale);
    });

    test('compaction fence rejects an old REST final', () {
      final result = decide(
        [user(), assistant('old final')],
        terminal: true,
        compaction: true,
      );
      expect(result.kind, TerminalAuthorityKind.stale);
      expect(result.mayPublishDone, isFalse);
      expect(result.mayDrainQueue, isFalse);
    });

    test('partial source cannot authorize direct legacy tool', () {
      final result = decide(
        [user(), tool()],
        source: TerminalEvidenceSource.desktopSnapshot,
        complete: false,
      );
      expect(result.kind, TerminalAuthorityKind.incompleteAwaitingAssistant);
    });

    test('transport terminal without transcript evidence is incomplete', () {
      final result = decide([user()], terminal: true);
      expect(result.kind, TerminalAuthorityKind.incompleteAwaitingAssistant);
      expect(result.needsRecovery, isTrue);
      expect(result.mayPublishDone, isFalse);
    });

    test('final decision exposes one coherent side-effect policy', () {
      final result = decide([user(), assistant('final')]);
      expect(result.assistantText, 'final');
      expect(result.mayReplaceVisibleProjection, isTrue);
      expect(result.mayPublishDone, isTrue);
      expect(result.mayDrainQueue, isTrue);
      expect(result.needsRecovery, isFalse);
    });

    test('partial assistant prefix cannot replace visible projection', () {
      final result = decide(
        [user(), assistant('partial')],
        complete: false,
        visible: true,
      );
      expect(result.kind, TerminalAuthorityKind.authoritativeSuccess);
      expect(result.mayReplaceVisibleProjection, isFalse);
    });

    test('complete snapshot final can replace visible projection', () {
      final result = decide(
        [user(), assistant('different final')],
        source: TerminalEvidenceSource.desktopSnapshot,
        complete: true,
        visible: true,
      );
      expect(result.kind, TerminalAuthorityKind.authoritativeSuccess);
      expect(result.mayReplaceVisibleProjection, isTrue);
    });
  });
}
