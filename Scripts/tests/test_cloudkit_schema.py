"""make cloudkit-schema's comparison of CloudKit/arx.ckdb with an exported environment, without cktool (DEV-1209)."""

import os
import unittest
from unittest.mock import patch

from Scripts import cloudkit_schema
from Scripts.core.paths import ROOT


FILE = """DEFINE SCHEMA

    RECORD TYPE Users (
        "___createTime" TIMESTAMP,
        roles           LIST<INT64>,
        GRANT WRITE TO "_creator",
        GRANT READ TO "_world"
    );

    RECORD TYPE profile (
        "___recordID"                          REFERENCE,
        id                                     ENCRYPTED STRING,
        isStarter                              ENCRYPTED INT64,
        sqlitedata_icloud_userModificationTime ENCRYPTED INT64,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );
"""


class ParseTests(unittest.TestCase):
    def test_reads_fields_and_types_and_skips_grants(self):
        types = cloudkit_schema.parse(FILE)
        self.assertEqual(set(types), {"Users", "profile"})
        self.assertEqual(types["Users"], {'"___createTime"': "TIMESTAMP", "roles": "LIST<INT64>"})
        self.assertEqual(types["profile"]["id"], "ENCRYPTED STRING")
        self.assertEqual(types["profile"]["isStarter"], "ENCRYPTED INT64")

    def test_the_committed_schema_has_every_category(self):
        types = cloudkit_schema.parse((ROOT / "CloudKit/arx.ckdb").read_text())
        for name in ("profile", "space", "preference", "historyVisit", "archiveEntry", "syncDeviceDirectory", "mergedItem"):
            self.assertIn(name, set(types))


class MissingTests(unittest.TestCase):
    def test_an_empty_environment_lacks_every_record_type(self):
        problems = cloudkit_schema.missing(cloudkit_schema.parse(FILE), {"Users": {}})
        self.assertIn("record type profile is missing", problems)
        self.assertNotIn("record type Users is missing", problems)

    def test_missing_and_retyped_fields_are_listed_and_extra_ones_are_not(self):
        expected = cloudkit_schema.parse(FILE)
        actual = cloudkit_schema.parse(FILE)
        del actual["profile"]["isStarter"]
        actual["profile"]["id"] = "STRING"
        actual["profile"]["removedLongAgo"] = "ENCRYPTED STRING"
        self.assertEqual(
            cloudkit_schema.missing(expected, actual),
            ["profile.id is STRING, not ENCRYPTED STRING", "profile.isStarter is missing"],
        )

    def test_a_matching_environment_has_nothing_missing(self):
        self.assertEqual(cloudkit_schema.missing(cloudkit_schema.parse(FILE), cloudkit_schema.parse(FILE)), [])


class CompareTests(unittest.TestCase):
    def test_compare_needs_a_team(self):
        with patch.dict(os.environ, {"DEVELOPMENT_TEAM": ""}), self.assertRaisesRegex(ValueError, "DEVELOPMENT_TEAM"):
            cloudkit_schema.compare("production")

    def test_compare_fails_listing_what_the_environment_lacks(self):
        def export(arguments, **_):
            output = arguments[arguments.index("--output-file") + 1]
            with open(output, "w") as file:
                file.write('DEFINE SCHEMA\n\n    RECORD TYPE Users (\n        roles LIST<INT64>\n    );\n')
            self.assertIn("production", arguments)
            self.assertIn(cloudkit_schema.CONTAINER, arguments)

        with patch.dict(os.environ, {"DEVELOPMENT_TEAM": "TEAM"}), patch.object(cloudkit_schema, "run", export):
            with self.assertRaisesRegex(ValueError, "record type profile is missing"):
                cloudkit_schema.compare("production")


if __name__ == "__main__":
    unittest.main()
