"""Process logging and exit-code propagation shared by script entry points."""

import subprocess
import sys

from .paths import ROOT


def run(arguments, *, capture=False, log=None, cwd=ROOT, env=None):
    print("+ " + " ".join(map(str, arguments)), flush=True)
    if log:
        destination = cwd / "build/logs" / log
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("w") as output:
            result = subprocess.run(arguments, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            print(destination.read_text(), file=sys.stderr)
        result.check_returncode()
        print(f"Log: {destination.relative_to(cwd)}", flush=True)
        return ""
    result = subprocess.run(arguments, cwd=cwd, env=env, text=True, capture_output=capture)
    if result.returncode and capture:
        print(result.stderr, file=sys.stderr)
    result.check_returncode()
    return result.stdout if capture else ""


def execute(action):
    try:
        action()
    except subprocess.CalledProcessError as error:
        return error.returncode
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0
