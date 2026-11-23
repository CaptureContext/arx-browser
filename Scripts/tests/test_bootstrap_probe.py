"""Exercise the host-only entry probe in fresh native processes, without Chromium."""

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

from Scripts.core.paths import ROOT


class BootstrapProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="arx-bootstrap-test-")
        root = Path(cls.directory.name)
        cls.binary = root / "probe"
        fixture = root / "main.c"
        fixture.write_text('''
#include "ChromiumBootstrap.h"
#include <pthread.h>
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static void *worker(void *unused) {
  (void)unused;
  pthread_mutex_lock(&lock);
  pthread_mutex_unlock(&lock);
  return 0;
}
int main(int argc, char **argv) {
  (void)argv;
  pthread_t thread;
  if (argc > 1) {
    pthread_mutex_lock(&lock);
    if (pthread_create(&thread, 0, worker, 0)) return 1;
  }
  ArxReportBootstrapEntryForSmoke();
  if (argc > 1) {
    pthread_mutex_unlock(&lock);
    pthread_join(thread, 0);
  }
  return 0;
}
''')
        source = ROOT / "Packages/engine/Sources/ChromiumBootstrap"
        subprocess.run([
            "xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
            "-mmacosx-version-min=27.0", "-I", str(source / "include"),
            str(source / "ChromiumBootstrap.c"), str(fixture), "-o", str(cls.binary),
        ], check=True, capture_output=True, text=True, timeout=60)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def run_probe(self, title, threaded=False):
        environment = os.environ.copy()
        environment.pop("ARX_ENGINE_SMOKE_TITLE", None)
        if title is not None:
            environment["ARX_ENGINE_SMOKE_TITLE"] = title
        return subprocess.run(
            [str(self.binary), *(["threaded"] if threaded else [])], env=environment,
            capture_output=True, text=True, check=True, timeout=5,
        )

    def test_ordinary_and_empty_environment_emit_nothing(self):
        for title in [None, ""]:
            with self.subTest(title=title):
                result = self.run_probe(title)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "")

    def test_smoke_reports_actual_single_and_multiple_threads(self):
        for threaded in [False, True]:
            with self.subTest(threaded=threaded):
                result = self.run_probe("fixture", threaded)
                match = re.fullmatch(
                    r"ARX_BOOTSTRAP_ENTRY threads=(\d+) main=1 zones=(\d+) "
                    r"threadStatus=0 zoneStatus=0 defaultZone=([^\n]+)\n", result.stderr,
                )
                self.assertIsNotNone(match, result.stderr)
                if threaded:
                    self.assertGreaterEqual(int(match[1]), 2)
                else:
                    self.assertEqual(int(match[1]), 1)
                self.assertGreater(int(match[2]), 0)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
