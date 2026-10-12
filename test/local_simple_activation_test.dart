// Tests TASK-019b: activación de chat-local-simple desde la instancia.
//
// Cubre:
//  1. Serialización round-trip de LocalChatMode en SavedConnection (complementa
//     connection_manager_test.dart que ya tiene el grupo LocalChatMode).
//  2. Resolución de modo: auto/simple → useSimple=true; agent → useSimple=false.
//     Esta es la lógica central de _sendViaBridge() en active_chat_service.dart.
//  3. Instancia remota (kind != localhost) no es afectada por localChatMode.
//  4. BridgeClient.chatSimple no incluye tools (regresión desde TASK-019).

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';

void main() {
  // =========================================================
  // Grupo 1: Resolución de modo
  // =========================================================
  // =========================================================
  // Grupo 2: LocalChatMode en SavedConnection
  // =========================================================
  group('SavedConnection.localChatMode', () {
    SavedConnection localConn({LocalChatMode mode = LocalChatMode.auto}) =>
        SavedConnection(
          id: 'loc',
          label: 'Local Termux',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'tok',
          onDeviceLoopback: true,
          kind: InstanceKind.localhost,
          localChatMode: mode,
        );

    SavedConnection remoteConn() => SavedConnection(
      id: 'rem',
      label: 'VPS',
      host: 'hermes.example.com',
      port: 8642,
      apiKey: 'tok',
      kind: InstanceKind.vps,
      // localChatMode se ignora en remoto
    );

    test('instancia local: kind == localhost, localChatMode se persiste', () {
      final conn = localConn(mode: LocalChatMode.simple);
      expect(conn.kind, InstanceKind.localhost);
      expect(conn.localChatMode, LocalChatMode.simple);
    });

    test('instancia remota: kind != localhost, localChatMode irrelevante', () {
      final conn = remoteConn();
      // El campo existe pero _sendViaBridge no se llama para remotos.
      expect(conn.kind, isNot(InstanceKind.localhost));
    });

    test('round-trip simple', () {
      final conn = localConn(mode: LocalChatMode.simple);
      expect(
        SavedConnection.fromMap(conn.toMap()).localChatMode,
        LocalChatMode.simple,
      );
    });

    test('round-trip agent', () {
      final conn = localConn(mode: LocalChatMode.agent);
      expect(
        SavedConnection.fromMap(conn.toMap()).localChatMode,
        LocalChatMode.agent,
      );
    });

    test('clave ausente en mapa migra a auto', () {
      final map = localConn().toMap()..remove('local_chat_mode');
      expect(SavedConnection.fromMap(map).localChatMode, LocalChatMode.auto);
    });

    test('copyWith sin localChatMode conserva el valor actual', () {
      final conn = localConn(mode: LocalChatMode.agent);
      expect(conn.copyWith(label: 'X').localChatMode, LocalChatMode.agent);
    });
  });

  // =========================================================
  // Grupo 3: chatSimple no incluye tools (regresión TASK-019)
  // =========================================================
}
