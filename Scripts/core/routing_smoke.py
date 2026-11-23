"""Owned cold-launch inputs and strict external-routing acceptance checks."""

import json
import os
from uuid import UUID
from pathlib import Path

SENTINEL = "Arx external routing fixture v1\n"
MODES = ("mainBrowser", "littleArx")


def is_owned_product(application, build_directory):
    """Xcode's Build/build spelling is not directory identity on macOS."""
    if not build_directory.is_dir():
        return False
    return any(parent.samefile(build_directory) for parent in application.resolve().parents)


def is_same_application(value, application):
    if not isinstance(value, str):
        return False
    try:
        return Path(value).samefile(application)
    except OSError:
        return False


def urls(port):
    base = f"http://127.0.0.1:{port}"
    first = base + "/routing/a/1?value=%E6%9D%B1%E4%BA%AC%2Fcaf%C3%A9%2B100%25#first"
    return [first, base + "/routing/b/2?value=two%20words%26more#second", first,
            base + "/routing/b/4?value=%3F%21%3D#last"]


def exclusive_json(path, value):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as output:
        json.dump(value, output)


def prepare(root, app, mode, port):
    if mode not in MODES or not 1 <= port <= 65535:
        raise ValueError("Invalid routing fixture configuration")
    root.chmod(0o700)
    (root / "profile").mkdir(mode=0o700)
    descriptor = os.open(root / ".arx-routing-smoke", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as output:
        output.write(SENTINEL)
    value = {"version": 1, "application": app.resolve().as_uri(), "mode": mode, "urls": urls(port)}
    exclusive_json(root / "fixture.json", value)
    return value


def verify(root, app, mode, expected, launcher):
    if launcher.returncode or "ARX_ROUTING_LAUNCHER_EXIT_SUCCESS" not in launcher.stdout:
        raise ValueError("Routing LaunchServices launcher failed")
    launch = read_json(root / "launch.json")
    result = read_json(root / "result.json")
    completion = read_json(root / "completion.json")
    if (completion.get("status") != "cleanExit"
            or any(completion.get(key) != result.get(key) for key in ("pid", "profile", "mode"))
            or not is_same_application(completion.get("application"), app)):
        raise ValueError("Routing runtime did not report a matching clean exit")
    if (not isinstance(launch.get("pid"), int) or launch["pid"] <= 1
            or result.get("status") != "passed" or result.get("pid") != launch.get("pid")
            or not is_same_application(result.get("application"), app)
            or not is_same_application(launch.get("application"), app)
            or result.get("profile") != str(root / "profile") or result.get("mode") != mode
            or result.get("received") != expected or result.get("committed") != expected
            or len(result.get("tabIDs", [])) != 4 or len(set(result["tabIDs"])) != 4):
        raise ValueError(f"Routing acceptance failed: {result.get('status', 'missing result')}")
    for tab_id in result["tabIDs"]:
        UUID(tab_id)
    workspace = read_json(root / "profile/arx-workspace.json")
    tabs = workspace["organization"]["tabs"]
    if mode == "littleArx":
        if tabs:
            raise ValueError("Little external URLs entered the durable workspace")
        # Little Arx pages are ordinary pages of their profile (DEV-728): only the
        # routed URLs themselves may reach history.
        for path in (root / "profile/History").glob("*.json"):
            if any(entry.get("url") not in expected for entry in read_json(path)["snapshot"]["entries"]):
                raise ValueError("Unexpected URLs entered ordinary browsing history")
    elif ([tab["id"] for tab in tabs] != result["tabIDs"]
          or [tab["restoration"]["url"] for tab in tabs] != expected):
        raise ValueError("Normal external URLs were not all persisted in order")
    return result


def read_json(path):
    if path.is_symlink() or path.stat().st_size > 65536:
        raise ValueError("Invalid routing result file")
    return json.loads(path.read_text())


def serve(handler):
    """Storage identity is set once per real profile; shared/wrong profiles fail titles."""
    path = handler.path.split("?", 1)[0]
    if path not in ("/routing/a/1", "/routing/b/2", "/routing/b/4"):
        handler.send_error(404)
        return
    identity = path.split("/")[2]
    body = ("<!doctype html><script>"
            f"if (!localStorage.routeProfile) localStorage.routeProfile='{identity}';"
            "document.title='Arx routing|'+localStorage.routeProfile+'|'+location.href;"
            "</script><p>External routing fixture</p>").encode()
    handler.send_response(200)
    handler.send_header("Content-Type", "text/html; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(body)
