"""Arx's branding in place of Helium's (DEV-1100).

Helium copies its logo over Chromium's (helium-chromium's `resources/helium_resources.txt`)
and renames Chrome and Chromium to Helium in every string (`utils/name_substitution.py`).
The engine shows both: macOS Now Playing takes `IDR_PRODUCT_LOGO_256` when a page gives no
Media Session artwork (`SystemMediaControlsNotifier::UpdateIcon`, through
`ChromeContentBrowserClient::GetProductLogo`), the framework bundles
`product_logo_32.png`, and the locale paks name Helium.

`apply` puts Arx's renders (`Packages/engine/Branding`, from `render_branding.swift`) at
each of Helium's logo destinations, and renames Helium to Arx in the string and translation
files. The string pass follows Helium's own: each changed message gets its new fingerprint,
and the translations that pointed at the old one point at the new one, so they still apply.
"The Helium Authors" (copyright) and `helium://` addresses stay as they are.

`check` fails the build when any of Helium's logos or its name come back, for example after
Helium updates its resources.
"""
import os
import re
import sys
import xml.etree.ElementTree as xml

from .config import PACKAGE

ASSETS = PACKAGE / "Branding"

# Helium's logo destinations and Arx's render for each.
LOGOS = {
    "chrome/app/theme/chromium/product_logo_16.png": "product_logo_16.png",
    "chrome/app/theme/chromium/product_logo_24.png": "product_logo_24.png",
    "chrome/app/theme/chromium/product_logo_48.png": "product_logo_48.png",
    "chrome/app/theme/chromium/product_logo_64.png": "product_logo_64.png",
    "chrome/app/theme/chromium/product_logo_128.png": "product_logo_128.png",
    "chrome/app/theme/chromium/product_logo_256.png": "product_logo_256.png",
    "chrome/app/theme/chromium/linux/product_logo_24.png": "product_logo_24.png",
    "chrome/app/theme/chromium/linux/product_logo_48.png": "product_logo_48.png",
    "chrome/app/theme/chromium/linux/product_logo_64.png": "product_logo_64.png",
    "chrome/app/theme/chromium/linux/product_logo_128.png": "product_logo_128.png",
    "chrome/app/theme/chromium/linux/product_logo_256.png": "product_logo_256.png",
    "chrome/app/theme/default_100_percent/chromium/product_logo_16.png": "product_logo_16.png",
    "chrome/app/theme/default_100_percent/chromium/product_logo_32.png": "product_logo_32.png",
    "chrome/app/theme/default_100_percent/chromium/linux/product_logo_16.png": "product_logo_16.png",
    "chrome/app/theme/default_100_percent/chromium/linux/product_logo_32.png": "product_logo_32.png",
    "chrome/app/theme/default_200_percent/chromium/product_logo_16.png": "product_logo_32.png",
    "chrome/app/theme/default_200_percent/chromium/product_logo_32.png": "product_logo_64.png",
    "components/resources/default_100_percent/chromium/product_logo.png": "product_logo_140.png",
    "components/resources/default_200_percent/chromium/product_logo.png": "product_logo_280.png",
    "components/resources/default_100_percent/chromium/product_logo_white.png": "product_logo_white_140.png",
    "components/resources/default_200_percent/chromium/product_logo_white.png": "product_logo_white_280.png",
    "chrome/app/theme/chromium/product_logo_22_mono.png": "product_logo_22_mono.png",
    "chrome/app/theme/chromium/product_logo.svg": "product_logo.svg",
    # The helpers' icon (helium-macos's platform_resources.txt): the Alerts helpers show it.
    "chrome/app/theme/chromium/mac/app.icns": "app.icns",
    "chrome/app/theme/chromium/mac/Assets.car": "Assets.car",
    # Helium's vector logo, drawn by Chrome's own views and notifications.
    "chrome/app/vector_icons/browser_logo.icon": "arx_mark.icon",
    "chrome/app/vector_icons/browser_logo_old.icon": "arx_mark.icon",
    "chrome/app/vector_icons/chrome_product.icon": "arx_mark.icon",
    "components/omnibox/browser/vector_icons/chrome_product.icon": "arx_mark.icon",
    "components/omnibox/browser/vector_icons/product_chrome_refresh.icon": "arx_mark.icon",
    "components/omnibox/browser/vector_icons/product_chrome_refresh_old.icon": "arx_mark.icon",
    "components/omnibox/browser/vector_icons/product_old.icon": "arx_mark.icon",
    "components/vector_icons/chromium/product.icon": "arx_mark.icon",
    "components/vector_icons/chromium/product_refresh.icon": "arx_mark.icon",
    "ui/message_center/vector_icons/chrome_product.icon": "arx_mark.icon",
    "ui/message_center/vector_icons/product_old.icon": "arx_mark.icon",
}

