"""Arx's developer world (DEV-668): an isolated world for agent scripts that can't read credentials.

Agent scripts run in their own isolated world, never the page's main world. In
that world, in every frame, Blink answers with nothing where a script would
otherwise read credential material:

- `document.cookie` reads as empty, `window.cookieStore` is null and its reads
  throw;
- an input that has ever been a password field, or whose autocomplete names a
  password, card or one-time code, reads `value` as empty, even after a type
  change;
- `new FormData(form)` and `new PasswordCredential(form)` throw;
- `navigator.credentials.get`, `.store` and `.create` throw.

Arx's translation world (ABI57, DEV-996) is a second isolated world, only for
the app's page translation scripts, so they never share state with agent
scripts. It gets the same hooks: translation reads a page's text and nothing
else.

Hooks are keyed on the calling world, so the page and every other world keep
their behavior. New text lives in whole header files rewritten on every apply;
each hook anchors on an upstream line only.
"""

from .overlay import replace_once

WORLD_ID_HEADER = '''#ifndef THIRD_PARTY_BLINK_PUBLIC_COMMON_ARX_DEVELOPER_WORLD_ID_H_
#define THIRD_PARTY_BLINK_PUBLIC_COMMON_ARX_DEVELOPER_WORLD_ID_H_

#include <cstdint>

namespace blink {
// chrome::ISOLATED_WORLD_ID_ARX_DEVELOPER; the renderer asserts they match.
inline constexpr int32_t kArxDeveloperWorldId = 6;
// chrome::ISOLATED_WORLD_ID_ARX_TRANSLATION (ABI57, DEV-996): the app's page
// translation scripts, in ordinary and private pages.
inline constexpr int32_t kArxTranslationWorldId = 7;
}  // namespace blink
#endif
'''

WORLD_HEADER = '''#ifndef THIRD_PARTY_BLINK_RENDERER_PLATFORM_BINDINGS_ARX_DEVELOPER_WORLD_H_
#define THIRD_PARTY_BLINK_RENDERER_PLATFORM_BINDINGS_ARX_DEVELOPER_WORLD_H_

#include "third_party/blink/public/common/arx_developer_world_id.h"
#include "third_party/blink/renderer/platform/bindings/dom_wrapper_world.h"
#include "third_party/blink/renderer/platform/bindings/script_state.h"
#include "v8/include/v8-isolate.h"

namespace blink {
// True while a script of Arx's developer world, or of its translation world
// (ABI57), is the current caller: neither reads credentials.
inline bool IsArxDeveloperWorld(v8::Isolate* isolate) {
  if (!isolate || !isolate->InContext()) return false;
  ScriptState* state = ScriptState::MaybeFrom(isolate, isolate->GetCurrentContext());
  if (!state) return false;
  const int32_t world = state->World().GetWorldId();
  return world == kArxDeveloperWorldId || world == kArxTranslationWorldId;
}
}  // namespace blink
#endif
'''

WORLD_IDS = "chrome/common/chrome_isolated_world_ids.h"
WORLD_IDS_ANCHOR = "  // Numbers for isolated worlds for extensions are set in\n"
# The ids as a tree prepared before ABI57 has them, and as they are now.
ABI34_WORLD_IDS = ("  // Arx's developer tier: agent scripts, never the page's own world.\n"
                   "  ISOLATED_WORLD_ID_ARX_DEVELOPER,\n\n" + WORLD_IDS_ANCHOR)
WORLD_IDS_TEXT = ("  // Arx's developer tier: agent scripts, never the page's own world.\n"
                  "  ISOLATED_WORLD_ID_ARX_DEVELOPER,\n\n"
                  "  // Arx's page translation scripts (ABI57, DEV-996).\n"
                  "  ISOLATED_WORLD_ID_ARX_TRANSLATION,\n\n" + WORLD_IDS_ANCHOR)

INCLUDE = '#include "third_party/blink/renderer/platform/bindings/arx_developer_world.h"\n'

