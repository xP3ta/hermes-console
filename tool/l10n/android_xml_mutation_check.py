#!/usr/bin/env python3
"""Disable each XML validator diagnostic in memory; its tests must fail."""

import io
import unittest
from unittest.mock import patch

import test_android_xml_parity


def main():
    original = test_android_xml_parity.check_resources
    guards = ('file', 'XML', 'root', 'name', 'duplicate', 'type', 'quantity',
              'other', 'empty', 'apostrophe', 'sigil', 'quote', 'missing',
              'extra', 'placeholders')
    for guard in guards:
        def without_guard(path, guard=guard):
            return [error for error in original(path) if f'[{guard}]' not in error]

        suite = unittest.defaultTestLoader.loadTestsFromModule(test_android_xml_parity)
        with patch.object(test_android_xml_parity, 'check_resources', without_guard):
            result = unittest.TextTestRunner(stream=io.StringIO()).run(suite)
        if result.wasSuccessful():
            print(f'SURVIVED: {guard}')
            return 1
        print(f'KILLED: {guard}')
    print(f'{len(guards)}/{len(guards)} Android XML guard mutants killed')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
