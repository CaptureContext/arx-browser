import io
import json
import unittest
import uuid
from urllib.parse import urlencode

from Scripts.core import reference_form_fixture as fixture


class Server:
    pass


class Handler:
    def __init__(self, server, path):
        self.server, self.path = server, path
        self.wfile = io.BytesIO()
        self.status = None
    def send_response(self, status):
        self.status = status
    def send_header(self, *_):
        pass
    def end_headers(self):
        pass


class ReferenceFormFixtureTests(unittest.TestCase):
    def setUp(self):
        self.server = Server()
        self.token = str(uuid.uuid4())

    def get(self, path):
        handler = Handler(self.server, path)
        self.assertTrue(fixture.serve(handler))
        return handler

    def create(self, mode="main"):
        response = self.get(f"/reference-form/{mode}?run={self.token}")
        self.assertEqual(response.status, 200)
        return response.wfile.getvalue().decode()

    def event(self, **changes):
        values = dict(target="text", event="input", trusted="1", activation="0", focused="0", correct="1")
        values.update(changes)
        return self.get(f"/reference-form/event/{self.token}?{urlencode(values)}")

    def test_each_owned_route_requires_unique_canonical_run(self):
        for mode in fixture.MODES:
            self.token = str(uuid.uuid4())
            self.create(mode)
            self.assertEqual(self.get(f"/reference-form/{mode}?run={self.token}").status, 409)
        self.assertEqual(self.get("/reference-form/main?run=invalid").status, 400)
        self.assertEqual(self.get("/reference-form/main").status, 400)
        self.assertEqual(self.get(f"/reference-form/main?run={self.token}&value=secret").status, 400)

    def test_evidence_is_bounded_value_free_and_owned_by_server(self):
        self.create()
        self.assertEqual(self.event().status, 204)
        self.assertEqual(self.event(value="secret").status, 400)
        self.assertEqual(self.event(correct="secret").status, 400)
        self.assertEqual(self.event(target="password").status, 400)
        state = self.get(f"/reference-form/state/{self.token}")
        events = json.loads(state.wfile.getvalue())["events"]
        self.assertEqual(events, [dict(target="text", event="input", trusted=True, activation=False, focused=False, correct=True)])
        for _ in range(fixture.MAXIMUM_EVENTS - 1):
            self.assertEqual(self.event().status, 204)
        self.assertEqual(self.event().status, 400)
        other = Handler(Server(), f"/reference-form/state/{self.token}")
        self.assertTrue(fixture.serve(other))
        self.assertEqual(other.status, 404)

    def test_property_mutation_acknowledgement_cannot_change_dom(self):
        page = self.create("value")
        mutation = page.split("element('mutate').onclick=", 1)[1]
        self.assertIn("input.value='replacement'", mutation)
        self.assertIn("input.setSelectionRange", mutation)
        self.assertIn("report('mutation'", mutation)
        self.assertNotIn("document.title=", mutation)
        self.assertNotIn("textContent=", mutation)
        self.assertIn("if(!e.isTrusted)return", mutation)

    def test_sensitive_baselines_and_exact_event_contract_remain_present(self):
        page = self.create()
        for name in fixture.NAMES.values():
            self.assertIn(name, page)
        for marker in ("ARX_FORM_PASSWORD", "ARX_FORM_FORMER_PASSWORD", "type=\"file\"", "display:none", "visibility:hidden"):
            self.assertIn(marker, page)
        self.assertIn("element('former').type='text'", page)
        self.assertIn("['input','change']", page)
        self.assertIn("navigator.userActivation.isActive", page)
        self.assertIn("document.activeElement===element(target)", page)
        self.assertNotIn(".focus(", page)

    def test_unknown_paths_and_unbounded_run_admission_are_rejected(self):
        for _ in range(fixture.MAXIMUM_RUNS):
            self.token = str(uuid.uuid4())
            self.create()
        self.token = str(uuid.uuid4())
        self.assertEqual(self.get(f"/reference-form/main?run={self.token}").status, 409)
        self.assertEqual(self.get("/reference-form/profile/Preferences").status, 404)
