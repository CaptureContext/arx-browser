"""Translations of Arx's string catalogs: export, import and check (DEV-1291).

The rules for translators and for anyone adding interface text are in `.agents/LOCALIZATION.md`.

- `make localization-export ARGS='--lang de [--chunk-size 120] [--out DIR]'` writes the strings
  that German still needs (missing, needs_review, stale against the English they were translated
  from, or with plural categories the language lacks) as numbered JSON chunks, with the German
  glossary beside them. The default directory is `build/localization/<lang>/`.
- `make localization-import ARGS='--lang de --from DIR [--validate-only]'` reads every
  `*.translated.json` in DIR, refuses the whole import with a per-key list if any entry has an
  unknown key, an empty value, placeholders that differ from the English ones, or plural
  categories the language doesn't use, and otherwise writes the translations into the catalogs as
  `translated`, in the catalog's own formatting, leaving every other entry and language as it was.
- `make localization-check [ARGS='--lang de --github --mark-stale']` reports per language what is
  missing, stale or suspicious. Only languages listed as shipped in `Localization/languages.json`
  fail it; `make check` runs the failing part for them alone.

The catalog keeps no record of the English a translation was made from, and Arx's catalogs are
mostly edited outside Xcode, which is what marks translations `needs_review` when English changes.
`Localization/sources.json` therefore stores a short hash of the English of every imported
translation; a translation whose English has changed since is stale.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from collections import Counter
from pathlib import Path

from .core.paths import ROOT

CATALOGS = {
    "AppUI": "Packages/design-system/Sources/AppUI/Resources/AppUI.xcstrings",
    "InfoPlist": "Containers/macOS/InfoPlist.xcstrings",
}
LANGUAGES = "Localization/languages.json"
SOURCES = "Localization/sources.json"
GLOSSARIES = ".agents/localization"
APP_SPEC = ".xcodegen/macOS.yml"
DEFAULT_CHUNK_SIZE = 120
TRANSLATED_SUFFIX = ".translated.json"

LANGUAGE_NAMES = {
    "de": "German", "es": "Spanish (Spain)", "fr": "French", "ja": "Japanese", "pl": "Polish",
    "ru": "Russian", "uk": "Ukrainian", "zh-Hans": "Simplified Chinese",
}
# CLDR plural categories for integers, as Xcode offers them in a catalog's plural variations.
# Optional ones may be given and are kept; required ones must all be there.
PLURALS_REQUIRED = {
    "en": {"one", "other"}, "de": {"one", "other"}, "es": {"one", "other"}, "fr": {"one", "other"},
    "pl": {"one", "few", "many", "other"}, "ru": {"one", "few", "many", "other"},
    "uk": {"one", "few", "many", "other"}, "ja": {"other"}, "zh-Hans": {"other"},
}
PLURALS_OPTIONAL = {"es": {"many"}, "fr": {"many"}}
CLDR_ORDER = ["zero", "one", "two", "few", "many", "other"]
# What a key's name says about where its text appears, for translators. First match wins.
HINTS = [
    (re.compile(r"^settingsSearch\.keywords\."), "comma-separated search keywords for a Settings row, not a sentence; translate each, keep the commas"),
    (re.compile(r"^(menu|contextMenu)\."), "menu item: as macOS and Safari write menu items in this language"),
    (re.compile(r"^command\."), "command name: shown in the command bar and Settings › Shortcuts"),
    (re.compile(r"(?i)accessibility|voiceover|\.a11y"), "VoiceOver text: read aloud, never shown"),
    (re.compile(r"(?i)(help|tooltip)$"), "tooltip"),
    (re.compile(r"^settings\.section\."), "Settings section title"),
    (re.compile(r"(?i)(button|action|\.cancel|\.done|\.save|\.close)$"), "button: short"),
]
# Stemming for the advisory glossary check: these languages inflect nouns and verbs, so a term
# counts as present when each of its words appears with the last letters cut off.
INFLECTED = {"de", "es", "fr", "pl", "ru", "uk"}

# printf conversions as Foundation reads them: `%`, an optional position (`%2$@`), flags, width,
# precision, a length modifier and a conversion character, or `%%`. A space is not taken as a
# flag: printf would read "% CPU" as `% C`, but in a catalog a percent sign before a space is
# always text, and `stray_percents` reports it, since the string must write it `%%`.
PLACEHOLDER = re.compile(
    r"%(?:(?P<position>[1-9]\d*)\$)?[-+#0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(?P<length>hh|h|ll|l|q|z|t|j|L)?(?P<conversion>[@dDiuUxXoOfFeEgGcCsSpaA%])"
)
SUBSTITUTION = re.compile(r"%#@")
HARDCODED = re.compile(
    r'\b(?:Text|Button|Label|Toggle|Section|Menu|Picker|NSMenuItem\(title:|String\(localized:|'
    r'\.help|\.accessibilityLabel|\.accessibilityHint|\.navigationTitle)\(?\s*"(?P<text>[^"\\]*[A-Za-z][^"\\]*)"'
)


class LocalizationError(ValueError):
    pass


# MARK: - Catalogs


class Catalog:
    """A `.xcstrings` file, read and written in the formatting it already has."""

    def __init__(self, name, path):
        self.name = name
        self.path = Path(path)
        self.text = self.path.read_text(encoding="utf-8")
        self.data = json.loads(self.text)
        self.source = self.data.get("sourceLanguage", "en")
        # Xcode writes `"key" : value`; Arx's AppUI catalog is written as `"key": value`. Keep
        # whichever the file has, and its final newline or its absence, so untouched entries
        # stay byte for byte the same.
        self.separators = (",", " : ") if '" : ' in self.text[:2000] else (",", ": ")
        self.trailing_newline = self.text.endswith("\n")

    @property
    def strings(self):
        return self.data.setdefault("strings", {})

    def render(self):
        text = json.dumps(self.data, indent=2, ensure_ascii=False, separators=self.separators)
        return text + "\n" if self.trailing_newline else text

    def save(self):
        text = self.render()
        if text != self.text:
            self.path.write_text(text, encoding="utf-8")
            self.text = text

    def line_numbers(self):
        """The line of each key's entry, for annotations."""
        lines = {}
        pattern = re.compile(r'^    "((?:[^"\\]|\\.)*)"\s?: \{')
        for number, line in enumerate(self.text.splitlines(), start=1):
            match = pattern.match(line)
            if match:
                lines.setdefault(json.loads(f'"{match[1]}"'), number)
        return lines


