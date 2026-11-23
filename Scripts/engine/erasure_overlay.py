"""Opt-in maintenance authority, ordinary startup fallback, and launch proof."""


def patches():
    yield "chrome/browser/process_singleton.h", "  bool Create();", """  bool Create();
#if BUILDFLAG(IS_MAC)
  // Strict maintenance must not notify, kill, or replace any existing lock.
  enum class StrictCreationResult { kCreated, kLockConflict, kFailed };
  StrictCreationResult CreateWithoutRecovery();
#endif"""
    yield "chrome/browser/process_singleton.h", "  // Notify another process, if available.\n  // Returns true if another process was found and notified, false if we should", """#if BUILDFLAG(IS_MAC)
  bool deny_lock_recovery_ = false;
  bool strict_lock_conflict_ = false;
#endif

  // Notify another process, if available.
  // Returns true if another process was found and notified, false if we should"""
    yield "chrome/browser/process_singleton_posix.cc", "bool ProcessSingleton::Create() {", """#if BUILDFLAG(IS_MAC)
ProcessSingleton::StrictCreationResult ProcessSingleton::CreateWithoutRecovery() {
  deny_lock_recovery_ = true;
  strict_lock_conflict_ = false;
  const bool created = Create();
  deny_lock_recovery_ = false;
  if (created) return StrictCreationResult::kCreated;
  return strict_lock_conflict_ ? StrictCreationResult::kLockConflict
                               : StrictCreationResult::kFailed;
}
#endif

bool ProcessSingleton::Create() {"""
    yield "chrome/browser/process_singleton_posix.cc", "  if (!SymlinkPath(symlink_content, lock_path_)) {", """  bool created_lock;
#if BUILDFLAG(IS_MAC)
  if (deny_lock_recovery_) {
    // SymlinkPath accepts an existing matching PID target after a failed
    // symlink call. Strict authority requires creating a genuinely new entry.
    created_lock = base::CreateSymbolicLink(symlink_content, lock_path_);
  } else
#endif
  {
    created_lock = SymlinkPath(symlink_content, lock_path_);
  }
  if (!created_lock) {"""
    yield "chrome/browser/process_singleton_posix.cc", "    if (base::IsLink(lock_path_) ||\n        !ReplaceOldSingletonLock(symlink_content, lock_path_)) {", """    if (deny_lock_recovery_) {
      strict_lock_conflict_ = true;
      return false;
    }
    if (base::IsLink(lock_path_) ||
        !ReplaceOldSingletonLock(symlink_content, lock_path_)) {"""
    yield "chrome/browser/chrome_process_singleton.h", "  ProcessSingleton::NotifyResult NotifyOtherProcessOrCreate();", """  ProcessSingleton::NotifyResult NotifyOtherProcessOrCreate();
#if BUILDFLAG(IS_MAC)
  // A conflicting lock takes ordinary recovery/notification without maintenance
  // authority. Other strict failures remain startup errors.
  ProcessSingleton::NotifyResult CreateForArxMaintenance();
  bool WasCreatedWithoutRecovery() const { return created_without_recovery_; }
#endif"""
    yield "chrome/browser/chrome_process_singleton.h", "  bool is_singleton_instance_ = false;", """  bool is_singleton_instance_ = false;
#if BUILDFLAG(IS_MAC)
  bool created_without_recovery_ = false;
#endif"""
    yield "chrome/browser/chrome_process_singleton.cc", "void ChromeProcessSingleton::StartWatching() {", """#if BUILDFLAG(IS_MAC)
ProcessSingleton::NotifyResult ChromeProcessSingleton::CreateForArxMaintenance() {
  CHECK(!is_singleton_instance_);
  created_without_recovery_ = false;
  const auto result = process_singleton_.CreateWithoutRecovery();
  if (result == ProcessSingleton::StrictCreationResult::kLockConflict)
    return NotifyOtherProcessOrCreate();
  if (result != ProcessSingleton::StrictCreationResult::kCreated)
    return ProcessSingleton::LOCK_ERROR;
  is_singleton_instance_ = true;
  created_without_recovery_ = true;
  return ProcessSingleton::PROCESS_NONE;
}
#endif

void ChromeProcessSingleton::StartWatching() {"""
    yield "chrome/app/chrome_main_delegate.cc", """  ProcessSingleton::NotifyResult notify_result =
      ChromeProcessSingleton::GetInstance()->NotifyOtherProcessOrCreate();""", """  ProcessSingleton::NotifyResult notify_result;
#if BUILDFLAG(IS_MAC)
  if (base::CommandLine::ForCurrentProcess()->HasSwitch("arx-profile-maintenance")) {
    notify_result = ChromeProcessSingleton::GetInstance()->CreateForArxMaintenance();
  } else
#endif
  {
    notify_result = ChromeProcessSingleton::GetInstance()->NotifyOtherProcessOrCreate();
  }"""
    yield "chrome/browser/profiles/profile_manager.h", '#include "base/callback_list.h"', '#include "base/callback_list.h"\n#include "base/functional/callback.h"'
    yield "chrome/browser/profiles/profile_manager.h", " private:\n  friend class TestingProfileManager;", """ public:
  // An embedder can deny startup/background recreation of retired profiles.
  // Unset preserves Chromium's existing profile policy.
  void SetArxProfileCreationGuard(
      base::RepeatingCallback<bool(const base::FilePath&)> guard) {
    arx_profile_creation_guard_ = std::move(guard);
  }

 private:
  base::RepeatingCallback<bool(const base::FilePath&)> arx_profile_creation_guard_;
  friend class TestingProfileManager;"""
    yield "chrome/browser/profiles/profile_manager.cc", "bool ProfileManager::CanCreateProfileAtPath(const base::FilePath& path) const {", """bool ProfileManager::CanCreateProfileAtPath(const base::FilePath& path) const {
  if (arx_profile_creation_guard_ && !arx_profile_creation_guard_.Run(path))
    return false;"""
    yield "chrome/browser/profiles/profile_manager.cc", "Profile* ProfileManager::GetProfile(const base::FilePath& profile_dir) {", """Profile* ProfileManager::GetProfile(const base::FilePath& profile_dir) {
  if (arx_profile_creation_guard_ && !arx_profile_creation_guard_.Run(profile_dir))
    return nullptr;"""

    yield from child_launch_patches()


