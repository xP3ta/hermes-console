// Adapters from Console's transport clients to the Capabilities repository.
//
// * [DashboardCapabilitiesRest] maps the repository's small REST surface onto
//   `DashboardClient` (auth, cookie rotation and 401 retry stay in one place).
// * [gatewayCapabilitiesRpc] exposes ONLY the hosted-connector family of the
//   gateway through `TuiGatewayClient.capabilitiesRequest`.
//
// A read-only connection never reaches the network with a mutation: every
// POST/PUT/DELETE fails closed with [CapabilityFailureKind.forbidden] before
// any request is built.
import '../services/connection_manager.dart' show DashboardClient;
import '../services/tui_gateway_client.dart';
import 'capabilities_repository.dart';

final class DashboardCapabilitiesRest implements CapabilitiesRest {
  final DashboardClient client;
  final bool readOnly;

  const DashboardCapabilitiesRest(this.client, {this.readOnly = false});

  void _requireWritable() {
    if (readOnly) {
      throw const CapabilityFailure(CapabilityFailureKind.forbidden);
    }
  }

  @override
  Future<Map<String, dynamic>> get(String endpoint) async {
    // `GET /api/skills` answers a bare JSON list.
    if (endpoint.split('?').first == 'skills') {
      return {'data': await client.apiGetList(endpoint)};
    }
    return client.apiGet(endpoint);
  }

  @override
  Future<Map<String, dynamic>> post(
    String endpoint, {
    Map<String, dynamic>? body,
    Duration? timeout,
  }) {
    _requireWritable();
    return timeout == null
        ? client.apiPost(endpoint, body: body)
        : client.apiPost(endpoint, body: body, timeout: timeout);
  }

  @override
  Future<Map<String, dynamic>> put(String endpoint, Map<String, dynamic> body) {
    _requireWritable();
    return client.apiPut(endpoint, body: body);
  }

  @override
  Future<void> delete(String endpoint) {
    _requireWritable();
    return client.apiDelete(endpoint);
  }
}

/// RPC adapter over the gateway. The gateway itself re-checks the allow-list
/// and the read-only flag; the adapter only narrows the type.
CapabilitiesRpc gatewayCapabilitiesRpc(TuiGatewayClient gateway) =>
    gateway.capabilitiesRequest;
