// «Contraseñas e inicios de sesión» (Hermes Desktop's Settings → Passwords &
// Logins) over the server vault: a fake gateway, no socket. Synthetic
// secrets carry the `canary-` prefix so a leak is easy to spot.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/vault_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/vault_service.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart' show HermesBadge;
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _password = 'canary-pw-7Hq';
const _master = 'canary-master-9Zx';
const _cvc = 'canary-cvc-123';

class _FakeVault implements VaultGateway {
  _FakeVault({this.readOnly = false});

  @override
  final bool readOnly;

  List<VaultItem> items = [];
  /// What `sources()` answers after the local vault row.
  List<VaultSource> sourcesResult = [];
  VaultFailure? listFailure;
  VaultFailure? sourcesFailure;
  VaultFailure? addFailure;
  VaultFailure? unlockFailure;

  /// The server saves the item and then its answer is lost.
  bool addSavesThenTimesOut = false;
  int lists = 0;
  final adds = <({VaultKind kind, String label, String? origin})>[];
  final secretKeys = <Set<String>>[];
  final secretValues = <String>[];
  final removed = <String>[];
  final toggles = <(String, bool)>[];
  final unlocks = <(String, String)>[];
  final locks = <String>[];

  @override
  Future<List<VaultItem>> list() async {
    lists++;
    final failure = listFailure;
    if (failure != null) throw failure;
    return items;
  }

  @override
  Future<List<VaultSource>> sources() async {
    final failure = sourcesFailure;
    if (failure != null) throw failure;
    return [
      const VaultSource(
        name: 'local',
        displayName: 'Hermes vault',
        enabled: true,
        needsUnlock: false,
        unlocked: true,
        installed: true,
      ),
      ...sourcesResult,
    ];
  }

  @override
  Future<void> add({
    required VaultKind kind,
    required String label,
    String? origin,
    required Map<String, String> secret,
  }) async {
    final failure = addFailure;
    if (failure != null) throw failure;
    adds.add((kind: kind, label: label, origin: origin));
    secretKeys.add(secret.keys.toSet());
    secretValues.addAll(secret.values);
    items = [
      ...items,
      VaultItem(id: 'vault_${items.length + 1}', kind: kind.wire, label: label),
    ];
    if (addSavesThenTimesOut) {
      throw const VaultFailure(VaultFailureKind.unavailable);
    }
  }

  @override
  Future<void> remove(String id) async {
    removed.add(id);
    items = [
      for (final item in items)
        if (item.id != id) item,
    ];
  }

  @override
  Future<void> setSourceEnabled(String name, {required bool enabled}) async {
    toggles.add((name, enabled));
  }

  @override
  Future<void> unlock(String name, String masterPassword) async {
    unlocks.add((name, masterPassword));
    final failure = unlockFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<void> lock(String name) async => locks.add(name);
}

const _github = VaultItem(
  id: 'vault_a1',
  kind: 'login',
  label: 'GitHub work',
  origin: 'https://github.com',
  createdAt: '2026-10-20T10:00:00+00:00',
  identifier: 'jose@example.com',
  identifierType: 'email',
  hasOtp: true,
);

const _bitwardenItem = VaultItem(
  id: 'bw_1',
  kind: 'login',
  label: 'Bank',
  origin: 'https://bank.example',
  identifier: 'jose',
  backend: 'bitwarden',
);

const _bitwarden = VaultSource(
  name: 'bitwarden',
  displayName: 'Bitwarden',
  enabled: true,
  needsUnlock: true,
  unlocked: false,
  installed: true,
);

final _connection = SavedConnection(
  id: 'c1',
  label: 'Home',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'k',
);

int _secureEntered = 0;
int _secureReleased = 0;

Future<Future<void> Function()> _fakeSecureScope() async {
  _secureEntered++;
  return () async => _secureReleased++;
}

Future<Strings> _pump(
  WidgetTester tester,
  _FakeVault vault, {
  ThemeData? theme,
  double textScale = 1,
  String profile = 'default',
  ValueListenable<bool>? appLocked,
}) async {
  tester.view.physicalSize = const Size(400, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      locale: const Locale('en'),
      theme: theme ?? AppTheme.hermesRedDark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('open-vault'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => VaultScreen(
                    connection: _connection,
                    profile: profile,
                    gateway: vault,
                    secureScope: _fakeSecureScope,
                    appLocked: appLocked,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-vault')));
  await _settle(tester);
  return Strings.of(tester.element(find.byKey(const ValueKey('vault-screen'))));
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

TextField _textField(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key)));

/// A line printed while the log capture is installed (proves it is live).
const _captureProbe = '[vault-test] log capture probe';

/// The [lines] that contain any of the [canaries].
List<String> _leakedLines(List<String> lines, List<String> canaries) => [
  for (final line in lines)
    if (canaries.any(line.contains)) line,
];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _secureEntered = 0;
    _secureReleased = 0;
  });

