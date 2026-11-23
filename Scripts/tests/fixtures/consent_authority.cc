#include "consent_authority.h"
#include <cassert>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>

#define CHECK(condition) assert(condition)
#define DCHECK(condition) assert(condition)
namespace base { using FilePath = std::string; }
struct Profile {
  Profile* parent = nullptr;
  std::string path = "/owned/Default";
  std::string GetPath() const { return path; }
  static Profile* FromBrowserContext(Profile* value) { return value; }
  Profile* GetOriginalProfile() { return parent ? parent : this; }
};
enum class ProfileKeepAliveOrigin { kWebAppPermissionDialogWindow };
struct ScopedProfileKeepAlive {
  static inline bool available = true;
  static inline Profile* acquired = nullptr;
  static std::unique_ptr<ScopedProfileKeepAlive> TryAcquire(Profile* profile, ProfileKeepAliveOrigin) {
    acquired = profile;
    return available ? std::make_unique<ScopedProfileKeepAlive>() : nullptr;
  }
};
struct Guard {
  std::function<bool()> function;
  explicit operator bool() const { return bool(function); }
  bool Run() const { return function(); }
};
std::map<Profile*, size_t> pending;
std::map<Profile*, size_t>& Work() { return pending; }
std::map<Profile*, base::FilePath> paths;
std::map<Profile*, base::FilePath>& WorkPaths() { return paths; }
// PATH_PREDICATE
int drained = 0;
void ConsentActivityChanged(Profile* profile) { assert(profile); ++drained; }
namespace content { struct RenderFrameHost {}; }
namespace url { struct Origin {}; }
namespace blink::mojom {
enum class MediaStreamType { NO_SERVICE, DEVICE_AUDIO_CAPTURE, DEVICE_VIDEO_CAPTURE, DISPLAY_VIDEO_CAPTURE };
}
namespace system_permission_settings {
enum class SystemPermission { kAllowed, kDenied, kNotDetermined };
SystemPermission audio = SystemPermission::kAllowed, video = SystemPermission::kAllowed;
SystemPermission CheckSystemAudioCapturePermission() { return audio; }
SystemPermission CheckSystemVideoCapturePermission() { return video; }
}
bool site_allowed = true;
bool CheckPageMediaAccess(content::RenderFrameHost*, const url::Origin&, blink::mojom::MediaStreamType) {
  return site_allowed;
}
// EXISTING_DEVICE_GRANTS
// MEDIA_WORK

struct Contents { Profile* profile; Profile* GetBrowserContext() { return profile; } };
struct WeakContents {
  Contents* pointer = nullptr;
  explicit operator bool() const { return pointer; }
  Contents* operator->() const { return pointer; }
  Contents* get() const { return pointer; }
};
struct URL { std::string GetScheme() const { return "owned-test"; } };
struct MessageBox { bool remember = true; bool IsCheckBoxSelected() const { return remember; } };
struct ExternalProtocolHandler {
  enum { DONT_BLOCK };
  static inline int metrics = 0, remembered = 0, launches = 0;
  static void RecordHandleStateMetrics(bool, int) { ++metrics; }
  static void SetBlockState(std::string, int, int, Profile*) { ++remembered; }
  static void LaunchUrlWithoutSecurityCheck(URL, Contents*, int) { ++launches; }
};
struct ExternalProtocolDialog {
  Guard source_guard_;
  MessageBox box;
  MessageBox* message_box_view_ = &box;
  WeakContents web_contents_;
  std::optional<int> initiating_origin_ = 42;
  URL url_;
  int initiator_document_ = 1;
  void OnDialogAccepted();
};
// EXTERNAL_ACCEPT