def load_catalogs(root=ROOT):
    return {name: Catalog(name, Path(root) / path) for name, path in CATALOGS.items() if (Path(root) / path).is_file()}


def source_value(entry, source="en"):
    """The English of an entry: a string, or a dict of plural category to string."""
    localization = entry.get("localizations", {}).get(source)
    if localization is None:
        return None
    return unit_value(localization)


def unit_value(localization):
    if "stringUnit" in localization:
        return localization["stringUnit"].get("value")
    variations = localization.get("variations", {})
    if set(variations) == {"plural"}:
        return {category: case.get("stringUnit", {}).get("value") for category, case in variations["plural"].items()}
    return None


def unit_states(localization):
    if "stringUnit" in localization:
        return [localization["stringUnit"].get("state")]
    return [case.get("stringUnit", {}).get("state") for case in localization.get("variations", {}).get("plural", {}).values()]


WORD = re.compile(r"[^\W\d_]{2,}")


def has_letters(value):
    """Whether a value has a word in it: two letters or more, so `⌘K` and `%lld×` don't count."""
    values = value.values() if isinstance(value, dict) else [value]
    return any(WORD.search(strip_placeholders(text or "")) for text in values)


def needs_translation(entry, kept, source="en"):
    """Translatable, and more than one name the language keeps in English (a lone "Peek", an
    address). `kept` is `kept_names`: whole values only, so "Proxy Link" isn't skipped because
    "Proxy" and "Link" each happen to stay English in German."""
    if not translatable(entry, source):
        return False
    value = source_value(entry, source)
    values = value.values() if isinstance(value, dict) else [value]
    return not all(only_kept_name(text or "", kept) for text in values)


def only_kept_name(text, kept):
    if "…" in text and WORD.search(text):
        return False  # German writes "Name …": a menu item's ellipsis is the language's own.
    remainder = strip_placeholders(text)
    remainder = re.sub(r"\b(?:https?://|www\.)\S+|\S+@\S+\.\w+|\S+\.(?:com|org|dev|app|io)\b", " ", remainder)
    if not WORD.search(remainder):
        return True
    words = " ".join(re.findall(r"[^\W_][\w’'-]*", remainder))
    return words in kept


def translatable(entry, source="en"):
    """Whether translators should see this entry: not marked shouldTranslate false, has English
    with letters in it, and has a shape this tooling understands (a string or a plural)."""
    if entry.get("shouldTranslate") is False:
        return False
    value = source_value(entry, source)
    return value is not None and has_letters(value)


def source_hash(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True).encode()).hexdigest()[:12]


# MARK: - Configuration


def read_languages(root=ROOT):
    path = Path(root) / LANGUAGES
    config = json.loads(path.read_text(encoding="utf-8"))
    shipped = list(config.get("shipped", []))
    planned = list(config.get("planned", []))
    for language in shipped + planned:
        if language not in PLURALS_REQUIRED or language == "en":
            raise LocalizationError(f"{LANGUAGES}: unknown language {language!r}")
    return {"source": config.get("source", "en"), "shipped": shipped, "planned": planned}


