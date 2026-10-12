import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';

void main() {
  group('suggestInstanceKind', () {
    const table = <String, InstanceKind>{
      // Home: private LAN ranges, mDNS and local names.
      '192.168.1.20': InstanceKind.homelab,
      '10.0.0.5': InstanceKind.homelab,
      '172.16.0.1': InstanceKind.homelab,
      '172.31.255.254': InstanceKind.homelab,
      '169.254.10.10': InstanceKind.homelab,
      'nas.local': InstanceKind.homelab,
      'NAS.LOCAL.': InstanceKind.homelab,
      'hermes.lan': InstanceKind.homelab,
      'box.home.arpa': InstanceKind.homelab,
      'nas': InstanceKind.homelab,
      'fd12:3456:789a::1': InstanceKind.homelab,
      '[fe80::1]': InstanceKind.homelab,
      // Private network: Tailscale names and the CGNAT range.
      'host.tail1234.ts.net': InstanceKind.tailscale,
      '100.64.0.1': InstanceKind.tailscale,
      '100.100.100.100': InstanceKind.tailscale,
      '100.127.255.255': InstanceKind.tailscale,
      'fd7a:115c:a1e0::1': InstanceKind.tailscale,
      // Server: public addresses and dotted hostnames.
      '203.0.113.9': InstanceKind.vps,
      '8.8.8.8': InstanceKind.vps,
      '100.63.0.1': InstanceKind.vps,
      '100.128.0.1': InstanceKind.vps,
      '172.15.0.1': InstanceKind.vps,
      '172.32.0.1': InstanceKind.vps,
      '192.169.0.1': InstanceKind.vps,
      'hermes.example.com': InstanceKind.vps,
      '2001:db8::1': InstanceKind.vps,
      '': InstanceKind.vps,
      // This computer: loopback and the emulator's alias of the host.
      'localhost': InstanceKind.pc,
      'LOCALHOST': InstanceKind.pc,
      '127.0.0.1': InstanceKind.pc,
      '127.1.2.3': InstanceKind.pc,
      '::1': InstanceKind.pc,
      '[::1]': InstanceKind.pc,
      '10.0.2.2': InstanceKind.pc,
    };
    for (final entry in table.entries) {
      test('"${entry.key}" -> ${entry.value.name}', () {
        expect(suggestInstanceKind(entry.key), entry.value);
      });
    }

    test('never answers the retired on-device kind', () {
      for (final host in table.keys) {
        expect(suggestInstanceKind(host), isNot(InstanceKind.localhost));
      }
    });

    test('only offers kinds that exist and not the on-device one', () {
      expect(kOfferedInstanceKinds, isNot(contains(InstanceKind.localhost)));
      expect(kOfferedInstanceKinds.toSet(), {
        InstanceKind.homelab,
        InstanceKind.vps,
        InstanceKind.tailscale,
        InstanceKind.pc,
      });
    });
  });
}
