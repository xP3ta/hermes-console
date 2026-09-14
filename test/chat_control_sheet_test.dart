import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_control_sheet.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';

const _labels = ChatControlLabels(
  title: 'Chat settings',
  scope: 'Only this conversation',
  sessionSection: 'Session',
  toolsSection: 'Tools',
  dangerSection: 'Danger',
  permissions: 'Permissions',
  refresh: 'Refresh',
  artifacts: 'Artifacts',
  details: 'Details',
  cron: 'Schedule',
  delete: 'Delete conversation',
  readOnly: 'Read only',
  releaseDesktop: 'Release for Desktop',
  releaseUnavailable: 'Viewer cardinality unavailable',
);

Widget _app({
  bool readOnly = false,
  bool showDelete = true,
  VoidCallback? onDelete,
  VoidCallback? onArtifacts,
  bool showRelease = false,
  bool releaseEnabled = false,
  bool releaseInFlight = false,
  VoidCallback? onRelease,
}) => MaterialApp(
  theme: AppTheme.hermesRedDark,
  home: Scaffold(
    body: ChatControlSheet(
      labels: _labels,
      conversationTitle: 'Synthetic conversation',
      readOnly: readOnly,
      showDetails: true,
      showCron: true,
      onPermissions: () {},
      onRefresh: () {},
      onArtifacts: onArtifacts ?? () {},
      onDetails: () {},
      onCron: () {},
      onDelete: showDelete ? onDelete ?? () {} : null,
      showReleaseDesktop: showRelease,
      releaseDesktopEnabled: releaseEnabled,
      releaseInFlight: releaseInFlight,
      onReleaseDesktop: onRelease,
    ),
  ),
);

void main() {
  testWidgets('keeps only unique session actions and direct tools', (
    tester,
  ) async {
    var artifactsOpened = false;
    await tester.pumpWidget(_app(onArtifacts: () => artifactsOpened = true));

    expect(find.byKey(const ValueKey('chat-control-sheet')), findsOneWidget);
    expect(find.text('Synthetic conversation'), findsOneWidget);
    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('Model and reasoning'), findsNothing);
    expect(find.text('Preferences'), findsNothing);
    expect(find.text('Density'), findsNothing);
    expect(find.text('Agents and subagents'), findsNothing);
    expect(find.text('More tools'), findsNothing);
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.text('Artifacts'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
    expect(find.text('Schedule'), findsOneWidget);

    await tester.ensureVisible(find.text('Artifacts'));
    await tester.tap(find.text('Artifacts'));
    await tester.pump();
    expect(artifactsOpened, isTrue);
  });

  testWidgets('read-only disables the destructive target', (tester) async {
    var deleted = false;
    await tester.pumpWidget(
      _app(readOnly: true, onDelete: () => deleted = true),
    );
    expect(find.text('READ ONLY'), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('chat-control-sheet')),
      const Offset(0, -1000),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete conversation'));
    await tester.pump();

    expect(deleted, isFalse);
  });

  testWidgets('omits the dangerous section when deletion is not applicable', (
    tester,
  ) async {
    await tester.pumpWidget(_app(showDelete: false));

    expect(find.text('Danger'), findsNothing);
    expect(find.text('Delete conversation'), findsNothing);
    expect(find.byKey(const ValueKey('chat-control-delete')), findsNothing);
  });

  testWidgets('release habilitado ejecuta callback y expone progreso estable', (
    tester,
  ) async {
    var released = false;
    await tester.pumpWidget(
      _app(
        showRelease: true,
        releaseEnabled: true,
        onRelease: () => released = true,
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('chat-control-release-desktop')),
    );
    expect(released, isTrue);

    await tester.pumpWidget(
      _app(showRelease: true, releaseEnabled: false, releaseInFlight: true),
    );
    expect(
      find.byKey(const ValueKey('chat-runtime-release-progress')),
      findsOneWidget,
    );
  });

  testWidgets('floating menu stays bounded and scrollable at 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.hermesRedDark,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showHermesFloatingSurface<void>(
                  context: context,
                  surfaceKey: const ValueKey('compact-chat-control'),
                  maxWidth: 480,
                  builder: (_) => ChatControlSheet(
                    labels: _labels,
                    conversationTitle: 'Synthetic conversation',
                    showDetails: true,
                    showCron: true,
                    onPermissions: () {},
                    onRefresh: () {},
                    onArtifacts: () {},
                    onDetails: () {},
                    onCron: () {},
                    onDelete: () {},
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey('compact-chat-control'));
    expect(surface, findsOneWidget);
    expect(tester.getSize(surface).width, lessThanOrEqualTo(328));
    expect(tester.getSize(surface).height, lessThan(540));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('chat-control-delete')),
      260,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('chat-control-sheet')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.byKey(const ValueKey('chat-control-delete')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
