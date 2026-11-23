#ifndef ARX_FILE_CHOOSER_BRIDGE_H
#define ARX_FILE_CHOOSER_BRIDGE_H

#include "base/memory/scoped_refptr.h"
#include "chrome/browser/arx/ChromiumBridge.h"
#include "third_party/blink/public/mojom/choosers/file_chooser.mojom-forward.h"

namespace base {
class FilePath;
}  // namespace base

namespace content {
class FileSelectListener;
class RenderFrameHost;
class WebContents;
}  // namespace content

namespace arx {
// ABI30. An automation pointer or keyboard action arms its page for a short
// window; a single or multiple file chooser the page opens in that window is
// held for the app instead of being cancelled, and any other chooser opened in
// that window is cancelled.
//
// DEV-1309. A chooser the page opens outside that window comes from a person's
// own input (Blink opens none without user activation). With `shows_panel`
// (an interactive run) it gets Chrome's own file dialog, FileSelectHelper:
// the macOS open or save panel on the page's window, for every mode (one or
// several files, a folder, a save). Without it (an unattended run) it is
// cancelled, as before. UI thread only.
void ArmFileChooser(uint64_t page);
void HandleFileChooser(uint64_t page, bool shows_panel, content::RenderFrameHost* frame,
                       scoped_refptr<content::FileSelectListener> listener,
                       const blink::mojom::FileChooserParams& params);
// DEV-1309. Lists a folder a person chose or dropped, for `webkitdirectory`
// inputs and dropped folders, as Chrome does; an unattended run cancels it.
void EnumerateFileChooserDirectory(bool shows_panel, content::WebContents* contents,
                                   scoped_refptr<content::FileSelectListener> listener,
                                   const base::FilePath& path);
bool PageFileChooser(uint64_t page, ArxFileChooserInfo* info);
ArxFileChooserStatus AnswerFileChooser(uint64_t page, uint64_t token,
                                       const char* const* paths, size_t count);
// Cancels a held chooser of a page that navigates, closes or is destroyed.
void ForgetFileChooser(uint64_t page);
void StopFileChoosers();
}  // namespace arx

#endif
