import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/mcp_log_filter.dart';

void main() {
  const current =
      "2026-10-04 10:00:00,100 ===== starting MCP server 'files' =====";
  const older = "===== [10:00:05] starting MCP server 'git' =====";

  test('keeps only the sections of the chosen server', () {
    final lines = [
      'orphan line before any banner',
      current,
      'files: ready',
      older,
      'git: cloning',
      "2026-10-04 10:01:00,000 ===== starting MCP server 'files' =====",
      'files: restarted',
    ];
    expect(filterStdioSections(lines, 'files'), [
      current,
      'files: ready',
      "2026-10-04 10:01:00,000 ===== starting MCP server 'files' =====",
      'files: restarted',
    ]);
    expect(filterStdioSections(lines, 'git'), [older, 'git: cloning']);
  });

  test('both banner formats are recognised', () {
    expect(
      filterStdioSections([older, 'a', 'b'], 'git'),
      [older, 'a', 'b'],
    );
    expect(
      filterStdioSections([current, 'x'], 'files'),
      [current, 'x'],
    );
  });

  test('a server with no banner yields nothing, names are exact', () {
    final lines = [current, 'files: ready'];
    expect(filterStdioSections(lines, 'file'), isEmpty);
    expect(filterStdioSections(lines, 'files.*'), isEmpty);
    expect(filterStdioSections(const [], 'files'), isEmpty);
  });
}
