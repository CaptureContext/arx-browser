#include "chrome/browser/arx/safe_storage_bridge.h"

#import <AppKit/AppKit.h>
#include <Security/Security.h>
#include <dirent.h>
#include <errno.h>
#include <stdlib.h>
#include <sys/stat.h>

#include <atomic>
#include <cstdio>
#include <string>
#include <utility>

#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/location.h"
#include "base/no_destructor.h"
#include "base/path_service.h"
#include "base/process/process.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/arx/safe_storage_hooks.h"
#include "chrome/common/chrome_paths.h"

namespace arx::safe_storage {
namespace {

// Written before threads start, read on Keychain worker threads afterwards.
base::FilePath& UserDataDirectory() {
  static base::NoDestructor<base::FilePath> directory;
  return *directory;
}
bool g_unattended = false;
// The person chose Start Over: a new key may replace the missing one.
std::atomic<bool> g_start_over{false};

// A path that's absent, or isn't what we look for, is certainly empty. One
// that can't be examined (permissions, I/O) may hold data.
bool IsAbsent(int error) {
  return error == ENOENT || error == ENOTDIR;
}

// Whether `path` may be a store with encrypted data in it.
bool MayHoldData(const std::string& path) {
  struct stat status;
  if (::stat(path.c_str(), &status) != 0) {
    return !IsAbsent(errno);
  }
  return S_ISREG(status.st_mode) && status.st_size > 0;
}

// Whether any profile holds data encrypted with the Safe Storage key: saved
// passwords, cookies or autofill. Plain POSIX calls, so it runs on whichever
// Keychain thread asks without Chromium's blocking-call bookkeeping. Anything
// that can't be listed or examined counts as holding data.
bool HasEncryptedData(const base::FilePath& root) {
  static constexpr const char* kStores[] = {
      "Login Data", "Login Data For Account", "Cookies", "Network/Cookies",
      "Web Data",
  };
  if (root.empty()) {
    return true;
  }
  DIR* directory = ::opendir(root.value().c_str());
  if (!directory) {
    return !IsAbsent(errno);
  }
  bool found = false;
  while (!found) {
    errno = 0;
    const dirent* entry = ::readdir(directory);
    if (!entry) {
      // A listing that stopped early may have missed a profile.
      found = errno != 0;
      break;
    }
    const std::string name = entry->d_name;
    if (name == "." || name == "..") {
      continue;
    }
    const std::string profile = root.value() + "/" + name;
    struct stat status;
    if (::stat(profile.c_str(), &status) != 0) {
      if (!IsAbsent(errno)) {
        found = true;
      }
      continue;
    }
    if (!S_ISDIR(status.st_mode)) {
      continue;
    }
    for (const char* store : kStores) {
      if (MayHoldData(profile + "/" + store)) {
        found = true;
        break;
      }
    }
  }
  ::closedir(directory);
  return found;
}

bool MayCreateKey() {
  return g_start_over.load() || !HasEncryptedData(UserDataDirectory());
}

// The Keychain item's name: "Arx Storage Key", or Arx Dev's (DEV-1013).
NSString* KeyName() {
  return @(arx::SafeStorageKeyServiceName().c_str());
}

NSString* Explanation(int status) {
  switch (status) {
    case errSecItemNotFound:
      return [NSString
          stringWithFormat:
              @"The “%@” item is missing from your login keychain, but Arx "
              @"has saved passwords and cookies that need it. If you moved or "
              @"deleted it, put it back (for example from a Time Machine "
              @"backup of your keychain) and click Try Again.\n\nStart Over "
              @"makes a new key. Arx then can't read its saved passwords, and "
              @"websites sign you out.",
              KeyName()];
    case errSecAuthFailed:
    case errSecUserCanceled:
      return @"macOS didn't let Arx use its key in your login keychain. Click "
             @"Try Again and choose Always Allow when macOS asks.\n\nIf you "
             @"changed your Mac's login password, your login keychain may "
             @"still use the old one. Update it in Keychain Access first.";
    case errSecInteractionNotAllowed:
    case errSecNoSuchKeychain:
    case errSecNotAvailable:
      return @"Your login keychain is locked or unavailable. Unlock it in "
             @"Keychain Access, then click Try Again.\n\nIf you changed your "
             @"Mac's login password, your login keychain may still use the "
             @"old one.";
    default:
      return [NSString
          stringWithFormat:@"macOS reported error %d while Arx read its key "
                           @"from your login keychain. Click Try Again.",
                           status];
  }
}

// Profiles are still waiting for the key: exit without writing anything
// that was only partly loaded.
[[noreturn]] void Quit() {
  base::Process::TerminateCurrentProcessImmediately(EXIT_FAILURE);
}

// A headless run's documented exit status for a startup failure.
constexpr int kUnattendedStartupFailure = 70;

bool ConfirmStartOver() {
  NSAlert* alert = [[NSAlert alloc] init];
  alert.alertStyle = NSAlertStyleCritical;
  alert.messageText = @"Start over with a new key?";
  alert.informativeText = [NSString
      stringWithFormat:@"Arx makes a new “%@”. Passwords saved in Arx can't be "
                       @"read anymore, and websites sign you out. This can't "
                       @"be undone.",
                       KeyName()];
  NSButton* start_over = [alert addButtonWithTitle:@"Start Over"];
  start_over.hasDestructiveAction = YES;
  [alert addButtonWithTitle:@"Cancel"];
  return [alert runModal] == NSAlertFirstButtonReturn;
}

void Ask(int status, base::OnceClosure retry) {
  NSAlert* alert = [[NSAlert alloc] init];
  alert.alertStyle = NSAlertStyleCritical;
  alert.messageText = @"Arx can't open its key in the Keychain";
  alert.informativeText = Explanation(status);
  [alert addButtonWithTitle:@"Try Again"];
  [alert addButtonWithTitle:@"Quit Arx"];
  if (status == errSecItemNotFound) {
    [alert addButtonWithTitle:@"Start Over…"].hasDestructiveAction = YES;
  }
  const NSModalResponse response = [alert runModal];
  if (response == NSAlertFirstButtonReturn) {
    std::move(retry).Run();
    return;
  }
  if (response == NSAlertThirdButtonReturn) {
    if (ConfirmStartOver()) {
      g_start_over = true;
      std::move(retry).Run();
      return;
    }
    // Cancelled: the same question again.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&Ask, status, std::move(retry)));
    return;
  }
  Quit();
}

void KeyUnavailable(int status, base::OnceClosure retry) {
  if (g_unattended) {
    std::fprintf(stderr, "ARX_SAFE_STORAGE_UNAVAILABLE %d\n", status);
    std::fflush(stderr);
    base::Process::TerminateCurrentProcessImmediately(kUnattendedStartupFailure);
  }
  // The alert runs a nested loop; start it from a task of its own.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&Ask, status, std::move(retry)));
}

}  // namespace

void Prepare(bool unattended) {
  g_unattended = unattended;
  base::FilePath directory;
  if (base::PathService::Get(chrome::DIR_USER_DATA, &directory)) {
    UserDataDirectory() = directory;
  }
  SetSafeStorageKeyCreationPolicy(&MayCreateKey);
  SetSafeStorageUnavailableHandler(&KeyUnavailable);
}

}  // namespace arx::safe_storage
