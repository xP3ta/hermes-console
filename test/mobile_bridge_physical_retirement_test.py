# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Hermes Console contributors
"""Executable source boundary: the optional Mobile Bridge is not a client dependency."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXCLUSIVE = [
    'lib/core/screens/bridge_config_screen.dart',
    *[f'lib/core/services/{name}.dart' for name in (
        'bridge_client', 'bridge_endpoint_resolver', 'bridge_manager',
        'bridge_release_channel', 'bridge_token_cache', 'bridge_update_service',
        'bridge_version', 'remote_bridge_installer',
    )],
    'lib/core/services/agent_runtime/agent_runtime.dart',
]


class PhysicalRetirement(unittest.TestCase):
    def test_exclusive_implementation_is_physically_absent(self):
        self.assertEqual([p for p in EXCLUSIVE if (ROOT / p).exists()], [])

    def test_dart_imports_and_exports_do_not_depend_on_retired_service(self):
        violations = []
        for tree in ('lib', 'test'):
            for path in (ROOT / tree).rglob('*.dart'):
                source = re.sub(r'/\*.*?\*/|^\s*//[^\n]*', '',
                                path.read_text(), flags=re.S | re.M)
                for uri in re.findall(r'^\s*(?:import|export)\s+[\'"]([^\'"]+)',
                                      source, re.M):
                    name = pathlib.PurePosixPath(uri).name
                    if name.startswith('bridge_') or name == 'remote_bridge_installer.dart':
                        violations.append(f'{path.relative_to(ROOT)}:{uri}')
        self.assertEqual(violations, [])


if __name__ == '__main__':
    unittest.main()
