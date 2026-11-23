"""Localization export, import and check (DEV-1291)."""

import io
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from Scripts import localization as l10n
from Scripts.core.paths import ROOT
from Scripts.core.privacy import USAGE_DESCRIPTIONS


def unit(value, state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


def plural(cases, state="translated"):
    return {"variations": {"plural": {category: unit(text, state) for category, text in cases.items()}}}


def entry(english, **localizations):
    value = plural(english) if isinstance(english, dict) else unit(english)
    return {"extractionState": "manual", "generatesSymbol": False, "localizations": {"en": value, **localizations}}


class Fixture:
    """A throwaway repository root with the files the tooling reads."""

    def __init__(self, strings, shipped=(), separators=(",", ": "), trailing_newline=False, bundle=None):
        self.root = Path(tempfile.mkdtemp())
        self.catalog = self.root / l10n.CATALOGS["AppUI"]
        self.catalog.parent.mkdir(parents=True)
        text = json.dumps({"sourceLanguage": "en", "strings": strings, "version": "1.0"}, indent=2, ensure_ascii=False, separators=separators)
        self.catalog.write_text(text + ("\n" if trailing_newline else ""), encoding="utf-8")
        info = self.root / l10n.CATALOGS["InfoPlist"]
        info.parent.mkdir(parents=True)
        info.write_text(json.dumps({"sourceLanguage": "en", "strings": {
            key: {"extractionState": "manual", "localizations": {"en": unit(text)}} for key, text in USAGE_DESCRIPTIONS.items()
        }, "version": "1.0"}, indent=2, separators=(",", " : ")) + "\n", encoding="utf-8")
        config = self.root / l10n.LANGUAGES
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({"source": "en", "shipped": list(shipped), "planned": ["de", "pl", "ja", "fr"]}))
        spec = self.root / l10n.APP_SPEC
        spec.parent.mkdir(parents=True)
        declared = bundle if bundle is not None else ["en", *shipped]
        spec.write_text(f"targets:\n  Arx:\n    info:\n      properties:\n        CFBundleLocalizations: [{', '.join(declared)}]\n")
        glossaries = self.root / l10n.GLOSSARIES
        glossaries.mkdir(parents=True)
        (glossaries / "glossary.de.md").write_text(
            "# Glossary: German (de)\n\n## Terms\n\n"
            "| English | Translation | Kind | Status | Check | Note |\n| --- | --- | --- | --- | --- | --- |\n"
            "| Arx | Arx | arx | decided | yes | brand |\n"
            "| Peek | Peek | arx | decided | yes | kept |\n"
            "| Sidebar | Seitenleiste | platform | verified | yes | |\n"
            "| Tab | Tab / Tabs | platform | verified | no | |\n"
        )

    def text(self):
        return self.catalog.read_text(encoding="utf-8")

    def data(self):
        return json.loads(self.text())

    def translations(self, name, translations):
        folder = self.root / "work"
        folder.mkdir(exist_ok=True)
        (folder / name).write_text(json.dumps({"translations": translations}, ensure_ascii=False), encoding="utf-8")
        return folder

    def cleanup(self):
        shutil.rmtree(self.root)


STRINGS = {
    "sidebar.title": entry("Sidebar"),
    "tabs.close": entry("Close %lld tabs in %@"),
    "tabs.count": entry({"one": "%lld tab", "other": "%lld tabs"}),
    "brand.name": entry("Arx"),
    "symbol.shortcut": entry("⌘K"),
    "featureFlags.title": {**entry("Feature Flags"), "shouldTranslate": False},
    "peek.open": entry("Open in Peek"),
}


