// Spec 080 step 8: remaining bubble-scroll details are single-scroll pages.
// Screenshots at 390×844 dark ES when DESIGN_SHOTS_DIR is set.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart';
import 'package:hermes_android/core/screens/memory_screen.dart';

import '../support/design_shots.dart';
import 'detail_single_scroll_contract_test.dart' show nestedVerticalScrollables;

final _log = List.generate(
  120,
  (i) => '2026-09-27 10:${(i % 60).toString().padLeft(2, '0')} bridge: line $i',
).join('\n');

const _diff = '''--- a/MEMORY.md
+++ b/MEMORY.md
@@ -1,6 +1,8 @@
 # Memory
-- Prefers Spanish replies
+- Prefers Spanish replies, English code
+- Uses Pixel 9 Pro for QA
 - Homelab: Proxmox + Tailscale
''';

void main() {
  testWidgets('memory file detail: page with one primary action', (
    tester,
  ) async {
    var opened = 0;
    var edited = 0;
    await pumpDesignScreen(
      tester,
      MemoryFileDetailPage(
        name: 'MEMORY',
        bytes: 5320,
        hasDraft: true,
        onOpenDraft: () => opened++,
        onEditEntries: () => edited++,
      ),
    );
    expect(nestedVerticalScrollables(tester), isEmpty);
    expect(find.text('Editar entradas'), findsOneWidget);
    expect(find.text('Abrir borrador local'), findsOneWidget);
    await saveDesignShot(tester, 'memory_file_detail');
    await tester.tap(find.byKey(const ValueKey('memory-file-edit-entries')));
    expect(edited, 1);
    await tester.tap(find.byKey(const ValueKey('memory-file-open-draft')));
    expect(opened, 1);
  });

  testWidgets('log page (bridge / gateway / run result): one scroll', (
    tester,
  ) async {
    await pumpDesignScreen(
      tester,
      HermesLogPage(title: 'Log del bridge', text: _log),
    );
    expect(nestedVerticalScrollables(tester), isEmpty);
    await saveDesignShot(tester, 'log_page');
  });

  testWidgets('diff review page: one scroll + pinned decision', (
    tester,
  ) async {
    bool? result;
    await pumpDesignScreen(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async => result = await showHermesReviewPage(
                context: context,
                title: '¿Aplicar a memory?',
                text: _diff,
                confirmLabel: 'Aplicar',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(nestedVerticalScrollables(tester), isEmpty);
    await saveDesignShot(tester, 'diff_review_page');
    await tester.tap(find.byKey(const ValueKey('hermes-review-confirm')));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });
}
