"""Per-contents consent UI and source-bound external handoff guards.

Empty guards preserve upstream Chrome behavior. Arx installs a nonempty guard,
including when disabled, so no source can fall through into unrelated UI.
"""

from .overlay import replace_once


def _patches():
    # Browser-owned distinction: initial-empty alone remains true after the
    # synchronous bootstrap. No renderer properties or URL-only exemption.
    navigation = "content/public/browser/navigation_handle.h"
    yield navigation, "  virtual bool IsNavigatingFromInitialEmptyDocument() const = 0;", """  virtual bool IsNavigatingFromInitialEmptyDocument() const = 0;

  // True only for the synchronous initial about:blank creation commit. This
  // identifies bootstrap ordering; it grants no gesture or protocol authority.
  virtual bool IsInitialSynchronousAboutBlankForEmbedding() { return false; }"""
    request = "content/browser/renderer_host/navigation_request"
    yield request + ".h", "  bool IsNavigatingFromInitialEmptyDocument() const override;", """  bool IsNavigatingFromInitialEmptyDocument() const override;
  bool IsInitialSynchronousAboutBlankForEmbedding() override;"""
    yield request + ".cc", "bool NavigationRequest::IsNavigatingFromInitialEmptyDocument() const {", """bool NavigationRequest::IsInitialSynchronousAboutBlankForEmbedding() {
  return is_synchronous_renderer_commit_ && IsRendererInitiated() &&
         IsInPrimaryMainFrame() && !IsSameDocument() &&
         IsNavigatingFromInitialEmptyDocument() &&
         GetURL() == GURL(url::kAboutBlankURL);
}

bool NavigationRequest::IsNavigatingFromInitialEmptyDocument() const {"""
    delegate = "components/web_modal/web_contents_modal_dialog_manager_delegate"
    yield delegate + ".h", '#include "components/web_modal/web_modal_export.h"', '''#include "components/web_modal/web_modal_export.h"
#include "base/functional/callback.h"
#include "content/public/browser/weak_document_ptr.h"'''
    yield delegate + ".h", "  // Returns whether the WebContents is currently visible or not.", '''  // Embedders may bind asynchronous external handoffs to exact source
  // document/host authority. An empty guard retains ordinary Chrome behavior.
  virtual base::RepeatingCallback<bool()> GetDialogDecisionGuard(
      content::WebContents*, content::WeakDocumentPtr);

  // Returns whether the WebContents is currently visible or not.'''
    yield delegate + ".cc", "bool WebContentsModalDialogManagerDelegate::IsWebContentsVisible(", '''base::RepeatingCallback<bool()>
WebContentsModalDialogManagerDelegate::GetDialogDecisionGuard(
    content::WebContents*, content::WeakDocumentPtr) {
  return {};
}

bool WebContentsModalDialogManagerDelegate::IsWebContentsVisible('''
    yield "components/permissions/permission_request_manager.h", "  void set_view_factory_for_testing(PermissionPrompt::Factory view_factory) {", '''  // A per-WebContents embedder supplies UI without a Chrome Browser window.
  void SetPromptFactoryForEmbedding(PermissionPrompt::Factory view_factory) {
    CHECK(!view_);
    view_factory_ = std::move(view_factory);
  }

  void set_view_factory_for_testing(PermissionPrompt::Factory view_factory) {'''
    handler = "chrome/browser/external_protocol/external_protocol_handler.cc"
    yield handler, '#include "components/web_modal/web_contents_modal_dialog_manager.h"', '''#include "components/web_modal/web_contents_modal_dialog_manager.h"
#include "components/web_modal/web_contents_modal_dialog_manager_delegate.h"'''
    launch = '''void LaunchUrlWithoutSecurityCheckWithDelegate(
    const GURL& url,
    content::WebContents* web_contents,
    content::WeakDocumentPtr initiator_document,
    ExternalProtocolHandler::Delegate* delegate) {'''
    yield handler, launch, '''bool EmbeddedExternalSourceCurrent(content::WebContents* contents,
                                   content::WeakDocumentPtr initiator) {
  auto* manager = contents
      ? web_modal::WebContentsModalDialogManager::FromWebContents(contents) : nullptr;
  if (!manager || !manager->delegate()) return true;
  auto guard = manager->delegate()->GetDialogDecisionGuard(contents, initiator);
  return !guard || guard.Run();
}

''' + launch + '''
  // Enterprise policy and other direct callers can bypass LaunchUrl's worker.
  // They still require the embedding source at this final synchronous boundary.
  if (!EmbeddedExternalSourceCurrent(web_contents, initiator_document)) return;'''
    yield handler, "    ExternalProtocolHandler::Delegate* delegate,\n    shell_integration::DefaultWebClientState state,", "    ExternalProtocolHandler::Delegate* delegate,\n    base::RepeatingCallback<bool()> source_guard,\n    shell_integration::DefaultWebClientState state,"
    yield handler, "  content::WebContents* web_contents = web_contents_getter.Run();\n\n  // The default handler", "  content::WebContents* web_contents = web_contents_getter.Run();\n  if (source_guard && !source_guard.Run()) return;\n\n  // The default handler"
    yield handler, "  // The worker creates tasks with references to itself and puts them into", '''  base::RepeatingCallback<bool()> source_guard;
  if (web_contents) {
    auto* manager = web_modal::WebContentsModalDialogManager::FromWebContents(
        web_contents);
    if (manager && manager->delegate()) {
      source_guard = manager->delegate()->GetDialogDecisionGuard(
          web_contents, initiator_document);
    }
  }
  if (source_guard && !source_guard.Run()) return;

  // The worker creates tasks with references to itself and puts them into'''
    yield handler, "                     g_external_protocol_handler_delegate);\n\n  // Start the check", "                     g_external_protocol_handler_delegate, std::move(source_guard));\n\n  // Start the check"
    dialog = "chrome/browser/ui/views/external_protocol_dialog"
    yield dialog + ".h", '#include "base/memory/raw_ptr.h"', '#include "base/memory/raw_ptr.h"\n#include "base/functional/callback.h"'
    yield dialog + ".h", "  const GURL url_;", "  base::RepeatingCallback<bool()> source_guard_;\n  const GURL url_;"
    yield dialog + ".cc", '#include "components/prefs/pref_service.h"', '''#include "components/prefs/pref_service.h"
#include "components/web_modal/web_contents_modal_dialog_manager.h"
#include "components/web_modal/web_contents_modal_dialog_manager_delegate.h"'''
    yield dialog + ".cc", "      initiator_document_(std::move(initiator_document)) {", '''      initiator_document_(std::move(initiator_document)) {
  auto* manager = web_modal::WebContentsModalDialogManager::FromWebContents(web_contents);
  if (manager && manager->delegate()) {
    source_guard_ = manager->delegate()->GetDialogDecisionGuard(
        web_contents, initiator_document_);
  }'''
    yield dialog + ".cc", "void ExternalProtocolDialog::OnDialogAccepted() {", '''void ExternalProtocolDialog::OnDialogAccepted() {
  // Check before metrics, remembered consent, or OS launch. The weak document
  // alone is insufficient: a navigation may have started without committing.
  if (source_guard_ && !source_guard_.Run()) return;'''
    # Physical child ownership follows the real protocol operation, including
    # blocked requests, synchronous delegates, async lookup and dialog lifetime.
    yield delegate + ".h", "  // Returns whether the WebContents is currently visible or not.", '''  // Optional exact-operation completion; default Chrome has no owned handoff.
  virtual base::OnceClosure GetExternalProtocolRequestCompletion(content::WebContents*);

  // Returns whether the WebContents is currently visible or not.'''
    yield delegate + ".cc", "bool WebContentsModalDialogManagerDelegate::IsWebContentsVisible(", '''base::OnceClosure
WebContentsModalDialogManagerDelegate::GetExternalProtocolRequestCompletion(content::WebContents*) {
  return {};
}

bool WebContentsModalDialogManagerDelegate::IsWebContentsVisible('''
    yield handler, '#include "components/web_modal/web_contents_modal_dialog_manager_delegate.h"', '''#include "components/web_modal/web_contents_modal_dialog_manager_delegate.h"
#include "base/functional/callback_helpers.h"
#include "base/no_destructor.h"'''
    yield handler, "bool EmbeddedExternalSourceCurrent(content::WebContents* contents,", '''base::OnceClosure EmbeddedExternalCompletion(content::WebContents* contents) {
  auto* manager = contents
      ? web_modal::WebContentsModalDialogManager::FromWebContents(contents) : nullptr;
  return manager && manager->delegate()
      ? manager->delegate()->GetExternalProtocolRequestCompletion(contents) : base::OnceClosure();
}

bool EmbeddedExternalSourceCurrent(content::WebContents* contents,'''
    # The early dialog wrapper precedes the helper definition.
    yield handler, "#if !BUILDFLAG(IS_ANDROID)\nvoid RunExternalProtocolDialogWithDelegate(", '''base::OnceClosure EmbeddedExternalCompletion(content::WebContents*);

#if !BUILDFLAG(IS_ANDROID)
void RunExternalProtocolDialogWithDelegate('''
    yield handler, "  CHECK(web_contents, base::NotFatalUntil::M161);\n  if (delegate) {", "  CHECK(web_contents, base::NotFatalUntil::M161);\n  base::ScopedClosureRunner completion(EmbeddedExternalCompletion(web_contents));\n  if (delegate) {"
    yield handler, "  ExternalProtocolHandler::RunExternalProtocolDialog(\n      url, web_contents", "  (void)completion.Release();  // The actual dialog owns its terminal callback.\n  ExternalProtocolHandler::RunExternalProtocolDialog(\n      url, web_contents"
    yield handler, "  if (!EmbeddedExternalSourceCurrent(web_contents, initiator_document)) return;", "  base::ScopedClosureRunner completion(EmbeddedExternalCompletion(web_contents));\n  if (!EmbeddedExternalSourceCurrent(web_contents, initiator_document)) return;"
    yield handler, "    base::RepeatingCallback<bool()> source_guard,\n    shell_integration::DefaultWebClientState state,", "    base::RepeatingCallback<bool()> source_guard,\n    base::OnceClosure request_completed,\n    shell_integration::DefaultWebClientState state,"
    yield handler, "  if (source_guard && !source_guard.Run()) return;\n\n  // The default handler", "  base::ScopedClosureRunner completion(std::move(request_completed));\n  if (source_guard && !source_guard.Run()) return;\n\n  // The default handler"
    yield handler, "    RunExternalProtocolDialogWithDelegate(\n        escaped_url", "    (void)completion.Release();  // Wrapper/dialog owns the next terminal path.\n    RunExternalProtocolDialogWithDelegate(\n        escaped_url"
    yield handler, "  Profile* profile = nullptr;\n  if (web_contents)", "  base::ScopedClosureRunner completion(EmbeddedExternalCompletion(web_contents));\n  Profile* profile = nullptr;\n  if (web_contents)"
    yield handler, "g_external_protocol_handler_delegate, std::move(source_guard));", "g_external_protocol_handler_delegate, std::move(source_guard), completion.Release());"
    yield dialog + ".h", '#include "base/functional/callback.h"', '#include "base/functional/callback.h"\n#include "base/functional/callback_helpers.h"'
    yield dialog + ".h", "  const GURL url_;", "  base::ScopedClosureRunner request_completed_;\n  const GURL url_;"
    yield dialog + ".cc", "    source_guard_ = manager->delegate()->GetDialogDecisionGuard(\n        web_contents, initiator_document_);", "    source_guard_ = manager->delegate()->GetDialogDecisionGuard(\n        web_contents, initiator_document_);\n    request_completed_.ReplaceClosure(\n        manager->delegate()->GetExternalProtocolRequestCompletion(web_contents));"

    # Owned fixture hooks preserve the actual Chrome dialog and shell lookup.
    # The final interceptor is process-local and suppresses every OS dispatch.
    yield delegate + ".h", '#include "base/functional/callback.h"', '#include "base/functional/callback.h"\n#include <string>\nclass GURL;'
    yield delegate + ".h", "  // Returns whether the WebContents is currently visible or not.", '''  virtual void DidShowExternalProtocolDialogForTesting(
      content::WebContents*, const GURL&, const std::u16string&,
      base::RepeatingCallback<bool()> visible, base::OnceClosure cancel,
      base::OnceClosure accept);

  // Returns whether the WebContents is currently visible or not.'''
    yield delegate + ".cc", "bool WebContentsModalDialogManagerDelegate::IsWebContentsVisible(", '''void WebContentsModalDialogManagerDelegate::DidShowExternalProtocolDialogForTesting(
    content::WebContents*, const GURL&, const std::u16string&,
    base::RepeatingCallback<bool()>, base::OnceClosure, base::OnceClosure) {}

bool WebContentsModalDialogManagerDelegate::IsWebContentsVisible('''
    yield "chrome/browser/external_protocol/external_protocol_handler.h", '#include <optional>', '#include <optional>\n#include "base/functional/callback.h"'
    yield "chrome/browser/external_protocol/external_protocol_handler.h", "  // Delegate to allow unit testing to provide different behavior.", '''  // A fresh owned fixture may suppress all final OS dispatches. Empty by default.
  static void SetOwnedFixtureLaunchInterceptorForTesting(
      base::RepeatingCallback<void(const GURL&, content::WebContents*)>);

  // Delegate to allow unit testing to provide different behavior.'''
    yield handler, "ExternalProtocolHandler::Delegate* g_external_protocol_handler_delegate =\n    nullptr;", '''ExternalProtocolHandler::Delegate* g_external_protocol_handler_delegate =
    nullptr;
base::RepeatingCallback<void(const GURL&, content::WebContents*)>&
OwnedFixtureLaunchInterceptor() {
  static base::NoDestructor<
      base::RepeatingCallback<void(const GURL&, content::WebContents*)>> interceptor;
  return *interceptor;
}'''
    yield handler, "  if (!EmbeddedExternalSourceCurrent(web_contents, initiator_document)) return;", '''  if (!EmbeddedExternalSourceCurrent(web_contents, initiator_document)) return;
  auto& interceptor = OwnedFixtureLaunchInterceptor();
  if (interceptor) {
    interceptor.Run(url, web_contents);
    return;
  }'''
    yield handler, "void ExternalProtocolHandler::PermitLaunchUrl() {", '''void ExternalProtocolHandler::SetOwnedFixtureLaunchInterceptorForTesting(
    base::RepeatingCallback<void(const GURL&, content::WebContents*)> interceptor) {
  OwnedFixtureLaunchInterceptor() = std::move(interceptor);
}

void ExternalProtocolHandler::PermitLaunchUrl() {'''
    yield dialog + ".cc", "\n}\n\nExternalProtocolDialog::~ExternalProtocolDialog() = default;", '''
  if (manager && manager->delegate() && GetWidget()) {
    auto widget = GetWidget()->GetWeakPtr();
    manager->delegate()->DidShowExternalProtocolDialogForTesting(
        web_contents, url_, program_name_,
        base::BindRepeating([](base::WeakPtr<views::Widget> widget) {
          return widget && widget->IsVisible();
        }, widget),
        base::BindOnce([](base::WeakPtr<views::Widget> widget, MayBeDangling<views::DialogDelegate> expected) {
          if (widget && widget->widget_delegate() == expected) expected->CancelDialog();
        }, widget, base::UnsafeDangling(static_cast<views::DialogDelegate*>(this))),
        base::BindOnce([](base::WeakPtr<views::Widget> widget, MayBeDangling<views::DialogDelegate> expected) {
          if (widget && widget->widget_delegate() == expected) expected->AcceptDialog();
        }, widget, base::UnsafeDangling(static_cast<views::DialogDelegate*>(this))));
  }
}

ExternalProtocolDialog::~ExternalProtocolDialog() = default;'''

    build = "chrome/browser/ui/views/BUILD.gn"
    prefix = '\n'.join([
        'source_set("external_protocol_dialog") {',
        '  public = [ "external_protocol_dialog.h" ]',
        '  sources = [ "external_protocol_dialog.cc" ]',
        '  public_deps = [',
    ])
    yield build, prefix, prefix + '\n    "//components/web_modal",'


