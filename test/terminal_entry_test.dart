// The terminal is reached on demand only: one row in the chat controls and one
// in Settings, and neither is offered once the server or the connection says
// there is no terminal.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/terminal_availability.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_control_sheet.dart';

SavedConnection _conn({String id = 'c1', bool readOnly = false}) =>
    SavedConnection(
      id: id,
      label: 'x',
      host: 'hermes.example.test',
      port: 8642,
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

  test('offered by default for a writable connection', () {
    expect(TerminalAvailability.offered(_conn()), isTrue);
  });

  test('never offered on a read-only connection', () {
    expect(TerminalAvailability.offered(_conn(readOnly: true)), isFalse);
  });

  test('a server that answered -32601 stops being offered', () {
    TerminalAvailability.markUnsupported('c1');
    expect(TerminalAvailability.offered(_conn()), isFalse);
    expect(TerminalAvailability.offered(_conn(id: 'c2')), isTrue);
  });
}
