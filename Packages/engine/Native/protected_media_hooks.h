#ifndef ARX_PROTECTED_MEDIA_HOOKS_H_
#define ARX_PROTECTED_MEDIA_HOOKS_H_

// DEV-877. Dependency-free so content's KeySystemSupportImpl can include it;
// the setter is defined next to its call site by protected_media_overlay.py.
namespace content { class RenderFrameHost; }

namespace arx {
// Why a document's protected media is reported (DEV-1211).
enum class ProtectedMediaReason {
  // The page can't play its protected media: a media element wants keys Arx
  // can't give it, or (with media::kArxWidevineAnswer on) every protected key
  // system the document asked for was refused.
  kPlaybackFailed = 0,
  // Keys couldn't be created, or (with the answer off) a request was refused,
  // and no media element wants keys yet. A bot check may do this; so may a
  // streaming site's player, which stops before it loads media.
  kKeysWithoutMedia = 1,
};

// Called on the UI thread, at most once per reason and document (each failed
// key creation reports again), and otherwise never after kPlaybackFailed: the
// document's KeySystemSupportImpl decides
// (protected_media_overlay.py). Arx has no Widevine module, so protected media
// fails. Must not block or reenter the frame: post anything else.
using ProtectedMediaObserver = void (*)(content::RenderFrameHost* frame,
                                        ProtectedMediaReason reason);
void SetProtectedMediaObserver(ProtectedMediaObserver observer);

// DEV-1144: content's MediaInterfaceProxy found no CDM for a key system a page
// was granted (Widevine answered without a CDM). Recorded on the frame's
// document, which reports it (DEV-1211).
void ReportProtectedMediaFailure(content::RenderFrameHost* frame);
}  // namespace arx

#endif  // ARX_PROTECTED_MEDIA_HOOKS_H_
