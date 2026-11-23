"""Dark pages (DEV-1020): both web-preference paths end with Arx's decision."""

from pathlib import Path
import tempfile
import unittest

from Scripts.engine import dark_pages_overlay


def prepare(root):
    for relative, old, _ in dark_pages_overlay.patches():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write(old + "\n")


class DarkPagesOverlayTests(unittest.TestCase):
    def test_applies_once_after_the_color_scheme_and_after_navigation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            dark_pages_overlay.apply(root)
            client = root / dark_pages_overlay.CLIENT
            first = client.read_text()
            dark_pages_overlay.apply(root)
            self.assertEqual(first, client.read_text())

            self.assertEqual(first.count('#include "chrome/browser/arx/dark_pages_bridge.h"'), 1)
            # OverrideWebPreferences, after the embedder parts.
            self.assertEqual(first.count("  arx::ApplyDarkPages(web_contents, web_prefs);"), 1)
            # OverrideWebPreferencesAfterNavigation reports the change, so the renderer gets it.
            self.assertEqual(first.count("  prefs_changed |= arx::ApplyDarkPages(web_contents, web_prefs);"), 1)
            self.assertLess(
                first.index("prefs_changed |= arx::ApplyDarkPages"),
                first.index("WebPreferencesNeedUpdateForColorRelatedStateChanges("),
            )
            self.assertEqual(first.count("#if BUILDFLAG(IS_MAC)"), 3)

    def test_a_document_with_its_own_dark_theme_turns_forced_darkening_off(self):
        """DEV-1077, DEV-1094, DEV-1095: the rules that apply decide, after every sheet update."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            dark_pages_overlay.apply(root)
            names = (dark_pages_overlay.STYLE_ENGINE_H, dark_pages_overlay.STYLE_ENGINE,
                     dark_pages_overlay.MEDIA_QUERIES, dark_pages_overlay.RULE_SET_H,
                     dark_pages_overlay.RULE_SET)
            texts = {name: (root / name).read_text() for name in names}
            dark_pages_overlay.apply(root)
            for name, text in texts.items():
                self.assertEqual(text, (root / name).read_text(), name)

            engine = texts[dark_pages_overlay.STYLE_ENGINE]
            # Forced darkening is read from the settings, then dropped while the theme holds.
            self.assertLess(engine.index("force_dark_mode_enabled_ = settings->GetForceDarkModeEnabled();"),
                            engine.index("if (has_own_dark_theme_) {"))
            # Recomputed after every active style sheet update, both ways.
            self.assertLess(engine.index("probe::ActiveStyleSheetsUpdated(document_);"),
                            engine.index("  UpdateHasOwnDarkTheme();\n"))
            self.assertIn("if (has_own_dark_theme == has_own_dark_theme_) {", engine)
            self.assertIn("GetDocumentStyleSheetCollection().ActiveStyleSheets()", engine)
            # Shadow trees and a sheet's own media count too.
            self.assertIn("for (TreeScope* tree_scope : active_tree_scopes_) {", engine)
            self.assertIn("active.first ? active.first->MediaQueries() : nullptr;", engine)
            # Extensions' user-origin sheets, and media queries in CSS functions and if().
            self.assertIn("holds_dark_theme(active_user_style_sheets_);", engine)
            self.assertLess(engine.index("query_set, &functional_media_query_result_flags_);"),
                            engine.index("if (result && ArxQuerySetMatchedDarkScheme() && !has_functional_dark_theme_) {"))
            # Functional answers are asked again before Blink drops their results.
            self.assertLess(engine.index("if (has_functional_dark_theme != has_functional_dark_theme_) {"),
                            engine.index("  functional_media_query_results_.clear();"))
            # Never inside the style update: a task updates the color scheme.
            self.assertIn("BindOnce(&StyleEngine::UpdateOwnDarkTheme", engine)

            rules = texts[dark_pages_overlay.RULE_SET]
            # The rule set asks right after its own evaluation, which only rules that apply reach.
            self.assertLess(rules.index("evaluator.Eval(*media_queries, &features_.MutableMediaQueryResultFlags());"),
                            rules.index("if (match_media && ArxQuerySetMatchedDarkScheme()) {"))
            self.assertIn("bool HasOwnDarkTheme() const { return has_own_dark_theme_; }",
                          texts[dark_pages_overlay.RULE_SET_H])
            # A mixin's media dependencies count as the cache check counts them.
            self.assertLess(rules.index("media_query_set_results_.append_range(mixins.media_query_set_results);"),
                            rules.index("for (const MediaQuerySetResult& result : mixins.media_query_set_results) {"))
            # A cached rule set is rebuilt when its dark answer changes.
            self.assertIn("return has_own_dark_theme != has_own_dark_theme_;", rules)

            queries = texts[dark_pages_overlay.MEDIA_QUERIES]
            # The feature only records that it matched; the whole query decides.
            self.assertLess(queries.index("arx_dark_scheme_matched = true;"),
                            queries.index("return (preferred_scheme == mojom::blink::PreferredColorScheme::kDark"))
            self.assertIn("result == KleeneValue::kTrue && arx_dark_scheme_matched;", queries)
            self.assertIn("arx_query_set_matched_dark_scheme = matched_dark_scheme;", queries)
            # Reset before the empty set's early return, so a media-less @import never inherits it.
            self.assertLess(queries.index("  arx_query_set_matched_dark_scheme = false;\n"),
                            queries.index("return true;  // An empty query list evaluates to true."))
            # A later query in the list may be the dark one.
            # Its dependencies join the flags, so a resize that changes the answer is noticed.
            self.assertIn("Eval(*queries[i], result_flags, custom_medias) == KleeneValue::kTrue &&", queries)
            # The evaluator no longer tells the document itself: a matchMedia call doesn't count.
            self.assertNotIn("NoteOwnDarkTheme", queries + engine + texts[dark_pages_overlay.STYLE_ENGINE_H])

    def test_a_tree_prepared_with_dev_1077_takes_the_current_insertions(self):
        """DEV-1094: DEV-1077's first insertions go back to upstream, then the current ones apply."""
        from Scripts.engine.dark_pages_dev1077 import INSERTIONS
        with tempfile.TemporaryDirectory() as fresh, tempfile.TemporaryDirectory() as earlier:
            fresh, earlier = Path(fresh), Path(earlier)
            # Both trees hold every upstream line either overlay anchors on.
            for root in (fresh, earlier):
                prepare(root)
                for relative, upstream, _ in INSERTIONS:
                    path = root / relative
                    if path.read_text().count(upstream) == 0:
                        with path.open("a") as stream:
                            stream.write(upstream + "\n")
            for relative, upstream, inserted in INSERTIONS:
                path = earlier / relative
                text = path.read_text()
                self.assertEqual(text.count(upstream), 1, relative)
                path.write_text(text.replace(upstream, inserted, 1))
            dark_pages_overlay.apply(fresh)
            dark_pages_overlay.apply(earlier)
            for relative, _, _ in dark_pages_overlay.patches():
                self.assertEqual((fresh / relative).read_text(), (earlier / relative).read_text(), relative)
            # And applying again changes nothing.
            dark_pages_overlay.apply(earlier)
            for relative, _, _ in dark_pages_overlay.patches():
                self.assertEqual((fresh / relative).read_text(), (earlier / relative).read_text(), relative)

    def test_a_changed_upstream_anchor_stops_preparation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            client = root / dark_pages_overlay.CLIENT
            client.write_text(client.read_text().replace("parts->OverrideWebPreferences", "parts->Override"))
            with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                dark_pages_overlay.apply(root)


if __name__ == "__main__":
    unittest.main()
