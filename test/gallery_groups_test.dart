// «Galería»: which artifacts are pictures, the day each belongs to, and how
// they group by day and by conversation.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/chat_content_extractor.dart';
import 'package:hermes_android/core/services/gallery_groups.dart';
import 'package:hermes_android/core/services/global_artifacts.dart';

import 'support/fake_global_artifacts_source.dart';

GlobalArtifact _artifact(
  String session,
  String path, {
  ChatContentKind kind = ChatContentKind.image,
  DateTime? at,
  double sessionAt = 1000,
}) => GlobalArtifact(
  item: ChatContentItem(
    kind: kind,
    value: path,
    href: path,
    label: path.split('/').last,
    timestamp: at,
  ),
  session: fakeArtifactSession(session, at: sessionAt),
);

void main() {
  test('solo quedan las imágenes, en su orden', () {
    final all = [
      _artifact('a', '/out/uno.png'),
      _artifact('a', '/out/informe.pdf', kind: ChatContentKind.file),
      _artifact('b', 'https://x.test/p', kind: ChatContentKind.link),
      _artifact('b', '/out/dos.png'),
    ];
    expect(
      [for (final a in galleryImages(all)) a.item.label],
      ['uno.png', 'dos.png'],
    );
  });

  test('sin hora propia, la imagen toma la de su conversación', () {
    final own = _artifact('a', '/o/a.png', at: DateTime(2026, 3, 4, 10));
    final inherited = _artifact('a', '/o/b.png', sessionAt: 86400 * 365);
    expect(galleryTimeOf(own), DateTime(2026, 3, 4, 10));
    expect(
      galleryTimeOf(inherited),
      DateTime.fromMillisecondsSinceEpoch(86400 * 365 * 1000),
    );
  });

  test('agrupa por día natural conservando el orden', () {
    final images = [
      _artifact('a', '/o/1.png', at: DateTime(2026, 3, 4, 23, 50)),
      _artifact('b', '/o/2.png', at: DateTime(2026, 3, 4, 0, 5)),
      _artifact('a', '/o/3.png', at: DateTime(2026, 3, 3, 12)),
      _artifact('a', '/o/4.png', at: DateTime(2026, 2, 28, 8)),
    ];
    final days = groupGalleryByDay(images);
    expect(
      [for (final d in days) d.day],
      [DateTime(2026, 3, 4), DateTime(2026, 3, 3), DateTime(2026, 2, 28)],
    );
    expect([for (final d in days) d.items.length], [2, 1, 1]);
    expect(groupGalleryByDay(const []), isEmpty);
  });

  test('las conversaciones salen con su número de imágenes y filtran', () {
    final images = [
      _artifact('a', '/o/1.png', at: DateTime(2026, 3, 4)),
      _artifact('b', '/o/2.png', at: DateTime(2026, 3, 4)),
      _artifact('a', '/o/3.png', at: DateTime(2026, 3, 3)),
    ];
    final conversations = galleryConversations(images);
    expect([for (final c in conversations) c.session.id], ['a', 'b']);
    expect([for (final c in conversations) c.count], [2, 1]);
    expect(galleryInConversation(images, null), hasLength(3));
    expect(galleryInConversation(images, 'b').single.item.label, '2.png');
    expect(galleryInConversation(images, 'zzz'), isEmpty);
  });
}
