#import <Foundation/Foundation.h>
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <functional>
#include <string>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
namespace base {
struct FilePath {
  std::string path;
  FilePath() = default;
  explicit FilePath(std::string value) : path(value) {}
  const std::string& value() const { return path; }
  FilePath BaseName() const { return FilePath(std::filesystem::path(path).filename()); }
  FilePath AppendASCII(const std::string& name) const { return FilePath((std::filesystem::path(path) / name).string()); }
  bool operator==(const FilePath&) const = default;
};
FilePath MakeAbsoluteFilePath(const FilePath& path) {
  std::error_code error;
  const auto canonical = std::filesystem::canonical(path.path, error);
  return error ? FilePath() : FilePath(canonical.string());
}
bool StartsWith(const std::string& value, const std::string& prefix) { return value.starts_with(prefix); }
std::u16string SysNSStringToUTF16(NSString* value) {
  if (!value) return {};
  std::u16string result(value.length, u'\0');
  [value getCharacters:reinterpret_cast<unichar*>(result.data()) range:NSMakeRange(0, value.length)];
  return result;
}
template<class T> struct NoDestructor { T value; T& operator*() { return value; } };
template<class F> auto BindRepeating(F function) { return function; }
}  // namespace base
struct GURL { bool exact; std::string path() const { return "accept"; } };
namespace content { struct WebContents { bool owned; }; }
struct ExternalProtocolHandler {
  static inline std::function<void(const GURL&, content::WebContents*)> interceptor;
  static void SetOwnedFixtureLaunchInterceptorForTesting(decltype(interceptor) callback) { interceptor = callback; }
};
// PRODUCTION_STATE
// PRODUCTION_GET_STATE
// PRODUCTION_RECORD
// PRODUCTION_OWNED_DIRECTORY
bool ExactTarget(const GURL& url) { return url.exact; }
bool OwnedProfile(content::WebContents* contents) { return contents && contents->owned; }
// PRODUCTION_OWNED_HANDLER_PROGRAM
// PRODUCTION_INITIALIZE
// PRODUCTION_RESET
void WriteMarker(const base::FilePath& root, const std::string& value) {
  int fd = open(root.AppendASCII(".arx-external-consent").value().c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
  assert(fd >= 0 && write(fd, value.data(), value.size()) == static_cast<ssize_t>(value.size())); close(fd);
}
int main(int argc, char** argv) {
  assert(argc == 2);
  const base::FilePath root(argv[1]), profile = root.AppendASCII("profile");
  unsetenv("ARX_EXTERNAL_CONSENT_FIXTURE_ROOT");
  assert(Initialize(profile, false)); assert(!ExternalProtocolHandler::interceptor);
  setenv("ARX_EXTERNAL_CONSENT_FIXTURE_ROOT", root.value().c_str(), 1);
  WriteMarker(root, std::string(32, 'a'));
  assert(!Initialize(profile, false));
  chmod(profile.value().c_str(), 0755); assert(!Initialize(profile, true)); chmod(profile.value().c_str(), 0700);
  auto preserved = root.AppendASCII("preserved-profile");
  assert(!rename(profile.value().c_str(), preserved.value().c_str()));
  assert(!symlink(preserved.value().c_str(), profile.value().c_str()));
  assert(!Initialize(profile, true));
  assert(!unlink(profile.value().c_str())); assert(!rename(preserved.value().c_str(), profile.value().c_str()));
  WriteMarker(root, std::string(32, 'Z')); assert(!Initialize(profile, true));
  WriteMarker(root, std::string(31, 'a')); assert(!Initialize(profile, true));
  WriteMarker(root, std::string(32, 'a'));
  assert(!Initialize(profile, true));  // Exact handler must exist before arming.
  const auto bundle = root.AppendASCII("Arx Owned External Handler.app");
  const auto preserved_bundle = root.AppendASCII("preserved-handler.app");
  assert(!mkdir(preserved_bundle.value().c_str(), 0755));
  assert(!symlink(preserved_bundle.value().c_str(), bundle.value().c_str()));
  assert(!Initialize(profile, true));  // Canonical path cannot be replaced by a symlink.
  assert(!unlink(bundle.value().c_str()));
  int fake = open(bundle.value().c_str(), O_WRONLY | O_CREAT | O_EXCL, 0600);
  assert(fake >= 0); close(fake);
  assert(!Initialize(profile, true));  // A regular file is not an application bundle.
  assert(!unlink(bundle.value().c_str()));
  assert(!mkdir(bundle.value().c_str(), 0755));
  assert(Initialize(profile, true));
  NSString* path = [NSString stringWithUTF8String:bundle.value().c_str()];
  assert(State().expected_program == base::SysNSStringToUTF16(
      [NSFileManager.defaultManager displayNameAtPath:path]));
  assert(!State().expected_program.empty());
  assert(State().receipt >= 0 && State().scheme == "arx-consent-" + std::string(32, 'a'));
  content::WebContents owned{true}, foreign{false};
  ExternalProtocolHandler::interceptor(GURL{true}, &owned);
  ExternalProtocolHandler::interceptor(GURL{false}, &owned);
  ExternalProtocolHandler::interceptor(GURL{true}, &foreign);
  assert(!Initialize(profile, true));  // No double arming in one process.
  Reset(); assert(State().receipt == -1);
  assert(ExternalProtocolHandler::interceptor);  // Late shutdown still cannot dispatch.
  assert(!Initialize(profile, true));  // Exclusive receipt forbids reuse after Reset.
}
