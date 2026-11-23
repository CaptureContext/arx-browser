"""Tests that read the prepared Chromium tree skip when it was prepared from another lock."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from Scripts.engine import config


class PreparedMismatchTests(unittest.TestCase):
    def mismatch(self, stamp):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            if stamp is not None:
                (work / "prepared.json").write_text(json.dumps(stamp))
            with patch.object(config, "WORK", work):
                return config.prepared_mismatch()

    def test_a_tree_prepared_from_the_lock_matches_whatever_its_abi(self):
        self.assertIsNone(self.mismatch(config.LOCK))
        self.assertIsNone(self.mismatch(dict(config.LOCK, abi=config.LOCK["abi"] - 1)))

    def test_no_stamp_is_no_mismatch(self):
        # Tests that need the tree skip on its missing files themselves.
        self.assertIsNone(self.mismatch(None))

    def test_an_older_tree_names_both_versions(self):
        older = dict(config.LOCK, chromium="156.0.8078.47", helium=dict(config.LOCK["helium"], version="0.20.1"))
        self.assertEqual(self.mismatch(older),
                         "the prepared tree (Chromium 156.0.8078.47, Helium 0.20.1) is not the one engine.lock.json "
                         f"pins (Chromium {config.LOCK['chromium']}, Helium {config.LOCK['helium']['version']})")

    def test_another_helium_revision_is_a_mismatch(self):
        other = dict(config.LOCK, helium=dict(config.LOCK["helium"], revision="0" * 40))
        self.assertIsNotNone(self.mismatch(other))


if __name__ == "__main__":
    unittest.main()
