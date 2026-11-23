"""Save, fill and isolate passwords through Chromium's password manager (DEV-708).

A loopback sign-in site and the engine host with three profiles and a private
page, all in disposable storage with the mock Keychain. Settings (DEV-721) then
lists, edits, adds and removes passwords and imports Chrome and Apple Passwords
CSV exports; edits and imports are proven by signing in to the fixture site.
The run fails if the probe password, or any value derived from it, appears in
any reply, log, error or file of the profile.
"""

from ..core import smoke
from . import smoke as engine_smoke


def main():
    with smoke.log("password-smoke") as log:
        engine_smoke.run(log, passwords=True)
