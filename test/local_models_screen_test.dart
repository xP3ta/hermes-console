import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/local_models_screen.dart';
import 'package:hermes_android/core/services/local_models_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/fake_local_models_server.dart';
import 'support/provider_logo_probe.dart';

/// lm1215: Server local models screen. Every write must hit the exact
/// Desktop route (`apps/desktop/src/api/local-models.ts`) with its body.
Future<void> _settle(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _readOnly(WidgetTester tester) =>
    Strings.of(tester.element(find.byType(LocalModelsScreen))).readOnlyNotice;

Future<void> _openMenu(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('lm1215-model-menu-$id')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists installed models with size, quant, state and default', (
    tester,
  ) async {
    final server = FakeLocalModelsServer();
    await pumpLocalModels(tester, server);

    expect(find.text('Qwen3-8B-Q4_K_M'), findsOneWidget);
    expect(find.text('5.0 GB · Q4_K_M · En memoria'), findsOneWidget);
    expect(find.text('gemma-3-4b-it-UD-Q8_K_XL'), findsOneWidget);
    expect(find.text('4.0 GB · UD-Q8_K_XL · En disco'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('lm1215-active-Qwen3-8B-Q4_K_M')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('lm1215-active-gemma-3-4b-it-UD-Q8_K_XL')),
      findsNothing,
    );
    expect(find.text('Servidor encendido'), findsOneWidget);
    expect(find.text('llama.cpp b6500 · cuda'), findsOneWidget);
    // Catalog: the oversized entry cannot be downloaded.
    expect(find.text('Qwen3 14B'), findsOneWidget);
    expect(find.text('No cabe en el servidor'), findsOneWidget);
    expect(server.writes(), isEmpty);
  });

  testWidgets('installed models show their maker logo, tinted', (tester) async {
    final server = FakeLocalModelsServer();
    await pumpLocalModels(tester, server);

    final active = find.byKey(
      const ValueKey('provider-logo-local-Qwen3-8B-Q4_K_M'),
    );
    final colors = Theme.of(tester.element(active)).hermes;
    expect(providerLogoId(tester, active), 'alibaba');
    expect(providerLogoTint(tester, active), colors.accent);
    final other = find.byKey(
      const ValueKey('provider-logo-local-gemma-3-4b-it-UD-Q8_K_XL'),
    );
    expect(providerLogoId(tester, other), 'google');
    expect(providerLogoTint(tester, other), colors.textSecondary);
  });

  testWidgets('404 on status shows the honest unavailable copy, no writes', (
    tester,
  ) async {
    final server = FakeLocalModelsServer(routesPresent: false);
    await pumpLocalModels(tester, server);
    expect(
      find.text(
        'Tu Hermes no tiene modelos locales activados (modo local de Desktop)',
      ),
      findsOneWidget,
    );
    expect(find.text('Qwen3-8B-Q4_K_M'), findsNothing);
    expect(server.calls.map((c) => c.path), ['/api/local-models/status']);
  });

  testWidgets('a 500 on status shows an error with retry that recovers', (
    tester,
  ) async {
    final server = FakeLocalModelsServer();
    server.failures['GET /api/local-models/status'] = (500, 'boom');
    await pumpLocalModels(tester, server);
    expect(
      find.text('No se pudieron leer los modelos locales'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('lm1215-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Qwen3-8B-Q4_K_M'), findsOneWidget);
  });

  testWidgets('activate posts model_id with ?profile= and polls the job', (
    tester,
  ) async {
    final server = FakeLocalModelsServer();
    await pumpLocalModels(tester, server, profile: 'research');
    await _openMenu(tester, 'gemma-3-4b-it-UD-Q8_K_XL');
    await tester.tap(find.byKey(const ValueKey('lm1215-action-use')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final post = server.writes().single;
    expect(post.method, 'POST');
    expect(post.path, '/api/local-models/activate');
    expect(post.query, 'profile=research');
    expect(post.body, {'model_id': 'gemma-3-4b-it-UD-Q8_K_XL'});
    expect(find.text('4.0 GB · UD-Q8_K_XL · Activando…'), findsOneWidget);

    server.finishJob(server.jobs.first['job_id'] as String);
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('lm1215-active-gemma-3-4b-it-UD-Q8_K_XL')),
      findsOneWidget,
    );
    expect(
      find.text('Los chats nuevos usarán gemma-3-4b-it-UD-Q8_K_XL'),
      findsOneWidget,
    );
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('the default model has no "use" action', (tester) async {
    final server = FakeLocalModelsServer();
    await pumpLocalModels(tester, server);
    await _openMenu(tester, 'Qwen3-8B-Q4_K_M');
    expect(find.byKey(const ValueKey('lm1215-action-use')), findsNothing);
    expect(find.byKey(const ValueKey('lm1215-action-eject')), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await _openMenu(tester, 'gemma-3-4b-it-UD-Q8_K_XL');
    // Not in memory: nothing to eject.
    expect(find.byKey(const ValueKey('lm1215-action-eject')), findsNothing);
  });

  testWidgets('activate error shows the server detail', (tester) async {
    final server = FakeLocalModelsServer();
    server.failures['POST /api/local-models/activate'] = (
      404,
      'gemma is not downloaded',
    );
    await pumpLocalModels(tester, server);
    await _openMenu(tester, 'gemma-3-4b-it-UD-Q8_K_XL');
    await tester.tap(find.byKey(const ValueKey('lm1215-action-use')));
    await tester.pumpAndSettle();
    expect(
      find.text('No se pudo completar: gemma is not downloaded'),
      findsOneWidget,
    );
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('eject posts model_id and refreshes residency', (tester) async {
    final server = FakeLocalModelsServer();
    await pumpLocalModels(tester, server);
    await _openMenu(tester, 'Qwen3-8B-Q4_K_M');
    await tester.tap(find.byKey(const ValueKey('lm1215-action-eject')));
    await tester.pumpAndSettle();
    final post = server.writes().single;
    expect(post.path, '/api/local-models/eject');
    expect(post.body, {'model_id': 'Qwen3-8B-Q4_K_M'});
    expect(find.text('5.0 GB · Q4_K_M · En disco'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('eject failure (409 server down) is reported', (tester) async {
    final server = FakeLocalModelsServer();
    server.failures['POST /api/local-models/eject'] = (
      409,
      'local server is not running',
    );
    await pumpLocalModels(tester, server);
    await _openMenu(tester, 'Qwen3-8B-Q4_K_M');
    await tester.tap(find.byKey(const ValueKey('lm1215-action-eject')));
    await tester.pumpAndSettle();
    expect(
      find.text('No se pudo completar: local server is not running'),
      findsOneWidget,
    );
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('delete asks first; cancel sends nothing', (tester) async {
    final server = FakeLocalModelsServer();
    await pumpLocalModels(tester, server);
    await _openMenu(tester, 'gemma-3-4b-it-UD-Q8_K_XL');
    await tester.tap(find.byKey(const ValueKey('lm1215-action-delete')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lm1215-delete-dialog')), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(server.writes(), isEmpty);
    expect(find.text('gemma-3-4b-it-UD-Q8_K_XL'), findsOneWidget);
  });

  testWidgets('confirmed delete sends DELETE with the encoded id', (
    tester,
  ) async {
    final server = FakeLocalModelsServer();
    await pumpLocalModels(tester, server);
    await _openMenu(tester, 'Qwen3-8B-Q4_K_M');
    await tester.tap(find.byKey(const ValueKey('lm1215-action-delete')));
    await tester.pumpAndSettle();
    // Deleting the default warns about it.
    expect(find.textContaining('Es el modelo predeterminado'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lm1215-delete-confirm')));
    await tester.pumpAndSettle();
    final call = server.writes().single;
    expect(call.method, 'DELETE');
    expect(call.path, '/api/local-models/models/Qwen3-8B-Q4_K_M');
    expect(find.text('Qwen3-8B-Q4_K_M'), findsNothing);
    expect(find.text('Qwen3-8B-Q4_K_M eliminado'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('delete 404 keeps the row and reports it', (tester) async {
    final server = FakeLocalModelsServer();
    server.failures['DELETE /api/local-models/models/gemma-3-4b-it-UD-Q8_K_XL'] =
        (404, 'model not found');
    await pumpLocalModels(tester, server);
    await _openMenu(tester, 'gemma-3-4b-it-UD-Q8_K_XL');
    await tester.tap(find.byKey(const ValueKey('lm1215-action-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('lm1215-delete-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('No se pudo completar: model not found'), findsOneWidget);
    expect(find.text('gemma-3-4b-it-UD-Q8_K_XL'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('catalog download shows progress, pauses, resumes, finishes', (
    tester,
  ) async {
    final server = FakeLocalModelsServer();
    await pumpLocalModels(tester, server);
    await tester.tap(find.byKey(const ValueKey('lm1215-catalog-qwen3-14b')));
    await _settle(tester, 2);
    final post = server.writes().single;
    expect(post.path, '/api/local-models/download');
    expect(post.body, {'model_id': 'qwen3-14b'});
    final jobId = server.jobs.first['job_id'] as String;
    expect(find.byKey(ValueKey('lm1215-job-$jobId')), findsOneWidget);
    expect(find.text('25 % · 250 B de 1000 B'), findsOneWidget);

    // Progress advances through polling.
    server.jobs.first
      ..['done_bytes'] = 750
      ..['percent'] = 75;
    await _settle(tester, 3);
    expect(find.text('75 % · 750 B de 1000 B'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('lm1215-job-pause-$jobId')));
    await _settle(tester, 2);
    expect(server.writes().last.path, '/api/local-models/download/pause');
    expect(server.writes().last.body, {'job_id': jobId});
    expect(find.text('En pausa'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('lm1215-job-resume-$jobId')));
    await _settle(tester, 2);
    expect(server.writes().last.path, '/api/local-models/download/resume');
    expect(server.writes().last.body, {'job_id': jobId});

    server.finishJob(jobId);
    await _settle(tester, 4);
    expect(find.byKey(ValueKey('lm1215-job-$jobId')), findsNothing);
    expect(find.text('Qwen3 14B (Q4_K_M): listo'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('a failed download job reports its error', (tester) async {
    final server = FakeLocalModelsServer();
    await pumpLocalModels(tester, server);
    await tester.tap(find.byKey(const ValueKey('lm1215-catalog-qwen3-14b')));
    await _settle(tester, 2);
    server.finishJob(server.jobs.first['job_id'] as String, error: 'disk full');
    await _settle(tester, 3);
    expect(find.text('Qwen3 14B (Q4_K_M): falló · disk full'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('stopping the server asks first and posts action=stop', (
    tester,
  ) async {
    final server = FakeLocalModelsServer();
    await pumpLocalModels(tester, server);
    await tester.tap(find.byKey(const ValueKey('lm1215-server-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lm1215-stop-dialog')), findsOneWidget);
    expect(server.writes(), isEmpty);
    await tester.tap(find.byKey(const ValueKey('lm1215-stop-confirm')));
    await tester.pumpAndSettle();
    expect(server.writes().single.path, '/api/local-models/server');
    expect(server.writes().single.body, {'action': 'stop'});
    expect(find.text('Servidor apagado'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lm1215-server-toggle')));
    await tester.pumpAndSettle();
    expect(server.writes().last.body, {'action': 'start'});
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('missing engine offers a confirmed runtime install', (
    tester,
  ) async {
    final server = FakeLocalModelsServer()..runtimeInstalled = false;
    await pumpLocalModels(tester, server);
    expect(
      find.text('El motor llama.cpp no está instalado en el servidor'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('lm1215-install-runtime')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('lm1215-install-confirm')));
    await _settle(tester, 2);
    final post = server.writes().single;
    expect(post.path, '/api/local-models/runtime/install');
    expect(post.body, {'backend': null});
    server.finishJob(server.jobs.first['job_id'] as String);
    await _settle(tester, 3);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('read-only connection never writes nor asks', (tester) async {
    final server = FakeLocalModelsServer();
    await pumpLocalModels(tester, server, readOnly: true);
    await _openMenu(tester, 'Qwen3-8B-Q4_K_M');
    await tester.tap(find.byKey(const ValueKey('lm1215-action-delete')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lm1215-delete-dialog')), findsNothing);
    expect(find.text(_readOnly(tester)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lm1215-server-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lm1215-stop-dialog')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('lm1215-catalog-qwen3-14b')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('lm1215-search-entry')));
    await tester.pumpAndSettle();
    expect(find.byType(LocalModelsSearchScreen), findsNothing);
    expect(server.writes(), isEmpty);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('a paused job keeps being watched (slower) until it settles', (
    tester,
  ) async {
    final server = FakeLocalModelsServer();
    await pumpLocalModels(tester, server);
    await tester.tap(find.byKey(const ValueKey('lm1215-catalog-qwen3-14b')));
    await _settle(tester, 2);
    final jobId = server.jobs.first['job_id'] as String;
    await tester.tap(find.byKey(ValueKey('lm1215-job-pause-$jobId')));
    await _settle(tester, 2);
    expect(find.text('En pausa'), findsOneWidget);
    // Resumed and finished elsewhere (for example from Desktop).
    server.finishJob(jobId);
    await _settle(tester, 8);
    expect(find.byKey(ValueKey('lm1215-job-$jobId')), findsNothing);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('Hugging Face search → files → download-browsed', (tester) async {
    final server = FakeLocalModelsServer();
    await pumpLocalModels(tester, server);
    await tester.tap(find.byKey(const ValueKey('lm1215-search-entry')));
    await tester.pumpAndSettle();
    expect(find.byType(LocalModelsSearchScreen), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('lm1215-search-field')),
      'qwen3 4b',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    final search = server.calls.lastWhere(
      (c) => c.path == '/api/local-models/search',
    );
    expect(search.query, 'q=qwen3+4b&limit=20');
    expect(find.text('120.0 k descargas · 340 me gusta'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('lm1215-hit-unsloth/Qwen3-4B-GGUF')),
    );
    await tester.pumpAndSettle();
    final files = server.calls.lastWhere(
      (c) => c.path == '/api/local-models/search/files',
    );
    expect(files.query, 'repo=unsloth%2FQwen3-4B-GGUF');
    expect(find.text('Q4_K_M'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lm1215-file-Q4_K_M')));
    await _settle(tester, 8);

    final post = server.writes().single;
    expect(post.path, '/api/local-models/download-browsed');
    expect(post.body, {
      'repo': 'unsloth/Qwen3-4B-GGUF',
      'paths': ['Qwen3-4B-Q4_K_M.gguf'],
    });
    // Back on the main screen, the job is tracked.
    expect(find.byType(LocalModelsSearchScreen), findsNothing);
    final jobId = server.jobs.first['job_id'] as String;
    expect(find.byKey(ValueKey('lm1215-job-$jobId')), findsOneWidget);
    server.finishJob(jobId);
    await _settle(tester, 3);
    expect(find.text('Qwen3-4B-Q4_K_M'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('a split build sends every part in order', (tester) async {
    final server = FakeLocalModelsServer();
    await pumpLocalModels(tester, server);
    await tester.tap(find.byKey(const ValueKey('lm1215-search-entry')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('lm1215-search-field')),
      'qwen3',
    );
    await tester.tap(find.byKey(const ValueKey('lm1215-search-go')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('lm1215-hit-unsloth/Qwen3-4B-GGUF')),
    );
    await tester.pumpAndSettle();
    // The too-big build cannot be picked.
    await tester.tap(find.byKey(const ValueKey('lm1215-file-BF16')));
    await tester.pumpAndSettle();
    expect(server.writes(), isEmpty);
    await tester.tap(find.byKey(const ValueKey('lm1215-file-Q8_0')));
    await _settle(tester, 8);
    expect(server.writes().single.body, {
      'repo': 'unsloth/Qwen3-4B-GGUF',
      'paths': [
        'Q8_0/Qwen3-4B-Q8_0-00001-of-00002.gguf',
        'Q8_0/Qwen3-4B-Q8_0-00002-of-00002.gguf',
      ],
    });
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('search failure (502) shows the server detail', (tester) async {
    final server = FakeLocalModelsServer();
    server.failures['GET /api/local-models/search'] = (
      502,
      'Hugging Face search unavailable: timeout',
    );
    await pumpLocalModels(tester, server);
    await tester.tap(find.byKey(const ValueKey('lm1215-search-entry')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('lm1215-search-field')),
      'x',
    );
    await tester.tap(find.byKey(const ValueKey('lm1215-search-go')));
    await tester.pumpAndSettle();
    expect(
      find.text('Hugging Face search unavailable: timeout'),
      findsOneWidget,
    );
    expect(server.writes(), isEmpty);
  });

  test('quant is read from the GGUF stem', () {
    expect(ggufQuantOf('Qwen3-8B-Q4_K_M'), 'Q4_K_M');
    expect(ggufQuantOf('gemma-3-4b-it-UD-Q8_K_XL'), 'UD-Q8_K_XL');
    expect(ggufQuantOf('Llama-3.2-1B-Instruct-IQ3_XS'), 'IQ3_XS');
    expect(ggufQuantOf('Qwen3-4B-BF16'), 'BF16');
    expect(ggufQuantOf('my-model'), isNull);
  });
}
