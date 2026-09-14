import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/command_risk.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late ApprovalPolicyService policy;

  test('capacidades Desktop sólo restringen choices y nunca añaden scopes', () {
    final cases = <(Map<String, dynamic>, Set<String>)>[
      (
        {
          'choices': ['once', 'deny'],
          'allow_session': false,
          'allow_permanent': false,
        },
        {'once', 'deny'},
      ),
      (
        {
          'choices': ['deny'],
          'allow_session': true,
          'allow_permanent': true,
        },
        {'deny'},
      ),
      (
        {
          'choices': ['allow-once', 'allow-session', 'allow-permanent'],
          'allow_permanent': false,
        },
        {'once', 'session'},
      ),
    ];
    for (final entry in cases) {
      expect(permittedApprovalChoices(entry.$1), entry.$2);
    }
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    policy = ApprovalPolicyService(prefs);
  });

  group('valores por defecto seguros', () {
    test('el modo global por defecto es interactive (NUNCA yolo)', () {
      expect(policy.globalMode, ApprovalMode.interactive);
    });

    test('confirmaciones extra activadas por defecto', () {
      expect(policy.confirmAlways, isTrue);
      expect(policy.confirmHighRisk, isTrue);
      expect(policy.requireLock, isTrue);
    });
  });

  group('read-only siempre gana', () {
    test('instancia read-only bloquea incluso en YOLO', () {
      final d = policy.evaluate(
        mode: ApprovalMode.yolo,
        risk: CommandRisk.low,
        readOnlyInstance: true,
      );
      expect(d.kind, ApprovalDecisionKind.blocked);
    });

    test('modo readOnly bloquea aunque no sea instancia read-only', () {
      final d = policy.evaluate(
        mode: ApprovalMode.readOnly,
        risk: CommandRisk.low,
        readOnlyInstance: false,
      );
      expect(d.kind, ApprovalDecisionKind.blocked);
    });
  });

  group('YOLO', () {
    test('auto-aprueba TODOS los riesgos (bajo/medio/alto)', () {
      for (final r in CommandRisk.values) {
        final d = policy.evaluate(
          mode: ApprovalMode.yolo,
          risk: r,
          readOnlyInstance: false,
        );
        expect(d.kind, ApprovalDecisionKind.autoApprove, reason: r.name);
        expect(d.scope, ApprovalScope.once);
      }
    });

    test('riesgo alto se auto-aprueba aunque confirmHighRisk esté activo '
        '(YOLO es opt-in explícito y respeta lo que el usuario eligió)', () {
      expect(policy.confirmHighRisk, isTrue); // default
      final d = policy.evaluate(
        mode: ApprovalMode.yolo,
        risk: CommandRisk.high,
        readOnlyInstance: false,
      );
      expect(d.kind, ApprovalDecisionKind.autoApprove);
    });

    test('Solo lectura sigue ganando sobre YOLO', () {
      final d = policy.evaluate(
        mode: ApprovalMode.yolo,
        risk: CommandRisk.low,
        readOnlyInstance: true,
      );
      expect(d.kind, ApprovalDecisionKind.blocked);
    });
  });

  group('interactive / conservative', () {
    test('interactive pregunta para TODOS los riesgos (no auto-aprueba)', () {
      for (final r in CommandRisk.values) {
        final d = policy.evaluate(
          mode: ApprovalMode.interactive,
          risk: r,
          readOnlyInstance: false,
        );
        expect(d.kind, ApprovalDecisionKind.ask, reason: r.name);
      }
    });

    test('interactive auto-aprueba con regla "always" guardada', () {
      final d = policy.evaluate(
        mode: ApprovalMode.interactive,
        risk: CommandRisk.low,
        readOnlyInstance: false,
        hasSavedAlways: true,
      );
      expect(d.kind, ApprovalDecisionKind.autoApprove);
      expect(d.scope, ApprovalScope.always);
    });

    test('conservative IGNORA reglas always y pregunta siempre', () {
      final d = policy.evaluate(
        mode: ApprovalMode.conservative,
        risk: CommandRisk.low,
        readOnlyInstance: false,
        hasSavedAlways: true,
      );
      expect(d.kind, ApprovalDecisionKind.ask);
    });

    test('conservative exige reconfirmación en riesgo alto', () {
      final d = policy.evaluate(
        mode: ApprovalMode.conservative,
        risk: CommandRisk.high,
        readOnlyInstance: false,
      );
      expect(d.requiresExtraConfirm, isTrue);
    });
  });

  group('modo efectivo por sesión', () {
    test('override de sesión gana sobre el global', () {
      policy.setSessionMode('s1', ApprovalMode.yolo);
      expect(policy.effectiveMode('s1'), ApprovalMode.yolo);
      expect(policy.effectiveMode('s2'), ApprovalMode.interactive);
    });

    test('globalDefault como override = volver al global', () {
      policy.setSessionMode('s1', ApprovalMode.yolo);
      policy.setSessionMode('s1', ApprovalMode.globalDefault);
      expect(policy.effectiveMode('s1'), ApprovalMode.interactive);
    });

    test(
      'el modo de sesión PERSISTE entre reinicios (nueva instancia)',
      () async {
        policy.setSessionMode('s1', ApprovalMode.yolo);
        policy.setSessionMode('s2', ApprovalMode.conservative);
        // Simula reinicio: nueva instancia con los mismos prefs.
        final prefs = await SharedPreferences.getInstance();
        final reloaded = ApprovalPolicyService(prefs);
        expect(reloaded.sessionMode('s1'), ApprovalMode.yolo);
        expect(reloaded.sessionMode('s2'), ApprovalMode.conservative);
        expect(reloaded.effectiveMode('s1'), ApprovalMode.yolo);
      },
    );
  });

  group('reglas always guardadas', () {
    test('guardar y consultar una regla', () async {
      await policy.saveRule(
        ApprovalRule(
          id: 'fs.write',
          description: 'Escribir archivos',
          instanceId: 'inst1',
          scope: ApprovalScope.always,
          risk: CommandRisk.medium,
          createdAt: DateTime.now(),
          patternKey: 'fs.write',
        ),
      );
      expect(policy.hasSavedAlways('inst1', patternKey: 'fs.write'), isTrue);
      expect(policy.hasSavedAlways('inst1', patternKey: 'otro'), isFalse);
      expect(policy.rulesFor('inst1'), hasLength(1));
    });

    test('revocar una regla', () async {
      await policy.saveRule(
        ApprovalRule(
          id: 'fs.write',
          description: 'x',
          instanceId: 'inst1',
          scope: ApprovalScope.always,
          risk: CommandRisk.medium,
          createdAt: DateTime.now(),
          patternKey: 'fs.write',
        ),
      );
      await policy.revokeRule('inst1', 'fs.write');
      expect(policy.rulesFor('inst1'), isEmpty);
    });

    test('si allowAlways=false, hasSavedAlways siempre es false', () async {
      await policy.saveRule(
        ApprovalRule(
          id: 'fs.write',
          description: 'x',
          instanceId: 'inst1',
          scope: ApprovalScope.always,
          risk: CommandRisk.medium,
          createdAt: DateTime.now(),
          patternKey: 'fs.write',
        ),
      );
      await policy.setAllowAlways(false);
      expect(policy.hasSavedAlways('inst1', patternKey: 'fs.write'), isFalse);
    });
  });
}