  testWidgets('empty vault: says so and offers Add', (tester) async {
    final s = await _pump(tester, _FakeVault());
    expect(find.byKey(const ValueKey('vault-empty')), findsOneWidget);
    expect(find.text(s.vltEmpty), findsOneWidget);
    expect(find.byKey(const ValueKey('vault-add')), findsOneWidget);
    expect(find.text(s.vltProfile('default').toUpperCase()), findsOneWidget);
  });

  testWidgets('items: metadata only, 2FA badge, managers keep their own', (
    tester,
  ) async {
    final vault = _FakeVault()
      ..items = [_github, _bitwardenItem]
      ..sourcesResult = [_bitwarden.copyUnlocked()];
    final s = await _pump(tester, vault);
    expect(find.text('GitHub work'), findsOneWidget);
    expect(find.textContaining('jose@example.com'), findsOneWidget);
    expect(find.textContaining('https://github.com'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('vault-otp-vault_a1')),
      findsOneWidget,
    );
    expect(find.text(s.vltTwoFactorBadge.toUpperCase()), findsOneWidget);
    // A local item can be removed; a password manager's item cannot.
    expect(
      find.byKey(const ValueKey('vault-remove-vault_a1')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('vault-remove-bw_1')), findsNothing);
    expect(find.text('BITWARDEN'), findsWidgets);
    // R5C C-K12: each remove says which item it removes.
    expect(find.byTooltip(s.vltRemoveItem('GitHub work')), findsOneWidget);
    // R5C C-K13: the profile badge is as wide as its text, no longer the
    // whole row (stretched, it measured exactly the row's width).
    final row = find.byKey(const ValueKey('vault-profile-badge'));
    final badge = find.descendant(of: row, matching: find.byType(HermesBadge));
    expect(tester.getSize(badge).width, lessThan(tester.getSize(row).width));
  });

  testWidgets('no connection: an error with Retry that recovers', (
    tester,
  ) async {
    final vault = _FakeVault()
      ..listFailure = const VaultFailure(VaultFailureKind.unavailable);
    final s = await _pump(tester, vault);
    expect(find.byKey(const ValueKey('vault-failed')), findsOneWidget);
    expect(find.text(s.vltUnavailable), findsOneWidget);
    vault.listFailure = null;
    await tester.tap(find.byKey(const ValueKey('vault-retry')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('vault-empty')), findsOneWidget);
  });

  testWidgets('an older Hermes without the vault: says so, no Add', (
    tester,
  ) async {
    final vault = _FakeVault()
      ..listFailure = const VaultFailure(VaultFailureKind.unsupported);
    final s = await _pump(tester, vault);
    expect(find.byKey(const ValueKey('vault-unsupported')), findsOneWidget);
    expect(find.text(s.vltUnsupported), findsOneWidget);
    expect(find.byKey(const ValueKey('vault-add')), findsNothing);
    expect(find.byKey(const ValueKey('vault-retry')), findsNothing);
  });

  testWidgets('without vault.sources the list still works', (tester) async {
    final vault = _FakeVault()
      ..items = [_github]
      ..sourcesFailure = const VaultFailure(VaultFailureKind.unsupported);
    await _pump(tester, vault);
    expect(find.text('GitHub work'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('vault-sources-unavailable')),
      findsOneWidget,
    );
  });