def read_sources(root=ROOT):
    path = Path(root) / SOURCES
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def write_sources(sources, root=ROOT):
    path = Path(root) / SOURCES
    cleaned = {
        catalog: {language: dict(sorted(keys.items())) for language, keys in sorted(languages.items()) if keys}
        for catalog, languages in sorted(sources.items())
    }
    cleaned = {catalog: languages for catalog, languages in cleaned.items() if languages}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(cleaned, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")


def bundle_localizations(root=ROOT):
    """CFBundleLocalizations from the app's Info.plist spec, or None when it isn't declared."""
    spec = (Path(root) / APP_SPEC).read_text(encoding="utf-8")
    match = re.search(r"^\s+CFBundleLocalizations:\s*\[(.*)\]\s*$", spec, re.MULTILINE)
    if match is None:
        return None
    return [item.strip().strip("'\"") for item in match[1].split(",") if item.strip()]


def require_language(language):
    if language not in PLURALS_REQUIRED or language == "en":
        known = ", ".join(sorted(set(PLURALS_REQUIRED) - {"en"}))
        raise LocalizationError(f"Unknown language {language!r}; Arx knows {known}")


# MARK: - Glossaries


def read_glossary(language, root=ROOT):
    """The rows of `.agents/localization/glossary.<lang>.md` as dicts."""
    path = Path(root) / GLOSSARIES / f"glossary.{language}.md"
    if not path.is_file():
        return []
    rows = []
    header = None
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line.startswith("|"):
            header = None if not line else header
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if header is None:
            header = [cell.lower() for cell in cells]
            continue
        if set("".join(cells)) <= set("-: "):
            continue
        if "english" not in header or "translation" not in header:
            continue
        row = dict(zip(header, cells))
        row["forms"] = [form.strip() for form in row.get("translation", "").split(" / ") if form.strip()]
        rows.append(row)
    return rows


def kept_terms(rows):
    """English terms a language writes in English: brands, product names, symbols."""
    return {row["english"] for row in rows if row["english"] in row["forms"]}


def kept_names(rows):
    """Kept terms that are names (Arx terms, platform and browser names), not everyday words:
    a lone "Update" may be a verb a language translates even if its noun stays English."""
    return {row["english"] for row in rows if row["english"] == (row["forms"] or [None])[0] and row.get("kind") != "ui"}


def stem(word, language):
    if language in INFLECTED and len(word) >= 5:
        return word[: max(3, len(word) - 2)]
    return word


def term_present(form, translation, language):
    folded = translation.casefold()
    words = form.casefold().split()
    if language in INFLECTED:
        return all(stem(word, language) in folded for word in words)
    return form.casefold() in folded


def glossary_misses(english, translation, rows, language):
    """Checked glossary terms the English uses whose required translation doesn't appear."""
    misses = []
    for row in rows:
        term = row["english"]
        if row.get("check", "no").lower() != "yes" or "(" in term or not row["forms"]:
            continue
        if not re.search(rf"(?<![\w-]){re.escape(term)}(?![\w-])", english, re.IGNORECASE):
            continue
        if not any(term_present(form, translation, language) for form in row["forms"]):
            misses.append((term, row["forms"][0]))
    return misses


# MARK: - Placeholders and plurals


def placeholders(text):
    """The format specifiers of a string in order, as (position or None, type)."""
    found = []
    for match in PLACEHOLDER.finditer(text or ""):
        if match["conversion"] == "%":
            continue
        position = int(match["position"]) if match["position"] else None
        found.append((position, (match["length"] or "") + match["conversion"]))
    return found


def stray_percents(text):
    """How many percent signs are neither a format specifier nor `%%`.

    Every catalog string goes through `String(format:)` (PackageResources' `String.localized`),
    which reads a bare `%` as the start of a specifier: "% CPU" loses its "C" and reads an
    argument that isn't there. A literal percent sign is written `%%`.
    """
    text = text or ""
    covered = set()
    for match in PLACEHOLDER.finditer(text):
        covered.update(range(match.start(), match.end()))
    return sum(1 for index, character in enumerate(text) if character == "%" and index not in covered)


def strip_placeholders(text):
    return PLACEHOLDER.sub(" ", text)


def placeholder_problem(english, translation):
    """Why a translation's specifiers don't fit the English ones, or None.

    The types must be the same multiset. Unnumbered specifiers take the arguments in order, so a
    translation that moves them must number them (`%2$@ … %1$lld`) to the English order.
    """
    if SUBSTITUTION.search(translation or ""):
        return "uses a %#@…@ substitution; Arx's catalogs don't"
    if stray_percents(translation):
        return "has a bare % that isn't a placeholder; write a percent sign as %%"
    if (english or "").count("%%") != (translation or "").count("%%"):
        return "the number of %% (a literal percent sign) differs from the English"
    source = placeholders(english)
    target = placeholders(translation)
    source_types = [kind for _, kind in source]
    if Counter(source_types) != Counter(kind for _, kind in target):
        return f"placeholders {format_types(target)} differ from the English {format_types(source)}"
    # The arguments' types in the order the code passes them: by number when the English numbers
    # its placeholders, else in the English order.
    if any(position for position, _ in source):
        expected = {position: kind for position, kind in source}
    else:
        expected = {index: kind for index, kind in enumerate(source_types, start=1)}
    positions = [position for position, _ in target]
    if any(positions) and not all(positions):
        return "mixes numbered and unnumbered placeholders; number all of them"
    if all(positions) and target:
        actual = {}
        for position, kind in target:
            if actual.setdefault(position, kind) != kind:
                return f"uses %{position}$ for two types"
        if actual != expected:
            return f"numbered placeholders {format_positions(actual)} don't match the English order {format_positions(expected)}"
        return None
    if [kind for _, kind in target] != [expected[position] for position in sorted(expected)]:
        return "placeholders are in a different order; number them (%1$@, %2$lld) to the English order"
    return None


def format_types(found):
    return "[" + ", ".join("%" + kind for _, kind in found) + "]"


def format_positions(positions):
    return "[" + ", ".join(f"%{position}${kind}" for position, kind in sorted(positions.items())) + "]"


def cldr_sorted(categories):
    return sorted(categories, key=lambda category: CLDR_ORDER.index(category) if category in CLDR_ORDER else len(CLDR_ORDER))


def plural_problem(language, categories):
    required = PLURALS_REQUIRED[language]
    allowed = required | PLURALS_OPTIONAL.get(language, set())
    given = set(categories)
    problems = []
    if required - given:
        problems.append("missing " + ", ".join(sorted(required - given)))
    if given - allowed:
        problems.append("not used in this language: " + ", ".join(sorted(given - allowed)))
    if problems:
        return f"plural categories for {language} must be {', '.join(cldr_sorted(required))}: " + "; ".join(problems)
    return None


def validate(english, translation, language):
    """Every problem that stops a translation from being imported, as strings."""
    problems = []
    if isinstance(english, dict):
        if not isinstance(translation, dict):
            return [f"the English is a plural ({', '.join(sorted(english))}); give an object of categories"]
        problem = plural_problem(language, translation)
        if problem:
            problems.append(problem)
        for category, text in sorted(translation.items()):
            if not isinstance(text, str) or not text.strip():
                problems.append(f"{category}: empty")
                continue
            reference = english.get("other", "")
            problem = placeholder_problem(reference, text)
            if problem and category in english and english[category] != reference:
                if placeholder_problem(english[category], text) is None:
                    problem = None
            if problem:
                problems.append(f"{category}: {problem}")
        return problems
    if isinstance(translation, dict):
        return ["the English is not a plural; give a string"]
    if not isinstance(translation, str) or not translation.strip():
        return ["empty"]
    problem = placeholder_problem(english, translation)
    return [problem] if problem else []


def make_localization(translation, state="translated"):
    if isinstance(translation, dict):
        return {"variations": {"plural": {
            category: {"stringUnit": {"state": state, "value": translation[category]}}
            for category in sorted(translation)
        }}}
    return {"stringUnit": {"state": state, "value": translation}}


# MARK: - Status


def entry_status(catalog_name, key, entry, language, sources, source="en"):
    """Why an entry still needs translating for a language, or None when it is done."""
    english = source_value(entry, source)
    localization = entry.get("localizations", {}).get(language)
    if localization is None:
        return "missing"
    value = unit_value(localization)
    if value is None or (isinstance(value, dict) and not all(value.values())) or value == "":
        return "missing"
    if isinstance(english, dict) != isinstance(value, dict):
        return "incomplete"
    if isinstance(value, dict) and plural_problem(language, value):
        return "incomplete"
    states = unit_states(localization)
    if any(state not in ("translated",) for state in states):
        return "needs_review" if "needs_review" in states else (states[0] or "new")
    recorded = sources.get(catalog_name, {}).get(language, {}).get(key)
    if recorded is not None and recorded != source_hash(english):
        return "stale"
    return None


# MARK: - Export


def export(language, out=None, chunk_size=DEFAULT_CHUNK_SIZE, root=ROOT, force=False):
    require_language(language)
    if chunk_size < 1:
        raise LocalizationError("--chunk-size must be positive")
    out = Path(out) if out else Path(root) / "build/localization" / language
    if out.exists() and any(out.glob("*" + TRANSLATED_SUFFIX)) and not force:
        raise LocalizationError(f"{out} holds translated chunks; import them first or pass --force to start over")
    if out.exists():
        for stale in list(out.glob("chunk-*.json")) + list(out.glob("index.json")) + list(out.glob("glossary.md")):
            stale.unlink()
    out.mkdir(parents=True, exist_ok=True)
    sources = read_sources(root)
    kept = kept_names(read_glossary(language, root))
    entries = []
    for catalog in load_catalogs(root).values():
        for key in sorted(catalog.strings):
            entry = catalog.strings[key]
            if not needs_translation(entry, kept, catalog.source):
                continue
            status = entry_status(catalog.name, key, entry, language, sources, catalog.source)
            if status is None:
                continue
            english = source_value(entry, catalog.source)
            item = {"key": key, "state": status, "english": english}
            if entry.get("comment"):
                item["comment"] = entry["comment"]
            if catalog.name != "AppUI":
                item["context"] = f"{catalog.name}: macOS shows this in a system prompt"
            hint = next((text for pattern, text in HINTS if pattern.search(key)), None)
            if hint:
                item["hint"] = hint
            if isinstance(english, dict):
                item["categories"] = cldr_sorted(PLURALS_REQUIRED[language])
            reference = english if isinstance(english, str) else english.get("other", "")
            specifiers = sorted({"%" + kind for _, kind in placeholders(reference)} | ({"%%"} if "%%" in reference else set()))
            if specifiers:
                item["placeholders"] = specifiers
            current = entry.get("localizations", {}).get(language)
            if current is not None and unit_value(current):
                item["current"] = unit_value(current)
            entries.append(item)
    chunks = [entries[index:index + chunk_size] for index in range(0, len(entries), chunk_size)]
    width = max(3, len(str(len(chunks))))
    names = []
    for number, chunk in enumerate(chunks, start=1):
        name = f"chunk-{number:0{width}d}.json"
        payload = {"language": language, "chunk": number, "chunks": len(chunks), "entries": chunk}
        (out / name).write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        names.append(name)
    glossary = Path(root) / GLOSSARIES / f"glossary.{language}.md"
    if glossary.is_file():
        shutil.copyfile(glossary, out / "glossary.md")
    index = {
        "language": language,
        "entries": len(entries),
        "states": dict(sorted(Counter(item["state"] for item in entries).items())),
        "chunks": names,
    }
    (out / "index.json").write_text(json.dumps(index, indent=2) + "\n", encoding="utf-8")
    return index, out


# MARK: - Import


def read_translations(location):
    """{key: translation} from every `*.translated.json` at a directory, or one file."""
    location = Path(location)
    files = [location] if location.is_file() else sorted(location.glob("*" + TRANSLATED_SUFFIX))
    if not files:
        raise LocalizationError(f"No *{TRANSLATED_SUFFIX} files in {location}")
    translations = {}
    problems = []
    for path in files:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            problems.append(f"{path.name}: not valid JSON ({error})")
            continue
        items = payload.get("translations") if isinstance(payload, dict) else None
        if not isinstance(items, dict):
            problems.append(f'{path.name}: expected {{"translations": {{"key": "translation", …}}}}')
            continue
        for key, value in items.items():
            if key in translations and translations[key] != value:
                problems.append(f"{key}: translated differently in two files ({path.name})")
            translations[key] = value
    return translations, problems


def import_translations(language, location, validate_only=False, root=ROOT):
    """Validate translations and, unless validate_only, merge them. Returns (count, problems)."""
    require_language(language)
    translations, problems = read_translations(location)
    catalogs = load_catalogs(root)
    owners = {}
    for catalog in catalogs.values():
        for key in catalog.strings:
            owners.setdefault(key, []).append(catalog)
    accepted = []
    for key in sorted(translations):
        value = translations[key]
        found = owners.get(key, [])
        if not found:
            problems.append(f"{key}: unknown key")
            continue
        if len(found) > 1:
            problems.append(f"{key}: in more than one catalog ({', '.join(c.name for c in found)})")
            continue
        catalog = found[0]
        entry = catalog.strings[key]
        if entry.get("shouldTranslate") is False:
            problems.append(f"{key}: marked shouldTranslate false; it stays in English")
            continue
        english = source_value(entry, catalog.source)
        if english is None:
            problems.append(f"{key}: has no English to translate from")
            continue
        for problem in validate(english, value, language):
            problems.append(f"{key}: {problem}")
        accepted.append((catalog, key, value, english))
    if problems:
        return 0, problems
    if validate_only:
        return len(accepted), []
    sources = read_sources(root)
    for catalog, key, value, english in accepted:
        localizations = catalog.strings[key].setdefault("localizations", {})
        localizations[language] = make_localization(value)
        catalog.strings[key]["localizations"] = dict(sorted(localizations.items()))
        sources.setdefault(catalog.name, {}).setdefault(language, {})[key] = source_hash(english)
    for catalog in catalogs.values():
        catalog.save()
    write_sources(prune_sources(sources, catalogs), root)
    return len(accepted), []


def prune_sources(sources, catalogs):
    """Drop recorded hashes for keys or translations that no longer exist."""
    pruned = {}
    for catalog_name, languages in sources.items():
        catalog = catalogs.get(catalog_name)
        if catalog is None:
            continue
        for language, keys in languages.items():
            kept = {
                key: digest for key, digest in keys.items()
                if language in catalog.strings.get(key, {}).get("localizations", {})
            }
            if kept:
                pruned.setdefault(catalog_name, {})[language] = kept
    return pruned


# MARK: - Check


class Finding:
    def __init__(self, level, language, catalog, key, message):
        self.level, self.language, self.catalog, self.key, self.message = level, language, catalog, key, message


def check_language(language, catalogs, sources, glossary, shipped, source="en"):
    """Findings for one language. Errors only matter for shipped languages."""
    findings = []
    kept = kept_terms(glossary)
    names = kept_names(glossary)
    for catalog in catalogs.values():
        for key, entry in catalog.strings.items():
            localization = entry.get("localizations", {}).get(language)
            english = source_value(entry, catalog.source)
            if english is None:
                continue
            if not needs_translation(entry, names, catalog.source):
                problem = copy_problem(entry, language, names, catalog.source)
                if problem:
                    findings.append(Finding("error", language, catalog, key, problem))
                continue
            status = entry_status(catalog.name, key, entry, language, sources, catalog.source)
            value = unit_value(localization) if localization is not None else None
            if status == "missing" or value is None:
                findings.append(Finding("error", language, catalog, key, "missing translation"))
                continue
            for problem in validate(english, value, language):
                findings.append(Finding("error", language, catalog, key, problem))
            if status == "stale":
                findings.append(Finding("warning", language, catalog, key, "stale: the English changed after this was translated"))
            elif status in ("needs_review", "new"):
                findings.append(Finding("warning", language, catalog, key, f"state is {status}"))
            pairs = zip_values(english, value)
            for english_text, text in pairs:
                if not isinstance(text, str):
                    continue
                if text == english_text and not identical_allowed(english_text, kept):
                    findings.append(Finding("warning", language, catalog, key, "same as the English"))
                if lead_trail(text) != lead_trail(english_text):
                    findings.append(Finding("warning", language, catalog, key, "leading or trailing whitespace differs from the English"))
                for term, required in glossary_misses(english_text, text, glossary, language):
                    findings.append(Finding("warning", language, catalog, key, f"glossary: “{term}” is “{required}”"))
    if shipped is False:
        for finding in findings:
            if finding.level == "error":
                finding.level = "info"
    return findings


def must_stay_english(entry, source="en"):
    """Entries no language changes: marked shouldTranslate false, or without a word in them."""
    return entry.get("shouldTranslate") is False or not has_letters(source_value(entry, source))


def copy_problem(entry, language, kept, source="en"):
    """An entry nobody translates still needs its English in every shipped language: a bundle
    returns the bare key, not the English, for a key its language's table lacks."""
    localization = entry.get("localizations", {}).get(language)
    if localization is None:
        return "no English copy for this language; run make localization-check ARGS='--lang LANG --fill'"
    if must_stay_english(entry, source) and unit_value(localization) != source_value(entry, source):
        return "the English copy is out of date; run make localization-check ARGS='--lang LANG --fill'"
    return None


def fill_copies(language, catalogs, kept):
    """Give every entry nobody translates its English as this language's value. Returns the count."""
    filled = 0
    for catalog in catalogs.values():
        for entry in catalog.strings.values():
            english = source_value(entry, catalog.source)
            if english is None or needs_translation(entry, kept, catalog.source):
                continue
            localizations = entry.setdefault("localizations", {})
            current = localizations.get(language)
            if current is not None and not (must_stay_english(entry, catalog.source) and unit_value(current) != english):
                continue
            localizations[language] = make_localization(english)
            entry["localizations"] = dict(sorted(localizations.items()))
            filled += 1
    return filled


def zip_values(english, value):
    if isinstance(english, dict) and isinstance(value, dict):
        return [(english.get(category, english.get("other", "")), text) for category, text in sorted(value.items())]
    if isinstance(english, str) and isinstance(value, str):
        return [(english, value)]
    return []


def lead_trail(text):
    return (text[: len(text) - len(text.lstrip())], text[len(text.rstrip()):])


def identical_allowed(text, kept):
    """A value may equal its English when nothing in it is a word to translate: symbols, URLs,
    placeholders, and terms the glossary keeps in English."""
    remainder = strip_placeholders(text)
    remainder = re.sub(r"\b(?:https?://|www\.)\S+|\S+@\S+\.\w+|\S+\.(?:com|org|dev|app|io)\b", " ", remainder)
    for term in sorted(kept, key=len, reverse=True):
        remainder = re.sub(rf"(?<!\w){re.escape(term)}(?!\w)", " ", remainder)
    return not WORD.search(remainder)


def check_bundle(languages, root=ROOT):
    """The app must declare exactly English and the shipped languages, or macOS won't offer them."""
    declared = bundle_localizations(root)
    expected = [languages["source"], *languages["shipped"]]
    if declared is None:
        return [f"{APP_SPEC}: CFBundleLocalizations is missing; declare [{', '.join(expected)}]"]
    if sorted(declared) != sorted(expected):
        return [
            f"{APP_SPEC}: CFBundleLocalizations is [{', '.join(declared)}] but {LANGUAGES} ships "
            f"[{', '.join(expected)}]; keep them the same"
        ]
    return []


def check_source_percents(catalogs):
    """AppUI's English goes through `String(format:)` too: a bare `%` in it is a bug in every
    language. (InfoPlist's usage descriptions are shown by macOS and never formatted.)"""
    problems = []
    catalog = catalogs.get("AppUI")
    if catalog is not None:
        for key, entry in catalog.strings.items():
            english = source_value(entry, catalog.source)
            texts = english.values() if isinstance(english, dict) else [english]
            if any(stray_percents(text) for text in texts if isinstance(text, str)):
                problems.append(f"{CATALOGS[catalog.name]}: {key}: the English has a bare % that isn't a placeholder; write %%")
    return problems


def check_info_plist(catalogs, root=ROOT):
    """InfoPlist.xcstrings must hold the usage descriptions the app declares, word for word."""
    from .core.privacy import USAGE_DESCRIPTIONS

    catalog = catalogs.get("InfoPlist")
    if catalog is None:
        return [f"{CATALOGS['InfoPlist']} is missing"]
    problems = []
    for key, text in USAGE_DESCRIPTIONS.items():
        entry = catalog.strings.get(key)
        if entry is None:
            problems.append(f"{CATALOGS['InfoPlist']}: {key} is missing")
        elif source_value(entry, catalog.source) != text:
            problems.append(f"{CATALOGS['InfoPlist']}: {key} differs from {APP_SPEC}; keep the English the same")
    return problems


def swift_sources(root=ROOT, previews=False):
    """Arx's production Swift files; with previews, the preview apps too (they name keys)."""
    listed = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.swift"],
        cwd=root, text=True, capture_output=True, check=True,
    ).stdout.splitlines()
    roots = ("Packages/", "Sources/", "Containers/") + (("Previews/",) if previews else ())
    return [
        path for path in listed
        if path.startswith(roots) and "/Tests/" not in path
        and (previews or ("/Previews/" not in path and "Preview" not in Path(path).name))
        and "Smoke" not in Path(path).name and not path.startswith("Packages/engine/Prototypes/")
        and (Path(root) / path).is_file()
    ]


