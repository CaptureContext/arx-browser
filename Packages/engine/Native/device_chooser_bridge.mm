#include "chrome/browser/arx/device_chooser_bridge.h"

#import <Foundation/Foundation.h>

#include <algorithm>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/values.h"
#include "chrome/browser/arx/device_chooser_hooks.h"
#include "chrome/browser/arx/engine_bridge.h"
#include "chrome/browser/bluetooth/bluetooth_chooser_context_factory.h"
#include "chrome/browser/hid/hid_chooser_context.h"
#include "chrome/browser/hid/hid_chooser_context_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/serial/serial_chooser_context.h"
#include "chrome/browser/serial/serial_chooser_context_factory.h"
#include "chrome/browser/usb/usb_chooser_context.h"
#include "chrome/browser/usb/usb_chooser_context_factory.h"
#include "components/permissions/chooser_controller.h"
#include "components/permissions/contexts/bluetooth_chooser_context.h"
#include "components/permissions/object_permission_context_base.h"
#include "content/public/browser/global_routing_id.h"
#include "content/public/browser/page.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace arx {
namespace {

// At most this many options reach the app; a chooser lists nearby devices.
constexpr size_t kMaximumOptions = 256;

struct Handler {
  ArxDeviceChooserHandler function = nullptr;
  void* context = nullptr;
};

Handler& CurrentHandler() {
  // Trivially destructible, so a plain function-local static (NoDestructor refuses it).
  static Handler handler;
  return handler;
}

void Notify(uint64_t page, uint64_t token, bool open) {
  const Handler handler = CurrentHandler();
  if (handler.function) handler.function(handler.context, page, token, open);
}

void PostNotify(uint64_t page, uint64_t token, bool open) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&Notify, page, token, open));
}

void Close(uint64_t page, uint64_t token);

// One page's chooser, owning Chrome's controller and standing in for its view.
// It ends when the frame that asked goes away or the page moves on, before
// the controller could outlive what it points at.
class Chooser final : public permissions::ChooserController::View,
                      public content::WebContentsObserver {
 public:
  Chooser(uint64_t page, uint64_t token, content::RenderFrameHost* owner,
          std::unique_ptr<permissions::ChooserController> controller)
      : content::WebContentsObserver(content::WebContents::FromRenderFrameHost(owner)),
        page_(page),
        token_(token),
        owner_(owner->GetGlobalId()),
        controller_(std::move(controller)) {
    controller_->set_view(this);
  }

  ~Chooser() override { controller_->set_view(nullptr); }

  // content::WebContentsObserver:
  void RenderFrameDeleted(content::RenderFrameHost* frame) override {
    if (frame->GetGlobalId() == owner_) Close(page_, token_);
  }
  void PrimaryPageChanged(content::Page& page) override { Close(page_, token_); }
  void WebContentsDestroyed() override { Close(page_, token_); }

  uint64_t token() const { return token_; }
  // Counts the list's changes, so an answer names the list the person saw.
  uint64_t revision() const { return revision_; }
  permissions::ChooserController& controller() { return *controller_; }
  bool scanning() const { return scanning_; }
  bool adapter_off() const { return adapter_off_; }

  // permissions::ChooserController::View:
  void OnOptionsInitialized() override { Changed(); }
  void OnOptionAdded(size_t index) override { Changed(); }
  void OnOptionRemoved(size_t index) override { Changed(); }
  void OnOptionUpdated(size_t index) override { Changed(); }
  void OnAdapterEnabledChanged(bool enabled) override {
    adapter_off_ = !enabled;
    Changed();
  }
  void OnRefreshStateChanged(bool refreshing) override {
    scanning_ = refreshing;
    Changed();
  }

 private:
  void Changed() {
    ++revision_;
    PostNotify(page_, token_, true);
  }

  const uint64_t page_;
  const uint64_t token_;
  const content::GlobalRenderFrameHostId owner_;
  std::unique_ptr<permissions::ChooserController> controller_;
  bool scanning_ = false;
  bool adapter_off_ = false;
  uint64_t revision_ = 0;
};

