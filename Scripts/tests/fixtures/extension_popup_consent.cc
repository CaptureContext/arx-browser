#include "consent_authority.h"
#include <cassert>
#include <functional>
#include <memory>
#include <utility>

struct WebContents {};
struct ProtocolObserver {};
struct GURL {};
namespace content { struct BrowserContext {}; }
namespace base {
template<typename T> class RepeatingCallback {
 public:
  RepeatingCallback(std::function<T> callback) : callback_(std::move(callback)) {}
  bool Run() { return callback_(); }
 private:
  std::function<T> callback_;
};
}
namespace web_modal {
struct WebContentsModalDialogManager {
  static inline WebContentsModalDialogManager* current;
  static WebContentsModalDialogManager* FromWebContents(WebContents*) { return current; }
  void SetDelegate(void* owner) { delegate=owner; }
  void* delegate=nullptr;
};
}
class ConsentHost {
 public:
  WebContents* web_contents() { return &contents; }
  void RemoveAttachmentObserver() { assert(!authority_.enabled() && !protocol_observer_); }
  void InvalidateDecisions() { assert(!authority_.enabled()); ++invalidations; }
  // CONFIGURE_PREFIX
    // The remaining production body allocates/removes AppKit attachment views.
    // Its enabled branch publishes this same authority only after attachment.
    authority_.Configure(enabled);
  }
  // SHUTDOWN
  std::unique_ptr<ProtocolObserver> protocol_observer_;
  arx::ConsentAuthority authority_;
  int invalidations=0;
  WebContents contents;
};
ConsentHost* consent;
void ConfigurePageConsentHosting(WebContents*,bool enabled) { consent->Configure(enabled); }
namespace extensions {
struct Extension {};
namespace mojom { enum class ViewType { kExtensionPopup }; }
struct ChromeModalHandler {
  ChromeModalHandler() { web_modal::WebContentsModalDialogManager::current->SetDelegate(this); }
  ~ChromeModalHandler() { web_modal::WebContentsModalDialogManager::current->SetDelegate(nullptr); }
};
class ExtensionViewHost {
 public:
  struct Delegate { virtual ~Delegate()=default; };
  ExtensionViewHost(const Extension*,content::BrowserContext*,const GURL&,mojom::ViewType,
      std::unique_ptr<Delegate>) {}
  virtual ~ExtensionViewHost()=default;
  virtual void LoadInitialURL() {
    ++loads;
    if (deferred) return;
    // Chrome's production handler constructor installs itself. Replacing it
    // subsequently destroys the old handler, which clears that same manager.
    modal=std::make_unique<ChromeModalHandler>();
    if (during_load) during_load();
  }
  WebContents* host_contents() { return &contents; }
  bool deferred=false;
  int loads=0;
  std::function<void()> during_load;
 private:
  WebContents contents;
  std::unique_ptr<ChromeModalHandler> modal;
};
}
// HOST_SUBCLASS
int main() {
  web_modal::WebContentsModalDialogManager manager;
  web_modal::WebContentsModalDialogManager::current=&manager;
  auto helper=std::make_unique<ConsentHost>();
  consent=helper.get();
  helper->protocol_observer_=std::make_unique<ProtocolObserver>();
  helper->Configure(true);
  assert(!helper->protocol_observer_);
  const auto initial=helper->authority_.generation();
  assert(manager.delegate==helper.get());
  bool source_current=true;
  auto host=std::make_unique<ConsentExtensionViewHost>(nullptr,nullptr,GURL{},
      std::make_unique<extensions::ExtensionViewHost::Delegate>(),
      base::RepeatingCallback<bool()>([&] { return source_current; }));
  host->deferred=true;
  host->LoadInitialURL();
  assert(manager.delegate==helper.get());
  assert(!helper->authority_.Current(initial));
  host->deferred=false;
  host->LoadInitialURL();
  assert(manager.delegate==helper.get());
  const auto loaded=helper->authority_.generation();
  host->LoadInitialURL(); // old Chrome handler destructor cannot clobber new Arx binding
  assert(manager.delegate==helper.get());
  assert(!helper->authority_.Current(loaded));
  host->during_load=[&] { source_current=false; };
  host->LoadInitialURL();
  assert(manager.delegate==helper.get()); // retained helper exists but must deny
  assert(!helper->authority_.enabled());
  const int loads=host->loads;
  host->LoadInitialURL(); // a late background-ready callback cannot start stale renderer work
  assert(host->loads==loads);
  assert(manager.delegate==helper.get() && !helper->authority_.enabled());
  helper->ShutDown();
  assert(!manager.delegate);
  helper.reset(); // no manager pointer remains to freed helper memory
  consent=nullptr;
  host.reset(); // Chrome handler may safely clear the still-live manager afterward
  assert(!manager.delegate);
}