def source_findings(catalogs, root=ROOT):
    """Advisory: AppUI keys no Swift file names, and literals that look like interface text."""
    findings = []
    texts = {path: (Path(root) / path).read_text(encoding="utf-8", errors="replace") for path in swift_sources(root, previews=True)}
    corpus = "\n".join(texts.values())
    production = set(swift_sources(root))
    texts = {path: text for path, text in texts.items() if path in production}
    catalog = catalogs.get("AppUI")
    if catalog is not None:
        for key in catalog.strings:
            if "." + key not in corpus and f'"{key}"' not in corpus:
                findings.append(Finding("advice", "", catalog, key, "no Swift source refers to this key"))
    for path, text in sorted(texts.items()):
        for number, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith("//") or "Logger" in line or "log(" in line:
                continue
            for match in HARDCODED.finditer(line):
                findings.append(Finding("advice", "", path, number, f"literal bypasses the catalog: \"{match['text']}\""))
    return findings


def escape(value, *, in_property=False):
    value = value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    return value.replace(":", "%3A").replace(",", "%2C") if in_property else value


def format_finding(finding, lines, github):
    if isinstance(finding.catalog, Catalog):
        path = os.path.relpath(finding.catalog.path, ROOT) if finding.catalog.path.is_absolute() else str(finding.catalog.path)
        line = lines.get(finding.catalog.name, {}).get(finding.key, 1)
        subject = f"{finding.key}" + (f" [{finding.language}]" if finding.language else "")
    else:
        path, line, subject = finding.catalog, finding.key, ""
    level = {"error": "error", "warning": "warning"}.get(finding.level, "notice" if github else finding.level)
    message = f"{subject}: {finding.message}" if subject else finding.message
    if github:
        return f"::{level} file={escape(path, in_property=True)},line={line},title={escape('localization', in_property=True)}::{escape(message)}"
    return f"{path}:{line}: {level}: {message}"


