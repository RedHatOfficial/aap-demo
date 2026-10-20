"""Compatibility loader for the established hyphenated acceptance test files."""

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import sys
import unittest


_TEST_ROOT = Path(__file__).resolve().parent.parent


def load_tests(loader: unittest.TestLoader, tests: unittest.TestSuite, pattern: str) -> unittest.TestSuite:
    """Load acceptance tests whose historical filenames are not Python modules."""
    del tests, pattern
    suite = unittest.TestSuite()
    for test_file in sorted(_TEST_ROOT.glob("test-ao-acceptance-*.py")):
        module_name = f"_ao_acceptance_{test_file.stem.replace('-', '_')}"
        spec = spec_from_file_location(module_name, test_file)
        if spec is None or spec.loader is None:
            raise ImportError(f"cannot load acceptance test: {test_file}")
        module = module_from_spec(spec)
        sys.modules[module_name] = module
        spec.loader.exec_module(module)
        suite.addTests(loader.loadTestsFromModule(module))
    return suite
