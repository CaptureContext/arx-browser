#import <AppKit/AppKit.h>
#include "chrome/browser/arx/external_consent_fixture.h"
#include <cstdlib>
#include <cstdio>
#include <algorithm>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/external_protocol/external_protocol_handler.h"
#include "chrome/browser/profiles/profile.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/web_contents.h"

namespace arx::consent_testing {
namespace {
struct Fixture {
  base::FilePath root, profile;
  std::string scheme;
  std::u16string expected_program;
  int receipt = -1;
  uint64_t generation = 0;
  dev_t root_device = 0, profile_device = 0;
  ino_t root_inode = 0, profile_inode = 0;
};
Fixture& State() { static base::NoDestructor<Fixture> state; return *state; }
void Record(const std::string& value) {
  const std::string line = value + "\n";
  if (State().receipt < 0 || write(State().receipt, line.data(), line.size()) !=
      static_cast<ssize_t>(line.size()) || fsync(State().receipt)) {
    std::fputs("ARX_EXTERNAL_CONSENT_FIXTURE_RECEIPT_FAILURE\n", stderr);
    return;
  }
  std::fprintf(stderr, "ARX_EXTERNAL_CONSENT_FIXTURE %s\n", value.c_str());
}
bool OwnedDirectory(const base::FilePath& path) {
  struct stat info;
  return !lstat(path.value().c_str(), &info) && S_ISDIR(info.st_mode) &&
      info.st_uid == getuid() && (info.st_mode & 0777) == 0700 &&
      base::MakeAbsoluteFilePath(path) == path;
}
bool OwnedHandlerProgram(const base::FilePath& root, std::u16string* program) {
  const auto bundle = root.AppendASCII("Arx Owned External Handler.app");
  struct stat info;
  // prepare() may create intermediate bundle directories with 0755. The
  // canonical private fixture root still confines this exact owned child.
  if (lstat(bundle.value().c_str(), &info) || !S_ISDIR(info.st_mode) ||
      info.st_uid != getuid() || base::MakeAbsoluteFilePath(bundle) != bundle) return false;
  NSString* path = [NSString stringWithUTF8String:bundle.value().c_str()];
  if (!path) return false;
  *program = base::SysNSStringToUTF16([NSFileManager.defaultManager displayNameAtPath:path]);
  return !program->empty();
}
bool ExactTarget(const GURL& url) {
  if (!url.is_valid() || !url.host().empty() || url.has_username() ||
      url.has_password() || url.has_query() || url.has_ref()) return false;
  if (url.path() == "unregistered") return url.SchemeIs(State().scheme + "-unregistered");
  return url.SchemeIs(State().scheme) &&
      (url.path() == "cancel" || url.path() == "accept" || url.path() == "stale" ||
       url.path() == "noopener" || url.path() == "blank-cancel" || url.path() == "blank-accept" ||
       url.path() == "blank-stale" || url.path() == "blank-source-loss" ||
       url.path() == "blank-after-http" || url.path() == "blank-private");
}
bool OwnedProfile(content::WebContents* contents) {
  if (!contents) return false;
  struct stat root_info, profile_info;
  if (lstat(State().root.value().c_str(), &root_info) || lstat(State().profile.value().c_str(), &profile_info) ||
      !S_ISDIR(root_info.st_mode) || !S_ISDIR(profile_info.st_mode) ||
      root_info.st_dev != State().root_device || root_info.st_ino != State().root_inode ||
      profile_info.st_dev != State().profile_device || profile_info.st_ino != State().profile_inode) return false;
  auto path = Profile::FromBrowserContext(contents->GetBrowserContext())->GetOriginalProfile()->GetPath();
  return path == State().profile || State().profile.IsParent(path);
}
}  // namespace

bool Initialize(const base::FilePath& profile, bool mock_keychain) {
  const char* environment = std::getenv("ARX_EXTERNAL_CONSENT_FIXTURE_ROOT");
  if (!environment) return true;
  auto& state = State();
  const base::FilePath root(environment);
  if (!mock_keychain || state.receipt >= 0 || !OwnedDirectory(root) ||
      !base::StartsWith(root.BaseName().value(), "app-smoke-") ||
      profile != root.AppendASCII("profile") || !OwnedDirectory(profile)) return false;
  int marker = open(root.AppendASCII(".arx-external-consent").value().c_str(), O_RDONLY | O_NOFOLLOW);
  struct stat info;
  char bytes[33];
  const bool valid = marker >= 0 && !fstat(marker, &info) && S_ISREG(info.st_mode) &&
      info.st_uid == getuid() && (info.st_mode & 0777) == 0600 && info.st_size == 32 &&
      read(marker, bytes, sizeof(bytes)) == 32;
  if (marker >= 0) close(marker);
  if (!valid) return false;
  const std::string token(bytes, 32);
  if (!std::ranges::all_of(token, [](char byte) {
        return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f');
      })) return false;
  std::u16string expected_program;
  if (!OwnedHandlerProgram(root, &expected_program)) return false;
  state.receipt = open(root.AppendASCII("external-consent.receipt").value().c_str(),
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
  if (state.receipt < 0) return false;
  struct stat root_info, profile_info;
  if (lstat(root.value().c_str(), &root_info) || lstat(profile.value().c_str(), &profile_info)) {
    close(state.receipt);
    state.receipt = -1;
    return false;
  }
  state.root = root;
  state.profile = profile;
  state.root_device = root_info.st_dev;
  state.root_inode = root_info.st_ino;
  state.profile_device = profile_info.st_dev;
  state.profile_inode = profile_info.st_ino;
  state.scheme = "arx-consent-" + token;
  state.expected_program = std::move(expected_program);
  ++state.generation;
  ExternalProtocolHandler::SetOwnedFixtureLaunchInterceptorForTesting(base::BindRepeating(
      [](const GURL& url, content::WebContents* contents) {
        const bool expected = ExactTarget(url) &&
            (url.path() == "accept" || url.path() == "blank-accept") && OwnedProfile(contents);
        Record(expected ? "os-attempt:" + std::string(url.path()) + ":intercepted" : "FAIL:unexpected-os-attempt");
        // Installing this interceptor unconditionally suppresses dispatch.
      }));
  Record("armed");
  return true;
}
void Reset() {
  if (State().receipt < 0) return;
  // The fixture process never resumes OS dispatch, even during late shutdown.
  close(State().receipt);
  State().receipt = -1;
  ++State().generation;
}
void DialogShown(content::WebContents* child, content::WebContents* source,
    const GURL& target, const std::u16string& program,
    base::RepeatingCallback<bool()> current, base::RepeatingCallback<bool()> visible,
    base::OnceClosure cancel, base::OnceClosure accept, content::WebContents* original_source) {
  if (State().receipt < 0) return;
  // Fixed value-free bits distinguish fixture setup from source lifetime loss.
  const unsigned checks = (ExactTarget(target) ? 1u : 0u) |
      (OwnedProfile(child) ? 2u : 0u) | (OwnedProfile(source) ? 4u : 0u) |
      (program == State().expected_program ? 8u : 0u) |
      (current && current.Run() ? 16u : 0u);
  if (checks != 31u) {
    Record("diagnostic:dialog-checks:" + std::to_string(checks) +
        ":program-app-suffix:" + (program == u"Arx Owned External Handler.app" ? "1" : "0") +
        ":program-length:" + std::to_string(program.size()));
    Record("FAIL:unexpected-dialog");
    std::move(cancel).Run();
    return;
  }
  const auto generation = State().generation;
  const std::string phase(target.path());
  auto source_weak = source->GetWeakPtr();
  auto original_weak = original_source ? original_source->GetWeakPtr() : source_weak;
  // Real Views dialog construction and LaunchServices name lookup have already
  // happened. Wait past native input protection before using its button action.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
      base::BindOnce([](uint64_t generation, std::string phase,
          base::WeakPtr<content::WebContents> source, base::WeakPtr<content::WebContents> original,
          base::RepeatingCallback<bool()> current,
          base::RepeatingCallback<bool()> visible, base::OnceClosure cancel, base::OnceClosure accept) {
        if (State().receipt < 0 || generation != State().generation) return;
        if (!current.Run() || !visible.Run() || !source ||
            !source->GetNativeView().GetNativeNSView().window.visible) {
          Record("FAIL:dialog-not-visible-on-source");
          std::move(cancel).Run();
          return;
        }
        Record("dialog:" + phase + ":visible");
        if (phase == "stale" || phase == "blank-stale" || phase == "blank-source-loss") {
          const GURL current_url = original ? original->GetLastCommittedURL() : GURL();
          if (!current_url.SchemeIsHTTPOrHTTPS() || !base::EndsWith(current_url.host(), ".localhost")) {
            Record("FAIL:stale-source-url");
            std::move(cancel).Run();
            return;
          }
          auto* replaced = phase == "blank-source-loss" ? original.get() : source.get();
          replaced->GetController().LoadURL(current_url.Resolve("destination.html"),
              content::Referrer(), ui::PAGE_TRANSITION_TYPED, std::string());
          // Keep the real old Accept action: when invoked later it must have
          // either died with the widget or refuse the invalidated source.
          base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
              base::BindOnce([](uint64_t generation, base::OnceClosure stale_accept) {
                if (State().receipt >= 0 && generation == State().generation)
                  std::move(stale_accept).Run();
              }, generation, std::move(accept)), base::Milliseconds(200));
        } else if (phase == "accept" || phase == "blank-accept") {
          std::move(accept).Run();
        } else {
          std::move(cancel).Run();
        }
      }, generation, phase, source_weak, original_weak, std::move(current), std::move(visible),
         std::move(cancel), std::move(accept)), base::Milliseconds(700));
}
void PublishedAttributionDiagnostic(content::WebContents* source, int stage, int detail) {
  if (State().receipt < 0 || !OwnedProfile(source)) return;
  const auto& url = source->GetLastCommittedURL();
  if (!url.SchemeIsHTTPOrHTTPS() || !base::EndsWith(url.host(), ".localhost")) return;
  for (const char* phase : {"blank-http-immediate", "blank-http-delayed", "blank-cancel", "blank-accept",
      "blank-stale", "blank-source-loss", "blank-after-http", "blank-private"}) {
    if (url.path() == std::string("/external-consent/") + phase + ".html") {
      std::fprintf(stderr, "ARX_BLANK_CHILD_ATTRIBUTION phase=%s stage=%d detail=%d\n", phase, stage, detail);
      return;
    }
  }
}
void PublishedNavigationStarted(content::WebContents* child, const GURL& target, bool primary) {
  if (State().receipt >= 0 && primary && ExactTarget(target) &&
      base::StartsWith(target.path(), "blank-") && OwnedProfile(child))
    Record("published:" + std::string(target.path()) + ":requested");
}
void PublishedAttributionDrained(const GURL& target) {
  if (State().receipt >= 0 && ExactTarget(target) && base::StartsWith(target.path(), "blank-"))
    Record("published:" + std::string(target.path()) + ":drained");
}
void ChildDestroyed(const GURL& target) {
  if (State().receipt >= 0 && ExactTarget(target)) Record("child:" + std::string(target.path()) + ":drained");
}
}  // namespace arx::consent_testing