def patches():
    # Fold edits to generated text into their original pinned-source anchor.
    # Each final patch remains independently idempotent and fails closed.
    folded = []
    for relative, old, new in _patches():
        owners = [index for index, (path, _, body) in enumerate(folded)
                  if path == relative and old in body]
        if len(owners) == 1:
            index = owners[0]
            path, anchor, body = folded[index]
            if body.count(old) != 1:
                raise ValueError("Ambiguous generated consent overlay anchor")
            folded[index] = path, anchor, body.replace(old, new, 1)
        else:
            folded.append((relative, old, new))
    yield from folded


def apply(source):
    # A previous Arx overlay used an exit-time callback global. Upgrade its
    # complete generated blocks before looking for the upstream anchors inside
    # them; otherwise a valid old overlay can receive duplicate definitions.
    interceptor = '''base::RepeatingCallback<void(const GURL&, content::WebContents*)>&
OwnedFixtureLaunchInterceptor() {
  static base::NoDestructor<
      base::RepeatingCallback<void(const GURL&, content::WebContents*)>> interceptor;
  return *interceptor;
}'''
    for relative, old, new in patches():
        previous = new.replace('\n#include "base/no_destructor.h"', '')
        previous = previous.replace(interceptor,
            'base::RepeatingCallback<void(const GURL&, content::WebContents*)> g_owned_fixture_interceptor;')
        previous = previous.replace('  auto& interceptor = OwnedFixtureLaunchInterceptor();\n'
            '  if (interceptor) {\n    interceptor.Run(url, web_contents);',
            '  if (g_owned_fixture_interceptor) {\n    g_owned_fixture_interceptor.Run(url, web_contents);')
        # The dialog's fixture actions may outlive it, so they bind it as
        # possibly dangling and touch it only while its widget still owns it.
        previous = previous.replace('MayBeDangling<views::DialogDelegate> expected',
            'views::DialogDelegate* expected')
        previous = previous.replace('base::UnsafeDangling(static_cast<views::DialogDelegate*>(this))',
            'static_cast<views::DialogDelegate*>(this)')
        previous = previous.replace('  OwnedFixtureLaunchInterceptor() = std::move(interceptor);',
            '  g_owned_fixture_interceptor = std::move(interceptor);')
        path = source / relative
        contents = path.read_text()
        if previous != new and new not in contents and contents.count(previous) == 1:
            path.write_text(contents.replace(previous, new, 1))
        replace_once(path, old, new)
