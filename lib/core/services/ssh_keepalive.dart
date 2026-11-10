// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
//
// Keepalive con plazo para los clientes SSH (M2). El de dartssh2 manda un
// `keepalive@openssh.com` y espera la respuesta SIN plazo: con un enlace
// medio abierto (NAT caducado, Wi-Fi sin salida, servidor apagado sin FIN)
// la espera no termina nunca, `done` no se completa y la UI se queda en
// «Conectando…» durante minutos. Aquí cada ping tiene un plazo; si vence,
// el cliente se cierra (una vez) y quien lo usa ve `done` y reconecta.
import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

/// Cada cuánto se comprueba el enlace. El mismo minuto que ya usaba la app
/// (spec 028 U-11: no despertar la radio cada 10 s).
const Duration kSshKeepAliveInterval = Duration(seconds: 60);

/// Cuánto se espera la respuesta antes de dar el enlace por muerto.
const Duration kSshKeepAliveTimeout = Duration(seconds: 15);

class SshKeepAliveWatchdog {
  SshKeepAliveWatchdog({
    required this.ping,
    required this.onDead,
    this.interval = kSshKeepAliveInterval,
    this.timeout = kSshKeepAliveTimeout,
  });

  final Future<void> Function() ping;
  final void Function() onDead;
  final Duration interval;
  final Duration timeout;

  Timer? _timer;
  bool _inFlight = false;
  bool _dead = false;

  void start() {
    if (_dead || _timer != null) return;
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_inFlight || _dead) return;
    _inFlight = true;
    try {
      await ping().timeout(timeout);
    } on TimeoutException {
      if (_timer == null || _dead) return;
      _dead = true;
      stop();
      onDead();
    } catch (_) {
      // El enlace ya se está cerrando: `done` lo dirá; no es un plazo vencido.
    } finally {
      _inFlight = false;
    }
  }
}

/// Vigila [client] desde que se autentica hasta que termina. Se usa en lugar
/// del keepalive de dartssh2 (`keepAliveInterval: null`).
void watchSshKeepAlive(SSHClient client) {
  final dog = SshKeepAliveWatchdog(ping: client.ping, onDead: client.close);
  client.authenticated.then((_) {
    if (!client.isClosed) dog.start();
  }, onError: (Object _) {});
  client.done.then((_) {}, onError: (Object _) {}).whenComplete(dog.stop);
}
