#include "chrome/browser/arx/cast_bridge.h"

#include <cstring>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/json/json_writer.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/values.h"
#include "chrome/browser/arx/cast_hooks.h"
#include "chrome/browser/arx/engine_bridge.h"
#include "chrome/browser/media/router/media_router_feature.h"
#include "chrome/browser/ui/media_router/cast_dialog_controller.h"
#include "chrome/browser/ui/media_router/cast_dialog_model.h"
#include "chrome/browser/ui/media_router/media_cast_mode.h"
#include "chrome/browser/ui/media_router/media_router_ui.h"
#include "chrome/browser/ui/media_router/ui_media_sink.h"
#include "components/media_router/browser/media_router_dialog_controller.h"
#include "components/media_router/browser/media_router_metrics.h"
#include "components/media_router/browser/presentation/start_presentation_context.h"
#include "components/media_router/common/issue.h"
#include "components/media_router/common/media_route.h"
#include "components/media_router/common/media_sink.h"
#include "components/media_router/common/mojom/media_route_provider_id.mojom.h"
#include "content/public/browser/navigation_details.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "third_party/blink/public/mojom/presentation/presentation.mojom.h"
#include "ui/display/types/display_constants.h"

namespace arx {
namespace {

using media_router::CastDialogModel;
using media_router::MediaCastMode;
using media_router::MediaRouterDialogActivationLocation;
using media_router::MediaRouterUI;
using media_router::StartPresentationContext;
using media_router::UIMediaSink;
using media_router::UIMediaSinkState;

struct CastHandler {
  void (*handler)(void* context, uint64_t page, const char* json) = nullptr;
  void* context = nullptr;
  std::string menu_title;
};

CastHandler& Handler() {
  static base::NoDestructor<CastHandler> handler;
  return *handler;
}

class CastPicker;

// The pickers open now, so clearing the handler can close them.
std::vector<base::WeakPtr<CastPicker>>& OpenPickers() {
  static base::NoDestructor<std::vector<base::WeakPtr<CastPicker>>> pickers;
  return *pickers;
}

// Only the modes Arx's picker offers: a site's presentation and the tab.
// Desktop mirroring and remote playback stay with Chrome's own UI, which Arx
// doesn't show.
bool Offered(MediaCastMode mode) {
  return mode == media_router::PRESENTATION || mode == media_router::TAB_MIRROR;
}

// Chrome's choice for a tab (CastDialogView::GetCastModeToUse): the site's
// presentation when the device takes it, else the tab.
std::optional<MediaCastMode> PreferredMode(const UIMediaSink& sink) {
  if (sink.cast_modes.contains(media_router::PRESENTATION))
    return media_router::PRESENTATION;
  if (sink.cast_modes.contains(media_router::TAB_MIRROR))
    return media_router::TAB_MIRROR;
  return std::nullopt;
}

const char* StateName(UIMediaSinkState state) {
  switch (state) {
    case UIMediaSinkState::AVAILABLE: return "available";
    case UIMediaSinkState::CONNECTING: return "connecting";
    case UIMediaSinkState::CONNECTED: return "connected";
    case UIMediaSinkState::DISCONNECTING: return "disconnecting";
    case UIMediaSinkState::UNAVAILABLE: return "unavailable";
  }
  return "unavailable";
}

const char* IconName(media_router::SinkIconType icon) {
  switch (icon) {
    case media_router::SinkIconType::CAST: return "cast";
    case media_router::SinkIconType::CAST_AUDIO: return "audio";
    case media_router::SinkIconType::CAST_AUDIO_GROUP: return "audioGroup";
    case media_router::SinkIconType::WIRED_DISPLAY: return "display";
    default: return "generic";
  }
}

bool CanCast(content::WebContents* contents) {
  return contents && Handler().handler && PageIdentifier(contents) &&
      media_router::MediaRouterEnabled(contents->GetBrowserContext());
}

// Arx's Media Router dialog for one WebContents. Chrome's controller would draw
// a views bubble; this one keeps Chrome's model (MediaRouterUI) and reports it
// to the app, which draws the picker and answers through the exports below.
class CastPicker final
    : public media_router::MediaRouterDialogController,
      public content::WebContentsObserver,
      public content::WebContentsUserData<CastPicker>,
      public media_router::CastDialogController::Observer {
 public:
  ~CastPicker() override {
    closing_ = true;
    Reset();
  }

  // A site's Cast button (PresentationRequest.start()).
  bool ShowMediaRouterDialogForPresentation(
      std::unique_ptr<StartPresentationContext> context) override {
    if (ui_) {
      context->InvokeErrorCallback(blink::mojom::PresentationError(
          blink::mojom::PresentationErrorType::UNKNOWN,
          "Unable to create dialog: dialog already shown"));
      return false;
    }
    if (!CanCast(&GetWebContents())) {
      context->InvokeErrorCallback(blink::mojom::PresentationError(
          blink::mojom::PresentationErrorType::NO_AVAILABLE_SCREENS,
          "No screens found."));
      return false;
    }
    start_presentation_context_ = std::move(context);
    CreateMediaRouterDialog(MediaRouterDialogActivationLocation::PAGE);
    return true;
  }

  // The page menu and the app's media controls. Unlike Chrome's, it never
  // activates the page: the app shows the picker where the page is.
  bool ShowMediaRouterDialog(
      MediaRouterDialogActivationLocation activation_location) override {
    if (ui_) {
      SchedulePublish();
      return false;
    }
    if (!CanCast(&GetWebContents())) return false;
    CreateMediaRouterDialog(activation_location);
    return true;
  }

  bool IsShowingMediaRouterDialog() const override { return !!ui_; }

  bool Choose(const std::string& id, int32_t mode) {
    if (!ui_) return false;
    for (const UIMediaSink& sink : sinks_) {
      if (sink.id != id) continue;
      if (sink.issue) {
        const media_router::Issue::Id issue = sink.issue->id();
        ui_->ClearIssue(issue);
        return true;
      }
      std::optional<MediaCastMode> chosen;
      if (mode == 0) {
        chosen = PreferredMode(sink);
      } else if (Offered(static_cast<MediaCastMode>(mode)) &&
                 sink.cast_modes.contains(static_cast<MediaCastMode>(mode))) {
        chosen = static_cast<MediaCastMode>(mode);
      }
      if (!chosen) return false;
      // As Chrome's: a connected Cast device takes a new session in place of
      // its old one; a connected DIAL device stops first.
      if (sink.state == UIMediaSinkState::CONNECTED && sink.route &&
          sink.provider == media_router::mojom::MediaRouteProviderId::DIAL) {
        const std::string route = sink.route->media_route_id();
        ui_->StopCasting(route);
        return true;
      }
      if (sink.state != UIMediaSinkState::AVAILABLE &&
          sink.state != UIMediaSinkState::CONNECTED)
        return false;
      // The model may change, and sinks_ with it, inside StartCasting.
      const std::string sink_id = sink.id;
      ui_->StartCasting(sink_id, *chosen);
      return true;
    }
    return false;
  }

  bool Stop(const std::string& route) {
    if (!ui_) return false;
    for (const UIMediaSink& sink : sinks_) {
      if (sink.route && sink.route->media_route_id() == route) {
        const std::string id = route;
        ui_->StopCasting(id);
        return true;
      }
    }
    return false;
  }

 protected:
  void CreateMediaRouterDialog(
      MediaRouterDialogActivationLocation activation_location) override {
    // As Chrome's: the page leaves full screen and can't return while the
    // picker is open, so it can't draw over or imitate it. Dropping it may
    // run the message loop and destroy the page.
    const base::WeakPtr<CastPicker> weak = weak_factory_.GetWeakPtr();
    auto blocker = GetWebContents().ForSecurityDropFullscreen(display::kInvalidDisplayId);
    if (!weak) return;
    if (!blocker) {
      // A request that can't show fails as if it closed (MediaRouterDialogController::Reset).
      MediaRouterDialogController::Reset();
      return;
    }
    fullscreen_blocker_ = std::move(*blocker);
    presentation_ = !!start_presentation_context_;
    ui_ = start_presentation_context_
        ? MediaRouterUI::CreateWithStartPresentationContextAndMirroring(
              &GetWebContents(), std::move(start_presentation_context_))
        : MediaRouterUI::CreateWithDefaultMediaSourceAndMirroring(
              &GetWebContents());
    OpenPickers().push_back(weak_factory_.GetWeakPtr());
    // Reports the model at once (OnModelUpdated); publishing is posted.
    ui_->AddObserver(this);
    SchedulePublish();
  }

  void CloseMediaRouterDialog() override { Reset(); }

  void Reset() override {
    const bool was_open = !!ui_;
    if (ui_) {
      std::erase_if(OpenPickers(), [this](const base::WeakPtr<CastPicker>& open) {
        return !open || open.get() == this;
      });
      ui_->RemoveObserver(this);
      // A site's request that never cast fails here (MediaRouteStarter).
      ui_.reset();
    }
    sinks_.clear();
    source_.clear();
    permission_rejected_ = false;
    presentation_ = false;
    MediaRouterDialogController::Reset();
    fullscreen_blocker_.RunAndReset();
    if (was_open) PostClosed();
  }

 private:
  friend class content::WebContentsUserData<CastPicker>;
  WEB_CONTENTS_USER_DATA_KEY_DECL();

  explicit CastPicker(content::WebContents* contents)
      : MediaRouterDialogController(contents),
        content::WebContentsObserver(contents),
        content::WebContentsUserData<CastPicker>(*contents) {}

  // media_router::CastDialogController::Observer:
  void OnModelUpdated(const CastDialogModel& model) override {
    sinks_ = model.media_sinks();
    source_ = base::UTF16ToUTF8(model.dialog_header());
    permission_rejected_ = model.is_permission_rejected();
    SchedulePublish();
  }

  // As Chrome's device list, the picker closes once casting starts. Never
  // inside the Media Router's own call.
  void OnCastingStarted() override { PostClose(); }

  void OnControllerDestroying() override {}

  // As Chrome's InitiatorWebContentsObserver: a new entry, a crash or the
  // page going away closes the picker.
  void NavigationEntryCommitted(const content::LoadCommittedDetails&) override {
    PostClose();
  }
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override {
    PostClose();
  }
  void WebContentsDestroyed() override { Reset(); }

  void PostClose() {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(
                       [](base::WeakPtr<CastPicker> picker) {
                         if (picker) picker->HideMediaRouterDialog();
                       },
                       weak_factory_.GetWeakPtr()));
  }

