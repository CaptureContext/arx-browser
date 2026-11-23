"""Stripping JavaScript keeps its tokens, and the vendored Readability is the stripped package (DEV-1028)."""

import unittest

from Scripts import strip_js
from Scripts.core.paths import ROOT


RESOURCES = ROOT / "Packages/services/Sources/PageReaderClient/Resources"


class StripJSTests(unittest.TestCase):
    def test_comments_and_indentation_go_and_literals_stay(self):
        source = (
            "// A comment.\n"
            "function f(a) {\n"
            "    /* Block\n"
            "       comment. */\n"
            "    const re = /\\/\\/ not a comment  [/]/g; // trailing\n"
            "    const s = '// still a string', t = `/* and ${a /* inside */} */`;\n"
            "    return a / 2 / re.lastIndex;\n"
            "}\n"
        )
        self.assertEqual(
            strip_js.strip(source),
            "function f(a) {\n"
            "const re = /\\/\\/ not a comment  [/]/g;\n"
            "const s = '// still a string', t = `/* and ${a /* inside */} */`;\n"
            "return a / 2 / re.lastIndex;\n"
            "}\n",
        )

    def test_a_line_that_changed_is_caught(self):
        self.assertTrue(strip_js.kept_verbatim("let a = 1; // one\n", "let a = 1;\n"))
        self.assertFalse(strip_js.kept_verbatim("let a = 1;\n", "let a = 2;\n"))

    def test_the_vendored_readability_is_already_stripped(self):
        for name in ["Readability.js", "Readability-readerable.js"]:
            text = (RESOURCES / name).read_text(encoding="utf-8")
            self.assertEqual(strip_js.strip(text), text, name)
            self.assertLess(len(text.encode()), 60_000, name)


if __name__ == "__main__":
    unittest.main()
