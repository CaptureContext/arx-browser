"""Child-offer reentrancy protects only the original native source."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from Scripts.engine.config import PACKAGE

class AdoptionScopeTests(unittest.TestCase):
    def test_nested_source_close_is_deferred_without_consuming_atomic_grants(self):
        source = r'''#include "adoption_scope.h"
#include <cassert>
int main() {
  arx::AdoptionScope scope;
  assert(!scope.Begin(0));
  assert(!scope.DeferDestroy(20));
  assert(scope.Begin(10));
  assert(scope.Begin(10));
  assert(scope.Begin(11));
  assert(scope.DeferDestroy(10));
  assert(!scope.End(11)); // unrelated child offer cannot release source 10
  assert(scope.Busy(10)); // authorized close must return busy before consumption
  assert(!scope.End(10));
  assert(scope.Busy(10));
  assert(scope.End(10)); // exactly one deferred explicit source destruction
  assert(!scope.Busy(10));
  assert(!scope.End(10));
  for (unsigned i=1;i<=16;++i) assert(scope.Begin(i));
  assert(!scope.Begin(17));
  assert(!scope.End(1));
  assert(scope.Begin(17)); // bounded resources recover after unwinding
  for (unsigned i=1;i<16;++i) assert(scope.Begin(17));
  assert(!scope.Begin(17));
  assert(scope.DeferDestroy(17));
  for (unsigned i=1;i<16;++i) assert(!scope.End(17));
  assert(scope.End(17));
}'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "test.cc").write_text(source)
            result = subprocess.run(["xcrun", "clang++", "-std=c++20", "-Wall", "-Werror",
                "-fsanitize=address,undefined", "-I", str(PACKAGE / "Native"),
                str(root / "test.cc"), "-o", str(root / "test")], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(root / "test")], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
