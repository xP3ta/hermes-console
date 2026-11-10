// What «Artefactos» says about each item: the type of a file, where it
// lives, and the files grouped by type.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/chat_content_extractor.dart';
import 'package:hermes_android/core/services/chat_content_presentation.dart';

ChatContentItem _file(String value, {String? label}) => ChatContentItem(
  kind: ChatContentKind.file,
  value: value,
  href: value,
  label: label ?? value.split(RegExp(r'[\\/]')).last,
);

void main() {
  test('a file says what it is by its extension', () {
    expect(
      chatContentFileType(_file('/o/informe.PDF')),
      ChatContentFileType.pdf,
    );
    expect(
      chatContentFileType(_file('/o/a.docx')),
      ChatContentFileType.document,
    );
    expect(
      chatContentFileType(_file('/o/a.csv')),
      ChatContentFileType.spreadsheet,
    );
    expect(
      chatContentFileType(_file('/o/a.pptx')),
      ChatContentFileType.presentation,
    );
    expect(chatContentFileType(_file('/o/a.zip')), ChatContentFileType.archive);
    expect(chatContentFileType(_file('/o/app.apk')), ChatContentFileType.app);
    expect(chatContentFileType(_file('/o/v.opus')), ChatContentFileType.audio);
    expect(chatContentFileType(_file('/o/v.mp4')), ChatContentFileType.video);
    expect(chatContentFileType(_file('/o/n.md')), ChatContentFileType.text);
    expect(chatContentFileType(_file('/o/d.json')), ChatContentFileType.data);
    expect(chatContentFileType(_file('/o/s.py')), ChatContentFileType.code);
    expect(chatContentFileType(_file('/o/blob')), ChatContentFileType.other);
    expect(chatContentExtension(_file('/o/informe.PDF')), 'pdf');
    expect(chatContentExtension(_file('/o/blob')), '');
  });

  test('a file lives in its folder; a link at its host and path', () {
    expect(chatContentLocation(_file('/srv/out/informe.pdf')), '/srv/out');
    expect(chatContentLocation(_file('/informe.pdf')), '/');
    expect(chatContentLocation(_file('~/x.pdf')), '~');
    expect(chatContentLocation(_file(r'C:\Users\a\x.pdf')), r'C:\Users\a');
    expect(
      chatContentLocation(_file('https://www.cdn.example/files/q3/a.pdf')),
      'cdn.example/files/q3',
    );
    expect(chatContentLocation(_file('file:///tmp/a%20b/x.pdf')), '/tmp/a b');
    expect(chatContentLocation(_file('x.pdf')), isNull);
    expect(
      chatContentLocation(
        const ChatContentItem(
          kind: ChatContentKind.image,
          value: 'data:image/png;base64,AAAA',
          href: 'data:image/png;base64,AAAA',
          label: 'data:image/png;base64',
        ),
      ),
      isNull,
    );
    expect(
      chatContentLocation(
        const ChatContentItem(
          kind: ChatContentKind.link,
          value: 'https://www.example.com/docs/guia/',
          href: 'https://www.example.com/docs/guia/',
          label: 'guia',
        ),
      ),
      'example.com/docs/guia',
    );
  });

  test('files group by type in a fixed order, newest first inside', () {
    final groups = groupChatContentFiles([
      _file('/o/b.zip'),
      _file('/o/new.pdf'),
      _file('/o/app.apk'),
      _file('/o/old.pdf'),
    ]);
    expect(groups.map((g) => g.$1), [
      ChatContentFileType.pdf,
      ChatContentFileType.archive,
      ChatContentFileType.app,
    ]);
    expect(groups.first.$2.map((f) => f.label), ['new.pdf', 'old.pdf']);
  });
}
