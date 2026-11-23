"""The post-exit history check requires real ordinary evidence and rejects any private index."""

import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from urllib.parse import urljoin

from Scripts.core import history_smoke


class HistorySmokeTests(unittest.TestCase):
    def test_ordinary_index_is_required_and_private_entries_in_other_files_fail(self):
        base = "http://127.0.0.1:12345/index.html"
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory)
            with self.assertRaisesRegex(ValueError, "did not persist"):
                history_smoke.verify(profile, base)
            history = profile / "History"
            history.mkdir()
            ordinary = {"version": 1, "snapshot": {"entries": [{"url": base + "?arx_history_smoke=ordinary"}]}}
            (history / "ordinary.json").write_text(json.dumps(ordinary))
            with self.assertRaisesRegex(ValueError, "Little Arx"):
                history_smoke.verify(profile, base)
            ordinary["snapshot"]["entries"].append({"url": base + "?arx_history_smoke=temporary"})
            (history / "ordinary.json").write_text(json.dumps(ordinary))
            history_smoke.verify(profile, base)
            forbidden = [base + "?" + query for query in ["arx_history_smoke=private", "peek=temporary"]]
            forbidden.append(urljoin(base, "mcp-private.html"))
            forbidden.extend(urljoin(base, "little-peek.html?phase=" + phase) for phase in ("dismiss", "promote-start"))
            for url in forbidden:
                with self.subTest(url=url):
                    hidden = {"version": 1, "snapshot": {"entries": [{"url": url}]}}
                    (history / "unexpected-profile.json").write_text(json.dumps(hidden))
                    with self.assertRaisesRegex(ValueError, "leaked"):
                        history_smoke.verify(profile, base)

    def test_history_in_the_database_counts_and_its_private_entries_fail(self):
        base = "http://127.0.0.1:12345/index.html"
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory)
            connection = sqlite3.connect(profile / history_smoke.DATABASE)
            connection.execute('CREATE TABLE "historyEntry" ("id" TEXT PRIMARY KEY NOT NULL, "url" TEXT NOT NULL)')
            connection.execute('CREATE TABLE "historyVisit" ("id" TEXT PRIMARY KEY NOT NULL, "url" TEXT NOT NULL)')
            connection.execute('INSERT INTO "historyEntry" VALUES (?, ?)', ("a", base + "?arx_history_smoke=ordinary"))
            connection.commit()
            with self.assertRaisesRegex(ValueError, "Little Arx"):
                history_smoke.verify(profile, base)
            connection.execute('INSERT INTO "historyEntry" VALUES (?, ?)', ("b", base + "?arx_history_smoke=temporary"))
            connection.commit()
            history_smoke.verify(profile, base)
            connection.execute('INSERT INTO "historyVisit" VALUES (?, ?)', ("c", base + "?arx_history_smoke=private"))
            connection.commit()
            connection.close()
            with self.assertRaisesRegex(ValueError, "leaked"):
                history_smoke.verify(profile, base)

    def test_empty_index_does_not_pass_as_privacy_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory)
            (profile / "History").mkdir()
            (profile / "History/empty.json").write_text(json.dumps({"version": 1, "snapshot": {"entries": []}}))
            with self.assertRaisesRegex(ValueError, "Ordinary fixture"):
                history_smoke.verify(profile, "http://127.0.0.1/index.html")


if __name__ == "__main__":
    unittest.main()
