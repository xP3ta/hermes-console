// SKILL.md: reading it rendered, rewriting it safely, creating a new skill.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_repository.dart';
import 'package:hermes_android/core/capabilities/capabilities_screen.dart';
import 'package:hermes_android/core/capabilities/capability_detail_screen.dart';
import 'package:hermes_android/core/capabilities/capability_models.dart';
import 'package:hermes_android/core/capabilities/skill_content_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardHttpException;

import '../support/inter_font.dart';
import 'capabilities_fakes.dart';

/// Windows line ends and trailing blanks on purpose: a rewrite must never
/// change what the user did not touch.
const _raw =
    '---\r\nname: notes\r\ndescription: Keeps notes\r\n---\r\n\r\n'
    '# Notes\r\n\r\nUse **bold** with care.  \r\n';

ScriptedRest _server({String provenance = 'agent'}) => ScriptedRest()
  ..gets['skills'] = [
    {
      'name': 'notes',
      'description': 'Keeps notes',
      'enabled': true,
      'provenance': provenance,
    },
  ]
  ..gets['skills/hub/official'] = {'skills': <Object>[]}
  ..gets['skills/content'] = {'name': 'notes', 'content': _raw}
  ..puts['skills/content'] = {'success': true};

CapabilityItem _notes({String provenance = 'agent'}) =>
    CapabilityItem.installedSkill({
      'name': 'notes',
      'description': 'Keeps notes',
      'enabled': true,
      'provenance': provenance,
    })!;