class PlaceholderTests(unittest.TestCase):
    def test_same_specifiers_in_the_same_order_pass(self):
        self.assertIsNone(l10n.placeholder_problem("Close %lld tabs in %@", "%lld Tabs in %@ schließen"))

    def test_a_missing_or_extra_specifier_is_refused(self):
        self.assertIn("differ", l10n.placeholder_problem("Close %lld tabs in %@", "Tabs schließen in %@"))
        self.assertIn("differ", l10n.placeholder_problem("Saved %@", "%@ %@ gesichert"))
        self.assertIn("differ", l10n.placeholder_problem("%lld tabs", "%d Tabs"))

    def test_moved_specifiers_must_be_numbered_in_the_english_order(self):
        self.assertIn("different order", l10n.placeholder_problem("Close %lld tabs in %@", "In %@ %lld Tabs schließen"))
        self.assertIsNone(l10n.placeholder_problem("Close %lld tabs in %@", "In %2$@ %1$lld Tabs schließen"))
        self.assertIn("don't match", l10n.placeholder_problem("Close %lld tabs in %@", "In %1$@ %2$lld Tabs schließen"))
        self.assertIn("mixes", l10n.placeholder_problem("Close %lld tabs in %@", "In %2$@ %lld Tabs schließen"))

    def test_numbered_english_keeps_its_numbers(self):
        self.assertIsNone(l10n.placeholder_problem("%2$@ from %1$@", "%1$@ → %2$@"))

    def test_percent_signs_and_precision_are_not_arguments(self):
        self.assertIsNone(l10n.placeholder_problem("%lld%% done", "%lld %% erledigt"))
        self.assertIsNone(l10n.placeholder_problem("%.1f MB", "%.2f Mo"))

    def test_a_dropped_or_added_percent_sign_is_refused(self):
        self.assertIn("%%", l10n.placeholder_problem("%lld%%", "%lld"))
        self.assertIn("%%", l10n.placeholder_problem("%@, intensity %lld%%", "%@, Intensität %lld %% %%"))

    def test_unnumbered_translations_follow_numbered_english(self):
        english = "%1$@ takes up to %2$lld files in one message."
        self.assertIsNone(l10n.placeholder_problem(english, "%@ nimmt bis zu %lld Dateien."))
        self.assertIn("different order", l10n.placeholder_problem(english, "Bis zu %lld Dateien in %@."))
        self.assertIn("different order", l10n.placeholder_problem("%2$@ from %1$lld", "%@ von %lld"))
        self.assertIsNone(l10n.placeholder_problem("%2$@ from %1$lld", "%lld → %@"))

    def test_only_real_specifiers_are_placeholders(self):
        # "% CPU" used to read as `% C` (a space flag and the unichar conversion).
        self.assertEqual(l10n.placeholders("%% CPU"), [])
        self.assertEqual(l10n.placeholders("% CPU"), [])
        self.assertEqual(l10n.placeholders("CPU %"), [])
        self.assertEqual(l10n.placeholders("50% off, 100%!"), [])
        self.assertEqual(
            l10n.placeholders("%1$@ %2$lld %-5d %+.2f %08.3lf %'d %*d %hhu %zu %C"),
            [(1, "@"), (2, "lld"), (None, "d"), (None, "f"), (None, "lf"), (None, "d"), (None, "d"), (None, "hhu"), (None, "zu"), (None, "C")],
        )
        self.assertEqual(l10n.placeholders("%0$@"), [])

    def test_bare_percent_signs_are_counted(self):
        self.assertEqual(l10n.stray_percents("%% CPU"), 0)
        self.assertEqual(l10n.stray_percents("%lld%%"), 0)
        self.assertEqual(l10n.stray_percents("% CPU"), 1)
        self.assertEqual(l10n.stray_percents("CPU %"), 1)
        self.assertEqual(l10n.stray_percents("50% of %lld"), 1)
        self.assertEqual(l10n.stray_percents("%%% CPU"), 1)

    def test_a_bare_percent_sign_in_a_translation_is_refused(self):
        self.assertIsNone(l10n.placeholder_problem("CPU %%", "%% CPU"))
        self.assertIn("bare %", l10n.placeholder_problem("CPU %%", "% CPU"))
        self.assertIn("bare %", l10n.placeholder_problem("CPU %%", "CPU %"))

    def test_a_bare_percent_sign_in_the_english_is_an_error(self):
        fixture = Fixture({**STRINGS, "task.cpu": entry("CPU %"), "task.zoom": entry("%lld%%")})
        try:
            out = io.StringIO()
            errors = l10n.check(["de"], include_sources=False, root=fixture.root, out=out)
            self.assertEqual(errors, 1)
            self.assertIn("task.cpu: the English has a bare %", out.getvalue())
            self.assertNotIn("task.zoom: the English has a bare %", out.getvalue())
        finally:
            fixture.cleanup()