  void SchedulePublish() {
    if (publish_scheduled_) return;
    publish_scheduled_ = true;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&CastPicker::Publish,
                                  weak_factory_.GetWeakPtr()));
  }

  void Publish() {
    publish_scheduled_ = false;
    const auto& handler = Handler();
    const uint64_t page = PageIdentifier(&GetWebContents());
    if (!ui_ || !handler.handler || !page) return;
    base::ListValue devices;
    for (const UIMediaSink& sink : sinks_) {
      base::ListValue modes;
      for (MediaCastMode mode : sink.cast_modes)
        if (Offered(mode)) modes.Append(static_cast<int>(mode));
      base::DictValue device;
      device.Set("id", sink.id);
      device.Set("name", base::UTF16ToUTF8(sink.friendly_name));
      device.Set("state", StateName(sink.state));
      device.Set("icon", IconName(sink.icon_type));
      device.Set("modes", std::move(modes));
      if (!sink.status_text.empty())
        device.Set("status", base::UTF16ToUTF8(sink.status_text));
      if (sink.issue) device.Set("issue", sink.issue->info().title);
      if (sink.route) device.Set("route", sink.route->media_route_id());
      devices.Append(std::move(device));
    }
    base::DictValue picker;
    picker.Set("source", source_);
    picker.Set("presentation", presentation_);
    picker.Set("permissionRejected", permission_rejected_);
    picker.Set("devices", std::move(devices));
    const std::optional<std::string> json = base::WriteJson(picker);
    if (!json) return;
    // No member access after this call: the app may close the picker or the page.
    handler.handler(handler.context, page, json->c_str());
  }

  void PostClosed() {
    if (closing_) {
      // The page is going away; the app hears about that from the page.
      return;
    }
    const uint64_t page = PageIdentifier(&GetWebContents());
    if (!page) return;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(
                       [](uint64_t page) {
                         const auto& handler = Handler();
                         // A picker opened again since then reports itself.
                         auto* contents = PageContents(page);
                         auto* picker = contents ? CastPicker::FromWebContents(contents)
                                                 : nullptr;
                         if (handler.handler && !(picker && picker->IsShowingMediaRouterDialog()))
                           handler.handler(handler.context, page, nullptr);
                       },
                       page));
  }

  std::unique_ptr<MediaRouterUI> ui_;
  base::ScopedClosureRunner fullscreen_blocker_;
  std::vector<UIMediaSink> sinks_;
  std::string source_;
  bool permission_rejected_ = false;
  bool presentation_ = false;
  bool publish_scheduled_ = false;
  bool closing_ = false;
  base::WeakPtrFactory<CastPicker> weak_factory_{this};
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(CastPicker);