def child_launch_patches():
    yield "content/public/browser/BUILD.gn", '    "child_process_launcher_utils.h",', '''    "child_process_launcher_utils.h",
    "arx_child_launch_tracker.h",'''
    yield "content/public/browser/child_process_launcher_utils.h", '#include "content/common/content_export.h"', '''#include "build/build_config.h"
#include "content/common/content_export.h"
#if BUILDFLAG(IS_MAC)
#include "content/public/browser/arx_child_launch_tracker.h"
#endif'''
    yield "content/public/browser/child_process_launcher_utils.h", "namespace content {", '''namespace content {

#if BUILDFLAG(IS_MAC)
// Observe the actual helper launch boundary, including owners that disappear
// before connection. Finish only after ChromeMain and all native threads exit.
CONTENT_EXPORT void BeginArxChildLaunchObservation();
CONTENT_EXPORT arx::erasure::ChildLaunchTracker::Snapshot FinishArxChildLaunchObservation();
#endif'''
    yield "content/browser/child_process_launcher_helper.cc", '#include "build/build_config.h"', '''#include "build/build_config.h"
#if BUILDFLAG(IS_MAC)
#include <libproc.h>
#endif'''
    yield "content/browser/child_process_launcher_helper.cc", "namespace content {\nnamespace internal {", '''namespace content {
#if BUILDFLAG(IS_MAC)
namespace {
arx::erasure::ChildLaunchTracker& ArxLaunches() {
  static base::NoDestructor<arx::erasure::ChildLaunchTracker> tracker;
  return *tracker;
}
}  // namespace
void BeginArxChildLaunchObservation() { ArxLaunches().StartObservation(); }
arx::erasure::ChildLaunchTracker::Snapshot FinishArxChildLaunchObservation() {
  return ArxLaunches().FinishObservation();
}
#endif
namespace internal {'''
    yield "content/browser/child_process_launcher_helper.cc", "  BeforeLaunchOnClientThread();", '''#if BUILDFLAG(IS_MAC)
  ArxLaunches().StartLaunch(this);
#endif
  BeforeLaunchOnClientThread();'''
    yield "content/browser/child_process_launcher_helper.cc", "    int error_code) {\n  if (child_process_launcher_) {", '''    int error_code) {
#if BUILDFLAG(IS_MAC)
  // Capture before the weak-owner branch and asynchronous termination. A public
  // connected-process observer cannot see every launched helper.
  if (ArxLaunches().IsObserving()) {
    if (!process.process.IsValid()) {
      ArxLaunches().DidNotLaunch(this);
    } else {
      struct proc_bsdinfo info;
      if (proc_pidinfo(process.process.Pid(), PROC_PIDTBSDINFO, 0, &info,
                       sizeof(info)) == sizeof(info)) {
        ArxLaunches().Launched(this, {process.process.Pid(), info.pbi_start_tvsec,
                                     info.pbi_start_tvusec});
      } else {
        ArxLaunches().Unknown(this);
      }
    }
  }
#endif
  if (child_process_launcher_) {'''


def apply(source):
    import shutil
    from .config import PACKAGE
    from .overlay import replace_once
    destination = source / "content/public/browser/arx_child_launch_tracker.h"
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(PACKAGE / "Native/profile_erasure/child_launch_tracker.h", destination)
    for relative, old, new in patches():
        replace_once(source / relative, old, new)