struct State {
  std::map<uint64_t, std::unique_ptr<Chooser>> choosers;
  uint64_t next_token = 1;
};

State& Choosers() {
  static base::NoDestructor<State> state;
  return *state;
}

// Ends the page's chooser `token`, if it's still the page's, without answering.
// It may be called from the chooser's own observer method, so the chooser is
// deleted after a posted task.
void Close(uint64_t page, uint64_t token) {
  auto& choosers = Choosers().choosers;
  auto found = choosers.find(page);
  if (found == choosers.end() || found->second->token() != token) return;
  std::unique_ptr<Chooser> chooser = std::move(found->second);
  choosers.erase(found);
  chooser->controller().Close();
  base::SingleThreadTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE, std::move(chooser));
  PostNotify(page, token, false);
}

// Chrome's ShowDeviceChooserDialog, before it looks for a browser window.
bool TakeChooser(content::RenderFrameHost* owner,
                 std::unique_ptr<permissions::ChooserController>& controller,
                 base::OnceClosure* close) {
  auto* contents = owner ? content::WebContents::FromRenderFrameHost(owner) : nullptr;
  const uint64_t page = contents ? PageIdentifier(contents) : 0;
  if (!page || !controller || !close) return false;

  auto& state = Choosers();
  // Nobody to ask (a headless run), or the page already asks: cancel at once,
  // so the page's promise rejects instead of waiting.
  if (!CurrentHandler().function || state.choosers.contains(page)) {
    controller->Cancel();
    controller.reset();
    *close = base::DoNothing();
    return true;
  }
  const uint64_t token = state.next_token++;
  state.choosers[page] = std::make_unique<Chooser>(page, token, owner, std::move(controller));
  *close = base::BindOnce(&Close, page, token);
  PostNotify(page, token, true);
  return true;
}

Chooser* Current(uint64_t page, uint64_t token) {
  auto& choosers = Choosers().choosers;
  auto found = choosers.find(page);
  if (found == choosers.end() || found->second->token() != token) return nullptr;
  return found->second.get();
}

size_t Copy(const std::string& json, char* buffer, size_t capacity) {
  if (buffer && capacity > json.size()) {
    std::memcpy(buffer, json.data(), json.size());
    buffer[json.size()] = '\0';
  }
  return json.size();
}

// A loaded ordinary profile's chooser contexts, by kind.
std::vector<std::pair<const char*, permissions::ObjectPermissionContextBase*>> Contexts(
    Profile* profile) {
  return {
      {"usb", UsbChooserContextFactory::GetForProfile(profile)},
      {"hid", HidChooserContextFactory::GetForProfile(profile)},
      {"serial", SerialChooserContextFactory::GetForProfile(profile)},
      {"bluetooth", BluetoothChooserContextFactory::GetForProfile(profile)},
  };
}

}  // namespace
}  // namespace arx

extern "C" __attribute__((visibility("default")))
void ArxEngineSetDeviceChooserHandler(ArxDeviceChooserHandler handler, void* context) {
  CHECK([NSThread isMainThread]);
  arx::CurrentHandler() = {handler, context};
  arx::SetDeviceChooserHandler(&arx::TakeChooser);
  if (handler) return;
  // Without a handler nobody answers: cancel what's open.
  auto choosers = std::move(arx::Choosers().choosers);
  arx::Choosers().choosers.clear();
  for (auto& [page, chooser] : choosers) chooser->controller().Cancel();
}

