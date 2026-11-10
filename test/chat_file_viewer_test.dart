import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/project_files.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/chat_file_path_policy.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_viewer_screen.dart';
import 'package:hermes_android/core/widgets/chat/chat_file_loader.dart';
import 'package:hermes_android/core/widgets/chat/chat_file_viewer_screen.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'chat_file_loader_test.dart' show FakeFiles;
import 'support/fake_webview_platform.dart';

Widget _host(Widget child, {double textScale = 1}) => MaterialApp(
  theme: AppTheme.fromMode(AppThemeMode.dark),
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: home!,
  ),
  home: child,
);

ChatFileViewerScreen _viewer(
  FakeFiles files,
  String raw, {
  String? name,
  String cwd = '/srv/p',
  int? line,
  int? endLine,
  VoidCallback? onOpenFolder,
}) => ChatFileViewerScreen(
  name: name ?? raw.split('/').last,
  path: raw.startsWith('/') ? raw : '$cwd/$raw',
  line: line,
  endLine: endLine,
  onOpenFolder: onOpenFolder,
  load: ({required confirmed}) => loadChatFile(
    files: files,
    resolution: chatResolveFilePath(raw, cwd: cwd),
    roots: [cwd],
    askedRelative: !raw.startsWith('/'),
    confirmedSensitive: confirmed,
  ),
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
  }
}

String _lines(int n) => [for (var i = 1; i <= n; i++) 'linea $i'].join('\n');

