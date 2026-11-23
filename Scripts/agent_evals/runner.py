"""`make agent-evals`: each task in its own `Arx --headless` run, then a report against the baseline.

    make agent-evals [ARGS='--app PATH --task NAME --tools core|all --record --model claude']

Without `--app` it builds the signed app with the engine, as the headless smoke does. A run uses a
disposable profile and grants only the task's classes, so a task can't lean on another's state.
Every run's figures go to `build/agent-evals/<UTC time>.json`; `--record` also rewrites
`baseline.json` from a scripted run where every task passed. A failed task fails the command;
changes against the baseline are only reported.

`--tools` picks the helper's tool listing: `core`, the small set Claude Code starts with, or `all`,
every granted tool as other clients get it (DEV-1021). Comparing the two shows what the core set
saves per turn.
"""

import argparse
import json
import os
import signal
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

from .. import build_app
from ..core import smoke
from ..core.paths import ROOT
from ..headless_smoke import Run
from . import claude
from .fixtures import Fixture
from .scenarios import TASKS, Agent, TaskFailure
from .session import Session
from .usage import BYTES_PER_TOKEN, Usage

BASELINE = Path(__file__).with_name("baseline.json")
RESULTS = ROOT / "build/agent-evals"


def parse(arguments):
    parser = argparse.ArgumentParser(prog="make agent-evals ARGS=…")
    parser.add_argument("--app", help="An already built Arx.app with the engine")
    parser.add_argument("--task", action="append", choices=[task.name for task in TASKS],
                        help="Run only this task; repeat for more")
    parser.add_argument("--tools", choices=["core", "all"], default="core",
                        help="The helper's tool listing: the core set Claude Code starts with, or every tool")
    parser.add_argument("--record", action="store_true", help="Rewrite baseline.json from this run")
    parser.add_argument("--model", choices=["scripted", "claude"], default="scripted",
                        help="Who does the tasks: the stand-in agents, or Claude Code (run by hand; spends tokens)")
    parser.add_argument("--claude", help="Claude Code's executable (default: claude on PATH)")
    parser.add_argument("--claude-model", help="Claude Code's --model")
    parser.add_argument("--claude-timeout", type=int, default=300, help="Seconds a Claude Code task may take")
    options = parser.parse_args(list(arguments))
    if options.record and options.model != "scripted":
        parser.error("--record keeps the scripted baseline only")
    return options


def main(arguments=()):
    options = parse(arguments)
    tasks = [task for task in TASKS if not options.task or task.name in options.task]
    with smoke.log("agent-evals") as log:
        app = Path(options.app).resolve() if options.app else Path(
            build_app.main(log="agent-evals-build.log", signed=True, require_engine=True)
        ).resolve()
        with Fixture() as fixture, log.open("a") as output, tempfile.TemporaryDirectory() as workspace:
            results = [evaluate(app, output, fixture, task, options, workspace) for task in tasks]
        report = {
            "version": 1,
            "recorded": datetime.now(timezone.utc).date().isoformat(),
            "commit": commit(),
            "model": options.model,
            "listing": options.tools,
            "bytesPerToken": BYTES_PER_TOKEN,
            "tasks": {result.pop("name"): result for result in results},
        }
        print(table(report, load(BASELINE)))
        save(report)
        # Inside the log's context, so a failed run's log says FAILED.
        failed = [name for name, result in report["tasks"].items() if result["status"] == "fail"]
        if options.record:
            if failed or len(tasks) != len(TASKS):
                raise ValueError("The baseline is recorded only from a run of every task with no unexpected failure")
            BASELINE.write_text(json.dumps(baseline(report), indent=2) + "\n")
            print(f"Baseline: {BASELINE.relative_to(ROOT)}")
        if failed:
            raise ValueError("Failed: " + ", ".join(failed))


