import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_repository.dart';
import 'package:hermes_android/core/capabilities/capability_models.dart';
import 'package:hermes_android/core/capabilities/connector_detail_screen.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart'
    show TuiGatewayRpcError;

import '../support/inter_font.dart';
import 'capabilities_fakes.dart';

const _revision = '01HZX0000000000000000000R1';
const _revisionAfterSave = '01HZX0000000000000000000R2';
const _revisionOther = '01HZX0000000000000000000R3';

Map<String, dynamic> _memberPolicy({
  String revision = _revision,
  List<String> disabled = const [],
  Map<String, dynamic>? org,
}) => {
  'layers': [
    ?org,
    {
      'kind': 'member',
      'revision': revision,
      'body': {
        'mode': 'deny',
        'disabled_connectors': <String>[],
        'tools': {'github': disabled},
      },
    },
  ],
};

final _tools = {
  'connector': 'github',
  'tools': [
    {'slug': 'list_repos', 'name': 'List repos', 'facet': 'read'},
    {'slug': 'create_issue', 'name': 'Create issue', 'facet': 'write'},
    {'slug': 'delete_repo', 'name': 'Delete repo', 'facet': 'destructive'},
    {
      'slug': 'old_tool',
      'name': 'Old tool',
      'facet': 'read',
      'deprecated': true,
    },
  ],
};

class _Gateway {
  final calls = <(String, Map<String, dynamic>)>[];
  Object policy;
  Object tools = _tools;
  final List<Object> setResults = [];

  _Gateway(this.policy);

  List<Map<String, dynamic>> sets() => [
    for (final call in calls)
      if (call.$1 == 'connectors.policy.set') call.$2,
  ];

  int count(String method) => calls.where((c) => c.$1 == method).length;

  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    calls.add((method, params));
    Object result;
    switch (method) {
      case 'connectors.policy.get':
        result = policy;
      case 'connectors.tools':
        result = tools;
      case 'connectors.policy.set':
        result = setResults.isEmpty
            ? {'revision': _revisionAfterSave}
            : setResults.removeAt(0);
      default:
        throw TuiGatewayRpcError(method, 'nope', code: -32601);
    }
    if (result is Exception) throw result;
    return Map<String, dynamic>.from(result as Map);
  }
}

const _connector = HostedConnector(
  slug: 'github',
  name: 'GitHub',
  connected: true,
);