  group('add', () {
    Future<Strings> openAdd(WidgetTester tester, _FakeVault vault) async {
      final s = await _pump(tester, vault);
      await tester.tap(find.byKey(const ValueKey('vault-add')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('vault-add-screen')), findsOneWidget);
      return s;
    }

    testWidgets('secret fields are masked, never autofilled or learned', (
      tester,
    ) async {
      await openAdd(tester, _FakeVault());
      for (final key in ['vault-password', 'vault-otp']) {
        final field = _textField(tester, key);
        expect(field.obscureText, isTrue, reason: key);
        // R5C C-K1: a password field, not a «visible password» one.
        expect(
          field.keyboardType,
          isNot(TextInputType.visiblePassword),
          reason: key,
        );
        expect(field.autofillHints, isNull, reason: key);
        expect(field.enableSuggestions, isFalse, reason: key);
        expect(field.enableIMEPersonalizedLearning, isFalse, reason: key);
        expect(field.autocorrect, isFalse, reason: key);
      }
      await tester.tap(find.byKey(const ValueKey('vault-kind-payment')));
      await tester.pump();
      for (final key in ['vault-card-number', 'vault-cvc']) {
        final field = _textField(tester, key);
        expect(field.obscureText, isTrue, reason: key);
        expect(field.autofillHints, isNull, reason: key);
      }
      // The page is kept out of screenshots while it is open.
      expect(_secureEntered, 1);
    });

    testWidgets('a login: sent once with Desktop\'s payload, then listed', (
      tester,
    ) async {
      final vault = _FakeVault();
      await openAdd(tester, vault);
      await tester.enterText(
        find.byKey(const ValueKey('vault-label')),
        'GitHub',
      );
      await tester.enterText(
        find.byKey(const ValueKey('vault-origin')),
        'https://github.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('vault-identifier')),
        'jose@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('vault-password')),
        _password,
      );
      await tester.enterText(
        find.byKey(const ValueKey('vault-otp')),
        'JBSW Y3DP EHPK 3PXP',
      );
      await tester.tap(find.byKey(const ValueKey('vault-save')));
      await _settle(tester);
      expect(vault.adds.single.kind, VaultKind.login);
      expect(vault.adds.single.label, 'GitHub');
      expect(vault.adds.single.origin, 'https://github.com');
      expect(vault.secretKeys.single, {
        'identifier_type',
        'identifier',
        'password',
        'otp_secret',
      });
      expect(vault.secretValues, contains(_password));
      // Back on the list, re-read with the new item.
      expect(find.byKey(const ValueKey('vault-add-screen')), findsNothing);
      expect(find.text('GitHub'), findsOneWidget);
    });

    testWidgets('an invalid origin is refused before anything is sent', (
      tester,
    ) async {
      final vault = _FakeVault();
      final s = await openAdd(tester, vault);
      await tester.enterText(find.byKey(const ValueKey('vault-label')), 'X');
      await tester.enterText(
        find.byKey(const ValueKey('vault-origin')),
        'github.com',
      );
      await tester.tap(find.byKey(const ValueKey('vault-save')));
      await tester.pump();
      expect(find.text(s.vltOriginInvalid), findsOneWidget);
      expect(vault.adds, isEmpty);
    });

    testWidgets('a bad authenticator key is refused locally', (tester) async {
      final vault = _FakeVault();
      final s = await openAdd(tester, vault);
      await tester.enterText(find.byKey(const ValueKey('vault-label')), 'X');
      await tester.enterText(
        find.byKey(const ValueKey('vault-origin')),
        'https://x.example',
      );
      await tester.enterText(
        find.byKey(const ValueKey('vault-identifier')),
        'me',
      );
      await tester.enterText(
        find.byKey(const ValueKey('vault-password')),
        _password,
      );
      await tester.enterText(
        find.byKey(const ValueKey('vault-otp')),
        'otpauth://hotp/x?secret=ABC',
      );
      await tester.tap(find.byKey(const ValueKey('vault-save')));
      await tester.pump();
      expect(find.text(s.vltOtpInvalid), findsOneWidget);
      expect(vault.adds, isEmpty);
    });

    testWidgets('a save with no answer re-reads the list and says so', (
      tester,
    ) async {
      // R5C C-K4: Hermes may have saved it; a blind retry saved it twice.
      final vault = _FakeVault()..addSavesThenTimesOut = true;
      final s = await openAdd(tester, vault);
      final listsBefore = vault.lists;
      await tester.enterText(find.byKey(const ValueKey('vault-label')), 'Mail');
      await tester.enterText(
        find.byKey(const ValueKey('vault-origin')),
        'https://mail.example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('vault-identifier')),
        'jose@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('vault-password')),
        _master,
      );
      await tester.tap(find.byKey(const ValueKey('vault-save')));
      await _settle(tester);
      expect(vault.adds, hasLength(1));
      expect(vault.lists, greaterThan(listsBefore));
      expect(find.text(s.vltSaveUnsure), findsOneWidget);
      expect(find.text(s.vltSaveFailed), findsNothing);
    });

    testWidgets('a card the server refuses: one fixed line, no server text', (
      tester,
    ) async {
      final vault = _FakeVault()
        ..addFailure = const VaultFailure(VaultFailureKind.rejected);
      final s = await openAdd(tester, vault);
      await tester.tap(find.byKey(const ValueKey('vault-kind-payment')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('vault-label')), 'Visa');
      await tester.enterText(
        find.byKey(const ValueKey('vault-origin')),
        'https://shop.example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('vault-card-number')),
        '4111 1111 1111 1111',
      );
      await tester.enterText(
        find.byKey(const ValueKey('vault-exp-month')),
        '12',
      );
      await tester.enterText(
        find.byKey(const ValueKey('vault-exp-year')),
        '2030',
      );
      await tester.enterText(find.byKey(const ValueKey('vault-cvc')), _cvc);
      await tester.tap(find.byKey(const ValueKey('vault-save')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('vault-form-error')), findsOneWidget);
      expect(find.text(s.vltSaveFailed), findsOneWidget);
      expect(find.textContaining(_cvc), findsNothing);
    });
  });