class PluralTests(unittest.TestCase):
    def test_each_language_needs_its_own_categories(self):
        english = {"one": "%lld tab", "other": "%lld tabs"}
        self.assertEqual(l10n.validate(english, {"one": "%lld karta", "few": "%lld karty", "many": "%lld kart", "other": "%lld karty"}, "pl"), [])
        self.assertTrue(any("missing few, many" in problem for problem in l10n.validate(english, {"one": "%lld karta", "other": "%lld kart"}, "pl")))
        self.assertEqual(l10n.validate(english, {"other": "%lld 個のタブ"}, "ja"), [])
        self.assertTrue(any("not used in this language: one" in problem for problem in l10n.validate(english, {"one": "%lld", "other": "%lld 個"}, "ja")))
        self.assertTrue(any("not used" in problem for problem in l10n.validate(english, {"one": "%lld Tab", "few": "%lld", "other": "%lld Tabs"}, "de")))
        self.assertEqual(l10n.validate(english, {"one": "%lld onglet", "many": "%lld d’onglets", "other": "%lld onglets"}, "fr"), [])

    def test_shapes_must_match(self):
        self.assertIn("give an object", l10n.validate({"one": "a", "other": "b"}, "x", "de")[0])
        self.assertIn("give a string", l10n.validate("a", {"other": "b"}, "de")[0])
        self.assertEqual(l10n.validate("a", "  ", "de"), ["empty"])

    def test_every_category_keeps_the_count(self):
        problems = l10n.validate({"one": "%lld tab", "other": "%lld tabs"}, {"one": "ein Tab", "other": "%lld Tabs"}, "de")
        self.assertTrue(any(problem.startswith("one:") for problem in problems))


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture(json.loads(json.dumps(STRINGS)))
        self.before = self.fixture.text()

    def tearDown(self):
        self.fixture.cleanup()

    def run_import(self, translations, validate_only=False, language="de"):
        folder = self.fixture.translations("chunk-001.translated.json", translations)
        return l10n.import_translations(language, folder, validate_only=validate_only, root=self.fixture.root)

    def test_bad_entries_are_listed_and_nothing_is_written(self):
        count, problems = self.run_import({
            "sidebar.title": "",
            "tabs.close": "Tabs schließen",
            "tabs.count": {"one": "%lld Tab", "few": "%lld Tabs", "other": "%lld Tabs"},
            "no.such.key": "x",
            "featureFlags.title": "Funktionsschalter",
            "peek.open": "In Peek öffnen",
        })
        self.assertEqual(count, 0)
        joined = "\n".join(problems)
        for expected in ["sidebar.title: empty", "tabs.close: placeholders", "tabs.count: plural categories", "no.such.key: unknown key", "featureFlags.title: marked shouldTranslate false"]:
            self.assertIn(expected, joined)
        self.assertNotIn("peek.open", joined)
        self.assertEqual(self.fixture.text(), self.before)
        self.assertFalse((self.fixture.root / l10n.SOURCES).exists())

    def test_validate_only_writes_nothing(self):
        count, problems = self.run_import({"sidebar.title": "Seitenleiste"}, validate_only=True)
        self.assertEqual((count, problems), (1, []))
        self.assertEqual(self.fixture.text(), self.before)

    def test_import_touches_only_its_entries_and_is_idempotent(self):
        translations = {
            "sidebar.title": "Seitenleiste",
            "tabs.count": {"one": "%lld Tab", "other": "%lld Tabs"},
        }
        count, problems = self.run_import(translations)
        self.assertEqual((count, problems), (2, []))
        after = self.fixture.data()
        self.assertEqual(after["strings"]["sidebar.title"]["localizations"]["de"], unit("Seitenleiste"))
        self.assertEqual(list(after["strings"]["sidebar.title"]["localizations"]), ["de", "en"])
        self.assertEqual(after["strings"]["tabs.count"]["localizations"]["de"], plural({"one": "%lld Tab", "other": "%lld Tabs"}))
        before = json.loads(self.before)
        for key in ["tabs.close", "brand.name", "symbol.shortcut", "featureFlags.title", "peek.open"]:
            self.assertEqual(after["strings"][key], before["strings"][key])
        self.assertEqual(list(after["strings"]), list(before["strings"]))
        first = self.fixture.text()
        self.assertEqual(self.run_import(translations), (2, []))
        self.assertEqual(self.fixture.text(), first)
        sources = json.loads((self.fixture.root / l10n.SOURCES).read_text())
        self.assertEqual(set(sources["AppUI"]["de"]), {"sidebar.title", "tabs.count"})

    def test_other_languages_are_left_alone(self):
        self.assertEqual(self.run_import({"sidebar.title": "Pasek boczny"}, language="pl"), (1, []))
        polish = self.fixture.text()
        self.assertEqual(self.run_import({"sidebar.title": "Seitenleiste"}), (1, []))
        data = self.fixture.data()
        self.assertEqual(data["strings"]["sidebar.title"]["localizations"]["pl"], unit("Pasek boczny"))
        self.assertEqual(list(data["strings"]["sidebar.title"]["localizations"]), ["de", "en", "pl"])
        self.assertNotEqual(polish, self.fixture.text())

    def test_unknown_languages_are_refused(self):
        with self.assertRaises(l10n.LocalizationError):
            self.run_import({"sidebar.title": "x"}, language="xx")


