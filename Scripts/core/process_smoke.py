"""Observe only a disposable app's packaged Chromium children and Seatbelt state."""

import ctypes
import json
import os
import re
import subprocess


class ProcessProbe:
    required_roles = frozenset({"renderer", "gpu", "network"})

    def __init__(self, app, check_sandbox=None, executable_path=None):
        framework = app / "Contents/Frameworks/Arx Framework.framework"
        self.helpers = {
            self.file_identity(path)
            for path in framework.glob("Versions/*/Helpers/Arx Helper*.app/Contents/MacOS/Arx Helper*")
            if path.is_file()
        }
        if not self.helpers:
            raise ValueError("No packaged Chromium helper executables found")
        self.observed = {}
        self.sandboxed = {}
        self.errors = []
        if check_sandbox is None:
            # Same read-only query as Chromium sandbox/mac/seatbelt.cc, IsSandboxed.
            self.library = ctypes.CDLL("/usr/lib/libsandbox.1.dylib")
            check = self.library.sandbox_check
            check.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
            check.restype = ctypes.c_int
            check_sandbox = lambda pid: check(pid, None, 0)
        self.check_sandbox = check_sandbox
        if executable_path is None:
            self.process_library = ctypes.CDLL("/usr/lib/libproc.dylib")
            path_for_pid = self.process_library.proc_pidpath
            path_for_pid.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
            path_for_pid.restype = ctypes.c_int

            def executable_path(pid):
                buffer = ctypes.create_string_buffer(4096)  # PROC_PIDPATHINFO_MAXSIZE
                if path_for_pid(pid, buffer, len(buffer)) <= 0:
                    return None  # The sampled child may have exited.
                return os.fsdecode(buffer.value)

        self.executable_path = executable_path

    @staticmethod
    def file_identity(path):
        value = os.stat(path)
        return value.st_dev, value.st_ino

    def observe(self, parent_id, listing):
        for row in listing.splitlines():
            fields = row.strip().split(maxsplit=2)
            if len(fields) != 3 or not fields[0].isdigit() or not fields[1].isdigit():
                continue
            pid, parent = map(int, fields[:2])
            if parent != parent_id:
                continue
            arguments = fields[2]
            if any(len(re.findall(r"(?:^|\s)--?" + name + r"=\S*", arguments)) > 1
                   for name in ("type", "utility-sub-type")):
                self.errors.append(f"child {pid} supplied ambiguous Chromium role switches")
                continue
            role = self.role(arguments)
            if role is None:
                continue
            path = self.executable_path(pid)
            if path is None:
                continue
            try:
                identity = self.file_identity(path)
            except FileNotFoundError:
                continue
            # argv is not executable identity. Kernel paths can also use a different
            # case or resolve bundle symlinks, so compare the actual packaged files.
            if identity not in self.helpers:
                self.errors.append(f"{role} child {pid} was not loaded from the packaged framework")
                continue
            if self.disables_sandbox(arguments, role):
                self.errors.append(f"{role} child {pid} disabled sandboxing")
                continue
            result = self.check_sandbox(pid)
            self.observed[role] = {"pid": pid, "seatbelt": result}
            # A process may be sampled before Chromium installs Seatbelt, or after it exits.
            # Only positive evidence for a live, scoped helper satisfies the gate.
            if result == 1:
                self.sandboxed[role] = {"pid": pid, "seatbelt": True}

    @staticmethod
    def disables_sandbox(arguments, role):
        # Chromium accepts one or two leading dashes. HasSwitch ignores the
        # assigned value, so even --no-sandbox=false disables the sandbox.
        def has_switch(name):
            return re.search(r"(?:^|\s)--?" + name + r"(?:=\S*|(?=\s|$))", arguments) is not None

        if has_switch("no-sandbox") or (role == "gpu" and has_switch("disable-gpu-sandbox")):
            return True
        return role == "network" and re.search(
            r"(?:^|\s)--?service-sandbox-type=none(?:\s|$)", arguments
        ) is not None

    @staticmethod
    def role(arguments):
        match = re.search(r"(?:^|\s)--?type=(\S+)", arguments)
        if match is None:
            return None
        kind = match.group(1)
        if kind == "renderer":
            return "renderer"
        if kind == "gpu-process":
            return "gpu"
        if kind == "utility" and re.search(
            r"(?:^|\s)--?utility-sub-type=network\.mojom\.NetworkService(?:\s|$)", arguments
        ):
            return "network"
        return None

    def monitor(self, process, stopped):
        try:
            while process.poll() is None and not stopped.wait(0.5):
                children = subprocess.run(
                    ["pgrep", "-P", str(process.pid)], capture_output=True, text=True, check=False, timeout=5
                )
                if children.returncode not in (0, 1):
                    raise ValueError("Could not inspect disposable app child processes")
                ids = [value for value in children.stdout.split() if value.isdigit()]
                if ids:
                    listing = subprocess.run(
                        ["ps", "-p", ",".join(ids), "-o", "pid=,ppid=,args="],
                        capture_output=True, text=True, check=False, timeout=5,
                    )
                    if listing.returncode not in (0, 1):
                        raise ValueError("Could not inspect disposable app helper arguments")
                    self.observe(process.pid, listing.stdout)
        except Exception as error:
            self.errors.append(str(error))

    def verify(self):
        if self.errors:
            raise ValueError("Chromium process validation failed: " + "; ".join(sorted(set(self.errors))))
        missing = self.required_roles.difference(self.sandboxed)
        if missing:
            raise ValueError(f"No sandboxed packaged helpers observed for {sorted(missing)}; observed={self.observed}")
        return "ARX_PROCESS_ISOLATION_SMOKE_SUCCESS " + json.dumps(self.sandboxed, sort_keys=True)