  group('nothing typed outlives the app hiding (R5C C-K2)', () {
    testWidgets('the background empties the Add form', (tester) async {
      await _pump(tester, _FakeVault());
      await tester.tap(find.byKey(const ValueKey('vault-add')));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('vault-label')), 'x');
      await tester.enterText(
        find.byKey(const ValueKey('vault-password')),
        _master,
      );
      await tester.pump();

      // Into the background and back, step by step as Android reports it
      // (a jump from paused straight to resumed is not a valid transition).
      const away = [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ];
      const back = [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ];
      for (final state in away) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(_textField(tester, 'vault-password').controller!.text, '');
      expect(_textField(tester, 'vault-label').controller!.text, '');
      for (final state in back) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(_textField(tester, 'vault-password').controller!.text, '');
      expect(_textField(tester, 'vault-label').controller!.text, '');
    });

    testWidgets('App Lock empties the Add form and the master password', (
      tester,
    ) async {
      final locked = ValueNotifier<bool>(false);
      final vault = _FakeVault()..sourcesResult = [_bitwarden];
      await _pump(tester, vault, appLocked: locked);
      await tester.tap(find.byKey(const ValueKey('vault-unlock-bitwarden')));
      await _settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('vault-master-password')),
        _master,
      );
      await tester.pump();

