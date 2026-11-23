#ifndef ARX_POPUP_HOST_H
#define ARX_POPUP_HOST_H

#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>
#include "base/functional/callback.h"

namespace content { class WebContents; }
namespace arx {

// Owned by one Page. The native indicator travels with its actual page view;
// menu actions revalidate the Page's captured document before opening anything.
class PopupHost {
 public:
  using Entries = std::vector<std::pair<int32_t, std::string>>;
  PopupHost(content::WebContents* contents,
            base::RepeatingCallback<void(int32_t)> blocked,
            base::RepeatingCallback<Entries()> entries,
            base::RepeatingCallback<void(int32_t)> open);
  ~PopupHost();
  void Refresh();

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};
}  // namespace arx
#endif
