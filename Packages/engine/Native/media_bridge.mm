#include "chrome/browser/arx/media_bridge.h"
#include "chrome/browser/arx/media_freeze_policy.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <cmath>
#include <optional>
#include <string>
#include <tuple>
#include <vector>

#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/timer/timer.h"
#include "chrome/browser/media/webrtc/media_capture_devices_dispatcher.h"
#include "chrome/browser/media/webrtc/media_stream_capture_indicator.h"
#include "chrome/browser/picture_in_picture/picture_in_picture_window_manager.h"
#include "components/performance_manager/public/freezing/freezing.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/media_session.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "services/media_session/public/cpp/media_image_manager.h"
#include "services/media_session/public/cpp/media_metadata.h"
#include "services/media_session/public/mojom/media_session.mojom.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "ui/gfx/codec/png_codec.h"
#include "url/origin.h"

namespace arx {
namespace {
using SessionAction = media_session::mojom::MediaSessionAction;
using SessionInfo = media_session::mojom::MediaSessionInfo;

struct Value {
  uint64_t generation = 1;
  bool present = false, video = false, picture = false;
  int playback = 0;
  uint32_t actions = 0;
  std::string title, origin;
  // ABI53 (DEV-906).
  std::string artist;
  std::vector<uint8_t> artwork;
  // ABI54 (DEV-948).
  bool call = false;
  ArxMediaDeviceState microphone = ARX_MEDIA_DEVICE_UNKNOWN, camera = ARX_MEDIA_DEVICE_UNKNOWN;
  bool operator==(const Value&) const = default;
};

// DEV-906: artwork is asked for at this size, and never smaller than the minimum.
constexpr int kArtworkMinimumSize = 48;
constexpr int kArtworkSize = 256;

class Observer final : public MediaBridge,
                       public content::WebContentsObserver,
                       public media_session::mojom::MediaSessionObserver,
                       public MediaStreamCaptureIndicator::Observer {
 public:
  Observer(uint64_t page, content::WebContents* contents, MediaCallbacks callbacks)
      : content::WebContentsObserver(contents), page_(page), callbacks_(callbacks),
        capture_indicator_(MediaCaptureDevicesDispatcher::GetInstance()
                               ->GetMediaStreamCaptureIndicator()) {
    // ABI54 (DEV-948): a call starts and ends with the page's camera and microphone.
    if (capture_indicator_) capture_indicator_->AddObserver(this);
    if (IsCapturing()) awaiting_player_ = false;
    if (auto* session = content::MediaSession::GetIfExists(contents)) Bind(session);
    Refresh();
  }
  ~Observer() override {
    if (capture_indicator_) capture_indicator_->RemoveObserver(this);
    Complete(ARX_MEDIA_STALE);
    media_runnable_lease_.reset();
    // Destruction is an explicit page teardown, outside Chromium observer delivery.
    Exit();
    receiver_.reset();
    ArxMediaSnapshot removed = {};
    removed.generation = value_.generation;
    removed.revision = ++revision_;
    PostChanged(removed);
  }

  void Perform(uint64_t request, uint64_t generation, uint64_t revision,
               ArxMediaAction action) override {
    // A seek needs its time; only Seek starts one.
    if (action == ARX_MEDIA_SEEK) { Reply(request, ARX_MEDIA_UNSUPPORTED); return; }
    auto* session = Begin(request, generation, revision, action);
    if (!session) return;
    // ABI53: nothing on the page reports a track change, so these complete
    // once the session has them.
    if (action == ARX_MEDIA_NEXT_TRACK || action == ARX_MEDIA_PREVIOUS_TRACK) {
      if (action == ARX_MEDIA_NEXT_TRACK) session->NextTrack();
      else session->PreviousTrack();
      Complete(ARX_MEDIA_SUCCESS);
      ScheduleRefresh();
      return;
    }
    switch (action) {
      case ARX_MEDIA_PLAY: session->Resume(content::MediaSession::SuspendType::kUI); break;
      case ARX_MEDIA_PAUSE: session->Suspend(content::MediaSession::SuspendType::kUI); break;
      case ARX_MEDIA_ENTER_PICTURE: session->EnterPictureInPicture(); break;
      case ARX_MEDIA_ENTER_AUTOMATIC_PICTURE: session->EnterAutoPictureInPicture(); break;
      case ARX_MEDIA_EXIT_PICTURE: Exit(); break;
      case ARX_MEDIA_SEEK: break;
      case ARX_MEDIA_NEXT_TRACK: case ARX_MEDIA_PREVIOUS_TRACK: break;
      // ABI54 (DEV-948). Done once the site's handler is asked; its answer
      // arrives as new microphone and camera states, or the call ending.
      case ARX_MEDIA_TOGGLE_MICROPHONE: session->ToggleMicrophone(); Complete(ARX_MEDIA_SUCCESS); break;
      case ARX_MEDIA_TOGGLE_CAMERA: session->ToggleCamera(); Complete(ARX_MEDIA_SUCCESS); break;
      case ARX_MEDIA_HANG_UP: session->HangUp(); Complete(ARX_MEDIA_SUCCESS); break;
    }
    ScheduleRefresh();
  }
  void Seek(uint64_t request, uint64_t generation, uint64_t revision,
            double seconds) override {
    if (!std::isfinite(seconds) || seconds < 0) { Reply(request, ARX_MEDIA_UNSUPPORTED); return; }
    auto* session = Begin(request, generation, revision, ARX_MEDIA_SEEK);
    if (!session) return;
    seek_target_ = seconds;
    if (auto position = session->GetMediaSessionPosition()) {
      const auto duration = position->duration();
      if (!duration.is_max() && duration.is_positive())
        seek_target_ = std::min(seek_target_, duration.InSecondsF());
    }
    seek_started_ = base::TimeTicks::Now();
    // Position notifications are coalesced and skipped when nothing moves, so
    // a pending seek polls the session itself. Nothing crosses to Swift.
    seek_poll_.Start(FROM_HERE, base::Milliseconds(100),
        base::BindRepeating(&Observer::Refresh, weak_.GetWeakPtr()));
    session->SeekTo(base::Seconds(seek_target_));
    ScheduleRefresh();
  }
  void Position(ArxMediaPosition* position) const override {
    *position = {};
    if (!web_contents()) return;
    position->muted = web_contents()->IsAudioMuted();
    if (!IsCurrent(value_.generation)) return;
    position->generation = value_.generation;
    auto* session = content::MediaSession::GetIfExists(web_contents());
    auto current = session ? session->GetMediaSessionPosition() : std::nullopt;
    if (!current) return;
    const auto duration = current->duration();
    const bool bounded = !duration.is_max() && duration.is_positive();
    double seconds = std::max(0.0, current->GetPosition().InSecondsF());
    if (bounded) seconds = std::min(seconds, duration.InSecondsF());
    position->has_position = true;
    position->position = seconds;
    position->duration = bounded ? duration.InSecondsF() : -1;
    position->playback_rate = current->playback_rate();
  }
  void Cancel(uint64_t request) override {
    if (request_ == request) Complete(ARX_MEDIA_CANCELLED);
  }
  content::PictureInPictureResult Enter() override {
    Refresh();
    // Reject direct private/page-script entry and late site handlers after cancellation.
    if (entry_quarantined_ || !request_ || !IsEntry(action_) ||
        request_generation_ != value_.generation ||
        (action_ == ARX_MEDIA_ENTER_AUTOMATIC_PICTURE && !Supported(action_)) ||
        web_contents()->GetBrowserContext()->IsOffTheRecord())
      return content::PictureInPictureResult::kNotSupported;
    ++picture_epoch_;
    auto result = PictureInPictureWindowManager::GetInstance()->EnterVideoPictureInPicture(web_contents());
    ScheduleRefresh();
    return result;
  }
  void Exit() override {
    auto* manager = PictureInPictureWindowManager::GetInstance();
    if (manager->GetWebContents() == web_contents()) manager->ExitPictureInPicture();
  }
  bool IsCurrent(uint64_t generation) const override {
    // Invalidate mutates generation synchronously, before Refresh/PostChanged and
    // the Swift stream drain. Never refresh or activate from this read-only query.
    return generation != 0 && generation == value_.generation && value_.present &&
        !crashed_ && !awaiting_player_ && web_contents() &&
        !web_contents()->GetBrowserContext()->IsOffTheRecord() &&
        content::MediaSession::GetIfExists(web_contents());
  }
  bool Activate() override {
    if (!IsCurrent(value_.generation)) return false;
    const auto generation = value_.generation;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<Observer> self, uint64_t generation) {
          if (self && self->IsCurrent(generation))
            self->callbacks_.activated(self->page_, generation);
        }, weak_.GetWeakPtr(), generation));
    return true;
  }

 private:
  // Validates at the last dispatch boundary and claims the single request slot.
  content::MediaSession* Begin(uint64_t request, uint64_t generation, uint64_t revision,
                               ArxMediaAction action) {
    Refresh(); // Re-read the synchronous native state at the last dispatch boundary.
    if (!value_.present || generation != value_.generation || revision != revision_) {
      Reply(request, ARX_MEDIA_STALE);
      return nullptr;
    }
    if (request_ != 0) { Reply(request, ARX_MEDIA_BUSY); return nullptr; }
    if (!Supported(action)) { Reply(request, ARX_MEDIA_UNSUPPORTED); return nullptr; }
    auto* session = content::MediaSession::GetIfExists(web_contents());
    if (!session) { Reply(request, ARX_MEDIA_UNAVAILABLE); return nullptr; }
    request_ = request;
    action_ = action;
    request_generation_ = generation;
    timeout_.Start(FROM_HERE, base::Seconds(5),
        base::BindOnce(&Observer::Complete, weak_.GetWeakPtr(), ARX_MEDIA_TIMEOUT));
    return session;
  }
  // The seek landed when the position is at the target, allowing for playback
  // since the seek started.
  bool SeekReached() const {
    auto* session = content::MediaSession::GetIfExists(web_contents());
    auto position = session ? session->GetMediaSessionPosition() : std::nullopt;
    if (!position) return false;
    const double now = position->GetPosition().InSecondsF();
    const double elapsed = (base::TimeTicks::Now() - seek_started_).InSecondsF();
    return now >= seek_target_ - 0.25 &&
        now <= seek_target_ + 0.25 + std::abs(position->playback_rate()) * elapsed;
  }
  static bool IsEntry(ArxMediaAction action) {
    return action == ARX_MEDIA_ENTER_PICTURE || action == ARX_MEDIA_ENTER_AUTOMATIC_PICTURE;
  }
  // ABI54 (DEV-948). Showing in a window of an app that isn't active: the
  // person switched to another app with the call on screen.
  bool IsSourceBehindAnotherApp() const {
    return IsSourceVisible() && !NSApp.active;
  }
  bool IsSourceVisible() const {
    // Read the actual source view at dispatch and again when a site handler
    // returns asynchronously. Focus alone cannot hide a pane or another window.
    if (!web_contents()) return true;
    NSView* view = web_contents()->GetNativeView().GetNativeNSView();
    if (!view) return true;  // Unknown presentation never grants automatic entry.
    NSWindow* window = view.window;
    return window && window.visible && !window.miniaturized &&
        !view.hiddenOrHasHiddenAncestor && !NSIsEmptyRect(view.visibleRect) &&
        (window.occlusionState & NSWindowOcclusionStateVisible);
  }
  void Bind(content::MediaSession* session) {
    receiver_.reset();
    session->AddObserver(receiver_.BindNewPipeAndPassRemote());
  }
  void MediaSessionCreated(content::MediaSession* session) override {
    Invalidate(false);
    Bind(session);
  }
  void OnVisibilityWillChange(content::Visibility) override {
    // PM observes the following visibility change synchronously. Acquire from
    // live media state before it can freeze a source outside its MRU allowance.
    // This never changes visibility or admits an automatic entry.
    Refresh();
  }
  void MediaSessionInfoChanged(media_session::mojom::MediaSessionInfoPtr) override { ScheduleRefresh(); }
  void MediaSessionActionsChanged(const std::vector<SessionAction>&) override { ScheduleRefresh(); }
  void MediaSessionMetadataChanged(const std::optional<media_session::MediaMetadata>& metadata) override {
    if (metadata_ && metadata != metadata_) Invalidate(false);
    metadata_ = metadata;
    ScheduleRefresh();
  }
  // ABI53 (DEV-906): the session's artwork, loaded through the session (the
  // page's own image fetch) and handed over as PNG bytes.
  void MediaSessionImagesChanged(
      const base::flat_map<media_session::mojom::MediaSessionImageType,
                          std::vector<media_session::MediaImage>>& images) override {
    std::optional<media_session::MediaImage> image;
    auto found = images.find(media_session::mojom::MediaSessionImageType::kArtwork);
    if (found != images.end()) {
      media_session::MediaImageManager manager(kArtworkMinimumSize, kArtworkSize);
      image = manager.SelectImage(found->second);
    }
    if (image == artwork_image_) return;
    artwork_image_ = image;
    artwork_.clear();
    ScheduleRefresh();
    auto* session = web_contents() ? content::MediaSession::GetIfExists(web_contents()) : nullptr;
    if (!image || !session) return;
    session->GetMediaImageBitmap(*image, kArtworkMinimumSize, kArtworkSize,
        base::BindOnce(&Observer::ArtworkLoaded, weak_.GetWeakPtr(), *image));
  }
  void ArtworkLoaded(media_session::MediaImage image, const SkBitmap& bitmap) {
    // A newer artwork, or none, replaced this one meanwhile.
    if (artwork_image_ != image || bitmap.drawsNothing()) return;
    SkBitmap converted = bitmap;
    if (bitmap.colorType() != kN32_SkColorType) {
      if (!converted.tryAllocN32Pixels(bitmap.width(), bitmap.height()) ||
          !bitmap.readPixels(converted.pixmap()))
        return;
    }
    auto png = gfx::PNGCodec::EncodeBGRASkBitmap(converted, false);
    if (!png) return;
    artwork_ = std::move(*png);
    ScheduleRefresh();
  }
  void MediaSessionPositionChanged(const std::optional<media_session::MediaPosition>&) override {}
  void MediaStartedPlaying(const MediaPlayerInfo&, const content::MediaPlayerId&) override { awaiting_player_ = false; ScheduleRefresh(); }
  void MediaStoppedPlaying(const MediaPlayerInfo&, const content::MediaPlayerId&,
                           MediaStoppedReason) override { ScheduleRefresh(); }
  void MediaMetadataChanged(const MediaPlayerInfo&, const content::MediaPlayerId&) override { Invalidate(false); }
  // A replaced player (an ad, the next video) keeps the page's PiP: Blink moves
  // it to the new player. If no player takes over, the window would keep a
  // stale frame, so it closes after a short grace period.
  void MediaDestroyed(const content::MediaPlayerId&) override {
    Invalidate(false);
    orphan_timer_.Start(FROM_HERE, base::Seconds(3),
        base::BindOnce(&Observer::CloseOrphanedPicture, weak_.GetWeakPtr(), picture_epoch_));
  }
  void CloseOrphanedPicture(uint64_t picture_epoch) {
    if (picture_epoch != picture_epoch_ || !web_contents()) return;
    auto* session = content::MediaSession::GetIfExists(web_contents());
    auto info = session ? session->GetMediaSessionInfoSync() : nullptr;
    const bool has_player = info && info->audio_video_states && !info->audio_video_states->empty();
    if (!has_player) Exit();
  }
  void MediaPictureInPictureChanged(bool) override { ScheduleRefresh(); }
  // ABI54 (DEV-948). MediaStreamCaptureIndicator::Observer. A call may play
  // nothing through a media player (WebRTC audio, a muted room): its capture
  // stands in for the player a new document otherwise waits for.
  void OnIsCapturingVideoChanged(content::WebContents* contents, bool capturing) override {
    CaptureChanged(contents, capturing);
  }
  void OnIsCapturingAudioChanged(content::WebContents* contents, bool capturing) override {
    CaptureChanged(contents, capturing);
  }
  void CaptureChanged(content::WebContents* contents, bool capturing) {
    if (contents != web_contents()) return;
    if (capturing) awaiting_player_ = false;
    ScheduleRefresh();
  }
  bool IsCapturing() const {
    return capture_indicator_ && web_contents() &&
        (capture_indicator_->IsCapturingVideo(web_contents()) ||
         capture_indicator_->IsCapturingAudio(web_contents()));
  }
  void TitleWasSet(content::NavigationEntry*) override { ScheduleRefresh(); }
  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (navigation->IsInPrimaryMainFrame() && navigation->HasCommitted()) {
      crashed_ = false;
      if (!navigation->IsSameDocument()) {
        // A new document has no player until one starts. A document restored
        // from the back/forward cache brings its players back, paused, without
        // MediaStartedPlaying (MediaSessionImpl re-adds them suspended), so it
        // doesn't wait. Either way old commands go stale (DEV-943).
        const bool restored = navigation->IsServedFromBackForwardCache();
        awaiting_player_ = !restored;
        // Artwork belongs to the document that showed it (DEV-906). A document
        // restored from the cache keeps its metadata, so its artwork stays: the
        // session announces it once, when the restored page's service is routed
        // again, which may come before this navigation finishes (DEV-960).
        if (!restored) {
          artwork_image_.reset();
          artwork_.clear();
        }
        Invalidate(true);
      }
      ScheduleRefresh();
    }
  }
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override {
    crashed_ = true;
    Invalidate(true);
  }
  void Invalidate(bool exit_picture) {
    ++value_.generation;
    // Metadata/session replacement invalidates command authority, but must not
    // briefly remove the only scheduling exemption before fresh facts arrive.
    // A resource-only lease remains bound to this exact PageNode, not the old
    // media generation. Refresh removes it if the replacement is ineligible.
    if (exit_picture) media_runnable_lease_.reset();
    Complete(ARX_MEDIA_STALE);
    if (exit_picture) {
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
          base::BindOnce([](base::WeakPtr<Observer> self, uint64_t picture_epoch) {
            // A new entry on the same page must survive an older teardown task.
            if (self && self->picture_epoch_ == picture_epoch) self->Exit();
          }, weak_.GetWeakPtr(), picture_epoch_));
    }
    ScheduleRefresh();
  }
  bool Supported(ArxMediaAction action) const {
    switch (action) {
      case ARX_MEDIA_PLAY: return value_.actions & ARX_MEDIA_CAN_PLAY;
      case ARX_MEDIA_PAUSE: return value_.actions & ARX_MEDIA_CAN_PAUSE;
      case ARX_MEDIA_ENTER_PICTURE: return value_.actions & ARX_MEDIA_CAN_ENTER_PICTURE;
      case ARX_MEDIA_ENTER_AUTOMATIC_PICTURE:
        // A call also floats while it shows behind another app (DEV-948), as a
        // site's own Document PiP can't be opened on its behalf.
        return (value_.actions & ARX_MEDIA_CAN_ENTER_AUTOMATIC_PICTURE) &&
            (!IsSourceVisible() || (value_.call && IsSourceBehindAnotherApp()));
      case ARX_MEDIA_EXIT_PICTURE: return value_.actions & ARX_MEDIA_CAN_EXIT_PICTURE;
      case ARX_MEDIA_SEEK: return value_.actions & ARX_MEDIA_CAN_SEEK;
      case ARX_MEDIA_NEXT_TRACK: return value_.actions & ARX_MEDIA_CAN_NEXT_TRACK;
      case ARX_MEDIA_PREVIOUS_TRACK: return value_.actions & ARX_MEDIA_CAN_PREVIOUS_TRACK;
      case ARX_MEDIA_TOGGLE_MICROPHONE: return value_.actions & ARX_MEDIA_CAN_TOGGLE_MICROPHONE;
      case ARX_MEDIA_TOGGLE_CAMERA: return value_.actions & ARX_MEDIA_CAN_TOGGLE_CAMERA;
      case ARX_MEDIA_HANG_UP: return value_.actions & ARX_MEDIA_CAN_HANG_UP;
    }
    return false;
  }
  void ScheduleRefresh() {
    if (refresh_posted_) return;
    refresh_posted_ = true;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<Observer> self) {
          if (self) { self->refresh_posted_ = false; self->Refresh(); }
        }, weak_.GetWeakPtr()));
  }
  void Refresh() {
    Value next;
    bool automatic_handler = false;
    next.generation = value_.generation;
    auto* session = content::MediaSession::GetIfExists(web_contents());
    if (session && !crashed_ && !awaiting_player_) {
      auto info = session->GetMediaSessionInfoSync();
      if (info) {
        if (info->audio_video_states) {
          for (auto state : *info->audio_video_states)
            next.video |= state == media_session::mojom::MediaAudioVideoState::kVideoOnly ||
                          state == media_session::mojom::MediaAudioVideoState::kAudioVideo;
        }
        // Document PiP (Google Meet) completes an entry the same way as video.
        next.picture = web_contents()->HasPictureInPictureVideo() ||
                       web_contents()->HasPictureInPictureDocument();
        const auto actions = session->GetMediaSessionActionsSync();
        auto has = [&actions](SessionAction action) { return std::ranges::contains(actions, action); };
        // ABI54 (DEV-948). A call captures the camera or microphone and offers
        // a call action or automatic PiP, as Chrome's video-conferencing
        // automatic PiP requires. It needs no playing player.
        next.call = IsCapturing() &&
            (has(SessionAction::kToggleMicrophone) || has(SessionAction::kToggleCamera) ||
             has(SessionAction::kHangUp) || has(SessionAction::kEnterAutoPictureInPicture));
        next.present = info->is_controllable || next.video || next.picture || next.call;
        if (next.present) {
          next.playback = (next.call ||
              info->playback_state == media_session::mojom::MediaPlaybackState::kPlaying) ? 1 : 2;
          automatic_handler = has(SessionAction::kEnterAutoPictureInPicture);
          if (next.playback == 2 && has(SessionAction::kPlay)) next.actions |= ARX_MEDIA_CAN_PLAY;
          if (next.playback == 1 && has(SessionAction::kPause)) next.actions |= ARX_MEDIA_CAN_PAUSE;
          if (!entry_quarantined_ && next.video && !next.picture && next.playback == 1 && has(SessionAction::kEnterPictureInPicture))
            next.actions |= ARX_MEDIA_CAN_ENTER_PICTURE;
          // Only the separately advertised automatic route may grant the
          // renderer's scoped PiP token. Never fall back to manual activation.
          if (!entry_quarantined_ && next.video && !next.picture && next.playback == 1 && has(SessionAction::kEnterAutoPictureInPicture))
            next.actions |= ARX_MEDIA_CAN_ENTER_AUTOMATIC_PICTURE;
          if (next.picture) next.actions |= ARX_MEDIA_CAN_EXIT_PICTURE;
          // The session offers seeking for controllable media that isn't live.
          if (has(SessionAction::kSeekTo)) next.actions |= ARX_MEDIA_CAN_SEEK;
          if (has(SessionAction::kNextTrack)) next.actions |= ARX_MEDIA_CAN_NEXT_TRACK;
          if (has(SessionAction::kPreviousTrack)) next.actions |= ARX_MEDIA_CAN_PREVIOUS_TRACK;
          // ABI54 (DEV-948). A call floats on its own through the site's
          // handler (Meet opens its Document PiP), without a playing video.
          if (!entry_quarantined_ && next.call && !next.picture &&
              has(SessionAction::kEnterAutoPictureInPicture))
            next.actions |= ARX_MEDIA_CAN_ENTER_AUTOMATIC_PICTURE;
          if (has(SessionAction::kToggleMicrophone)) next.actions |= ARX_MEDIA_CAN_TOGGLE_MICROPHONE;
          if (has(SessionAction::kToggleCamera)) next.actions |= ARX_MEDIA_CAN_TOGGLE_CAMERA;
          if (has(SessionAction::kHangUp)) next.actions |= ARX_MEDIA_CAN_HANG_UP;
          next.microphone =
              info->microphone_state == media_session::mojom::MicrophoneState::kUnmuted
                  ? ARX_MEDIA_DEVICE_ON
              : info->microphone_state == media_session::mojom::MicrophoneState::kMuted
                  ? ARX_MEDIA_DEVICE_OFF : ARX_MEDIA_DEVICE_UNKNOWN;
          next.camera =
              info->camera_state == media_session::mojom::CameraState::kTurnedOn
                  ? ARX_MEDIA_DEVICE_ON
              : info->camera_state == media_session::mojom::CameraState::kTurnedOff
                  ? ARX_MEDIA_DEVICE_OFF : ARX_MEDIA_DEVICE_UNKNOWN;
          const auto& metadata = session->GetMediaSessionMetadata();
          auto title = metadata.title;
          if (title.empty()) title = web_contents()->GetTitle();
          next.title = base::UTF16ToUTF8(title.substr(0, 512));
          next.artist = base::UTF16ToUTF8(metadata.artist.substr(0, 512));
          next.artwork = artwork_;
          const auto origin = url::Origin::Create(web_contents()->GetLastCommittedURL());
          if (!origin.opaque()) next.origin = origin.Serialize();
        }
      }
    }
    UpdateMediaRunnableLease(next, automatic_handler);
    if (revision_ == 0 || next != published_) {
      value_ = next;
      published_ = next;
      ++revision_;
      // Copy strings into the posted closure; Swift may destroy this observer in its callback.
      ArxMediaSnapshot snapshot = {value_.generation, revision_, value_.present, value_.video,
          value_.picture, value_.playback, value_.actions, nullptr, nullptr, nullptr, nullptr, 0,
          value_.call, value_.microphone, value_.camera};
      PostChanged(snapshot, value_.title, value_.origin, value_.artist, value_.artwork);
    } else { value_ = next; }
    if (request_ && request_generation_ == value_.generation) {
      bool completed = action_ == ARX_MEDIA_PLAY ? value_.playback == 1 :
          action_ == ARX_MEDIA_PAUSE ? value_.playback == 2 :
          action_ == ARX_MEDIA_SEEK ? SeekReached() :
          IsEntry(action_) ? value_.picture : !value_.picture;
      if (completed && value_.present) Complete(ARX_MEDIA_SUCCESS);
    }
  }
  void UpdateMediaRunnableLease(const Value& next, bool automatic_handler) {
    const MediaRunnableFacts facts = {
        .ordinary = web_contents() &&
                    !web_contents()->GetBrowserContext()->IsOffTheRecord(),
        .valid_source = next.present && !crashed_ && !awaiting_player_ &&
                        !entry_quarantined_,
        .video = next.video,
        .playing = next.playback == 1,
        .automatic_handler = automatic_handler,
        .picture = next.picture,
        .pending_automatic_entry = request_ &&
            action_ == ARX_MEDIA_ENTER_AUTOMATIC_PICTURE &&
            request_generation_ == next.generation,
    };
    if (NeedsMediaRunnableLease(facts)) {
      if (!media_runnable_lease_) {
        media_runnable_lease_ = std::make_unique<
            performance_manager::freezing::ScopedMediaRunnableLease>(
                web_contents());
      }
    } else {
      media_runnable_lease_.reset();
    }
  }
  void PostChanged(ArxMediaSnapshot snapshot, std::string title = {}, std::string origin = {},
                   std::string artist = {}, std::vector<uint8_t> artwork = {}) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](MediaCallbacks callbacks, uint64_t page, ArxMediaSnapshot snapshot,
                          std::string title, std::string origin, std::string artist,
                          std::vector<uint8_t> artwork) {
          snapshot.title = title.c_str();
          snapshot.origin = origin.c_str();
          snapshot.artist = artist.c_str();
          snapshot.artwork = artwork.empty() ? nullptr : artwork.data();
          snapshot.artwork_size = artwork.size();
          callbacks.changed(page, &snapshot);
        }, callbacks_, page_, snapshot, std::move(title), std::move(origin), std::move(artist),
           std::move(artwork)));
  }
  void Reply(uint64_t request, ArxMediaStatus status) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(callbacks_.completed, request, page_, status));
  }
  void Complete(ArxMediaStatus status) {
    if (!request_) return;
    const auto request = std::exchange(request_, 0);
    timeout_.Stop();
    seek_poll_.Stop();
    if (status == ARX_MEDIA_SUCCESS && IsEntry(action_)) {
      // The synchronous WebContents PiP notification already installed PM's
      // actual-PiP reason. Drop the candidate lease without a freeze gap.
      media_runnable_lease_.reset();
    }
    if (IsEntry(action_) && status != ARX_MEDIA_SUCCESS) {
      // Website handlers carry no request ID into Enter(). A late handler must
      // never borrow a newer request's authority, including after BFCache restore.
      // Keep this page quarantined until its native session is recreated.
      entry_quarantined_ = true;
      media_runnable_lease_.reset();
      ScheduleRefresh();
    }
    Reply(request, status);
  }
  uint64_t page_, revision_ = 0, request_ = 0, request_generation_ = 0, picture_epoch_ = 0;
  MediaCallbacks callbacks_;
  Value value_, published_;
  ArxMediaAction action_ = ARX_MEDIA_PLAY;
  bool crashed_ = false, awaiting_player_ = false, refresh_posted_ = false;
  bool entry_quarantined_ = false;
  std::unique_ptr<performance_manager::freezing::ScopedMediaRunnableLease>
      media_runnable_lease_;
  std::optional<media_session::MediaMetadata> metadata_;
  // ABI53 (DEV-906): the artwork asked for, and its PNG bytes once loaded.
  std::optional<media_session::MediaImage> artwork_image_;
  std::vector<uint8_t> artwork_;
  scoped_refptr<MediaStreamCaptureIndicator> capture_indicator_;
  mojo::Receiver<media_session::mojom::MediaSessionObserver> receiver_{this};
  base::OneShotTimer timeout_;
  base::OneShotTimer orphan_timer_;
  base::RepeatingTimer seek_poll_;
  base::TimeTicks seek_started_;
  double seek_target_ = 0;
  base::WeakPtrFactory<Observer> weak_{this};
};
}

std::unique_ptr<MediaBridge> ObserveMedia(uint64_t page, content::WebContents* contents, MediaCallbacks callbacks) {
  if (!contents || contents->GetBrowserContext()->IsOffTheRecord()) return nullptr;
  return std::make_unique<Observer>(page, contents, callbacks);
}
}
