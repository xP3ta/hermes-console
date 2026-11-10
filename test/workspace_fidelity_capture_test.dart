// Capturas «ahora» de REPORT-WS-FIDELIDAD, para ponerlas al lado de la v25.
// No forma parte de la suite: solo corre con WS_FIDELITY_CAPTURE=1 y deja
// los PNG en WS_FIDELITY_OUT (por defecto build/ws_fidelity). Pinta el host
// real (marco, selector y acciones del panel, navegación lateral) y el composer y
// la píldora reales; el chat y el contenido de las pestañas son de muestra.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/shell/gesture_dock_host.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/console_composer.dart';
import 'package:hermes_android/core/widgets/chat_status_pill.dart';
import 'package:hermes_android/core/widgets/session_context_usage.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace.dart';
import 'package:hermes_android/core/widgets/workspace/chat_workspace_host.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

final bool _enabled = Platform.environment['WS_FIDELITY_CAPTURE'] == '1';
final String _out =
    Platform.environment['WS_FIDELITY_OUT'] ?? 'build/ws_fidelity';
const _shot = ValueKey('ws-fidelity-shot');

Future<void> _loadFonts() async {
  for (final (family, asset) in const [
    ('Inter', 'assets/fonts/Inter.ttf'),
    ('JetBrainsMono', 'assets/fonts/JetBrainsMono.ttf'),
  ]) {
    await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
  }
  final root = Platform.environment['FLUTTER_ROOT'];
  final icons = File(
    '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (root != null && icons.existsSync()) {
    final bytes = ByteData.sublistView(icons.readAsBytesSync());
    await (FontLoader('MaterialIcons')..addFont(Future.value(bytes))).load();
  }
}

Future<void> _save(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_shot),
    );
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$_out/$name.png')..createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
  });
}

/// A chat of sample bubbles above the real composer and status pill.
class _SampleChat extends StatefulWidget {
  const _SampleChat();

  @override
  State<_SampleChat> createState() => _SampleChatState();
}

class _SampleChatState extends State<_SampleChat> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _metrics = ValueNotifier(const SessionContextMetrics(percent: 12));

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _metrics.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    Widget bubble(String text, {required bool mine}) => Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: mine ? colors.surfaceVariant : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(text, style: TextStyle(color: colors.textPrimary)),
      ),
    );
    return Scaffold(
      backgroundColor: colors.background,
      body: Column(
        children: [
          const SizedBox(height: 60),
          bubble(
            'Arregla el título con ideograma y sube los cambios',
            mine: true,
          ),
          bubble(
            'Hecho. Cambié session.dart y el comando de estado SSH; '
            'los 51 tests pasan.',
            mine: false,
          ),
          const Spacer(),
          ConsoleComposer(
            controller: _controller,
            focusNode: _focus,
            onSend: (_, _) {},
            onAttach: (_) {},
            dictation: ConsoleComposerDictation(
              recording: false,
              onStart: () {},
              onStop: () {},
              onCancel: () {},
              onSend: () {},
            ),
            footer: ChatStatusPill(
              metrics: _metrics,
              onOpenContext: () {},
              modelLabel: 'Sonnet 4.5',
              onOpenModel: () {},
              permissionsLabel: 'Preguntar',
              onOpenPermissions: () {},
            ),
          ),
        ],
      ),
    );
  }
}

/// Stands in for a tab: a terminal-like card for Terminal (with the
/// controls the real one puts on the bar), a list for the others.
class _SampleTab extends StatefulWidget {
  const _SampleTab(this.tab);

  final ChatWorkspaceTab tab;

  @override
  State<_SampleTab> createState() => _SampleTabState();
}

class _SampleTabState extends State<_SampleTab> {
  bool keys = true;