void main() {
  late FakeWebViewPlatform webPlatform;

  setUp(() {
    webPlatform = FakeWebViewPlatform();
    WebViewPlatform.instance = webPlatform;
  });

  testWidgets('it shows a spinner, then the Markdown rendered', (tester) async {
    final files = FakeFiles(
      files: {
        '/srv/p/push.md':
            '# Título\n\nUn [enlace](https://example.com/a) y `codigo`.\n\n'
            '```dart\nfinal x = 1;\n```\n',
      },
    );
    await tester.pumpWidget(_host(_viewer(files, 'push.md')));
    expect(find.byKey(const ValueKey('chat-file-loading')), findsOneWidget);
    await _settle(tester);
    expect(find.byType(ArtifactViewerScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('artifact-viewer-markdown')), findsOne);
    expect(find.textContaining('Título', findRichText: true), findsWidgets);
    expect(find.textContaining('enlace', findRichText: true), findsWidgets);
    expect(
      find.textContaining('final x = 1;', findRichText: true),
      findsWidgets,
    );
    expect(find.byKey(const ValueKey('artifact-viewer-text')), findsNothing);
  });

  testWidgets('the switch shows the source and back', (tester) async {
    final files = FakeFiles(files: {'/srv/p/push.md': '# Título\n\ncuerpo\n'});
    await tester.pumpWidget(_host(_viewer(files, 'push.md')));
    await _settle(tester);
    await tester.tap(
      find.byKey(const ValueKey('artifact-viewer-source-toggle')),
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('artifact-viewer-text')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('artifact-viewer-markdown')),
      findsNothing,
    );
    expect(find.textContaining('# Título', findRichText: true), findsWidgets);
    await tester.tap(
      find.byKey(const ValueKey('artifact-viewer-source-toggle')),
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('artifact-viewer-markdown')), findsOne);
  });

  testWidgets('code shows with line numbers', (tester) async {
    final files = FakeFiles(files: {'/srv/p/lib/a.dart': 'void main() {}\n'});
    await tester.pumpWidget(_host(_viewer(files, 'lib/a.dart')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('artifact-viewer-text')), findsOneWidget);
    expect(find.byKey(const ValueKey('artifact-viewer-gutter-0')), findsOne);
  });

  testWidgets('a line opens highlighted and scrolled into view', (
    tester,
  ) async {
    final files = FakeFiles(files: {'/srv/p/lib/a.dart': _lines(300)});
    await tester.pumpWidget(
      _host(_viewer(files, 'lib/a.dart', line: 220, endLine: 222)),
    );
    await _settle(tester);
    for (final index in [219, 220, 221]) {
      expect(
        find.byKey(ValueKey('artifact-viewer-marked-$index')),
        findsOneWidget,
        reason: 'line ${index + 1}',
      );
    }
    expect(
      find.byKey(const ValueKey('artifact-viewer-marked-222')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('artifact-viewer-marked-218')),
      findsNothing,
    );
  });

  testWidgets('a Markdown file with a line opens as source', (tester) async {
    final files = FakeFiles(files: {'/srv/p/n.md': _lines(40)});
    await tester.pumpWidget(_host(_viewer(files, 'n.md', line: 5)));
    await _settle(tester);
    expect(find.byKey(const ValueKey('artifact-viewer-text')), findsOneWidget);
    expect(find.byKey(const ValueKey('artifact-viewer-marked-4')), findsOne);
  });

  testWidgets('HTML is shown as text and nothing runs', (tester) async {
    final files = FakeFiles(
      files: {
        '/srv/p/page.html': '<h1>Hola</h1><script>alert(1)</script>',
        '/srv/p/logo.svg': '<svg><script>alert(2)</script></svg>',
      },
    );
    for (final name in ['page.html', 'logo.svg']) {
      await tester.pumpWidget(_host(_viewer(files, name)));
      await _settle(tester);
      expect(find.byType(WebViewWidget), findsNothing, reason: name);
      expect(webPlatform.controllers, isEmpty, reason: name);
      expect(
        find.byKey(const ValueKey('artifact-viewer-webview')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('artifact-viewer-text')),
        findsOneWidget,
      );
      expect(find.textContaining('<script>', findRichText: true), findsWidgets);
      // There is no switch to a rendered page.
      expect(
        find.byKey(const ValueKey('artifact-viewer-source-toggle')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('raw HTML inside Markdown is not run', (tester) async {
    final files = FakeFiles(
      files: {'/srv/p/x.md': 'hola <script>alert(1)</script> fin\n'},
    );
    await tester.pumpWidget(_host(_viewer(files, 'x.md')));
    await _settle(tester);
    expect(find.byType(WebViewWidget), findsNothing);
    expect(webPlatform.controllers, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty file says so', (tester) async {
    final files = FakeFiles(files: {'/srv/p/a.txt': ''});
    await tester.pumpWidget(_host(_viewer(files, 'a.txt')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('artifact-viewer-notice')),
      findsOneWidget,
    );
    expect(find.text('El archivo está vacío.'), findsOneWidget);
  });

  testWidgets('a cut file says so', (tester) async {
    final files = FakeFiles(
      files: {'/srv/p/a.txt': _lines(10)},
      truncated: {'/srv/p/a.txt'},
    );
    await tester.pumpWidget(_host(_viewer(files, 'a.txt')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('artifact-viewer-notice')),
      findsOneWidget,
    );
  });

  testWidgets('a large file is shown by pieces with a notice', (tester) async {
    final big = List.filled(
      artifactViewerInitialRenderBytes ~/ 6 + 5000,
      'linea\n',
    ).join();
    final files = FakeFiles(files: {'/srv/p/big.log': big});
    await tester.pumpWidget(_host(_viewer(files, 'big.log')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('artifact-viewer-truncated')), findsOne);
    expect(find.byKey(const ValueKey('artifact-viewer-show-all')), findsOne);
  });

  testWidgets('an image opens in the image viewer', (tester) async {
    final files = FakeFiles(
      images: {
        '/srv/p/a.png': Uint8List.fromList([1, 2, 3]),
      },
    );
    await tester.pumpWidget(_host(_viewer(files, 'a.png')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('artifact-viewer-image')), findsOneWidget);
  });

  group('errors', () {
    testWidgets('not found says so, with retry and copy path', (tester) async {
      final files = FakeFiles();
      await tester.pumpWidget(_host(_viewer(files, 'push.md')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('chat-file-error')), findsOneWidget);
      expect(find.textContaining('No se encuentra el archivo'), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
      expect(find.text('Copiar ruta'), findsOneWidget);
    });

    testWidgets('retry reads again and shows the file', (tester) async {
      final files = FakeFiles();
      await tester.pumpWidget(_host(_viewer(files, 'push.md')));
      await _settle(tester);
      expect(files.reads, ['/srv/p/push.md']);
      files.files['/srv/p/push.md'] = 'ya está';
      await tester.tap(find.text('Reintentar'));
      await _settle(tester);
      expect(files.reads, ['/srv/p/push.md', '/srv/p/push.md']);
      expect(find.byType(ArtifactViewerScreen), findsOneWidget);
    });

    testWidgets('copy path copies the absolute path', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final files = FakeFiles();
      await tester.pumpWidget(_host(_viewer(files, 'push.md')));
      await _settle(tester);
      await tester.tap(find.text('Copiar ruta'));
      await tester.pump();
      expect(copied, ['/srv/p/push.md']);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('each reason has its own words', (tester) async {
      final cases = <Object, String>{
        const DesktopControlFailure(
          DesktopControlFailureKind.forbidden,
          code: 403,
        ): 'El servidor no permite leer este archivo.',
        const DesktopControlFailure(
          DesktopControlFailureKind.rejected,
          code: 422,
        ): 'El servidor ha rechazado esta ruta.',
        const DesktopControlFailure(
          DesktopControlFailureKind.unavailable,
          code: 413,
        ): 'El archivo es demasiado grande para verlo aquí.',
        const DesktopControlFailure(DesktopControlFailureKind.unsupported):
            'Este servidor no permite leer archivos.',
      };
      for (final entry in cases.entries) {
        final files = FakeFiles(failures: {'/srv/p/a.md': entry.key});
        await tester.pumpWidget(_host(_viewer(files, 'a.md')));
        await _settle(tester);
        expect(find.text(entry.value), findsOneWidget, reason: entry.value);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('binary and the path that is not valid', (tester) async {
      final files = FakeFiles(
        files: {'/srv/p/a.bin': 'x'},
        binary: {'/srv/p/a.bin'},
      );
      await tester.pumpWidget(_host(_viewer(files, 'a.bin')));
      await _settle(tester);
      expect(find.textContaining('archivo binario'), findsOneWidget);
      // Nothing to retry for a binary file.
      expect(find.text('Reintentar'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_host(_viewer(files, 'file:///etc/passwd')));
      await _settle(tester);
      expect(find.textContaining('no es válida'), findsOneWidget);
      expect(files.reads.where((r) => r.contains('passwd')), isEmpty);
    });

    testWidgets('large text (2x) still fits', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final files = FakeFiles();
      await tester.pumpWidget(_host(_viewer(files, 'push.md'), textScale: 2));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Reintentar'), findsOneWidget);
    });
  });

  group('sensitive files', () {
    testWidgets('they ask first and read nothing until the yes', (
      tester,
    ) async {
      final files = FakeFiles(files: {'/srv/p/.env': 'TOKEN=abc'});
      await tester.pumpWidget(_host(_viewer(files, '.env')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('chat-file-confirm')), findsOneWidget);
      expect(find.text('Archivo sensible'), findsOneWidget);
      expect(find.textContaining('TOKEN'), findsNothing);
      expect(files.reads, isEmpty);
      await tester.tap(find.text('Mostrar'));
      await _settle(tester);
      expect(files.reads, ['/srv/p/.env']);
      expect(
        find.textContaining('TOKEN=abc', findRichText: true),
        findsWidgets,
      );
    });

    testWidgets('cancelling leaves without reading', (tester) async {
      final files = FakeFiles(files: {'/srv/p/id_rsa': 'KEY'});
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(builder: (_) => _viewer(files, 'id_rsa')),
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('chat-file-confirm')), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('chat-file-confirm')), findsNothing);
      expect(files.reads, isEmpty);
    });
  });

  group('sharing', () {
    testWidgets('a secret has no share on a phone; a text file has', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final files = FakeFiles(
        files: {'/srv/p/.env': 'TOKEN=abc', '/srv/p/a.txt': 'hola'},
      );
      await tester.pumpWidget(_host(_viewer(files, 'a.txt')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('artifact-viewer-actions')), findsOne);
      expect(find.byKey(const ValueKey('artifact-viewer-share')), findsOne);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_host(_viewer(files, '.env')));
      await _settle(tester);
      await tester.tap(find.text('Mostrar'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('artifact-viewer-actions')), findsOne);
      expect(find.byKey(const ValueKey('artifact-viewer-copy')), findsOne);
      expect(find.byKey(const ValueKey('artifact-viewer-share')), findsNothing);
      // Held in memory: there is no file behind the viewer.
      expect(
        tester
            .widget<ArtifactViewerScreen>(find.byType(ArtifactViewerScreen))
            .file,
        isNull,
      );
    });
  });

  group('menu', () {
    testWidgets('copy path and open folder', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      var folder = 0;
      final files = FakeFiles(files: {'/srv/p/docs/a.md': 'hola'});
      await tester.pumpWidget(
        _host(_viewer(files, 'docs/a.md', onOpenFolder: () => folder++)),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('artifact-viewer-menu')));
      await _settle(tester);
      expect(find.text('Copiar'), findsOneWidget);
      expect(find.text('Copiar ruta'), findsOneWidget);
      await tester.tap(find.text('Copiar ruta'));
      await _settle(tester);
      expect(copied, ['/srv/p/docs/a.md']);
      await tester.tap(find.byKey(const ValueKey('artifact-viewer-menu')));
      await _settle(tester);
      await tester.tap(find.text('Abrir carpeta'));
      await _settle(tester);
      expect(folder, 1);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('copy content copies the text', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final files = FakeFiles(files: {'/srv/p/a.md': 'contenido'});
      await tester.pumpWidget(_host(_viewer(files, 'a.md')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('artifact-viewer-menu')));
      await _settle(tester);
      await tester.tap(find.text('Copiar'));
      await _settle(tester);
      expect(copied, ['contenido']);
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('folders', () {
    testWidgets('a secret in a folder asks before it is read', (tester) async {
      final files = _Listing({
        '/home/a/.ssh': [
          const ProjectFsEntry(
            name: 'id_rsa',
            path: '/home/a/.ssh/id_rsa',
            isDirectory: false,
          ),
          const ProjectFsEntry(
            name: 'page.html',
            path: '/home/a/.ssh/page.html',
            isDirectory: false,
          ),
        ],
      });
      await tester.pumpWidget(
        _host(ChatFolderScreen(files: files, root: '/home/a/.ssh')),
      );
      await _settle(tester);
      await tester.tap(find.text('id_rsa'));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('chat-file-confirm')), findsOneWidget);
      expect(files.reads, isEmpty, reason: 'nothing is read before the yes');
      await tester.tap(find.text('Cancelar'));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 500));
      expect(files.reads, isEmpty);
    });

    testWidgets('an HTML file of a folder is not rendered', (tester) async {
      final files = _Listing({
        '/srv/p': [
          const ProjectFsEntry(
            name: 'page.html',
            path: '/srv/p/page.html',
            isDirectory: false,
          ),
        ],
      });
      await tester.pumpWidget(
        _host(ChatFolderScreen(files: files, root: '/srv/p')),
      );
      await _settle(tester);
      await tester.tap(find.text('page.html'));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 500));
      expect(files.reads, ['/srv/p/page.html']);
      expect(find.byType(WebViewWidget), findsNothing);
      expect(webPlatform.controllers, isEmpty);
      expect(find.byKey(const ValueKey('artifact-viewer-text')), findsOne);
    });

    testWidgets('a folder opens in the explorer', (tester) async {
      final files = _Listing({
        '/srv/p/docs': [
          const ProjectFsEntry(
            name: 'notas.md',
            path: '/srv/p/docs/notas.md',
            isDirectory: false,
          ),
          const ProjectFsEntry(
            name: 'img',
            path: '/srv/p/docs/img',
            isDirectory: true,
          ),
        ],
      });
      await tester.pumpWidget(
        _host(
          ChatFolderScreen(
            files: files,
            root: '/srv/p',
            initialPath: '/srv/p/docs',
          ),
        ),
      );
      await _settle(tester);
      expect(files.listed, contains('/srv/p/docs'));
      expect(find.text('notas.md'), findsOneWidget);
      expect(find.text('img'), findsOneWidget);
    });
  });
}

class _Listing implements HermesProjectFilesGateway {
  _Listing(this.entries);

  final Map<String, List<ProjectFsEntry>> entries;
  final List<String> listed = [];
  final List<String> reads = [];

  @override
  bool get projectFilesKnownUnsupported => false;

  @override
  Future<ProjectDirectoryListing> listProjectDirectory(String path) async {
    listed.add(path);
    return ProjectDirectoryListing(entries: entries[path] ?? const []);
  }

  @override
  Future<ProjectFilePreview> readProjectFileText(String path) async {
    reads.add(path);
    return ProjectFilePreview(
      path: path,
      text: '<script>alert(1)</script>',
      binary: false,
      truncated: false,
      byteSize: 25,
      mimeType: 'text/html',
    );
  }

  @override
  Future<Uint8List> readProjectFileBytes(String path) =>
      throw UnimplementedError();
}
