"""Execute the exact native one-use Escape admission policy, without browser input."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from Scripts.engine.config import PACKAGE


class UnhandledEscapeTests(unittest.TestCase):
    def test_original_event_generation_one_use_expiry_and_supersession(self):
        source = r'''
#include "unhandled_escape_authority.h"
#include <cassert>
int main() {
  arx::UnhandledEscapeAuthority proof;
  assert(!proof.Consume(1, 1, 10));
  proof.Observe(1, 2, 10);
  assert(!proof.Consume(2, 2, 11)); // foreign ACK cannot erase current key
  assert(proof.Consume(1, 2, 11));
  assert(!proof.Consume(1, 2, 11)); // replay
  proof.Observe(1, 2, 10);
  assert(!proof.Consume(1, 3, 11)); // navigation before renderer's ACK
  assert(!proof.Consume(1, 2, 11));
  proof.Observe(1, 2, 10);
  assert(!proof.Consume(1, 2, 9)); // impossible clock reversal
  proof.Observe(1, 2, 10);
  assert(!proof.Consume(1, 2, 5011));
  proof.Observe(1, 2, 10);
  assert(proof.Consume(1, 2, 5010));
  proof.Observe(1, 2, 10);
  proof.Observe(2, 2, 11);
  assert(!proof.Consume(1, 2, 12)); // newer physical event supersedes old ACK
  assert(proof.Consume(2, 2, 12));
  proof.Observe(1, 2, 10);
  proof.Clear();
  assert(!proof.Consume(1, 2, 11)); // host navigation/crash/document teardown
  proof.Observe(1, 0, 10);
  assert(!proof.Consume(1, 0, 11)); // exhausted generation
  proof.Observe(0, 2, 10);
  assert(!proof.Consume(0, 2, 11)); // missing native event
}'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "test.cc").write_text(source)
            result = subprocess.run([
                "xcrun", "clang++", "-std=c++20", "-Wall", "-Werror",
                "-fsanitize=address,undefined", "-I", str(PACKAGE / "Native"),
                str(root / "test.cc"), "-o", str(root / "test"),
            ], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(root / "test")], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
