"""Let a FileStream that never got to close its file close it at shutdown.

On the Mac, `net::FileStream::Context` guards its descriptor against `close` and `dup`
with its own address (https://crbug.com/330771755), and drops the guard in
`CloseFileImpl` before `base::File` closes it. A FileStream that goes away hands its
Context to a `CloseFileImpl` task that owns it. When that task is skipped because the
thread pool is shutting down, the Context is deleted without running it: its `base::File`
then closes a descriptor that is still guarded, and the kernel kills the process with
EXC_GUARD (GUARD_TYPE_FD, CLOSE). Engine batch 4's media smoke quit Arx while a
`file://` load was finishing and hit exactly that.

The Context's destructor now drops its own guard when it still holds the file, so the
file closes as it would have. Every path that leaves the file open has it guarded (the
constructor and `OnOpenCompleted` guard it; `CloseFileImpl` drops the guard and closes),
so the guard it names always matches.

If an anchor changes, the build stops.
"""
from .overlay import replace_once

SOURCE = "net/base/file_stream_context_posix.cc"

DESTRUCTOR = "FileStream::Context::~Context() = default;\n"

ARX_DESTRUCTOR = """FileStream::Context::~Context() {
#if BUILDFLAG(IS_MAC)
  // Arx: a Context whose CloseFileImpl task was skipped at shutdown is deleted
  // still guarding its descriptor, and ~File would close it under the guard
  // (EXC_GUARD). The file is open only while this Context guards it.
  if (file_.IsValid()) {
    guardid_t guardid = reinterpret_cast<guardid_t>(this);
    const int unguarded = change_fdguard_np(
        file_.GetPlatformFile(), &guardid, GUARD_CLOSE | GUARD_DUP,
        /*nguard=*/nullptr, /*nguardflags=*/0, /*fdflagsp=*/nullptr);
    // Shutting down: a failure here mustn't stop the file from closing.
    DPCHECK(unguarded == 0);
  }
#endif
}
"""


def patches():
    yield SOURCE, DESTRUCTOR, ARX_DESTRUCTOR


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
