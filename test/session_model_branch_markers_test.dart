import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';

Map<String, dynamic> _row(Map<String, dynamic> extra) => {
  'id': 's1',
  'started_at': 1,
  ...extra,
};

void main() {
  test('parses _branched_from and _reset_from', () {
    final session = Session.fromJson(
      _row({'_branched_from': 'parent-a', '_reset_from': 'old-b'}),
    );
    expect(session.branchedFromId, 'parent-a');
    expect(session.resetFromId, 'old-b');
  });

  test('null or missing markers are absent', () {
    final nulls = Session.fromJson(
      _row({'_branched_from': null, '_reset_from': null}),
    );
    expect(nulls.branchedFromId, isNull);
    expect(nulls.resetFromId, isNull);
    final missing = Session.fromJson(_row({}));
    expect(missing.branchedFromId, isNull);
    expect(missing.resetFromId, isNull);
  });

  test('markers are bounded opaque ids', () {
    final session = Session.fromJson(
      _row({'_branched_from': 12, '_reset_from': 'x' * 5000}),
    );
    expect(session.branchedFromId, isNull);
    expect(session.resetFromId?.length ?? 0, lessThanOrEqualTo(512));
  });

  test('copyWith keeps the markers', () {
    final session = Session.fromJson(_row({'_branched_from': 'p'}));
    expect(session.copyWith(title: 'x').branchedFromId, 'p');
  });
}
