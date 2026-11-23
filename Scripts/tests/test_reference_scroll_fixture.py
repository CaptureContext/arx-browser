import json
import unittest
import uuid
from urllib.parse import urlencode

from Scripts.core import reference_scroll_fixture as fixture
from Scripts.tests.test_reference_form_fixture import Handler, Server


class ReferenceScrollFixtureTests(unittest.TestCase):
    def setUp(self):
        self.server = Server()
        self.token = str(uuid.uuid4())

    def get(self, path):
        handler = Handler(self.server, path)
        self.assertTrue(fixture.serve(handler))
        return handler

    def create(self):
        result = self.get(f"/reference-scroll/main?run={self.token}")
        self.assertEqual(result.status, 200)
        return result.wfile.getvalue().decode()

    def report(self, **changes):
        state = dict(innerX="0", innerY="80", outerX="0", outerY="0", pageX="0", pageY="0",
                     sample="1", events="1", focused="0", activation="0", trusted="1", innerAtEnd="0")
        state.update(changes)
        return self.get(f"/reference-scroll/report/{self.token}?{urlencode(state)}")

    def test_owned_reuse_invalid_queries_and_private_files_are_denied(self):
        self.create()
        self.assertEqual(self.get(f"/reference-scroll/main?run={self.token}").status, 409)
        self.assertEqual(self.get("/reference-scroll/main?run=invalid").status, 400)
        self.assertEqual(self.get("/reference-scroll/profile/Preferences").status, 404)
        other = Handler(Server(), f"/reference-scroll/state/{self.token}")
        self.assertTrue(fixture.serve(other))
        self.assertEqual(other.status, 404)

    def test_only_bounded_numeric_and_boolean_effect_evidence_is_retained(self):
        self.create()
        for change in ({"innerY": "nan"}, {"innerY": "inf"}, {"pageX": "100001"},
                       {"sample": "10001"}, {"events": "-1"}, {"trusted": "true"}, {"value": "secret"}):
            self.assertEqual(self.report(**change).status, 400)
        self.assertEqual(self.report().status, 204)
        self.assertEqual(self.report().status, 400)
        value = json.loads(self.get(f"/reference-scroll/state/{self.token}").wfile.getvalue())
        self.assertEqual(value["innerY"], 80)
        self.assertTrue(value["trusted"])
        self.assertFalse(value["focused"])
        self.assertFalse(value["activation"])

    def test_nested_axis_clamping_and_observation_do_not_mutate_focus_or_dom(self):
        page = self.create()
        self.assertIn("overflow-y:auto;overflow-x:hidden", page)
        self.assertIn("scroll-behavior:smooth", page)
        self.assertIn("inner.scrollHeight-inner.clientHeight", page)
        self.assertIn("event.isTrusted", page)
        self.assertIn("navigator.userActivation.isActive", page)
        self.assertNotIn(".focus(", page)
        self.assertNotIn("scrollTo(", page)
        self.assertNotIn("textContent=", page)

    def test_bounded_run_admission_and_report_length(self):
        for _ in range(fixture.MAXIMUM_RUNS):
            self.token = str(uuid.uuid4())
            self.create()
        self.token = str(uuid.uuid4())
        self.assertEqual(self.get(f"/reference-scroll/main?run={self.token}").status, 409)
        self.assertEqual(self.get("/reference-scroll/report/" + "a" * 4096).status, 400)
