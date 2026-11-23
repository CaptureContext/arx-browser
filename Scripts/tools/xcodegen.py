"""Generate an Xcode project with the mise-selected XcodeGen executable."""

import os
import re

from ..core.process import run


def generate(root, *, spec="project.yml", environment=None):
    environment = dict(os.environ if environment is None else environment)
    team = environment.get("DEVELOPMENT_TEAM", "").strip()
    if team and not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("DEVELOPMENT_TEAM must be a 10-character Apple team identifier.")
    environment["DEVELOPMENT_TEAM"] = team
    run(["xcodegen", "generate", "--spec", spec], cwd=root, env=environment)
