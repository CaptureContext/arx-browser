"""Opt-in options dispatch; stock Chrome keeps its normal browser-window path."""
from .overlay import replace_once


def options_patches():
    header = "chrome/browser/extensions/api/runtime/chrome_runtime_api_delegate.h"
    source = "chrome/browser/extensions/api/runtime/chrome_runtime_api_delegate.cc"
    yield header, '#include "base/memory/raw_ptr.h"', '#include "base/memory/raw_ptr.h"\n#include "base/functional/callback.h"'
    yield header, '  // Sets a custom TickClock to use in tests.', '''  // An embedder owns all dispatch while installed, including refusal. The
  // actual RuntimeAPI supplies the extension/context; no caller URL is accepted.
  using EmbedderOptionsPageOpener = base::RepeatingCallback<void(
      const extensions::Extension*, content::BrowserContext*, base::OnceCallback<void(bool)>)>;
  static void SetEmbedderOptionsPageOpener(EmbedderOptionsPageOpener opener);

  // Sets a custom TickClock to use in tests.'''
    yield source, '#include "chrome/browser/extensions/api/runtime/chrome_runtime_api_delegate.h"', '#include "chrome/browser/extensions/api/runtime/chrome_runtime_api_delegate.h"\n#include "base/no_destructor.h"'
    yield source, 'namespace {', '''namespace {
ChromeRuntimeAPIDelegate::EmbedderOptionsPageOpener& EmbeddedOptionsPageOpener() {
  static base::NoDestructor<ChromeRuntimeAPIDelegate::EmbedderOptionsPageOpener> opener;
  return *opener;
}'''
    yield source, 'void ChromeRuntimeAPIDelegate::set_tick_clock_for_tests(', '''void ChromeRuntimeAPIDelegate::SetEmbedderOptionsPageOpener(EmbedderOptionsPageOpener opener) {
  EmbeddedOptionsPageOpener() = std::move(opener);
}

void ChromeRuntimeAPIDelegate::set_tick_clock_for_tests('''
    yield source, '''    base::OnceCallback<void(bool)> callback) {
  if (!extensions::OptionsPageInfo::HasOptionsPage(extension)) {''', '''    base::OnceCallback<void(bool)> callback) {
  if (EmbeddedOptionsPageOpener()) {
    // Copy before dispatch: teardown can clear the installed callback reentrantly.
    auto opener = EmbeddedOptionsPageOpener();
    opener.Run(extension, browser_context, std::move(callback));
    return;
  }
  if (!extensions::OptionsPageInfo::HasOptionsPage(extension)) {'''


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)


def command_patches():
    header = "chrome/browser/extensions/extension_keybinding_registry.h"
    source = "chrome/browser/extensions/extension_keybinding_registry.cc"
    yield header, "  // Notifies appropriate parties that a command has been executed.", '''  // Embedders with an actual contents host may supply its exact focused tab.
  // The desktop default retains the TabListInterface active-tab lookup.
  virtual content::WebContents* GetCommandWebContents() const;

  // Notifies appropriate parties that a command has been executed.'''
    yield source, "void ExtensionKeybindingRegistry::CommandExecuted(", '''content::WebContents* ExtensionKeybindingRegistry::GetCommandWebContents() const {
  auto* active_tab = tab_list_interface_ ? tab_list_interface_->GetActiveTab() : nullptr;
  return active_tab ? active_tab->GetContents() : nullptr;
}

void ExtensionKeybindingRegistry::CommandExecuted('''
    yield source, '''  if (tab_list_interface_) {
    auto* active_tab = tab_list_interface_->GetActiveTab();
    content::WebContents* web_contents =
        active_tab ? active_tab->GetContents() : nullptr;''', '''  if (content::WebContents* web_contents = GetCommandWebContents()) {'''


# Keep the two upstream seams in one fingerprinted next-batch overlay.
def patches():
    yield from options_patches()
    yield from command_patches()