def check(languages=None, github=False, mark_stale=False, include_sources=True, verbose=True, root=ROOT, out=None, fill=False):
    """Report findings; return the number of errors in shipped languages and the bundle."""
    out = out or sys.stdout
    config = read_languages(root)
    catalogs = load_catalogs(root)
    sources = read_sources(root)
    selected = languages or (config["shipped"] + [language for language in config["planned"] if language not in config["shipped"]])
    for language in selected:
        require_language(language)
    errors = 0
    lines = {name: catalog.line_numbers() for name, catalog in catalogs.items()}

    for problem in check_bundle(config, root) + check_info_plist(catalogs, root) + check_source_percents(catalogs):
        errors += 1
        print(f"::error::{escape(problem)}" if github else f"error: {problem}", file=out)

    summaries = []
    for language in selected:
        shipped = language in config["shipped"]
        if fill:
            filled = fill_copies(language, catalogs, kept_names(read_glossary(language, root)))
            print(f"{language}: wrote the English into {filled} entries nobody translates", file=out)
        findings = check_language(language, catalogs, sources, read_glossary(language, root), shipped)
        if mark_stale:
            marked = mark_needs_review(language, catalogs, sources)
            if marked:
                print(f"{language}: marked {marked} stale translations needs_review", file=out)
        counts = Counter((finding.level, finding.message.split(":")[0]) for finding in findings)
        language_errors = sum(1 for finding in findings if finding.level == "error")
        errors += language_errors
        if verbose or shipped:
            for finding in findings:
                if finding.level == "error" or (verbose and len(selected) == 1) or (verbose and finding.level == "warning" and shipped):
                    print(format_finding(finding, lines, github), file=out)
        summaries.append((language, shipped, findings, counts))

    if include_sources:
        advice = source_findings(catalogs, root)
        unreferenced = [finding for finding in advice if isinstance(finding.catalog, Catalog)]
        literals = [finding for finding in advice if not isinstance(finding.catalog, Catalog)]
        if verbose:
            for finding in literals:
                print(format_finding(finding, lines, github), file=out)
        print(f"Advisory: {len(unreferenced)} AppUI keys no Swift source names; {len(literals)} Swift literals look like interface text.", file=out)
        if verbose and unreferenced:
            print("  Unreferenced keys: " + ", ".join(str(finding.key) for finding in unreferenced[:40]) + (" …" if len(unreferenced) > 40 else ""), file=out)

    total = sum(1 for catalog in catalogs.values() for entry in catalog.strings.values() if translatable(entry, catalog.source))
    print(f"Localization: {total} translatable strings; shipped languages: {', '.join(config['shipped']) or 'none (English only)'}.", file=out)
    for language, shipped, findings, counts in summaries:
        kept = kept_names(read_glossary(language, root))
        total = sum(1 for catalog in catalogs.values() for entry in catalog.strings.values() if needs_translation(entry, kept, catalog.source))
        missing = sum(1 for f in findings if f.message == "missing translation")
        copies = sum(1 for f in findings if "English copy" in f.message)
        placeholder = sum(1 for f in findings if "placeholder" in f.message)
        plural = sum(1 for f in findings if "plural" in f.message)
        stale = sum(1 for f in findings if f.message.startswith(("stale", "state is")))
        same = sum(1 for f in findings if f.message == "same as the English")
        space = sum(1 for f in findings if "whitespace" in f.message)
        glossary = sum(1 for f in findings if f.message.startswith("glossary"))
        label = "shipped" if shipped else "not shipped"
        print(
            f"  {language} ({label}): {total - missing} of {total} translated; missing {missing}, "
            f"needs review or stale {stale}, placeholders {placeholder}, plurals {plural}, "
            f"same as English {same}, whitespace {space}, glossary {glossary}, English copies missing {copies}",
            file=out,
        )
    if mark_stale or fill:
        for catalog in catalogs.values():
            catalog.save()
    return errors