# Helium's name, not "The Helium Authors" and not a helium:// address. Only Latin letters and
# digits around it make it part of another word: translations write it beside Han and Hangul
# text (重新安装Helium, Helium이) and in compounds (Helium-Steuerfelder).
NAME = re.compile(r"(?<![A-Za-z0-9_/.])Helium(?![A-Za-z0-9_]| Authors)")
STRING_EXTENSIONS = (".grd", ".grdp", ".xtb")
# Helium's own skips, and the platforms Arx doesn't build.
SKIPPED_DIRECTORIES = {"out", ".pc", "chromeos", "remoting", "ash", "testdata", "ios", "android"}


def string_files(source):
    for root, directories, files in os.walk(source):
        directories[:] = [name for name in directories if name not in SKIPPED_DIRECTORIES and not name.startswith(".")]
        for name in files:
            if name.endswith(STRING_EXTENSIONS):
                path = os.path.join(root, name)
                with open(path, "rb") as stream:
                    if b"Helium" in stream.read():
                        yield path


def _rename(text):
    renamed = NAME.sub("Arx", text)
    return renamed, renamed != text


def _rename_element(element):
    changed = False
    if element.text:
        element.text, did = _rename(element.text)
        changed |= did
    if element.tail:
        element.tail, did = _rename(element.tail)
        changed |= did
    for child in element:
        changed |= _rename_element(child)
    return changed


def _fingerprint(message):
    # Grit's own message id: the text with each placeholder's name, and the meaning.
    from grit.extern import tclib
    text = message.text or ""
    for placeholder in message.findall("ph"):
        text += placeholder.get("name").upper() + (placeholder.tail or "")
    text = text.strip()
    if text.startswith("'''"):
        text = text[3:]
    if text.endswith("'''"):
        text = text[:-3]
    return tclib.GenerateMessageId(text.strip(), message.get("meaning", ""))


def _parser():
    return xml.XMLParser(target=xml.TreeBuilder(insert_comments=True))


def rename_strings(source):
    """Helium's name to Arx's in the string and translation files, translations kept."""
    grit = str(source / "tools/grit")
    if grit not in sys.path:
        sys.path.insert(0, grit)
    paths = list(string_files(source))
    fingerprints = {}
    for path in (p for p in paths if not p.endswith(".xtb")):
        with open(path, encoding="utf-8") as stream:
            text = stream.read()
        tree = xml.fromstring(_protect(text)[0], _parser())
        changed = False
        for message in tree.iter("message"):
            before = _fingerprint(message)
            if _rename_element_inner(message):
                changed = True
                after = _fingerprint(message)
                if after != before:
                    fingerprints[before] = after
        if changed:
            _write(path, tree, text)
    for path in (p for p in paths if p.endswith(".xtb")):
        with open(path, encoding="utf-8") as stream:
            text = stream.read()
        tree = xml.fromstring(_protect(text)[0], _parser())
        changed = False
        seen = set()
        for translation in tree.iter("translation"):
            if _rename_element_inner(translation):
                changed = True
            identifier = fingerprints.get(translation.get("id"), translation.get("id"))
            # Two messages that now read the same share a fingerprint; grit refuses a
            # duplicate id, so the later one moves aside, as Helium's pass does.
            while identifier in seen and identifier.isdigit():
                identifier = str(int(identifier) + 1)
            if identifier != translation.get("id"):
                translation.set("id", identifier)
                changed = True
            seen.add(identifier)
        if changed:
            _write(path, tree, text)