Future<void> _openViewer(
  WidgetTester tester, {
  required Future<String> Function() load,
  Future<void> Function(String)? save,
  String? readOnlyReason,
  List<String> files = const [],
}) async {
  await setPhone(tester);
  await tester.pumpWidget(
    spanishApp(
      SkillContentScreen(
        name: 'notes',
        load: load,
        save: save,
        readOnlyReason: readOnlyReason,
        files: files,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The rows of a detail are built lazily: scroll until [target] exists.
Future<void> _reveal(WidgetTester tester, Finder target) =>
    tester.scrollUntilVisible(
      target,
      300,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('cph-detail-list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );

String _fieldText(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('spp-edit-field')))
    .controller!
    .text;

void main() {
  setUpAll(loadInterFont);

  group('repository', () {
    test('reads the text exactly as stored', () async {
      final rest = _server();
      final repo = repoOf(rest);
      final doc = await repo.skillContent('notes');
      expect(doc.content, _raw);
      expect(rest.calls, ['GET skills/content?name=notes']);
    });

    test('a missing skill is a rejection, not a missing route', () async {
      final rest = ScriptedRest()
        ..gets['skills/content'] = const DashboardHttpException(
          404,
          body: '{"detail":"Skill \'ghost\' not found."}',
        );
      final repo = repoOf(rest);
      await expectLater(
        repo.skillContent('ghost'),
        throwsA(
          isA<CapabilityFailure>()
              .having((e) => e.kind, 'kind', CapabilityFailureKind.rejected)
              .having((e) => e.detail, 'detail', contains('ghost')),
        ),
      );
      expect(repo.supports(CapabilityFeature.skillContent), isNot(false));
    });

    test('a server without the route is unsupported, asked once', () async {
      final rest = ScriptedRest()
        ..gets['skills/content'] = const DashboardHttpException(
          404,
          body: '{"detail":"Not Found"}',
        );
      final repo = repoOf(rest);
      await expectLater(
        repo.skillContent('notes'),
        throwsA(
          isA<CapabilityFailure>().having(
            (e) => e.kind,
            'kind',
            CapabilityFailureKind.unsupported,
          ),
        ),
      );
      expect(repo.supports(CapabilityFeature.skillContent), isFalse);
      rest.calls.clear();
      await expectLater(
        repo.skillContent('notes'),
        throwsA(isA<CapabilityFailure>()),
      );
      expect(rest.calls, isEmpty);
    });

    test('rewrite sends name and the untouched text', () async {
      final rest = _server();
      await repoOf(rest).updateSkillContent('notes', _raw);
      expect(rest.mutations, ['PUT skills/content']);
      expect(rest.bodies.last, {'name': 'notes', 'content': _raw});
    });

    test('a rewrite the server refuses carries its reason', () async {
      final rest = ScriptedRest()
        ..puts['skills/content'] = const DashboardHttpException(
          400,
          body: '{"detail":"Frontmatter must include name field."}',
        );
      await expectLater(
        repoOf(rest).updateSkillContent('notes', 'x'),
        throwsA(
          isA<CapabilityFailure>()
              .having((e) => e.kind, 'kind', CapabilityFailureKind.rejected)
              .having((e) => e.detail, 'detail', contains('Frontmatter')),
        ),
      );
    });

    test('create posts name, content and category', () async {
      final rest = ScriptedRest()..posts['skills'] = {'success': true};
      await repoOf(rest).createSkill('my-skill', _raw, category: 'dev');
      expect(rest.mutations, ['POST skills']);
      expect(rest.bodies.last, {
        'name': 'my-skill',
        'content': _raw,
        'category': 'dev',
      });
    });

    test(
      'an old server answers 405 and creation is marked unsupported',
      () async {
        final rest = ScriptedRest()
          ..posts['skills'] = const DashboardHttpException(405);
        final repo = repoOf(rest);
        await expectLater(
          repo.createSkill('x', _raw),
          throwsA(
            isA<CapabilityFailure>().having(
              (e) => e.kind,
              'kind',
              CapabilityFailureKind.unsupported,
            ),
          ),
        );
        expect(repo.supports(CapabilityFeature.skillCreate), isFalse);
      },
    );
  });

  group('viewer', () {
    testWidgets('renders the Markdown and lists the header fields', (
      tester,
    ) async {
      await _openViewer(tester, load: () async => _raw);
      expect(find.byKey(const ValueKey('spp-content-fields')), findsOneWidget);
      expect(find.textContaining('Keeps notes'), findsWidgets);
      expect(
        find.textContaining('Use bold with care', findRichText: true),
        findsWidgets,
      );
      expect(find.textContaining('**', findRichText: true), findsNothing);
      expect(find.byKey(const ValueKey('spp-content-edit')), findsNothing);
    });

    testWidgets('a long text shows its start and offers the rest', (
      tester,
    ) async {
      final body = List.generate(
        500,
        (i) => 'Paragraph $i of the skill text.',
      ).join('\n\n');
      await _openViewer(
        tester,
        load: () async => '---\nname: big\ndescription: d\n---\n\n$body\n',
      );
      final more = find.byKey(const ValueKey('spp-content-more'));
      await tester.scrollUntilVisible(
        more,
        1000,
        scrollable: find.byType(Scrollable).first,
      );
      expect(more, findsOneWidget);
      expect(
        find.textContaining('Paragraph 499 of', findRichText: true),
        findsNothing,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('spp-content-more')),
      );
      await tester.tap(find.byKey(const ValueKey('spp-content-more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('spp-content-more')), findsNothing);
      await tester.scrollUntilVisible(
        find.textContaining('Paragraph 499 of', findRichText: true),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.textContaining('Paragraph 499 of', findRichText: true),
        findsWidgets,
      );
    });

    testWidgets('a failed read says so and retries', (tester) async {
      var attempts = 0;
      await _openViewer(
        tester,
        load: () async {
          if (++attempts == 1) throw const DashboardHttpException(503);
          return _raw;
        },
      );
      expect(find.byKey(const ValueKey('spp-content-error')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('spp-content-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('spp-content-error')), findsNothing);
      expect(find.byKey(const ValueKey('spp-content-body')), findsOneWidget);
    });

    testWidgets('a preview lists the files of the hub skill', (tester) async {
      await _openViewer(
        tester,
        load: () async => '# Docker\nRuns **containers**',
        files: const ['SKILL.md', 'scripts/run.sh'],
      );
      expect(find.textContaining('scripts/run.sh'), findsOneWidget);
      expect(find.byKey(const ValueKey('spp-content-fields')), findsNothing);
    });

    testWidgets('no edit for a skill that is not the user\'s own', (
      tester,
    ) async {
      await _openViewer(
        tester,
        load: () async => _raw,
        readOnlyReason: 'No se edita aquí',
      );
      expect(
        find.byKey(const ValueKey('spp-content-readonly')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('spp-content-edit')), findsNothing);
    });
  });

  group('editing', () {
    testWidgets(
      'saves exactly the text, keeps line ends, offers the original',
      (tester) async {
        var server = _raw;
        final saved = <String>[];
        await _openViewer(
          tester,
          load: () async => server,
          save: (text) async {
            saved.add(text);
            server = text;
          },
        );
        await tester.tap(find.byKey(const ValueKey('spp-content-edit')));
        await tester.pumpAndSettle();
        expect(_fieldText(tester), _raw, reason: 'opened untouched');

        final edited = _raw.replaceFirst('with care', 'with great care');
        await tester.enterText(
          find.byKey(const ValueKey('spp-edit-field')),
          edited,
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('spp-edit-submit')));
        await tester.pumpAndSettle();

        expect(saved, [edited]);
        expect(saved.single.contains('\r\n'), isTrue);
        expect(find.byKey(const ValueKey('spp-edit-field')), findsNothing);
        expect(
          find.textContaining('with great care', findRichText: true),
          findsWidgets,
        );
        // The original is one tap away and goes back byte for byte.
        await tester.ensureVisible(
          find.byKey(const ValueKey('spp-content-restore')),
        );
        await tester.tap(find.byKey(const ValueKey('spp-content-restore')));
        await tester.pumpAndSettle();
        expect(saved.last, _raw);
        expect(find.byKey(const ValueKey('spp-content-restore')), findsNothing);
      },
    );

    testWidgets('a header the server would refuse is stopped here', (
      tester,
    ) async {
      final saved = <String>[];
      await _openViewer(
        tester,
        load: () async => _raw,
        save: (text) async => saved.add(text),
      );
      await tester.tap(find.byKey(const ValueKey('spp-content-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('spp-edit-field')),
        'just words',
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('spp-edit-issue')), findsOneWidget);
      expect(
        find.textContaining('debe empezar con una cabecera'),
        findsOneWidget,
      );
      final submit = tester.widget<FilledButton>(
        find.byKey(const ValueKey('spp-edit-submit')),
      );
      expect(submit.onPressed, isNull);
      expect(saved, isEmpty);
    });

    testWidgets('a failed save keeps the typed text and says why', (
      tester,
    ) async {
      await _openViewer(
        tester,
        load: () async => _raw,
        save: (_) async => throw const CapabilityFailure(
          CapabilityFailureKind.rejected,
          detail: 'Description exceeds 1024 characters.',
        ),
      );
      await tester.tap(find.byKey(const ValueKey('spp-content-edit')));
      await tester.pumpAndSettle();
      final edited = _raw.replaceFirst('Keeps notes', 'Keeps all notes');
      await tester.enterText(
        find.byKey(const ValueKey('spp-edit-field')),
        edited,
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('spp-edit-submit')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Description exceeds 1024'), findsOneWidget);
      expect(_fieldText(tester), edited, reason: 'nothing typed was lost');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('spp-edit-submit')))
            .onPressed,
        isNotNull,
        reason: 'can try again',
      );
    });

    testWidgets('a lost connection while re-reading saves nothing', (
      tester,
    ) async {
      var reads = 0;
      final saved = <String>[];
      await _openViewer(
        tester,
        load: () async {
          if (++reads > 1) throw const DashboardHttpException(503);
          return _raw;
        },
        save: (text) async => saved.add(text),
      );
      await tester.tap(find.byKey(const ValueKey('spp-content-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('spp-edit-field')),
        _raw.replaceFirst('Keeps notes', 'Keeps more'),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('spp-edit-submit')));
      await tester.pumpAndSettle();
      expect(saved, isEmpty);
      expect(find.byKey(const ValueKey('spp-edit-field')), findsOneWidget);
    });

    testWidgets('a copy changed on the server asks before overwriting', (
      tester,
    ) async {
      var reads = 0;
      final saved = <String>[];
      await _openViewer(
        tester,
        load: () async => ++reads == 1 ? _raw : '$_raw\r\nAdded elsewhere.\r\n',
        save: (text) async => saved.add(text),
      );
      await tester.tap(find.byKey(const ValueKey('spp-content-edit')));
      await tester.pumpAndSettle();
      final edited = _raw.replaceFirst('Keeps notes', 'Keeps mine');
      await tester.enterText(
        find.byKey(const ValueKey('spp-edit-field')),
        edited,
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('spp-edit-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('spp-changed-dialog')), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(saved, isEmpty);

      await tester.tap(find.byKey(const ValueKey('spp-edit-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('spp-changed-overwrite')));
      await tester.pumpAndSettle();
      expect(saved, [edited]);
    });
  });

  group('after a write', () {
    Future<String> editAndSave(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('spp-content-edit')));
      await tester.pumpAndSettle();
      final edited = _raw.replaceFirst('with care', 'with great care');
      await tester.enterText(
        find.byKey(const ValueKey('spp-edit-field')),
        edited,
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('spp-edit-submit')));
      await tester.pumpAndSettle();
      return edited;
    }

    testWidgets('the viewer shows what the server holds, not what was typed', (
      tester,
    ) async {
      var server = _raw;
      var reads = 0;
      await _openViewer(
        tester,
        load: () async {
          reads++;
          return server;
        },
        // The server normalises the text it stores.
        save: (text) async => server = text.replaceFirst(
          'great care',
          'great care (stored by the server)',
        ),
      );
      expect(reads, 1);
      await editAndSave(tester);
      // One read to open, one before the write, one after it.
      expect(reads, 3);
      expect(find.byKey(const ValueKey('spp-edit-field')), findsNothing);
      expect(find.byKey(const ValueKey('spp-changed-dialog')), findsNothing);
      expect(
        find.textContaining('stored by the server', findRichText: true),
        findsWidgets,
      );
    });

    testWidgets('restoring asks first when the server copy changed', (
      tester,
    ) async {
      var server = _raw;
      final saved = <String>[];
      await _openViewer(
        tester,
        load: () async => server,
        save: (text) async {
          saved.add(text);
          server = text;
        },
      );
      final edited = await editAndSave(tester);
      expect(saved, [edited]);

      // The agent rewrote it in the meantime.
      server = '$edited\r\nAdded elsewhere.\r\n';
      final restore = find.byKey(const ValueKey('spp-content-restore'));
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('spp-changed-dialog')), findsOneWidget);
      expect(saved, [edited], reason: 'nothing written before the answer');

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(saved, [edited]);

      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('spp-changed-overwrite')));
      await tester.pumpAndSettle();
      expect(saved, [edited, _raw]);
      // Re-read after the write: back to the original, nothing left to restore.
      expect(restore, findsNothing);
    });

    testWidgets('restoring an unchanged copy writes without the dialog', (
      tester,
    ) async {
      var server = _raw;
      final saved = <String>[];
      await _openViewer(
        tester,
        load: () async => server,
        save: (text) async {
          saved.add(text);
          server = text;
        },
      );
      final edited = await editAndSave(tester);
      final restore = find.byKey(const ValueKey('spp-content-restore'));
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('spp-changed-dialog')), findsNothing);
      expect(saved, [edited, _raw]);
    });

    testWidgets('a restore that cannot re-read the server writes nothing', (
      tester,
    ) async {
      var server = _raw;
      var failReads = false;
      final saved = <String>[];
      await _openViewer(
        tester,
        load: () async {
          if (failReads) throw const DashboardHttpException(503);
          return server;
        },
        save: (text) async {
          saved.add(text);
          server = text;
        },
      );
      final edited = await editAndSave(tester);
      failReads = true;
      final restore = find.byKey(const ValueKey('spp-content-restore'));
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(saved, [edited]);
    });
  });

  group('from the skill detail', () {
    Future<void> openDetail(
      WidgetTester tester,
      ScriptedRest rest,
      CapabilityItem item, {
      bool readOnly = false,
      VoidCallback? onChanged,
    }) async {
      await setPhone(tester);
      await tester.pumpWidget(
        spanishApp(
          CapabilityDetailScreen(
            key: UniqueKey(),
            item: item,
            repository: repoOf(rest),
            readOnly: readOnly,
            onChanged: onChanged,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the user\'s own skill opens, is editable and saves', (
      tester,
    ) async {
      var changed = 0;
      final rest = _server();
      await openDetail(tester, rest, _notes(), onChanged: () => changed++);
      await _reveal(tester, find.byKey(const ValueKey('spp-row-skill-md')));
      await tester.tap(find.byKey(const ValueKey('spp-row-skill-md')));
      await tester.pumpAndSettle();

      expect(find.byType(SkillContentScreen), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('spp-content-edit')));
      await tester.pumpAndSettle();
      final edited = _raw.replaceFirst('Keeps notes', 'Keeps notes well');
      await tester.enterText(
        find.byKey(const ValueKey('spp-edit-field')),
        edited,
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('spp-edit-submit')));
      await tester.pumpAndSettle();

      expect(rest.mutations, ['PUT skills/content']);
      expect(rest.bodies.last, {'name': 'notes', 'content': edited});
      expect(changed, 1);
    });

    testWidgets('a hub or bundled skill is readable, never editable', (
      tester,
    ) async {
      for (final provenance in ['hub', 'bundled', 'external']) {
        final rest = _server(provenance: provenance);
        await openDetail(tester, rest, _notes(provenance: provenance));
        await _reveal(tester, find.byKey(const ValueKey('spp-row-skill-md')));
        await tester.tap(find.byKey(const ValueKey('spp-row-skill-md')));
        await tester.pumpAndSettle();
        expect(
          find.byType(SkillContentScreen),
          findsOneWidget,
          reason: provenance,
        );
        expect(
          find.byKey(const ValueKey('spp-content-readonly')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('spp-content-edit')), findsNothing);
        expect(rest.mutations, isEmpty);
        // Back to the detail so the next one starts from a clean stack.
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('a read-only connection can read and not edit', (tester) async {
      final rest = _server();
      await openDetail(tester, rest, _notes(), readOnly: true);
      await _reveal(tester, find.byKey(const ValueKey('spp-row-skill-md')));
      await tester.tap(find.byKey(const ValueKey('spp-row-skill-md')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('spp-content-body')), findsOneWidget);
      expect(find.byKey(const ValueKey('spp-content-edit')), findsNothing);
    });

    testWidgets(
      'a server without the route shows no SKILL.md row after trying',
      (tester) async {
        final rest = ScriptedRest();
        await openDetail(tester, rest, _notes());
        await _reveal(tester, find.byKey(const ValueKey('spp-row-skill-md')));
        await tester.tap(find.byKey(const ValueKey('spp-row-skill-md')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('spp-content-error')), findsOneWidget);
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('spp-row-skill-md')), findsNothing);
      },
    );

    testWidgets('a hub preview renders the Markdown, not its marks', (
      tester,
    ) async {
      const docker = CapabilityItem(
        kind: CapabilityKind.skill,
        id: 'skill:official:official/devops/docker',
        name: 'docker',
        installId: 'official/devops/docker',
        installedName: 'docker',
        provenance: 'hub',
      );
      final rest = ScriptedRest()
        ..gets['skills/hub/preview'] = {
          'name': 'docker',
          'skill_md': '# Docker\nRuns **containers**',
          'files': ['SKILL.md', 'scripts/run.sh'],
        };
      final repo = repoOf(rest);
      await repo.skillPreview(docker.installId);
      await setPhone(tester);
      await tester.pumpWidget(
        spanishApp(CapabilityDetailScreen(item: docker, repository: repo)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('cph-row-preview')));
      await tester.tap(find.byKey(const ValueKey('cph-row-preview')));
      await tester.pumpAndSettle();
      expect(find.byType(SkillContentScreen), findsOneWidget);
      expect(
        find.textContaining('Runs containers', findRichText: true),
        findsWidgets,
      );
      expect(find.textContaining('**', findRichText: true), findsNothing);
      expect(find.byKey(const ValueKey('spp-content-edit')), findsNothing);
    });
  });

  group('new skill', () {
    Future<void> openHub(WidgetTester tester, ScriptedRest rest) async {
      await setPhone(tester);
      await tester.pumpWidget(
        spanishApp(
          CapabilitiesScreen(
            repository: repoOf(rest),
            searchDebounce: Duration.zero,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('exu-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('spp-menu-new-skill')));
      await tester.pumpAndSettle();
    }

    Future<void> fill(
      WidgetTester tester, {
      String name = 'my-skill',
      String description = 'Plans my week',
      String body = 'Ask for the goals, then list the steps.',
    }) async {
      await tester.enterText(
        find.byKey(const ValueKey('spp-create-name')),
        name,
      );
      await tester.enterText(
        find.byKey(const ValueKey('spp-create-description')),
        description,
      );
      await tester.enterText(
        find.byKey(const ValueKey('spp-create-body-field')),
        body,
      );
      await tester.pump();
    }

    testWidgets('the form builds the header and posts the skill', (
      tester,
    ) async {
      final rest = populatedServer()..posts['skills'] = {'success': true};
      await openHub(tester, rest);
      await fill(tester);
      await tester.enterText(
        find.byKey(const ValueKey('spp-create-category')),
        'planning',
      );
      await tester.tap(find.byKey(const ValueKey('spp-create-submit')));
      await tester.pumpAndSettle();

      expect(rest.mutations, ['POST skills']);
      final body = rest.bodies.last!;
      expect(body['name'], 'my-skill');
      expect(body['category'], 'planning');
      expect(
        body['content'],
        '---\nname: my-skill\ndescription: "Plans my week"\n---\n\n'
        'Ask for the goals, then list the steps.\n',
      );
      // Back on the hub, reloaded.
      expect(find.byKey(const ValueKey('spp-create-body')), findsNothing);
    });

    testWidgets('a bad name is explained as it is typed; nothing is sent', (
      tester,
    ) async {
      final rest = populatedServer();
      await openHub(tester, rest);
      await fill(tester, name: 'My Skill');
      expect(
        find.textContaining('Usa minúsculas, números, punto, guion'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('spp-create-submit')));
      await tester.pumpAndSettle();
      expect(rest.mutations, isEmpty);
    });

    testWidgets('a description over the prompt budget is refused here', (
      tester,
    ) async {
      final rest = populatedServer();
      await openHub(tester, rest);
      await fill(tester, description: 'd' * 61);
      expect(find.textContaining('hasta 60 caracteres'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('spp-create-submit')));
      await tester.pumpAndSettle();
      expect(rest.mutations, isEmpty);
    });

    testWidgets('missing instructions are asked for on submit', (tester) async {
      final rest = populatedServer();
      await openHub(tester, rest);
      await fill(tester, body: '');
      await tester.tap(find.byKey(const ValueKey('spp-create-submit')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Faltan las instrucciones'), findsOneWidget);
      expect(rest.mutations, isEmpty);
    });

    testWidgets('a server that refuses says why and keeps the form', (
      tester,
    ) async {
      final rest = populatedServer()
        ..posts['skills'] = const DashboardHttpException(
          400,
          body: '{"detail":"A skill named \'my-skill\' already exists."}',
        );
      await openHub(tester, rest);
      await fill(tester);
      await tester.tap(find.byKey(const ValueKey('spp-create-submit')));
      await tester.pumpAndSettle();
      expect(find.textContaining('already exists'), findsOneWidget);
      expect(find.byKey(const ValueKey('spp-create-body')), findsOneWidget);
    });

    testWidgets('an old server (405) removes the menu entry', (tester) async {
      final rest = populatedServer()
        ..posts['skills'] = const DashboardHttpException(405);
      await openHub(tester, rest);
      await fill(tester);
      await tester.tap(find.byKey(const ValueKey('spp-create-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('spp-create-body')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('form-page-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('form-page-discard')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('exu-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('spp-menu-new-skill')), findsNothing);
    });

    testWidgets('the «+» keeps only the hub when nothing else is offered', (
      tester,
    ) async {
      final rest = ScriptedRest()
        ..gets['skills'] = [
          {'name': 'notes', 'provenance': 'agent', 'enabled': true},
        ]
        ..gets['skills/hub/official'] = {'skills': <Object>[]}
        ..posts['skills'] = const DashboardHttpException(405);
      final repo = repoOf(rest);
      // Creation was learned to be unsupported and there is no hub skill to
      // update, so the hub is all that is left to put in the menu.
      await expectLater(
        repo.createSkill('x', _raw),
        throwsA(isA<CapabilityFailure>()),
      );
      await setPhone(tester);
      await tester.pumpWidget(
        spanishApp(
          CapabilitiesScreen(repository: repo, searchDebounce: Duration.zero),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Más opciones'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('exu-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('exu-add-skill-hub')), findsOneWidget);
      expect(find.byKey(const ValueKey('spp-menu-new-skill')), findsNothing);
      expect(
        find.byKey(const ValueKey('cph-menu-update-skills')),
        findsNothing,
      );
    });

    testWidgets('read-only connections are not offered a new skill', (
      tester,
    ) async {
      await setPhone(tester);
      await tester.pumpWidget(
        spanishApp(
          CapabilitiesScreen(
            repository: repoOf(populatedServer()),
            readOnly: true,
            searchDebounce: Duration.zero,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('exu-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('spp-menu-new-skill')), findsNothing);
      expect(find.byKey(const ValueKey('spp-menu-add-mcp')), findsNothing);
    });
  });
}
