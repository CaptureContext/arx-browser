"""Per-process resource counters for a browser and all of its helpers, without root.

`proc_pid_rusage(RUSAGE_INFO_V4)` gives each process's physical footprint (the number
Activity Monitor shows as Memory), CPU time, idle wakeups and bytes written to disk.
`powermetrics` needs root, so CPU and wakeups stand in for energy. A process tree is the
browser's PID and every descendant, found with `pgrep -P`; nothing is matched by name.
Each process gets a role from its command line (`role`), so costs can be reported per
process type: browser, GPU, network, storage, audio, renderers and extension renderers.
"""

import ctypes
import subprocess
from dataclasses import dataclass, field

RUSAGE_INFO_V4 = 4


class RusageInfoV4(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups", "ri_pageins",
        "ri_wired_size", "ri_resident_size", "ri_phys_footprint", "ri_proc_start_abstime",
        "ri_proc_exit_abstime", "ri_child_user_time", "ri_child_system_time",
        "ri_child_pkg_idle_wkups", "ri_child_interrupt_wkups", "ri_child_pageins",
        "ri_child_elapsed_abstime", "ri_diskio_bytesread", "ri_diskio_byteswritten",
        "ri_cpu_time_qos_default", "ri_cpu_time_qos_maintenance", "ri_cpu_time_qos_background",
        "ri_cpu_time_qos_utility", "ri_cpu_time_qos_legacy", "ri_cpu_time_qos_user_initiated",
        "ri_cpu_time_qos_user_interactive", "ri_billed_system_time", "ri_serviced_system_time",
        "ri_logical_writes", "ri_lifetime_max_phys_footprint", "ri_instructions", "ri_cycles",
        "ri_billed_energy", "ri_serviced_energy", "ri_interval_max_phys_footprint", "ri_runnable_time",
    )]


class MachTimebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
_libc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(RusageInfoV4)]
_libc.proc_pid_rusage.restype = ctypes.c_int
_timebase = MachTimebase()
_libc.mach_timebase_info(ctypes.byref(_timebase))
# rusage CPU times are Mach absolute time units: nanoseconds on Intel, 1/24 µs ticks on Apple silicon.
TICKS_TO_SECONDS = _timebase.numer / _timebase.denom / 1e9
_libc.mach_continuous_time.restype = ctypes.c_uint64


def continuous_seconds():
    """Mach continuous time in seconds: the clock signposts' `machTimestamp` is read from.

    Unlike Mach absolute time, which `time.monotonic()` reads on macOS, it keeps counting while
    the Mac sleeps, so the two differ by every sleep since boot (DEV-939).
    """
    return _libc.mach_continuous_time() * TICKS_TO_SECONDS


@dataclass(frozen=True)
class Usage:
    footprint: int  # bytes
    resident: int  # bytes
    cpu_seconds: float
    idle_wakeups: int
    bytes_written: int
    logical_writes: int


@dataclass
class TreeSample:
    processes: dict = field(default_factory=dict)  # pid -> (role, Usage)
    arguments: dict = field(default_factory=dict)  # pid -> command line

    @property
    def footprint(self):
        return sum(usage.footprint for _, usage in self.processes.values())

    @property
    def resident(self):
        return sum(usage.resident for _, usage in self.processes.values())

    @property
    def cpu_seconds(self):
        return sum(usage.cpu_seconds for _, usage in self.processes.values())

    @property
    def idle_wakeups(self):
        return sum(usage.idle_wakeups for _, usage in self.processes.values())

    @property
    def bytes_written(self):
        return sum(usage.bytes_written for _, usage in self.processes.values())

    def count(self, name):
        return sum(1 for value, _ in self.processes.values() if value == name)


def usage(pid):
    """The process's counters, or None when it has exited or can't be read."""
    info = RusageInfoV4()
    if _libc.proc_pid_rusage(pid, RUSAGE_INFO_V4, ctypes.byref(info)) != 0:
        return None
    return Usage(
        footprint=info.ri_phys_footprint,
        resident=info.ri_resident_size,
        cpu_seconds=(info.ri_user_time + info.ri_system_time) * TICKS_TO_SECONDS,
        idle_wakeups=info.ri_pkg_idle_wkups + info.ri_interrupt_wkups,
        bytes_written=info.ri_diskio_byteswritten,
        logical_writes=info.ri_logical_writes,
    )


def descendants(pid):
    result = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True)
    children = [int(value) for value in result.stdout.split()]
    return children + [grandchild for child in children for grandchild in descendants(child)]