int main() {
  arx::ConsentAuthority authority;
  assert(!authority.Current(authority.generation()));
  authority.Configure(true);
  auto initial = authority.generation();
  assert(authority.Current(initial));
  authority.Invalidate(); // Navigation starts before old document disappears.
  assert(!authority.Current(initial));
  auto next = authority.generation();
  assert(authority.Current(next));
  authority.Configure(false);
  assert(!authority.Current(next));
  authority.Configure(true);
  assert(!authority.Current(next)); // Disable/reenable must not resurrect consent.

  content::RenderFrameHost frame;
  using Type = blink::mojom::MediaStreamType;
  assert(ExistingDeviceGrants(&frame, {}, Type::DEVICE_AUDIO_CAPTURE, Type::DEVICE_VIDEO_CAPTURE));
  assert(!ExistingDeviceGrants(&frame, {}, Type::NO_SERVICE, Type::DISPLAY_VIDEO_CAPTURE));
  assert(!ExistingDeviceGrants(&frame, {}, Type::NO_SERVICE, Type::NO_SERVICE));
  site_allowed = false;
  assert(!ExistingDeviceGrants(&frame, {}, Type::DEVICE_AUDIO_CAPTURE, Type::NO_SERVICE));
  site_allowed = true;
  system_permission_settings::audio = system_permission_settings::SystemPermission::kNotDetermined;
  assert(!ExistingDeviceGrants(&frame, {}, Type::DEVICE_AUDIO_CAPTURE, Type::NO_SERVICE));
  system_permission_settings::audio = system_permission_settings::SystemPermission::kDenied;
  assert(!ExistingDeviceGrants(&frame, {}, Type::DEVICE_AUDIO_CAPTURE, Type::NO_SERVICE));
  assert(ExistingDeviceGrants(&frame, {}, Type::NO_SERVICE, Type::DEVICE_VIDEO_CAPTURE));
  Profile parent, other, private_profile{&parent};
  other.path = "/owned/Other";
  {
    MediaWork first(&private_profile);
    assert(ScopedProfileKeepAlive::acquired == &parent);
    assert(pending[&private_profile] == 1 && !pending.contains(&parent));
    assert(HasPageConsentWorkForPath("/owned/Default"));
    assert(!HasPageConsentWorkForPath("/owned/Unknown"));
    private_profile.path = "/unmapped/changed";
    assert(HasPageConsentWorkForPath("/owned/Default")); // Immutable capture survives map/path changes.
    {
      MediaWork second(&private_profile), independent(&other);
      assert(pending[&private_profile] == 2 && pending[&other] == 1);
    }
    assert(pending[&private_profile] == 1 && !pending.contains(&other));
  }
  assert(pending.empty() && paths.empty() && drained == 3);
  ScopedProfileKeepAlive::available = false;
  { MediaWork unavailable(&private_profile); assert(!unavailable.keep_alive); }
  assert(pending.empty() && paths.empty() && drained == 3);

  Contents contents{&parent};
  ExternalProtocolDialog dialog;
  dialog.web_contents_.pointer = &contents;
  auto token = authority.generation();
  dialog.source_guard_.function = [&] { return authority.Current(token); };
  authority.Invalidate(); // Navigation or transfer during shell handler lookup/UI.
  dialog.OnDialogAccepted();
  assert(!ExternalProtocolHandler::metrics && !ExternalProtocolHandler::remembered &&
         !ExternalProtocolHandler::launches);
  token = authority.generation();
  dialog.OnDialogAccepted();
  assert(ExternalProtocolHandler::metrics == 1 && ExternalProtocolHandler::remembered == 1 &&
         ExternalProtocolHandler::launches == 1);
  authority.Configure(false);
  dialog.OnDialogAccepted();
  assert(ExternalProtocolHandler::remembered == 1 && ExternalProtocolHandler::launches == 1);
  dialog.source_guard_ = {}; // Ordinary upstream Chrome behavior remains unchanged.
  dialog.box.remember = false;
  dialog.OnDialogAccepted();
  assert(ExternalProtocolHandler::remembered == 1 && ExternalProtocolHandler::launches == 2);
}
