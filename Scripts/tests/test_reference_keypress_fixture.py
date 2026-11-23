import io
import json
import unittest
import uuid
from urllib.parse import urlencode

from Scripts.core import reference_keypress_fixture as fixture


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


class ReferenceKeypressFixtureTests(unittest.TestCase):
    def setUp(self):
        self.server = Server()
        self.token = str(uuid.uuid4())

    def get(self, path):
        handler = Handler(self.server, path)
        self.assertTrue(fixture.serve(handler))
        return handler

    def create(self, mode="printable"):
        response = self.get(f"/reference-keypress/{mode}?run={self.token}")
        self.assertEqual(response.status, 200)
        return response.wfile.getvalue().decode()

    def event(self, **changes):
        values = dict(target="target", event="keydown", trusted="1", activation="0", focused="0", correct="1")
        values.update(changes)
        return self.get(f"/reference-keypress/event/{self.token}?{urlencode(values)}")

    def test_each_owned_route_requires_unique_canonical_run(self):
        for mode in fixture.MODES:
            self.token = str(uuid.uuid4())
            self.create(mode)
            self.assertEqual(self.get(f"/reference-keypress/{mode}?run={self.token}").status, 409)
        self.assertEqual(self.get("/reference-keypress/printable?run=invalid").status, 400)
        self.assertEqual(self.get("/reference-keypress/printable").status, 400)
        self.assertEqual(self.get(f"/reference-keypress/printable?run={self.token}&value=secret").status, 400)

    def test_evidence_is_bounded_value_free_and_owned_by_server(self):
        self.create()
        self.assertEqual(self.event().status, 204)
        self.assertEqual(self.event(value="secret").status, 400)
        self.assertEqual(self.event(correct="secret").status, 400)
        self.assertEqual(self.event(target="password").status, 400)
        state = self.get(f"/reference-keypress/state/{self.token}")
        events = json.loads(state.wfile.getvalue())["events"]
        self.assertEqual(events, [dict(target="target", event="keydown", trusted=True, activation=False, focused=False, correct=True)])
        for _ in range(fixture.MAXIMUM_EVENTS - 1):
            self.assertEqual(self.event().status, 204)
        self.assertEqual(self.event().status, 400)
        other = Handler(Server(), f"/reference-keypress/state/{self.token}")
        self.assertTrue(fixture.serve(other))
        self.assertEqual(other.status, 404)

    def test_hostile_handlers_are_static_and_do_not_upload_values(self):
        page = self.create()
        for marker in ("mode===type+'-focus'", "mode===type+'-selection'", "target.value='author'",
                       "event.preventDefault()", "mode==='enter-change'", "navigator.userActivation.isActive",
                       "textInput", "target.focus();target.setSelectionRange(2,2)", "scrollY===200"):
            self.assertIn(marker, page)
        self.assertIn(r"enter:'ab\ncd'", page)
        self.assertNotIn(r"enter:'ab\\ncd'", page)
        self.assertNotIn("eval(", page)
        self.assertNotIn("query.set('value'", page)
        self.assertNotIn("event.key", page)
        self.assertIn("correct:String(+correct())", page)

    def test_native_runner_requires_all_hostile_and_receipt_evidence(self):
        from Scripts.engine import smoke
        self.assertIn("ARX_REFERENCE_KEYPRESS_SMOKE_HOSTILE_DEFAULTS", smoke.REFERENCE_KEYPRESS_MARKERS)
        self.assertIn("ARX_REFERENCE_KEYPRESS_SMOKE_SUPPRESSION_SUBMISSION", smoke.REFERENCE_KEYPRESS_MARKERS)
        self.assertIn("ARX_REFERENCE_KEYPRESS_SMOKE_CANCEL_FOCUS", smoke.REFERENCE_KEYPRESS_MARKERS)
