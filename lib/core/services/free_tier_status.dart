import '../models/free_tier_status.dart';
import 'tui_gateway_client.dart';

final class FreeTierStatusReader {
  final HermesDesktopFreeTierGateway gateway;
  final String profile;

  const FreeTierStatusReader({required this.gateway, required this.profile});

  Future<FreeTierStatus?> load() async {
    try {
      return await gateway.freeTierStatus(profile: profile);
    } on TuiGatewayRpcError catch (error) {
      if (error.code == -32601) return null;
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<FreeTierStatus?> acknowledgeAndReload() async {
    try {
      await gateway.ackFreeTierNotice(profile: profile);
      return await gateway.freeTierStatus(profile: profile);
    } catch (_) {
      return null;
    }
  }
}
