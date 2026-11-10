// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
//
// H4: FLAG_SECURE mientras una pantalla sensible está montada (clave privada
// SSH, terminal, edición de instancia con claves), con independencia de la
// preferencia global. Envuelve la página; no cambia su estado.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/screen_security.dart';

/// Pone FLAG_SECURE y devuelve cómo quitarlo.
typedef SecureScreenAcquire = Future<Future<void> Function()> Function();

Future<Future<void> Function()> _defaultScope() async {
  final prefs = await SharedPreferences.getInstance();
  final lease = await ScreenSecurityService(prefs).pushSecureScope();
  return lease.release;
}

class SecureScreenScope extends StatefulWidget {
  const SecureScreenScope({
    required this.child,
    this.scope = _defaultScope,
    super.key,
  });

  final Widget child;
  final SecureScreenAcquire scope;

  @override
  State<SecureScreenScope> createState() => _SecureScreenScopeState();
}

class _SecureScreenScopeState extends State<SecureScreenScope> {
  Future<void> Function()? _release;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_acquire());
  }

  Future<void> _acquire() async {
    final Future<void> Function() release;
    try {
      release = await widget.scope();
    } catch (_) {
      return; // Best-effort, como ScreenSecurityService.apply.
    }
    if (_disposed) {
      await release();
    } else {
      _release = release;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final release = _release;
    _release = null;
    if (release != null) unawaited(release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
