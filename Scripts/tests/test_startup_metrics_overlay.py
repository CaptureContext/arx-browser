"""Chrome's metrics-only TPM benchmark is compiled out on macOS (DEV-894)."""

from pathlib import Path
import re
import shutil
import tempfile
import unittest

from Scripts.engine import startup_metrics_overlay
from Scripts.engine.config import SOURCE, prepared_mismatch

FIXTURE = Path(__file__).parent / "fixtures/startup-metrics-overlay/chrome_browser_main_extra_parts_metrics.cc"


def prepare(root, origin=FIXTURE):
    target = root / startup_metrics_overlay.METRICS
    target.parent.mkdir(parents=True)
    shutil.copy2(origin, target)
    return target


def startup_metrics(source):
    """`PostBrowserStart`, which posts the benchmark since Chromium 157."""
    return re.search(r"void ChromeBrowserMainExtraPartsMetrics::PostBrowserStart\(\) \{\n.*?\n}\n",
                     source, re.S).group(0)


def mac_lines(body):
    """The lines of `body` the macOS preprocessor keeps (only the IS_MAC/IS_WIN guards this function uses)."""
    kept, stack = [], []
    for line in body.splitlines():
        directive = line.strip()
        if directive.startswith("#if"):
            stack.append("IS_MAC" in directive if "IS_WIN" in directive or "IS_MAC" in directive else True)
            continue
        if directive.startswith("#endif"):
            stack.pop()
            continue
        if directive.startswith("#else") or directive.startswith("#elif"):
            continue
        if all(stack):
            kept.append(line)
    return "\n".join(kept)


class StartupMetricsOverlayTests(unittest.TestCase):
    def test_tpm_benchmark_is_gone_on_mac_and_apply_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            target = prepare(Path(directory))
            self.assertIn("MaybeMeasureTpmOperations", mac_lines(startup_metrics(FIXTURE.read_text())))
            startup_metrics_overlay.apply(Path(directory))
            first = target.read_text()
            startup_metrics_overlay.apply(Path(directory))
            self.assertEqual(first, target.read_text())

            body = startup_metrics(first)
            self.assertNotIn("MaybeMeasureTpmOperations", mac_lines(body))
            # Windows keeps it; the rest of the startup metrics are untouched.
            self.assertEqual(body.count("&crypto::MaybeMeasureTpmOperations,"), 1)
            self.assertIn("#if BUILDFLAG(IS_WIN)\n  // Deliberately delayed", body)
            self.assertIn("metrics::BeginFirstWebContentsProfiling();", mac_lines(body))
            self.assertEqual(first.replace(startup_metrics_overlay.ARX_TPM, startup_metrics_overlay.TPM),
                             FIXTURE.read_text())

    def test_changed_anchor_fails_closed(self):
        for _, anchor, _ in startup_metrics_overlay.patches():
            lines = anchor.splitlines(keepends=True)
            for index, line in enumerate(lines):
                changed = "".join(lines[:index] + [line.rstrip("\n") + " // changed upstream\n"] + lines[index + 1:])
                with self.subTest(line=line), tempfile.TemporaryDirectory() as directory:
                    target = prepare(Path(directory))
                    target.write_text(target.read_text().replace(anchor, changed, 1))
                    with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                        startup_metrics_overlay.apply(Path(directory))

    @unittest.skipUnless((SOURCE / startup_metrics_overlay.METRICS).is_file(), "no prepared Chromium tree")
    def test_anchor_matches_the_prepared_chromium_tree(self):
        if mismatch := prepared_mismatch():
            self.skipTest(mismatch)
        with tempfile.TemporaryDirectory() as directory:
            target = prepare(Path(directory), origin=SOURCE / startup_metrics_overlay.METRICS)
            startup_metrics_overlay.apply(Path(directory))
            self.assertNotIn("MaybeMeasureTpmOperations", mac_lines(startup_metrics(target.read_text())))


if __name__ == "__main__":
    unittest.main()