Future<void> _pump(
  WidgetTester tester,
  _Gateway gateway, {
  bool readOnly = false,
  VoidCallback? onChanged,
}) async {
  await setPhone(tester);
  await tester.pumpWidget(
    spanishApp(
      ConnectorDetailScreen(
        connector: _connector,
        repository: repoOf(ScriptedRest(), rpc: gateway.call),
        readOnly: readOnly,
        onChanged: onChanged,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

HermesToggleRow _row(WidgetTester tester, String key) =>
    tester.widget<HermesToggleRow>(find.byKey(ValueKey(key)));

Future<void> _tapTool(WidgetTester tester, String slug) async {
  final finder = find.byKey(ValueKey('cph-tool-$slug'));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  final finder = find.byKey(const ValueKey('cph-connector-save'));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Map<String, dynamic> _orgLock() => {
  'kind': 'org',
  'revision': '01HZX0000000000000000000OO',
  'body': {
    'mode': 'deny',
    'disabled_connectors': <String>[],
    'tools': {
      'github': ['delete_repo'],
    },
  },
};

void main() {
  setUpAll(loadInterFont);

  testWidgets(
    'reads policy and tools once, groups by facet, hides deprecated',
    (tester) async {
      final gateway = _Gateway(_memberPolicy(org: _orgLock()));
      await _pump(tester, gateway);

      expect(gateway.count('connectors.policy.get'), 1);
      expect(gateway.count('connectors.tools'), 1);
      expect(find.text('Lectura'), findsOneWidget);
      expect(find.text('Escritura'), findsOneWidget);
      expect(find.text('Destructivas'), findsOneWidget);
      expect(find.byKey(const ValueKey('cph-tool-old_tool')), findsNothing);

      // Locked by the organisation: off and not toggleable.
      final locked = _row(tester, 'cph-tool-delete_repo');
      expect(locked.value, isFalse);
      expect(locked.onChanged, isNull);
      expect(_row(tester, 'cph-tool-list_repos').value, isTrue);
      expect(_row(tester, 'cph-tool-list_repos').onChanged, isNotNull);
      // Nothing edited yet: no Save.
      expect(find.byKey(const ValueKey('cph-connector-save')), findsNothing);
    },
  );

  testWidgets('Save appears only when dirty and sends one full change', (
    tester,
  ) async {
    final gateway = _Gateway(_memberPolicy(disabled: ['old_tool']));
    var changed = 0;
    await _pump(tester, gateway, onChanged: () => changed++);

    await _tapTool(tester, 'create_issue');
    expect(find.byKey(const ValueKey('cph-connector-save')), findsOneWidget);
    // Back to the stored state: clean again.
    await _tapTool(tester, 'create_issue');
    expect(find.byKey(const ValueKey('cph-connector-save')), findsNothing);

    await _tapTool(tester, 'create_issue');
    await _tapTool(tester, 'list_repos');
    await _save(tester);

    expect(gateway.sets(), [
      {
        'change': {
          'type': 'tools',
          'connector': 'github',
          // The deprecated tool the screen hides stays in the list.
          'disabled_tools': ['create_issue', 'list_repos', 'old_tool'],
        },
        'expected_revision': _revision,
      },
    ]);
    expect(changed, 1);
    expect(find.byKey(const ValueKey('cph-connector-save')), findsNothing);
  });

  testWidgets('a second save quotes the revision the first one returned', (
    tester,
  ) async {
    final gateway = _Gateway(_memberPolicy());
    await _pump(tester, gateway);

    await _tapTool(tester, 'create_issue');
    await _save(tester);
    await _tapTool(tester, 'list_repos');
    await _save(tester);

    expect(gateway.sets().map((c) => c['expected_revision']).toList(), [
      _revision,
      _revisionAfterSave,
    ]);
  });

  testWidgets('a conflict keeps the draft and Keep mine re-saves on the new '
      'revision', (tester) async {
    final gateway = _Gateway(_memberPolicy())
      ..setResults.add(
        TuiGatewayRpcError(
          'connectors.policy.set',
          'Connector policy changed. Refresh and try again.',
          code: 4090,
          data: const {'reason': 'POLICY_CONFLICT'},
        ),
      );
    await _pump(tester, gateway);
    await _tapTool(tester, 'create_issue');

    // The other side disabled list_repos meanwhile.
    gateway.policy = _memberPolicy(
      revision: _revisionOther,
      disabled: ['list_repos'],
    );
    await _save(tester);

    expect(find.text('Las reglas cambiaron'), findsOneWidget);
    expect(find.textContaining('List repos'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('cph-conflict-keep')));
    await tester.pumpAndSettle();

    expect(gateway.sets(), hasLength(2));
    expect(gateway.sets().last['expected_revision'], _revisionOther);
    expect((gateway.sets().last['change'] as Map)['disabled_tools'], [
      'create_issue',
      'list_repos',
    ]);
  });

  testWidgets('Discard after a conflict adopts the other side', (tester) async {
    final gateway = _Gateway(_memberPolicy())
      ..setResults.add(
        TuiGatewayRpcError(
          'connectors.policy.set',
          'changed',
          code: 4090,
          data: const {'reason': 'POLICY_CONFLICT'},
        ),
      );
    await _pump(tester, gateway);
    await _tapTool(tester, 'create_issue');
    gateway.policy = _memberPolicy(
      revision: _revisionOther,
      disabled: ['list_repos'],
    );
    await _save(tester);
    await tester.tap(find.byKey(const ValueKey('cph-conflict-discard')));
    await tester.pumpAndSettle();

    expect(gateway.sets(), hasLength(1));
    expect(_row(tester, 'cph-tool-create_issue').value, isTrue);
    expect(_row(tester, 'cph-tool-list_repos').value, isFalse);
    expect(find.byKey(const ValueKey('cph-connector-save')), findsNothing);
  });

  testWidgets('the connector switch is one change with the member revision', (
    tester,
  ) async {
    final gateway = _Gateway(_memberPolicy());
    await _pump(tester, gateway);

    await tester.tap(find.byKey(const ValueKey('cph-connector-enabled')));
    await tester.pumpAndSettle();

    expect(gateway.sets(), [
      {
        'change': {
          'type': 'connector',
          'connector': 'github',
          'enabled': false,
        },
        'expected_revision': _revision,
      },
    ]);
  });

  testWidgets('an organisation lock disables the switch and says why', (
    tester,
  ) async {
    final gateway = _Gateway(
      _memberPolicy(
        org: {
          'kind': 'org',
          'revision': 'OO',
          'body': {'mode': 'deny-all'},
        },
      ),
    );
    await _pump(tester, gateway);

    final enabled = _row(tester, 'cph-connector-enabled');
    expect(enabled.value, isFalse);
    expect(enabled.onChanged, isNull);
    expect(find.text('Bloqueado por tu organización.'), findsOneWidget);
  });

  testWidgets('without a member layer everything is read-only', (tester) async {
    final gateway = _Gateway({
      'layers': [_orgLock()],
    });
    await _pump(tester, gateway);

    expect(_row(tester, 'cph-tool-list_repos').onChanged, isNull);
    expect(_row(tester, 'cph-connector-enabled').onChanged, isNull);
    expect(find.byKey(const ValueKey('cph-connector-save')), findsNothing);
    expect(
      find.text(
        'Tu organización gestiona estas reglas; aquí solo se pueden ver.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a read-only connection never edits', (tester) async {
    final gateway = _Gateway(_memberPolicy());
    await _pump(tester, gateway, readOnly: true);

    expect(_row(tester, 'cph-tool-list_repos').onChanged, isNull);
    expect(_row(tester, 'cph-connector-enabled').onChanged, isNull);
    expect(gateway.sets(), isEmpty);
  });

  testWidgets('signed out shows the existing note', (tester) async {
    final gateway = _Gateway(
      TuiGatewayRpcError(
        'connectors.policy.get',
        'Sign in',
        code: 4032,
        data: const {'reason': 'NEEDS_NOUS_AUTH'},
      ),
    );
    await _pump(tester, gateway);

    expect(
      find.textContaining('Inicia sesión con tu cuenta Nous'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('cph-connector-save')), findsNothing);
  });
}
