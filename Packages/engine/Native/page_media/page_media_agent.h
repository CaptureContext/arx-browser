#ifndef ARX_PAGE_MEDIA_PAGE_MEDIA_AGENT_H_
#define ARX_PAGE_MEDIA_PAGE_MEDIA_AGENT_H_

#include <cstddef>
#include <optional>
#include <string>

#include "base/memory/weak_ptr.h"
#include "components/arx_page_media/page_media.mojom.h"
#include "content/public/renderer/render_frame_observer.h"
#include "content/public/renderer/render_frame_observer_tracker.h"
#include "mojo/public/cpp/bindings/associated_receiver.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "v8/include/v8-forward.h"
#include "v8/include/v8-persistent-handle.h"

namespace gin {
class Arguments;
}  // namespace gin

namespace arx::page_media {

// The longest message either side passes on: a FairPlay playlist in parts,
// a certificate or a licence is far smaller.
inline constexpr size_t kMaximumMessageBytes = 4 * 1024 * 1024;

// The longest script the browser prepares.
inline constexpr size_t kMaximumScriptBytes = 1024 * 1024;

// DEV-1144. One per outermost main frame, created with the frame. Runs the
// script the browser prepared for the next document of a bridged origin in its
// main world at document start, where extensions run their document_start
// scripts, and carries its messages. The script's `send` is a closure
// argument, so no global of the page's sees it.
class PageMediaAgent final
    : public content::RenderFrameObserver,
      public content::RenderFrameObserverTracker<PageMediaAgent>,
      public mojom::PageMediaAgent {
 public:
  explicit PageMediaAgent(content::RenderFrame* frame);
  ~PageMediaAgent() override;

  // ChromeContentRendererClient::RunScriptsAtDocumentStart, where script may
  // run (DidCreateDocumentElement runs inside a ScriptForbiddenScope): runs the
  // script DidCreateDocumentElement chose for the frame's new document.
  static void RunAtDocumentStart(content::RenderFrame* frame);

  // mojom::PageMediaAgent
  void Prepare(const std::string& origin, const std::string& script) override;
  void Deliver(const std::string& message) override;

  // content::RenderFrameObserver
  void DidCreateDocumentElement() override;
  void OnDestruct() override;

 private:
  struct Prepared {
    std::string origin;
    std::string script;
  };

  void Bind(mojo::PendingAssociatedReceiver<mojom::PageMediaAgent> receiver);
  void Run(const std::string& script);
  void Send(std::string message);
  static void SendFromPage(base::WeakPtr<PageMediaAgent> agent, gin::Arguments* arguments);

  mojo::AssociatedReceiver<mojom::PageMediaAgent> receiver_{this};
  mojo::AssociatedRemote<mojom::PageMediaHost> host_;
  std::optional<Prepared> prepared_;
  // The script for the document whose element was just created, run at
  // document start.
  std::string pending_script_;
  // The running script's context, set as it starts so it can send while it sets
  // itself up, and its receive function, both of the frame's current document;
  // reset when another document runs or none does.
  v8::Global<v8::Context> context_;
  v8::Global<v8::Function> receive_;
  base::WeakPtrFactory<PageMediaAgent> weak_factory_{this};
};

}  // namespace arx::page_media

#endif  // ARX_PAGE_MEDIA_PAGE_MEDIA_AGENT_H_