def _rename_element_inner(element):
    """An element's own text and its children's, not its tail (which belongs to its parent)."""
    changed = False
    if element.text:
        element.text, did = _rename(element.text)
        changed |= did
    for child in element:
        changed |= _rename_element(child)
    return changed


def _prolog(text):
    """What comes before the root element, exactly as the file had it: an XML declaration, a
    DOCTYPE and comments, or nothing. Helium's own generators read some of these files as text
    and expect the root first (helium_onboarding_strings.grdp has no declaration)."""
    index = 0
    while True:
        start = text.find("<", index)
        if start < 0 or not text.startswith(("<?", "<!"), start):
            return text[:max(start, 0)]
        end = text.find("-->", start) + 3 if text.startswith("<!--", start) else text.find(">", start) + 1
        index = end


_REFERENCE = re.compile(r"&(?:#[0-9]+|#x[0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]*);")
_TOKEN = 0xF0000


def _protect(text):
    """The text with each character or entity reference swapped for a private-use character,
    and the references in order. The XML parser would decode them, and a decoded `&#36;` before
    a digit reads to grit as a placeholder outside <ph>; written back as they were, the file
    only changes where a name was renamed."""
    references = []

    def swap(match):
        references.append(match.group(0))
        return chr(_TOKEN + len(references) - 1)

    return _REFERENCE.sub(swap, text), references


def _restore(serialized, references):
    return "".join(
        references[ord(character) - _TOKEN] if _TOKEN <= ord(character) < _TOKEN + len(references) else character
        for character in serialized
    )


def _write(path, tree, text):
    references = _protect(text)[1]
    with open(path, "w", encoding="utf-8") as stream:
        stream.write(_prolog(text) + _restore(xml.tostring(tree, encoding="unicode"), references))
        if text.endswith("\n"):
            stream.write("\n")


def apply(source):
    for relative, asset in LOGOS.items():
        target = source / relative
        data = (ASSETS / asset).read_bytes()
        if not target.exists() or target.read_bytes() != data:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
    rename_strings(source)


def problems(source):
    """What still carries Helium's branding: logos not Arx's, and string files naming Helium."""
    found = [relative for relative, asset in LOGOS.items()
             if not (source / relative).exists() or (source / relative).read_bytes() != (ASSETS / asset).read_bytes()]
    for path in string_files(source):
        with open(path, encoding="utf-8") as stream:
            tree = xml.fromstring(stream.read(), _parser())
        # What the engine shows: messages and translations, not comments or descriptions.
        tag = "translation" if path.endswith(".xtb") else "message"
        if any(NAME.search("".join(element.itertext())) for element in tree.iter(tag)):
            found.append(os.path.relpath(path, source))
    return found


def check(source):
    found = problems(source)
    if found:
        listed = "\n  ".join(found[:20])
        raise ValueError(f"Helium's branding is back in the engine source (DEV-1100):\n  {listed}")


PAK_NAME = re.compile(rb"(?<![A-Za-z0-9_/.])Helium(?![A-Za-z0-9_]| Authors)")


def check_framework(resources):
    """The built framework: Arx's logo, and no Helium name in its English strings."""
    logo = resources / "product_logo_32.png"
    if logo.read_bytes() != (ASSETS / "product_logo_32.png").read_bytes():
        raise ValueError(f"The engine framework bundles Helium's logo (DEV-1100): {logo}")
    for helper in sorted((resources.parent / "Helpers").glob("*.app")):
        icon = helper / "Contents/Resources/app.icns"
        if icon.exists() and icon.read_bytes() != (ASSETS / "app.icns").read_bytes():
            raise ValueError(f"The engine framework's helper has Helium's icon (DEV-1100): {icon}")
    for locale in ("en.lproj", "en_GB.lproj"):
        pak = resources / locale / "locale.pak"
        if pak.exists() and PAK_NAME.search(pak.read_bytes()):
            raise ValueError(f"The engine framework's strings name Helium (DEV-1100): {pak}")