extern "C" __attribute__((visibility("default")))
size_t ArxEngineCopyDeviceChooser(uint64_t page, char* buffer, size_t capacity) {
  CHECK([NSThread isMainThread]);
  auto& choosers = arx::Choosers().choosers;
  auto found = choosers.find(page);
  if (found == choosers.end()) return 0;
  arx::Chooser& chooser = *found->second;
  permissions::ChooserController& controller = chooser.controller();

  base::ListValue options;
  const size_t count = std::min(controller.NumOptions(), arx::kMaximumOptions);
  for (size_t index = 0; index < count; ++index) {
    base::DictValue option;
    option.Set("name", base::UTF16ToUTF8(controller.GetOption(index)));
    option.Set("connected", controller.IsConnected(index));
    option.Set("paired", controller.IsPaired(index));
    option.Set("signal", controller.GetSignalStrengthLevel(index));
    options.Append(std::move(option));
  }
  base::DictValue body;
  // A token as a string: JSON numbers lose 64-bit precision.
  body.Set("token", base::NumberToString(chooser.token()));
  body.Set("revision", base::NumberToString(chooser.revision()));
  body.Set("title", base::UTF16ToUTF8(controller.GetTitle()));
  body.Set("multiple", controller.AllowMultipleSelection());
  body.Set("rescan", controller.ShouldShowReScanButton());
  body.Set("scanning", chooser.scanning());
  body.Set("adapterOff", chooser.adapter_off() || controller.ShouldShowAdapterOffView());
  body.Set("options", std::move(options));
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(body)), &json);
  return arx::Copy(json, buffer, capacity);
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineAnswerDeviceChooser(uint64_t page, uint64_t token, uint64_t revision,
                                  const uint32_t* indices, size_t count) {
  CHECK([NSThread isMainThread]);
  arx::Chooser* chooser = arx::Current(page, token);
  if (!chooser || (count && !indices)) return false;
  // A choice from a list that has changed since may name another device.
  if (count && chooser->revision() != revision) return false;
  permissions::ChooserController& controller = chooser->controller();
  std::vector<size_t> chosen;
  for (size_t index = 0; index < count; ++index) {
    if (indices[index] >= controller.NumOptions()) return false;
    chosen.push_back(indices[index]);
  }
  if (chosen.size() > 1 && !controller.AllowMultipleSelection()) return false;

  auto& choosers = arx::Choosers().choosers;
  std::unique_ptr<arx::Chooser> owned = std::move(choosers[page]);
  choosers.erase(page);
  if (chosen.empty()) {
    owned->controller().Cancel();
  } else {
    owned->controller().Select(chosen);
  }
  arx::PostNotify(page, token, false);
  return true;
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineRescanDeviceChooser(uint64_t page, uint64_t token) {
  CHECK([NSThread isMainThread]);
  arx::Chooser* chooser = arx::Current(page, token);
  if (!chooser || !chooser->controller().ShouldShowReScanButton()) return false;
  chooser->controller().RefreshOptions();
  return true;
}

extern "C" __attribute__((visibility("default")))
size_t ArxEngineCopyDeviceGrants(const char* profile_key, char* buffer, size_t capacity) {
  CHECK([NSThread isMainThread]);
  Profile* profile = arx::LoadedOrdinaryProfile(profile_key ? profile_key : "");
  if (!profile) return 0;
  base::ListValue grants;
  for (const auto& [kind, context] : arx::Contexts(profile)) {
    if (!context) continue;
    for (const auto& object : context->GetAllGrantedObjects()) {
      base::DictValue grant;
      grant.Set("kind", kind);
      grant.Set("origin", url::Origin::Create(object->origin).Serialize());
      grant.Set("key", context->GetKeyForObject(object->value));
      grant.Set("name", base::UTF16ToUTF8(context->GetObjectDisplayNameForUI(object->value)));
      grants.Append(std::move(grant));
    }
  }
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(grants)), &json);
  return arx::Copy(json, buffer, capacity);
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineRevokeDeviceGrant(const char* profile_key, const char* kind, const char* origin,
                                const char* key) {
  CHECK([NSThread isMainThread]);
  Profile* profile = arx::LoadedOrdinaryProfile(profile_key ? profile_key : "");
  if (!profile || !kind || !origin || !key) return false;
  const url::Origin site = url::Origin::Create(GURL(origin));
  if (site.opaque()) return false;
  for (const auto& [name, context] : arx::Contexts(profile)) {
    if (!context || std::strcmp(name, kind) != 0) continue;
    for (const auto& object : context->GetGrantedObjects(site)) {
      if (context->GetKeyForObject(object->value) != key) continue;
      context->RevokeObjectPermission(site, object->value);
      return true;
    }
  }
  return false;
}
