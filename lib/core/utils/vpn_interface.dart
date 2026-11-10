import 'dart:io';

/// Whether a Tailscale tunnel is up: a VPN/tunnel interface (Tailscale's
/// `tun*`/`tailscale*`, WireGuard's `wg*`, `ppp*`) that holds an IPv4 address
/// in Tailscale's 100.64.0.0/10. Any other VPN (a work VPN on `tun0` with a
/// 10.x address) does not make a 100.x host reachable through WireGuard, so
/// it does not count. Used only to decide if a Tailscale address can be
/// trusted for a background read; never throws.
Future<bool> vpnInterfaceActive({
  @pragma('vm:visible-for-testing')
  Future<List<({String name, List<String> ipv4})>> Function()? interfaces,
}) async {
  try {
    final list = await (interfaces ?? _interfaces)();
    return list.any((i) {
      final name = i.name.toLowerCase();
      final tunnel =
          name.startsWith('tun') ||
          name.startsWith('tailscale') ||
          name.startsWith('wg') ||
          name.startsWith('ppp');
      return tunnel && i.ipv4.any(_inTailscaleRange);
    });
  } on Object {
    return false;
  }
}

bool _inTailscaleRange(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  return a == 100 && b != null && b >= 64 && b <= 127;
}

Future<List<({String name, List<String> ipv4})>> _interfaces() async => [
  for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4))
    (name: i.name, ipv4: [for (final a in i.addresses) a.address]),
];
