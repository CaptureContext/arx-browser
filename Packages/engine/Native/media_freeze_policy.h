#ifndef CHROME_BROWSER_ARX_MEDIA_FREEZE_POLICY_H_
#define CHROME_BROWSER_ARX_MEDIA_FREEZE_POLICY_H_

namespace arx {

// Resource scheduling only. Entry authorization remains in MediaBridge and
// Swift's exact-origin opt-in. The native observer does not know that opt-in.
struct MediaRunnableFacts {
  bool ordinary = false;
  bool valid_source = false;
  bool video = false;
  bool playing = false;
  bool automatic_handler = false;
  bool picture = false;
  bool pending_automatic_entry = false;
};

inline bool NeedsMediaRunnableLease(const MediaRunnableFacts& facts) {
  return facts.ordinary && facts.valid_source && facts.video && facts.playing &&
         facts.automatic_handler &&
         (!facts.picture || facts.pending_automatic_entry);
}

}  // namespace arx

#endif  // CHROME_BROWSER_ARX_MEDIA_FREEZE_POLICY_H_