class FormattingTests(unittest.TestCase):
    def test_untouched_entries_stay_byte_for_byte_in_either_style(self):
        for separators, trailing in [((",", ": "), False), ((",", " : "), True)]:
            with self.subTest(separators=separators):
                fixture = Fixture(json.loads(json.dumps(STRINGS)), separators=separators, trailing_newline=trailing)
                try:
                    catalog = l10n.Catalog("AppUI", fixture.catalog)
                    self.assertEqual(catalog.render(), fixture.text())
                    folder = fixture.translations("a.translated.json", {"peek.open": "In Peek öffnen"})
                    l10n.import_translations("de", folder, root=fixture.root)
                    before = fixture.text()
                    after_lines = before.splitlines()
                    # Only lines inside peek.open's entry were added.
                    original = json.dumps({"sourceLanguage": "en", "strings": STRINGS, "version": "1.0"}, indent=2, ensure_ascii=False, separators=separators).splitlines()
                    added = [line for line in after_lines if line not in original]
                    self.assertTrue(added)
                    self.assertTrue(all("de" in line or "stringUnit" in line or "state" in line or "value" in line or line.strip() in ("},", "}") for line in added), added)
                    self.assertEqual(before.endswith("\n"), trailing)
                    self.assertEqual(f'"de"{separators[1]}' in before, True)
                finally:
                    fixture.cleanup()

    def test_the_real_catalogs_render_as_they_are(self):
        for name, path in l10n.CATALOGS.items():
            with self.subTest(catalog=name):
                catalog = l10n.Catalog(name, ROOT / path)
                self.assertEqual(catalog.render(), catalog.text)


