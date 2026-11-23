"""make agent-evals (DEV-1026): accounting, fixtures, the stand-in agents, the relay and the report.

The headless runs themselves need the signed app with the engine and are `make agent-evals`'s
own; these tests drive the agents against a fake MCP session that answers as Arx does.
"""

import json
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import urllib.parse
import urllib.request
import unittest.mock
from pathlib import Path

from Scripts.agent_evals import claude, runner, scenarios, session
from Scripts.agent_evals.fixtures import Fixture
from Scripts.agent_evals.scenarios import Agent, Reply, TaskFailure
from Scripts.agent_evals.usage import Usage, tokens


def text_result(value, *, error=False, images=0):
    """A tools/call result shaped as Arx sends it: JSON text content plus the structured result."""
    content = [{"type": "text", "text": json.dumps({"result": value})}]
    content += [{"type": "image", "data": "AAAA", "mimeType": "image/png"}] * images
    return {"content": content, "structuredContent": {"result": value}, "isError": error}


class UsageTests(unittest.TestCase):
    def test_tokens_round_up_at_four_bytes(self):
        self.assertEqual([tokens(0), tokens(1), tokens(4), tokens(5)], [0, 1, 1, 2])

    def test_exchanges_add_up_to_the_summary(self):
        usage = Usage()
        tool = {"name": "browser_read", "description": "Reads a page.", "inputSchema": {"type": "object"},
                "annotations": {"readOnlyHint": True}}
        usage.observe({"method": "initialize"}, {"result": {"instructions": "x" * 40}})
        usage.observe({"method": "tools/list"}, {"result": {"tools": [tool]}})
        usage.observe({"method": "tools/call", "params": {"name": "browser_read", "arguments": {"a": 1}}},
                      {"result": text_result({"text": "hello"}, images=2)})
        usage.observe({"method": "tools/call", "params": {"name": "browser_click", "arguments": {}}},
                      {"result": text_result({"kind": "error", "code": "denied"}, error=True)})
        usage.observe({"method": "tools/call", "params": {"name": "browser_read", "arguments": {"bad": 1}}},
                      {"error": {"code": -32602, "message": "Invalid params"}})
        usage.observe({"method": "tools/list"}, {"error": {"code": -32000}})

        summary = usage.summary()
        self.assertEqual(summary["calls"], 3)
        self.assertEqual(summary["errors"], 2)
        self.assertEqual(summary["byTool"], {"browser_click": 1, "browser_read": 2})
        self.assertEqual(usage.calls[2].error, "-32602")
        self.assertEqual(summary["images"], 2)
        # Annotations aren't part of what a model reads of a tool.
        described = len(json.dumps({"name": "browser_read", "description": "Reads a page.",
                                    "inputSchema": {"type": "object"}}, separators=(",", ":")))
        self.assertEqual(summary["bytes"]["descriptions"], described)
        self.assertEqual(summary["bytes"]["instructions"], 40)
        self.assertEqual(summary["bytes"]["arguments"], len('{"a":1}') + len("{}") + len('{"bad":1}'))
        self.assertEqual(summary["tokens"]["total"], tokens(40 + described) + summary["tokens"]["arguments"]
                         + summary["tokens"]["results"])
        self.assertEqual(usage.calls[1].error, "denied")

    def test_each_call_carries_the_tool_list_it_was_made_with(self):
        usage = Usage()
        usage.observe({"method": "initialize"}, {"result": {"instructions": "x" * 400}})
        usage.listed([{"name": "a" * 390}])
        usage.called("first", {}, text_result({}))
        usage.listed([{"name": "a" * 390}, {"name": "b" * 1990}])
        usage.called("second", {}, text_result({}))
        first, second = (call.context_bytes for call in usage.calls)
        self.assertEqual(second - first, len(json.dumps({"name": "b" * 1990, "description": None, "inputSchema": None},
                                                        separators=(",", ":"))))
        figures = usage.summary()["tokens"]
        self.assertEqual(figures["perTurn"], tokens((first + second) // 2))
        self.assertEqual(figures["allTurns"], tokens(first) + tokens(second) + figures["arguments"] + figures["results"])

    def test_without_calls_a_turn_carries_the_listing(self):
        usage = Usage()
        usage.observe({"method": "initialize"}, {"result": {"instructions": "x" * 40}})
        usage.listed([{"name": "a"}])
        figures = usage.summary()["tokens"]
        self.assertEqual(figures["perTurn"], tokens(usage.context_bytes()))
        self.assertEqual(figures["allTurns"], figures["perTurn"])

    def test_a_later_tool_list_replaces_the_first(self):
        usage = Usage()
        usage.listed([{"name": "a"}, {"name": "b"}])
        usage.listed([{"name": "a"}])
        self.assertEqual(usage.tools, 1)


class FixtureTests(unittest.TestCase):
    def test_pages_and_posts(self):
        with Fixture() as fixture:
            with urllib.request.urlopen(fixture.url("/article")) as response:
                self.assertIn("opened to traffic in 1932", response.read().decode())
            data = urllib.parse.urlencode({"name": "Ada", "topic": "delivery"}).encode()
            with urllib.request.urlopen(fixture.url("/submit"), data=data) as response:
                self.assertIn("on its way", response.read().decode())
            with self.assertRaises(urllib.error.HTTPError):
                urllib.request.urlopen(fixture.url("/missing"))
            self.assertEqual(fixture.posted(), [{"name": "Ada", "topic": "delivery"}])
            fixture.clear()
            self.assertEqual(fixture.posted(), [])


class FakeArx:
    """Answers the agents' calls as Arx would, from canned page text, and records each call."""

    TEXT = {
        "/article": "The Old Bridge turns 94\nThe engineer, Marta Hollis, chose stone over steel.\n"
                    "The Old Bridge opened to traffic in 1932, a year late.",
        "/shop/kettle-a": "Brightline kettle\nPrice: €34.90",
        "/shop/kettle-b": "Northwind kettle\nPrice: €29.50",
        "/contact": "Contact us",
        "/newsletter": "The Courier's weekly letter",
        "/submit": "Thanks, your message is on its way.",
    }
    # As Arx's snapshot gives a form: labels beside unnamed controls, a button without its text.
    FORM = [
        {"index": 0, "role": "form"},
        {"index": 1, "parent": 0, "role": "paragraph"},
        {"index": 2, "parent": 1, "role": "labelText"},
        {"index": 3, "parent": 2, "role": "staticText", "text": "Name"},
        {"index": 4, "parent": 1, "role": "textField", "reference": "name"},
        {"index": 5, "parent": 0, "role": "paragraph"},
        {"index": 6, "parent": 5, "role": "labelText"},
        {"index": 7, "parent": 6, "role": "staticText", "text": "Email"},
        {"index": 8, "parent": 5, "role": "textField", "reference": "email"},
        {"index": 9, "parent": 0, "role": "paragraph"},
        {"index": 10, "parent": 9, "role": "labelText"},
        {"index": 11, "parent": 10, "role": "staticText", "text": "Topic"},
        {"index": 12, "parent": 9, "role": "comboBoxSelect", "reference": "topic"},
        {"index": 13, "parent": 0, "role": "labelText"},
        {"index": 14, "parent": 13, "role": "staticText", "text": "Message"},
        {"index": 15, "parent": 13, "role": "textField", "reference": "message"},
        {"index": 16, "parent": 0, "role": "button", "reference": "send"},
        {"index": 17, "parent": 16, "role": "staticText"},
    ]
    NEWSLETTER = [
        {"index": 0, "role": "form"},
        {"index": 1, "parent": 0, "role": "labelText"},
        {"index": 2, "parent": 1, "role": "staticText", "text": "Email address"},
        {"index": 3, "parent": 0, "role": "textField", "reference": "address"},
        {"index": 4, "parent": 0, "role": "button", "reference": "subscribe"},
    ]

    def __init__(self, tools=None, refuse=None, batch_uses_up_snapshot=False, types_email=True, sends=False,
                 fills=True):
        self.tools = tools or {"browser_inventory", "browser_tabs", "browser_wait", "browser_read",
                               "browser_inspect", "browser_batch", "browser_replace_text"}
        self.refuse = refuse
        self.added = set()
        self.batch_uses_up_snapshot = batch_uses_up_snapshot
        self.types_email = types_email
        # Whether a press on Send message goes through rather than asking, which Arx never lets an
        # unattended run do (DEV-1008), and whether a field takes what the agent puts in it.
        self.sends = sends
        self.fills = fills
        self.values = {}
        self.calls = []
        self.tabs = {}

    def list_tools(self):
        self.calls.append(("tools/list", {}))
        return self.tools | self.added

    def call(self, tool, arguments):
        self.calls.append((tool, arguments))
        if tool == "browser_more_tools":
            added = {"browser_find", "browser_find_in_page"} if arguments["groups"] == ["find"] else set()
            self.added |= added
            return Reply(True, {"kind": "moreTools", "added": sorted(added), "notGranted": []}, None)
        if tool == "browser_find":
            text = self.TEXT[self.tabs[arguments["targetID"]]]
            excerpts = [{"index": 3, "role": "paragraph", "excerpt": "…" + line.strip()[:120]}
                        for line in text.splitlines() if arguments["query"] in line]
            return Reply(True, {"kind": "find", "matches": excerpts}, None)
        if tool == "browser_inventory":
            items = [{"kind": "space", "id": "space", "revision": "1"}]
            items += [{"kind": "tab", "id": tab, "revision": "2", "sessionState": "ready"} for tab in self.tabs]
            return Reply(True, {"items": items}, None)
        if tool == "browser_tabs":
            tab = f"tab-{len(self.tabs) + 1}"
            self.tabs[tab] = urllib.parse.urlparse(arguments["url"]).path
            return Reply(True, {"kind": "acceptedLoading", "targetID": tab}, None)
        if tool == "browser_wait":
            return Reply(True, {"kind": "wait"}, None)
        if tool == "browser_read":
            return Reply(True, {"kind": "read", "text": self.TEXT[self.tabs[arguments["targetID"]]]}, None)
        if tool == "browser_inspect":
            nodes = self.nodes(arguments)
            if arguments.get("formValues"):
                nodes = [{**node, "value": self.values[node["reference"]]} if node.get("reference") in self.values
                         else node for node in nodes]
            return Reply(True, {"kind": "inspection", "snapshotID": "snap", "nodes": nodes}, None)
        if self.refuse:
            return Reply(False, {"kind": "error", "code": self.refuse}, self.refuse)
        if tool == "browser_batch":
            tab = arguments["steps"][0]["arguments"]["targetID"]
            if self.batch_uses_up_snapshot:
                steps = [{"index": 0, "result": {"disposition": "dispatched", "failure": None}},
                         {"index": 1, "result": {"disposition": "notDispatched", "failure": "staleReference"}}]
                self.fill(arguments["steps"][0]["arguments"])
                return Reply(False, {"kind": "batch", "completed": 1, "stoppedAt": 1, "steps": steps}, "error")
            if any(step["tool"] == "browser_click" for step in arguments["steps"]):
                return Reply(False, {"kind": "error", "code": "userActionRequired"}, "userActionRequired")
            for step in arguments["steps"]:
                self.fill(step["arguments"])
            return Reply(True, {"kind": "batch"}, None)
        if tool in ("browser_replace_text", "browser_select_value", "browser_click", "browser_type"):
            if tool == "browser_type" and not self.types_email:
                return Reply(False, {"kind": "form", "disposition": "possiblyDispatched", "failure": "staleReference"},
                             "error")
            if tool == "browser_replace_text" and arguments["reference"] in ("email", "address"):
                # As Arx answers for an <input type="email">.
                snapshot = {"snapshotID": "after-refusal", "nodes": self.nodes(arguments)}
                return Reply(False, {"kind": "form", "failure": "unsupportedControl", "snapshot": snapshot}, "error")
            if tool == "browser_click":
                if arguments["reference"] == "send" and not self.sends:
                    # As Arx answers a press that sends, with nobody there to ask.
                    return Reply(False, {"kind": "click", "disposition": "notDispatched",
                                         "failure": "userActionRequired"}, "error")
                self.tabs[arguments["targetID"]] = "/submit"
                if arguments["reference"] == "subscribe":
                    return Reply(True, {"kind": "click"}, None)
                # As Arx answers a click whose page left before the snapshot.
                return Reply(False, {"kind": "click", "disposition": "dispatched", "failure": "staleReference"}, "error")
            self.fill(arguments)
            return Reply(True, {"kind": "form", "snapshot": {"snapshotID": "next", "nodes": self.nodes(arguments)}}, None)
        raise AssertionError(f"Unexpected call {tool}")

    def fill(self, arguments):
        value = arguments.get("value", arguments.get("text"))
        if value is not None:
            # A select reads back as its option's text.
            self.values[arguments["reference"]] = (value.title() if arguments["reference"] == "topic" else value) \
                if self.fills else ""

    def nodes(self, arguments):
        return self.NEWSLETTER if self.tabs[arguments["targetID"]] == "/newsletter" else self.FORM


class FakeFixture:
    def __init__(self, posted=()):
        self.submissions = list(posted)

    def url(self, path):
        return "http://127.0.0.1:1" + path

    def posted(self):
        return self.submissions


class AgentTests(unittest.TestCase):
    def tools(self, arx):
        return [tool for tool, _ in arx.calls]

    def test_finding_adds_the_find_group_once_when_it_is_missing(self):
        arx = FakeArx()
        answer = scenarios.find_engineer(Agent(arx, FakeFixture()))
        self.assertEqual(answer, "The engineer was Marta Hollis.")
        self.assertTrue(scenarios.check_engineer(answer, FakeFixture())[0])
        self.assertEqual(self.tools(arx)[:2], ["browser_more_tools", "tools/list"])
        self.assertEqual(arx.calls[0][1], {"groups": ["find"]})
        self.assertIn("browser_find", self.tools(arx))

    def test_a_listed_find_tool_is_used_without_asking_for_more(self):
        arx = FakeArx(tools=FakeArx().tools | {"browser_find"})
        scenarios.find_engineer(Agent(arx, FakeFixture()))
        self.assertNotIn("browser_more_tools", self.tools(arx))

    def test_a_group_that_adds_nothing_fails_the_task(self):
        arx = FakeArx()
        with self.assertRaisesRegex(TaskFailure, "not browser_capture"):
            Agent(arx, FakeFixture()).more("browser_capture", "screenshots")

    def test_reading_an_article_opens_waits_and_reads_once(self):
        arx = FakeArx()
        answer = scenarios.read_article(Agent(arx, FakeFixture()))
        self.assertEqual(answer, "The Old Bridge opened in 1932.")
        self.assertEqual(self.tools(arx), ["browser_inventory", "browser_tabs", "browser_inventory",
                                           "browser_wait", "browser_read"])
        read = arx.calls[-1][1]
        self.assertEqual((read["format"], read["scope"]), ("text", "main"))
        self.assertTrue(scenarios.check_article(answer, FakeFixture())[0])
        for wrong in ("It opened in 1929, not 1932.", "19320", "Work began in 1929."):
            self.assertFalse(scenarios.check_article(wrong, FakeFixture())[0], wrong)

    def test_the_fields_go_in_one_batch_on_the_controls_and_send_asks_on_its_own(self):
        arx = FakeArx()
        answer = scenarios.send_contact_form(Agent(arx, FakeFixture()))
        batch = next(arguments for tool, arguments in arx.calls if tool == "browser_batch")
        steps = [(step["tool"], step["arguments"]["reference"], step["arguments"].get("value"))
                 for step in batch["steps"]]
        self.assertEqual(steps, [
            ("browser_replace_text", "name", "Ada Lovelace"),
            ("browser_replace_text", "email", "ada@example.invalid"),
            ("browser_select_value", "topic", "delivery"),
            ("browser_replace_text", "message", "My kettle hasn't arrived yet. Order 4471."),
        ])
        operations = {step["arguments"]["operationID"] for step in batch["steps"]}
        self.assertEqual(len(operations), 4)
        # Send asks every time (DEV-1008): after a look at what the fields hold, it goes on its own.
        after = arx.calls[[tool for tool, _ in arx.calls].index("browser_batch") + 1:]
        self.assertEqual([(tool, arguments.get("formValues")) for tool, arguments in after],
                         [("browser_inspect", True), ("browser_click", None)])
        self.assertEqual(after[-1][1]["reference"], "send")
        self.assertTrue(answer.startswith("NEEDS:"), answer)
        self.assertTrue(scenarios.check_contact_form(answer, FakeFixture())[0])
        self.assertFalse(scenarios.check_contact_form(answer, FakeFixture([scenarios.CONTACT]))[0])
        self.assertFalse(scenarios.check_contact_form("Sent: your message is on its way.", FakeFixture())[0])
        self.assertFalse(scenarios.check_contact_form("NEEDS:", FakeFixture())[0])

    def test_the_answer_may_name_what_waits_right_after_needs(self):
        check = scenarios.check_contact_form
        for answer in ("NEEDS: Send message", "NEEDS: approval to submit the contact form.",
                       "needs: your permission in Arx to press Send"):
            self.assertTrue(check(answer, FakeFixture())[0], answer)
        self.assertFalse(check("NEEDS: nothing.", FakeFixture())[0])

    def test_a_field_that_doesnt_hold_its_value_fails_before_send(self):
        arx = FakeArx(fills=False)
        with self.assertRaisesRegex(TaskFailure, "Name holds ''"):
            scenarios.send_contact_form(Agent(arx, FakeFixture()))
        self.assertNotIn("browser_click", self.tools(arx))

    def test_a_send_that_goes_through_unasked_fails_the_task(self):
        with self.assertRaisesRegex(TaskFailure, "without asking"):
            scenarios.send_contact_form(Agent(FakeArx(sends=True), FakeFixture()))

    def test_when_a_step_uses_up_the_batch_snapshot_the_rest_go_one_at_a_time(self):
        arx = FakeArx(batch_uses_up_snapshot=True)
        answer = scenarios.send_contact_form(Agent(arx, FakeFixture()))
        after = self.tools(arx)[self.tools(arx).index("browser_batch") + 1:]
        self.assertEqual(after, ["browser_inspect", "browser_replace_text", "browser_type", "browser_select_value",
                                 "browser_replace_text", "browser_inspect", "browser_click"])
        # Each step takes the snapshot the call before returned; the email field is typed instead.
        acted = [(tool, arguments["snapshotID"]) for tool, arguments in arx.calls if "returnSnapshot" in arguments]
        self.assertEqual(acted, [("browser_replace_text", "snap"), ("browser_type", "after-refusal"),
                                 ("browser_select_value", "next"), ("browser_replace_text", "next")])
        typed = next(arguments for tool, arguments in arx.calls if tool == "browser_type")
        self.assertEqual((typed["reference"], typed["text"]), ("email", "ada@example.invalid"))
        self.assertTrue(answer.startswith("NEEDS:"), answer)

    def test_an_email_field_is_typed_when_replacing_is_refused(self):
        arx = FakeArx()
        answer = scenarios.subscribe(Agent(arx, FakeFixture()))
        acted = [tool for tool, arguments in arx.calls if "reference" in arguments]
        self.assertEqual(acted, ["browser_replace_text", "browser_type", "browser_click"])
        self.assertIn("ada@example.invalid", answer)
        self.assertTrue(scenarios.check_subscription(answer, FakeFixture([{"address": "ada@example.invalid"}]))[0])

    def test_an_email_field_that_nothing_fills_fails_the_task(self):
        with self.assertRaisesRegex(TaskFailure, "Neither replacing nor typing"):
            scenarios.subscribe(Agent(FakeArx(types_email=False), FakeFixture()))

    def test_a_named_control_or_a_button_with_text_wins(self):
        nodes = [
            {"index": 0, "role": "textField", "name": "Search", "reference": "search"},
            {"index": 1, "role": "button", "reference": "go"},
            {"index": 2, "parent": 1, "role": "staticText", "text": "Go"},
            {"index": 3, "role": "button", "reference": "cancel"},
            {"index": 4, "parent": 3, "role": "staticText", "text": "Cancel"},
        ]
        self.assertEqual(scenarios.reference(nodes, "search"), "search")
        self.assertEqual(scenarios.reference(nodes, "Cancel", button=True), "cancel")
        with self.assertRaises(TaskFailure):
            scenarios.reference(nodes, "Send", button=True)

    def test_an_inventory_read_during_a_change_is_read_again(self):
        arx = FakeArx()
        stale = iter([Reply(False, {"kind": "error", "code": "staleTarget"}, "staleTarget")])
        call = arx.call
        arx.call = lambda tool, arguments: next(stale, None) or call(tool, arguments)
        self.assertEqual(Agent(arx, FakeFixture()).inventory()[0]["kind"], "space")

    def test_comparing_names_the_cheaper_kettle_with_both_prices(self):
        answer = scenarios.compare_kettles(Agent(FakeArx(), FakeFixture()))
        self.assertEqual(answer, "Cheaper: Northwind kettle (€29.50); other: Brightline kettle (€34.90)")
        self.assertTrue(scenarios.check_kettles(answer, FakeFixture())[0])
        self.assertTrue(scenarios.check_kettles("cheaper: Northwind (29.50 EUR); Other: Brightline (34.90 EUR)",
                                                FakeFixture())[0])
        for wrong in ("Northwind is cheaper: €29.50 vs €34.90.",
                      "Cheaper: Northwind (€129.50); other: Brightline (€134.90)",
                      "Cheaper: Northwind (€29.50 or €30); other: Brightline (€34.90)",
                      "Cheaper: Brightline kettle (€34.90); other: Northwind kettle (€29.50)",
                      "Cheaper: Northwind kettle (€29.50)"):
            self.assertFalse(scenarios.check_kettles(wrong, FakeFixture())[0], wrong)

    def test_a_read_after_the_page_moved_on_reads_the_revision_again(self):
        arx = FakeArx()
        stale = iter([True])
        call = arx.call

        def once_stale(tool, arguments):
            if tool == "browser_read" and next(stale, False):
                arx.calls.append((tool, arguments))
                return Reply(False, {"kind": "error", "code": "staleTarget"}, "staleTarget")
            return call(tool, arguments)

        arx.call = once_stale
        self.assertEqual(scenarios.read_article(Agent(arx, FakeFixture())), "The Old Bridge opened in 1932.")
        self.assertEqual(self.tools(arx)[-3:], ["browser_read", "browser_inventory", "browser_read"])

    def test_only_the_expected_failure_counts_as_the_known_issue(self):
        task = next(task for task in scenarios.TASKS if task.name == "email-input")
        self.assertTrue(task.expected("Neither replacing nor typing fills the email field: possiblyDispatched/staleReference"))
        self.assertFalse(task.expected("Neither replacing nor typing fills the email field: notDispatched/denied"))
        self.assertFalse(task.expected("Tab 1 never stopped loading"))
        self.assertFalse(task.expected(None))

    def test_looks_while_a_page_loads_are_polls_not_work(self):
        arx = FakeArx()
        states = iter(["loading", "loading"])
        call = arx.call

        def loading_first(tool, arguments):
            reply = call(tool, arguments)
            tabs = [item for item in reply.value.get("items", []) if item["kind"] == "tab"]
            if tool == "browser_inventory" and tabs:
                state = next(states, "ready")
                for item in tabs:
                    item["sessionState"] = state
            return reply

        arx.call = loading_first
        agent = Agent(arx, FakeFixture())
        scenarios.read_article(agent)
        # inventory, openTab, two loading looks, the ready look and wait, read: two polls.
        self.assertEqual((agent.calls, agent.polls), (7, 2))

    def test_without_the_interaction_tools_the_agent_asks_without_calling(self):
        arx = FakeArx(tools={"browser_inventory", "browser_tabs", "browser_wait", "browser_read", "browser_inspect"})
        answer = scenarios.send_without_interaction(Agent(arx, FakeFixture()))
        self.assertEqual(arx.calls, [])
        self.assertTrue(scenarios.check_without_interaction(answer, FakeFixture())[0])

    def test_the_refusal_answer_must_say_what_is_needed(self):
        check = scenarios.check_without_interaction
        self.assertTrue(check("NEEDS: the interact grant in Arx.", FakeFixture())[0])
        self.assertFalse(check("No approval is necessary; the form was sent.", FakeFixture())[0])
        self.assertFalse(check("NEEDS:", FakeFixture())[0])
        self.assertFalse(check("NEEDS: the interact grant.", FakeFixture([scenarios.CONTACT]))[0])

    def test_a_refused_change_is_reported_not_worked_around(self):
        arx = FakeArx(refuse="userActionRequired")
        answer = scenarios.send_without_interaction(Agent(arx, FakeFixture()))
        self.assertIn("userActionRequired", answer)
        self.assertEqual(self.tools(arx)[-1], "browser_replace_text")
        self.assertFalse(scenarios.check_without_interaction(answer, FakeFixture([scenarios.CONTACT]))[0])

    def test_an_unexpected_refusal_fails_the_task(self):
        with self.assertRaises(TaskFailure):
            scenarios.send_without_interaction(Agent(FakeArx(refuse="staleReference"), FakeFixture()))

    def test_every_task_has_a_distinct_name_and_a_prompt_with_its_addresses(self):
        names = [task.name for task in scenarios.TASKS]
        self.assertEqual(len(names), len(set(names)))
        for task in scenarios.TASKS:
            self.assertIn("http://127.0.0.1:1/", task.ask(FakeFixture()))
            self.assertIn("read", task.grants.split(","))


class SessionTests(unittest.TestCase):
    def test_a_rejected_call_is_counted_and_fails_the_task(self):
        helper = ("import json, sys\n"
                  "for line in sys.stdin:\n"
                  "    message = json.loads(line)\n"
                  "    if message.get('method') == 'initialize':\n"
                  "        reply = {'result': {'instructions': 'hi'}}\n"
                  "    elif message.get('method') == 'tools/list':\n"
                  "        reply = {'result': {'tools': [{'name': 'browser_read'}]}}\n"
                  "    elif 'id' in message:\n"
                  "        reply = {'error': {'code': -32602, 'message': 'Invalid params'}}\n"
                  "    else:\n"
                  "        continue\n"
                  "    print(json.dumps({'jsonrpc': '2.0', 'id': message['id'], **reply}), flush=True)\n")
        with tempfile.TemporaryDirectory() as directory:
            configuration = Path(directory) / "mcp.json"
            configuration.write_text(json.dumps({"mcpServers": {"arx": {
                "command": sys.executable, "args": ["-c", helper], "env": {}}}}))
            usage = Usage()
            client = session.Session(configuration, usage)
            try:
                self.assertEqual(client.tools, {"browser_read"})
                with self.assertRaises(TaskFailure):
                    client.call("browser_read", {"targetID": "x"})
            finally:
                client.close()
        self.assertEqual([(call.tool, call.error) for call in usage.calls], [("browser_read", "-32602")])


class RelayTests(unittest.TestCase):
    def test_the_relay_passes_messages_through_and_records_them(self):
        helper = ("import json, sys\n"
                  "for line in sys.stdin:\n"
                  "    message = json.loads(line)\n"
                  "    if 'id' in message:\n"
                  "        print(json.dumps({'jsonrpc': '2.0', 'id': message['id'], 'result': "
                  "{'content': [{'type': 'text', 'text': 'pong'}]}}), flush=True)\n")
        with tempfile.TemporaryDirectory() as directory:
            transcript = Path(directory) / "transcript.jsonl"
            relay = Path(session.__file__).with_name("relay.py")
            requests = [
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "browser_read", "arguments": {}}},
            ]
            finished = subprocess.run(
                [sys.executable, "-I", str(relay), str(transcript), sys.executable, "-c", helper],
                input="".join(json.dumps(request) + "\n" for request in requests),
                capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(finished.returncode, 0, finished.stderr)
            self.assertEqual(json.loads(finished.stdout)["id"], 1)
            usage = Usage()
            session.account(transcript, usage)
            self.assertEqual([(call.tool, call.result_bytes) for call in usage.calls], [("browser_read", 4)])

    def test_a_relayed_call_keeps_the_tool_list_it_was_sent_with(self):
        with tempfile.TemporaryDirectory() as directory:
            transcript = Path(directory) / "t.jsonl"
            records = [
                ("client", {"id": 1, "method": "tools/list"}),
                ("server", {"id": 1, "result": {"tools": [{"name": "a"}]}}),
                ("client", {"id": 2, "method": "tools/call", "params": {"name": "browser_more_tools", "arguments": {}}}),
                # The client reads the grown list before the call's own reply arrives.
                ("client", {"id": 3, "method": "tools/list"}),
                ("server", {"id": 3, "result": {"tools": [{"name": "a"}, {"name": "b" * 400}]}}),
                ("server", {"id": 2, "result": {"content": []}}),
                ("client", {"id": 4, "method": "tools/call", "params": {"name": "browser_find", "arguments": {}}}),
                ("server", {"id": 4, "result": {"content": []}}),
            ]
            transcript.write_text("".join(json.dumps({"from": who, "message": message}) + "\n" for who, message in records))
            usage = Usage()
            session.account(transcript, usage)
            first, second = usage.calls
            self.assertLess(first.context_bytes, second.context_bytes)
            self.assertEqual(first.context_bytes, len('{"name":"a","description":null,"inputSchema":null}'))

    def test_the_relayed_configuration_keeps_the_helper_and_its_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            configuration = Path(directory) / "mcp.json"
            configuration.write_text(json.dumps({"mcpServers": {"arx": {
                "command": "/Arx.app/Contents/Helpers/ArxMCP", "env": {"ARX_MCP_TOKEN": "t"}}}}))
            relayed = session.relay_configuration(configuration, Path(directory) / "t.jsonl")["mcpServers"]["arx"]
            self.assertEqual(relayed["env"], {"ARX_MCP_TOKEN": "t"})
            self.assertEqual(relayed["args"][-1], "/Arx.app/Contents/Helpers/ArxMCP")
            self.assertTrue(relayed["args"][1].endswith("relay.py"))
            listed = session.relay_configuration(configuration, Path(directory) / "t.jsonl", "all")["mcpServers"]["arx"]
            self.assertEqual(listed["env"], {"ARX_MCP_TOKEN": "t", "ARX_MCP_TOOLS": "all"})


class ReportTests(unittest.TestCase):
    def result(self, *, passed=True, calls=5, total=900, per_turn=700):
        return {"passed": passed, "status": "pass" if passed else "fail", "knownIssue": None,
                "rule": "rule", "answer": "an answer", "seconds": 3.2, "calls": calls + 2,
                "polls": 2, "work": calls, "errors": 0, "byTool": {}, "tools": 40, "bytes": {}, "images": 0,
                "tokens": {"instructions": 100, "descriptions": 600, "arguments": 50, "results": 150, "total": total,
                           "perTurn": per_turn, "allTurns": 4 * per_turn + 200}}

    def report(self, **result):
        return {"version": 1, "recorded": "2026-11-16", "commit": "abc", "model": "scripted", "listing": "core",
                "bytesPerToken": 4,
                "tasks": {"read-article": self.result(**result)}}

    def test_the_baseline_keeps_figures_not_answers_or_times(self):
        kept = runner.baseline(self.report())["tasks"]["read-article"]
        self.assertNotIn("answer", kept)
        self.assertNotIn("seconds", kept)
        self.assertEqual((kept["calls"], kept["work"], kept["polls"]), (7, 5, 2))

    def test_the_table_shows_changes_against_the_baseline(self):
        table = runner.table(self.report(calls=4, total=950), runner.baseline(self.report()))
        row = next(line for line in table.splitlines() if line.startswith("read-article"))
        self.assertIn("-1", row)
        self.assertIn("+50", row)
        self.assertIn("baseline from 2026-11-16", table)
        self.assertIn("listing core", table)

    def test_the_table_shows_the_turn_cost_against_the_baseline(self):
        table = runner.table(self.report(per_turn=300), runner.baseline(self.report()))
        row = next(line for line in table.splitlines() if line.startswith("read-article"))
        self.assertIn("-400", row)
        self.assertIn("1,400", row)
        self.assertEqual(runner.baseline(self.report())["listing"], "core")

    def test_without_a_baseline_the_table_says_how_to_record_one(self):
        self.assertIn("ARGS=--record", runner.table(self.report(), None))

    def test_a_failed_task_is_named(self):
        self.assertIn("read-article failed: rule", runner.table(self.report(passed=False), None))

    def test_a_known_issue_is_reported_and_a_pass_says_it_looks_fixed(self):
        report = self.report(passed=False)
        report["tasks"]["read-article"].update(status="known", knownIssue="DEV-1")
        self.assertIn("fails as DEV-1 says", runner.table(report, None))
        report["tasks"]["read-article"].update(status="fixed?", passed=True)
        self.assertIn("DEV-1 looks fixed", runner.table(report, None))

    def test_only_a_scripted_run_records_the_baseline(self):
        with self.assertRaises(SystemExit), open("/dev/null", "w") as quiet:
            stderr, sys.stderr = sys.stderr, quiet
            try:
                runner.parse(["--record", "--model", "claude"])
            finally:
                sys.stderr = stderr
        self.assertTrue(runner.parse(["--record"]).record)

    def test_the_core_listing_is_the_default(self):
        self.assertEqual(runner.parse([]).tools, "core")
        self.assertEqual(runner.parse(["--tools", "all"]).tools, "all")


class ClaudeTests(unittest.TestCase):
    def test_a_timeout_fails_the_task_and_keeps_what_was_recorded(self):
        class Options:
            claude = sys.executable
            claude_model = None
            claude_timeout = 1
            tools = "core"

        task = scenarios.TASKS[0]
        with tempfile.TemporaryDirectory() as directory, unittest.mock.patch.object(
            claude.subprocess, "run", side_effect=subprocess.TimeoutExpired("claude", 1)
        ):
            configuration = Path(directory) / "mcp.json"
            configuration.write_text(json.dumps({"mcpServers": {"arx": {"command": "/ArxMCP", "env": {}}}}))
            transcript = Path(directory) / f"{task.name}.jsonl"
            transcript.write_text(
                json.dumps({"from": "client", "message": {"id": 1, "method": "tools/call", "params": {"name": "browser_inventory"}}})
                + "\n" + json.dumps({"from": "server", "message": {"id": 1, "result": {"content": []}}}) + "\n")
            usage = Usage()
            with self.assertRaisesRegex(TaskFailure, "longer than 1 s"):
                claude.run(task, FakeFixture(), configuration, usage, directory, Options())
            self.assertEqual([call.tool for call in usage.calls], ["browser_inventory"])

    def test_claude_code_gets_only_the_arx_server(self):
        arguments = claude.command("claude", "Do it", "/tmp/mcp.json", "sonnet")
        self.assertIn("--strict-mcp-config", arguments)
        self.assertEqual(arguments[arguments.index("--tools") + 1], "")
        self.assertEqual(arguments[arguments.index("--allowedTools") + 1], "mcp__arx")
        self.assertEqual(arguments[-2:], ["--model", "sonnet"])

    def test_the_stream_gives_the_answer_and_the_figures(self):
        lines = [
            json.dumps({"type": "system", "subtype": "init"}),
            json.dumps({"type": "assistant", "message": {"content": [
                {"type": "tool_use", "name": "mcp__arx__browser_inventory"}, {"type": "text", "text": "…"}]}}),
            "not json",
            json.dumps({"type": "result", "result": " 1932. ", "num_turns": 3, "total_cost_usd": 0.01,
                        "usage": {"input_tokens": 10, "cache_read_input_tokens": 5, "output_tokens": 7}}),
        ]
        answer, figures = claude.parse(lines)
        self.assertEqual(answer, "1932.")
        self.assertEqual(figures, {"turns": 3, "inputTokens": 15, "outputTokens": 7, "costUSD": 0.01, "toolUses": 1})


if __name__ == "__main__":
    unittest.main()