media_router::MediaRouterDialogController* CastPickerFor(
    content::WebContents* contents) {
  CastPicker::CreateForWebContents(contents);
  return CastPicker::FromWebContents(contents);
}

CastPicker* OpenPicker(uint64_t page) {
  auto* contents = PageContents(page);
  auto* picker = contents ? CastPicker::FromWebContents(contents) : nullptr;
  return picker && picker->IsShowingMediaRouterDialog() ? picker : nullptr;
}

}  // namespace

void StartCastPicker() {
  SetCastDialogFactory(&CastPickerFor);
}

std::string CastMenuTitle(content::WebContents* contents) {
  return CanCast(contents) ? Handler().menu_title : std::string();
}

bool ShowCastPicker(content::WebContents* contents) {
  if (!CanCast(contents)) return false;
  // Through Chromium's own getter, so the picker is the one the Presentation
  // API reaches.
  media_router::MediaRouterDialogController::GetOrCreateForWebContents(contents)
      ->ShowMediaRouterDialog(MediaRouterDialogActivationLocation::CONTEXTUAL_MENU);
  return true;
}

}  // namespace arx

extern "C" __attribute__((visibility("default")))
void ArxEngineSetCastPickerHandler(void (*handler)(void*, uint64_t, const char*),
                                   void* context,
                                   const char* menu_title) {
  auto& current = arx::Handler();
  const bool closing = current.handler && !handler;
  current.handler = handler;
  current.context = context;
  current.menu_title = menu_title && strnlen(menu_title, 257) <= 256 ? menu_title : "";
  if (!closing) return;
  // Nobody shows pickers any more: close the open ones.
  const auto open = arx::OpenPickers();
  for (const auto& picker : open)
    if (picker) picker->HideMediaRouterDialog();
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineShowCastPicker(uint64_t page) {
  return arx::ShowCastPicker(arx::PageContents(page));
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineChooseCastDevice(uint64_t page, const char* device, int32_t mode) {
  auto* picker = arx::OpenPicker(page);
  return picker && device && picker->Choose(device, mode);
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineStopCasting(uint64_t page, const char* route) {
  auto* picker = arx::OpenPicker(page);
  return picker && route && picker->Stop(route);
}

extern "C" __attribute__((visibility("default")))
void ArxEngineCloseCastPicker(uint64_t page) {
  if (auto* picker = arx::OpenPicker(page)) picker->HideMediaRouterDialog();
}