REFUSAL = "Arx's developer scripts can't read credentials."

VALUE_FOR_BINDING = '''String HTMLInputElement::valueForBinding() const {
  // Arx: a password, card or one-time-code value never reaches Arx's
  // developer world, even after the field's type changes.
  if (IsArxDeveloperWorld(v8::Isolate::TryGetCurrent())) {
    if (arx_was_password_) return g_empty_string;
    std::string autocomplete = FastGetAttribute(html_names::kAutocompleteAttr).GetString().Utf8();
    for (char& character : autocomplete) {
      if (character >= 'A' && character <= 'Z') character += 'a' - 'A';
    }
    for (const char* token : {"password", "cc-number", "cc-csc", "cc-exp", "one-time-code"}) {
      if (autocomplete.find(token) != std::string::npos) return g_empty_string;
    }
  }
  return Value();
}

void HTMLInputElement::setValueForBinding(const String& value,'''


def refuse(promise):
    return (f'  if (IsArxDeveloperWorld(script_state->GetIsolate())) {{\n'
            f'    exception_state.ThrowSecurityError("{REFUSAL}");\n'
            f'    return {promise};\n'
            f'  }}\n')


def patches():
    blink = "third_party/blink/renderer"
    input_cc = f"{blink}/core/html/forms/html_input_element.cc"
    cookie_store = f"{blink}/modules/cookie_store/cookie_store.cc"
    credentials = f"{blink}/modules/credentialmanagement/authentication_credentials_container.cc"
    get_all = ("ScriptPromise<IDLSequence<CookieListItem>> CookieStore::getAll(\n"
               "    ScriptState* script_state,\n"
               "    const CookieStoreGetOptions* options,\n"
               "    ExceptionState& exception_state) {\n")
    get_one = ("ScriptPromise<IDLNullable<CookieListItem>> CookieStore::get(\n"
               "    ScriptState* script_state,\n"
               "    const CookieStoreGetOptions* options,\n"
               "    ExceptionState& exception_state) {\n")
    credential_get = ("ScriptPromise<IDLNullable<Credential>> AuthenticationCredentialsContainer::get(\n"
                      "    ScriptState* script_state,\n"
                      "    const CredentialRequestOptions* options,\n"
                      "    ExceptionState& exception_state) {\n")
    credential_store = ("ScriptPromise<Credential> AuthenticationCredentialsContainer::store(\n"
                        "    ScriptState* script_state,\n"
                        "    Credential* credential,\n"
                        "    ExceptionState& exception_state) {\n")
    credential_create = ("AuthenticationCredentialsContainer::create(\n"
                         "    ScriptState* script_state,\n"
                         "    const CredentialCreationOptions* options,\n"
                         "    ExceptionState& exception_state) {\n")
    form_data = ("FormData* FormData::Create(HTMLFormElement* form,\n"
                 "                           HTMLElement* submitter,\n"
                 "                           ExceptionState& exception_state) {\n")
    global_cookie_store = "CookieStore* GlobalCookieStore::cookieStore(LocalDOMWindow& window) {\n"
    return [
        (WORLD_IDS, WORLD_IDS_ANCHOR, WORLD_IDS_TEXT),
        (f"{blink}/core/html/forms/html_input_element.h",
         "  String valueForBinding() const { return Value(); }\n",
         "  String valueForBinding() const;\n"
         "  // Arx: set once this input is a password field. Arx's developer world\n"
         "  // never reads its value, even after a type change.\n"
         "  bool arx_was_password_ = false;\n"),
        (input_cc, '#include "base/compiler_specific.h"\n',
         '#include "base/compiler_specific.h"\n' + INCLUDE),
        (input_cc,
         "  input_type_ = InputType::Create(*this, new_type_name);\n"
         "  input_type_view_ = input_type_->CreateView();\n"
         "  String default_value",
         "  input_type_ = InputType::Create(*this, new_type_name);\n"
         "  arx_was_password_ |= input_type_->IsPasswordInputType();\n"
         "  input_type_view_ = input_type_->CreateView();\n"
         "  String default_value"),
        (input_cc,
         "  input_type_ = new_type;\n"
         "  input_type_view_ = input_type_->CreateView();\n",
         "  input_type_ = new_type;\n"
         "  arx_was_password_ |= input_type_->IsPasswordInputType();\n"
         "  input_type_view_ = input_type_->CreateView();\n"),
        (input_cc, "void HTMLInputElement::setValueForBinding(const String& value,", VALUE_FOR_BINDING),
        (f"{blink}/core/dom/document.cc",
         '#include "third_party/blink/renderer/core/dom/document.h"\n',
         '#include "third_party/blink/renderer/core/dom/document.h"\n' + INCLUDE),
        (f"{blink}/core/dom/document.cc",
         "  CountUse(WebFeature::kCookieGet);\n",
         "  if (IsArxDeveloperWorld(dom_window_->GetIsolate())) return String();\n"
         "  CountUse(WebFeature::kCookieGet);\n"),
        (cookie_store,
         '#include "third_party/blink/renderer/modules/cookie_store/cookie_store.h"\n',
         '#include "third_party/blink/renderer/modules/cookie_store/cookie_store.h"\n' + INCLUDE),
        (cookie_store, get_all, get_all + refuse("EmptyPromise()")),
        (cookie_store, get_one, get_one + refuse("EmptyPromise()")),
        (f"{blink}/modules/cookie_store/global_cookie_store.cc",
         '#include "third_party/blink/renderer/modules/cookie_store/global_cookie_store.h"\n',
         '#include "third_party/blink/renderer/modules/cookie_store/global_cookie_store.h"\n' + INCLUDE),
        (f"{blink}/modules/cookie_store/global_cookie_store.cc", global_cookie_store,
         global_cookie_store + "  if (IsArxDeveloperWorld(window.GetIsolate())) return nullptr;\n"),
        (credentials,
         '#include "third_party/blink/renderer/modules/credentialmanagement/'
         'authentication_credentials_container.h"\n',
         '#include "third_party/blink/renderer/modules/credentialmanagement/'
         'authentication_credentials_container.h"\n' + INCLUDE),
        (credentials, credential_get,
         credential_get + refuse("ScriptPromise<IDLNullable<Credential>>()")),
        (credentials, credential_store, credential_store + refuse("EmptyPromise()")),
        (credentials, credential_create,
         credential_create + refuse("ScriptPromise<IDLNullable<Credential>>()")),
        (f"{blink}/core/html/forms/form_data.cc",
         '#include "third_party/blink/renderer/core/html/forms/form_data.h"\n',
         '#include "third_party/blink/renderer/core/html/forms/form_data.h"\n' + INCLUDE),
        (f"{blink}/core/html/forms/form_data.cc", form_data,
         form_data
         + "  if (form && IsArxDeveloperWorld(v8::Isolate::TryGetCurrent())) {\n"
         f'    exception_state.ThrowSecurityError("{REFUSAL}");\n'
         "    return nullptr;\n"
         "  }\n"),
    ]


def write_sources(source):
    """Whole files, rewritten on every application, so edits never double-apply."""
    for relative, text in [("third_party/blink/public/common/arx_developer_world_id.h", WORLD_ID_HEADER),
                           ("third_party/blink/renderer/platform/bindings/arx_developer_world.h", WORLD_HEADER)]:
        path = source / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


def apply(source):
    write_sources(source)
    # A tree prepared before ABI57 has the developer world's id alone.
    ids = source / WORLD_IDS
    if ids.exists():
        text = ids.read_text()
        if WORLD_IDS_TEXT not in text and text.count(ABI34_WORLD_IDS) == 1:
            ids.write_text(text.replace(ABI34_WORLD_IDS, WORLD_IDS_TEXT, 1))
    for relative, old, new in patches():
        replace_once(source / relative, old, new)