  void _toggle() => setState(() => keys = !keys);
  void _noop() {}
  int _needsYou() => 1;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final terminal = widget.tab == ChatWorkspaceTab.terminal;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !terminal) return;
      ChatWorkspacePaneScope.publish(
        context,
        ChatWorkspaceToolbar(
          keysShown: keys,
          onToggleKeys: _toggle,
          onHerdr: _noop,
          herdrNeedsYou: _needsYou,
          menu: [
            ChatWorkspaceMenuEntry(
              label: 'Editar credenciales',
              icon: Icons.edit_outlined,
              onSelected: _noop,
            ),
          ],
        ),
      );
    });
    final mono = TextStyle(
      fontFamily: 'JetBrainsMono',
      fontSize: 13,
      height: 1.5,
      color: colors.textPrimary,
    );
    return Scaffold(
      backgroundColor: colors.surface,
      body: terminal
          ? Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                  child: Row(
                    children: [
                      Icon(Icons.dns_outlined, color: colors.textSecondary),
                      const SizedBox(width: 8),
                      Text(
                        'xpeta@servidor:22 · Hermes',
                        style: TextStyle(color: colors.textSecondary),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colors.background,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: colors.divider),
                    ),
                    child: Text(
                      '\$ flutter test\n00:03 +51: All tests passed!\n'
                      '\$ git status -s\n M lib/core/models/session.dart',
                      style: mono,
                    ),
                  ),
                ),
              ],
            )
          : ListView(
              children: [
                for (final name in const [
                  'session.dart',
                  'ssh_commands.dart',
                  'session_model_test.dart',
                ])
                  ListTile(
                    title: Text(
                      name,
                      style: TextStyle(color: colors.textPrimary),
                    ),
                  ),
              ],
            ),
    );
  }
}

Future<ChatWorkspaceController> _pumpWorkspace(
  WidgetTester tester, {
  required Size size,
  required ThemeData theme,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  // A status bar, so the frame shows it stays below it (point 8).
  tester.view.padding = const FakeViewPadding(top: 24);
  addTearDown(tester.view.reset);
  final controller = ChatWorkspaceController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shot,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: theme,
        home: ChatWorkspaceHost(
          controller: controller,
          chat: const _SampleChat(),
          tabBuilder: (_, tab) => _SampleTab(tab),
          tabBadge: (tab) => tab == ChatWorkspaceTab.git ? 4 : null,
          navigation: GestureDockHost(
            actions: const {},
            rail: true,
            railAlignment: Alignment.center,
          ),
        ),
      ),
    ),
  );
  for (final tab in ChatWorkspaceTab.values.reversed) {
    controller.open(tab);
  }
  controller.open(ChatWorkspaceTab.terminal);
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  return controller;
}

void main() {
  setUpAll(() async {
    if (!_enabled) return;
    await _loadFonts();
    // The rail's items open sample places, so none is drawn disabled.
    GestureDockHost.debugPlace = (_, _) => const SizedBox();
    GestureDockHost.debugNewChat = () {};
  });

  final themes = {
    'light': AppTheme.hermesRedLight,
    'dark': AppTheme.hermesRedDark,
  };
  final devices = {
    'fold': const Size(933, 704),
    'tablet': const Size(1280, 800),
  };

  for (final device in devices.entries) {
    for (final theme in themes.entries) {
      final name = '${device.key}-${theme.key}';
      testWidgets('capture $name', tags: 'opt-in', skip: !_enabled, (
        tester,
      ) async {
        final c = await _pumpWorkspace(
          tester,
          size: device.value,
          theme: theme.value,
        );
        await _save(tester, '$name-split-term');

        c.activate(ChatWorkspaceTab.git);
        await tester.pump(const Duration(milliseconds: 400));
        await _save(tester, '$name-split-git');

        c.activate(ChatWorkspaceTab.terminal);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(
          find.byKey(const ValueKey('chat-workspace-layout-menu')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await _save(tester, '$name-menu');
        await tester.tapAt(const Offset(200, 400));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        c.setMode(ChatWorkspaceMode.workspace);
        await tester.pump(const Duration(milliseconds: 400));
        await _save(tester, '$name-ws');

        // Mock 136 v2-A: the bar is no longer folded by hand (only with the
        // keyboard up), so there is no «tools hidden» capture.
        c.setMode(ChatWorkspaceMode.split);
      });
    }
  }
}