class ExportTests(unittest.TestCase):
    def setUp(self):
        strings = json.loads(json.dumps(STRINGS))
        strings["sidebar.title"]["localizations"]["de"] = unit("Seitenleiste")
        strings["peek.open"]["localizations"]["de"] = unit("In Peek öffnen", state="needs_review")
        strings["tabs.count"]["localizations"]["de"] = plural({"one": "%lld Tab", "other": "%lld Tabs"})
        self.fixture = Fixture(strings)
        sources = {"AppUI": {"de": {
            "sidebar.title": l10n.source_hash("Sidebar"),
            "tabs.count": l10n.source_hash({"one": "%lld tab (old)", "other": "%lld tabs"}),
        }}}
        (self.fixture.root / l10n.SOURCES).write_text(json.dumps(sources))
        self.out = self.fixture.root / "out"

    def tearDown(self):
        self.fixture.cleanup()

    def test_exports_missing_needs_review_and_stale_only(self):
        index, _ = l10n.export("de", self.out, chunk_size=2, root=self.fixture.root)
        entries = [item for name in index["chunks"] for item in json.loads((self.out / name).read_text())["entries"]]
        states = {item["key"]: item["state"] for item in entries}
        expected = {"tabs.close": "missing", "peek.open": "needs_review", "tabs.count": "stale"}
        expected.update({key: "missing" for key in USAGE_DESCRIPTIONS})
        self.assertEqual(states, expected)
        self.assertEqual(len(index["chunks"]), (len(expected) + 1) // 2)
        count = next(item for item in entries if item["key"] == "tabs.count")
        self.assertEqual(count["categories"], ["one", "other"])
        self.assertEqual(count["current"], {"one": "%lld Tab", "other": "%lld Tabs"})
        close = next(item for item in entries if item["key"] == "tabs.close")
        self.assertEqual(close["placeholders"], ["%@", "%lld"])
        self.assertTrue((self.out / "glossary.md").is_file())

    def test_polish_plurals_ask_for_four_categories(self):
        index, _ = l10n.export("pl", self.out, root=self.fixture.root)
        entries = json.loads((self.out / index["chunks"][0]).read_text())["entries"]
        count = next(item for item in entries if item["key"] == "tabs.count")
        self.assertEqual(count["categories"], ["one", "few", "many", "other"])
        self.assertEqual(count["state"], "missing")

    def test_refuses_to_overwrite_translated_chunks(self):
        l10n.export("de", self.out, root=self.fixture.root)
        (self.out / "chunk-001.translated.json").write_text("{}")
        with self.assertRaises(l10n.LocalizationError):
            l10n.export("de", self.out, root=self.fixture.root)


class KeptNameTests(unittest.TestCase):
    ROWS = [
        {"english": "Peek", "forms": ["Peek"], "kind": "arx"},
        {"english": "Proxy", "forms": ["Proxy"], "kind": "browser"},
        {"english": "Link", "forms": ["Link"], "kind": "browser"},
        {"english": "Update", "forms": ["Update"], "kind": "ui"},
        {"english": "Proxy Link", "forms": ["Proxy-Link"], "kind": "arx"},
    ]

    def test_only_a_whole_kept_name_is_left_untranslated(self):
        names = l10n.kept_names(self.ROWS)
        self.assertEqual(names, {"Peek", "Proxy", "Link"})
        for text, needed in [("Peek", False), ("Peek: %@", False), ("https://example.com", False), ("⌘K", False),
                             ("Proxy Link", True), ("Update", True), ("Open in Peek", True), ("Peek…", True)]:
            with self.subTest(text=text):
                self.assertEqual(l10n.needs_translation(entry(text), names), needed)


class CheckTests(unittest.TestCase):
    def run_check(self, fixture, languages=None, **options):
        output = io.StringIO()
        errors = l10n.check(languages, include_sources=False, root=fixture.root, out=output, **options)
        return errors, output.getvalue()

    def test_missing_translations_fail_only_shipped_languages(self):
        fixture = Fixture(json.loads(json.dumps(STRINGS)), shipped=["de"])
        try:
            errors, output = self.run_check(fixture, ["de"])
            self.assertGreater(errors, 0)
            self.assertIn("tabs.close [de]: missing translation", output)
            errors, _ = self.run_check(fixture, ["pl"])
            self.assertEqual(errors, 0)
        finally:
            fixture.cleanup()

    def test_the_bundle_must_declare_the_shipped_languages(self):
        fixture = Fixture(json.loads(json.dumps(STRINGS)), shipped=["de"], bundle=["en"])
        try:
            errors, output = self.run_check(fixture, ["pl"])
            self.assertEqual(errors, 1)
            self.assertIn("CFBundleLocalizations", output)
            self.assertEqual(l10n.check_errors_without_languages(fixture.root), 1)
        finally:
            fixture.cleanup()

    def test_warnings_for_copies_whitespace_and_glossary(self):
        strings = json.loads(json.dumps(STRINGS))
        strings["sidebar.title"]["localizations"]["de"] = unit("Sidebar ")
        strings["brand.name"]["localizations"]["de"] = unit("Arx")
        strings["peek.open"]["localizations"]["de"] = unit("Open in Peek")
        fixture = Fixture(strings)
        try:
            findings = l10n.check_language("de", l10n.load_catalogs(fixture.root), {}, l10n.read_glossary("de", fixture.root), shipped=False)
            messages = {(finding.key, finding.message) for finding in findings}
            self.assertIn(("sidebar.title", "leading or trailing whitespace differs from the English"), messages)
            self.assertIn(("sidebar.title", "glossary: “Sidebar” is “Seitenleiste”"), messages)
            self.assertIn(("peek.open", "same as the English"), messages)
            self.assertNotIn(("brand.name", "same as the English"), messages)
            self.assertFalse(any(finding.level == "error" for finding in findings))
        finally:
            fixture.cleanup()

    def test_mark_stale_sets_needs_review(self):
        strings = json.loads(json.dumps(STRINGS))
        strings["sidebar.title"]["localizations"]["de"] = unit("Seitenleiste")
        fixture = Fixture(strings)
        try:
            (fixture.root / l10n.SOURCES).write_text(json.dumps({"AppUI": {"de": {"sidebar.title": "0" * 12}}}))
            self.run_check(fixture, ["de"], mark_stale=True)
            self.assertEqual(fixture.data()["strings"]["sidebar.title"]["localizations"]["de"]["stringUnit"]["state"], "needs_review")
        finally:
            fixture.cleanup()

    def test_shipped_languages_need_english_copies_of_untranslated_entries(self):
        # A bundle returns the bare key for a key its language's table lacks, so entries nobody
        # translates (shouldTranslate false, symbols, kept brand names) carry the English.
        fixture = Fixture(json.loads(json.dumps(STRINGS)), shipped=["de"])
        try:
            _, output = self.run_check(fixture, ["de"])
            for key in ["featureFlags.title", "symbol.shortcut", "brand.name"]:
                self.assertIn(f"{key} [de]: no English copy", output)
            self.run_check(fixture, ["de"], fill=True)
            data = fixture.data()["strings"]
            self.assertEqual(data["featureFlags.title"]["localizations"]["de"], unit("Feature Flags"))
            self.assertEqual(data["symbol.shortcut"]["localizations"]["de"], unit("⌘K"))
            self.assertEqual(data["brand.name"]["localizations"]["de"], unit("Arx"))
            self.assertNotIn("de", data["tabs.close"]["localizations"])
            _, output = self.run_check(fixture, ["de"])
            self.assertNotIn("English copy", output)
            text = fixture.text().replace('"value": "Feature Flags"', '"value": "Feature flags"', 1)
            fixture.catalog.write_text(text, encoding="utf-8")
            _, output = self.run_check(fixture, ["de"])
            self.assertIn("featureFlags.title [de]: the English copy is out of date", output)
        finally:
            fixture.cleanup()

    def test_github_annotations(self):
        fixture = Fixture(json.loads(json.dumps(STRINGS)), shipped=["de"])
        try:
            _, output = self.run_check(fixture, ["de"], github=True)
            self.assertIn("::error file=", output)
            self.assertIn(",line=", output)
        finally:
            fixture.cleanup()


class RepositoryTests(unittest.TestCase):
    def test_shipped_languages_pass(self):
        self.assertEqual(l10n.check_errors_without_languages(ROOT), 0)
        config = l10n.read_languages(ROOT)
        self.assertEqual(sorted(l10n.bundle_localizations(ROOT)), sorted(["en", *config["shipped"]]))

    def test_every_planned_language_has_a_glossary_that_keeps_brands_and_separates_spaces(self):
        for language in l10n.read_languages(ROOT)["planned"]:
            with self.subTest(language=language):
                rows = {row["english"]: row for row in l10n.read_glossary(language, ROOT)}
                self.assertGreater(len(rows), 200)
                for term in ["Arx", "Little Arx", "Peek", "Air Traffic Control", "Runway"]:
                    self.assertEqual(rows[term]["forms"][0], term)
                for row in rows.values():
                    self.assertIn(row["status"], {"verified", "standard", "decided", "unverified"}, row)
                    self.assertIn(row["check"], {"yes", "no"}, row)
                arx_space = {form.casefold() for form in rows["Space"]["forms"]}
                macos_spaces = {form.casefold() for form in rows["Spaces (macOS)"]["forms"]}
                self.assertFalse(arx_space & macos_spaces, (arx_space, macos_spaces))


if __name__ == "__main__":
    unittest.main()