def evaluate(app, log, fixture, task, options, workspace):
    """One task in one headless run: its result with the usage figures."""
    fixture.clear()
    log.write(f"\n== {task.name} (--allow {task.grants})\n")
    # The run outlives the agent: a real model gets its own timeout, plus a minute to start and stop.
    lifetime = max(300, options.claude_timeout + 60) if options.model == "claude" else 300
    run = Run(app, log, "--allow", task.grants, "--timeout", str(lifetime), "--viewport", "1280x800")
    usage, answer, failure, extra = Usage(), "", None, {}
    started = time.monotonic()
    try:
        configuration = run.wait_for("ready")["configuration"]
        if options.model == "claude":
            try:
                answer, extra = claude.run(task, fixture, configuration, usage, workspace, options)
            except TaskFailure as error:
                failure = str(error)
        else:
            session = Session(configuration, usage, log, options.tools)
            agent = Agent(session, fixture)
            try:
                answer = task.agent(agent)
            except TaskFailure as error:
                failure = str(error)
            finally:
                usage.polls = agent.polls
                session.close()
    finally:
        stop(run)
    seconds = round(time.monotonic() - started, 1)
    passed, rule = (False, failure) if failure else task.check(answer, fixture)
    if passed:
        status = "fixed?" if task.known_issue else "pass"
    else:
        status = "known" if task.expected(failure) else "fail"
    log.write(f"{task.name}: {status} ({rule}) answer={answer!r}\n")
    return {"name": task.name, "passed": passed, "status": status, "knownIssue": task.known_issue,
            "rule": rule, "answer": answer, "seconds": seconds,
            **usage.summary(), **({"model": extra} if extra else {})}


def stop(run):
    if run.process.poll() is None:
        os.kill(run.process.pid, signal.SIGTERM)
    try:
        run.finish()
    except ValueError:
        pass  # A run that won't stop is killed by finish; the task's own result still stands.


# MARK: - Reporting

KEPT = ("passed", "status", "knownIssue", "calls", "polls", "work", "errors", "byTool", "tools", "bytes", "tokens", "images")


def baseline(report):
    """What the committed baseline keeps: no answers, times or machine-specific figures."""
    return {**{key: report[key] for key in ("version", "recorded", "commit", "listing", "bytesPerToken")},
            "tasks": {name: {key: result[key] for key in KEPT} for name, result in report["tasks"].items()}}


def load(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def delta(now, before):
    if before is None:
        return ""
    change = now - before
    return "=" if change == 0 else f"{change:+,}"


def table(report, previous):
    """The per-task report, with changes against `previous` for a scripted run."""
    compared = previous if report["model"] == "scripted" and previous else None
    rows = [("task", "result", "work", "Δ", "polls", "instr", "tools", "args", "results", "total tok", "Δ",
             "per turn", "Δ", "all turns", "seconds")]
    for name, result in report["tasks"].items():
        before = (compared or {}).get("tasks", {}).get(name)
        tokens = result["tokens"]
        rows.append((
            name, result["status"],
            f"{result['work']:,}", delta(result["work"], before and before["work"]), f"{result['polls']:,}",
            f"{tokens['instructions']:,}", f"{tokens['descriptions']:,}", f"{tokens['arguments']:,}",
            f"{tokens['results']:,}", f"{tokens['total']:,}",
            delta(tokens["total"], before and before["tokens"]["total"]),
            f"{tokens['perTurn']:,}", delta(tokens["perTurn"], before and before["tokens"].get("perTurn")),
            f"{tokens['allTurns']:,}", f"{result['seconds']}",
        ))
    widths = [max(len(row[column]) for row in rows) for column in range(len(rows[0]))]
    lines = ["  ".join(cell.ljust(width) if column == 0 else cell.rjust(width)
                       for column, (cell, width) in enumerate(zip(row, widths))) for row in rows]
    lines.insert(1, "  ".join("-" * width for width in widths))
    notes = [f"work: calls that do the task; polls: repeated looks while a page commits (they follow the "
             f"machine's load). Tokens are estimated at {report['bytesPerToken']} bytes each and count every "
             "call (instr: server instructions, tools: tool descriptions). per turn: the instructions and tool "
             "list a model holds at each call; all turns: the task's arguments and results plus that, once "
             f"per call. Tool listing: {report['listing']}."]
    if compared:
        notes.append(f"Δ against the baseline from {compared.get('recorded')} ({compared.get('commit')}, "
                     f"listing {compared.get('listing', 'all')}).")
    elif report["model"] == "scripted":
        notes.append("No baseline to compare with; record one with ARGS=--record.")
    for name, result in report["tasks"].items():
        if result["status"] == "fail":
            notes.append(f"{name} failed: {result['rule']}")
        elif result["status"] == "known":
            notes.append(f"{name} fails as {result['knownIssue']} says: {result['rule']}")
        elif result["status"] == "fixed?":
            notes.append(f"{name} passed: {result['knownIssue']} looks fixed; drop known_issue and record the baseline")
        if "model" in result:
            notes.append(f"{name}: Claude Code {json.dumps(result['model'])} answered {result['answer']!r}")
    return "\n".join(lines + [""] + notes)


def save(report):
    RESULTS.mkdir(parents=True, exist_ok=True)
    path = RESULTS / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-{report['model']}.json")
    path.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Results: {path.relative_to(ROOT)}")


def commit():
    head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    return head.stdout.strip() or None
