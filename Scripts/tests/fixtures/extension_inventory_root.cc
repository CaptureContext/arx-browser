#include <cassert>
#include <cstdlib>
#include <fcntl.h>
#include <filesystem>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>
namespace base {
struct FilePath {
  std::string path;
  FilePath() = default;
  explicit FilePath(std::string value) : path(std::move(value)) {}
  bool IsAbsolute() const { return std::filesystem::path(path).is_absolute(); }
  const std::string& value() const { return path; }
  FilePath BaseName() const { return FilePath(std::filesystem::path(path).filename().string()); }
  FilePath AppendASCII(const char* name) const { return FilePath(path + "/" + name); }
  bool operator==(const FilePath&) const = default;
  bool empty() const { return path.empty(); }
};
FilePath MakeAbsoluteFilePath(const FilePath& value) {
  std::error_code error;
  auto path = std::filesystem::canonical(value.path, error);
  return error ? FilePath() : FilePath(path.string());
}
}
// PRODUCTION_ROOT
int main() {
  unsetenv("ARX_EXTENSION_SETTINGS_SMOKE_ROOT"); unsetenv("ARX_ENGINE_PROFILE");
  assert(OwnedSettingsDiagnosticProfile().empty());
  char pattern[] = "/private/tmp/app-extension-install-smoke-XXXXXX";
  char* created = mkdtemp(pattern); assert(created);
  const base::FilePath root(created), profile = root.AppendASCII("profile");
  assert(!mkdir(profile.value().c_str(), 0700));
  const auto marker = root.AppendASCII(".arx-extension-settings-smoke");
  auto write_marker = [&](std::string_view text) {
    int file = open(marker.value().c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    assert(file >= 0); assert(write(file, text.data(), text.size()) == static_cast<ssize_t>(text.size()));
    close(file);
  };
  constexpr std::string_view sentinel = "Arx extension Settings disposable fixture v1\n";
  write_marker(sentinel);
  setenv("ARX_EXTENSION_SETTINGS_SMOKE_ROOT", root.value().c_str(), 1);
  setenv("ARX_ENGINE_PROFILE", profile.value().c_str(), 1);
  assert(OwnedSettingsDiagnosticProfile() == profile);
  setenv("ARX_ENGINE_PROFILE", root.AppendASCII("profile-other").value().c_str(), 1);
  assert(OwnedSettingsDiagnosticProfile().empty());
  setenv("ARX_ENGINE_PROFILE", profile.value().c_str(), 1);
  chmod(root.value().c_str(), 0755); assert(OwnedSettingsDiagnosticProfile().empty());
  chmod(root.value().c_str(), 0700);
  chmod(profile.value().c_str(), 0755); assert(OwnedSettingsDiagnosticProfile().empty());
  chmod(profile.value().c_str(), 0700);
  chmod(marker.value().c_str(), 0644); assert(OwnedSettingsDiagnosticProfile().empty());
  chmod(marker.value().c_str(), 0600);
  write_marker("wrong sentinel"); assert(OwnedSettingsDiagnosticProfile().empty());
  write_marker(std::string(10000, 'x')); assert(OwnedSettingsDiagnosticProfile().empty());
  write_marker(sentinel);
  auto saved = root.AppendASCII("saved-marker");
  assert(!rename(marker.value().c_str(), saved.value().c_str()));
  assert(!symlink(saved.value().c_str(), marker.value().c_str()));
  assert(OwnedSettingsDiagnosticProfile().empty()); unlink(marker.value().c_str());
  assert(!mkfifo(marker.value().c_str(), 0600));
  assert(OwnedSettingsDiagnosticProfile().empty()); unlink(marker.value().c_str());
  assert(!rename(saved.value().c_str(), marker.value().c_str()));
  const auto link = root.AppendASCII("profile-link");
  assert(!symlink(profile.value().c_str(), link.value().c_str()));
  setenv("ARX_ENGINE_PROFILE", link.value().c_str(), 1);
  assert(OwnedSettingsDiagnosticProfile().empty());
  setenv("ARX_ENGINE_PROFILE", profile.value().c_str(), 1);
  assert(OwnedSettingsDiagnosticProfile() == profile);
  std::filesystem::remove_all(root.value()); // only this mkdtemp-owned root
}