def mark_needs_review(language, catalogs, sources):
    marked = 0
    for catalog in catalogs.values():
        for key, entry in catalog.strings.items():
            if entry_status(catalog.name, key, entry, language, sources, catalog.source) != "stale":
                continue
            localization = entry["localizations"][language]
            units = [localization["stringUnit"]] if "stringUnit" in localization else [
                case["stringUnit"] for case in localization.get("variations", {}).get("plural", {}).values()
            ]
            for unit in units:
                unit["state"] = "needs_review"
            marked += 1
    return marked


def check_shipped(root=ROOT):
    """The failing part of the check, for `make check`: errors in shipped languages only."""
    config = read_languages(root)
    if config["shipped"]:
        errors = check(config["shipped"], include_sources=False, verbose=False, root=root)
    else:
        errors = check_errors_without_languages(root)
    if errors:
        raise LocalizationError(f"Localization check failed with {errors} errors; run make localization-check")
    print("Localization check passed.")


def check_errors_without_languages(root=ROOT):
    config = read_languages(root)
    catalogs = load_catalogs(root)
    problems = check_bundle(config, root) + check_info_plist(catalogs, root) + check_source_percents(catalogs)
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    return len(problems)


# MARK: - Commands


def export_main(arguments):
    parser = argparse.ArgumentParser(prog="make localization-export ARGS=")
    parser.add_argument("--lang", required=True)
    parser.add_argument("--chunk-size", type=int, default=DEFAULT_CHUNK_SIZE)
    parser.add_argument("--out")
    parser.add_argument("--force", action="store_true", help="start over even if DIR holds translated chunks")
    options = parser.parse_args(arguments)
    index, out = export(options.lang, options.out, options.chunk_size, force=options.force)
    states = ", ".join(f"{state} {count}" for state, count in index["states"].items()) or "nothing to translate"
    print(f"{options.lang}: {index['entries']} strings in {len(index['chunks'])} chunks ({states}) in {out}")


