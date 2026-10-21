// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

// Guard the two route boundaries that are otherwise private implementation:
// the post-frame latch makes repeated scheduling harmless.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final editor = File(
    'lib/core/screens/instance_edit_screen.dart',
  ).readAsStringSync();

  test('R10: first sign-in is latched before the asynchronous route starts', () {
    expect(
      editor,
      contains(
        'if (!mounted || _signInFirstStarted) return;\n        _signInFirstStarted = true;',
      ),
    );
  });
}
