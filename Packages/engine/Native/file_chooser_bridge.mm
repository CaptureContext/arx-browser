#include "chrome/browser/arx/file_chooser_bridge.h"

#include <map>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/no_destructor.h"
#include "base/rand_util.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "chrome/browser/file_select_helper.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/file_select_listener.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/weak_document_ptr.h"
#include "third_party/blink/public/mojom/choosers/file_chooser.mojom.h"

namespace arx {
namespace {
// How long after an automation action admits input its page may open a chooser.
constexpr base::TimeDelta kArmedWindow = base::Seconds(3);
// An unanswered chooser is cancelled after this long.
constexpr base::TimeDelta kHeldLifetime = base::Seconds(60);
constexpr size_t kMaximumPaths = 32;
constexpr size_t kMaximumPathBytes = 4096;
constexpr size_t kMaximumAcceptBytes = 1024;

struct Held {
  uint64_t token = 0;
  bool multiple = false;
  std::string accept;
  scoped_refptr<content::FileSelectListener> listener;
  content::WeakDocumentPtr document;
  std::unique_ptr<base::OneShotTimer> expiry;
};

std::map<uint64_t, base::TimeTicks>& Armed() {
  static base::NoDestructor<std::map<uint64_t, base::TimeTicks>> armed;
  return *armed;
}

std::map<uint64_t, Held>& Choosers() {
  static base::NoDestructor<std::map<uint64_t, Held>> choosers;
  return *choosers;
}

void Cancel(uint64_t page) {
  auto found = Choosers().find(page);
  if (found == Choosers().end()) return;
  auto listener = std::move(found->second.listener);
  Choosers().erase(found);
  if (listener) listener->FileSelectionCanceled();
}
}  // namespace

void ArmFileChooser(uint64_t page) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  Armed()[page] = base::TimeTicks::Now() + kArmedWindow;
}

void HandleFileChooser(uint64_t page, bool shows_panel, content::RenderFrameHost* frame,
                       scoped_refptr<content::FileSelectListener> listener,
                       const blink::mojom::FileChooserParams& params) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  const auto armed = Armed().find(page);
  const bool admitted = armed != Armed().end() && armed->second >= base::TimeTicks::Now();
  if (!admitted) {
    // A person's own click, key or drop opened it. Before DEV-1309 this was
    // cancelled too, so no file input or upload button worked in Arx.
    if (shows_panel && frame) {
      FileSelectHelper::RunFileChooser(frame, std::move(listener), params);
    } else {
      listener->FileSelectionCanceled();
    }
    return;
  }
  const bool supported = params.mode == blink::mojom::FileChooserParams::Mode::kOpen ||
      params.mode == blink::mojom::FileChooserParams::Mode::kOpenMultiple;
  if (!supported || !frame || Choosers().contains(page)) {
    listener->FileSelectionCanceled();
    return;
  }
  Armed().erase(page);
  std::string accept;
  for (const auto& type : params.accept_types) {
    const auto value = base::UTF16ToUTF8(type);
    if (accept.size() + value.size() + 1 > kMaximumAcceptBytes) break;
    if (!accept.empty()) accept += ",";
    accept += value;
  }
  auto& held = Choosers()[page];
  held.token = base::RandUint64() | 1;
  held.multiple = params.mode == blink::mojom::FileChooserParams::Mode::kOpenMultiple;
  held.accept = std::move(accept);
  held.listener = std::move(listener);
  held.document = frame->GetWeakDocumentPtr();
  held.expiry = std::make_unique<base::OneShotTimer>();
  held.expiry->Start(FROM_HERE, kHeldLifetime, base::BindOnce(&Cancel, page));
}

void EnumerateFileChooserDirectory(bool shows_panel, content::WebContents* contents,
                                   scoped_refptr<content::FileSelectListener> listener,
                                   const base::FilePath& path) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!shows_panel || !contents) {
    listener->FileSelectionCanceled();
    return;
  }
  FileSelectHelper::EnumerateDirectory(contents, std::move(listener), path);
}

bool PageFileChooser(uint64_t page, ArxFileChooserInfo* info) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto found = Choosers().find(page);
  if (!info || found == Choosers().end()) return false;
  if (!found->second.document.AsRenderFrameHostIfValid()) {
    Cancel(page);
    return false;
  }
  *info = {found->second.token, found->second.multiple, found->second.accept.c_str()};
  return true;
}

ArxFileChooserStatus AnswerFileChooser(uint64_t page, uint64_t token,
                                       const char* const* paths, size_t count) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto found = Choosers().find(page);
  if (found == Choosers().end() || found->second.token != token ||
      !found->second.document.AsRenderFrameHostIfValid())
    return ARX_FILE_CHOOSER_STALE;
  if (!count) {
    Cancel(page);
    return ARX_FILE_CHOOSER_OK;
  }
  if (count > kMaximumPaths || (count > 1 && !found->second.multiple) || !paths)
    return ARX_FILE_CHOOSER_INVALID;
  // The app checked each file and the user approved each path. Only the path
  // syntax is rechecked here; the UI thread does no file IO.
  std::vector<blink::mojom::FileChooserFileInfoPtr> files;
  for (size_t i = 0; i < count; ++i) {
    if (!paths[i]) return ARX_FILE_CHOOSER_INVALID;
    const std::string text(paths[i]);
    const base::FilePath path(text);
    if (text.empty() || text.size() > kMaximumPathBytes || !base::IsStringUTF8(text) ||
        !path.IsAbsolute() || path.ReferencesParent())
      return ARX_FILE_CHOOSER_INVALID;
    files.push_back(blink::mojom::FileChooserFileInfo::NewNativeFile(
        blink::mojom::NativeFileInfo::New(path, path.BaseName().AsUTF16Unsafe(),
                                          std::vector<std::u16string>())));
  }
  const auto mode = found->second.multiple ? blink::mojom::FileChooserParams::Mode::kOpenMultiple
                                           : blink::mojom::FileChooserParams::Mode::kOpen;
  auto listener = std::move(found->second.listener);
  Choosers().erase(found);
  listener->FileSelected(std::move(files), base::FilePath(), mode);
  return ARX_FILE_CHOOSER_OK;
}

void ForgetFileChooser(uint64_t page) {
  Armed().erase(page);
  Cancel(page);
}

void StopFileChoosers() {
  Armed().clear();
  std::vector<uint64_t> pages;
  for (const auto& [page, held] : Choosers()) pages.push_back(page);
  for (const auto page : pages) Cancel(page);
}
}  // namespace arx
