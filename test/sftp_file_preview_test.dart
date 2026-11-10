import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/sftp_file_preview_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/artifact_viewer/artifact_viewer_screen.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Uint8List _text(String s) => Uint8List.fromList(utf8.encode(s));

Widget _app(
  Widget child, {
  ThemeData? theme,
  double textScale = 1,
}) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: const [
    Strings.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: Strings.supportedLocales,
  theme: theme ?? AppTheme.hermesRedDark,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: home!,
  ),
  home: child,
);

/// Records every read and answers with [bytes] (or throws [error]).
class _Reader {
  _Reader(this.bytes, {this.error});

  final Uint8List bytes;
  final Object? error;
  final List<int?> reads = [];

  Future<Uint8List> call(int? maxBytes) async {
    reads.add(maxBytes);
    if (error != null) throw error!;
    if (maxBytes != null && bytes.length > maxBytes) {
      return Uint8List.sublistView(bytes, 0, maxBytes);
    }
    return bytes;
  }
}

void _narrow(WidgetTester tester) {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  group('sftpLooksBinary (Desktop looksBinary)', () {
    test('text, tabs and newlines are not binary', () {
      expect(sftpLooksBinary(_text('hello\tworld\r\nline 2\n')), isFalse);
      expect(sftpLooksBinary(Uint8List(0)), isFalse);
    });

    test('a NUL byte is binary', () {
      expect(sftpLooksBinary(Uint8List.fromList([72, 0, 73])), isTrue);
    });

    test('more than 12% other control bytes is binary', () {
      // 13 control bytes in 100 = 13%.
      final bytes = Uint8List.fromList([
        ...List.filled(13, 1),
        ...List.filled(87, 65),
      ]);
      expect(sftpLooksBinary(bytes), isTrue);
      final fine = Uint8List.fromList([
        ...List.filled(12, 1),
        ...List.filled(88, 65),
      ]);
      expect(sftpLooksBinary(fine), isFalse);
    });

    test('only the first 4096 bytes are sniffed', () {
      final bytes = Uint8List.fromList([
        ...List.filled(4096, 65),
        ...List.filled(100, 0),
      ]);
      expect(sftpLooksBinary(bytes), isFalse);
    });
  });

  group('SftpFilePreviewScreen (gap 3)', () {
    testWidgets('a small text file opens in the viewer, read up to 512 KB', (
      tester,
    ) async {
      _narrow(tester);
      final reader = _Reader(_text('name: hermes\n'));
      await tester.pumpWidget(
        _app(
          SftpFilePreviewScreen(
            name: 'config.yaml',
            size: 13,
            read: reader.call,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(reader.reads, [sftpPreviewMaxBytes]);
      expect(
        find.byKey(const ValueKey('sftp-preview-viewer')),
        findsOneWidget,
      );
      expect(find.byType(ArtifactViewerScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a large file warns first; Preview anyway reads 512 KB', (
      tester,
    ) async {
      _narrow(tester);
      final reader = _Reader(_text('x' * 1000));
      var downloads = 0;
      await tester.pumpWidget(
        _app(
          SftpFilePreviewScreen(
            name: 'app.log',
            size: 2 * 1024 * 1024,
            read: reader.call,
            onDownload: () => downloads++,
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('sftp-preview-large')), findsOneWidget);
      expect(find.text('This file is large'), findsOneWidget);
      expect(
        find.text('app.log is 2.0 MB. Hermes will only show the first 512 KB.'),
        findsOneWidget,
      );
      expect(reader.reads, isEmpty);

      await tester.tap(find.text('Download'));
      expect(downloads, 1);

      await tester.tap(find.text('Preview anyway'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(reader.reads, [sftpPreviewMaxBytes]);
      expect(
        find.byKey(const ValueKey('sftp-preview-viewer')),
        findsOneWidget,
      );
    });

    testWidgets('a binary file warns; Preview anyway shows it as text', (
      tester,
    ) async {
      _narrow(tester);
      final reader = _Reader(Uint8List.fromList([0x7F, 0x45, 0, 0, 1, 2]));
      await tester.pumpWidget(
        _app(SftpFilePreviewScreen(name: 'tool', size: 6, read: reader.call)),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('sftp-preview-binary')), findsOneWidget);
      expect(find.text('This looks like a binary file'), findsOneWidget);
      expect(
        find.text('Previewing tool may show unreadable text.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Preview anyway'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const ValueKey('sftp-preview-viewer')),
        findsOneWidget,
      );
      // No second read: the bytes already loaded are shown.
      expect(reader.reads, hasLength(1));
    });

    testWidgets('images are read whole and skip the binary sniff', (
      tester,
    ) async {
      _narrow(tester);
      final reader = _Reader(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0]));
      await tester.pumpWidget(
        _app(
          SftpFilePreviewScreen(
            name: 'shot.png',
            size: 2 * 1024 * 1024,
            read: reader.call,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(reader.reads, [null]);
      expect(find.byKey(const ValueKey('sftp-preview-binary')), findsNothing);
      expect(find.byKey(const ValueKey('sftp-preview-large')), findsNothing);
      expect(
        find.byKey(const ValueKey('sftp-preview-viewer')),
        findsOneWidget,
      );
    });

    testWidgets('a read error says why, with Close', (tester) async {
      _narrow(tester);
      final reader = _Reader(
        Uint8List(0),
        error: SftpStatusError(
          SftpStatusCode.permissionDenied,
          'Permission denied',
        ),
      );
      await tester.pumpWidget(
        _app(
          SftpFilePreviewScreen(name: 'secret', size: 10, read: reader.call),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('sftp-preview-unavailable')),
        findsOneWidget,
      );
      expect(find.text('Preview unavailable'), findsOneWidget);
      expect(find.text('Permission denied.'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
    });

    testWidgets('opened from a chat: the notch returns there', (
      tester,
    ) async {
      _narrow(tester);
      var back = 0;
      await tester.pumpWidget(
        _app(
          SftpFilePreviewScreen(
            name: 'big.log',
            size: 4 * 1024 * 1024,
            read: _Reader(Uint8List(0)).call,
            onBackToChat: () => back++,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('sftp-preview-notch')));
      expect(back, 1);
    });

    testWidgets('no notch when not opened from a chat', (tester) async {
      _narrow(tester);
      await tester.pumpWidget(
        _app(
          SftpFilePreviewScreen(
            name: 'big.log',
            size: 4 * 1024 * 1024,
            read: _Reader(Uint8List(0)).call,
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('sftp-preview-notch')), findsNothing);
    });

    for (final entry in {
      'dark': AppTheme.hermesRedDark,
      'light': AppTheme.hermesRedLight,
    }.entries) {
      testWidgets('${entry.key} theme at 2x on 412 dp: no overflow', (
        tester,
      ) async {
        _narrow(tester);
        await tester.pumpWidget(
          _app(
            SftpFilePreviewScreen(
              name: 'a-rather-long-file-name-for-a-narrow-screen.log',
              size: 4 * 1024 * 1024,
              read: _Reader(Uint8List(0)).call,
              onDownload: () {},
              onBackToChat: () {},
            ),
            theme: entry.value,
            textScale: 2,
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('sftp-preview-large')),
          findsOneWidget,
        );
      });
    }
  });
}
