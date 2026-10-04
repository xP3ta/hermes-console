// The terminal is reached on demand only: one row in the chat controls and one
// in Settings, and neither is offered once the server or the connection says
// there is no terminal.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/models/terminal_exec.dart';
import 'package:hermes_android/core/services/terminal_availability.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_control_sheet.dart';

import 'support/fake_terminal_gateway.dart';

SavedConnection _conn({
  String id = 'c1',
  bool readOnly = false,
  String host = 'hermes.example.test',
  int port = 8642,
}) => SavedConnection(
  id: id,
  label: 'x',
  host: host,
  port: port,
  apiKey: 'k',
  readOnly: readOnly,
);

const _labels = ChatControlLabels(
  title: 'Chat settings',
  scope: 'Only this conversation',
  sessionSection: 'Session',
  toolsSection: 'Tools',
  dangerSection: 'Danger',
  permissions: 'Permissions',
  refresh: 'Refresh',
  artifacts: 'Artifacts',
  details: 'Details',
  cron: 'Schedule',
  delete: 'Delete conversation',
  readOnly: 'Read only',
  releaseDesktop: 'Release for Desktop',
  releaseUnavailable: 'Viewer cardinality unavailable',
  terminal: 'Terminal',
);

Widget _sheet({VoidCallback? onTerminal}) => MaterialApp(
  theme: AppTheme.hermesRedDark,
  home: Scaffold(
    body: ChatControlSheet(
      labels: _labels,
      conversationTitle: 'Synthetic conversation',
      onPermissions: () {},
      onRefresh: () {},
      onArtifacts: () {},
      onTerminal: onTerminal,
    ),
  ),
);

void main() {
  setUp(TerminalAvailability.resetForTesting);

  testWidgets('the chat controls list Terminal when it is offered', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(_sheet(onTerminal: () => opened++));
    await tester.tap(find.text('Terminal'));
    expect(opened, 1);
  });

  testWidgets('and omit it when it is not', (tester) async {
    await tester.pumpWidget(_sheet());
    expect(find.text('Terminal'), findsNothing);
  });

  test('hidden by default: nothing declared or confirmed yet', () {
    expect(TerminalAvailability.offered(_conn()), isFalse);
  });

  test('a 4004 answer to the empty probe confirms and offers it', () async {
    final gateway = FakeTerminalGateway();
    await TerminalAvailability.confirm(_conn(), gateway, profile: 'default');
    expect(gateway.commands.map((c) => c.command), ['']);
    expect(TerminalAvailability.offered(_conn()), isTrue);
  });

  test('a failed probe confirms nothing and a later one may retry', () async {
    final failing = _Probe(const ShellExecFailure());
    await TerminalAvailability.confirm(_conn(), failing, profile: 'default');
    expect(TerminalAvailability.offered(_conn()), isFalse);
    await TerminalAvailability.confirm(
      _conn(),
      FakeTerminalGateway(),
      profile: 'default',
    );
    expect(TerminalAvailability.offered(_conn()), isTrue);
  });

  test('-32601 hides it for good and is not probed again', () async {
    final gateway = _Probe(const ShellExecUnsupported());
    await TerminalAvailability.confirm(_conn(), gateway, profile: 'default');
    await TerminalAvailability.confirm(_conn(), gateway, profile: 'default');
    expect(TerminalAvailability.offered(_conn()), isFalse);
    expect(gateway.commands.length, 1);
  });

  test('a read-only connection is never probed or offered', () async {
    final gateway = FakeTerminalGateway();
    await TerminalAvailability.confirm(
      _conn(readOnly: true),
      gateway,
      profile: 'default',
    );
    expect(gateway.commands, isEmpty);
    expect(TerminalAvailability.offered(_conn(readOnly: true)), isFalse);
  });

  test('a confirmed connection stops being offered after -32601', () async {
    await TerminalAvailability.confirm(
      _conn(),
      FakeTerminalGateway(),
      profile: 'default',
    );
    TerminalAvailability.markUnsupported(_conn());
    expect(TerminalAvailability.offered(_conn()), isFalse);
    expect(TerminalAvailability.offered(_conn(id: 'c2')), isFalse);
  });

  test(
    'editing a saved connection to another server forgets the answer',
    () async {
      await TerminalAvailability.confirm(
        _conn(),
        FakeTerminalGateway(),
        profile: 'default',
      );
      expect(TerminalAvailability.offered(_conn()), isTrue);
      final moved = _conn(host: 'other.example.test');
      expect(TerminalAvailability.offered(moved), isFalse);
      final bare = _Probe(const ShellExecUnsupported());
      await TerminalAvailability.confirm(moved, bare, profile: 'default');
      expect(bare.commands.length, 1, reason: 'the new server is probed');
      expect(TerminalAvailability.offered(moved), isFalse);
    },
  );

  test(
    'a port change also forgets it, and an unsupported mark is per server',
    () async {
      TerminalAvailability.markUnsupported(_conn());
      expect(TerminalAvailability.offered(_conn()), isFalse);
      await TerminalAvailability.confirm(
        _conn(port: 9999),
        FakeTerminalGateway(),
        profile: 'default',
      );
      expect(TerminalAvailability.offered(_conn(port: 9999)), isTrue);
    },
  );
}

class _Probe extends FakeTerminalGateway {
  _Probe(this.error);
  final Object error;

  @override
  Future<ShellExecResult> shellExec(String command, {required String profile}) {
    commands.add((command: command, profile: profile));
    return Future.error(error);
  }
}
