"""The reusable click fixture has deterministic owned routes and effect evidence."""

import io
import unittest
from types import SimpleNamespace

from Scripts.core import reference_click_fixture as fixture


class ReferenceClickFixtureTests(unittest.TestCase):
    def test_routes_only_serve_exact_owned_pages(self):
        handler = SimpleNamespace(path="/outside", wfile=io.BytesIO())
        self.assertFalse(fixture.serve(handler))
        for path in fixture.DOCUMENTS:
            events = []
            handler = SimpleNamespace(path=path + "?test=1", wfile=io.BytesIO(),
                                      send_response=lambda value: events.append(value),
                                      send_header=lambda key, value: events.append((key, value)),
                                      end_headers=lambda: None)
            self.assertTrue(fixture.serve(handler))
            body = handler.wfile.getvalue()
            self.assertIn(("Content-Length", str(len(body))), events)
            self.assertIn(("Cache-Control", "no-store"), events)

    def test_counter_is_only_changed_by_trusted_target_handler(self):
        main = fixture.DOCUMENTS["/reference-click/main"]
        self.assertEqual(main.count("count++;"), 1)
        self.assertIn("if(!event.isTrusted)", main)
        self.assertIn("navigator.userActivation.isActive", main)
        self.assertIn("aria-label=\"" + fixture.BUTTON_NAME + "\"", main)
        self.assertIn("'Arx reference count='+count+' trusted=true activation='+active", main)

    def test_mutation_delay_and_hidden_variants_are_distinct(self):
        self.assertIn("performance.now()+1200", fixture.DOCUMENTS["/reference-click/slow"])
        self.assertIn("#target{opacity:0", fixture.DOCUMENTS["/reference-click/transparent"])
        self.assertIn("old.replaceWith(replacement)", fixture.MAIN)
        self.assertIn("old.remove();parent.appendChild(old)", fixture.MAIN)
        self.assertNotIn("ARX_FIXTURE_DELAY", "".join(fixture.DOCUMENTS.values()))
        self.assertIn('href="/reference-click/destination"', fixture.MAIN)
