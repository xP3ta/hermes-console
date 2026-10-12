// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Records actual HTTP dispatch, not a removed service's unused DI seam.
/// All values stored here are method/path only: no credentials or raw URLs.
class OfficialHttpAudit {
  final requests = <String>[];
  List<String> get calls => requests
      .where(
        (request) => request.contains('/bridge/') || request.contains('/fs/'),
      )
      .toList();

  MockClient client(FutureOr<http.Response> Function(http.Request) handler) =>
      MockClient((request) async {
        requests.add('${request.method} ${request.url.path}');
        return await handler(request);
      });
}
