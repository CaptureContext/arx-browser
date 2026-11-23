"""make engine-hosts: every host the engine framework has hard-coded, and a check on them (DEV-930).

It reads the printable strings of every Mach-O binary in the framework (the framework itself,
its helpers and libraries) and finds two kinds of host:

* URL hosts, from `http://`, `https://`, `ws://` and `wss://` URLs. These are what code could
  fetch, open or show as a link.
* Bare host names, as in Chromium's HSTS preload and pinning tables. These are data, so only
  Helium's own appear in the check.

The check fails on any Helium host (`helium.computer`, `imput.net`), in a URL or bare, and on any
Google URL host that isn't in `allowed-hosts.json` with a reason. Everything found is listed in
`build/logs/engine-hosts.txt`. `make engine-build` runs the check before it marks a build complete.

Resource packs (`.pak`) are compressed and aren't read; WebUI pages there reach the network only
through the same browser code the binary holds.
"""

import argparse
import json
import re
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

from ..core.paths import ROOT


ALLOWED = Path(__file__).with_name("allowed-hosts.json")
REPORT = ROOT / "build/logs/engine-hosts.txt"
MACHO_MAGIC = {
    b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
}
PRINTABLE = re.compile(rb"[\x20-\x7e]{6,}")
URL = re.compile(r"\b(?:https?|wss?)://([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+)")
BARE = re.compile(r"(?<![A-Za-z0-9.-])((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+(?:computer|net))(?![A-Za-z0-9-])")

HELIUM_DOMAINS = ("helium.computer", "imput.net")
GOOGLE_DOMAINS = (
    "google", "google.com", "googleapis.com", "gstatic.com", "googleusercontent.com", "gvt1.com",
    "gvt2.com", "doubleclick.net", "google-analytics.com", "googlesyndication.com",
    "googletagmanager.com", "googleadservices.com", "youtube.com", "ytimg.com", "ggpht.com",
    "googlevideo.com", "appspot.com", "withgoogle.com", "chrome.com", "chromium.org", "crbug.com",
    "android.com", "gmail.com", "goo.gl", "goo.gle", "g.co", "goog",
)


def within(host, domains):
    return any(host == domain or host.endswith("." + domain) for domain in domains)


def is_helium(host):
    return within(host, HELIUM_DOMAINS)


def is_google(host):
    """Google's own domains, its country domains (`www.google.de`, `google.com.au`) and hosts
    such as `*.google.fastly-edge.com` that name Google: any `google` label before the last."""
    return within(host, GOOGLE_DOMAINS) or "google" in host.split(".")[:-1]


@dataclass
class Findings:
    urls: Counter = field(default_factory=Counter)
    bare: Counter = field(default_factory=Counter)

    def add(self, text):
        for match in URL.finditer(text):
            self.urls[match.group(1).lower()] += 1
        for match in BARE.finditer(text):
            if is_helium(match.group(1)):
                self.bare[match.group(1)] += 1


def strings(path):
    """The printable runs of six characters or more, like `strings -a -n 6`."""
    data = Path(path).read_bytes()
    for match in PRINTABLE.finditer(data):
        yield match.group().decode("ascii")


def is_macho(path):
    try:
        with path.open("rb") as source:
            return source.read(4) in MACHO_MAGIC
    except OSError:
        return False


def binaries(framework):
    """The framework's executable and every Mach-O file under its current version, once each."""
    framework = Path(framework)
    current = (framework / "Versions/Current").resolve()
    found = []
    for path in sorted(current.rglob("*")):
        if path.is_file() and not path.is_symlink() and path.suffix != ".pak" and is_macho(path):
            found.append(path)
    if not found:
        raise ValueError(f"No binaries in {framework}")
    return found


def scan(paths):
    findings = Findings()
    for path in paths:
        for text in strings(path):
            findings.add(text)
    return findings


def allowed_entries(path=ALLOWED):
    return json.loads(Path(path).read_text())


def allowed_hosts(path=ALLOWED):
    entries = allowed_entries(path)
    hosts = {}
    for entry in entries:
        host, reason = entry.get("host", "").strip().lower(), entry.get("reason", "").strip()
        if not host or not reason:
            raise ValueError(f"{Path(path).name}: every entry needs a host and a reason")
        if is_helium(host):
            raise ValueError(f"{Path(path).name}: Helium hosts can't be allowed ({host})")
        hosts[host] = reason
    return hosts


def problems(findings, allowed):
    found = []
    for host in sorted(findings.urls):
        if is_helium(host):
            found.append(f"Helium URL host {host}")
        elif is_google(host) and host not in allowed:
            found.append(f"Google URL host {host} isn't in {ALLOWED.name}")
    for host in sorted(findings.bare):
        found.append(f"Helium host name {host}")
    return found


def report(findings, allowed):
    lines = ["# URL hosts in the engine framework (count, host, note)"]
    for host, count in sorted(findings.urls.items(), key=lambda item: (-item[1], item[0])):
        note = allowed.get(host) or ("Helium" if is_helium(host) else "Google, not allowed" if is_google(host) else "")
        lines.append(f"{count:6} {host}" + (f"  # {note}" if note else ""))
    if findings.bare:
        lines.append("")
        lines.append("# Helium host names outside URLs")
        lines += [f"{count:6} {host}" for host, count in sorted(findings.bare.items())]
    return "\n".join(lines) + "\n"


def check(framework, *, allowed_path=ALLOWED, report_path=REPORT):
    findings = scan(binaries(framework))
    allowed = allowed_hosts(allowed_path)
    report_path = Path(report_path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(report(findings, allowed))
    found = problems(findings, allowed)
    unused = sorted(host for host in allowed if host not in findings.urls)
    if unused:
        print(f"note: allowed but not found any more: {', '.join(unused)}", flush=True)
    review = sorted(entry["host"] for entry in allowed_entries(allowed_path) if entry.get("review") and entry["host"] in findings.urls)
    if review:
        print(f"note: allowed until reviewed: {', '.join(review)}", flush=True)
    if found:
        raise ValueError(
            "The engine framework has hosts it shouldn't:\n  " + "\n  ".join(found)
            + f"\nEvery host found is listed in {report_path}."
        )
    print(f"{len(findings.urls)} URL hosts checked; the list is in {report_path}", flush=True)
    return findings


def main(arguments=()):
    parser = argparse.ArgumentParser(prog="make engine-hosts", description=__doc__.splitlines()[0])
    parser.add_argument("framework", nargs="?", type=Path, help="the engine framework (default: the engine build's)")
    options = parser.parse_args(list(arguments))
    from .artifact import FRAMEWORK
    framework = options.framework or FRAMEWORK
    if not framework.is_dir():
        raise ValueError(f"No engine framework at {framework}. Pass a path, or run make engine-build.")
    check(framework)
