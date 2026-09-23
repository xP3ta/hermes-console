const clientCapabilitiesMethod = 'client.capabilities';

bool isClientCapabilitiesFrame(Map<String, dynamic> frame) =>
    frame['method'] == clientCapabilitiesMethod;

List<Map<String, dynamic>> framesWithoutClientCapabilities(
  Iterable<Map<String, dynamic>> frames,
) => frames.where((frame) => !isClientCapabilitiesFrame(frame)).toList();

Map<String, dynamic> clientCapabilitiesResponse(Map<String, dynamic> frame) => {
  'jsonrpc': '2.0',
  'id': frame['id'],
  'result': <String, dynamic>{},
};
