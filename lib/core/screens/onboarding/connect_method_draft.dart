// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../services/dashboard_address.dart' show isTailscaleAddress;
import '../../services/ssh_manager.dart' show SshAuthMethod;

/// How the person proves who they are to the Dashboard.
enum ConnectMethod { password, browser, token }

/// Where the connection goes: straight to the address, or through SSH.
enum ConnectRoute { direct, ssh }

/// The connection entries. SSH remains available for callers opening its
/// route directly and for orienting a draft; it has no separate method card.
enum ConnectWay { nous, manual, ssh, scan }

/// What the person typed on the Connect form, kept by whoever shows the
/// choice of ways so that leaving one door and opening another loses nothing.
///
/// Secrets live here only while the screen that owns the draft is open; the
/// form clears them on success and the owner disposes them with the screen.
class ConnectDraft {
  ConnectDraft();

  final address = TextEditingController();
  final name = TextEditingController();
  final user = TextEditingController();
  final pass = TextEditingController();
  final token = TextEditingController();
  final sshHost = TextEditingController();
  final sshUser = TextEditingController();
  final sshPort = TextEditingController(text: '22');
  final sshSecret = TextEditingController();
  final sshPassphrase = TextEditingController();
  final dashHost = TextEditingController(text: '127.0.0.1');
  final dashPort = TextEditingController(text: '9119');

  ConnectRoute route = ConnectRoute.direct;
  ConnectMethod method = ConnectMethod.password;
  SshAuthMethod sshAuth = SshAuthMethod.password;
  bool remember = false;
  bool sshRemember = false;

  /// Turns the draft towards one door without touching what was typed.
  void orient(ConnectWay way) {
    switch (way) {
      case ConnectWay.nous:
        route = ConnectRoute.direct;
        method = ConnectMethod.browser;
      case ConnectWay.manual:
        route = ConnectRoute.direct;
      case ConnectWay.ssh:
        route = ConnectRoute.ssh;
      case ConnectWay.scan:
        break;
    }
  }

  void dispose() {
    for (final c in [
      address,
      name,
      user,
      pass,
      token,
      sshHost,
      sshUser,
      sshPort,
      sshSecret,
      sshPassphrase,
      dashHost,
      dashPort,
    ]) {
      c.dispose();
    }
  }
}

/// The code / find-my-server door is the recommended connection method.
ConnectWay recommendedConnectWay({
  required bool pairingSeen,
  bool onTailnet = false,
}) => ConnectWay.scan;

/// Whether one of this phone's own network interfaces has a Tailscale
/// address (100.64.0.0/10). Reads the local interface list only: nothing is
/// sent anywhere. Always false under `flutter test`, so the recommendation
/// never depends on the machine the tests run on.
Future<bool> phoneOnTailnet() async {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return false;
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (isTailscaleAddress(address)) return true;
      }
    }
  } catch (_) {
    // No interface list: no signal.
  }
  return false;
}
