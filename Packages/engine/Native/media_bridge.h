#ifndef ARX_MEDIA_BRIDGE_H
#define ARX_MEDIA_BRIDGE_H

#include <memory>
#include "chrome/browser/arx/ChromiumBridge.h"
#include "content/public/browser/web_contents_delegate.h"

namespace content { class WebContents; }
namespace arx {

// One explicitly enabled observer per ordinary page. No player or media stream is created.
class MediaBridge {
 public:
  virtual ~MediaBridge() = default;
  virtual void Perform(uint64_t request, uint64_t generation, uint64_t revision,
                       ArxMediaAction action) = 0;
  // ABI32: an absolute seek through the media session, and one on-demand read.
  virtual void Seek(uint64_t request, uint64_t generation, uint64_t revision,
                    double seconds) = 0;
  virtual void Position(ArxMediaPosition* position) const = 0;
  virtual void Cancel(uint64_t request) = 0;
  virtual content::PictureInPictureResult Enter() = 0;
  virtual void Exit() = 0;
  virtual bool Activate() = 0;
  virtual bool IsCurrent(uint64_t generation) const = 0;
};

struct MediaCallbacks {
  void (*changed)(uint64_t, const ArxMediaSnapshot*);
  void (*completed)(uint64_t, uint64_t, ArxMediaStatus);
  void (*activated)(uint64_t, uint64_t);
};
std::unique_ptr<MediaBridge> ObserveMedia(uint64_t page, content::WebContents*, MediaCallbacks);
}
#endif