      locked.value = true;
      await tester.pump();
      expect(_textField(tester, 'vault-master-password').controller!.text, '');
      expect(find.textContaining(_master), findsNothing);
      expect(vault.unlocks, isEmpty);
    });
  });

  testWidgets('remove asks first; cancel keeps the item', (tester) async {
    final vault = _FakeVault()..items = [_github];
    final s = await _pump(tester, vault);
    await tester.tap(find.byKey(const ValueKey('vault-remove-vault_a1')));
    await _settle(tester);
    await tester.tap(find.text(s.commonCancel));
    await _settle(tester);
    expect(vault.removed, isEmpty);
    await tester.tap(find.byKey(const ValueKey('vault-remove-vault_a1')));
    await _settle(tester);
    await tester.tap(find.text(s.vltDeleteConfirm));
    await _settle(tester);
    expect(vault.removed, ['vault_a1']);
    expect(find.byKey(const ValueKey('vault-empty')), findsOneWidget);
  });

  group('password managers', () {
    testWidgets('the switch turns a manager off', (tester) async {
      final vault = _FakeVault()..sourcesResult = [_bitwarden];
      await _pump(tester, vault);
      await tester.tap(
        find.byKey(const ValueKey('vault-source-switch-bitwarden')),
      );
      await _settle(tester);
      expect(vault.toggles, [('bitwarden', false)]);
    });

    testWidgets('unlock sends the master password once and clears it', (
      tester,
    ) async {
      final vault = _FakeVault()..sourcesResult = [_bitwarden];
      await _pump(tester, vault);
      await tester.tap(find.byKey(const ValueKey('vault-unlock-bitwarden')));
      await _settle(tester);
      final field = _textField(tester, 'vault-master-password');
      expect(field.obscureText, isTrue);
      expect(field.keyboardType, isNot(TextInputType.visiblePassword));
      expect(field.autofillHints, isNull);
      expect(field.enableIMEPersonalizedLearning, isFalse);
      await tester.enterText(
        find.byKey(const ValueKey('vault-master-password')),
        _master,
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('vault-unlock-submit')));
      await _settle(tester);
      expect(vault.unlocks, [('bitwarden', _master)]);
      expect(find.byKey(const ValueKey('vault-unlock-dialog')), findsNothing);
    });

    testWidgets('a wrong master password: error, field emptied', (
      tester,
    ) async {
      final vault = _FakeVault()
        ..sourcesResult = [_bitwarden]
        ..unlockFailure = const VaultFailure(VaultFailureKind.rejected);
      await _pump(tester, vault);
      await tester.tap(find.byKey(const ValueKey('vault-unlock-bitwarden')));
      await _settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('vault-master-password')),
        _master,
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('vault-unlock-submit')));
      await _settle(tester);
      final s = Strings.of(
        tester.element(find.byKey(const ValueKey('vault-master-password'))),
      );
      expect(find.text(s.vltUnlockFailed), findsOneWidget);
      expect(_textField(tester, 'vault-master-password').controller!.text, '');
      expect(find.textContaining(_master), findsNothing);
    });

    testWidgets('a dropped connection is not the master password', (
      tester,
    ) async {
      // R5C C-K3: a timeout said «check the master password».
      final vault = _FakeVault()
        ..sourcesResult = [_bitwarden]
        ..unlockFailure = const VaultFailure(VaultFailureKind.unavailable);
      final s = await _pump(tester, vault);
      await tester.tap(find.byKey(const ValueKey('vault-unlock-bitwarden')));
      await _settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('vault-master-password')),
        _master,
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('vault-unlock-submit')));
      await _settle(tester);
      expect(find.text(s.vltUnavailable), findsOneWidget);
      expect(find.text(s.vltUnlockFailed), findsNothing);
    });

    testWidgets('an unlocked manager offers Lock', (tester) async {
      final vault = _FakeVault()..sourcesResult = [_bitwarden.copyUnlocked()];
      await _pump(tester, vault);
      await tester.tap(find.byKey(const ValueKey('vault-lock-bitwarden')));
      await _settle(tester);
      expect(vault.locks, ['bitwarden']);
    });
  });

  testWidgets('read-only: the list, nothing that changes it', (tester) async {
    final vault = _FakeVault(readOnly: true)
      ..items = [_github]
      ..sourcesResult = [_bitwarden];
    final s = await _pump(tester, vault);
    expect(find.byKey(const ValueKey('vault-read-only')), findsOneWidget);
    expect(find.text(s.vltReadOnly), findsOneWidget);
    expect(find.byKey(const ValueKey('vault-add')), findsNothing);
    expect(
      find.byKey(const ValueKey('vault-remove-vault_a1')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('vault-unlock-bitwarden')), findsNothing);
    final toggle = tester.widget<Switch>(
      find.byKey(const ValueKey('vault-source-switch-bitwarden')),
    );
    expect(toggle.onChanged, isNull);
  });

  testWidgets('leaving the page releases the screenshot block', (
    tester,
  ) async {
    await _pump(tester, _FakeVault());
    expect(_secureEntered, 1);
    expect(_secureReleased, 0);
    await tester.pageBack();
    await _settle(tester);
    expect(_secureReleased, 1);
  });

  for (final (name, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    testWidgets('$name theme at 2x text: no overflow', (tester) async {
      final vault = _FakeVault()
        ..items = [_github, _bitwardenItem]
        ..sourcesResult = [_bitwarden];
      await _pump(tester, vault, theme: theme, textScale: 2);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('vault-add')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('no secret reaches a log line or stored preferences', (
    tester,
  ) async {
    final storageWrites = <String>[];
    const secureChannel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
          storageWrites.add('${call.method} ${call.arguments}');
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureChannel, null),
    );

    final vault = _FakeVault()
      ..sourcesResult = [_bitwarden]
      ..unlockFailure = const VaultFailure(VaultFailureKind.rejected);

    // debugPrint is a foundation debug variable: testWidgets checks it is
    // back to its default when the body ends, BEFORE tear-downs run, so it
    // is restored here in a finally rather than with addTearDown.
    final logged = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logged.add(message);
    };
    try {
      // The capture is live: a line printed now is seen.
      debugPrint(_captureProbe);
      await _pump(tester, vault);
      // A login that is saved and a master password that is refused.
      await tester.tap(find.byKey(const ValueKey('vault-add')));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('vault-label')), 'L');
      await tester.enterText(
        find.byKey(const ValueKey('vault-origin')),
        'https://l.example',
      );
      await tester.enterText(
        find.byKey(const ValueKey('vault-identifier')),
        'me',
      );
      await tester.enterText(
        find.byKey(const ValueKey('vault-password')),
        _password,
      );
      await tester.tap(find.byKey(const ValueKey('vault-save')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('vault-unlock-bitwarden')));
      await _settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('vault-master-password')),
        _master,
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('vault-unlock-submit')));
      await _settle(tester);
      final dialogField = find.byKey(const ValueKey('vault-master-password'));
      final cancel = Strings.of(tester.element(dialogField)).commonCancel;
      await tester.tap(find.text(cancel));
      await _settle(tester);
      await tester.pageBack();
      await _settle(tester);
    } finally {
      debugPrint = original;
    }

    // The capture saw what was printed while it was installed.
    expect(logged, contains(_captureProbe));
    // The secrets did reach the gateway (the canaries exist)…
    expect(vault.secretValues, contains(_password));
    expect(vault.unlocks.single.$2, _master);
    // …and nowhere else.
    final prefs = await SharedPreferences.getInstance();
    final stored = [
      for (final key in prefs.getKeys()) '$key=${prefs.get(key)}',
    ];
    const canaries = [_password, _master];
    // The check itself catches a planted leak, so an empty answer below
    // means "no secret", not "the check never looks".
    expect(
      _leakedLines(['[vault] failed for $_master'], canaries),
      isNotEmpty,
    );
    expect(
      _leakedLines([...logged, ...stored, ...storageWrites], canaries),
      isEmpty,
    );
    expect(storageWrites, isEmpty);
  });

  group('TuiVaultGateway', () {
    test('only vault methods, and only reads on a read-only connection', () {
      for (final method in ['vault.list', 'vault.sources']) {
        expect(
          TuiGatewayClient.vaultRpcAllowed(method, readOnly: true),
          isTrue,
        );
      }
      for (final method in [
        'vault.add',
        'vault.remove',
        'vault.source.set',
        'vault.unlock',
        'vault.lock',
      ]) {
        expect(
          TuiGatewayClient.vaultRpcAllowed(method, readOnly: false),
          isTrue,
        );
        expect(
          TuiGatewayClient.vaultRpcAllowed(method, readOnly: true),
          isFalse,
        );
      }
      expect(
        TuiGatewayClient.vaultRpcAllowed('vault.get', readOnly: false),
        isFalse,
      );
      // A refusal of a call that carries a secret keeps only its code.
      expect(
        SanitizedRpcFailureFactory.sensitiveMethods,
        contains('vault.add'),
      );
      expect(
        SanitizedRpcFailureFactory.sensitiveMethods,
        contains('vault.unlock'),
      );
    });

    test('scopes to the profile and sends the payload as data', () async {
      final client = _RecordingClient(_connection);
      addTearDown(client.close);
      final named = TuiVaultGateway(client, profile: 'work', readOnly: false);
      await named.add(
        kind: VaultKind.login,
        label: 'GitHub',
        origin: 'https://github.com',
        secret: const {'password': _password},
      );
      expect(client.calls.single.$1, 'vault.add');
      expect(client.calls.single.$2['profile'], 'work');
      expect(client.calls.single.$2['secret'], {'password': _password});

      final primary = TuiVaultGateway(
        client,
        profile: 'default',
        readOnly: false,
      );
      await primary.list();
      expect(client.calls.last.$2.containsKey('profile'), isFalse);
    });

    test('errors keep the kind, never the server text', () async {
      final client = _RecordingClient(_connection);
      addTearDown(client.close);
      final gateway = TuiVaultGateway(
        client,
        profile: 'default',
        readOnly: false,
      );
      Future<VaultFailureKind> kindOf(TuiGatewayRpcError error) async {
        client.error = error;
        try {
          await gateway.unlock('bitwarden', _master);
        } on VaultFailure catch (failure) {
          expect(failure.toString(), isNot(contains(_master)));
          return failure.kind;
        }
        fail('expected a VaultFailure');
      }

      expect(
        await kindOf(
          const TuiGatewayRpcError('vault.unlock', 'nope', code: -32601),
        ),
        VaultFailureKind.unsupported,
      );
      expect(
        await kindOf(
          const TuiGatewayRpcError(
            'vault.unlock',
            'bad master password $_master',
            code: 5095,
          ),
        ),
        VaultFailureKind.rejected,
      );
      expect(
        await kindOf(
          const TuiGatewayRpcError(
            'vault.unlock',
            'Timeout',
            failureKind: TuiGatewayRpcFailureKind.timeout,
          ),
        ),
        VaultFailureKind.unavailable,
      );
    });

    test('a read-only gateway refuses a change without calling', () async {
      final client = _RecordingClient(_connection);
      addTearDown(client.close);
      final gateway = TuiVaultGateway(
        client,
        profile: 'default',
        readOnly: true,
      );
      await expectLater(
        gateway.remove('vault_a1'),
        throwsA(
          isA<VaultFailure>().having(
            (f) => f.kind,
            'kind',
            VaultFailureKind.readOnly,
          ),
        ),
      );
      expect(client.calls, isEmpty);
    });
  });

  group('form rules', () {
    test('origins are http(s) with a host', () {
      expect(isValidVaultOrigin('https://github.com'), isTrue);
      expect(isValidVaultOrigin('http://192.168.1.2:8080'), isTrue);
      expect(isValidVaultOrigin('github.com'), isFalse);
      expect(isValidVaultOrigin('ftp://x.example'), isFalse);
      expect(isValidVaultOrigin(''), isFalse);
    });

    test('authenticator keys follow the server', () {
      expect(isValidVaultOtp(''), isTrue);
      expect(isValidVaultOtp('JBSW Y3DP EHPK 3PXP'), isTrue);
      expect(isValidVaultOtp('jbswy3dpehpk3pxp'), isTrue);
      expect(
        isValidVaultOtp('otpauth://totp/GitHub:me?secret=JBSWY3DPEHPK3PXP'),
        isTrue,
      );
      expect(isValidVaultOtp('otpauth://hotp/x?secret=ABC'), isFalse);
      expect(isValidVaultOtp('not-base32!'), isFalse);
      expect(isValidVaultOtp('1890'), isFalse);
    });
  });
}

extension on VaultSource {
  VaultSource copyUnlocked() => VaultSource(
    name: name,
    displayName: displayName,
    enabled: enabled,
    needsUnlock: needsUnlock,
    unlocked: true,
    installed: installed,
  );
}

class _RecordingClient extends TuiGatewayClient {
  _RecordingClient(super.connection);

  final calls = <(String, Map<String, dynamic>)>[];
  TuiGatewayRpcError? error;

  @override
  Future<Map<String, dynamic>> vaultRequest(
    String method,
    Map<String, dynamic> params,
  ) async {
    final failure = error;
    if (failure != null) throw failure;
    calls.add((method, params));
    return method == 'vault.list'
        ? <String, dynamic>{'items': <Object>[]}
        : <String, dynamic>{};
  }
}
