// Tests de RunRecord: serialización JSON con los campos opcionales añadidos en
// Fase 1 (progressLabel, lastEvent, updatedAt) y retrocompatibilidad con
// registros anteriores que no los tienen.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/task_center_screen.dart';
import 'package:hermes_android/core/services/run_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('Task Center ephemeral owner includes normalized profile', () {
    expect(
      taskCenterRunOwnerKey(' Alpha ', 'shared-run'),
      isNot(taskCenterRunOwnerKey('beta', 'shared-run')),
    );
    expect(
      taskCenterRunOwnerKey(' Alpha ', 'shared-run'),
      taskCenterRunOwnerKey('alpha', 'shared-run'),
    );
  });

  group('RunRecord — campos nuevos y JSON', () {
    test('toJson incluye campos opcionales cuando están presentes', () {
      const r = RunRecord(
        runId: 'run-abc',
        prompt: 'haz algo',
        createdAt: 1718000000.0,
        lastStatus: 'running',
        sessionId: 'sess-1',
        output: 'salida',
        progressLabel: 'tool: read_file',
        lastEvent: 'tool.started',
        updatedAt: 1718000010.0,
      );
      final j = r.toJson();
      expect(j['run_id'], 'run-abc');
      expect(j['prompt'], 'haz algo');
      expect(j['session_id'], 'sess-1');
      expect(j['last_status'], 'running');
      expect(j['output'], 'salida');
      expect(j['progress_label'], 'tool: read_file');
      expect(j['last_event'], 'tool.started');
      expect(j['updated_at'], 1718000010.0);
    });

    test('toJson omite campos nulos (sin campos vacíos innecesarios)', () {
      const r = RunRecord(
        runId: 'run-min',
        prompt: 'mínimo',
        createdAt: 1718000000.0,
        lastStatus: 'completed',
      );
      final j = r.toJson();
      expect(j.containsKey('session_id'), isFalse);
      expect(j.containsKey('output'), isFalse);
      expect(j.containsKey('error'), isFalse);
      expect(j.containsKey('progress_label'), isFalse);
      expect(j.containsKey('last_event'), isFalse);
      expect(j.containsKey('updated_at'), isFalse);
    });

    test('fromJson — registro antiguo sin campos nuevos devuelve null', () {
      final json = {
        'run_id': 'run-old',
        'prompt': 'viejo',
        'created_at': 1718000000.0,
        'last_status': 'expired',
      };
      final r = RunRecord.fromJson(json);
      expect(r.runId, 'run-old');
      expect(r.progressLabel, isNull);
      expect(r.lastEvent, isNull);
      expect(r.updatedAt, isNull);
    });

    test('fromJson — registro nuevo con todos los campos opcionales', () {
      final json = {
        'run_id': 'run-new',
        'prompt': 'nuevo',
        'created_at': 1718000000.0,
        'last_status': 'running',
        'progress_label': 'tool: bash',
        'last_event': 'tool.completed',
        'updated_at': 1718000020.0,
      };
      final r = RunRecord.fromJson(json);
      expect(r.progressLabel, 'tool: bash');
      expect(r.lastEvent, 'tool.completed');
      expect(r.updatedAt, 1718000020.0);
    });

    test('profile roundtrip is exact and legacy records default safely', () {
      const owned = RunRecord(
        runId: 'run-owned',
        prompt: 'owned',
        createdAt: 1718000000.0,
        lastStatus: 'running',
        profile: 'room-alpha',
      );

      final restored = RunRecord.fromJson(owned.toJson());
      final legacy = RunRecord.fromJson({
        'run_id': 'run-legacy',
        'prompt': 'legacy',
        'created_at': 1718000000.0,
        'last_status': 'running',
      });

      expect(restored.profile, 'room-alpha');
      expect(restored.copyWith(lastStatus: 'completed').profile, 'room-alpha');
      expect(legacy.profile, 'default');
    });

    test('same run id is updated and removed by exact profile', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final registry = await RunRegistry.load(prefs, 'conn-a');

      for (final profile in ['room-alpha', 'room-beta']) {
        await registry.add(
          RunRecord(
            runId: 'shared-run',
            prompt: profile,
            createdAt: profile == 'room-alpha' ? 1 : 2,
            lastStatus: 'queued',
            connId: 'conn-a',
            profile: profile,
          ),
        );
      }

      expect(registry.records.map((record) => record.profile).toSet(), {
        'room-alpha',
        'room-beta',
      });

      await registry.update(
        'shared-run',
        profile: 'room-alpha',
        lastStatus: 'completed',
      );
      expect(
        registry.records
            .singleWhere((r) => r.profile == 'room-alpha')
            .lastStatus,
        'completed',
      );
      expect(
        registry.records
            .singleWhere((r) => r.profile == 'room-beta')
            .lastStatus,
        'queued',
      );

      await registry.remove('shared-run', profile: 'room-alpha');
      final reopened = await RunRegistry.load(prefs, 'conn-a');
      expect(reopened.records, hasLength(1));
      expect(reopened.records.single.profile, 'room-beta');
    });

    test('fromJson — ida y vuelta preserva todos los campos', () {
      const original = RunRecord(
        runId: 'run-rt',
        prompt: 'round-trip',
        createdAt: 1718000000.0,
        lastStatus: 'completed',
        sessionId: 'sess-rt',
        output: 'ok',
        error: null,
        progressLabel: 'tool: write_file',
        lastEvent: 'run.completed',
        updatedAt: 1718000030.0,
      );
      final restored = RunRecord.fromJson(original.toJson());
      expect(restored.runId, original.runId);
      expect(restored.prompt, original.prompt);
      expect(restored.sessionId, original.sessionId);
      expect(restored.lastStatus, original.lastStatus);
      expect(restored.output, original.output);
      expect(restored.progressLabel, original.progressLabel);
      expect(restored.lastEvent, original.lastEvent);
      expect(restored.updatedAt, original.updatedAt);
    });

    test(
      'copyWith preserva nuevos campos cuando no se pasan explícitamente',
      () {
        const original = RunRecord(
          runId: 'run-cw',
          prompt: 'cp',
          createdAt: 1718000000.0,
          lastStatus: 'running',
          progressLabel: 'tool: read_file',
          lastEvent: 'tool.started',
          updatedAt: 1718000005.0,
        );
        final updated = original.copyWith(lastStatus: 'completed');
        expect(updated.lastStatus, 'completed');
        expect(updated.progressLabel, 'tool: read_file');
        expect(updated.lastEvent, 'tool.started');
        expect(updated.updatedAt, 1718000005.0);
        expect(updated.runId, original.runId);
      },
    );

    test('copyWith puede actualizar solo campos nuevos', () {
      const original = RunRecord(
        runId: 'run-cw2',
        prompt: 'cp2',
        createdAt: 1718000000.0,
        lastStatus: 'running',
      );
      final updated = original.copyWith(
        progressLabel: 'tool: bash',
        lastEvent: 'tool.started',
        updatedAt: 1718000015.0,
      );
      expect(updated.progressLabel, 'tool: bash');
      expect(updated.lastEvent, 'tool.started');
      expect(updated.updatedAt, 1718000015.0);
      expect(updated.lastStatus, 'running');
    });

    test('isTerminal cubre todos los estados esperados', () {
      for (final s in ['completed', 'failed', 'cancelled', 'expired']) {
        final r = RunRecord(
          runId: 'x',
          prompt: 'p',
          createdAt: 0,
          lastStatus: s,
        );
        expect(r.isTerminal, isTrue, reason: '$s debe ser terminal');
      }
      for (final s in [
        'queued',
        'running',
        'waiting_for_approval',
        'stopping',
      ]) {
        final r = RunRecord(
          runId: 'x',
          prompt: 'p',
          createdAt: 0,
          lastStatus: s,
        );
        expect(r.isTerminal, isFalse, reason: '$s no debe ser terminal');
      }
    });
  });
}