def import_main(arguments):
    parser = argparse.ArgumentParser(prog="make localization-import ARGS=")
    parser.add_argument("--lang", required=True)
    parser.add_argument("--from", dest="location", required=True)
    parser.add_argument("--validate-only", action="store_true")
    options = parser.parse_args(arguments)
    count, problems = import_translations(options.lang, options.location, options.validate_only)
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        raise LocalizationError(f"{options.lang}: refused, {len(problems)} problem{"" if len(problems) == 1 else "s"}; nothing was written")
    verb = "valid" if options.validate_only else "imported"
    print(f"{options.lang}: {count} translations {verb}")


def check_main(arguments):
    parser = argparse.ArgumentParser(prog="make localization-check ARGS=")
    parser.add_argument("--lang", action="append")
    parser.add_argument("--github", action="store_true", default=os.environ.get("GITHUB_ACTIONS") == "true")
    parser.add_argument("--mark-stale", action="store_true", help="set stale translations to needs_review")
    parser.add_argument("--fill", action="store_true", help="write the English into entries nobody translates (do this before shipping a language)")
    parser.add_argument("--no-sources", action="store_true", help="skip the advisory Swift source scan")
    options = parser.parse_args(arguments)
    if options.fill and not options.lang:
        raise LocalizationError("--fill needs --lang")
    errors = check(options.lang, github=options.github, mark_stale=options.mark_stale, include_sources=not options.no_sources, fill=options.fill)
    if errors:
        raise LocalizationError(f"Localization check failed with {errors} errors")


if __name__ == "__main__":
    from .core.process import execute

    commands = {"export": export_main, "import": import_main, "check": check_main}
    raise SystemExit(execute(lambda: commands[sys.argv[1]](sys.argv[2:])))
