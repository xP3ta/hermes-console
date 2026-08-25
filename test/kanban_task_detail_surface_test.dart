import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/kanban.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/kanban_task_detail_surface.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  Future<void> pumpSurface(
    WidgetTester tester, {
    required KanbanTaskDetail detail,
    bool readOnly = false,
    KanbanCommentAction? onAddComment,
    Size physicalSize = const Size(900, 1600),
  }) async {
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromId('dark'),
        home: Scaffold(
          body: KanbanTaskDetailSurface(
            detail: detail,
            readOnly: readOnly,
            onAddComment: onAddComment,
            onUploadAttachment: () async {},
            onDownloadAttachment: (_) async {},
            onDeleteAttachment: (_) async {},
            onInspectRun: (_) async {},
            onTerminateRun: (_) async {},
            onShowLog: () async {},
            onReclaim: () async {},
            onReassign: () async {},
            onSpecify: () async {},
            onDecompose: () async {},
            onConfigureModel: () async {},
            onOpenLinkedTask: (_) async {},
            onArchive: () {},
            onDelete: () {},
            onMove: () {},
            onEdit: () {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> expand(WidgetTester tester, String key) async {
    final section = find.byKey(ValueKey(key));
    await tester.ensureVisible(section);
    await tester.tap(section);
    await tester.pumpAndSettle();
  }

  testWidgets('tarjeta larga oculta contenido secundario hasta expandirlo', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pendingComment = Completer<void>();
    final detail = KanbanTaskDetail.fromJson({
      'task': {
        'id': 'long',
        'title': 'Tarjeta larga',
        'body': 'Objetivo completo que ocupa muchas líneas',
        'status': 'blocked',
        'assignee': 'luna',
        'block_reason': 'Falta decisión humana',
        'result': 'Evidencia final reservada',
        'diagnostics': [
          {
            'kind': 'stuck',
            'title': 'Atascada',
            'detail': 'Detalle diagnóstico',
          },
        ],
      },
      'comments': [
        {'id': 1, 'author': 'qa', 'body': 'Comentario reservado'},
      ],
      'attachments': [
        {'id': 2, 'filename': 'evidence.txt', 'size': 12},
      ],
      'runs': [
        {'id': 3, 'status': 'failed', 'summary': 'Resumen ejecución'},
      ],
      'events': [
        for (var index = 0; index < 23; index++)
          {'id': index, 'kind': 'event_$index'},
      ],
      'links': {
        'parents': ['parent-private'],
      },
      'child_results': [
        {'id': 'child', 'title': 'Subtarea reservada', 'status': 'done'},
      ],
    });

    await pumpSurface(
      tester,
      detail: detail,
      physicalSize: const Size(390, 844),
      onAddComment: (_) => pendingComment.future,
    );

    expect(find.text('Tarjeta larga'), findsOneWidget);
    expect(find.text('Falta decisión humana'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('kanban-task-detail-body-summary')),
      findsOneWidget,
    );
    final blockY = tester.getTopLeft(find.text('Falta decisión humana')).dy;
    final summaryY = tester
        .getTopLeft(
          find.byKey(const ValueKey('kanban-task-detail-body-summary')),
        )
        .dy;
    expect(blockY, lessThan(summaryY));
    for (final hidden in [
      'Evidencia final reservada',
      'Detalle diagnóstico',
      'parent-private',
      'Subtarea reservada',
      'Comentario reservado',
      'evidence.txt',
      'Resumen ejecución',
      'event 6',
    ]) {
      expect(find.text(hidden), findsNothing, reason: hidden);
    }

    final sections = {
      'kanban-detail-result': 'Evidencia final reservada',
      'kanban-detail-diagnostics': 'Detalle diagnóstico',
      'kanban-detail-links': 'parent-private',
      'kanban-detail-children': 'Subtarea reservada',
      'kanban-detail-comments': 'Comentario reservado',
      'kanban-detail-attachments': 'evidence.txt',
      'kanban-detail-runs': 'Resumen ejecución',
      'kanban-detail-events': 'event 22',
    };
    await expand(tester, 'kanban-detail-objective');
    expect(
      find.byKey(const ValueKey('kanban-task-detail-body')),
      findsOneWidget,
    );
    for (final entry in sections.entries) {
      await expand(tester, entry.key);
      expect(find.text(entry.value), findsOneWidget, reason: entry.key);
    }
    expect(find.text('event 1'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('kanban-events-show-all')));
    await tester.pumpAndSettle();
    expect(find.text('event 0'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('kanban-comment-field')),
      'borrador anterior',
    );
    await tester.tap(find.byKey(const ValueKey('kanban-comment-send')));
    await tester.pump();

    await pumpSurface(
      tester,
      detail: KanbanTaskDetail.fromJson({
        'task': {'id': 'next', 'title': 'Siguiente', 'status': 'todo'},
        'events': [
          for (var index = 0; index < 7; index++)
            {'id': index, 'kind': 'next_$index'},
        ],
        'comments': [],
      }),
      physicalSize: const Size(390, 844),
      onAddComment: (_) async {},
    );
    expect(find.text('next 1'), findsNothing);
    final nextComments = find.byKey(const ValueKey('kanban-detail-comments'));
    await tester.ensureVisible(nextComments);
    await tester.tap(nextComments);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.byKey(const ValueKey('kanban-comment-field')),
      'borrador nuevo',
    );
    pendingComment.complete();
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('kanban-comment-field')))
          .controller!
          .text,
      'borrador nuevo',
    );
  });

  testWidgets('detalle 0.20 muestra secciones ricas y envía comentario', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? submitted;
    final detail = KanbanTaskDetail.fromJson({
      'task': {
        'id': 't1',
        'title': 'Investigar fallo',
        'body': 'Cuerpo completo',
        'status': 'triage',
        'diagnostics': [
          {
            'kind': 'stuck',
            'severity': 'warning',
            'title': 'Atascada',
            'detail': 'No progresa',
          },
        ],
      },
      'comments': [
        {'id': 1, 'author': 'tester', 'body': 'Reproducido'},
      ],
      'attachments': [
        {'id': 2, 'filename': 'trace.txt', 'size': 12},
      ],
      'runs': [
        {'id': 3, 'status': 'failed', 'ended_at': 100},
      ],
      'events': [
        {
          'id': 4,
          'kind': 'blocked',
          'payload': {'reason': 'timeout'},
        },
      ],
      'links': {
        'parents': ['parent'],
        'children': ['child'],
      },
      'child_results': [
        {'id': 'child', 'title': 'Subtarea', 'status': 'done'},
      ],
    });

    await pumpSurface(
      tester,
      detail: detail,
      onAddComment: (body) async => submitted = body,
    );

    for (final key in [
      'kanban-detail-diagnostics',
      'kanban-detail-links',
      'kanban-detail-children',
      'kanban-detail-comments',
      'kanban-detail-attachments',
      'kanban-detail-runs',
      'kanban-detail-events',
      'kanban-detail-operations',
    ]) {
      await expand(tester, key);
    }

    expect(
      find.byKey(const ValueKey('kanban-detail-diagnostics')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('kanban-detail-links')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('kanban-detail-children')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('kanban-detail-comments')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('kanban-detail-attachments')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('kanban-detail-runs')), findsOneWidget);
    expect(find.byKey(const ValueKey('kanban-detail-events')), findsOneWidget);
    expect(find.byKey(const ValueKey('kanban-task-specify')), findsOneWidget);
    expect(find.byKey(const ValueKey('kanban-task-decompose')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('kanban-comment-field')),
      'Nueva pista',
    );
    await tester.tap(find.byKey(const ValueKey('kanban-comment-send')));
    await tester.pump();

    expect(submitted, 'Nueva pista');
    expect(tester.takeException(), isNull);
  });

  testWidgets('solo lectura conserva inspección y bloquea mutaciones', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final detail = KanbanTaskDetail.fromJson({
      'task': {'id': 't1', 'title': 'Running', 'status': 'running'},
      'comments': [],
      'attachments': [],
      'runs': [
        {'id': 3, 'status': 'running'},
      ],
      'events': [],
      'links': {},
      'child_results': [],
    });

    await pumpSurface(tester, detail: detail, readOnly: true);

    await expand(tester, 'kanban-detail-runs');
    await expand(tester, 'kanban-detail-operations');

    expect(
      find.byKey(const ValueKey('kanban-detail-read-only')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('kanban-comment-field')), findsNothing);
    expect(
      find.byKey(const ValueKey('kanban-attachment-upload')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('kanban-run-terminate-3')), findsNothing);
    expect(find.byKey(const ValueKey('kanban-task-archive')), findsNothing);
    expect(find.byKey(const ValueKey('kanban-model-override')), findsOneWidget);
    expect(find.byIcon(Icons.monitor_heart_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('respuesta legacy oculta secciones inexistentes', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final detail = KanbanTaskDetail.fromJson({
      'id': 'legacy',
      'title': 'Legacy',
      'status': 'todo',
    });

    await pumpSurface(tester, detail: detail);

    expect(find.byKey(const ValueKey('kanban-detail-comments')), findsNothing);
    expect(
      find.byKey(const ValueKey('kanban-detail-attachments')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('kanban-detail-runs')), findsNothing);
    expect(find.byKey(const ValueKey('kanban-detail-events')), findsNothing);
    expect(find.byKey(const ValueKey('kanban-detail-links')), findsNothing);
    expect(find.byKey(const ValueKey('kanban-detail-children')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ancho estrecho apila acciones y no muestra rutas remotas', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final detail = KanbanTaskDetail.fromJson({
      'task': {'id': 't1', 'title': 'Estrecha', 'status': 'todo'},
      'attachments': [
        {'id': 2, 'filename': '/srv/hermes/private/trace.txt', 'size': 12},
      ],
    });

    await pumpSurface(
      tester,
      detail: detail,
      physicalSize: const Size(320, 1200),
    );

    await expand(tester, 'kanban-detail-attachments');

    expect(find.text('trace.txt'), findsOneWidget);
    expect(find.textContaining('/srv/hermes'), findsNothing);
    expect(find.byKey(const ValueKey('kanban-task-archive')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('kanban-task-delete-permanent')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
