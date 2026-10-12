import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dock_preferences_store.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/responsive.dart';
import 'package:hermes_android/core/widgets/general_dock_shell.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Material 3 window size classes: compact phones keep the floating bottom
// dock; medium and expanded windows get a navigation rail on the side and
// content that never stretches into unreadable line lengths.

final _connection = SavedConnection(
  id: 'tablet-shell',
  label: 'Tablet QA',
  host: 'hermes.local',
  port: 8642,
  apiKey: 'k',
);

const _railKey = ValueKey('general-mode-dock-rail');
const _barKey = ValueKey('general-mode-floating-dock');
const _bodyKey = ValueKey('tablet-shell-body');

Widget _host(ConnectionManager manager, {bool paneLayout = false}) =>
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: Scaffold(
        body: GeneralDockShell(
          connection: _connection,
          connManager: manager,
          paneLayout: paneLayout,
          body: const SizedBox.expand(key: _bodyKey),
        ),
      ),
    );

Future<void> _setSize(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('window size classes', () {
    test('breakpoints follow Material 3 (600 / 840)', () {
      expect(Responsive.sizeClassForWidth(320), WindowSizeClass.compact);
      expect(Responsive.sizeClassForWidth(599.9), WindowSizeClass.compact);
      expect(Responsive.sizeClassForWidth(600), WindowSizeClass.medium);
      expect(Responsive.sizeClassForWidth(839.9), WindowSizeClass.medium);
      expect(Responsive.sizeClassForWidth(840), WindowSizeClass.expanded);
      expect(Responsive.sizeClassForWidth(1280), WindowSizeClass.expanded);
    });

    testWidgets('reading the size class does not rebuild on keyboard insets', (
      tester,
    ) async {
      var builds = 0;
      WindowSizeClass? seen;
      var tablet = false;
      Widget app(EdgeInsets insets) => MediaQuery(
        data: MediaQueryData(size: const Size(1024, 768), viewInsets: insets),
        child: Builder(
          builder: (context) {
            // The probe is a child of a stable widget so only a dependency
            // change can rebuild it.
            return const _Probe();
          },
        ),
      );
      _Probe.onBuild = (context) {
        builds++;
        seen = Responsive.sizeClassOf(context);
        tablet = Responsive.isTablet(context);
      };
      await tester.pumpWidget(app(EdgeInsets.zero));
      expect(builds, 1);
      expect(seen, WindowSizeClass.expanded);
      expect(tablet, isTrue);
      // Keyboard opens and animates: only viewInsets change.
      for (final h in [80.0, 160.0, 320.0]) {
        await tester.pumpWidget(app(EdgeInsets.only(bottom: h)));
      }
      expect(builds, 1, reason: 'size class must depend on size only');
    });
  });

  group('GeneralDockShell navigation', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await DockPreferencesController.instance.ensureLoaded();
    });

    for (final (size, rail) in [
      (const Size(411, 915), false),
      (const Size(700, 1000), true),
      (const Size(1024, 768), true),
      (const Size(1280, 800), true),
    ]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()} uses '
          '${rail ? 'a navigation rail' : 'the bottom dock'}', (tester) async {
        await _setSize(tester, size);
        final manager = await ConnectionManager.create(
          await SharedPreferences.getInstance(),
        );
        await tester.pumpWidget(_host(manager));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        expect(find.byKey(_railKey), rail ? findsOneWidget : findsNothing);
        expect(find.byKey(_barKey), rail ? findsNothing : findsOneWidget);
        // The same destinations exist in both forms.
        expect(
          find.byKey(const ValueKey('general-mode-dock-settings')),
          findsOneWidget,
        );

        final body = tester.getRect(find.byKey(_bodyKey));
        if (rail) {
          final railRect = tester.getRect(find.byKey(_railKey));
          expect(railRect.height, greaterThan(railRect.width));
          expect(body.left, greaterThanOrEqualTo(railRect.right));
          // No bottom reservation for a dock that is not at the bottom.
          expect(body.bottom, size.height);
          // Single-pane content never stretches beyond a readable width.
          expect(body.width, lessThanOrEqualTo(Responsive.maxContentWidth));
          final free = size.width - railRect.right;
          if (free > Responsive.maxContentWidth) {
            final centre = railRect.right + free / 2;
            // Centred in the space beside the rail (the rail's own 8dp
            // breathing gap shifts it by half of that at most).
            expect(body.center.dx, closeTo(centre, 4.5));
          }
        } else {
          final bar = tester.getRect(find.byKey(_barKey));
          expect(bar.width, greaterThan(bar.height));
          expect(body.left, 0);
          expect(body.width, size.width);
          expect(body.bottom, lessThanOrEqualTo(bar.top));
        }
      });
    }

    testWidgets('a pane screen gets the full width beside the rail when '
        'expanded but stays centred when medium', (tester) async {
      final manager = await ConnectionManager.create(
        await SharedPreferences.getInstance(),
      );
      await _setSize(tester, const Size(1280, 800));
      await tester.pumpWidget(_host(manager, paneLayout: true));
      await tester.pumpAndSettle();
      final railRect = tester.getRect(find.byKey(_railKey));
      final body = tester.getRect(find.byKey(_bodyKey));
      expect(body.left, greaterThanOrEqualTo(railRect.right));
      expect(body.right, 1280);
      expect(body.width, greaterThan(Responsive.maxContentWidth));

      await _setSize(tester, const Size(700, 1000));
      await tester.pumpAndSettle();
      final medium = tester.getRect(find.byKey(_bodyKey));
      expect(medium.width, lessThanOrEqualTo(Responsive.maxContentWidth));
    });
  });
}

class _Probe extends StatelessWidget {
  const _Probe();
  static void Function(BuildContext context) onBuild = (_) {};

  @override
  Widget build(BuildContext context) {
    onBuild(context);
    return const SizedBox();
  }
}
