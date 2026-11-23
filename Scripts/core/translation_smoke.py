"""The French page the app smoke translates (DEV-996).

With the ARX_TRANSLATE feature flag on, as it is by default (DEV-1143), the app says Translation
Available for the page, translates it in place with its link kept on the translated words, and
Show Original brings the French back, in an ordinary window and a private one. A Mac that hasn't
downloaded French and English for Apple's translation, or a run with the flag turned off, skips
the stage and says so: the smoke never downloads languages.
"""

from pathlib import Path

MARKERS = ("ARX_TRANSLATE_SMOKE_TRANSLATED", "ARX_TRANSLATE_SMOKE_PRIVATE", "ARX_TRANSLATE_SMOKE_SUCCESS")
SKIPPED = "ARX_TRANSLATE_SMOKE_SKIPPED"


def prepare(root: Path):
    """`translate.html`: French paragraphs, one with a link inside its sentence."""
    (root / "translate.html").write_text(
        '<!doctype html><html lang="fr"><head><meta charset="utf-8"><title>Arx traduction</title></head>'
        "<body><h1>Les réglages</h1>"
        '<p>Cliquez <a id="link" href="#reglages">ici</a> pour ouvrir les réglages de la page.</p>'
        "<p>Bonjour tout le monde, ceci est une page de test pour la traduction.</p>"
        "</body></html>",
        encoding="utf-8",
    )


def verify(stdout: str):
    """Every step, or the skip on a Mac without the languages."""
    if SKIPPED in stdout:
        return
    if any(marker not in stdout for marker in MARKERS):
        raise ValueError("Translation smoke did not complete")