# Utility services worth their own row; other utilities keep their service name.
SERVICES = {
    "network.mojom.NetworkService": "network",
    "storage.mojom.StorageService": "storage",
    "audio.mojom.AudioService": "audio",
}
# How report tables order process types.
ROLES = ("browser", "gpu", "network", "storage", "audio", "renderer", "extension", "utility", "other")


def switches(arguments):
    """`--name=value` and bare `--name` switches from a `ps` command line; paths may contain spaces."""
    table = {}
    for argument in arguments.split():
        if argument.startswith("--"):
            name, _, value = argument[2:].partition("=")
            table[name] = value
    return table


def role(arguments):
    """What a process of a Chromium browser's tree does, from its command line.

    Renderers with `--extension-process` host extension pages (background pages and
    their popups); other renderers host web pages, or nothing yet (the spare renderer).
    A descendant with no `--type=` isn't a Chromium helper (`other`).
    """
    table = switches(arguments)
    kind = table.get("type")
    if kind is None:
        return "other"
    if kind == "renderer":
        return "extension" if "extension-process" in table else "renderer"
    if kind == "gpu-process":
        return "gpu"
    if kind == "utility":
        service = table.get("utility-sub-type", "")
        return SERVICES.get(service) or ("utility:" + service.rsplit(".", 1)[-1] if service else "utility")
    return kind


def role_order(name):
    """Sort key: the fixed roles first, then other utilities and helper types by name."""
    base = name.split(":", 1)[0]
    return (ROLES.index(base) if base in ROLES else len(ROLES), name)


def arguments_by_pid(pids):
    if not pids:
        return {}
    result = subprocess.run(["ps", "-o", "pid=,args=", "-p", ",".join(map(str, pids))],
                            capture_output=True, text=True)
    table = {}
    for line in result.stdout.splitlines():
        parts = line.strip().split(maxsplit=1)
        if parts:
            table[int(parts[0])] = parts[1] if len(parts) > 1 else ""
    return table


def sample_tree(root):
    """Every process of the tree. Helpers may come and go, but the browser itself must be
    running: an empty sample would read as 0 MB and no CPU, a crash looking like a gain."""
    if usage(root) is None:
        raise ValueError(f"the browser (PID {root}) exited before a sample could be taken")
    pids = [root, *descendants(root)]
    arguments = arguments_by_pid(pids)
    sample = TreeSample()
    for pid in pids:
        value = usage(pid)
        if value is not None:
            sample.processes[pid] = ("browser" if pid == root else role(arguments.get(pid, "")), value)
            sample.arguments[pid] = arguments.get(pid, "")
    return sample


def changes(before, after):
    """Per process in `after`: (role, CPU seconds, idle wakeups, bytes written) since `before`.

    Processes that exited in between are left out; new ones count from zero.
    """
    result = {}
    for pid, (name, current) in after.processes.items():
        previous = before.processes.get(pid, (None, None))[1]
        result[pid] = (name,
                       current.cpu_seconds - (previous.cpu_seconds if previous else 0),
                       current.idle_wakeups - (previous.idle_wakeups if previous else 0),
                       current.bytes_written - (previous.bytes_written if previous else 0))
    return result


def by_role(before, after, seconds):
    """Processes, memory, CPU, wakeups and disk writes per process type between two samples."""
    table = {}
    for pid, (name, cpu, wakeups, written) in changes(before, after).items():
        row = table.setdefault(name, {"processes": 0, "footprint_mb": 0.0, "cpu_percent": 0.0,
                                      "wakeups_per_second": 0.0, "bytes_written": 0})
        row["processes"] += 1
        row["footprint_mb"] += after.processes[pid][1].footprint / 2**20
        row["cpu_percent"] += 100 * cpu / seconds
        row["wakeups_per_second"] += wakeups / seconds
        row["bytes_written"] += written
    return dict(sorted(table.items(), key=lambda item: role_order(item[0])))


def delta(before, after, seconds):
    """CPU percent of one core, idle wakeups per second and bytes written between two samples.

    Processes that exited in between are left out; new ones count from zero.
    """
    values = changes(before, after).values()
    return {
        "cpu_percent": 100 * sum(cpu for _, cpu, _, _ in values) / seconds,
        "wakeups_per_second": sum(wakeups for _, _, wakeups, _ in values) / seconds,
        "bytes_written": sum(written for _, _, _, written in values),
    }
