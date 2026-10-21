// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../utils/transport_privacy.dart';
import 'simple_connect/hermes_server_status.dart';

/// How the phone reaches the typed address.
enum DiscoveryRoute { tailscale, typed }

/// The Dashboard address the owner typed, as host, port and scheme.
class DiscoveryTarget {
  const DiscoveryTarget(
    this.host,
    this.port,
    this.route, {
    this.secure = false,
  });
  final String host;
  final int port;
  final DiscoveryRoute route;

  /// https instead of http; plain http otherwise.
  final bool secure;

  String get url =>
      Uri(scheme: secure ? 'https' : 'http', host: host, port: port).toString();

  /// Plain http to a host outside the networks the owner controls. Nothing
  /// is ever sent there: the status request and a later sign-in would cross
  /// the internet in the clear.
  bool get publicCleartext =>
      TransportPrivacy.classify(url) == TransportPrivacyClass.publicCleartext;

  @override
  bool operator ==(Object other) =>
      other is DiscoveryTarget &&
      other.host == host &&
      other.port == port &&
      other.secure == secure;

  @override
  int get hashCode => Object.hash(host, port, secure);

  @override
  String toString() => '$host:$port';
}

typedef StatusProbe = Future<HermesServerStatus?> Function(DiscoveryTarget);

/// Tailscale's 100.64.0.0/10 range (carrier-grade NAT, which on Android is
/// Tailscale or the mobile carrier).
bool isTailscaleAddress(InternetAddress a) {
  if (a.type != InternetAddressType.IPv4) return false;
  final b = a.rawAddress;
  return b[0] == 100 && b[1] >= 64 && b[1] <= 127;
}

/// `host`, `host:port`, `http://…` or `https://…`; the Dashboard's own
/// port (9119) unless the owner typed another or chose https.
DiscoveryTarget? parseDashboardAddress(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'http://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) return null;
  final secure = uri.scheme == 'https';
  final ip = InternetAddress.tryParse(uri.host);
  final tailscale =
      ip != null && isTailscaleAddress(ip) || uri.host.endsWith('.ts.net');
  return DiscoveryTarget(
    uri.host,
    uri.hasPort ? uri.port : (secure ? 443 : 9119),
    tailscale ? DiscoveryRoute.tailscale : DiscoveryRoute.typed,
    secure: secure,
  );
}

/// A TCP connect gate, then one bounded `GET /api/status` without redirects.
Future<HermesServerStatus?> defaultStatusProbe(
  DiscoveryTarget t, {
  Duration connect = const Duration(milliseconds: 700),
  Duration read = const Duration(milliseconds: 2500),
}) async {
  if (await tcpConnect(t.host, t.port, connect) != TcpOutcome.open) {
    return null;
  }
  final client = http.Client();
  try {
    final req = http.Request(
      'GET',
      Uri(
        scheme: t.secure ? 'https' : 'http',
        host: t.host,
        port: t.port,
        path: '/api/status',
      ),
    )..followRedirects = false;
    final res = await client
        .send(req)
        .then(http.Response.fromStream)
        .timeout(read);
    if (res.statusCode != 200) return null;
    return HermesServerStatus.tryParse(jsonDecode(res.body));
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

/// Where a typed address stands, from the phone's side only.
enum HostVerdict {
  /// Hermes answered `/api/status`.
  hermes,

  /// The computer answers, nothing Hermes listens on the Dashboard port:
  /// the Dashboard is not running (or runs on another port / only locally).
  notListening,

  /// The computer answers on other ports, the Dashboard port stays silent:
  /// a firewall drops it.
  blocked,

  /// Nothing answers at all: off, asleep, another network or a wrong
  /// address.
  silent,

  /// Plain http to a public address. Refused before any packet is sent.
  publicCleartext,
}

class HostProbeResult {
  const HostProbeResult(this.verdict, [this.status]);
  final HostVerdict verdict;
  final HermesServerStatus? status;
}

/// Classifies one typed address without sending anything but TCP connects
/// and the public status request.
Future<HostProbeResult> probeHost(
  DiscoveryTarget t, {
  StatusProbe? status,
  Future<TcpOutcome> Function(String host, int port, Duration timeout)? tcp,
}) async {
  if (t.publicCleartext) {
    return const HostProbeResult(HostVerdict.publicCleartext);
  }
  final connect = tcp ?? tcpConnect;
  final dashboard = await connect(t.host, t.port, const Duration(seconds: 4));
  if (dashboard == TcpOutcome.open) {
    final s =
        await (status ??
            (x) => defaultStatusProbe(
              x,
              connect: const Duration(seconds: 4),
              read: const Duration(seconds: 6),
            ))(t);
    return s == null
        ? const HostProbeResult(HostVerdict.notListening)
        : HostProbeResult(HostVerdict.hermes, s);
  }
  if (dashboard == TcpOutcome.refused) {
    return const HostProbeResult(HostVerdict.notListening);
  }
  // Silent on the Dashboard port: does the computer answer anything? SSH,
  // SMB, RDP and HTTP cover Linux, macOS and Windows. A refusal counts: only
  // a machine that is up refuses.
  final others = await Future.wait([
    for (final p in const [22, 445, 3389, 80])
      connect(t.host, p, const Duration(milliseconds: 1500)),
  ]);
  return others.any((r) => r != TcpOutcome.silent)
      ? const HostProbeResult(HostVerdict.blocked)
      : const HostProbeResult(HostVerdict.silent);
}

/// One TCP connect attempt, as the network answered it.
enum TcpOutcome { open, refused, silent }

Future<TcpOutcome> tcpConnect(String host, int port, Duration timeout) async {
  try {
    final s = await Socket.connect(host, port, timeout: timeout);
    s.destroy();
    return TcpOutcome.open;
  } on SocketException catch (e) {
    final code = e.osError?.errorCode;
    // ECONNREFUSED: 111 (Linux/Android), 61 (Darwin), 10061 (Windows).
    return code == 111 || code == 61 || code == 10061
        ? TcpOutcome.refused
        : TcpOutcome.silent;
  } catch (_) {
    return TcpOutcome.silent;
  }
}
