// Splits the shared MCP stderr log (`mcp-stderr.log`) into the part that
// belongs to one server. Every stdio subprocess writes a banner when it
// starts; the lines after it belong to that server until the next banner.
//
// Same marker as Hermes Desktop's `filterStdioSections`: the current banner
// is `<asctime> ===== starting …`, the older one `===== [<time>] starting …`.
final RegExp _stdioMarker = RegExp(
  r"^(?:\d{4}-\d{2}-\d{2} [\d:,]+ )?===== (?:\[.*\] )?starting MCP server '(.+)' =====$",
);

List<String> filterStdioSections(List<String> lines, String server) {
  final out = <String>[];
  var inSection = false;
  for (final line in lines) {
    final marker = _stdioMarker.firstMatch(line);
    if (marker != null) inSection = marker.group(1) == server;
    if (inSection) out.add(line);
  }
  return out;
}
